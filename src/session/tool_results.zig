//! Project-scoped storage for oversized model-facing tool results.

const std = @import("std");
const db = @import("../db.zig");
const backend_mod = @import("backend.zig");
const migration = @import("migration.zig");
const output_policy = @import("../tools/output_policy.zig");

const log = std.log.scoped(.tool_results);
const SqlParam = backend_mod.SqlParam;
const SessionBackend = backend_mod.SessionBackend;

pub const inline_limit_bytes: usize = @intCast(output_policy.default_tool_output_cap_bytes);
pub const chunk_bytes: usize = 64 * 1024;
pub const max_result_bytes: usize = 10 * 1024 * 1024;
pub const max_read_chars: u64 = 4096;
pub const default_read_chars: u64 = 2048;
pub const default_search_matches: u64 = 5;
pub const max_search_matches: u64 = 8;
pub const max_search_query_bytes: usize = 1024;
pub const retention_ms: i64 = 7 * 24 * 60 * 60 * 1000;
pub const incomplete_retention_ms: i64 = 24 * 60 * 60 * 1000;
pub const project_result_limit: usize = 128;
pub const project_bytes_limit: i64 = 32 * 1024 * 1024;

const max_batch_statements = 16;
const search_chunk_batch_size: u64 = 24;
const max_result_chunks: usize = (max_result_bytes + chunk_bytes - 1) / chunk_bytes;

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

pub const SearchMatch = struct {
    chunk_index: u64,
    offset_characters: u64,
};

pub const SearchResult = struct {
    tool_name: []u8,
    exit_code: u8,
    byte_length: u64,
    match_offset: u64,
    matches: []SearchMatch,
    has_more: bool,

    pub fn deinit(self: *SearchResult, gpa: std.mem.Allocator) void {
        gpa.free(self.tool_name);
        gpa.free(self.matches);
        self.* = undefined;
    }
};

const ChunkSpan = struct {
    start: usize,
    end: usize,
};

const ResultChunkSpan = struct {
    chunk_index: u64,
    start_byte: usize,
    end_byte: usize,
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
    return storeWithLimit(gpa, io, backend, session_id, result_id, tool_name, exit_code, content, inline_limit_bytes);
}

pub fn storeWithLimit(
    gpa: std.mem.Allocator,
    io: std.Io,
    backend: *SessionBackend,
    session_id: []const u8,
    result_id: []const u8,
    tool_name: []const u8,
    exit_code: u8,
    content: []const u8,
    inline_limit: usize,
) !Metadata {
    return storeAtWithLimit(gpa, io, backend, session_id, result_id, tool_name, exit_code, content, nowMs(io), inline_limit);
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
    return storeAtWithLimit(gpa, io, backend, session_id, result_id, tool_name, exit_code, content, created_at_ms, inline_limit_bytes);
}

fn storeAtWithLimit(
    gpa: std.mem.Allocator,
    io: std.Io,
    backend: *SessionBackend,
    session_id: []const u8,
    result_id: []const u8,
    tool_name: []const u8,
    exit_code: u8,
    content: []const u8,
    created_at_ms: i64,
    inline_limit: usize,
) !Metadata {
    if (session_id.len == 0 or result_id.len == 0 or tool_name.len == 0) return error.InvalidIdentity;
    if (content.len > max_result_bytes) return error.ResultTooLarge;
    if (content.len <= inline_limit) return error.ResultNotLarge;

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
        "select c.content, r.byte_length, r.line_count, r.chunk_count, r.tool_name, r.exit_code " ++
        "from tool_results r join tool_result_chunks c on c.session_id = r.session_id and c.result_id = r.id " ++
        "where r.id = ? and r.session_id = ? " ++
        "and r.project_key = (select coalesce(project_key, id) from sessions where id = ?) " ++
        "and r.complete = 1 and r.created_at_ms >= ? and c.ordinal = ?";
    const params = [_]SqlParam{
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
    const chunk_text = try duplicateText(gpa, row[0]);
    defer gpa.free(chunk_text);
    const chunk_characters = std.unicode.utf8CountCodepoints(chunk_text) catch return error.InvalidStoredResult;
    const start_byte = try byteOffsetForCharacterCount(chunk_text, offset_characters);
    const end_characters = @min(offset_characters + limit_characters, @as(u64, @intCast(chunk_characters)));
    const end_byte = try byteOffsetForCharacterCount(chunk_text, end_characters);
    const text = try gpa.dupe(u8, chunk_text[start_byte..end_byte]);
    errdefer gpa.free(text);
    const tool_name = try duplicateText(gpa, row[4]);
    errdefer gpa.free(tool_name);

    return .{
        .text = text,
        .tool_name = tool_name,
        .exit_code = @intCast(try integer(row[5])),
        .byte_length = @intCast(try integer(row[1])),
        .line_count = @intCast(try integer(row[2])),
        .chunk_index = chunk_index,
        .chunk_count = @intCast(try integer(row[3])),
        .chunk_characters = @intCast(chunk_characters),
        .offset_characters = offset_characters,
    };
}

fn byteOffsetForCharacterCount(text: []const u8, characters: u64) error{InvalidStoredResult}!usize {
    var byte_offset: usize = 0;
    var character_index: u64 = 0;
    while (byte_offset < text.len and character_index < characters) : (character_index += 1) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(text[byte_offset]) catch return error.InvalidStoredResult;
        byte_offset += sequence_length;
        if (byte_offset > text.len) return error.InvalidStoredResult;
    }
    return byte_offset;
}

