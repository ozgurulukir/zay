const std = @import("std");
const parse = @import("parse.zig");

const assert = std.debug.assert;

/// Lines of unchanged context shown above and below each hunk.
const context_lines: u32 = 3;
/// One tab in displayed content is rendered as this many spaces.
const tab_replacement: []const u8 = "    ";

/// A single emitted line in the diff stream — pre-windowing. Each carries
/// the original-file and/or new-file line number it occupies, plus its
/// content (still raw, tabs not yet replaced).
const Record = union(enum) {
    context: ContextRecord,
    added: AddedRecord,
    removed: RemovedRecord,

    const ContextRecord = struct { orig_line: u32, new_line: u32, text: []const u8 };
    const AddedRecord = struct { new_line: u32, text: []const u8 };
    const RemovedRecord = struct { orig_line: u32, text: []const u8 };

    fn isChange(self: Record) bool {
        return switch (self) {
            .context => false,
            .added, .removed => true,
        };
    }
};

/// Routing of the parsed edits onto the original file's line space. Mirrors
/// `apply.zig`'s bucket model: every original line N can be deleted and/or
/// have any number of new lines inserted before it; plus separate buckets
/// for inserts at BOF and EOF.
const Routing = struct {
    by_line: std.AutoHashMapUnmanaged(u32, Bucket),
    bof: std.ArrayList([]const u8),
    eof: std.ArrayList([]const u8),

    const Bucket = struct {
        delete: bool = false,
        inserts_before: std.ArrayList([]const u8) = .empty,
    };

    fn deinit(self: *Routing, gpa: std.mem.Allocator) void {
        var it = self.by_line.valueIterator();
        while (it.next()) |bucket| bucket.inserts_before.deinit(gpa);
        self.by_line.deinit(gpa);
        self.bof.deinit(gpa);
        self.eof.deinit(gpa);
        self.* = undefined;
    }
};

/// A contiguous slice of the record stream to actually emit. Distant hunks
/// are joined by a single `    ...` elision line between them.
const Hunk = struct {
    first: u32, // inclusive index into records
    last: u32, // inclusive index into records
};

/// Render a diff view of the edits applied to `original`. Returns an
/// allocated string containing the rendered body. See CONTEXT.md
/// "Diff view" and docs/adr/0002.
pub fn render(
    gpa: std.mem.Allocator,
    original: []const u8,
    edits: []const parse.Edit,
) ![]u8 {
    assert(edits.len > 0);

    var lines = try splitLines(gpa, original);
    defer lines.deinit(gpa);
    assert(lines.items.len > 0);

    var routing = try buildRouting(gpa, edits, @intCast(lines.items.len));
    defer routing.deinit(gpa);

    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(gpa);
    try emitRecords(gpa, &records, lines.items, &routing);
    assert(records.items.len > 0);

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(gpa);
    try computeHunks(gpa, &hunks, records.items);

    return writeHunks(gpa, records.items, hunks.items);
}

fn splitLines(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| try list.append(gpa, line);
    assert(list.items.len > 0);
    return list;
}

fn buildRouting(
    gpa: std.mem.Allocator,
    edits: []const parse.Edit,
    line_count: u32,
) !Routing {
    var routing: Routing = .{
        .by_line = .empty,
        .bof = .empty,
        .eof = .empty,
    };
    errdefer routing.deinit(gpa);

    for (edits) |edit| {
        switch (edit) {
            .delete => |d| try markDelete(gpa, &routing, d.anchor.line),
            .insert => |ins| try routeInsert(gpa, &routing, ins, line_count),
        }
    }
    return routing;
}

fn markDelete(gpa: std.mem.Allocator, routing: *Routing, line: u32) !void {
    assert(line > 0);
    const entry = try routing.by_line.getOrPut(gpa, line);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    entry.value_ptr.delete = true;
}

fn routeInsert(
    gpa: std.mem.Allocator,
    routing: *Routing,
    insert: parse.Insert,
    line_count: u32,
) !void {
    switch (insert.cursor) {
        .bof => try routing.bof.append(gpa, insert.text),
        .eof => try routing.eof.append(gpa, insert.text),
        .before_anchor => |anchor| {
            if (anchor.line > line_count) {
                try routing.eof.append(gpa, insert.text);
            } else {
                try appendInsertBefore(gpa, routing, anchor.line, insert.text);
            }
        },
        .after_anchor => |anchor| {
            if (anchor.line >= line_count) {
                try routing.eof.append(gpa, insert.text);
            } else {
                try appendInsertBefore(gpa, routing, anchor.line + 1, insert.text);
            }
        },
    }
}

