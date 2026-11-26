//! Mouse-to-transcript byte-offset mapping and word/line selection (issue #513).

const std = @import("std");
const vaxis = @import("vaxis");
const terminal_markdown = @import("terminal_markdown");
const tui = @import("../tui.zig");
const transcript_mod = @import("../transcript.zig");
const tui_metrics = @import("metrics.zig");
const text_fit = @import("text_fit.zig");
const message_widget = @import("widgets/message.zig");

const App = tui.App;
const ConversationLayout = message_widget.ConversationLayout;

pub const HitTarget = struct {
    message_index: u32,
    byte_offset: usize,
};

pub const TranscriptViewport = struct {
    view_row: u16,
    view_col: u16,
    view_width: u16,
    view_height: u16,
    list_top_pad: u16,
    list_bottom: u16,
};

/// Compute the inner transcript viewport bounds for the driver pane (lane 0),
/// accounting for `LaneColumnWidget`'s 1-cell border in split mode and the
/// active density's vertical padding.
pub fn transcriptViewport(app: *const App) ?TranscriptViewport {
    const vpad = ConversationLayout.verticalPadding(app.presentation);
    const list_top_pad = vpad.top;
    const list_bottom_pad = vpad.bottom;

    if (app.frame_geometry.split_rect_count > 0) {
        const rects = app.frame_geometry.split_rects[0..app.frame_geometry.split_rect_count];
        for (rects) |rect| {
            if (rect.lane_index == 0) {
                if (rect.width <= 2 or rect.height <= 2) return null;
                const inner_w = rect.width - 2;
                const inner_h = rect.height - 2;
                return .{
                    .view_row = rect.row + 1,
                    .view_col = rect.col + 1,
                    .view_width = inner_w,
                    .view_height = inner_h,
                    .list_top_pad = list_top_pad,
                    .list_bottom = inner_h -| list_bottom_pad,
                };
            }
        }
        return null;
    }

    if (app.frame_geometry.terminal_width > 0 and app.frame_geometry.layout.transcript_height > 0) {
        const view_w = app.frame_geometry.terminal_width;
        const view_h = app.frame_geometry.layout.transcript_height;
        return .{
            .view_row = 0,
            .view_col = 0,
            .view_width = view_w,
            .view_height = view_h,
            .list_top_pad = list_top_pad,
            .list_bottom = view_h -| list_bottom_pad,
        };
    }

    const view_w = app.thread.transcript_view_width;
    const view_h = app.thread.transcript_view_height;
    return .{
        .view_row = 0,
        .view_col = 0,
        .view_width = view_w,
        .view_height = view_h,
        .list_top_pad = list_top_pad,
        .list_bottom = list_top_pad +| view_h,
    };
}

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

pub fn wordRange(body: []const u8, offset: usize) [2]usize {
    if (body.len == 0) return .{ 0, 0 };
    const pos = @min(offset, body.len - 1);
    if (!isWordByte(body[pos])) {
        var iter = vaxis.unicode.graphemeIterator(body);
        while (iter.next()) |g| {
            const g_end = g.start + g.len;
            if (pos >= g.start and pos < g_end) {
                return .{ g.start, g_end };
            }
        }
        return .{ pos, pos + 1 };
    }
    var start = pos;
    while (start > 0 and isWordByte(body[start - 1])) : (start -= 1) {}
    var end = pos + 1;
    while (end < body.len and isWordByte(body[end])) : (end += 1) {}
    return .{ start, end };
}

pub fn lineRange(body: []const u8, offset: usize) [2]usize {
    if (body.len == 0) return .{ 0, 0 };
    const pos = @min(offset, body.len);
    const start = if (std.mem.lastIndexOfScalar(u8, body[0..pos], '\n')) |nl| nl + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
    return .{ start, end };
}

