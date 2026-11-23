//! Mouse-to-transcript byte-offset mapping and word/line selection (issue #513).

const std = @import("std");
const vaxis = @import("vaxis");
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

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

pub fn wordRange(body: []const u8, offset: usize) [2]usize {
    if (body.len == 0) return .{ 0, 0 };
    const pos = @min(offset, body.len - 1);
    if (!isWordByte(body[pos])) {
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
    var view_row: u16 = 0;
    var view_col: u16 = 0;
    var view_width: u16 = app.thread.transcript_view_width;
    var view_height: u16 = app.thread.transcript_view_height;
    const list_top_pad = ConversationLayout.top;
    const list_bottom_pad = ConversationLayout.bottom;
    var list_bottom: u16 = list_top_pad +| view_height;

    if (app.frame_geometry.split_rect_count > 0) {
        const rects = app.frame_geometry.split_rects[0..app.frame_geometry.split_rect_count];
        var matched_driver = false;
        for (rects) |rect| {
            if (row >= rect.row and row < rect.row + rect.height and col >= rect.col and col < rect.col + rect.width) {
                if (rect.lane_index != 0) return null;
                view_row = rect.row;
                view_col = rect.col;
                view_width = rect.width;
                view_height = rect.height;
                list_bottom = view_height -| list_bottom_pad;
                matched_driver = true;
                break;
            }
        }
        if (!matched_driver) return null;
    } else {
        if (app.frame_geometry.terminal_width > 0 and app.frame_geometry.layout.transcript_height > 0) {
            view_width = app.frame_geometry.terminal_width;
            view_height = app.frame_geometry.layout.transcript_height;
            list_bottom = view_height -| list_bottom_pad;
        }
        if (row >= list_bottom or col >= view_width) return null;
    }

    const local_row: i32 = @as(i32, row) - @as(i32, view_row);
    if (local_row < @as(i32, list_top_pad) or local_row >= @as(i32, list_bottom)) return null;
    const local_col: u16 = col -| view_col;
    const messages = app.thread.transcript.messages.items;
    if (messages.len == 0) return null;

    const content_width = ConversationLayout.contentWidth(view_width, app.presentation.max_content_width);
    const top_idx = app.thread.transcript_list.scroll.top;
    if (top_idx >= messages.len) return null;

    var y: i32 = @as(i32, list_top_pad) - @as(i32, app.thread.transcript_list.scroll.offset);
    var idx: usize = top_idx;
    while (idx < messages.len) : (idx += 1) {
        const h: i32 = tui_metrics.messageRowsCached(&messages[idx], content_width, app.presentation);
        if (local_row >= y and local_row < y + h) {
            const msg_row: u16 = @intCast(local_row - y);
            const body = messages[idx].mirror().body;
            const indent = messageBodyIndent(&messages[idx]);
            const extra_header_rows = messageHeaderRows(&messages[idx], app.presentation);
            const byte_off = mapRowColToByteOffset(
                body,
                msg_row -| extra_header_rows,
                local_col,
                content_width,
                indent,
                app.presentation,
            );
            return .{
                .message_index = @intCast(idx),
                .byte_offset = byte_off,
            };
        }
        y += h;
        if (y >= @as(i32, list_bottom)) break;
    }
    return null;
}

fn messageHeaderRows(msg: *const transcript_mod.Message, pres: tui_metrics.PresentationConfig) u16 {
    return switch (msg.*) {
        .user => if (pres.show_turn_timestamps) 1 else 0,
        .thinking => |m| if (m.expanded) 1 else 0,
        else => 0,
    };
}

fn messageBodyIndent(msg: *const transcript_mod.Message) u16 {
    return switch (msg.*) {
        .user, .notice, .success, .info, .thinking => 2,
        .agent, .skill, .logo, .tool, .status => 0,
    };
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
