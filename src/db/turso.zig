//! Turso / LibSQL HTTP Pipeline Client.
//!
//! Provides a direct, native HTTP client for Turso (LibSQL) databases over the
//! `/v2/pipeline` protocol. Requires no local proxy, CLI, or companion daemon.
//!
//! Features:
//!   - Zero external dependencies: speaks native JSON over standard HTTP/TLS
//!   - Supports single `exec` and `query` operations with parameter binding (Hrana format)
//!   - Atomic multi-statement batch transactions in a single pipeline roundtrip
//!   - Direct schema inspection using SQLite system tables and pragmas
//!   - Health checks reporting SQLite version and engine identity
//!   - URL scheme normalization (`libsql://` -> `https://`, auto-appending `/v2/pipeline`)
//!   - Endpoint validation before transport (https, or loopback http only)
//!   - Socket read timeout + bounded response bodies on every pipeline request

const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const remote_http = @import("http_transport.zig");
const service = @import("service.zig");
const mock_http_server = @import("../ai/mock_http_server.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.turso);

pub const Error = service.Error;
pub const HealthStatus = service.HealthStatus;
pub const ExecResult = service.ExecResult;
pub const QueryResult = service.QueryResult;
pub const BatchResult = service.BatchResult;
pub const BatchStatement = service.BatchStatement;
pub const ColumnSchema = service.ColumnSchema;
pub const SchemaResult = service.SchemaResult;

/// Normalize a raw user or config URL to the Turso `/v2/pipeline` endpoint.
///
/// Accepts:
///   - `libsql://my-db.turso.io` -> `https://my-db.turso.io/v2/pipeline`
///   - `https://my-db.turso.io`  -> `https://my-db.turso.io/v2/pipeline`
///   - `http://127.0.0.1:8080`   -> `http://127.0.0.1:8080/v2/pipeline`
///   - `https://.../v2/pipeline` -> unchanged
///
/// Validation (#159) happens here, BEFORE any network activity: `https` is
/// always accepted, plain `http` only for loopback endpoints (local libsql/
/// sqld dev servers), and anything else — wrong scheme, missing host,
/// embedded credentials, unparseable URL — fails with `UnsupportedScheme` /
/// `InvalidEndpoint`.
pub fn pipelineUrl(allocator: std.mem.Allocator, raw_url: []const u8) ![]u8 {
    assert(raw_url.len > 0);
    var base = raw_url;
    var scheme_override: ?[]const u8 = null;
    if (std.mem.startsWith(u8, base, "libsql://")) {
        base = base["libsql://".len..];
        scheme_override = "https://";
    }

    const trimmed = std.mem.trimEnd(u8, base, "/");
    var candidate: []u8 = undefined;
    if (std.mem.endsWith(u8, trimmed, "/v2/pipeline")) {
        if (scheme_override) |s| {
            candidate = try std.fmt.allocPrint(allocator, "{s}{s}", .{ s, trimmed });
        } else {
            candidate = try allocator.dupe(u8, trimmed);
        }
    } else if (scheme_override) |s| {
        candidate = try std.fmt.allocPrint(allocator, "{s}{s}/v2/pipeline", .{ s, trimmed });
    } else {
        candidate = try std.fmt.allocPrint(allocator, "{s}/v2/pipeline", .{trimmed});
    }
    errdefer allocator.free(candidate);

    const uri = std.Uri.parse(candidate) catch return error.InvalidEndpoint;
    // Embedded credentials in a database endpoint are almost certainly a
    // mis-pasted URL; reject rather than silently send them as auth material.
    if (uri.user != null or uri.password != null) return error.InvalidEndpoint;
    const host_component = uri.host orelse return error.InvalidEndpoint;
    if (host_component.isEmpty()) return error.InvalidEndpoint;
    var host_buffer: [256]u8 = undefined;
    const host = host_component.toRaw(&host_buffer) catch return error.InvalidEndpoint;

    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        // Always accepted.
    } else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) {
        // Plain HTTP is only permitted for loopback endpoints.
        if (!isLoopbackHost(host)) return error.UnsupportedScheme;
    } else {
        return error.UnsupportedScheme;
    }
    return candidate;
}