/// Search a stored result for a case-sensitive literal and return bounded
/// character offsets. Text is scanned across chunk boundaries so a match is
/// not missed just because its bytes were split between stored chunks.
pub fn search(
    gpa: std.mem.Allocator,
    io: std.Io,
    backend: *SessionBackend,
    session_id: []const u8,
    result_id: []const u8,
    needle: []const u8,
    match_offset: u64,
    match_limit: u64,
    now_ms: i64,
) !SearchResult {
    if (session_id.len == 0 or result_id.len == 0) return error.ResultNotFound;
    if (needle.len == 0 or needle.len > max_search_query_bytes) return error.InvalidSearchQuery;
    _ = std.unicode.utf8CountCodepoints(needle) catch return error.InvalidSearchQuery;
    if (match_limit == 0 or match_limit > max_search_matches) return error.InvalidSearchLimit;

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var chunk_spans: std.ArrayList(ResultChunkSpan) = .empty;
    defer chunk_spans.deinit(gpa);
    var tool_name: ?[]u8 = null;
    errdefer if (tool_name) |name| gpa.free(name);
    var byte_length: ?u64 = null;
    var chunk_count: ?u64 = null;
    var exit_code: ?u8 = null;
    const sql =
        "select c.ordinal, c.content, r.byte_length, r.chunk_count, r.tool_name, r.exit_code " ++
        "from tool_results r join tool_result_chunks c on c.session_id = r.session_id and c.result_id = r.id " ++
        "where r.id = ? and r.session_id = ? " ++
        "and r.project_key = (select coalesce(project_key, id) from sessions where id = ?) " ++
        "and r.complete = 1 and r.created_at_ms >= ? and c.ordinal >= ? and c.ordinal < ? order by c.ordinal";
    var next_chunk: u64 = 0;
    while (chunk_count == null or next_chunk < chunk_count.?) {
        const batch_end = next_chunk + search_chunk_batch_size;
        const params = [_]SqlParam{
            .{ .text = result_id },
            .{ .text = session_id },
            .{ .text = session_id },
            .{ .int = now_ms - retention_ms },
            .{ .int = @intCast(next_chunk) },
            .{ .int = @intCast(batch_end) },
        };
        var result = try backend.query(io, sql, &params);
        defer result.deinit();
        if (result.rows.len == 0) {
            if (chunk_count == null and next_chunk == 0) return error.ResultNotFound;
            return error.InvalidStoredResult;
        }

        for (result.rows, 0..) |row, row_index| {
            const chunk_index_i64 = try integer(row[0]);
            const expected_index = next_chunk + @as(u64, @intCast(row_index));
            if (chunk_index_i64 < 0 or chunk_index_i64 != @as(i64, @intCast(expected_index))) return error.InvalidStoredResult;
            const content_part = try duplicateText(gpa, row[1]);
            defer gpa.free(content_part);
            _ = std.unicode.utf8CountCodepoints(content_part) catch return error.InvalidStoredResult;

            const result_byte_length = try integer(row[2]);
            const result_chunk_count = try integer(row[3]);
            const result_exit_code = try integer(row[5]);
            if (result_byte_length <= 0 or result_byte_length > @as(i64, @intCast(max_result_bytes)) or
                result_chunk_count <= 0 or result_chunk_count > @as(i64, @intCast(max_result_chunks)) or
                result_exit_code < 0 or result_exit_code > std.math.maxInt(u8))
            {
                return error.InvalidStoredResult;
            }
            if (byte_length) |expected| {
                if (expected != result_byte_length or chunk_count.? != result_chunk_count or exit_code.? != result_exit_code) return error.InvalidStoredResult;
            } else {
                byte_length = @intCast(result_byte_length);
                chunk_count = @intCast(result_chunk_count);
                exit_code = @intCast(result_exit_code);
                tool_name = try duplicateText(gpa, row[4]);
            }

            const start_byte = content.items.len;
            try content.appendSlice(gpa, content_part);
            try chunk_spans.append(gpa, .{
                .chunk_index = @intCast(chunk_index_i64),
                .start_byte = start_byte,
                .end_byte = content.items.len,
            });
            if (content.items.len > max_result_bytes) return error.InvalidStoredResult;
        }

        next_chunk = @as(u64, @intCast(chunk_spans.items.len));
    }

    if (byte_length.? != @as(u64, @intCast(content.items.len)) or chunk_count.? != @as(u64, @intCast(chunk_spans.items.len))) return error.InvalidStoredResult;

    var matches: std.ArrayList(SearchMatch) = .empty;
    defer matches.deinit(gpa);
    var seen_matches: u64 = 0;
    var has_more = false;
    var search_from: usize = 0;
    while (search_from < content.items.len) {
        const relative = std.mem.indexOf(u8, content.items[search_from..], needle) orelse break;
        const match_byte = search_from + relative;
        var span_index: usize = 0;
        while (span_index + 1 < chunk_spans.items.len and chunk_spans.items[span_index].end_byte <= match_byte) : (span_index += 1) {}
        const span = chunk_spans.items[span_index];
        if (match_byte < span.start_byte or match_byte >= span.end_byte) return error.InvalidStoredResult;
        const local_offset = std.unicode.utf8CountCodepoints(content.items[span.start_byte..match_byte]) catch return error.InvalidStoredResult;

        if (seen_matches < match_offset) {
            seen_matches += 1;
        } else if (matches.items.len < @as(usize, @intCast(match_limit))) {
            try matches.append(gpa, .{
                .chunk_index = span.chunk_index,
                .offset_characters = @intCast(local_offset),
            });
            seen_matches += 1;
        } else {
            has_more = true;
            break;
        }
        search_from = match_byte + needle.len;
    }

    return .{
        .tool_name = tool_name.?,
        .exit_code = exit_code.?,
        .byte_length = byte_length.?,
        .match_offset = match_offset,
        .matches = try matches.toOwnedSlice(gpa),
        .has_more = has_more,
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

test "saved tool result search crosses chunks and reports character offsets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const connection = try db.Connection.open(":memory:", .{});
    var backend = try SessionBackend.openLocal(gpa, connection, "test-host", ":memory:");
    defer backend.deinit();
    if (backend.local) |*local| try migration.migrate(local, io);
    try backend.exec(io, "insert into sessions(id, cwd, project_key, created_at_ms, updated_at_ms) values (?, ?, ?, 1, 1)", &.{ .{ .text = "session-a" }, .{ .text = "/project/a" }, .{ .text = "project-a" } });

    const content = try gpa.alloc(u8, chunk_bytes + 64);
    defer gpa.free(content);
    @memset(content, 'x');
    const prefix = "😀";
    @memcpy(content[0..prefix.len], prefix);
    content[prefix.len] = 0;
    const needle = "boundary-match";
    const nul_safe_needle = "nul-safe";
    const nul_safe_offset = 100;
    @memcpy(content[nul_safe_offset..][0..nul_safe_needle.len], nul_safe_needle);
    const first_match = chunk_bytes - 5;
    const second_match = chunk_bytes + 18;
    @memcpy(content[first_match..][0..needle.len], needle);
    @memcpy(content[second_match..][0..needle.len], needle);
    _ = try storeAt(gpa, io, &backend, "session-a", "call-search", "bash", 0, content, 1000);

    var first_page = try search(gpa, io, &backend, "session-a", "call-search", needle, 0, 1, 1000);
    defer first_page.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), first_page.matches.len);
    try std.testing.expect(first_page.has_more);
    try std.testing.expectEqual(@as(u64, 0), first_page.matches[0].chunk_index);
    try std.testing.expectEqual(@as(u64, chunk_bytes - 8), first_page.matches[0].offset_characters);

    var second_page = try search(gpa, io, &backend, "session-a", "call-search", needle, 1, 1, 1000);
    defer second_page.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), second_page.matches.len);
    try std.testing.expect(!second_page.has_more);
    try std.testing.expectEqual(@as(u64, 1), second_page.matches[0].chunk_index);
    try std.testing.expectEqual(@as(u64, 18), second_page.matches[0].offset_characters);

    var nul_search = try search(gpa, io, &backend, "session-a", "call-search", nul_safe_needle, 0, 1, 1000);
    defer nul_search.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), nul_search.matches.len);
    var nul_read = try read(gpa, io, &backend, "session-a", "call-search", nul_search.matches[0].chunk_index, nul_search.matches[0].offset_characters, nul_safe_needle.len, 1000);
    defer nul_read.deinit(gpa);
    try std.testing.expectEqualStrings(nul_safe_needle, nul_read.text);
    try std.testing.expectEqual(@as(u64, chunk_bytes - 3), nul_read.chunk_characters);

    try std.testing.expectError(error.ResultNotFound, search(gpa, io, &backend, "other-session", "call-search", needle, 0, 1, 1000));
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
