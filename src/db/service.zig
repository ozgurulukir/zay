//! External Database Service REST Client.
//!
//! Provides an HTTP client for interacting with an external database server or service
//! (such as `tools/db_server/` or a remote PostgreSQL / SQLite HTTP gateway).
//!
//! Supports health status probes, DDL/DML statement execution, parameterized
//! SELECT queries with column typing, atomic batch transactions, and schema reflection.

const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const remote_http = @import("http_transport.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.db_service);

pub const Error = error{
    HttpError,
    Unauthorized,
    InvalidResponse,
    ServerTimeout,
    ConnectionRefused,
    QueryFailed,
    OutOfMemory,
    UriMissingHost,
    UnsupportedScheme,
    InvalidEndpoint,
    ResponseTooLarge,
    ConstraintFailed,
    SqlSyntaxError,
    InvalidParameter,
};

/// Shared maximum database response body accepted from a remote backend
/// (#159). An unexpectedly large query/error response fails with
/// `error.ResponseTooLarge` instead of accumulating unbounded memory.
pub const response_max_bytes: usize = remote_http.response_max_bytes_default;

pub const HealthStatus = struct {
    status: []const u8,
    backend: []const u8,
    version: []const u8,
    auth_required: bool = false,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *HealthStatus) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ExecResult = struct {
    success: bool,
    changes: i32 = 0,
    last_insert_rowid: ?i64 = null,
};

pub const QueryResult = struct {
    arena: std.heap.ArenaAllocator,
    columns: [][]const u8,
    types: []db.ColumnType,
    rows: [][]db.Value,
    count: usize,

    pub fn deinit(self: *QueryResult) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const QueryResult, row_idx: usize, col_idx: usize) ?db.Value {
        if (row_idx >= self.rows.len) return null;
        if (col_idx >= self.columns.len) return null;
        return self.rows[row_idx][col_idx];
    }

    pub fn getInt(self: *const QueryResult, row_idx: usize, col_idx: usize) ?i64 {
        const v = self.get(row_idx, col_idx) orelse return null;
        return switch (v) {
            .int => |val| val,
            else => null,
        };
    }

    pub fn getFloat(self: *const QueryResult, row_idx: usize, col_idx: usize) ?f64 {
        const v = self.get(row_idx, col_idx) orelse return null;
        return switch (v) {
            .float => |val| val,
            .int => |val| @floatFromInt(val),
            else => null,
        };
    }

    pub fn getText(self: *const QueryResult, row_idx: usize, col_idx: usize) ?[]const u8 {
        const v = self.get(row_idx, col_idx) orelse return null;
        return switch (v) {
            .text => |val| val,
            else => null,
        };
    }

    pub fn getBlob(self: *const QueryResult, row_idx: usize, col_idx: usize) ?[]const u8 {
        const v = self.get(row_idx, col_idx) orelse return null;
        return switch (v) {
            .blob => |val| val,
            .text => |val| val,
            else => null,
        };
    }
};

pub const BatchStatement = struct {
    sql: []const u8,
    params: []const db.Value = &.{},
};

pub const BatchResult = struct {
    success: bool,
    results_count: usize,
};

pub const ColumnSchema = struct {
    name: []const u8,
    type_name: []const u8,
    nullable: bool = true,
    primary_key: bool = false,
};

