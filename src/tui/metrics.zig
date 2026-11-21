const std = @import("std");

const terminal_markdown = @import("terminal_markdown");
const transcript_mod = @import("../transcript.zig");
const blackhole = @import("blackhole.zig");
const text_fit = @import("text_fit.zig");
const CountingAllocator = @import("counting_allocator").CountingAllocator;

/// Agent bodies at or below this size keep their fully rendered markdown cached
/// across frames via the message's `Incremental` render cache. Larger bodies
/// fall back to a per-frame, viewport-bounded render (`renderLimited` in the
/// message widget) so a giant message never materializes its whole row list
/// into a long-lived cache. Shared with the message widget so the row-counting
/// path gates on exactly the same threshold the render path uses — they must
/// stay consistent or ListView rows desync from rendered content.
///
/// Raised 64→256 KiB (4×) so long streaming answers keep their stable-prefix
/// cache instead of re-parsing the whole body every redraw frame. The
/// Incremental cache holds owned stabilized segments which scale fine to this
/// size for a single active message.
pub const render_cache_max_bytes: usize = 256 * 1024;

/// Readable-measure cap for transcript content (issue #489): 0 fills the
/// terminal width (historical behavior); any positive value caps prose and
/// markdown at that many columns. Set ONCE at startup from
/// `config.tui.max_content_width` (mirroring `tui_style.active`'s
/// set-once-at-startup pattern) so every consumer of
/// `ConversationLayout.contentWidth` — draw, row counting, and scroll
/// navigation — applies the same cap by construction and the row cache never
/// desyncs from the render.
pub var readable_measure_max: u16 = 0;

/// Transcript vertical spacing density (`comfortable` = 1 blank row between
/// messages; `compact` = 0). Set at startup and on settings preview/save.
pub var transcript_density: @import("../config/config.zig").TranscriptDensity = .comfortable;

/// Whether user messages render a dim turn separator/timestamp row above the
/// prompt body. Set at startup and on settings preview/save.
pub var show_turn_timestamps: bool = false;

pub fn topSpacingRows() u16 {
    return switch (transcript_density) {
        .comfortable => 1,
        .compact => 0,
    };
}

/// The transcript content width at `width` columns under the cap. With the
/// cap at 0 this is exactly the historical `width -| left -| right`.
pub fn effectiveContentWidth(width: u16, max_content_width: u16) u16 {
    const content = width -| content_margin_left -| content_margin_right;
    if (max_content_width == 0) return content;
    return @min(content, max_content_width);
}

/// ConversationLayout's fixed margins, mirrored here because the metrics
/// layer receives content widths from it and cannot import a widget module.
const content_margin_left: u16 = 2;
const content_margin_right: u16 = 2;

pub fn messageRowsCached(message: *transcript_mod.Message, width: u16) u16 {
    const cache = message.rowCachePtr();
    if (cache.valid and cache.width == width) {
        return cache.rows;
    }
    const rows = messageContentRows(message, width) + topSpacingRows();
    cache.* = .{ .valid = true, .width = width, .rows = rows };
    return rows;
}

pub fn messageContentRows(message: *transcript_mod.Message, width: u16) u16 {
    return switch (message.*) {
        .user => |m| textRows(m.body, width -| 2) + @as(u16, @intFromBool(show_turn_timestamps)),
        .info => |m| textRows(m.body, width -| 2),
        .notice => |m| blk: {
            const has_marker = std.mem.startsWith(u8, m.body, "! ") or std.mem.startsWith(u8, m.body, "⚠ ");
            var stack_buf: [256]u8 = undefined;
            if (!has_marker and m.body.len + 2 <= stack_buf.len) {
                @memcpy(stack_buf[0..2], "! ");
                @memcpy(stack_buf[2 .. 2 + m.body.len], m.body);
                break :blk textRows(stack_buf[0 .. 2 + m.body.len], width -| 2);
            }
            break :blk textRows(m.body, width -| (if (has_marker) @as(u16, 2) else @as(u16, 4)));
        },
        .success => |m| blk: {
            const has_marker = std.mem.startsWith(u8, m.body, "✓ ");
            var stack_buf: [256]u8 = undefined;
            if (!has_marker and m.body.len + 4 <= stack_buf.len) {
                @memcpy(stack_buf[0..4], "✓ ");
                @memcpy(stack_buf[4 .. 4 + m.body.len], m.body);
                break :blk textRows(stack_buf[0 .. 4 + m.body.len], width -| 2);
            }
            break :blk textRows(m.body, width -| (if (has_marker) @as(u16, 2) else @as(u16, 4)));
        },
        .agent => |m| agentContentRows(message, m, width),
        .skill => |m| textRows(m.title, width -| 2) + if (m.expanded and m.body.len > 0) textRows(m.body, width) else 0,
        .logo => blackhole.intro_block_rows,
        .thinking => |m| if (m.expanded)
            1 + textRows(m.body, width -| 2)
        else
            1,
        .status => 1,
        .tool => |m| if (m.expanded)
            toolTitleRowsForView(m, width) + toolBodyRows(m, width)
        else
            toolTitleRowsForView(m, width),
    };
}