/// Map a screen `(row, col)` inside the focused transcript pane to a message
/// index and byte offset in `msg.mirror().body`.
pub fn hitTestTranscript(app: *App, row: u16, col: u16) ?HitTarget {
    const vp = transcriptViewport(app) orelse return null;
    if (row < vp.view_row or col < vp.view_col) return null;

    const local_row: i32 = @as(i32, row) - @as(i32, vp.view_row);
    const local_col: u16 = col - vp.view_col;
    if (local_row < @as(i32, vp.list_top_pad) or local_row >= @as(i32, vp.list_bottom) or local_col >= vp.view_width) {
        return null;
    }

    const messages = app.thread.transcript.messages.items;
    if (messages.len == 0) return null;

    const content_width = ConversationLayout.contentWidth(vp.view_width, app.presentation.max_content_width);
    const top_idx = app.thread.transcript_list.scroll.top;
    if (top_idx >= messages.len) return null;

    var y: i32 = @as(i32, vp.list_top_pad) - @as(i32, app.thread.transcript_list.scroll.offset);
    var idx: usize = top_idx;
    while (idx < messages.len) : (idx += 1) {
        const h: i32 = tui_metrics.messageRowsCached(&messages[idx], content_width, app.presentation);
        if (local_row >= y and local_row < y + h) {
            const msg_row: u16 = @intCast(local_row - y);
            const byte_off = mapMessageRowColToByteOffset(
                app.gpa,
                &messages[idx],
                msg_row,
                local_col,
                content_width,
                app.presentation,
            ) orelse return null;
            return .{
                .message_index = @intCast(idx),
                .byte_offset = byte_off,
            };
        }
        y += h;
        if (y >= @as(i32, vp.list_bottom)) break;
    }
    return null;
}

fn mapMessageRowColToByteOffset(
    gpa: std.mem.Allocator,
    msg: *transcript_mod.Message,
    msg_row: u16,
    local_col: u16,
    content_width: u16,
    pres: tui_metrics.PresentationConfig,
) ?usize {
    const top_pad = ConversationLayout.messageTop(pres);
    switch (msg.*) {
        .logo, .status => return null,
        .user => |m| {
            const header_rows: u16 = if (pres.show_turn_timestamps) 1 else 0;
            if (msg_row < top_pad + header_rows) return 0;
            return mapRowColToByteOffset(m.body, msg_row - header_rows, local_col, content_width, 2, pres);
        },
        .info => |m| {
            return mapRowColToByteOffset(m.body, msg_row, local_col, content_width, 2, pres);
        },
        .notice => |m| {
            const prefix: []const u8 = if (std.mem.startsWith(u8, m.body, "! ") or std.mem.startsWith(u8, m.body, "⚠ ")) "" else "! ";
            return mapPrefixedRowColToByteOffset(gpa, prefix, m.body, msg_row, local_col, content_width, 2, pres);
        },
        .success => |m| {
            const prefix: []const u8 = if (std.mem.startsWith(u8, m.body, "✓ ")) "" else "✓ ";
            return mapPrefixedRowColToByteOffset(gpa, prefix, m.body, msg_row, local_col, content_width, 2, pres);
        },
        .thinking => |m| {
            if (!m.expanded) return null;
            if (msg_row < top_pad + 1) return 0;
            return mapRowColToByteOffset(m.body, msg_row - 1, local_col, content_width, 2, pres);
        },
        .skill => |m| {
            if (!m.expanded or m.body.len == 0) return null;
            const title_rows = tui_metrics.textRows(m.title, content_width -| 2);
            if (msg_row < top_pad + title_rows) return 0;
            return mapRowColToByteOffset(m.body, msg_row - title_rows, local_col, content_width, 0, pres);
        },
        .tool => |m| {
            if (!m.expanded or m.body.len == 0) return null;
            const title_rows = tui_metrics.toolTitleRowsForView(m, content_width);
            if (msg_row < top_pad + title_rows) return 0;
            return mapRowColToByteOffset(m.body, msg_row - title_rows, local_col, content_width, 0, pres);
        },
        .agent => |m| {
            return mapMarkdownRowColToByteOffset(gpa, msg, m.body, msg_row, local_col, content_width, pres);
        },
    }
}

fn mapPrefixedRowColToByteOffset(
    gpa: std.mem.Allocator,
    prefix: []const u8,
    body: []const u8,
    msg_row: u16,
    local_col: u16,
    content_width: u16,
    indent: u16,
    pres: tui_metrics.PresentationConfig,
) usize {
    if (prefix.len == 0) {
        return mapRowColToByteOffset(body, msg_row, local_col, content_width, indent, pres);
    }
    var stack_buf: [512]u8 = undefined;
    if (prefix.len + body.len <= stack_buf.len) {
        @memcpy(stack_buf[0..prefix.len], prefix);
        @memcpy(stack_buf[prefix.len .. prefix.len + body.len], body);
        const marked = stack_buf[0 .. prefix.len + body.len];
        return mapRowColToByteOffset(marked, msg_row, local_col, content_width, indent, pres) -| prefix.len;
    }
    const marked = std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, body }) catch {
        return mapRowColToByteOffset(body, msg_row, local_col, content_width, indent, pres);
    };
    defer gpa.free(marked);
    return mapRowColToByteOffset(marked, msg_row, local_col, content_width, indent, pres) -| prefix.len;
}