pub const SchemaResult = struct {
    arena: std.heap.ArenaAllocator,
    tables: []TableSchema,

    pub const TableSchema = struct {
        name: []const u8,
        columns: []ColumnSchema,
    };

    pub fn deinit(self: *SchemaResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    auth_token: ?[]const u8 = null,
    timeout_seconds: u32 = remote_http.timeout_seconds_default,
    response_max_bytes: usize = response_max_bytes,

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8, auth_token: ?[]const u8) Client {
        assert(endpoint.len > 0);
        return .{
            .allocator = allocator,
            .endpoint = endpoint,
            .auth_token = auth_token,
        };
    }

    fn requestUrl(self: *const Client, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const trimmed = std.mem.trimEnd(u8, self.endpoint, "/");
        try validateEndpoint(trimmed);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, path });
    }

    pub fn health(self: *const Client, io: std.Io) !HealthStatus {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        const url = try self.requestUrl(aa, "/health");
        const response_bytes = try self.fetch(aa, io, .GET, url, null);

        const parsed = std.json.parseFromSlice(std.json.Value, aa, response_bytes, .{}) catch return error.InvalidResponse;
        if (parsed.value != .object) return error.InvalidResponse;

        const status_val = parsed.value.object.get("status") orelse return error.InvalidResponse;
        const backend_val = parsed.value.object.get("backend") orelse return error.InvalidResponse;
        const version_val = parsed.value.object.get("version");
        const auth_val = parsed.value.object.get("auth_required");

        const status_str = if (status_val == .string) status_val.string else "unknown";
        const backend_str = if (backend_val == .string) backend_val.string else "unknown";
        const version_str = if (version_val != null and version_val.? == .string) version_val.?.string else "0.1.0";
        const auth_req = if (auth_val != null and auth_val.? == .bool) auth_val.?.bool else false;

        return HealthStatus{
            .status = try aa.dupe(u8, status_str),
            .backend = try aa.dupe(u8, backend_str),
            .version = try aa.dupe(u8, version_str),
            .auth_required = auth_req,
            .arena = arena,
        };
    }

    pub fn exec(self: *const Client, io: std.Io, sql: []const u8, params: []const db.Value) !ExecResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const url = try self.requestUrl(aa, "/v1/exec");
        const payload = try serializeSqlPayload(aa, sql, params);
        const response_bytes = try self.fetch(aa, io, .POST, url, payload);

        const parsed = std.json.parseFromSlice(std.json.Value, aa, response_bytes, .{}) catch return error.InvalidResponse;
        if (parsed.value != .object) return error.InvalidResponse;

        const success_val = parsed.value.object.get("success") orelse return error.InvalidResponse;
        const changes_val = parsed.value.object.get("changes");
        const last_id_val = parsed.value.object.get("last_insert_rowid");

        return ExecResult{
            .success = (success_val == .bool and success_val.bool),
            .changes = try parseExecChanges(changes_val),
            .last_insert_rowid = if (last_id_val != null and last_id_val.? == .integer) last_id_val.?.integer else null,
        };
    }

    pub fn query(self: *const Client, io: std.Io, sql: []const u8, params: []const db.Value) !QueryResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        const url = try self.requestUrl(aa, "/v1/query");
        const payload = try serializeSqlPayload(aa, sql, params);
        const response_bytes = try self.fetch(aa, io, .POST, url, payload);

        const parsed = std.json.parseFromSlice(std.json.Value, aa, response_bytes, .{}) catch return error.InvalidResponse;
        if (parsed.value != .object) return error.InvalidResponse;

        const success_val = parsed.value.object.get("success") orelse return error.InvalidResponse;
        if (success_val != .bool or !success_val.bool) return error.QueryFailed;

        const cols_val = parsed.value.object.get("columns") orelse return error.InvalidResponse;
        const types_val = parsed.value.object.get("types") orelse return error.InvalidResponse;
        const rows_val = parsed.value.object.get("rows") orelse return error.InvalidResponse;

        if (cols_val != .array or types_val != .array or rows_val != .array) return error.InvalidResponse;

        var columns = try aa.alloc([]const u8, cols_val.array.items.len);
        for (cols_val.array.items, 0..) |item, i| {
            columns[i] = if (item == .string) try aa.dupe(u8, item.string) else "";
        }

        var types = try aa.alloc(db.ColumnType, types_val.array.items.len);
        for (types_val.array.items, 0..) |item, i| {
            types[i] = if (item == .string) db.parseTypeString(item.string) else .text;
        }

        var rows = try aa.alloc([]db.Value, rows_val.array.items.len);
        for (rows_val.array.items, 0..) |row_item, r| {
            if (row_item != .array) return error.InvalidResponse;
            var row_cells = try aa.alloc(db.Value, row_item.array.items.len);
            for (row_item.array.items, 0..) |cell, c| {
                row_cells[c] = switch (cell) {
                    .null => .null,
                    .bool => |b| .{ .int = if (b) 1 else 0 },
                    .integer => |iv| .{ .int = iv },
                    .float => |fv| .{ .float = fv },
                    .string => |sv| .{ .text = try aa.dupe(u8, sv) },
                    else => .null,
                };
            }
            rows[r] = row_cells;
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
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const url = try self.requestUrl(aa, "/v1/batch");
        var out: std.Io.Writer.Allocating = .init(aa);
        defer out.deinit();
        try out.writer.writeAll("{\"statements\":[");
        for (statements, 0..) |stmt, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"sql\":");
            try std.json.Stringify.value(stmt.sql, .{}, &out.writer);
            try out.writer.writeAll(",\"params\":");
            try serializeParams(&out.writer, stmt.params);
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}");

        const response_bytes = try self.fetch(aa, io, .POST, url, out.written());
        const parsed = std.json.parseFromSlice(std.json.Value, aa, response_bytes, .{}) catch return error.InvalidResponse;
        if (parsed.value != .object) return error.InvalidResponse;

        const success_val = parsed.value.object.get("success") orelse return error.InvalidResponse;
        const res_val = parsed.value.object.get("results");
        const count = if (res_val != null and res_val.? == .array) res_val.?.array.items.len else 0;

        return BatchResult{
            .success = (success_val == .bool and success_val.bool),
            .results_count = count,
        };
    }

    pub fn schema(self: *const Client, io: std.Io, table: ?[]const u8) !SchemaResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        const url = try self.requestUrl(aa, "/v1/schema");
        var payload: []const u8 = "{}";
        if (table) |t| {
            var out: std.Io.Writer.Allocating = .init(aa);
            defer out.deinit();
            try out.writer.writeAll("{\"table\":");
            try std.json.Stringify.value(t, .{}, &out.writer);
            try out.writer.writeByte('}');
            payload = try out.toOwnedSlice();
        }

        const response_bytes = try self.fetch(aa, io, .POST, url, payload);
        const parsed = std.json.parseFromSlice(std.json.Value, aa, response_bytes, .{}) catch return error.InvalidResponse;
        if (parsed.value != .object) return error.InvalidResponse;

        const tables_obj = parsed.value.object.get("tables") orelse return error.InvalidResponse;
        if (tables_obj != .object) return error.InvalidResponse;

        var table_list: std.ArrayList(SchemaResult.TableSchema) = .empty;
        errdefer table_list.deinit(aa);

        var it = tables_obj.object.iterator();
        while (it.next()) |entry| {
            const table_name = entry.key_ptr.*;
            if (entry.value_ptr.* != .array) continue;

            var cols: std.ArrayList(ColumnSchema) = .empty;
            errdefer cols.deinit(aa);

            for (entry.value_ptr.*.array.items) |col_val| {
                if (col_val != .object) continue;
                const name_val = col_val.object.get("name") orelse continue;
                const type_val = col_val.object.get("type");
                const notnull_val = col_val.object.get("notnull");
                const nullable_val = col_val.object.get("nullable");
                const pk_val = col_val.object.get("pk");

                const c_name = if (name_val == .string) name_val.string else continue;
                const c_type = if (type_val != null and type_val.? == .string) type_val.?.string else "text";
                const is_null = if (notnull_val != null and notnull_val.? == .bool)
                    !notnull_val.?.bool
                else if (nullable_val != null and nullable_val.? == .bool)
                    nullable_val.?.bool
                else
                    true;
                const is_pk = if (pk_val != null and pk_val.? == .bool) pk_val.?.bool else false;

                try cols.append(aa, .{
                    .name = try aa.dupe(u8, c_name),
                    .type_name = try aa.dupe(u8, c_type),
                    .nullable = is_null,
                    .primary_key = is_pk,
                });
            }

            try table_list.append(aa, .{
                .name = try aa.dupe(u8, table_name),
                .columns = try cols.toOwnedSlice(aa),
            });
        }

        return SchemaResult{
            .arena = arena,
            .tables = try table_list.toOwnedSlice(aa),
        };
    }

    fn fetch(
        self: *const Client,
        allocator: std.mem.Allocator,
        io: std.Io,
        method: std.http.Method,
        url: []const u8,
        payload: ?[]const u8,
    ) ![]const u8 {
        const options: remote_http.Options = .{
            .method = method,
            .url = url,
            .payload = payload,
            .auth_token = self.auth_token,
            .timeout_seconds = self.timeout_seconds,
            .response_max_bytes = self.response_max_bytes,
        };
        const response = try remote_http.fetch(allocator, io, &options);
        errdefer allocator.free(response.body);

        if (response.status == 401 or response.status == 403) return error.Unauthorized;
        if (!http.isSuccess(response.status)) return error.HttpError;

        return response.body;
    }
};