fn isLoopbackHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.ascii.eqlIgnoreCase(host, "::1") or std.mem.eql(u8, host, "[::1]")) return true;
    return std.ascii.startsWithIgnoreCase(host, "127.");
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    auth_token: ?[]const u8 = null,
    /// Windows bounds the whole pipeline by this deadline; POSIX applies it
    /// to socket sends and reads. Multi-megabyte roaming resumes can exceed
    /// 15 seconds on a cold Turso read even when the indexed query is healthy.
    timeout_seconds: u32 = remote_http.timeout_seconds_default,
    /// Response-body ceiling; over-cap responses fail with
    /// `error.ResponseTooLarge`. Field (not constant) so tests can shrink it.
    response_max_bytes: usize = service.response_max_bytes,

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8, auth_token: ?[]const u8) Client {
        assert(endpoint.len > 0);
        return .{
            .allocator = allocator,
            .endpoint = endpoint,
            .auth_token = auth_token,
        };
    }

    pub fn health(self: *const Client, io: std.Io) !HealthStatus {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        var res = try self.query(io, "SELECT sqlite_version() AS version", &.{});
        defer res.deinit();

        var version_str: []const u8 = "3.45.0";
        if (res.rows.len > 0 and res.rows[0].len > 0) {
            version_str = switch (res.rows[0][0]) {
                .text => |t| t,
                else => "3.45.0",
            };
        }

        return HealthStatus{
            .status = try aa.dupe(u8, "ok"),
            .backend = try aa.dupe(u8, "turso (libsql)"),
            .version = try aa.dupe(u8, version_str),
            .auth_required = (self.auth_token != null),
            .arena = arena,
        };
    }

    pub fn exec(self: *const Client, io: std.Io, sql: []const u8, params: []const db.Value) !ExecResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const stmts = [_]BatchStatement{.{ .sql = sql, .params = params }};
        const payload = try serializePipelinePayload(aa, &stmts, false);
        const response_bytes = try self.fetchPipeline(aa, io, payload);

        const parsed = std.json.parseFromSlice(std.json.Value, aa, response_bytes, .{}) catch return error.InvalidResponse;
        if (parsed.value != .object) return error.InvalidResponse;

        const results_arr = parsed.value.object.get("results") orelse return error.InvalidResponse;
        if (results_arr != .array or results_arr.array.items.len != 2) return error.InvalidResponse;

        const resp_obj = try requireOkResponse(results_arr.array.items[0], "execute", "exec");
        try validateCloseResponse(results_arr.array.items[1], "exec close");

        const result_data = resp_obj.object.get("result") orelse return error.InvalidResponse;
        if (result_data != .object) return error.InvalidResponse;

        var changes: i32 = 0;
        if (result_data.object.get("affected_row_count")) |arc| {
            if (arc != .integer) return error.InvalidResponse;
            changes = std.math.cast(i32, arc.integer) orelse return error.InvalidResponse;
        }

        var last_id: ?i64 = null;
        if (result_data.object.get("last_insert_rowid")) |lir| {
            if (lir == .string) {
                last_id = std.fmt.parseInt(i64, lir.string, 10) catch return error.InvalidResponse;
            } else if (lir == .integer) {
                last_id = lir.integer;
            } else if (lir != .null) {
                return error.InvalidResponse;
            }
        }

        return ExecResult{
            .success = true,
            .changes = changes,
            .last_insert_rowid = last_id,
        };
    }

    pub fn query(self: *const Client, io: std.Io, sql: []const u8, params: []const db.Value) !QueryResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        const stmts = [_]BatchStatement{.{ .sql = sql, .params = params }};
        const payload = try serializePipelinePayload(aa, &stmts, false);
        const response_bytes = try self.fetchPipeline(aa, io, payload);

        const parsed = std.json.parseFromSlice(std.json.Value, aa, response_bytes, .{}) catch return error.InvalidResponse;
        if (parsed.value != .object) return error.InvalidResponse;

        const results_arr = parsed.value.object.get("results") orelse return error.InvalidResponse;
        if (results_arr != .array or results_arr.array.items.len != 2) return error.InvalidResponse;

        const resp_obj = try requireOkResponse(results_arr.array.items[0], "execute", "query");
        try validateCloseResponse(results_arr.array.items[1], "query close");

        const result_data = resp_obj.object.get("result") orelse return error.InvalidResponse;
        if (result_data != .object) return error.InvalidResponse;

        const cols_val = result_data.object.get("cols") orelse return error.InvalidResponse;
        if (cols_val != .array) return error.InvalidResponse;

        const rows_val = result_data.object.get("rows") orelse return error.InvalidResponse;
        if (rows_val != .array) return error.InvalidResponse;

        const num_cols = cols_val.array.items.len;
        var columns = try aa.alloc([]const u8, num_cols);
        var types = try aa.alloc(db.ColumnType, num_cols);
        const infer_types = try aa.alloc(bool, num_cols);

        for (cols_val.array.items, 0..) |col_item, i| {
            if (col_item != .object) return error.InvalidResponse;
            const name_val = col_item.object.get("name") orelse return error.InvalidResponse;
            if (name_val != .string) return error.InvalidResponse;
            columns[i] = try aa.dupe(u8, name_val.string);

            const decl_val = col_item.object.get("decltype");
            infer_types[i] = decl_val == null or decl_val.? == .null or
                (decl_val.? == .string and decl_val.?.string.len == 0);
            if (!infer_types[i] and decl_val.? != .string) return error.InvalidResponse;
            types[i] = if (infer_types[i]) .text else parseTypeString(decl_val.?.string);
        }

        var rows = try aa.alloc([]db.Value, rows_val.array.items.len);
        for (rows_val.array.items, 0..) |row_item, row_idx| {
            if (row_item != .array) return error.InvalidResponse;
            if (row_item.array.items.len != num_cols) return error.InvalidResponse;
            var cells = try aa.alloc(db.Value, num_cols);
            for (row_item.array.items, 0..) |cell_val, col_idx| {
                cells[col_idx] = try parseHranaValue(aa, cell_val);
            }
            rows[row_idx] = cells;
        }

        for (0..num_cols) |c_idx| {
            if (infer_types[c_idx]) {
                for (rows) |row| {
                    const sample = row[c_idx];
                    switch (sample) {
                        .int => types[c_idx] = .int,
                        .float => types[c_idx] = .float,
                        .blob => types[c_idx] = .blob,
                        .text => types[c_idx] = .text,
                        .null => continue,
                    }
                    break;
                }
            }
        }

        return QueryResult{
            .arena = arena,
            .columns = columns,
            .types = types,
            .rows = rows,
            .count = rows.len,
        };
    }

    pub fn batch(self: *const Client, io: std.Io, statements: []const BatchStatement) !BatchResult {
        if (statements.len == 0) return BatchResult{ .success = true, .results_count = 0 };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const payload = try serializePipelinePayload(aa, statements, true);
        const response_bytes = try self.fetchPipeline(aa, io, payload);

        const parsed = std.json.parseFromSlice(std.json.Value, aa, response_bytes, .{}) catch return error.InvalidResponse;
        if (parsed.value != .object) return error.InvalidResponse;

        const results_arr = parsed.value.object.get("results") orelse return error.InvalidResponse;
        if (results_arr != .array or results_arr.array.items.len != 2) return error.InvalidResponse;

        const batch_response = try requireOkResponse(results_arr.array.items[0], "batch", "batch");
        try validateBatchResult(batch_response, statements.len);
        try validateCloseResponse(results_arr.array.items[1], "batch close");

        return BatchResult{
            .success = true,
            .results_count = statements.len,
        };
    }

    pub fn schema(self: *const Client, io: std.Io, table: ?[]const u8) !SchemaResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        var table_names: std.ArrayList([]const u8) = .empty;
        defer table_names.deinit(aa);

        if (table) |tbl| {
            try table_names.append(aa, try aa.dupe(u8, tbl));
        } else {
            var tables_query = try self.query(io, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", &.{});
            defer tables_query.deinit();
            for (tables_query.rows) |row| {
                if (row.len > 0) {
                    switch (row[0]) {
                        .text => |t| try table_names.append(aa, try aa.dupe(u8, t)),
                        else => {},
                    }
                }
            }
        }

        if (table_names.items.len == 0) {
            return SchemaResult{
                .arena = arena,
                .tables = &.{},
            };
        }

        // Batch all pragma_table_info queries in a single pipeline roundtrip to eliminate N+1 queries.
        var out: std.Io.Writer.Allocating = .init(aa);
        defer out.deinit();
        try out.writer.writeAll("{\"requests\":[");
        for (table_names.items, 0..) |tbl_name, i| {
            if (i > 0) try out.writer.writeByte(',');
            const table_param = [_]db.Value{.{ .text = tbl_name }};
            try serializeHranaStatement(&out.writer, aa, "SELECT cid, name, type, \"notnull\", dflt_value, pk FROM pragma_table_info(?)", &table_param);
        }
        try out.writer.writeAll(",{\"type\":\"close\"}]}");

        const payload = try out.toOwnedSlice();
        const response_bytes = try self.fetchPipeline(aa, io, payload);

        const parsed = std.json.parseFromSlice(std.json.Value, aa, response_bytes, .{}) catch return error.InvalidResponse;
        if (parsed.value != .object) return error.InvalidResponse;

        const results_arr = parsed.value.object.get("results") orelse return error.InvalidResponse;
        if (results_arr != .array or results_arr.array.items.len != table_names.items.len + 1) return error.InvalidResponse;

        try validateCloseResponse(results_arr.array.items[table_names.items.len], "schema close");

        var table_schemas: std.ArrayList(SchemaResult.TableSchema) = .empty;
        errdefer table_schemas.deinit(aa);

        for (table_names.items, 0..) |tbl_name, idx| {
            const resp_obj = requireOkResponse(results_arr.array.items[idx], "execute", "schema pragma") catch |err| {
                // A missing table is not an error here — pragma_table_info
                // returns zero rows for one — so every failure on this path
                // is transport/auth/protocol and must not silently shrink
                // the reported schema (#160).
                log.warn("turso.schema: pragma_table_info failed for table \"{s}\": {s}", .{ tbl_name, @errorName(err) });
                return err;
            };

            const result_data = resp_obj.object.get("result") orelse return error.InvalidResponse;
            if (result_data != .object) return error.InvalidResponse;

            const rows_val = result_data.object.get("rows") orelse return error.InvalidResponse;
            if (rows_val != .array) return error.InvalidResponse;

            var cols: std.ArrayList(ColumnSchema) = .empty;
            errdefer cols.deinit(aa);

            // PRAGMA table_info returns: cid, name, type, notnull, dflt_value, pk
            for (rows_val.array.items) |row_item| {
                if (row_item != .array or row_item.array.items.len < 6) continue;

                const col_name_val = try parseHranaValue(aa, row_item.array.items[1]);
                const col_name = switch (col_name_val) {
                    .text => |t| t,
                    else => continue,
                };
                const col_type_val = try parseHranaValue(aa, row_item.array.items[2]);
                const col_type = switch (col_type_val) {
                    .text => |t| t,
                    else => "TEXT",
                };
                const notnull_val = try parseHranaValue(aa, row_item.array.items[3]);
                const notnull = switch (notnull_val) {
                    .int => |v| (v != 0),
                    else => false,
                };
                const pk_val = try parseHranaValue(aa, row_item.array.items[5]);
                const pk = switch (pk_val) {
                    .int => |v| (v != 0),
                    else => false,
                };

                try cols.append(aa, .{
                    .name = try aa.dupe(u8, col_name),
                    .type_name = try aa.dupe(u8, col_type),
                    .nullable = !notnull,
                    .primary_key = pk,
                });
            }

            try table_schemas.append(aa, .{
                .name = try aa.dupe(u8, tbl_name),
                .columns = try cols.toOwnedSlice(aa),
            });
        }
        return SchemaResult{
            .arena = arena,
            .tables = try table_schemas.toOwnedSlice(aa),
        };
    }

    fn fetchPipeline(
        self: *const Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        payload: []const u8,
    ) ![]const u8 {
        const url = try pipelineUrl(allocator, self.endpoint);
        defer allocator.free(url);

        const options: remote_http.Options = .{
            .method = .POST,
            .url = url,
            .payload = payload,
            .auth_token = self.auth_token,
            .timeout_seconds = self.timeout_seconds,
            .response_max_bytes = self.response_max_bytes,
        };
        const response = try remote_http.fetch(allocator, io, &options);
        errdefer allocator.free(response.body);

        if (response.status == 401 or response.status == 403) return error.Unauthorized;
        if (!http.isSuccess(response.status)) {
            // Head-cut the body: warn lines route into the toast bus when the
            // TUI is up, and a misconfigured host can return a huge HTML page.
            log.warn("turso HTTP {d} error response: {s}", .{ response.status, http.logBytesHead(response.body) });
            return error.HttpError;
        }
        return response.body;
    }
};