fn borrowedSpanOffset(span_text: []const u8, body: []const u8) ?usize {
    const span_addr = @intFromPtr(span_text.ptr);
    const text_addr = @intFromPtr(body.ptr);
    if (span_addr < text_addr) return null;
    const offset = span_addr - text_addr;
    if (offset > body.len or offset + span_text.len > body.len) return null;
    return offset;
}

fn firstBorrowedOffsetInRow(md_row: terminal_markdown.Row, body: []const u8) ?usize {
    for (md_row.spans) |span| {
        if (borrowedSpanOffset(span.text, body)) |off| return off;
    }
    return null;
}

fn lastBorrowedEndInRow(md_row: terminal_markdown.Row, body: []const u8) ?usize {
    var i: usize = md_row.spans.len;
    while (i > 0) {
        i -= 1;
        if (borrowedSpanOffset(md_row.spans[i].text, body)) |off| {
            return off + md_row.spans[i].text.len;
        }
    }
    return null;
}

/// Map `(msg_row, local_col)` inside a markdown-rendered `.agent` message to a
/// byte offset in `body`, using the exact `terminal_markdown` rows and
/// borrowed span offsets that `drawMarkdown` renders.
fn mapMarkdownRowColToByteOffset(
    gpa: std.mem.Allocator,
    msg: *transcript_mod.Message,
    body: []const u8,
    msg_row: u16,
    local_col: u16,
    content_width: u16,
    pres: tui_metrics.PresentationConfig,
) usize {
    if (body.len == 0) return 0;
    const top_pad = ConversationLayout.messageTop(pres);
    if (msg_row < top_pad) return 0;
    const target_row: usize = msg_row - top_pad;
    const width = @max(content_width, 1);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const rows: []const terminal_markdown.Row = rows: {
        if (body.len > tui_metrics.render_cache_max_bytes) {
            const limited = terminal_markdown.renderLimited(arena.allocator(), body, width, target_row + 1) catch {
                return mapRowColToByteOffset(body, msg_row, local_col, content_width, 0, pres);
            };
            break :rows limited.rows;
        }
        break :rows msg.renderIncPtr().rowsArena(arena.allocator(), body, width) catch {
            return mapRowColToByteOffset(body, msg_row, local_col, content_width, 0, pres);
        };
    };

    if (target_row >= rows.len) return body.len;
    const md_row = rows[target_row];

    var col: u16 = ConversationLayout.left + md_row.indent;
    var last_borrowed_end: ?usize = null;
    for (md_row.spans, 0..) |span, span_idx| {
        const span_w: u16 = @intCast(@min(vaxis.gwidth.gwidth(span.text, .unicode), std.math.maxInt(u16)));
        const borrowed = borrowedSpanOffset(span.text, body);
        if (local_col < col + span_w) {
            if (borrowed) |off| {
                return colToByteInSegment(span.text, off, local_col -| col);
            }
            for (md_row.spans[span_idx + 1 ..]) |next_span| {
                if (borrowedSpanOffset(next_span.text, body)) |next_off| return next_off;
            }
            if (last_borrowed_end) |end_off| return end_off;
            break;
        }
        if (borrowed) |off| {
            last_borrowed_end = off + span.text.len;
        }
        col +|= span_w;
    }

    if (last_borrowed_end) |end_off| return end_off;

    // Row had no borrowed spans (e.g. blank separator or code-fence border).
    // Resolve to the start of the next borrowed row, or end of the previous one.
    for (rows[target_row + 1 ..]) |next_row| {
        if (firstBorrowedOffsetInRow(next_row, body)) |off| return off;
    }
    var prev_idx: usize = target_row;
    while (prev_idx > 0) {
        prev_idx -= 1;
        if (lastBorrowedEndInRow(rows[prev_idx], body)) |end_off| return end_off;
    }
    return body.len;
}

