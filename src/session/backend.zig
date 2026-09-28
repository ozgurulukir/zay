//! Storage backend abstraction for Zay's internal session persistence.
//!
//! Provides a drop-in storage abstraction supporting both local embedded SQLite
//! and remote database services (HTTP/REST via `db.Service`) for roaming users.

const std = @import("std");
const db = @import("../db.zig");
const session_type = @import("types.zig");

pub const BackendKind = enum {
    local_sqlite,
    remote_service,
    turso_http,
    postgres_native,

    pub const local = BackendKind.local_sqlite;
    pub const zay_service = BackendKind.remote_service;

    pub fn fromString(str: []const u8) ?BackendKind {
        if (std.mem.eql(u8, str, "local") or std.mem.eql(u8, str, "local_sqlite") or std.mem.eql(u8, str, "sqlite")) return .local_sqlite;
        if (std.mem.eql(u8, str, "zay_service") or std.mem.eql(u8, str, "remote_service") or std.mem.eql(u8, str, "service")) return .remote_service;
        if (std.mem.eql(u8, str, "turso_http") or std.mem.eql(u8, str, "turso") or std.mem.eql(u8, str, "libsql")) return .turso_http;
        if (std.mem.eql(u8, str, "postgres_native") or std.mem.eql(u8, str, "postgres") or std.mem.eql(u8, str, "postgresql")) return .postgres_native;
        return null;
    }

    pub fn asString(self: BackendKind) []const u8 {
        return switch (self) {
            .local_sqlite => "local",
            .remote_service => "zay_service",
            .turso_http => "turso_http",
            .postgres_native => "postgres_native",
        };
    }
};

pub const SqlParam = db.Value;
pub const QueryResult = db.service.QueryResult;
pub const Value = db.Value;
pub const ColumnType = db.ColumnType;