fn requireOkResponse(item: std.json.Value, expected_type: []const u8, operation: []const u8) !std.json.Value {
    if (item != .object) return error.InvalidResponse;

    const result_type = item.object.get("type") orelse return error.InvalidResponse;
    if (result_type != .string) return error.InvalidResponse;
    if (std.mem.eql(u8, result_type.string, "error")) {
        return classifyProviderError(item.object.get("error"), operation);
    }
    if (!std.mem.eql(u8, result_type.string, "ok")) return error.InvalidResponse;

    const response = item.object.get("response") orelse return error.InvalidResponse;
    if (response != .object) return error.InvalidResponse;
    const response_type = response.object.get("type") orelse return error.InvalidResponse;
    if (response_type != .string or !std.mem.eql(u8, response_type.string, expected_type)) {
        return error.InvalidResponse;
    }
    return response;
}

/// Log a Turso/LibSQL error object's code+message for diagnosis.
fn logProviderError(operation: []const u8, error_value: ?std.json.Value) void {
    const err_obj = error_value orelse {
        log.warn("turso.{s} error: (no error object)", .{operation});
        return;
    };
    if (err_obj != .object) {
        log.warn("turso.{s} error: (malformed error object)", .{operation});
        return;
    }
    const message: []const u8 = if (err_obj.object.get("message")) |m|
        (if (m == .string) m.string else "")
    else
        "";
    const code: []const u8 = if (err_obj.object.get("code")) |c|
        (if (c == .string) c.string else "")
    else
        "";
    log.warn("turso.{s} error code={s} message={s}", .{ operation, code, message });
}

