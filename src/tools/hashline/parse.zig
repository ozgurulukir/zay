const std = @import("std");

const assert = std.debug.assert;

/// Filler hash used for the interior anchors of a range (`A..B`). The parser
/// emits this for every anchor strictly between A and B; apply skips hash
/// validation on these.
pub const range_interior_hash: [2]u8 = .{ '*', '*' };

pub const Anchor = struct {
    line: u32,
    hash: [2]u8,
};

pub const Cursor = union(enum) {
    bof,
    eof,
    before_anchor: Anchor,
    after_anchor: Anchor,
};

pub const Insert = struct {
    cursor: Cursor,
    text: []const u8,
    source_line: u32,
};

pub const Delete = struct {
    anchor: Anchor,
    source_line: u32,
};

pub const Edit = union(enum) {
    insert: Insert,
    delete: Delete,
};

pub const Error = error{
    EmptyPatch,
    MissingPayload,
    PayloadOutsideOp,
    InvalidAnchor,
    InvalidRange,
    UnrecognizedOp,
    OutOfMemory,
};

/// Optional payload separator. The model is told to use `~`; we accept it
/// literally and don't honor an env-override (the runtime is single-flavor).
const payload_sep: u8 = '~';

/// Parse a hashline patch into a flat sequence of edits. The returned slice
/// is arena-owned; payload text references back into `patch` so the caller
/// must keep `patch` alive at least as long as the edits are used.
pub fn parse(arena: std.mem.Allocator, patch: []const u8) Error![]const Edit {
    var edits: std.ArrayList(Edit) = .empty;
    var iter = std.mem.splitScalar(u8, patch, '\n');
    var line_no: u32 = 0;

    while (iter.next()) |raw_line| {
        line_no += 1;
        const line = trimTrailingCR(raw_line);
        const control_line = std.mem.trimStart(u8, line, " \t");
        if (shouldSkipLine(control_line)) continue;
        if (control_line[0] == payload_sep) return Error.PayloadOutsideOp;

        const op_kind = classifyOp(control_line) orelse return Error.UnrecognizedOp;
        const operand = std.mem.trim(u8, control_line[1..], " \t");
        if (operand.len == 0) return Error.UnrecognizedOp;

        switch (op_kind) {
            .insert_before, .insert_after => {
                const cursor = try parseInsertTarget(operand, op_kind == .insert_after);
                try collectInsertPayload(arena, &edits, &iter, &line_no, cursor, line_no, true);
            },
            .replace => {
                const range = try parseRange(operand);
                const start_cursor = Cursor{ .before_anchor = range.start };
                try collectInsertPayload(arena, &edits, &iter, &line_no, start_cursor, line_no, false);
                try emitRangeDeletes(arena, &edits, range, line_no);
            },
            .delete => {
                const range = try parseRange(operand);
                try emitRangeDeletes(arena, &edits, range, line_no);
            },
        }
    }

    if (edits.items.len == 0) return Error.EmptyPatch;
    return edits.toOwnedSlice(arena);
}

const OpKind = enum { insert_before, insert_after, replace, delete };

fn classifyOp(line: []const u8) ?OpKind {
    if (line.len == 0) return null;
    switch (line[0]) {
        '<' => return .insert_before,
        '+' => return .insert_after,
        '=' => return .replace,
        '-' => return .delete,
        else => return null,
    }
}

fn shouldSkipLine(line: []const u8) bool {
    if (line.len == 0) return true;
    // Envelope markers and filename headers are silently consumed.
    if (std.mem.startsWith(u8, line, "*** Begin Patch")) return true;
    if (std.mem.startsWith(u8, line, "*** End Patch")) return true;
    if (line[0] == '@') return true;
    return false;
}

