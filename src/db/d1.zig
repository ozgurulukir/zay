//! Direct Cloudflare D1 HTTP client for Zay.
//!
//! Connects to Cloudflare D1 databases using the Cloudflare v4 REST API
//! endpoint (`POST https://api.cloudflare.com/client/v4/accounts/{account_id}/d1/database/{database_id}/query`).
//!
//! Features:
//! - Direct, single-binary HTTPS client without local daemons or proxies.
//! - URL normalization: supports full REST URL or `d1://{account_id}/{database_id}`.
//! - Atomic batch execution: batches multiple statements in a single HTTP roundtrip.
//! - Schema introspection (`sqlite_master` and `PRAGMA table_info`).
//! - TigerStyle safety: bounded allocations, explicit allocators, error handling.

const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.d1);

const service = @import("service.zig");

pub const Error = service.Error;
pub const BatchStatement = service.BatchStatement;
pub const QueryResult = service.QueryResult;
pub const ExecResult = service.ExecResult;
pub const BatchResult = service.BatchResult;
pub const ColumnType = db.ColumnType;
pub const HealthStatus = service.HealthStatus;
pub const ColumnSchema = service.ColumnSchema;
pub const TableSchema = service.SchemaResult.TableSchema;
pub const SchemaResult = service.SchemaResult;

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
            .backend = try aa.dupe(u8, "cloudflare d1 (sqlite)"),
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
        const payload = try serializeD1Payload(aa, &stmts);
        const response_bytes = try self.fetch(aa, io, payload);

        const parsed = std.json.parseFromSlice(std.json.Value, aa, response_bytes, .{}) catch return error.InvalidResponse;
        if (parsed.value != .object) return error.InvalidResponse;

        if (parsed.value.object.get("success")) |s| {
            if (s == .bool and !s.bool) {
                logErrors(parsed.value);
                return error.QueryFailed;
            }
        }

        const result_arr = parsed.value.object.get("result") orelse return error.InvalidResponse;
        if (result_arr != .array or result_arr.array.items.len == 0) return error.InvalidResponse;

        const first_result = result_arr.array.items[0];
        if (first_result != .object) return error.InvalidResponse;

        if (first_result.object.get("success")) |s| {
            if (s == .bool and !s.bool) return error.QueryFailed;
        }

        var changes: i32 = 0;
        var last_id: ?i64 = null;
        if (first_result.object.get("meta")) |meta| {
            if (meta == .object) {
                if (meta.object.get("changes")) |c| {
                    if (c == .integer) changes = @intCast(c.integer);
                }
                if (meta.object.get("last_row_id")) |lri| {
                    if (lri == .integer) last_id = lri.integer;
                }
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
        const payload = try serializeD1Payload(aa, &stmts);
        const response_bytes = try self.fetch(aa, io, payload);

        const parsed = std.json.parseFromSlice(std.json.Value, aa, response_bytes, .{}) catch return error.InvalidResponse;
        if (parsed.value != .object) return error.InvalidResponse;

        if (parsed.value.object.get("success")) |s| {
            if (s == .bool and !s.bool) {
                logErrors(parsed.value);
                return error.QueryFailed;
            }
        }

        const result_arr = parsed.value.object.get("result") orelse return error.InvalidResponse;
        if (result_arr != .array or result_arr.array.items.len == 0) return error.InvalidResponse;

        const first_result = result_arr.array.items[0];
        if (first_result != .object) return error.InvalidResponse;

        const rows_val = first_result.object.get("results") orelse return error.InvalidResponse;
        if (rows_val != .array) return error.InvalidResponse;

        var columns_list: std.ArrayList([]const u8) = .empty;
        defer columns_list.deinit(self.allocator);

        var types_list: std.ArrayList(ColumnType) = .empty;
        defer types_list.deinit(self.allocator);

        var rows_list: std.ArrayList([]db.Value) = .empty;
        defer rows_list.deinit(self.allocator);

        if (rows_val.array.items.len > 0) {
            const first_row = rows_val.array.items[0];
            if (first_row == .object) {
                for (first_row.object.keys()) |key| {
                    try columns_list.append(self.allocator, try aa.dupe(u8, key));
                    try types_list.append(self.allocator, .text);
                }
            }

            for (rows_val.array.items) |row_val| {
                if (row_val != .object) continue;
                var cells = try aa.alloc(db.Value, columns_list.items.len);
                for (columns_list.items, 0..) |col_name, col_idx| {
                    if (row_val.object.get(col_name)) |cell_val| {
                        cells[col_idx] = try parseD1JsonValue(aa, cell_val);
                        if (rows_list.items.len == 0) {
                            types_list.items[col_idx] = inferColumnType(cells[col_idx]);
                        }
                    } else {
                        cells[col_idx] = .null;
                    }
                }
                try rows_list.append(self.allocator, cells);
            }
        }

        const columns_slice = try aa.alloc([]const u8, columns_list.items.len);
        @memcpy(columns_slice, columns_list.items);

        const types_slice = try aa.alloc(ColumnType, types_list.items.len);
        @memcpy(types_slice, types_list.items);

        const rows_slice = try aa.alloc([]db.Value, rows_list.items.len);
        @memcpy(rows_slice, rows_list.items);

        return QueryResult{
            .arena = arena,
            .columns = columns_slice,
            .types = types_slice,
            .rows = rows_slice,
            .count = rows_slice.len,
        };
    }

    pub fn batch(self: *const Client, io: std.Io, statements: []const BatchStatement) !BatchResult {
        if (statements.len == 0) return BatchResult{ .success = true, .results_count = 0 };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const payload = try serializeD1Payload(aa, statements);
        const response_bytes = try self.fetch(aa, io, payload);

        const parsed = std.json.parseFromSlice(std.json.Value, aa, response_bytes, .{}) catch return error.InvalidResponse;
        if (parsed.value != .object) return error.InvalidResponse;

        if (parsed.value.object.get("success")) |s| {
            if (s == .bool and !s.bool) {
                logErrors(parsed.value);
                return error.QueryFailed;
            }
        }

        const result_arr = parsed.value.object.get("result") orelse return error.InvalidResponse;
        if (result_arr != .array) return error.InvalidResponse;

        var ok_count: usize = 0;
        for (result_arr.array.items) |res_item| {
            if (res_item == .object) {
                if (res_item.object.get("success")) |item_s| {
                    if (item_s == .bool and !item_s.bool) return error.QueryFailed;
                }
                ok_count += 1;
            }
        }

        return BatchResult{
            .success = (ok_count == statements.len),
            .results_count = ok_count,
        };
    }

    pub fn schema(self: *const Client, io: std.Io, table_filter: ?[]const u8) !SchemaResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        const sql = if (table_filter) |_|
            "SELECT name FROM sqlite_master WHERE type='table' AND name = ? ORDER BY name"
        else
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' ORDER BY name";

        const params = if (table_filter) |tbl|
            &[_]db.Value{.{ .text = tbl }}
        else
            &[_]db.Value{};

        var tables_res = try self.query(io, sql, params);
        defer tables_res.deinit();

        var tables_list: std.ArrayList(TableSchema) = .empty;
        defer tables_list.deinit(self.allocator);

        for (tables_res.rows) |row| {
            if (row.len == 0) continue;
            const table_name = switch (row[0]) {
                .text => |t| t,
                else => continue,
            };

            const pragma_sql = try std.fmt.allocPrint(aa, "PRAGMA table_info(\"{s}\")", .{table_name});
            defer aa.free(pragma_sql);

            var pragma_res = self.query(io, pragma_sql, &.{}) catch continue;
            defer pragma_res.deinit();

            var cols_list: std.ArrayList(ColumnSchema) = .empty;
            defer cols_list.deinit(self.allocator);

            for (pragma_res.rows) |col_row| {
                if (col_row.len < 6) continue;
                const col_name = switch (col_row[1]) {
                    .text => |t| t,
                    else => continue,
                };
                const col_type = switch (col_row[2]) {
                    .text => |t| t,
                    else => "TEXT",
                };
                const not_null = switch (col_row[3]) {
                    .int => |v| v != 0,
                    else => false,
                };
                const pk = switch (col_row[5]) {
                    .int => |v| v != 0,
                    else => false,
                };

                try cols_list.append(self.allocator, .{
                    .name = try aa.dupe(u8, col_name),
                    .type_name = try aa.dupe(u8, col_type),
                    .nullable = !not_null,
                    .primary_key = pk,
                });
            }

            const cols_slice = try aa.alloc(ColumnSchema, cols_list.items.len);
            @memcpy(cols_slice, cols_list.items);

            try tables_list.append(self.allocator, .{
                .name = try aa.dupe(u8, table_name),
                .columns = cols_slice,
            });
        }

        const tables_slice = try aa.alloc(TableSchema, tables_list.items.len);
        @memcpy(tables_slice, tables_list.items);

        return SchemaResult{
            .tables = tables_slice,
            .arena = arena,
        };
    }

    fn fetch(
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

        const url = try normalizeD1Url(allocator, self.endpoint);
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
            log.warn("d1 HTTP {d} error response: {s}", .{ code, response_body.written() });
            return error.HttpError;
        }

        return response_body.toOwnedSlice();
    }
};