/// Inspect a Turso/LibSQL error object (`{"message": ..., "code": ...}`) and
/// return a distinguishable error class (#162): callers can tell constraint,
/// syntax, and generic provider failures apart without parsing logs. The
/// code+message are always logged here for diagnosis.
fn classifyProviderError(error_value: ?std.json.Value, operation: []const u8) Error {
    logProviderError(operation, error_value);
    if (error_value == null or error_value.? != .object) return error.QueryFailed;
    const err_obj = error_value.?;

    const message: []const u8 = if (err_obj.object.get("message")) |m|
        (if (m == .string) m.string else "")
    else
        "";
    const code: []const u8 = if (err_obj.object.get("code")) |c|
        (if (c == .string) c.string else "")
    else
        "";

    // Classification keys off the provider error code first (SQLite extended
    // codes like SQLITE_CONSTRAINT_FOREIGNKEY) and falls back to the message
    // text, since sqld deployments frequently omit the code field.
    if (std.ascii.indexOfIgnoreCase(code, "CONSTRAINT") != null or
        std.ascii.indexOfIgnoreCase(message, "constraint") != null or
        std.ascii.indexOfIgnoreCase(message, "unique") != null or
        std.ascii.indexOfIgnoreCase(message, "foreign key") != null)
    {
        return error.ConstraintFailed;
    }
    if (std.ascii.indexOfIgnoreCase(code, "SQLITE_ERROR") != null or
        std.ascii.indexOfIgnoreCase(message, "syntax error") != null)
    {
        return error.SqlSyntaxError;
    }
    return error.QueryFailed;
}

fn logResponseError(operation: []const u8, error_value: ?std.json.Value) void {
    // Kept for the close-ambiguity path, where the error is observed but must
    // not fail the operation (see validateCloseResponse).
    logProviderError(operation, error_value);
}

fn validateCloseResponse(item: std.json.Value, operation: []const u8) !void {
    if (item != .object) return error.InvalidResponse;

    const result_type = item.object.get("type") orelse return error.InvalidResponse;
    if (result_type != .string) return error.InvalidResponse;
    if (std.mem.eql(u8, result_type.string, "error")) {
        // The statement has already completed, so surfacing a close failure as
        // a query failure could make a caller retry a committed mutation.
        // Observe only: the provider code+message are logged via
        // classifyProviderError for diagnosis (#162).
        logResponseError(operation, item.object.get("error"));
        return;
    }
    if (!std.mem.eql(u8, result_type.string, "ok")) return error.InvalidResponse;

    const response = item.object.get("response") orelse return error.InvalidResponse;
    if (response != .object) return error.InvalidResponse;
    const response_type = response.object.get("type") orelse return error.InvalidResponse;
    if (response_type != .string or !std.mem.eql(u8, response_type.string, "close")) {
        return error.InvalidResponse;
    }
}