fn trimTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn parseInsertTarget(operand: []const u8, after: bool) Error!Cursor {
    if (std.mem.eql(u8, operand, "BOF")) return .bof;
    if (std.mem.eql(u8, operand, "EOF")) return .eof;
    const anchor = try parseAnchor(operand);
    if (after) return .{ .after_anchor = anchor };
    return .{ .before_anchor = anchor };
}

fn parseAnchor(token: []const u8) Error!Anchor {
    if (token.len < 3) return Error.InvalidAnchor;
    const hash_start = token.len - 2;
    const number_text = token[0..hash_start];
    const hash_text = token[hash_start..];
    if (!isAllDigits(number_text)) return Error.InvalidAnchor;
    if (!isAllLowerLetters(hash_text)) return Error.InvalidAnchor;
    const line = std.fmt.parseInt(u32, number_text, 10) catch return Error.InvalidAnchor;
    if (line == 0) return Error.InvalidAnchor;
    return .{ .line = line, .hash = .{ hash_text[0], hash_text[1] } };
}

fn isAllDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn isAllLowerLetters(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (c < 'a' or c > 'z') return false;
    }
    return true;
}

const Range = struct { start: Anchor, end: Anchor };

fn parseRange(operand: []const u8) Error!Range {
    const dot_dot = std.mem.indexOf(u8, operand, "..") orelse return Error.InvalidRange;
    const start_text = operand[0..dot_dot];
    const end_text = operand[dot_dot + 2 ..];
    if (start_text.len == 0 or end_text.len == 0) return Error.InvalidRange;
    const start = try parseAnchor(start_text);
    const end = try parseAnchor(end_text);
    if (end.line < start.line) return Error.InvalidRange;
    if (end.line == start.line and !std.mem.eql(u8, &end.hash, &start.hash)) return Error.InvalidRange;
    return .{ .start = start, .end = end };
}

fn emitRangeDeletes(
    arena: std.mem.Allocator,
    edits: *std.ArrayList(Edit),
    range: Range,
    source_line: u32,
) Error!void {
    var line = range.start.line;
    while (line <= range.end.line) : (line += 1) {
        const hash: [2]u8 = if (line == range.start.line)
            range.start.hash
        else if (line == range.end.line)
            range.end.hash
        else
            range_interior_hash;
        try edits.append(arena, .{ .delete = .{
            .anchor = .{ .line = line, .hash = hash },
            .source_line = source_line,
        } });
    }
}

fn collectInsertPayload(
    arena: std.mem.Allocator,
    edits: *std.ArrayList(Edit),
    iter: *std.mem.SplitIterator(u8, .scalar),
    line_no: *u32,
    cursor: Cursor,
    op_source_line: u32,
    require_payload: bool,
) Error!void {
    var collected: u32 = 0;
    while (iter.peek()) |raw_peek| {
        const peek = std.mem.trimStart(u8, trimTrailingCR(raw_peek), " \t");
        if (peek.len == 0 or peek[0] != payload_sep) break;
        _ = iter.next();
        line_no.* += 1;
        if (peek.len == 1) {
            const block_count = try collectBlockPayload(arena, edits, iter, line_no, cursor, op_source_line);
            if (block_count > 0) {
                collected += block_count;
                continue;
            }
        }
        try appendInsert(arena, edits, cursor, peek[1..], op_source_line);
        collected += 1;
    }
    if (collected == 0 and require_payload) return Error.MissingPayload;
    if (collected == 0) {
        // `= A..B` with no payload blanks the range to a single empty line.
        try appendInsert(arena, edits, cursor, "", op_source_line);
    }
}

fn collectBlockPayload(
    arena: std.mem.Allocator,
    edits: *std.ArrayList(Edit),
    iter: *std.mem.SplitIterator(u8, .scalar),
    line_no: *u32,
    cursor: Cursor,
    op_source_line: u32,
) Error!u32 {
    var collected: u32 = 0;
    while (iter.peek()) |raw_peek| {
        const raw_line = trimTrailingCR(raw_peek);
        const control_line = std.mem.trimStart(u8, raw_line, " \t");
        if (isBlockPayloadTerminator(control_line)) break;
        _ = iter.next();
        line_no.* += 1;
        try appendInsert(arena, edits, cursor, raw_line, op_source_line);
        collected += 1;
    }
    return collected;
}