/// Map `(msg_row, local_col)` inside a message surface to a byte offset in
/// `body`, accounting for wrapped lines and grapheme display width.
pub fn mapRowColToByteOffset(
    body: []const u8,
    msg_row: u16,
    local_col: u16,
    content_width: u16,
    indent: u16,
    pres: tui_metrics.PresentationConfig,
) usize {
    if (body.len == 0) return 0;
    const top_pad = ConversationLayout.messageTop(pres);
    if (msg_row < top_pad) return 0;
    const target_row = msg_row - top_pad;
    const body_left = ConversationLayout.left + indent;
    const target_col = local_col -| body_left;
    const wrap_width = @max(content_width -| indent, 1);

    var cur_row: u16 = 0;
    var line_start: usize = 0;
    while (line_start <= body.len) {
        const hard_end = std.mem.indexOfScalarPos(u8, body, line_start, '\n') orelse body.len;
        const hard_line = body[line_start..hard_end];

        var seg_start: usize = 0;
        while (true) {
            const seg_end = if (seg_start < hard_line.len)
                text_fit.wrappedLineEnd(hard_line, seg_start, wrap_width)
            else
                seg_start;

            if (cur_row == target_row) {
                return line_start + colToByteInSegment(hard_line[seg_start..seg_end], seg_start, target_col);
            }
            cur_row += 1;
            if (seg_end >= hard_line.len) break;
            seg_start = text_fit.skipLinearWhitespace(hard_line, seg_end);
        }

        if (hard_end >= body.len) break;
        line_start = hard_end + 1;
    }
    return body.len;
}

fn colToByteInSegment(seg: []const u8, seg_start: usize, target_col: u16) usize {
    var iter = vaxis.unicode.graphemeIterator(seg);
    var col: u16 = 0;
    while (iter.next()) |g| {
        const grapheme = g.bytes(seg);
        const w: u16 = @intCast(vaxis.gwidth.gwidth(grapheme, .unicode));
        if (col + w > target_col) {
            return seg_start + g.start;
        }
        col += w;
    }
    return seg_start + seg.len;
}

test "mapRowColToByteOffset handles wrapping and wide graphemes" {
    const body = "hello world";
    // With wrap_width = 6: row 0 = "hello", row 1 = "world"
    try std.testing.expectEqual(@as(usize, 2), mapRowColToByteOffset(body, 1, ConversationLayout.left + 2, 6, 0, .{}));
    try std.testing.expectEqual(@as(usize, 6), mapRowColToByteOffset(body, 2, ConversationLayout.left + 0, 6, 0, .{}));
}

test "wordRange and lineRange select expected slices" {
    const body = "alpha beta_gamma\nsecond line";
    const w = wordRange(body, 8);
    try std.testing.expectEqualStrings("beta_gamma", body[w[0]..w[1]]);
    const l = lineRange(body, 8);
    try std.testing.expectEqualStrings("alpha beta_gamma", body[l[0]..l[1]]);
}

test "wordRange selects full UTF-8 grapheme clusters without splitting multi-byte sequences" {
    const body = "hi 🚀 café";
    // Emoji starts at byte 3 and is 4 bytes long.
    const emoji_start = std.mem.indexOf(u8, body, "🚀").?;
    const w_emoji_start = wordRange(body, emoji_start);
    try std.testing.expectEqualStrings("🚀", body[w_emoji_start[0]..w_emoji_start[1]]);
    const w_emoji_mid = wordRange(body, emoji_start + 2);
    try std.testing.expectEqualStrings("🚀", body[w_emoji_mid[0]..w_emoji_mid[1]]);

    // Multi-byte accented character 'é' at the end.
    const accented_start = std.mem.indexOf(u8, body, "é").?;
    const w_accented = wordRange(body, accented_start);
    try std.testing.expectEqualStrings("é", body[w_accented[0]..w_accented[1]]);
    try std.testing.expect(std.unicode.utf8ValidateSlice(body[w_accented[0]..w_accented[1]]));
}

test "hitTestTranscript accounts for vertical list padding, indent, wrapping, and scroll offset" {
    const agent_mod = @import("../agent.zig");
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .user, "you", "alpha beta gamma delta");
    app.thread.transcript_view_width = 20; // contentWidth = 16, user wrap_width = 14
    app.thread.transcript_view_height = 10;
    app.thread.transcript_list.scroll.top = 0;
    app.thread.transcript_list.scroll.offset = 1; // scrolled past messageTop()

    // Screen row 0 is the top padding of TranscriptWidget -> outside list.
    try std.testing.expect(hitTestTranscript(&app, 0, 4) == null);
    // Screen row 1 with scroll.offset = 1 lands on message row 1 (first body line).
    // User indent = 2, ConversationLayout.left = 2 -> body starts at col 4.
    const hit = hitTestTranscript(&app, 1, 4).?;
    try std.testing.expectEqual(@as(u32, 0), hit.message_index);
    try std.testing.expectEqual(@as(usize, 0), hit.byte_offset);
    // Screen row 2 lands on wrapped second row ("delta").
    const hit2 = hitTestTranscript(&app, 2, 4).?;
    try std.testing.expectEqual(@as(u32, 0), hit2.message_index);
    try std.testing.expectEqual(@as(usize, "alpha beta ".len), hit2.byte_offset);
}