fn appendInsertBefore(
    gpa: std.mem.Allocator,
    routing: *Routing,
    line: u32,
    text: []const u8,
) !void {
    assert(line > 0);
    const entry = try routing.by_line.getOrPut(gpa, line);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    try entry.value_ptr.inserts_before.append(gpa, text);
}

fn emitRecords(
    gpa: std.mem.Allocator,
    records: *std.ArrayList(Record),
    lines: []const []const u8,
    routing: *const Routing,
) !void {
    var new_line: u32 = 1;
    for (routing.bof.items) |text| {
        try records.append(gpa, .{ .added = .{ .new_line = new_line, .text = text } });
        new_line += 1;
    }
    for (lines, 1..) |line, idx| {
        const orig_line: u32 = @intCast(idx);
        if (routing.by_line.get(orig_line)) |bucket| {
            for (bucket.inserts_before.items) |text| {
                try records.append(gpa, .{ .added = .{ .new_line = new_line, .text = text } });
                new_line += 1;
            }
            if (bucket.delete) {
                try records.append(gpa, .{ .removed = .{ .orig_line = orig_line, .text = line } });
                continue;
            }
        }
        try records.append(gpa, .{
            .context = .{ .orig_line = orig_line, .new_line = new_line, .text = line },
        });
        new_line += 1;
    }
    for (routing.eof.items) |text| {
        try records.append(gpa, .{ .added = .{ .new_line = new_line, .text = text } });
        new_line += 1;
    }
}

fn computeHunks(
    gpa: std.mem.Allocator,
    hunks: *std.ArrayList(Hunk),
    records: []const Record,
) !void {
    assert(records.len > 0);
    var change_indexes: std.ArrayList(u32) = .empty;
    defer change_indexes.deinit(gpa);
    for (records, 0..) |record, i| {
        if (record.isChange()) try change_indexes.append(gpa, @intCast(i));
    }
    if (change_indexes.items.len == 0) return;

    var cluster_start = change_indexes.items[0];
    var cluster_end = cluster_start;
    var i: u32 = 1;
    while (i < change_indexes.items.len) : (i += 1) {
        const next = change_indexes.items[i];
        const gap = next - cluster_end;
        if (gap <= context_lines * 2) {
            cluster_end = next;
            continue;
        }
        try hunks.append(gpa, makeHunk(cluster_start, cluster_end, @intCast(records.len)));
        cluster_start = next;
        cluster_end = next;
    }
    try hunks.append(gpa, makeHunk(cluster_start, cluster_end, @intCast(records.len)));
}

fn makeHunk(cluster_start: u32, cluster_end: u32, records_len: u32) Hunk {
    assert(cluster_end >= cluster_start);
    assert(records_len > 0);
    const first = if (cluster_start > context_lines) cluster_start - context_lines else 0;
    const last_unclamped = cluster_end + context_lines;
    const last = if (last_unclamped >= records_len) records_len - 1 else last_unclamped;
    return .{ .first = first, .last = last };
}

fn writeHunks(
    gpa: std.mem.Allocator,
    records: []const Record,
    hunks: []const Hunk,
) ![]u8 {
    const gutter_width = computeGutterWidth(records);
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    for (hunks, 0..) |hunk, idx| {
        if (idx > 0) {
            try writeElision(gpa, &buffer, gutter_width);
        }
        try writeOneHunk(gpa, &buffer, records, hunk, gutter_width);
    }
    return buffer.toOwnedSlice(gpa);
}

fn computeGutterWidth(records: []const Record) u8 {
    var max_seen: u32 = 1;
    for (records) |record| {
        const candidate: u32 = switch (record) {
            .context => |c| @max(c.orig_line, c.new_line),
            .added => |a| a.new_line,
            .removed => |r| r.orig_line,
        };
        if (candidate > max_seen) max_seen = candidate;
    }
    return digitCount(max_seen);
}

fn digitCount(value: u32) u8 {
    assert(value > 0);
    var v = value;
    var digits: u8 = 0;
    while (v > 0) : (v /= 10) digits += 1;
    return digits;
}

