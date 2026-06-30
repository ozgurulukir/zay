const std = @import("std");

const terminal_markdown = @import("terminal_markdown");
const transcript_mod = @import("../transcript.zig");
const blackhole = @import("blackhole.zig");
const CountingAllocator = @import("counting_allocator").CountingAllocator;

pub fn messageRowsCached(message: *transcript_mod.Message, width: u16) u16 {
    if (message.row_cache.valid and message.row_cache.width == width) {
        return message.row_cache.rows;
    }
    const rows = messageContentRows(message.*, width) + 1;
    message.row_cache = .{ .valid = true, .width = width, .rows = rows };
    return rows;
}

pub fn messageContentRows(message: transcript_mod.Message, width: u16) u16 {
    return switch (message.kind) {
        .user, .notice, .success, .info => textRows(message.body, width -| 2),
        .agent => terminal_markdown.countRows(message.body, @max(width, 1)),
        .skill => textRows(message.title, width -| 2) + if (message.expanded and message.body.len > 0) textRows(message.body, width) else 0,
        .logo => blackhole.rows,
        .thinking => if (message.expanded)
            1 + textRows(message.body, width -| 2)
        else
            1,
        .status => 1,
        .tool => if (message.expanded)
            toolTitleRows(toolMessageTitle(message), width) + toolBodyRows(message, width)
        else
            toolTitleRows(toolMessageTitle(message), width),
    };
}

pub fn toolTitleRows(title: []const u8, width: u16) u16 {
    const indent: u16 = 3;
    return textRows(toolCommandTitle(title), width -| indent);
}

fn toolMessageTitle(message: transcript_mod.Message) []const u8 {
    if (message.expanded) return message.tool_expanded_title orelse message.title;
    return message.title;
}

pub fn toolBodyRows(message: transcript_mod.Message, width: u16) u16 {
    var rows: u16 = 0;
    if (message.body.len > 0) rows += textRows(message.body, width);
    if (message.stderr_body) |stderr| rows += textRows(stderr, width);
    return rows;
}

pub fn textRows(text: []const u8, width: u16) u16 {
    if (text.len == 0) return 1;
    const row_width = @max(@as(usize, width), 1);
    var rows: u16 = 0;
    var line_start: usize = 0;
    while (line_start <= text.len) {
        const line_end = std.mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
        rows += wrappedLineRows(text[line_start..line_end], row_width);
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
    return rows;
}

fn toolCommandTitle(title: []const u8) []const u8 {
    const prefix = "🛠  ";
    if (std.mem.startsWith(u8, title, prefix)) return title[prefix.len..];
    return title;
}

fn wrappedLineRows(line: []const u8, row_width: usize) u16 {
    if (line.len == 0) return 1;
    var rows: u16 = 0;
    var start: usize = 0;
    while (start < line.len) {
        const end = wrappedLineEnd(line, start, row_width);
        rows += 1;
        start = skipLinearWhitespace(line, end);
    }
    return rows;
}

fn wrappedLineEnd(line: []const u8, start: usize, row_width: usize) usize {
    std.debug.assert(start < line.len);
    std.debug.assert(row_width > 0);
    var index = start;
    var col: usize = 0;
    var last_break: ?usize = null;
    while (index < line.len) : (index += 1) {
        const next_col = col + 1;
        if (next_col > row_width) {
            return last_break orelse @max(index, start + 1);
        }
        if (isLinearWhitespace(line[index])) last_break = index;
        col = next_col;
    }
    return line.len;
}

fn skipLinearWhitespace(line: []const u8, start: usize) usize {
    var index = start;
    while (index < line.len) : (index += 1) {
        if (!isLinearWhitespace(line[index])) break;
    }
    return index;
}

fn isLinearWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

test "textRows wraps at word boundaries" {
    try std.testing.expectEqual(@as(u16, 2), textRows("hello world", 8));
    try std.testing.expectEqual(@as(u16, 1), textRows("hello", 8));
}

test "textRows hard wraps words wider than the row" {
    try std.testing.expectEqual(@as(u16, 3), textRows("abcdefgh", 3));
}

test "markdown render allocations stay sub-linear in row count" {
    const gpa = std.testing.allocator;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try body.appendSlice(gpa, "## Section heading with several words to wrap\n");
        try body.appendSlice(gpa, "A paragraph of **bold** and `code` text long enough to wrap across an eighty column terminal more than once.\n");
        try body.appendSlice(gpa, "- a list item with `inline code` and trailing words to force wrapping\n\n");
    }

    var counting: CountingAllocator = .{ .child = gpa };
    var out = try terminal_markdown.render(counting.allocator(), body.items, 80);
    const rows = out.rows.len;
    out.deinit(counting.allocator());

    try std.testing.expect(rows > 60); // body really did wrap to many rows
    try std.testing.expect(counting.count < rows * 2);
}

test "incremental streaming render is far cheaper than full re-render" {
    const gpa = std.testing.allocator;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        try body.appendSlice(gpa, "## Heading for block number with a few words\n\n");
        try body.appendSlice(gpa, "A paragraph of **bold** and `code` text long enough to wrap across an eighty column terminal more than once over.\n\n");
        try body.appendSlice(gpa, "- list item one\n- list item two with `code`\n\n");
    }

    const steps = 48;

    var full_total: usize = 0;
    var s: usize = 1;
    while (s <= steps) : (s += 1) {
        const prefix = body.items[0 .. body.items.len * s / steps];
        var c: CountingAllocator = .{ .child = gpa };
        var out = try terminal_markdown.render(c.allocator(), prefix, 80);
        out.deinit(c.allocator());
        full_total += c.count;
    }

    var inc: terminal_markdown.Incremental = .{};
    defer inc.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var c_gpa: CountingAllocator = .{ .child = gpa };
    var c_arena: CountingAllocator = .{ .child = arena.allocator() };
    var inc_total: usize = 0;
    s = 1;
    while (s <= steps) : (s += 1) {
        const prefix = body.items[0 .. body.items.len * s / steps];
        _ = arena.reset(.retain_capacity);
        const before_gpa = c_gpa.count;
        const before_arena = c_arena.count;
        _ = try inc.rows(c_gpa.allocator(), c_arena.allocator(), prefix, 80);
        inc_total += (c_gpa.count - before_gpa) + (c_arena.count - before_arena);
    }

    try std.testing.expect(inc_total * 8 < full_total);
}