fn logErrors(val: std.json.Value) void {
    if (val != .object) return;
    if (val.object.get("errors")) |errs| {
        if (errs == .array) {
            for (errs.array.items) |e| {
                if (e == .object) {
                    if (e.object.get("message")) |m| {
                        if (m == .string) log.warn("d1 api error: {s}", .{m.string});
                    }
                }
            }
        }
    }
}

fn inferColumnType(val: db.Value) ColumnType {
    return switch (val) {
        .null, .text => .text,
        .int => .int,
        .float => .float,
        .blob => .blob,
    };
}

fn parseD1JsonValue(allocator: std.mem.Allocator, val: std.json.Value) !db.Value {
    return switch (val) {
        .null => .null,
        .bool => |b| .{ .int = if (b) 1 else 0 },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string => |ns| {
            if (std.fmt.parseInt(i64, ns, 10)) |i| {
                return .{ .int = i };
            } else |_| {
                if (std.fmt.parseFloat(f64, ns)) |f| {
                    return .{ .float = f };
                } else |_| {
                    return .{ .text = try allocator.dupe(u8, ns) };
                }
            }
        },
        .string => |s| .{ .text = try allocator.dupe(u8, s) },
        .array, .object => {
            var str_buf: std.Io.Writer.Allocating = .init(allocator);
            defer str_buf.deinit();
            try std.json.Stringify.value(val, .{}, &str_buf.writer);
            return .{ .text = try str_buf.toOwnedSlice() };
        },
    };
}