fn agentContentRows(message: *transcript_mod.Message, m: transcript_mod.Basic, width: u16) u16 {
    const w = @max(width, 1);
    // Bodies above the render cache cap are drawn via `renderLimited` at draw
    // time — count with the plain allocation-free scan to mirror that branch.
    // Smaller bodies render through `Incremental`, whose cached stable rows
    // already own their count; counting them allocates nothing (no more
    // `page_allocator` traffic on every width change).
    if (m.body.len > render_cache_max_bytes) {
        return terminal_markdown.countRows(std.heap.page_allocator, m.body, w);
    }
    return message.renderIncPtr().countRows(m.body, w);
}

pub fn toolTitleRows(title: []const u8, width: u16) u16 {
    const indent: u16 = 3;
    return textRows(toolCommandTitle(title), width -| indent);
}

/// Row count for a tool's collapsed title including the duration/exit suffix
/// — the same text `drawToolTitle` renders (both call `titledWithSuffix`).
pub fn toolTitleRowsForView(message: transcript_mod.ToolView, width: u16) u16 {
    var buf: [256]u8 = undefined;
    const base = toolCommandTitle(toolMessageTitle(message));
    const title = message.titledWithSuffix(&buf, base);
    const indent: u16 = 3;
    return textRows(title, width -| indent);
}

fn toolMessageTitle(message: transcript_mod.ToolView) []const u8 {
    if (message.expanded) return message.expanded_title_formatted orelse message.expanded_title orelse message.title;
    return message.title;
}

pub const tool_head_lines: usize = 8;
pub const tool_tail_lines: usize = 15;
pub const tool_line_budget: usize = tool_head_lines + tool_tail_lines + 1;

pub const HeadTailView = struct {
    head: []const u8,
    omitted_lines: usize,
    tail: []const u8,
};

/// Split long tool output into head + tail when it exceeds `tool_line_budget`
/// and `expanded_in_place` is false (#499). Shared by `toolBodyRows` and
/// `drawToolBody` so row counting and rendering never drift.
pub fn splitToolBodyHeadTail(text: []const u8, expanded_in_place: bool) ?HeadTailView {
    if (expanded_in_place or text.len == 0) return null;
    var total_lines: usize = 1;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') total_lines += 1;
    }
    if (total_lines <= tool_line_budget) return null;

    var head_end: usize = 0;
    var seen: usize = 0;
    while (head_end < text.len) : (head_end += 1) {
        if (text[head_end] == '\n') {
            seen += 1;
            if (seen == tool_head_lines) break;
        }
    }

    const tail_target = total_lines - tool_tail_lines;
    var tail_start: usize = 0;
    seen = 0;
    while (tail_start < text.len) : (tail_start += 1) {
        if (text[tail_start] == '\n') {
            seen += 1;
            if (seen == tail_target) {
                tail_start += 1;
                break;
            }
        }
    }

    const omitted = total_lines -| (tool_head_lines + tool_tail_lines);
    if (omitted == 0 or head_end >= tail_start) return null;
    return .{
        .head = text[0..head_end],
        .omitted_lines = omitted,
        .tail = text[tail_start..],
    };
}

pub fn formatTruncationFooter(buf: []u8, omitted_lines: usize) []const u8 {
    return std.fmt.bufPrint(buf, "… {d} more lines · Enter to expand in place", .{omitted_lines}) catch "… more lines · Enter to expand in place";
}

pub fn formatGroupItemRow(buf: []u8, item: transcript_mod.GroupItem) []const u8 {
    const marker: []const u8 = if (item.failed) "✗ " else "✓ ";
    const base = toolCommandTitle(item.title);
    if (item.duration_ms > 0) {
        var dur_buf: [24]u8 = undefined;
        const dur = transcript_mod.formatToolDuration(&dur_buf, item.duration_ms);
        if (item.failed and item.exit_code != 0) {
            return std.fmt.bufPrint(buf, "{s}{s} · exit {d} · {s}", .{ marker, base, item.exit_code, dur }) catch base;
        }
        return std.fmt.bufPrint(buf, "{s}{s} · {s}", .{ marker, base, dur }) catch base;
    }
    return std.fmt.bufPrint(buf, "{s}{s}", .{ marker, base }) catch base;
}

pub fn toolBodyRows(message: transcript_mod.ToolView, width: u16) u16 {
    if (message.group_items.len > 0) {
        var rows: u16 = 0;
        var buf: [256]u8 = undefined;
        for (message.group_items) |item| {
            rows += textRows(formatGroupItemRow(&buf, item), width);
        }
        return rows;
    }
    var rows: u16 = 0;
    if (message.parts.len > 0) {
        for (message.parts) |part| {
            if (splitToolBodyHeadTail(part.text, message.body_expanded_in_place)) |ht| {
                var fbuf: [96]u8 = undefined;
                rows += textRows(ht.head, width);
                rows += textRows(formatTruncationFooter(&fbuf, ht.omitted_lines), width);
                rows += textRows(ht.tail, width);
            } else {
                rows += textRows(part.text, width);
            }
        }
    } else if (message.body.len > 0) {
        if (splitToolBodyHeadTail(message.body, message.body_expanded_in_place)) |ht| {
            var fbuf: [96]u8 = undefined;
            rows += textRows(ht.head, width);
            rows += textRows(formatTruncationFooter(&fbuf, ht.omitted_lines), width);
            rows += textRows(ht.tail, width);
        } else {
            rows += textRows(message.body, width);
        }
    }
    if (message.stderr) |stderr| rows += textRows(stderr, width);
    return rows;
}

