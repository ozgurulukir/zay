const std = @import("std");

const hash_mod = @import("hash.zig");
const parse = @import("parse.zig");

const assert = std.debug.assert;

pub const Mismatch = struct {
    line: u32,
    expected: [2]u8,
    actual: [2]u8,
};

pub const Outcome = union(enum) {
    applied: Applied,
    rejected: []const Mismatch,
};

pub const Applied = struct {
    content: []u8,
    first_changed_line: ?u32,
};

pub const Error = error{
    LineOutOfRange,
    OutOfMemory,
};

/// Validate anchor hashes and apply the edits to `original`. On success the
/// returned `content` is gpa-owned; on rejection the `mismatches` slice is
/// gpa-owned and the caller must `free` it.
pub fn apply(
    gpa: std.mem.Allocator,
    original: []const u8,
    edits: []const parse.Edit,
) Error!Outcome {
    if (edits.len == 0) return Outcome{ .applied = .{
        .content = try gpa.dupe(u8, original),
        .first_changed_line = null,
    } };

    var lines = try splitLines(gpa, original);
    defer lines.deinit(gpa);

    if (try collectMismatches(gpa, edits, lines.items)) |mismatches| {
        return Outcome{ .rejected = mismatches };
    }
    return Outcome{ .applied = try applyValidated(gpa, &lines, edits) };
}

fn splitLines(gpa: std.mem.Allocator, text: []const u8) Error!std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| try list.append(gpa, line);
    return list;
}

fn collectMismatches(
    gpa: std.mem.Allocator,
    edits: []const parse.Edit,
    file_lines: []const []const u8,
) Error!?[]const Mismatch {
    var mismatches: std.ArrayList(Mismatch) = .empty;
    errdefer mismatches.deinit(gpa);
    for (edits) |edit| {
        switch (edit) {
            .delete => |d| try collectAnchorMismatch(gpa, &mismatches, d.anchor, file_lines, false),
            .insert => |i| switch (i.cursor) {
                .bof, .eof => {},
                .before_anchor => |a| try collectAnchorMismatch(gpa, &mismatches, a, file_lines, true),
                .after_anchor => |a| try collectAnchorMismatch(gpa, &mismatches, a, file_lines, true),
            },
        }
    }
    if (mismatches.items.len == 0) {
        mismatches.deinit(gpa);
        return null;
    }
    return try mismatches.toOwnedSlice(gpa);
}

fn collectAnchorMismatch(
    gpa: std.mem.Allocator,
    mismatches: *std.ArrayList(Mismatch),
    anchor: parse.Anchor,
    file_lines: []const []const u8,
    allow_virtual_trailing_empty: bool,
) Error!void {
    if (anchor.line == 0) return Error.LineOutOfRange;
    if (anchor.line > file_lines.len) {
        if (allow_virtual_trailing_empty) {
            if (isVirtualTrailingEmptyAnchor(anchor, file_lines.len)) return;
        }
        return Error.LineOutOfRange;
    }
    if (std.mem.eql(u8, &anchor.hash, &parse.range_interior_hash)) return;
    const actual = hash_mod.computeLineHash(anchor.line, file_lines[anchor.line - 1]);
    if (actual[0] == anchor.hash[0]) {
        if (actual[1] == anchor.hash[1]) return;
    }
    try mismatches.append(gpa, .{
        .line = anchor.line,
        .expected = anchor.hash,
        .actual = .{ actual[0], actual[1] },
    });
}

fn isVirtualTrailingEmptyAnchor(anchor: parse.Anchor, file_line_count: usize) bool {
    if (anchor.line != file_line_count + 1) return false;
    const expected = hash_mod.computeLineHash(anchor.line, "");
    if (expected[0] != anchor.hash[0]) return false;
    if (expected[1] != anchor.hash[1]) return false;
    return true;
}

const Bucket = struct {
    inserts_before: std.ArrayList([]const u8) = .empty,
    delete: bool = false,
};

