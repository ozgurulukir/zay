//! Project-scoped storage for oversized model-facing tool results.

const std = @import("std");
const db = @import("../db.zig");
const backend_mod = @import("backend.zig");
const migration = @import("migration.zig");

const log = std.log.scoped(.tool_results);
const SqlParam = backend_mod.SqlParam;
const SessionBackend = backend_mod.SessionBackend;

pub const inline_limit_bytes: usize = 24 * 1024;
pub const chunk_bytes: usize = 64 * 1024;
pub const max_result_bytes: usize = 10 * 1024 * 1024;
pub const max_read_chars: u64 = 4096;
pub const default_read_chars: u64 = 2048;
pub const retention_ms: i64 = 7 * 24 * 60 * 60 * 1000;
pub const incomplete_retention_ms: i64 = 24 * 60 * 60 * 1000;
pub const project_result_limit: usize = 128;
pub const project_bytes_limit: i64 = 32 * 1024 * 1024;

const max_batch_statements = 16;

pub const Metadata = struct {
    byte_length: u64,
    line_count: u64,
    chunk_count: u64,
};

pub const ResultSlice = struct {
    text: []u8,
    tool_name: []u8,
    exit_code: u8,
    byte_length: u64,
    line_count: u64,
    chunk_index: u64,
    chunk_count: u64,
    chunk_characters: u64,
    offset_characters: u64,

    pub fn deinit(self: *ResultSlice, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.tool_name);
        self.* = undefined;
    }
};

const ChunkSpan = struct {
    start: usize,
    end: usize,
};

pub fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.now(.real, io).toMilliseconds();
}

pub fn store(
    gpa: std.mem.Allocator,
    io: std.Io,
    backend: *SessionBackend,
    session_id: []const u8,
    result_id: []const u8,
    tool_name: []const u8,
    exit_code: u8,
    content: []const u8,
) !Metadata {
    return storeAt(gpa, io, backend, session_id, result_id, tool_name, exit_code, content, nowMs(io));
}

fn storeAt(
    gpa: std.mem.Allocator,
    io: std.Io,
    backend: *SessionBackend,
    session_id: []const u8,
    result_id: []const u8,
    tool_name: []const u8,
    exit_code: u8,
    content: []const u8,
    created_at_ms: i64,
) !Metadata {
    if (session_id.len == 0 or result_id.len == 0 or tool_name.len == 0) return error.InvalidIdentity;
    if (content.len > max_result_bytes) return error.ResultTooLarge;
    if (content.len <= inline_limit_bytes) return error.ResultNotLarge;

    const spans = try splitChunks(gpa, content);
    defer gpa.free(spans);
    const project_key = try projectKeyForSession(gpa, io, backend, session_id);
    defer gpa.free(project_key);

    try cleanupResult(backend, io, session_id, result_id);

    const statement_count = spans.len + 2;
    const parameters = try gpa.alloc([9]SqlParam, statement_count);
    defer gpa.free(parameters);
    const statements = try gpa.alloc(db.service.BatchStatement, statement_count);
    defer gpa.free(statements);

    parameters[0] = .{
        .{ .text = result_id },
        .{ .text = session_id },
        .{ .text = project_key },
        .{ .text = tool_name },
        .{ .int = created_at_ms },
        .{ .int = @intCast(content.len) },
        .{ .int = @intCast(countLines(content)) },
        .{ .int = @intCast(spans.len) },
        .{ .int = exit_code },
    };
    statements[0] = .{
        .sql = "insert into tool_results(id, session_id, project_key, tool_name, created_at_ms, byte_length, line_count, chunk_count, exit_code, complete) values (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)",
        .params = parameters[0][0..9],
    };

    for (spans, 0..) |span, index| {
        const statement_index = index + 1;
        parameters[statement_index][0] = .{ .text = session_id };
        parameters[statement_index][1] = .{ .text = result_id };
        parameters[statement_index][2] = .{ .int = @intCast(index) };
        parameters[statement_index][3] = .{ .text = content[span.start..span.end] };
        statements[statement_index] = .{
            .sql = "insert into tool_result_chunks(session_id, result_id, ordinal, content) values (?, ?, ?, ?)",
            .params = parameters[statement_index][0..4],
        };
    }

    const complete_index = statement_count - 1;
    parameters[complete_index][0] = .{ .text = result_id };
    parameters[complete_index][1] = .{ .text = session_id };
    statements[complete_index] = .{
        .sql = "update tool_results set complete = 1 where id = ? and session_id = ?",
        .params = parameters[complete_index][0..2],
    };

    var complete = false;
    errdefer if (!complete) cleanupResult(backend, io, session_id, result_id) catch |err| {
        log.warn("incomplete result cleanup failed err={s}", .{@errorName(err)});
    };

    var batch_start: usize = 0;
    while (batch_start < statements.len) {
        const batch_end = @min(batch_start + max_batch_statements, statements.len);
        try executeStatements(backend, io, statements[batch_start..batch_end]);
        batch_start = batch_end;
    }
    complete = true;

    maintain(backend, io, created_at_ms) catch |err| {
        log.warn("post-store expiry cleanup failed err={s}", .{@errorName(err)});
    };
    pruneProject(backend, io, project_key) catch |err| {
        log.warn("project result quota cleanup failed err={s}", .{@errorName(err)});
    };

    return .{
        .byte_length = @intCast(content.len),
        .line_count = countLines(content),
        .chunk_count = @intCast(spans.len),
    };
}