pub fn textRows(text: []const u8, width: u16) u16 {
    return text_fit.textRows(text, width);
}

fn toolCommandTitle(title: []const u8) []const u8 {
    const prefix = "🛠  ";
    if (std.mem.startsWith(u8, title, prefix)) return title[prefix.len..];
    return title;
}

test "textRows wraps at word boundaries" {
    try std.testing.expectEqual(@as(u16, 2), textRows("hello world", 8));
    try std.testing.expectEqual(@as(u16, 1), textRows("hello", 8));
}

test "textRows hard wraps words wider than the row" {
    try std.testing.expectEqual(@as(u16, 3), textRows("abcdefgh", 3));
}

test "textRows counts grapheme display width for multi-byte UTF-8, wide CJK/emoji, and combining marks" {
    // 4 accented 2-byte UTF-8 chars (4 cells) fit on width 4 in 1 row (8 bytes would have wrapped).
    try std.testing.expectEqual(@as(u16, 1), textRows("éééé", 4));
    // 3 CJK wide chars = 6 cells: wraps to 2 rows at width 4 (2 + 1).
    try std.testing.expectEqual(@as(u16, 2), textRows("日本語", 4));
    // 2 emoji (2 cells each = 4 cells) fit on width 4 in 1 row, wrap to 2 rows at width 3.
    try std.testing.expectEqual(@as(u16, 1), textRows("🦎🦎", 4));
    try std.testing.expectEqual(@as(u16, 2), textRows("🦎🦎", 3));
    // Combining mark rides the base character: "e\u{0301}e\u{0301}" is 2 cells, not 6 bytes.
    try std.testing.expectEqual(@as(u16, 1), textRows("e\u{0301}e\u{0301}", 2));
}

test "toolBodyRows equals the sum over parts text rows" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "curl");
    try transcript.finishTool(gpa, index, "{\"a\":1}", null, false, .plain, 0, 0);
    transcript.messages.items[index].tool.expanded = true;
    const t = transcript.messages.items[index].tool;

    var expected: u16 = 0;
    for (t.parts) |part| expected += textRows(part.text, 30);
    try std.testing.expectEqual(expected, toolBodyRows(t, 30));
}

test "formatted expanded title with newline counts its lines" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "greet");
    try transcript.updateToolExpanded(gpa, index, "greet", "greet {\"a\":1}");
    transcript.messages.items[index].tool.expanded = true;
    const t = transcript.messages.items[index].tool;
    const title = toolMessageTitle(t);
    // Pretty-printed JSON args span multiple lines.
    try std.testing.expect(std.mem.indexOf(u8, title, "\n") != null);
    // The title rows mirror the draw path (textRows over the command at the
    // indented width), so metrics and rendering never diverge.
    try std.testing.expectEqual(textRows(toolCommandTitle(title), 30 -| 3), toolTitleRows(title, 30));
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

test "effectiveContentWidth caps content under the readable-measure setting" {
    // Cap disabled: historical width - margins (saturating at narrow widths).
    try std.testing.expectEqual(@as(u16, 76), effectiveContentWidth(80, 0));
    try std.testing.expectEqual(@as(u16, 0), effectiveContentWidth(4, 0));
    // Cap enabled: never exceeds the cap, and never the unclamped content.
    try std.testing.expectEqual(@as(u16, 60), effectiveContentWidth(80, 60));
    try std.testing.expectEqual(@as(u16, 30), effectiveContentWidth(34, 60));
    try std.testing.expectEqual(@as(u16, 0), effectiveContentWidth(4, 60));
}

test "splitToolBodyHeadTail truncates long output and expands in place" {
    const long_output = "line\n" ** 50; // 51 lines (50 newlines)
    const ht = splitToolBodyHeadTail(long_output, false).?;
    try std.testing.expectEqual(@as(usize, 51 - tool_head_lines - tool_tail_lines), ht.omitted_lines);
    try std.testing.expect(splitToolBodyHeadTail(long_output, true) == null);

    var tv: transcript_mod.ToolView = .{
        .title = @constCast("bash"),
        .body = @constCast(long_output),
        .expanded = true,
        .running = false,
    };
    const collapsed_rows = toolBodyRows(tv, 80);
    try std.testing.expectEqual(@as(u16, tool_line_budget), collapsed_rows);
    tv.body_expanded_in_place = true;
    const expanded_rows = toolBodyRows(tv, 80);
    try std.testing.expectEqual(@as(u16, 51), expanded_rows);
}