fn applyValidated(
    gpa: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    edits: []const parse.Edit,
) Error!Applied {
    var bof_inserts: std.ArrayList([]const u8) = .empty;
    defer bof_inserts.deinit(gpa);
    var eof_inserts: std.ArrayList([]const u8) = .empty;
    defer eof_inserts.deinit(gpa);
    var by_line: std.AutoHashMap(u32, Bucket) = .init(gpa);
    defer freeBuckets(gpa, &by_line);

    for (edits) |edit| try routeEdit(gpa, edit, &bof_inserts, &eof_inserts, &by_line, lines.items.len);

    var first_changed: ?u32 = null;
    try applyAnchorBuckets(gpa, lines, &by_line, &first_changed);
    try applyBofInserts(gpa, lines, bof_inserts.items, &first_changed);
    try applyEofInserts(gpa, lines, eof_inserts.items, &first_changed);

    return .{
        .content = try joinLines(gpa, lines.items),
        .first_changed_line = first_changed,
    };
}

fn routeEdit(
    gpa: std.mem.Allocator,
    edit: parse.Edit,
    bof: *std.ArrayList([]const u8),
    eof: *std.ArrayList([]const u8),
    by_line: *std.AutoHashMap(u32, Bucket),
    file_line_count: usize,
) Error!void {
    switch (edit) {
        .delete => |d| {
            const entry = try by_line.getOrPut(d.anchor.line);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            entry.value_ptr.delete = true;
        },
        .insert => |ins| switch (ins.cursor) {
            .bof => try bof.append(gpa, ins.text),
            .eof => try eof.append(gpa, ins.text),
            .before_anchor => |a| {
                if (isVirtualTrailingEmptyAnchor(a, file_line_count)) {
                    try eof.append(gpa, ins.text);
                } else {
                    try appendToBucket(gpa, by_line, a.line, ins.text);
                }
            },
            .after_anchor => |a| {
                if (a.line >= file_line_count) {
                    try eof.append(gpa, ins.text);
                } else {
                    try appendToBucket(gpa, by_line, a.line + 1, ins.text);
                }
            },
        },
    }
}

fn appendToBucket(
    gpa: std.mem.Allocator,
    by_line: *std.AutoHashMap(u32, Bucket),
    line: u32,
    text: []const u8,
) Error!void {
    const entry = try by_line.getOrPut(line);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    try entry.value_ptr.inserts_before.append(gpa, text);
}

fn freeBuckets(gpa: std.mem.Allocator, by_line: *std.AutoHashMap(u32, Bucket)) void {
    var it = by_line.iterator();
    while (it.next()) |entry| entry.value_ptr.inserts_before.deinit(gpa);
    by_line.deinit();
}

fn applyAnchorBuckets(
    gpa: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    by_line: *std.AutoHashMap(u32, Bucket),
    first_changed: *?u32,
) Error!void {
    var sorted: std.ArrayList(u32) = .empty;
    defer sorted.deinit(gpa);
    var key_iter = by_line.keyIterator();
    while (key_iter.next()) |k| try sorted.append(gpa, k.*);
    std.mem.sort(u32, sorted.items, {}, std.sort.desc(u32));

    for (sorted.items) |line| {
        const bucket = by_line.getPtr(line).?;
        const idx = line - 1;
        const current_line = lines.items[idx];
        if (bucket.delete) {
            try replaceLine(gpa, lines, idx, bucket.inserts_before.items);
        } else if (bucket.inserts_before.items.len > 0) {
            try insertBefore(gpa, lines, idx, bucket.inserts_before.items, current_line);
        } else continue;
        trackFirst(first_changed, line);
    }
}

fn replaceLine(
    gpa: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    idx: u32,
    replacement: []const []const u8,
) Error!void {
    _ = lines.orderedRemove(idx);
    var insert_idx: u32 = idx;
    for (replacement) |text| {
        try lines.insert(gpa, insert_idx, text);
        insert_idx += 1;
    }
}

fn insertBefore(
    gpa: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    idx: u32,
    new_lines: []const []const u8,
    current_line: []const u8,
) Error!void {
    _ = current_line;
    var insert_idx: u32 = idx;
    for (new_lines) |text| {
        try lines.insert(gpa, insert_idx, text);
        insert_idx += 1;
    }
}

fn applyBofInserts(
    gpa: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    texts: []const []const u8,
    first_changed: *?u32,
) Error!void {
    if (texts.len == 0) return;
    var insert_idx: u32 = 0;
    for (texts) |text| {
        try lines.insert(gpa, insert_idx, text);
        insert_idx += 1;
    }
    trackFirst(first_changed, 1);
}