pub fn serializeD1Value(writer: anytype, allocator: std.mem.Allocator, val: db.Value) !void {
    switch (val) {
        .null => try writer.writeAll("null"),
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .text => |t| try std.json.Stringify.value(t, .{}, writer),
        .blob => |b| {
            const encoded_len = std.base64.standard.Encoder.calcSize(b.len);
            var buf: [512]u8 = undefined;
            if (encoded_len <= buf.len) {
                _ = std.base64.standard.Encoder.encode(&buf, b);
                try std.json.Stringify.value(buf[0..encoded_len], .{}, writer);
            } else {
                const heap_buf = try allocator.alloc(u8, encoded_len);
                defer allocator.free(heap_buf);
                _ = std.base64.standard.Encoder.encode(heap_buf, b);
                try std.json.Stringify.value(heap_buf, .{}, writer);
            }
        },
    }
}

pub fn serializeD1Statement(writer: anytype, allocator: std.mem.Allocator, sql: []const u8, params: []const db.Value) !void {
    try writer.writeAll("{\"sql\":");
    try std.json.Stringify.value(sql, .{}, writer);
    try writer.writeAll(",\"params\":[");
    for (params, 0..) |p, i| {
        if (i > 0) try writer.writeByte(',');
        try serializeD1Value(writer, allocator, p);
    }
    try writer.writeAll("]}");
}

pub fn serializeD1Payload(allocator: std.mem.Allocator, statements: []const BatchStatement) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    if (statements.len == 1) {
        try serializeD1Statement(&out.writer, allocator, statements[0].sql, statements[0].params);
    } else {
        try out.writer.writeByte('[');
        for (statements, 0..) |stmt, i| {
            if (i > 0) try out.writer.writeByte(',');
            try serializeD1Statement(&out.writer, allocator, stmt.sql, stmt.params);
        }
        try out.writer.writeByte(']');
    }

    return out.toOwnedSlice();
}