fn validateBatchResult(batch_response: std.json.Value, statement_count: usize) !void {
    // Defensive shape validation (#162): do not assume the caller handed us
    // an object — a malformed response is InvalidResponse, never a query
    // failure the caller might retry.
    if (batch_response != .object) return error.InvalidResponse;

    const result = batch_response.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;

    const step_results = result.object.get("step_results") orelse return error.InvalidResponse;
    const step_errors = result.object.get("step_errors") orelse return error.InvalidResponse;
    if (step_results != .array or step_errors != .array) return error.InvalidResponse;

    const step_count = statement_count + 3;
    if (step_results.array.items.len != step_count or step_errors.array.items.len != step_count) {
        return error.InvalidResponse;
    }

    const commit_step = statement_count + 1;
    for (0..commit_step + 1) |step| {
        const step_result = step_results.array.items[step];
        const step_error = step_errors.array.items[step];
        if (step_error != .null) {
            return classifyProviderError(step_error, "batch step");
        }
        if (step_result != .object) return error.InvalidResponse;
    }

    const rollback_step = commit_step + 1;
    if (step_results.array.items[rollback_step] != .null or
        step_errors.array.items[rollback_step] != .null)
    {
        log.warn("turso.batch rollback executed after commit step", .{});
        return error.QueryFailed;
    }
}

fn parseTypeString(s: []const u8) db.ColumnType {
    if (std.ascii.eqlIgnoreCase(s, "int") or std.ascii.eqlIgnoreCase(s, "integer")) return .int;
    if (std.ascii.eqlIgnoreCase(s, "float") or std.ascii.eqlIgnoreCase(s, "real") or std.ascii.eqlIgnoreCase(s, "double")) return .float;
    if (std.ascii.eqlIgnoreCase(s, "blob")) return .blob;
    if (std.ascii.eqlIgnoreCase(s, "null")) return .null;
    return .text;
}

pub fn parseHranaValue(aa: std.mem.Allocator, cell_val: std.json.Value) !db.Value {
    if (cell_val != .object) return error.InvalidResponse;
    const type_val = cell_val.object.get("type") orelse return error.InvalidResponse;
    if (type_val != .string) return error.InvalidResponse;
    const type_str = type_val.string;

    if (std.mem.eql(u8, type_str, "null")) {
        return .null;
    } else if (std.mem.eql(u8, type_str, "integer")) {
        const value = cell_val.object.get("value") orelse return error.InvalidResponse;
        if (value == .string) {
            const number = std.fmt.parseInt(i64, value.string, 10) catch return error.InvalidResponse;
            return .{ .int = number };
        } else if (value == .integer) {
            return .{ .int = value.integer };
        }
        return error.InvalidResponse;
    } else if (std.mem.eql(u8, type_str, "float")) {
        const value = cell_val.object.get("value") orelse return error.InvalidResponse;
        if (value == .float) {
            return .{ .float = value.float };
        } else if (value == .integer) {
            return .{ .float = @floatFromInt(value.integer) };
        }
        return error.InvalidResponse;
    } else if (std.mem.eql(u8, type_str, "text")) {
        const value = cell_val.object.get("value") orelse return error.InvalidResponse;
        if (value != .string) return error.InvalidResponse;
        return .{ .text = try aa.dupe(u8, value.string) };
    } else if (std.mem.eql(u8, type_str, "blob")) {
        const value = cell_val.object.get("base64") orelse return error.InvalidResponse;
        if (value != .string) return error.InvalidResponse;
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(value.string) catch
            return error.InvalidResponse;
        const decoded_buf = try aa.alloc(u8, decoded_len);
        std.base64.standard.Decoder.decode(decoded_buf, value.string) catch
            return error.InvalidResponse;
        return .{ .blob = decoded_buf };
    }
    return error.InvalidResponse;
}

pub fn serializeHranaValue(writer: anytype, allocator: std.mem.Allocator, val: db.Value) !void {
    switch (val) {
        .null => try writer.writeAll("{\"type\":\"null\"}"),
        .int => |v| {
            try writer.writeAll("{\"type\":\"integer\",\"value\":");
            var num_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "\"{d}\"", .{v}) catch unreachable;
            try writer.writeAll(s);
            try writer.writeAll("}");
        },
        .float => |v| {
            // NaN/Infinity are not representable in JSON — reject them before
            // they can produce an invalid payload the provider would refuse
            // with a confusing error (#162).
            if (!std.math.isFinite(v)) return error.InvalidParameter;
            try writer.writeAll("{\"type\":\"float\",\"value\":");
            try writer.print("{d}", .{v});
            try writer.writeAll("}");
        },
        .text => |v| {
            try writer.writeAll("{\"type\":\"text\",\"value\":");
            try std.json.Stringify.value(v, .{}, writer);
            try writer.writeAll("}");
        },
        .blob => |v| {
            const b64_len = std.base64.standard.Encoder.calcSize(v.len);
            const b64_buf = try allocator.alloc(u8, b64_len);
            defer allocator.free(b64_buf);
            _ = std.base64.standard.Encoder.encode(b64_buf, v);
            try writer.writeAll("{\"type\":\"blob\",\"base64\":");
            try std.json.Stringify.value(b64_buf, .{}, writer);
            try writer.writeAll("}");
        },
    }
}