fn applyEofInserts(
    gpa: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    texts: []const []const u8,
    first_changed: *?u32,
) Error!void {
    if (texts.len == 0) return;
    // Treat a trailing empty line (file ended with `\n`) as the boundary so
    // appended text lives before it; without one, append at the very end.
    const has_trailing_empty = lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0;
    const insert_at: u32 = if (has_trailing_empty)
        @intCast(lines.items.len - 1)
    else
        @intCast(lines.items.len);
    var idx = insert_at;
    for (texts) |text| {
        try lines.insert(gpa, idx, text);
        idx += 1;
    }
    trackFirst(first_changed, insert_at + 1);
}

fn trackFirst(first_changed: *?u32, line: u32) void {
    if (first_changed.*) |current| {
        if (line < current) first_changed.* = line;
    } else first_changed.* = line;
}

fn joinLines(gpa: std.mem.Allocator, lines: []const []const u8) Error![]u8 {
    var total: usize = 0;
    for (lines, 0..) |line, i| {
        total += line.len;
        if (i + 1 < lines.len) total += 1;
    }
    var buffer = try gpa.alloc(u8, total);
    errdefer gpa.free(buffer);
    var index: usize = 0;
    for (lines, 0..) |line, i| {
        @memcpy(buffer[index .. index + line.len], line);
        index += line.len;
        if (i + 1 < lines.len) {
            buffer[index] = '\n';
            index += 1;
        }
    }
    assert(index == total);
    return buffer;
}

fn parseFromOne(arena: std.mem.Allocator, patch: []const u8) ![]const parse.Edit {
    return parse.parse(arena, patch);
}

test "apply replaces a single line" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const original = "alpha\nbeta\ngamma\n";
    const beta_hash = hash_mod.computeLineHash(2, "beta");
    const patch = try std.fmt.allocPrint(arena, "= 2{s}..2{s}\n~BETA\n", .{ beta_hash, beta_hash });
    const edits = try parseFromOne(arena, patch);
    const outcome = try apply(gpa, original, edits);
    switch (outcome) {
        .applied => |a| {
            defer gpa.free(a.content);
            try std.testing.expectEqualStrings("alpha\nBETA\ngamma\n", a.content);
            try std.testing.expectEqual(@as(?u32, 2), a.first_changed_line);
        },
        .rejected => return error.UnexpectedRejection,
    }
}

test "apply inserts before an anchor" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const original = "first\nsecond\n";
    const second_hash = hash_mod.computeLineHash(2, "second");
    const patch = try std.fmt.allocPrint(arena, "< 2{s}\n~middle\n", .{second_hash});
    const edits = try parseFromOne(arena, patch);
    const outcome = try apply(gpa, original, edits);
    switch (outcome) {
        .applied => |a| {
            defer gpa.free(a.content);
            try std.testing.expectEqualStrings("first\nmiddle\nsecond\n", a.content);
        },
        .rejected => return error.UnexpectedRejection,
    }
}

test "apply rejects when a hash no longer matches" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const original = "alpha\nbeta\ngamma\n";
    const edits = try parseFromOne(arena, "- 2zz..2zz\n");
    const outcome = try apply(gpa, original, edits);
    switch (outcome) {
        .applied => return error.UnexpectedApply,
        .rejected => |mismatches| {
            defer gpa.free(mismatches);
            try std.testing.expectEqual(@as(usize, 1), mismatches.len);
            try std.testing.expectEqual(@as(u32, 2), mismatches[0].line);
            try std.testing.expectEqualSlices(u8, "zz", &mismatches[0].expected);
        },
    }
}

test "apply appends after a virtual trailing empty anchor" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const virtual_hash = hash_mod.computeLineHash(2, "");
    const patch = try std.fmt.allocPrint(arena, "+ 2{s}\n~tail\n", .{virtual_hash});
    const edits = try parseFromOne(arena, patch);
    const outcome = try apply(gpa, "only", edits);
    switch (outcome) {
        .applied => |a| {
            defer gpa.free(a.content);
            try std.testing.expectEqualStrings("only\ntail", a.content);
        },
        .rejected => return error.UnexpectedRejection,
    }
}

test "apply appends at EOF" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const original = "only\n";
    const edits = try parseFromOne(arena, "+ EOF\n~tail\n");
    const outcome = try apply(gpa, original, edits);
    switch (outcome) {
        .applied => |a| {
            defer gpa.free(a.content);
            try std.testing.expectEqualStrings("only\ntail\n", a.content);
        },
        .rejected => return error.UnexpectedRejection,
    }
}