fn isBlockPayloadTerminator(line: []const u8) bool {
    if (line.len == 0) return false;
    if (line[0] == payload_sep) return true;
    if (classifyOp(line) != null) return true;
    if (shouldSkipLine(line)) return true;
    return false;
}

fn appendInsert(
    arena: std.mem.Allocator,
    edits: *std.ArrayList(Edit),
    cursor: Cursor,
    text: []const u8,
    op_source_line: u32,
) Error!void {
    try edits.append(arena, .{ .insert = .{
        .cursor = cursor,
        .text = text,
        .source_line = op_source_line,
    } });
}

test "parses a single insert-before with payload" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const edits = try parse(arena, "< 42sr\n~  return 1;\n");
    try std.testing.expectEqual(@as(usize, 1), edits.len);
    const insert = edits[0].insert;
    try std.testing.expectEqual(@as(u32, 42), insert.cursor.before_anchor.line);
    try std.testing.expectEqualStrings("sr", &insert.cursor.before_anchor.hash);
    try std.testing.expectEqualStrings("  return 1;", insert.text);
}

test "parses a delete range as one anchor per line" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const edits = try parse(arena, "- 10sr..12ab\n");
    try std.testing.expectEqual(@as(usize, 3), edits.len);
    try std.testing.expectEqual(@as(u32, 10), edits[0].delete.anchor.line);
    try std.testing.expectEqual(@as(u32, 11), edits[1].delete.anchor.line);
    try std.testing.expectEqual(@as(u32, 12), edits[2].delete.anchor.line);
    try std.testing.expectEqualSlices(u8, &range_interior_hash, &edits[1].delete.anchor.hash);
}

test "parses bare separator as block payload marker" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const edits = try parse(arena,
        \\= 30sm..30sm
        \\~
        \\## Heading
        \\Body text
        \\*** End Patch
    );
    try std.testing.expectEqual(@as(usize, 3), edits.len);
    try std.testing.expectEqualStrings("## Heading", edits[0].insert.text);
    try std.testing.expectEqualStrings("Body text", edits[1].insert.text);
    try std.testing.expectEqual(@as(u32, 30), edits[2].delete.anchor.line);
}

test "parses indented operations" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const edits = try parse(arena,
        \\  = 5sr..5sr
        \\  ~replacement
    );
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expectEqualStrings("replacement", edits[0].insert.text);
    try std.testing.expectEqual(@as(u32, 5), edits[1].delete.anchor.line);
}

test "replace becomes insert-before plus deletes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const edits = try parse(arena, "= 5sr..6ab\n~one\n~two\n");
    // 2 inserts + 2 deletes (lines 5 and 6).
    try std.testing.expectEqual(@as(usize, 4), edits.len);
    try std.testing.expectEqualStrings("one", edits[0].insert.text);
    try std.testing.expectEqualStrings("two", edits[1].insert.text);
    try std.testing.expectEqual(@as(u32, 5), edits[2].delete.anchor.line);
    try std.testing.expectEqual(@as(u32, 6), edits[3].delete.anchor.line);
}

test "envelope markers are skipped" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const edits = try parse(arena, "*** Begin Patch\n@src/foo.zig\n- 1ab..1ab\n*** End Patch\n");
    try std.testing.expectEqual(@as(usize, 1), edits.len);
    try std.testing.expectEqual(@as(u32, 1), edits[0].delete.anchor.line);
}

test "payload without an op is an error" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(Error.PayloadOutsideOp, parse(arena, "~  orphan\n"));
}

test "insert without payload is an error" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(Error.MissingPayload, parse(arena, "< 1ab\n"));
}