fn serializeHranaStmt(writer: anytype, allocator: std.mem.Allocator, sql: []const u8, params: []const db.Value) !void {
    try writer.writeAll("{\"sql\":");
    try std.json.Stringify.value(sql, .{}, writer);
    try writer.writeAll(",\"args\":[");
    for (params, 0..) |p, i| {
        if (i > 0) try writer.writeByte(',');
        try serializeHranaValue(writer, allocator, p);
    }
    try writer.writeAll("]}");
}

pub fn serializeHranaStatement(writer: anytype, allocator: std.mem.Allocator, sql: []const u8, params: []const db.Value) !void {
    try writer.writeAll("{\"type\":\"execute\",\"stmt\":");
    try serializeHranaStmt(writer, allocator, sql, params);
    try writer.writeByte('}');
}

pub fn serializePipelinePayload(allocator: std.mem.Allocator, statements: []const BatchStatement, in_transaction: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    if (in_transaction) {
        try out.writer.writeAll("{\"requests\":[{\"type\":\"batch\",\"batch\":{\"steps\":[");
        try out.writer.writeAll("{\"stmt\":{\"sql\":\"BEGIN\"}}");

        for (statements, 0..) |stmt, i| {
            try out.writer.print(",{{\"condition\":{{\"type\":\"ok\",\"step\":{d}}},\"stmt\":", .{i});
            try serializeHranaStmt(&out.writer, allocator, stmt.sql, stmt.params);
            try out.writer.writeByte('}');
        }

        const commit_step = statements.len + 1;
        try out.writer.print(",{{\"condition\":{{\"type\":\"ok\",\"step\":{d}}},\"stmt\":{{\"sql\":\"COMMIT\"}}}}", .{commit_step - 1});
        try out.writer.print(",{{\"condition\":{{\"type\":\"not\",\"cond\":{{\"type\":\"ok\",\"step\":{d}}}}},\"stmt\":{{\"sql\":\"ROLLBACK\"}}}}", .{commit_step});
        try out.writer.writeAll("]}},{\"type\":\"close\"}]}");
    } else {
        assert(statements.len == 1);
        try out.writer.writeAll("{\"requests\":[");
        try serializeHranaStatement(&out.writer, allocator, statements[0].sql, statements[0].params);
        try out.writer.writeAll(",{\"type\":\"close\"}]}");
    }

    return out.toOwnedSlice();
}

test "pipelineUrl correctly normalizes libsql and https URLs" {
    const gpa = std.testing.allocator;

    const url1 = try pipelineUrl(gpa, "libsql://my-db.turso.io");
    defer gpa.free(url1);
    try std.testing.expectEqualStrings("https://my-db.turso.io/v2/pipeline", url1);

    const url2 = try pipelineUrl(gpa, "https://my-db.turso.io/");
    defer gpa.free(url2);
    try std.testing.expectEqualStrings("https://my-db.turso.io/v2/pipeline", url2);

    const url3 = try pipelineUrl(gpa, "https://my-db.turso.io/v2/pipeline");
    defer gpa.free(url3);
    try std.testing.expectEqualStrings("https://my-db.turso.io/v2/pipeline", url3);

    const url4 = try pipelineUrl(gpa, "http://127.0.0.1:8080");
    defer gpa.free(url4);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/v2/pipeline", url4);
}

test "serializePipelinePayload makes transactional batches conditional" {
    const gpa = std.testing.allocator;

    const params = [_]db.Value{
        .{ .int = 123 },
        .{ .text = "session-1" },
        .{ .null = {} },
    };
    const stmts = [_]BatchStatement{
        .{ .sql = "INSERT INTO test (id, title, notes) VALUES (?, ?, ?)", .params = &params },
    };

    const payload = try serializePipelinePayload(gpa, &stmts, true);
    defer gpa.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, payload, .{});
    defer parsed.deinit();

    const requests = parsed.value.object.get("requests").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), requests.len);
    const steps = requests[0].object.get("batch").?.object.get("steps").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), steps.len);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"BEGIN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"COMMIT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"ROLLBACK\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"not\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"integer\",\"value\":\"123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"text\",\"value\":\"session-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"null\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"close\"") != null);
}

test "validateBatchResult accepts commit and rejects rollback" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const committed_response =
        \\{
        \\  "type": "batch",
        \\  "result": {
        \\    "step_results": [{}, {}, {}, null],
        \\    "step_errors": [null, null, null, null]
        \\  }
        \\}
    ;
    const committed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), committed_response, .{});
    try validateBatchResult(committed.value, 1);

    const rolled_back_response =
        \\{
        \\  "type": "batch",
        \\  "result": {
        \\    "step_results": [{}, null, null, {}],
        \\    "step_errors": [null, {"message": "constraint failed", "code": "SQLITE_CONSTRAINT_PRIMARYKEY"}, null, null]
        \\  }
        \\}
    ;
    const rolled_back = try std.json.parseFromSlice(std.json.Value, arena.allocator(), rolled_back_response, .{});
    // Constraint-class failures are distinguishable from generic provider
    // failures (#162) — callers can branch without parsing logs.
    try std.testing.expectError(error.ConstraintFailed, validateBatchResult(rolled_back.value, 1));
}

