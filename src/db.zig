const std = @import("std");
const c = @import("c");

const assert = std.debug.assert;

pub const Error = error{
    Misuse,
    Sqlite,
    OutOfMemory,
};

pub const OpenFlags = packed struct(c_int) {
    readonly: bool = false,
    readwrite: bool = true,
    create: bool = true,
    uri: bool = false,
    memory: bool = false,
    no_mutex: bool = false,
    full_mutex: bool = false,
    shared_cache: bool = false,
    private_cache: bool = false,
    _reserved: u23 = 0,

    pub fn bits(self: OpenFlags) c_int {
        var value: c_int = 0;
        if (self.readonly) value |= c.SQLITE_OPEN_READONLY;
        if (self.readwrite) value |= c.SQLITE_OPEN_READWRITE;
        if (self.create) value |= c.SQLITE_OPEN_CREATE;
        if (self.uri) value |= c.SQLITE_OPEN_URI;
        if (self.memory) value |= c.SQLITE_OPEN_MEMORY;
        if (self.no_mutex) value |= c.SQLITE_OPEN_NOMUTEX;
        if (self.full_mutex) value |= c.SQLITE_OPEN_FULLMUTEX;
        if (self.shared_cache) value |= c.SQLITE_OPEN_SHAREDCACHE;
        if (self.private_cache) value |= c.SQLITE_OPEN_PRIVATECACHE;
        return value;
    }
};

pub const Connection = struct {
    handle: *c.sqlite3,

    pub fn open(path: []const u8, flags: OpenFlags) Error!Connection {
        assert(path.len > 0);
        var path_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
        if (path.len >= path_buffer.len) return error.Misuse;
        @memcpy(path_buffer[0..path.len], path);
        path_buffer[path.len] = 0;

        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path_buffer[0..path.len :0].ptr, &handle, flags.bits(), null);
        if (rc != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.Sqlite;
        }
        return .{ .handle = handle orelse return error.Sqlite };
    }

    pub fn close(self: *Connection) void {
        _ = c.sqlite3_close(self.handle);
        self.* = undefined;
    }

    pub fn exec(self: *Connection, sql: []const u8) Error!void {
        assert(sql.len > 0);
        var statement = try self.prepare(sql);
        defer statement.finalize();
        while (true) {
            if (try statement.step()) |_| {} else break;
        }
    }

    pub fn prepare(self: *Connection, sql: []const u8) Error!Statement {
        assert(sql.len > 0);
        var sql_buffer: [64 * 1024:0]u8 = undefined;
        if (sql.len >= sql_buffer.len) return error.Misuse;
        @memcpy(sql_buffer[0..sql.len], sql);
        sql_buffer[sql.len] = 0;

        var handle: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v3(self.handle, sql_buffer[0..sql.len :0].ptr, @intCast(sql.len), 0, &handle, null);
        if (rc != c.SQLITE_OK) return error.Sqlite;
        return .{ .connection = self.handle, .handle = handle orelse return error.Sqlite };
    }

    pub fn lastInsertRowid(self: *const Connection) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn changes(self: *const Connection) i32 {
        return c.sqlite3_changes(self.handle);
    }

    pub fn errorMessage(self: *const Connection) [:0]const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }
};

pub const Statement = struct {
    connection: *c.sqlite3,
    handle: *c.sqlite3_stmt,

    pub fn finalize(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
        self.* = undefined;
    }

    pub fn reset(self: *Statement) Error!void {
        try self.check(c.sqlite3_reset(self.handle));
    }

    pub fn clearBindings(self: *Statement) Error!void {
        try self.check(c.sqlite3_clear_bindings(self.handle));
    }

    pub fn step(self: *Statement) Error!?Row {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return Row{ .handle = self.handle };
        if (rc == c.SQLITE_DONE) return null;
        return error.Sqlite;
    }

    pub fn bindNull(self: *Statement, index: i32) Error!void {
        assert(index > 0);
        try self.check(c.sqlite3_bind_null(self.handle, index));
    }

    pub fn bindInt(self: *Statement, index: i32, value: i64) Error!void {
        assert(index > 0);
        try self.check(c.sqlite3_bind_int64(self.handle, index, value));
    }

    pub fn bindFloat(self: *Statement, index: i32, value: f64) Error!void {
        assert(index > 0);
        try self.check(c.sqlite3_bind_double(self.handle, index, value));
    }

    pub fn bindText(self: *Statement, index: i32, value: []const u8) Error!void {
        assert(index > 0);
        try self.check(c.sqlite3_bind_text(self.handle, index, value.ptr, @intCast(value.len), sqlite_static));
    }

    pub fn bindBlob(self: *Statement, index: i32, value: []const u8) Error!void {
        assert(index > 0);
        try self.check(c.sqlite3_bind_blob(self.handle, index, value.ptr, @intCast(value.len), sqlite_static));
    }

    pub fn bindValue(self: *Statement, index: i32, value: Value) Error!void {
        assert(index > 0);
        switch (value) {
            .null => try self.bindNull(index),
            .int => |v| try self.bindInt(index, v),
            .float => |v| try self.bindFloat(index, v),
            .text => |v| try self.bindText(index, v),
            .blob => |v| try self.bindBlob(index, v),
        }
    }

    pub fn columnCount(self: *const Statement) i32 {
        return c.sqlite3_column_count(self.handle);
    }

    pub fn errorMessage(self: *const Statement) [:0]const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.connection));
    }

    fn check(self: *Statement, rc: c_int) Error!void {
        _ = self;
        if (rc == c.SQLITE_OK) return;
        return error.Sqlite;
    }
};