pub fn read(
    gpa: std.mem.Allocator,
    io: std.Io,
    backend: *SessionBackend,
    session_id: []const u8,
    result_id: []const u8,
    chunk_index: u64,
    offset_characters: u64,
    limit_characters: u64,
    now_ms: i64,
) !ResultSlice {
    if (session_id.len == 0 or result_id.len == 0) return error.ResultNotFound;
    if (limit_characters == 0 or limit_characters > max_read_chars) return error.InvalidReadLimit;
    if (offset_characters >= std.math.maxInt(i64) or chunk_index > std.math.maxInt(i64)) return error.InvalidReadRange;

    const sql =
        "select substr(c.content, ?, ?), length(c.content), r.byte_length, r.line_count, r.chunk_count, r.tool_name, r.exit_code " ++
        "from tool_results r join tool_result_chunks c on c.session_id = r.session_id and c.result_id = r.id " ++
        "where r.id = ? and r.session_id = ? " ++
        "and r.project_key = (select coalesce(project_key, id) from sessions where id = ?) " ++
        "and r.complete = 1 and r.created_at_ms >= ? and c.ordinal = ?";
    const params = [_]SqlParam{
        .{ .int = @intCast(offset_characters + 1) },
        .{ .int = @intCast(limit_characters) },
        .{ .text = result_id },
        .{ .text = session_id },
        .{ .text = session_id },
        .{ .int = now_ms - retention_ms },
        .{ .int = @intCast(chunk_index) },
    };
    var result = try backend.query(io, sql, &params);
    defer result.deinit();
    if (result.rows.len == 0) return error.ResultNotFound;

    const row = result.rows[0];
    const text = try duplicateText(gpa, row[0]);
    errdefer gpa.free(text);
    const tool_name = try duplicateText(gpa, row[5]);
    errdefer gpa.free(tool_name);

    return .{
        .text = text,
        .tool_name = tool_name,
        .exit_code = @intCast(try integer(row[6])),
        .byte_length = @intCast(try integer(row[2])),
        .line_count = @intCast(try integer(row[3])),
        .chunk_index = chunk_index,
        .chunk_count = @intCast(try integer(row[4])),
        .chunk_characters = @intCast(try integer(row[1])),
        .offset_characters = offset_characters,
    };
}

