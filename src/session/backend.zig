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
};

pub const SqlParam = db.Value;
pub const QueryResult = db.service.QueryResult;
pub const Value = db.Value;
pub const ColumnType = db.ColumnType;

pub const SessionBackend = struct {
    gpa: std.mem.Allocator,
    kind: BackendKind,
    local: ?db.Connection = null,
    remote: ?db.Service = null,
    remote_url: ?[]const u8 = null,
    remote_token: ?[]const u8 = null,
    host_id: []const u8,

    pub fn openLocal(gpa: std.mem.Allocator, conn: db.Connection, host_id: []const u8) !SessionBackend {
        return .{
            .gpa = gpa,
            .kind = .local_sqlite,
            .local = conn,
            .remote = null,
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
            .host_id = try gpa.dupe(u8, host_id),
        };
    }

    pub fn deinit(self: *SessionBackend) void {
        self.gpa.free(self.host_id);
        if (self.remote_url) |u| self.gpa.free(u);
        if (self.remote_token) |t| self.gpa.free(t);
        switch (self.kind) {
            .local_sqlite => {
                if (self.local) |*conn| conn.close();
            },
            .remote_service => {},
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
                _ = try svc.exec(io, sql, params);
            },
        }
    }

    pub fn query(self: *SessionBackend, io: std.Io, sql: []const u8, params: []const SqlParam) !QueryResult {
        switch (self.kind) {
            .local_sqlite => {
                var conn = self.local orelse return error.MissingConnection;
                var stmt = try conn.prepare(sql);
                defer stmt.finalize();
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

                var col_names_populated = false;

                while (try stmt.step()) |row| {
                    const num_cols: usize = @intCast(row.columnCount());
                    if (!col_names_populated) {
                        for (0..num_cols) |i| {
                            const name = row.columnName(@intCast(i));
                            try columns_list.append(self.gpa, try aa.dupe(u8, name));
                            try types_list.append(self.gpa, row.columnType(@intCast(i)));
                        }
                        col_names_populated = true;
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
        }
    }

    pub fn beginTransaction(self: *SessionBackend, io: std.Io) !void {
        try self.exec(io, "BEGIN", &.{});
    }

    pub fn commitTransaction(self: *SessionBackend, io: std.Io) !void {
        try self.exec(io, "COMMIT", &.{});
    }

    pub fn rollbackTransaction(self: *SessionBackend, io: std.Io) !void {
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