pub const Row = struct {
    handle: *c.sqlite3_stmt,

    pub fn columnCount(self: *const Row) i32 {
        return c.sqlite3_column_count(self.handle);
    }

    pub fn columnName(self: *const Row, index: i32) [:0]const u8 {
        assert(index >= 0);
        assert(index < self.columnCount());
        return std.mem.span(c.sqlite3_column_name(self.handle, index));
    }

    pub fn columnType(self: *const Row, index: i32) ColumnType {
        assert(index >= 0);
        assert(index < self.columnCount());
        return ColumnType.fromSqlite(c.sqlite3_column_type(self.handle, index));
    }

    pub fn int(self: *const Row, index: i32) i64 {
        assert(index >= 0);
        assert(index < self.columnCount());
        return c.sqlite3_column_int64(self.handle, index);
    }

    pub fn float(self: *const Row, index: i32) f64 {
        assert(index >= 0);
        assert(index < self.columnCount());
        return c.sqlite3_column_double(self.handle, index);
    }

    pub fn text(self: *const Row, index: i32) []const u8 {
        assert(index >= 0);
        assert(index < self.columnCount());
        const ptr = c.sqlite3_column_text(self.handle, index) orelse return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, index));
        return ptr[0..len];
    }

    pub fn blob(self: *const Row, index: i32) []const u8 {
        assert(index >= 0);
        assert(index < self.columnCount());
        const ptr = c.sqlite3_column_blob(self.handle, index) orelse return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, index));
        const bytes: [*]const u8 = @ptrCast(ptr);
        return bytes[0..len];
    }

    pub fn value(self: *const Row, index: i32) ValueRef {
        assert(index >= 0);
        assert(index < self.columnCount());
        return switch (self.columnType(index)) {
            .null => .null,
            .int => .{ .int = self.int(index) },
            .float => .{ .float = self.float(index) },
            .text => .{ .text = self.text(index) },
            .blob => .{ .blob = self.blob(index) },
        };
    }
};

pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
};

pub const ValueRef = Value;

pub const ColumnType = enum {
    int,
    float,
    text,
    blob,
    null,

    fn fromSqlite(value: c_int) ColumnType {
        return switch (value) {
            c.SQLITE_INTEGER => .int,
            c.SQLITE_FLOAT => .float,
            c.SQLITE_TEXT => .text,
            c.SQLITE_BLOB => .blob,
            c.SQLITE_NULL => .null,
            else => .null,
        };
    }
};

const sqlite_static: ?*const fn (?*anyopaque) callconv(.c) void = null;

test "open in-memory database and query row" {
    var connection = try Connection.open(":memory:", .{});
    defer connection.close();

    try connection.exec("create table test(id integer primary key, name text not null)");
    var insert = try connection.prepare("insert into test(name) values (?)");
    defer insert.finalize();
    try insert.bindText(1, "nova");
    try std.testing.expect(try insert.step() == null);
    try std.testing.expectEqual(@as(i32, 1), connection.changes());

    var query = try connection.prepare("select id, name from test");
    defer query.finalize();
    const row = (try query.step()) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 1), row.int(0));
    try std.testing.expectEqualStrings("nova", row.text(1));
    try std.testing.expect(try query.step() == null);
}