pub fn maintain(backend: *SessionBackend, io: std.Io, now_ms: i64) !void {
    const expired_before = now_ms - retention_ms;
    const incomplete_before = now_ms - incomplete_retention_ms;
    const chunk_params = [_]SqlParam{
        .{ .int = expired_before },
        .{ .int = incomplete_before },
    };
    const result_params = chunk_params;
    const statements = [_]db.service.BatchStatement{
        .{
            .sql = "delete from tool_result_chunks where exists (select 1 from tool_results r where r.session_id = tool_result_chunks.session_id and r.id = tool_result_chunks.result_id and (r.created_at_ms < ? or (r.complete = 0 and r.created_at_ms < ?)))",
            .params = &chunk_params,
        },
        .{
            .sql = "delete from tool_results where created_at_ms < ? or (complete = 0 and created_at_ms < ?)",
            .params = &result_params,
        },
    };
    try executeStatements(backend, io, &statements);
}

fn projectKeyForSession(gpa: std.mem.Allocator, io: std.Io, backend: *SessionBackend, session_id: []const u8) ![]u8 {
    var result = try backend.query(io, "select coalesce(project_key, id) from sessions where id = ?", &.{.{ .text = session_id }});
    defer result.deinit();
    if (result.rows.len == 0) return error.MissingSession;
    return duplicateText(gpa, result.rows[0][0]);
}

fn cleanupResult(backend: *SessionBackend, io: std.Io, session_id: []const u8, result_id: []const u8) !void {
    const chunk_params = [_]SqlParam{ .{ .text = session_id }, .{ .text = result_id } };
    const result_params = chunk_params;
    const statements = [_]db.service.BatchStatement{
        .{ .sql = "delete from tool_result_chunks where session_id = ? and result_id = ?", .params = &chunk_params },
        .{ .sql = "delete from tool_results where session_id = ? and id = ?", .params = &result_params },
    };
    try executeStatements(backend, io, &statements);
}

fn executeStatements(backend: *SessionBackend, io: std.Io, statements: []const db.service.BatchStatement) !void {
    if (backend.kind != .local_sqlite) return backend.execBatch(io, statements);
    for (statements) |statement| try backend.exec(io, statement.sql, statement.params);
}

const QuotaRow = struct {
    session_id: []u8,
    id: []u8,
    created_at_ms: i64,
    byte_length: i64,

    fn deinit(self: *QuotaRow, gpa: std.mem.Allocator) void {
        gpa.free(self.session_id);
        gpa.free(self.id);
        self.* = undefined;
    }
};

fn appendQuotaRow(gpa: std.mem.Allocator, rows: *std.ArrayList(QuotaRow), values: []const db.Value) !void {
    const created_at_ms = try integer(values[2]);
    const byte_length = try integer(values[3]);
    const session_id = try duplicateText(gpa, values[0]);
    var session_id_transferred = false;
    defer if (!session_id_transferred) gpa.free(session_id);
    const id = try duplicateText(gpa, values[1]);
    var id_transferred = false;
    defer if (!id_transferred) gpa.free(id);

    try rows.append(gpa, .{
        .session_id = session_id,
        .id = id,
        .created_at_ms = created_at_ms,
        .byte_length = byte_length,
    });
    session_id_transferred = true;
    id_transferred = true;
}

