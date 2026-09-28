//! Turso / LibSQL HTTP Pipeline Client.
//!
//! Provides a direct, native HTTP client for Turso (LibSQL) databases over the
//! `/v2/pipeline` protocol. Requires no local proxy, CLI, or companion daemon.
//!
//! Features:
//!   - Zero external dependencies: speaks native JSON over standard HTTP/TLS
//!   - Supports single `exec` and `query` operations with parameter binding (Hrana format)
//!   - Atomic multi-statement batch transactions (`BEGIN` ... `COMMIT` in a single pipeline roundtrip)
//!   - Direct schema inspection using SQLite system tables and pragmas
//!   - Health checks reporting SQLite version and engine identity
//!   - URL scheme normalization (`libsql://` -> `https://`, auto-appending `/v2/pipeline`)

const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const service = @import("service.zig");

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
pub fn pipelineUrl(allocator: std.mem.Allocator, raw_url: []const u8) ![]u8 {
    assert(raw_url.len > 0);
    var base = raw_url;
    var scheme_override: ?[]const u8 = null;
    if (std.mem.startsWith(u8, base, "libsql://")) {
        base = base["libsql://".len..];
        scheme_override = "https://";
    }

    const trimmed = std.mem.trimEnd(u8, base, "/");
    if (std.mem.endsWith(u8, trimmed, "/v2/pipeline")) {
        if (scheme_override) |s| {
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ s, trimmed });
        }
        return allocator.dupe(u8, trimmed);
    }

    if (scheme_override) |s| {
        return std.fmt.allocPrint(allocator, "{s}{s}/v2/pipeline", .{ s, trimmed });
    }
    return std.fmt.allocPrint(allocator, "{s}/v2/pipeline", .{trimmed});
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    auth_token: ?[]const u8 = null,
    timeout_seconds: u32 = 15,

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
        if (results_arr != .array or results_arr.array.items.len == 0) return error.InvalidResponse;

        const first_result = results_arr.array.items[0];
        if (first_result != .object) return error.InvalidResponse;

        const res_type = first_result.object.get("type");
        if (res_type == null or res_type.? != .string) return error.InvalidResponse;

        if (std.mem.eql(u8, res_type.?.string, "error")) {
            if (first_result.object.get("error")) |err_obj| {
                if (err_obj == .object) {
                    if (err_obj.object.get("message")) |msg| {
                        if (msg == .string) log.warn("turso.exec error: {s}", .{msg.string});
                    }
                }
            }
            return error.QueryFailed;
        }

        if (!std.mem.eql(u8, res_type.?.string, "ok")) return error.InvalidResponse;

        const resp_obj = first_result.object.get("response") orelse return error.InvalidResponse;
        if (resp_obj != .object) return error.InvalidResponse;

        const result_data = resp_obj.object.get("result") orelse return error.InvalidResponse;
        if (result_data != .object) return error.InvalidResponse;

        var changes: i32 = 0;
        if (result_data.object.get("affected_row_count")) |arc| {
            if (arc == .integer) changes = @intCast(arc.integer);
        }

        var last_id: ?i64 = null;
        if (result_data.object.get("last_insert_rowid")) |lir| {
            if (lir == .string) {
                last_id = std.fmt.parseInt(i64, lir.string, 10) catch null;
            } else if (lir == .integer) {
                last_id = lir.integer;
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
        if (results_arr != .array or results_arr.array.items.len == 0) return error.InvalidResponse;

        const first_result = results_arr.array.items[0];
        if (first_result != .object) return error.InvalidResponse;

        const res_type = first_result.object.get("type");
        if (res_type == null or res_type.? != .string) return error.InvalidResponse;

        if (std.mem.eql(u8, res_type.?.string, "error")) {
            if (first_result.object.get("error")) |err_obj| {
                if (err_obj == .object) {
                    if (err_obj.object.get("message")) |msg| {
                        if (msg == .string) log.warn("turso.query error: {s}", .{msg.string});
                    }
                }
            }
            return error.QueryFailed;
        }

        if (!std.mem.eql(u8, res_type.?.string, "ok")) return error.InvalidResponse;

        const resp_obj = first_result.object.get("response") orelse return error.InvalidResponse;
        if (resp_obj != .object) return error.InvalidResponse;

        const result_data = resp_obj.object.get("result") orelse return error.InvalidResponse;
        if (result_data != .object) return error.InvalidResponse;

        const cols_val = result_data.object.get("cols") orelse return error.InvalidResponse;
        if (cols_val != .array) return error.InvalidResponse;

        const rows_val = result_data.object.get("rows") orelse return error.InvalidResponse;
        if (rows_val != .array) return error.InvalidResponse;

        const num_cols = cols_val.array.items.len;
        var columns = try aa.alloc([]const u8, num_cols);
        var types = try aa.alloc(db.ColumnType, num_cols);

        for (cols_val.array.items, 0..) |col_item, i| {
            if (col_item != .object) return error.InvalidResponse;
            const name_val = col_item.object.get("name") orelse return error.InvalidResponse;
            columns[i] = try aa.dupe(u8, if (name_val == .string) name_val.string else "unknown");

            const decl_val = col_item.object.get("decltype");
            const decl_str = if (decl_val != null and decl_val.? == .string) decl_val.?.string else "text";
            types[i] = parseTypeString(decl_str);
        }

        var rows = try aa.alloc([]db.Value, rows_val.array.items.len);
        for (rows_val.array.items, 0..) |row_item, row_idx| {
            if (row_item != .array) return error.InvalidResponse;
            var cells = try aa.alloc(db.Value, num_cols);
            for (row_item.array.items, 0..) |cell_val, col_idx| {
                if (col_idx >= num_cols) break;
                cells[col_idx] = try parseHranaValue(aa, cell_val);
            }
            // Fill any missing trailing columns with null
            for (row_item.array.items.len..num_cols) |col_idx| {
                cells[col_idx] = .null;
            }
            rows[row_idx] = cells;
        }

        // Infer column types from the first non-null row cells when decltype was absent/generic
        if (rows.len > 0) {
            for (0..num_cols) |c_idx| {
                if (types[c_idx] == .text) {
                    const sample = rows[0][c_idx];
                    switch (sample) {
                        .int => types[c_idx] = .int,
                        .float => types[c_idx] = .float,
                        .blob => types[c_idx] = .blob,
                        else => {},
                    }
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
        if (results_arr != .array) return error.InvalidResponse;

        // Expect results: [BEGIN, stmt_1, ..., stmt_N, COMMIT, close]
        // results_arr.items.len should be statements.len + 3
        var ok_count: usize = 0;
        for (results_arr.array.items) |res_item| {
            if (res_item != .object) return error.InvalidResponse;
            const r_type = res_item.object.get("type");
            if (r_type == null or r_type.? != .string) return error.InvalidResponse;
            if (std.mem.eql(u8, r_type.?.string, "error")) {
                if (res_item.object.get("error")) |err_obj| {
                    if (err_obj == .object) {
                        if (err_obj.object.get("message")) |msg| {
                            if (msg == .string) log.warn("turso.batch error: {s}", .{msg.string});
                        }
                    }
                }
                return error.QueryFailed;
            }
            if (std.mem.eql(u8, r_type.?.string, "ok")) {
                ok_count += 1;
            }
        }

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

        var table_schemas: std.ArrayList(SchemaResult.TableSchema) = .empty;
        errdefer table_schemas.deinit(aa);

        for (table_names.items) |tbl_name| {
            const pragma_sql = try std.fmt.allocPrint(aa, "PRAGMA table_info(\"{s}\")", .{tbl_name});
            var info_query = self.query(io, pragma_sql, &.{}) catch continue;
            defer info_query.deinit();

            var cols: std.ArrayList(ColumnSchema) = .empty;
            errdefer cols.deinit(aa);

            // PRAGMA table_info returns: cid, name, type, notnull, dflt_value, pk
            for (info_query.rows) |row| {
                if (row.len < 6) continue;
                const col_name = switch (row[1]) {
                    .text => |t| t,
                    else => continue,
                };
                const col_type = switch (row[2]) {
                    .text => |t| t,
                    else => "TEXT",
                };
                const notnull = switch (row[3]) {
                    .int => |v| (v != 0),
                    else => false,
                };
                const pk = switch (row[5]) {
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
        var response_body: std.Io.Writer.Allocating = .init(allocator);
        errdefer response_body.deinit();
        var redirect_buffer: [http.redirect_buffer_bytes]u8 = undefined;

        var http_client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer http_client.deinit();

        const url = try pipelineUrl(allocator, self.endpoint);
        defer allocator.free(url);

        const auth_header: ?[]u8 = if (self.auth_token) |t|
            try std.fmt.allocPrint(allocator, "Bearer {s}", .{t})
        else
            null;
        defer if (auth_header) |a| allocator.free(a);

        const status = http_client.fetch(.{
            .method = .POST,
            .location = .{ .url = url },
            .payload = payload,
            .response_writer = &response_body.writer,
            .redirect_buffer = &redirect_buffer,
            .keep_alive = true,
            .headers = .{
                .content_type = .{ .override = http.content_type_json },
                .authorization = if (auth_header) |a| .{ .override = a } else .omit,
            },
        }) catch |err| switch (err) {
            error.ConnectionRefused, error.ConnectionResetByPeer => return error.ConnectionRefused,
            else => return err,
        };

        const code: u16 = @intFromEnum(status.status);
        if (code == 401 or code == 403) return error.Unauthorized;
        if (!http.isSuccess(code)) {
            log.warn("turso HTTP {d} error response: {s}", .{ code, response_body.written() });
            return error.HttpError;
        }

        return response_body.toOwnedSlice();
    }
};

fn parseTypeString(s: []const u8) db.ColumnType {
    if (std.ascii.eqlIgnoreCase(s, "int") or std.ascii.eqlIgnoreCase(s, "integer")) return .int;
    if (std.ascii.eqlIgnoreCase(s, "float") or std.ascii.eqlIgnoreCase(s, "real") or std.ascii.eqlIgnoreCase(s, "double")) return .float;
    if (std.ascii.eqlIgnoreCase(s, "blob")) return .blob;
    if (std.ascii.eqlIgnoreCase(s, "null")) return .null;
    return .text;
}

pub fn parseHranaValue(aa: std.mem.Allocator, cell_val: std.json.Value) !db.Value {
    if (cell_val != .object) return .null;
    const type_val = cell_val.object.get("type");
    const type_str = if (type_val != null and type_val.? == .string) type_val.?.string else "null";

    if (std.mem.eql(u8, type_str, "null")) {
        return .null;
    } else if (std.mem.eql(u8, type_str, "integer")) {
        if (cell_val.object.get("value")) |v| {
            if (v == .string) {
                const num = std.fmt.parseInt(i64, v.string, 10) catch 0;
                return .{ .int = num };
            } else if (v == .integer) {
                return .{ .int = v.integer };
            }
        }
        return .{ .int = 0 };
    } else if (std.mem.eql(u8, type_str, "float")) {
        if (cell_val.object.get("value")) |v| {
            if (v == .float) {
                return .{ .float = v.float };
            } else if (v == .integer) {
                return .{ .float = @floatFromInt(v.integer) };
            }
        }
        return .{ .float = 0.0 };
    } else if (std.mem.eql(u8, type_str, "text")) {
        if (cell_val.object.get("value")) |v| {
            if (v == .string) {
                return .{ .text = try aa.dupe(u8, v.string) };
            }
        }
        return .{ .text = try aa.dupe(u8, "") };
    } else if (std.mem.eql(u8, type_str, "blob")) {
        if (cell_val.object.get("base64")) |v| {
            if (v == .string) {
                const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(v.string) catch v.string.len;
                const decoded_buf = try aa.alloc(u8, decoded_len);
                std.base64.standard.Decoder.decode(decoded_buf, v.string) catch {
                    return .{ .blob = try aa.dupe(u8, v.string) };
                };
                return .{ .blob = decoded_buf };
            }
        }
        return .{ .blob = try aa.dupe(u8, "") };
    }
    return .null;
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

pub fn serializeHranaStatement(writer: anytype, allocator: std.mem.Allocator, sql: []const u8, params: []const db.Value) !void {
    try writer.writeAll("{\"type\":\"execute\",\"stmt\":{\"sql\":");
    try std.json.Stringify.value(sql, .{}, writer);
    try writer.writeAll(",\"args\":[");
    for (params, 0..) |p, i| {
        if (i > 0) try writer.writeByte(',');
        try serializeHranaValue(writer, allocator, p);
    }
    try writer.writeAll("]}}");
}

pub fn serializePipelinePayload(allocator: std.mem.Allocator, statements: []const BatchStatement, in_transaction: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeAll("{\"requests\":[");
    var wrote_first = false;

    if (in_transaction) {
        try out.writer.writeAll("{\"type\":\"execute\",\"stmt\":{\"sql\":\"BEGIN\"}}");
        wrote_first = true;
    }

    for (statements) |stmt| {
        if (wrote_first) try out.writer.writeByte(',');
        try serializeHranaStatement(&out.writer, allocator, stmt.sql, stmt.params);
        wrote_first = true;
    }

    if (in_transaction) {
        if (wrote_first) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"type\":\"execute\",\"stmt\":{\"sql\":\"COMMIT\"}}");
        wrote_first = true;
    }

    if (wrote_first) try out.writer.writeByte(',');
    try out.writer.writeAll("{\"type\":\"close\"}]}");

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

test "serializePipelinePayload formats valid Hrana pipeline JSON with parameters" {
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

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"BEGIN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"COMMIT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"integer\",\"value\":\"123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"text\",\"value\":\"session-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"null\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"close\"") != null);
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
