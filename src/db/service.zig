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
};

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
    timeout_seconds: u32 = 10,

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
            .changes = if (changes_val != null and changes_val.? == .integer) @intCast(changes_val.?.integer) else 0,
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
            types[i] = if (item == .string) parseTypeString(item.string) else .text;
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
        var payload: ?[]u8 = null;
        if (table) |t| {
            payload = try std.fmt.allocPrint(aa, "{{\"table\":\"{s}\"}}", .{t});
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
                const null_val = col_val.object.get("notnull") orelse col_val.object.get("nullable");
                const pk_val = col_val.object.get("pk");

                const c_name = if (name_val == .string) name_val.string else continue;
                const c_type = if (type_val != null and type_val.? == .string) type_val.?.string else "text";
                const is_null = if (null_val != null and null_val.? == .bool) !null_val.?.bool else true;
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
        var response_body: std.Io.Writer.Allocating = .init(allocator);
        errdefer response_body.deinit();
        var redirect_buffer: [http.redirect_buffer_bytes]u8 = undefined;

        var http_client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer http_client.deinit();

        var auth_buf: [512]u8 = undefined;
        const auth_header: ?[]const u8 = if (self.auth_token) |t| blk: {
            break :blk std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{t}) catch null;
        } else null;

        const status = http_client.fetch(.{
            .method = method,
            .location = .{ .url = url },
            .payload = payload,
            .response_writer = &response_body.writer,
            .redirect_buffer = &redirect_buffer,
            .keep_alive = true,
            .headers = .{
                .content_type = if (payload != null) .{ .override = http.content_type_json } else .default,
                .authorization = if (auth_header) |a| .{ .override = a } else .omit,
            },
        }) catch |err| switch (err) {
            error.ConnectionRefused, error.ConnectionResetByPeer => return error.ConnectionRefused,
            else => return err,
        };

        const code: u16 = @intFromEnum(status.status);
        if (code == 401 or code == 403) return error.Unauthorized;
        if (!http.isSuccess(code)) return error.HttpError;

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

pub fn serializeParams(writer: anytype, params: []const db.Value) !void {
    try writer.writeByte('[');
    for (params, 0..) |p, i| {
        if (i > 0) try writer.writeByte(',');
        switch (p) {
            .null => try writer.writeAll("null"),
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
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

test "parseTypeString maps standard types" {
    try std.testing.expectEqual(db.ColumnType.int, parseTypeString("int"));
    try std.testing.expectEqual(db.ColumnType.int, parseTypeString("INTEGER"));
    try std.testing.expectEqual(db.ColumnType.float, parseTypeString("real"));
    try std.testing.expectEqual(db.ColumnType.float, parseTypeString("double"));
    try std.testing.expectEqual(db.ColumnType.blob, parseTypeString("blob"));
    try std.testing.expectEqual(db.ColumnType.null, parseTypeString("null"));
    try std.testing.expectEqual(db.ColumnType.text, parseTypeString("VARCHAR(255)"));
    try std.testing.expectEqual(db.ColumnType.text, parseTypeString("TEXT"));
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