fn pruneProject(backend: *SessionBackend, io: std.Io, project_key: []const u8) !void {
    const sql = "select session_id, id, created_at_ms, byte_length from tool_results where project_key = ? and complete = 1 order by created_at_ms desc, id desc, session_id desc limit ?";
    var result = try backend.query(io, sql, &.{ .{ .text = project_key }, .{ .int = @intCast(project_result_limit + 1) } });
    defer result.deinit();
    if (result.rows.len <= project_result_limit) {
        var total_bytes: i64 = 0;
        for (result.rows) |row| total_bytes += try integer(row[2]);
        if (total_bytes <= project_bytes_limit) return;
    }

    var rows: std.ArrayList(QuotaRow) = .empty;
    defer {
        for (rows.items) |*row| row.deinit(backend.gpa);
        rows.deinit(backend.gpa);
    }
    for (result.rows) |row| {
        try appendQuotaRow(backend.gpa, &rows, row);
    }

    var retained_count: usize = 0;
    var retained_bytes: i64 = 0;
    var cutoff: ?QuotaRow = null;
    for (rows.items) |*row| {
        if (retained_count == project_result_limit or retained_bytes + row.byte_length > project_bytes_limit) break;
        retained_count += 1;
        retained_bytes += row.byte_length;
        cutoff = row.*;
    }
    const oldest_kept = cutoff orelse return;
    if (retained_count == rows.items.len and rows.items.len <= project_result_limit and retained_bytes <= project_bytes_limit) return;

    const chunk_params = [_]SqlParam{
        .{ .text = project_key },
        .{ .int = oldest_kept.created_at_ms },
        .{ .int = oldest_kept.created_at_ms },
        .{ .text = oldest_kept.id },
        .{ .text = oldest_kept.id },
        .{ .text = oldest_kept.session_id },
    };
    const result_params = chunk_params;
    const older_than_cutoff = "project_key = ? and (created_at_ms < ? or (created_at_ms = ? and (id < ? or (id = ? and session_id < ?))))";
    const older_chunk_than_cutoff = "r.project_key = ? and (r.created_at_ms < ? or (r.created_at_ms = ? and (r.id < ? or (r.id = ? and r.session_id < ?))))";
    const statements = [_]db.service.BatchStatement{
        .{
            .sql = "delete from tool_result_chunks where exists (select 1 from tool_results r where r.session_id = tool_result_chunks.session_id and r.id = tool_result_chunks.result_id and " ++ older_chunk_than_cutoff ++ ")",
            .params = &chunk_params,
        },
        .{
            .sql = "delete from tool_results where " ++ older_than_cutoff,
            .params = &result_params,
        },
    };
    try executeStatements(backend, io, &statements);
}

fn splitChunks(gpa: std.mem.Allocator, content: []const u8) ![]ChunkSpan {
    var spans: std.ArrayList(ChunkSpan) = .empty;
    errdefer spans.deinit(gpa);

    var start: usize = 0;
    while (start < content.len) {
        const end_limit = start + @min(content.len - start, chunk_bytes);
        var end = end_limit;
        if (end < content.len) {
            while (end > start and isUtf8Continuation(content[end])) end -= 1;
            if (end == start) end = end_limit;
        }
        try spans.append(gpa, .{ .start = start, .end = end });
        start = end;
    }
    return spans.toOwnedSlice(gpa);
}

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn countLines(content: []const u8) u64 {
    if (content.len == 0) return 0;
    var count: u64 = 0;
    for (content) |byte| {
        if (byte == '\n') count += 1;
    }
    if (content[content.len - 1] != '\n') count += 1;
    return count;
}

fn duplicateText(gpa: std.mem.Allocator, value: backend_mod.Value) ![]u8 {
    return switch (value) {
        .text => |text| gpa.dupe(u8, text),
        .null => gpa.alloc(u8, 0),
        else => error.InvalidDatabaseValue,
    };
}

fn integer(value: backend_mod.Value) !i64 {
    return switch (value) {
        .int => |number| number,
        else => error.InvalidDatabaseValue,
    };
}