pub const SessionBackend = struct {
    gpa: std.mem.Allocator,
    kind: BackendKind,
    local: ?db.Connection = null,
    local_path: ?[]u8 = null,
    remote: ?db.Service = null,
    remote_url: ?[]const u8 = null,
    remote_token: ?[]const u8 = null,
    turso: ?db.Turso = null,
    host_id: []const u8,

    pub fn openLocal(gpa: std.mem.Allocator, conn: db.Connection, host_id: []const u8, path: []const u8) !SessionBackend {
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        return .{
            .gpa = gpa,
            .kind = .local_sqlite,
            .local = conn,
            .local_path = owned_path,
            .remote = null,
            .turso = null,
            .host_id = try gpa.dupe(u8, host_id),
        };
    }

    pub fn openRemote(gpa: std.mem.Allocator, url: []const u8, auth_token: ?[]const u8, host_id: []const u8) !SessionBackend {
        const owned_url = try gpa.dupe(u8, url);
        errdefer gpa.free(owned_url);
        const owned_token = if (auth_token) |t| try gpa.dupe(u8, t) else null;
        errdefer if (owned_token) |t| gpa.free(t);

        const client = db.Service.init(gpa, owned_url, owned_token);
        return .{
            .gpa = gpa,
            .kind = .remote_service,
            .local = null,
            .remote = client,
            .remote_url = owned_url,
            .remote_token = owned_token,
            .turso = null,
            .host_id = try gpa.dupe(u8, host_id),
        };
    }

    pub fn openTurso(gpa: std.mem.Allocator, url: []const u8, auth_token: ?[]const u8, host_id: []const u8) !SessionBackend {
        const owned_url = try gpa.dupe(u8, url);
        errdefer gpa.free(owned_url);
        const owned_token = if (auth_token) |t| try gpa.dupe(u8, t) else null;
        errdefer if (owned_token) |t| gpa.free(t);

        const client = db.Turso.init(gpa, owned_url, owned_token);
        return .{
            .gpa = gpa,
            .kind = .turso_http,
            .local = null,
            .local_path = null,
            .remote = null,
            .remote_url = owned_url,
            .remote_token = owned_token,
            .turso = client,
            .host_id = try gpa.dupe(u8, host_id),
        };
    }

    pub fn deinit(self: *SessionBackend) void {
        self.gpa.free(self.host_id);
        if (self.local_path) |path| self.gpa.free(path);
        if (self.remote_url) |u| self.gpa.free(u);
        if (self.remote_token) |t| self.gpa.free(t);
        switch (self.kind) {
            .local_sqlite => {
                if (self.local) |*conn| conn.close();
            },
            .remote_service, .turso_http, .postgres_native => {},
        }
        self.* = undefined;
    }

    pub fn exec(self: *SessionBackend, io: std.Io, sql: []const u8, params: []const SqlParam) !void {
        switch (self.kind) {
            .local_sqlite => {
                var conn = self.local orelse return error.MissingConnection;
                var stmt = try conn.prepare(sql);
                defer stmt.finalize();
                for (params, 0..) |p, idx| {
                    const col_idx: i32 = @intCast(idx + 1);
                    try stmt.bindValue(col_idx, p);
                }
                while (true) {
                    if (try stmt.step()) |_| {} else break;
                }
            },
            .remote_service => {
                const svc = self.remote orelse return error.MissingConnection;
                const result = try svc.exec(io, sql, params);
                if (!result.success) return error.QueryFailed;
            },
            .turso_http => {
                const client = self.turso orelse return error.MissingConnection;
                const result = try client.exec(io, sql, params);
                if (!result.success) return error.QueryFailed;
            },
            .postgres_native => return error.BackendNotImplemented,
        }
    }

    pub fn execBatch(self: *SessionBackend, io: std.Io, statements: []const db.service.BatchStatement) !void {
        switch (self.kind) {
            .local_sqlite => return error.UnsupportedTransaction,
            .remote_service => {
                const svc = self.remote orelse return error.MissingConnection;
                const result = try svc.batch(io, statements);
                if (!result.success or result.results_count != statements.len) return error.QueryFailed;
            },
            .turso_http => {
                const client = self.turso orelse return error.MissingConnection;
                const result = try client.batch(io, statements);
                if (!result.success or result.results_count != statements.len) return error.QueryFailed;
            },
            .postgres_native => return error.BackendNotImplemented,
        }
    }

    pub fn query(self: *SessionBackend, io: std.Io, sql: []const u8, params: []const SqlParam) !QueryResult {
        switch (self.kind) {
            .local_sqlite => {
                var conn = self.local orelse return error.MissingConnection;
                var stmt = try conn.prepare(sql);
                defer stmt.finalize();
                if (!stmt.isReadOnly()) return error.ReadOnlyQueryRequired;
                for (params, 0..) |p, idx| {
                    const col_idx: i32 = @intCast(idx + 1);
                    try stmt.bindValue(col_idx, p);
                }

                var arena = std.heap.ArenaAllocator.init(self.gpa);
                errdefer arena.deinit();
                const aa = arena.allocator();

                var rows_list: std.ArrayList([]Value) = .empty;
                defer rows_list.deinit(self.gpa);

                var columns_list: std.ArrayList([]const u8) = .empty;
                defer columns_list.deinit(self.gpa);
                var types_list: std.ArrayList(ColumnType) = .empty;
                defer types_list.deinit(self.gpa);

                const num_cols: usize = @intCast(stmt.columnCount());
                for (0..num_cols) |i| {
                    try columns_list.append(self.gpa, try aa.dupe(u8, stmt.columnName(@intCast(i))));
                    try types_list.append(self.gpa, .text);
                }

                while (try stmt.step()) |row| {
                    if (rows_list.items.len == 0) {
                        for (0..num_cols) |i| {
                            types_list.items[i] = row.columnType(@intCast(i));
                        }
                    }

                    var cells = try aa.alloc(Value, num_cols);
                    for (0..num_cols) |i| {
                        const col_i: i32 = @intCast(i);
                        cells[i] = switch (row.columnType(col_i)) {
                            .null => .null,
                            .int => .{ .int = row.int(col_i) },
                            .float => .{ .float = row.float(col_i) },
                            .text => .{ .text = try aa.dupe(u8, row.text(col_i)) },
                            .blob => .{ .blob = try aa.dupe(u8, row.blob(col_i)) },
                        };
                    }
                    try rows_list.append(self.gpa, cells);
                }

                const columns_slice = try aa.alloc([]const u8, columns_list.items.len);
                @memcpy(columns_slice, columns_list.items);
                const types_slice = try aa.alloc(ColumnType, types_list.items.len);
                @memcpy(types_slice, types_list.items);
                const rows_slice = try aa.alloc([]Value, rows_list.items.len);
                @memcpy(rows_slice, rows_list.items);

                return QueryResult{
                    .arena = arena,
                    .columns = columns_slice,
                    .types = types_slice,
                    .rows = rows_slice,
                    .count = rows_list.items.len,
                };
            },
            .remote_service => {
                const svc = self.remote orelse return error.MissingConnection;
                return try svc.query(io, sql, params);
            },
            .turso_http => {
                const client = self.turso orelse return error.MissingConnection;
                return try client.query(io, sql, params);
            },
            .postgres_native => return error.BackendNotImplemented,
        }
    }

    pub fn beginTransaction(self: *SessionBackend, io: std.Io) !void {
        if (self.kind != .local_sqlite) return error.UnsupportedTransaction;
        try self.exec(io, "BEGIN", &.{});
    }

    pub fn commitTransaction(self: *SessionBackend, io: std.Io) !void {
        if (self.kind != .local_sqlite) return error.UnsupportedTransaction;
        try self.exec(io, "COMMIT", &.{});
    }

    pub fn rollbackTransaction(self: *SessionBackend, io: std.Io) !void {
        if (self.kind != .local_sqlite) return error.UnsupportedTransaction;
        try self.exec(io, "ROLLBACK", &.{});
    }
};