// #162: batch validation must independently validate response shape. A
// non-object batch response or a malformed step entry is a protocol error
// (InvalidResponse), not a query failure a caller might retry; provider
// error objects classify into distinct error classes.
test "validateBatchResult validates shape and classifies provider errors" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    // Non-object input: InvalidResponse even though the caller was supposed
    // to pre-validate (requireOkResponse) — defense in depth.
    const not_object = try std.json.parseFromSlice(std.json.Value, aa, "123", .{});
    try std.testing.expectError(error.InvalidResponse, validateBatchResult(not_object.value, 1));

    // A step_result entry with the wrong shape is a protocol violation.
    const bad_step_shape =
        \\{
        \\  "type": "batch",
        \\  "result": {
        \\    "step_results": [{}, "not-an-object", {}, null],
        \\    "step_errors": [null, null, null, null]
        \\  }
        \\}
    ;
    const bad_shape = try std.json.parseFromSlice(std.json.Value, aa, bad_step_shape, .{});
    try std.testing.expectError(error.InvalidResponse, validateBatchResult(bad_shape.value, 1));

    // A syntax-class provider error classifies distinctly.
    const syntax_error =
        \\{
        \\  "type": "batch",
        \\  "result": {
        \\    "step_results": [{}, null, null, {}],
        \\    "step_errors": [null, {"message": "near \"FRUM\": syntax error"}, null, null]
        \\  }
        \\}
    ;
    const syntax = try std.json.parseFromSlice(std.json.Value, aa, syntax_error, .{});
    try std.testing.expectError(error.SqlSyntaxError, validateBatchResult(syntax.value, 1));
}

// #162: NaN and infinities are not representable in JSON; they must be
// rejected at serialization time with a dedicated invalid-parameter error.
test "serializeHranaValue rejects non-finite floats" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try std.testing.expectError(
        error.InvalidParameter,
        serializeHranaValue(&out.writer, gpa, .{ .float = std.math.nan(f64) }),
    );
    try std.testing.expectError(
        error.InvalidParameter,
        serializeHranaValue(&out.writer, gpa, .{ .float = std.math.inf(f64) }),
    );
    // A finite float still serializes.
    try serializeHranaValue(&out.writer, gpa, .{ .float = 1.5 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"type\":\"float\"") != null);
}

// #162: a close-response failure is observed (code+message logged) but must
// NOT fail the operation — the statement already completed, and surfacing
// the failure could make a caller retry a committed mutation.
test "validateCloseResponse observes error results without failing" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const close_error =
        \\{"type":"error","error":{"message":"io error","code":"HRANA_CLOSED"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), close_error, .{});
    try validateCloseResponse(parsed.value, "test close");
}

test "parseHranaValue parses integers, text, floats, blobs, and nulls" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const json_str =
        \\[
        \\  {"type": "null"},
        \\  {"type": "integer", "value": "9876543210"},
        \\  {"type": "float", "value": 42.5},
        \\  {"type": "text", "value": "test string"},
        \\  {"type": "blob", "base64": "SGVsbG8="}
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, aa, json_str, .{});
    const items = parsed.value.array.items;

    const v0 = try parseHranaValue(aa, items[0]);
    try std.testing.expectEqual(db.Value.null, v0);

    const v1 = try parseHranaValue(aa, items[1]);
    try std.testing.expectEqual(@as(i64, 9876543210), v1.int);

    const v2 = try parseHranaValue(aa, items[2]);
    try std.testing.expectEqual(@as(f64, 42.5), v2.float);

    const v3 = try parseHranaValue(aa, items[3]);
    try std.testing.expectEqualStrings("test string", v3.text);

    const v4 = try parseHranaValue(aa, items[4]);
    try std.testing.expectEqualStrings("Hello", v4.blob);
}

test "parseHranaValue rejects malformed values" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const json_str =
        \\[
        \\  {"type": "integer", "value": "not-an-integer"},
        \\  {"type": "blob", "base64": "%%%"}
        \\]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, aa, json_str, .{});

    try std.testing.expectError(error.InvalidResponse, parseHranaValue(aa, parsed.value.array.items[0]));
    try std.testing.expectError(error.InvalidResponse, parseHranaValue(aa, parsed.value.array.items[1]));
}

// #159: invalid endpoints must fail in pipelineUrl — BEFORE any network
// activity. Wrong schemes, plain http off-loopback, embedded credentials,
// and missing hosts are all configuration errors, not runtime surprises.
test "pipelineUrl rejects invalid endpoints before transport" {
    const gpa = std.testing.allocator;

    try std.testing.expectError(error.UnsupportedScheme, pipelineUrl(gpa, "ftp://db.example.com"));
    try std.testing.expectError(error.UnsupportedScheme, pipelineUrl(gpa, "ws://db.example.com"));
    try std.testing.expectError(error.UnsupportedScheme, pipelineUrl(gpa, "http://db.example.com"));
    try std.testing.expectError(error.InvalidEndpoint, pipelineUrl(gpa, "https://user:pass@db.example.com"));
    try std.testing.expectError(error.InvalidEndpoint, pipelineUrl(gpa, "https:///v2/pipeline"));

    // Local dev endpoints over plain http stay allowed.
    const local = try pipelineUrl(gpa, "http://localhost:8080");
    defer gpa.free(local);
    try std.testing.expectEqualStrings("http://localhost:8080/v2/pipeline", local);
}

// #159: an oversized response body must fail with ResponseTooLarge instead
// of accumulating without bound. The cap is a field so the test can shrink it.
test "oversized pipeline responses fail with ResponseTooLarge" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const responses = [_]mock_http_server.Response{
        .{ .status = .ok, .body = "0123456789abcdefghij" }, // 20 bytes > cap
    };
    var server = try mock_http_server.MockHttpServer.init(io, &responses);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, mock_http_server.MockHttpServer.serve, .{&server});
    defer thread.join();

    const endpoint = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(endpoint);
    var client = Client.init(gpa, endpoint, null);
    client.response_max_bytes = 16;

    try std.testing.expectError(error.ResponseTooLarge, client.query(io, "SELECT 1", &.{}));
}