test "tool result chunks round trip and stay scoped to the originating session" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const connection = try db.Connection.open(":memory:", .{});
    var backend = try SessionBackend.openLocal(gpa, connection, "test-host", ":memory:");
    defer backend.deinit();
    if (backend.local) |*local| try migration.migrate(local, io);

    try backend.exec(io, "insert into sessions(id, cwd, project_key, created_at_ms, updated_at_ms) values (?, ?, ?, 1, 1)", &.{ .{ .text = "session-a" }, .{ .text = "/project/a" }, .{ .text = "project-a" } });
    try backend.exec(io, "insert into sessions(id, cwd, project_key, created_at_ms, updated_at_ms) values (?, ?, ?, 1, 1)", &.{ .{ .text = "session-b" }, .{ .text = "/project/b" }, .{ .text = "project-b" } });

    const content = try gpa.alloc(u8, chunk_bytes + 37);
    defer gpa.free(content);
    @memset(content, 'x');
    const suffix = "tail-of-the-second-chunk-1234567890";
    @memcpy(content[chunk_bytes..][0..suffix.len], suffix);

    const metadata = try storeAt(gpa, io, &backend, "session-a", "call-1", "mcp:search", 0, content, 1000);
    try std.testing.expectEqual(@as(u64, 2), metadata.chunk_count);
    try std.testing.expectEqual(@as(u64, content.len), metadata.byte_length);

    var slice = try read(gpa, io, &backend, "session-a", "call-1", 1, 0, 64, 1000);
    defer slice.deinit(gpa);
    try std.testing.expectEqualStrings(content[chunk_bytes..], slice.text);
    try std.testing.expectEqualStrings("mcp:search", slice.tool_name);
    try std.testing.expectEqual(@as(u64, 2), slice.chunk_count);

    try std.testing.expectError(error.ResultNotFound, read(gpa, io, &backend, "session-b", "call-1", 1, 0, 64, 1000));
}

test "tool result maintenance removes expired data and its chunks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const connection = try db.Connection.open(":memory:", .{});
    var backend = try SessionBackend.openLocal(gpa, connection, "test-host", ":memory:");
    defer backend.deinit();
    if (backend.local) |*local| try migration.migrate(local, io);
    try backend.exec(io, "insert into sessions(id, cwd, project_key, created_at_ms, updated_at_ms) values (?, ?, ?, 1, 1)", &.{ .{ .text = "session-a" }, .{ .text = "/project/a" }, .{ .text = "project-a" } });

    const content = try gpa.alloc(u8, inline_limit_bytes + 1);
    defer gpa.free(content);
    @memset(content, 'x');
    _ = try storeAt(gpa, io, &backend, "session-a", "call-old", "mcp:search", 0, content, 1000);

    try maintain(&backend, io, 1000 + retention_ms + 1);
    try std.testing.expectError(error.ResultNotFound, read(gpa, io, &backend, "session-a", "call-old", 0, 0, 8, 1000 + retention_ms + 1));

    var chunks = try backend.query(io, "select count(*) from tool_result_chunks", &.{});
    defer chunks.deinit();
    try std.testing.expectEqual(@as(i64, 0), try integer(chunks.rows[0][0]));
}

test "project pruning breaks ties by session identity" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const connection = try db.Connection.open(":memory:", .{});
    var backend = try SessionBackend.openLocal(gpa, connection, "test-host", ":memory:");
    defer backend.deinit();
    if (backend.local) |*local| try migration.migrate(local, io);

    const content = try gpa.alloc(u8, inline_limit_bytes + 1);
    defer gpa.free(content);
    @memset(content, 'x');

    for (0..project_result_limit + 1) |index| {
        var session_id_buffer: [32]u8 = undefined;
        const session_id = try std.fmt.bufPrint(&session_id_buffer, "session-{d}", .{index});
        try backend.exec(io, "insert into sessions(id, cwd, project_key, created_at_ms, updated_at_ms) values (?, ?, ?, 1, 1)", &.{
            .{ .text = session_id },
            .{ .text = "/project/a" },
            .{ .text = "project-a" },
        });
        _ = try storeAt(gpa, io, &backend, session_id, "same-result-id", "bash", 0, content, 1234);
    }

    var results = try backend.query(io, "select count(*) from tool_results where project_key = ?", &.{.{ .text = "project-a" }});
    defer results.deinit();
    try std.testing.expectEqual(@as(i64, @intCast(project_result_limit)), try integer(results.rows[0][0]));

    var chunks = try backend.query(io, "select count(*) from tool_result_chunks", &.{});
    defer chunks.deinit();
    try std.testing.expectEqual(@as(i64, @intCast(project_result_limit)), try integer(chunks.rows[0][0]));
}