fn writeElision(
    gpa: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    gutter_width: u8,
) !void {
    try buffer.append(gpa, ' ');
    var i: u8 = 0;
    while (i < gutter_width) : (i += 1) try buffer.append(gpa, ' ');
    try buffer.appendSlice(gpa, " ...\n");
}

fn writeOneHunk(
    gpa: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    records: []const Record,
    hunk: Hunk,
    gutter_width: u8,
) !void {
    assert(hunk.last < records.len);
    assert(hunk.first <= hunk.last);
    var i: u32 = hunk.first;
    while (i <= hunk.last) : (i += 1) {
        try writeRecord(gpa, buffer, records[i], gutter_width);
    }
}

fn writeRecord(
    gpa: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    record: Record,
    gutter_width: u8,
) !void {
    switch (record) {
        .context => |c| try writeLine(gpa, buffer, ' ', c.orig_line, c.text, gutter_width),
        .added => |a| try writeLine(gpa, buffer, '+', a.new_line, a.text, gutter_width),
        .removed => |r| try writeLine(gpa, buffer, '-', r.orig_line, r.text, gutter_width),
    }
}

fn writeLine(
    gpa: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    prefix: u8,
    line_number: u32,
    text: []const u8,
    gutter_width: u8,
) !void {
    try buffer.append(gpa, prefix);
    try writeLineNumber(gpa, buffer, line_number, gutter_width);
    try buffer.append(gpa, ' ');
    try writeNormalisedContent(gpa, buffer, text);
    try buffer.append(gpa, '\n');
}

fn writeLineNumber(
    gpa: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    line_number: u32,
    gutter_width: u8,
) !void {
    assert(line_number > 0);
    const number_width = digitCount(line_number);
    assert(number_width <= gutter_width);
    var padding = gutter_width - number_width;
    while (padding > 0) : (padding -= 1) try buffer.append(gpa, ' ');
    try buffer.print(gpa, "{d}", .{line_number});
}

fn writeNormalisedContent(
    gpa: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    text: []const u8,
) !void {
    for (text) |byte| {
        if (byte == '\t') {
            try buffer.appendSlice(gpa, tab_replacement);
        } else {
            try buffer.append(gpa, byte);
        }
    }
}

test "render produces a diff for a single-line replacement" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hash_mod = @import("hash.zig");
    const original = "alpha\nbeta\ngamma\n";
    const beta_hash = hash_mod.computeLineHash(2, "beta");
    const patch = try std.fmt.allocPrint(arena, "= 2{s}..2{s}\n~BETA\n", .{ beta_hash, beta_hash });
    const edits = try parse.parse(arena, patch);

    const out = try render(gpa, original, edits);
    defer gpa.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "-2 beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+2 BETA") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " 1 alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " 3 gamma") != null);
}

test "render elides distant unchanged sections" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hash_mod = @import("hash.zig");

    var lines_buffer: std.ArrayList(u8) = .empty;
    defer lines_buffer.deinit(gpa);
    var i: u32 = 1;
    while (i <= 50) : (i += 1) try lines_buffer.print(gpa, "line {d}\n", .{i});
    const original = lines_buffer.items;

    const hash_2 = hash_mod.computeLineHash(2, "line 2");
    const hash_40 = hash_mod.computeLineHash(40, "line 40");
    const patch = try std.fmt.allocPrint(
        arena,
        "= 2{s}..2{s}\n~LINE TWO\n= 40{s}..40{s}\n~LINE FORTY\n",
        .{ hash_2, hash_2, hash_40, hash_40 },
    );
    const edits = try parse.parse(arena, patch);

    const out = try render(gpa, original, edits);
    defer gpa.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "...") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+ 2 LINE TWO") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+40 LINE FORTY") != null);
}

test "render normalises tabs to four spaces" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hash_mod = @import("hash.zig");

    const original = "alpha\nbeta\n";
    const beta_hash = hash_mod.computeLineHash(2, "beta");
    const patch = try std.fmt.allocPrint(arena, "= 2{s}..2{s}\n~\tindented\n", .{ beta_hash, beta_hash });
    const edits = try parse.parse(arena, patch);

    const out = try render(gpa, original, edits);
    defer gpa.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "+2     indented") != null);
}