/// Validate the service endpoint BEFORE any network activity (#445). Every
/// request carries the auth token as a bearer header, so an unparseable
/// endpoint or embedded credentials fail with InvalidEndpoint, and plain
/// http is only accepted for loopback endpoints (the same gate
/// `turso.pipelineUrl` applies; the loopback exception keeps the common
/// `http://localhost:8766` companion-service setup working).
fn validateEndpoint(endpoint: []const u8) !void {
    const uri = std.Uri.parse(endpoint) catch return error.InvalidEndpoint;
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
        if (!remote_http.isLoopbackHost(host)) return error.UnsupportedScheme;
    } else {
        return error.UnsupportedScheme;
    }
}

/// The `changes` field is remote-controlled: a missing field stays lenient
/// (reported as 0), but an integer outside i32 would have panicked the old
/// `@intCast` (#445) — out-of-range values fail with InvalidResponse instead.
fn parseExecChanges(value: ?std.json.Value) !i32 {
    const v = value orelse return 0;
    if (v != .integer) return 0;
    return std.math.cast(i32, v.integer) orelse error.InvalidResponse;
}

pub fn serializeParams(writer: anytype, params: []const db.Value) !void {
    try writer.writeByte('[');
    for (params, 0..) |p, i| {
        if (i > 0) try writer.writeByte(',');
        switch (p) {
            .null => try writer.writeAll("null"),
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| {
                // NaN/Infinity are not representable in JSON — reject them
                // before they can produce an invalid payload the provider
                // would refuse with a confusing error (#162, #445).
                if (!std.math.isFinite(v)) return error.InvalidParameter;
                try writer.print("{d}", .{v});
            },
            .text => |v| try std.json.Stringify.value(v, .{}, writer),
            .blob => |v| try std.json.Stringify.value(v, .{}, writer),
        }
    }
    try writer.writeByte(']');
}