pub fn normalizeD1Url(allocator: std.mem.Allocator, input_url: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, input_url, " \t\r\n");

    if (std.mem.startsWith(u8, trimmed, "d1://")) {
        const rest = trimmed[5..];
        var parts = std.mem.tokenizeAny(u8, rest, "/:");
        const account_id = parts.next() orelse return error.InvalidUrl;
        const database_id = parts.next() orelse return error.InvalidUrl;
        return std.fmt.allocPrint(allocator, "https://api.cloudflare.com/client/v4/accounts/{s}/d1/database/{s}/query", .{ account_id, database_id });
    }

    if (std.mem.startsWith(u8, trimmed, "https://") or std.mem.startsWith(u8, trimmed, "http://")) {
        const without_slash = std.mem.trimEnd(u8, trimmed, "/");
        if (std.mem.endsWith(u8, without_slash, "/query")) {
            return allocator.dupe(u8, without_slash);
        }
        return std.fmt.allocPrint(allocator, "{s}/query", .{without_slash});
    }

    return allocator.dupe(u8, trimmed);
}

test "normalizeD1Url normalizes d1 protocol and https endpoints" {
    const gpa = std.testing.allocator;

    const url1 = try normalizeD1Url(gpa, "d1://my-account/my-db");
    defer gpa.free(url1);
    try std.testing.expectEqualStrings("https://api.cloudflare.com/client/v4/accounts/my-account/d1/database/my-db/query", url1);

    const url2 = try normalizeD1Url(gpa, "d1://my-account:my-db");
    defer gpa.free(url2);
    try std.testing.expectEqualStrings("https://api.cloudflare.com/client/v4/accounts/my-account/d1/database/my-db/query", url2);

    const url3 = try normalizeD1Url(gpa, "https://api.cloudflare.com/client/v4/accounts/acc123/d1/database/db456");
    defer gpa.free(url3);
    try std.testing.expectEqualStrings("https://api.cloudflare.com/client/v4/accounts/acc123/d1/database/db456/query", url3);

    const url4 = try normalizeD1Url(gpa, "https://api.cloudflare.com/client/v4/accounts/acc123/d1/database/db456/query");
    defer gpa.free(url4);
    try std.testing.expectEqualStrings("https://api.cloudflare.com/client/v4/accounts/acc123/d1/database/db456/query", url4);
}

test "serializeD1Payload serializes single statement and batch array" {
    const gpa = std.testing.allocator;

    const p1 = [_]db.Value{ .{ .int = 42 }, .{ .text = "hello" }, .{ .null = {} } };
    const single_stmt = [_]BatchStatement{.{ .sql = "SELECT * FROM t WHERE a = ? AND b = ? AND c = ?", .params = &p1 }};

    const payload1 = try serializeD1Payload(gpa, &single_stmt);
    defer gpa.free(payload1);

    try std.testing.expect(std.mem.startsWith(u8, payload1, "{\"sql\":\"SELECT"));
    try std.testing.expect(std.mem.indexOf(u8, payload1, "\"params\":[42,\"hello\",null]") != null);

    const p2 = [_]db.Value{.{ .text = "world" }};
    const batch_stmts = [_]BatchStatement{
        .{ .sql = "INSERT INTO t (b) VALUES (?)", .params = &p2 },
        .{ .sql = "UPDATE t SET a = 1", .params = &.{} },
    };

    const payload2 = try serializeD1Payload(gpa, &batch_stmts);
    defer gpa.free(payload2);

    try std.testing.expect(std.mem.startsWith(u8, payload2, "[{"));
    try std.testing.expect(std.mem.endsWith(u8, payload2, "}]"));
    try std.testing.expect(std.mem.indexOf(u8, payload2, "UPDATE t SET a = 1") != null);
}

test "parseD1JsonValue correctly converts booleans, integers, strings and nulls" {
    const gpa = std.testing.allocator;

    const v_null = try parseD1JsonValue(gpa, .null);
    try std.testing.expectEqual(db.Value.null, v_null);

    const v_bool_t = try parseD1JsonValue(gpa, .{ .bool = true });
    try std.testing.expectEqual(@as(i64, 1), v_bool_t.int);

    const v_int = try parseD1JsonValue(gpa, .{ .integer = 999 });
    try std.testing.expectEqual(@as(i64, 999), v_int.int);

    const v_str = try parseD1JsonValue(gpa, .{ .string = "test-session" });
    defer gpa.free(v_str.text);
    try std.testing.expectEqualStrings("test-session", v_str.text);
}