// #159: a server that sends the head then stalls the body must hit the
// configured deadline. POSIX applies socket timeouts before the first byte;
// Windows races the whole exchange against a timer, so the same timeout holds
// on both platforms.
test "stalled pipeline body times out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const responses = [_]mock_http_server.Response{
        .{ .status = .ok, .body = "{}", .body_delay_ms = 3000 },
    };
    var server = try mock_http_server.MockHttpServer.init(io, &responses);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, mock_http_server.MockHttpServer.serve, .{&server});
    defer thread.join();

    const endpoint = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(endpoint);
    var client = Client.init(gpa, endpoint, null);
    client.timeout_seconds = 1;

    try std.testing.expectError(error.ServerTimeout, client.query(io, "SELECT 1", &.{}));
}

// #160: a failed per-table pragma query must fail the whole schema request.
// Before the fix, `catch continue` turned transport/auth/SQL failures into a
// silently omitted table — the tool reported an incomplete schema as success.
test "schema propagates pragma_table_info failures instead of omitting tables" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const listing_body =
        \\{"results":[{"type":"ok","response":{"type":"execute","result":{"cols":[{"name":"name"}],"rows":[[{"type":"text","value":"sessions"}]]}}},{"type":"ok","response":{"type":"close"}}]}
    ;
    const responses = [_]mock_http_server.Response{
        // 1st roundtrip: sqlite_master lists one table.
        .{ .status = .ok, .body = listing_body },
        // 2nd roundtrip: pragma_table_info dies mid-request (HTTP 500).
        .{ .status = .internal_server_error, .body = "boom" },
    };
    var server = try mock_http_server.MockHttpServer.init(io, &responses);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, mock_http_server.MockHttpServer.serve, .{&server});
    defer thread.join();

    const endpoint = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(endpoint);
    const client = Client.init(gpa, endpoint, null);

    try std.testing.expectError(error.HttpError, client.schema(io, null));
}


test "schema fetches multiple table schemas in a single batched pipeline request" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const listing_body =
        \\{"results":[{"type":"ok","response":{"type":"execute","result":{"cols":[{"name":"name"}],"rows":[[{"type":"text","value":"users"}],[{"type":"text","value":"posts"}]]}}},{"type":"ok","response":{"type":"close"}}]}
    ;
    const pragma_batched_body =
        \\{"results":[
        \\  {"type":"ok","response":{"type":"execute","result":{"cols":[{"name":"cid"},{"name":"name"},{"name":"type"},{"name":"notnull"},{"name":"dflt_value"},{"name":"pk"}],"rows":[[{"type":"integer","value":"0"},{"type":"text","value":"id"},{"type":"text","value":"INTEGER"},{"type":"integer","value":"1"},{"type":"null"},{"type":"integer","value":"1"}],[{"type":"integer","value":"1"},{"type":"text","value":"email"},{"type":"text","value":"TEXT"},{"type":"integer","value":"1"},{"type":"null"},{"type":"integer","value":"0"}]]}}},
        \\  {"type":"ok","response":{"type":"execute","result":{"cols":[{"name":"cid"},{"name":"name"},{"name":"type"},{"name":"notnull"},{"name":"dflt_value"},{"name":"pk"}],"rows":[[{"type":"integer","value":"0"},{"type":"text","value":"id"},{"type":"text","value":"INTEGER"},{"type":"integer","value":"1"},{"type":"null"},{"type":"integer","value":"1"}],[{"type":"integer","value":"1"},{"type":"text","value":"title"},{"type":"text","value":"TEXT"},{"type":"integer","value":"0"},{"type":"null"},{"type":"integer","value":"0"}]]}}},
        \\  {"type":"ok","response":{"type":"close"}}
        \\]}
    ;
    const responses = [_]mock_http_server.Response{
        // 1st roundtrip: sqlite_master lists two tables.
        .{ .status = .ok, .body = listing_body },
        // 2nd roundtrip: batched pragma_table_info pipeline query for both tables in 1 HTTP roundtrip.
        .{ .status = .ok, .body = pragma_batched_body },
    };
    var server = try mock_http_server.MockHttpServer.init(io, &responses);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, mock_http_server.MockHttpServer.serve, .{&server});
    defer thread.join();

    const endpoint = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(endpoint);
    const client = Client.init(gpa, endpoint, null);

    var res = try client.schema(io, null);
    defer res.deinit();

    try std.testing.expectEqual(@as(usize, 2), res.tables.len);
    try std.testing.expectEqualStrings("users", res.tables[0].name);
    try std.testing.expectEqual(@as(usize, 2), res.tables[0].columns.len);
    try std.testing.expectEqualStrings("id", res.tables[0].columns[0].name);
    try std.testing.expectEqualStrings("email", res.tables[0].columns[1].name);

    try std.testing.expectEqualStrings("posts", res.tables[1].name);
    try std.testing.expectEqual(@as(usize, 2), res.tables[1].columns.len);
    try std.testing.expectEqualStrings("id", res.tables[1].columns[0].name);
    try std.testing.expectEqualStrings("title", res.tables[1].columns[1].name);
}