test "hitTestTranscript succeeds on row 15 in single-pane mode using FrameGeometry" {
    const agent_mod = @import("../agent.zig");
    const frame_geometry = @import("frame_geometry.zig");
    const vxfw = @import("vaxis").vxfw;
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Multi-line message tall enough to span past row 15 even with default 80x1 transcript_view_*.
    var long_body: std.ArrayListUnmanaged(u8) = .empty;
    defer long_body.deinit(gpa);
    for (0..25) |_| {
        try long_body.appendSlice(gpa, "line of text for single-pane hit test\n");
    }
    _ = try app.thread.transcript.append(gpa, .user, "you", long_body.items);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 120, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    app.frame_geometry = frame_geometry.computeFrameGeometry(&app, ctx, 120, 40, "");

    const hit = hitTestTranscript(&app, 15, 4);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(@as(u32, 0), hit.?.message_index);
}

test "hitTestTranscript maps rendered markdown coordinates in agent messages to exact body byte offsets" {
    const agent_mod = @import("../agent.zig");
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    const body = "Hello **world**!";
    _ = try app.thread.transcript.append(gpa, .agent, "agent", body);
    app.thread.transcript_view_width = 60;
    app.thread.transcript_view_height = 20;
    app.thread.transcript_list.scroll.top = 0;
    app.thread.transcript_list.scroll.offset = 0;

    // Rendered row 0 (screen row = list_top_pad(1) + messageTop(1) = 2):
    // "Hello world!" starts at ConversationLayout.left (2).
    // 'w' of "world" is at visual column 2 + 6 = 8, which is byte offset 8 ("Hello **".len).
    const hit_w = hitTestTranscript(&app, 2, ConversationLayout.left + 6).?;
    try std.testing.expectEqual(@as(u32, 0), hit_w.message_index);
    try std.testing.expectEqual(@as(usize, std.mem.indexOf(u8, body, "world").?), hit_w.byte_offset);
}

test "hitTestTranscript respects compact density vertical padding" {
    const agent_mod = @import("../agent.zig");
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.presentation.density = .compact;
    _ = try app.thread.transcript.append(gpa, .user, "you", "compact line");
    app.thread.transcript_view_width = 40;
    app.thread.transcript_view_height = 10;
    app.thread.transcript_list.scroll.top = 0;
    app.thread.transcript_list.scroll.offset = 0;

    // In compact density, list_top_pad == 0 and messageTop == 0, so row 0 hits byte 0.
    const hit = hitTestTranscript(&app, 0, ConversationLayout.left + 2).?;
    try std.testing.expectEqual(@as(u32, 0), hit.message_index);
    try std.testing.expectEqual(@as(usize, 0), hit.byte_offset);
}

test "hitTestTranscript insets split-pane border and accounts for notice prefix" {
    const agent_mod = @import("../agent.zig");
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .notice, "notice", "hello");
    app.frame_geometry.split_rects[0] = .{ .row = 0, .col = 0, .width = 40, .height = 20, .lane_index = 0 };
    app.frame_geometry.split_rect_count = 1;
    app.thread.transcript_list.scroll.top = 0;
    app.thread.transcript_list.scroll.offset = 0;

    // Border cells must not hit.
    try std.testing.expect(hitTestTranscript(&app, 0, 0) == null);

    // Inner transcript starts at (1, 1).
    // list_top_pad(1) + messageTop(1) => screen row 3.
    // col = border(1) + left(2) + indent(2) + "! "(2) = 7 -> 'h' (byte 0).
    const hit_h = hitTestTranscript(&app, 3, 7).?;
    try std.testing.expectEqual(@as(u32, 0), hit_h.message_index);
    try std.testing.expectEqual(@as(usize, 0), hit_h.byte_offset);
    // col 8 -> 'e' (byte 1).
    const hit_e = hitTestTranscript(&app, 3, 8).?;
    try std.testing.expectEqual(@as(usize, 1), hit_e.byte_offset);
}