pub fn serializeSqlPayload(allocator: std.mem.Allocator, sql: []const u8, params: []const db.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"sql\":");
    try std.json.Stringify.value(sql, .{}, &out.writer);
    try out.writer.writeAll(",\"params\":");
    try serializeParams(&out.writer, params);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

test "serializeSqlPayload formats valid JSON with mixed parameters" {
    const gpa = std.testing.allocator;
    const params = [_]db.Value{
        .{ .int = 42 },
        .{ .text = "hello world" },
        .{ .float = 3.14 },
        .null,
    };
    const json = try serializeSqlPayload(gpa, "INSERT INTO test VALUES (?, ?, ?, ?)", &params);
    defer gpa.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"sql\":\"INSERT INTO test VALUES (?, ?, ?, ?)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"params\":[42,\"hello world\",3.14,null]") != null);
}

// #445: the service transport attaches a bearer token, so plain http is only
// accepted for loopback endpoints (matching turso.pipelineUrl's gate). The
// loopback exception keeps the common `http://localhost:8766` companion
// service working (config round-trips that spelling).
test "validateEndpoint gates plain http on loopback endpoints" {
    // Loopback plain http stays accepted (local companion service).
    try validateEndpoint("http://localhost:8766");
    try validateEndpoint("http://127.0.0.1:8766");
    // https is always accepted.
    try validateEndpoint("https://db.example.com");
    try validateEndpoint("https://db.example.com/");

    // Non-loopback plain http is rejected before any network activity.
    try std.testing.expectError(error.UnsupportedScheme, validateEndpoint("http://db.example.com"));
    try std.testing.expectError(error.UnsupportedScheme, validateEndpoint("http://127.evil.com:8766"));
    // Other schemes are rejected too.
    try std.testing.expectError(error.UnsupportedScheme, validateEndpoint("ftp://db.example.com"));
    // Embedded credentials are almost certainly a mis-pasted URL.
    try std.testing.expectError(error.InvalidEndpoint, validateEndpoint("https://user:pass@db.example.com"));
    // Unparseable / hostless endpoints are rejected.
    try std.testing.expectError(error.InvalidEndpoint, validateEndpoint("not a url"));
}