/// Resolve a persistent host/machine identifier for roaming session grouping.
pub fn resolveHostId(gpa: std.mem.Allocator, env_map: ?*const std.process.Environ.Map) ![]u8 {
    if (env_map) |em| {
        if (em.get("ZAY_HOST_ID")) |h| {
            if (h.len > 0) return try gpa.dupe(u8, h);
        }
        if (em.get("COMPUTERNAME")) |c| {
            if (c.len > 0) return try gpa.dupe(u8, c);
        }
        if (em.get("HOSTNAME")) |h| {
            if (h.len > 0) return try gpa.dupe(u8, h);
        }
    }
    return try gpa.dupe(u8, "default-host");
}

test "BackendKind correctly identifies turso_http" {
    try std.testing.expectEqual(BackendKind.turso_http, BackendKind.fromString("turso_http").?);
    try std.testing.expectEqual(BackendKind.turso_http, BackendKind.fromString("turso").?);
    try std.testing.expectEqual(BackendKind.turso_http, BackendKind.fromString("libsql").?);
    try std.testing.expectEqualStrings("turso_http", BackendKind.turso_http.asString());
}

test "SessionBackend openTurso initializes and deinits cleanly without leaks" {
    const gpa = std.testing.allocator;
    var backend = try SessionBackend.openTurso(gpa, "https://my-db.turso.io", "secret-token", "test-host");
    defer backend.deinit();

    try std.testing.expectEqual(BackendKind.turso_http, backend.kind);
    try std.testing.expectEqualStrings("https://my-db.turso.io", backend.remote_url.?);
    try std.testing.expectEqualStrings("secret-token", backend.remote_token.?);
    try std.testing.expectEqualStrings("test-host", backend.host_id);
    try std.testing.expect(backend.turso != null);
}