// #445: `changes` is remote-controlled; a missing field stays lenient (0) but
// an integer outside i32 must fail instead of panicking the old @intCast.
test "parseExecChanges bounds remote-controlled integers" {
    try std.testing.expectEqual(@as(i32, 0), try parseExecChanges(null));
    try std.testing.expectEqual(@as(i32, 0), try parseExecChanges(.{ .bool = true }));
    try std.testing.expectEqual(@as(i32, 5), try parseExecChanges(.{ .integer = 5 }));
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), try parseExecChanges(.{ .integer = std.math.maxInt(i32) }));
    try std.testing.expectError(error.InvalidResponse, parseExecChanges(.{ .integer = 1 << 40 }));
    try std.testing.expectError(error.InvalidResponse, parseExecChanges(.{ .integer = -(1 << 40) }));
}

// #445: NaN and infinities are not representable in JSON; they must be
// rejected at serialization time with a dedicated invalid-parameter error.
test "serializeParams rejects non-finite floats" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try std.testing.expectError(
        error.InvalidParameter,
        serializeParams(&out.writer, &.{.{ .float = std.math.nan(f64) }}),
    );
    try std.testing.expectError(
        error.InvalidParameter,
        serializeParams(&out.writer, &.{.{ .float = std.math.inf(f64) }}),
    );
    // A finite float still serializes.
    try serializeParams(&out.writer, &.{.{ .float = 1.5 }});
}

test "QueryResult accessors retrieve typed values correctly" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    const aa = arena.allocator();

    var cols = try aa.alloc([]const u8, 3);
    cols[0] = "id";
    cols[1] = "name";
    cols[2] = "score";

    var types = try aa.alloc(db.ColumnType, 3);
    types[0] = .int;
    types[1] = .text;
    types[2] = .float;

    var rows = try aa.alloc([]db.Value, 1);
    var cells = try aa.alloc(db.Value, 3);
    cells[0] = .{ .int = 100 };
    cells[1] = .{ .text = "sample" };
    cells[2] = .{ .float = 99.5 };
    rows[0] = cells;

    var res = QueryResult{
        .arena = arena,
        .columns = cols,
        .types = types,
        .rows = rows,
        .count = 1,
    };
    defer res.deinit();

    try std.testing.expectEqual(@as(i64, 100), res.getInt(0, 0).?);
    try std.testing.expectEqualStrings("sample", res.getText(0, 1).?);
    try std.testing.expectEqual(@as(f64, 99.5), res.getFloat(0, 2).?);
    try std.testing.expect(res.getInt(0, 1) == null);
    try std.testing.expect(res.getInt(1, 0) == null);
}
