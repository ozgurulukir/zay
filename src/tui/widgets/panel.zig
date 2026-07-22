const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const message = @import("message.zig");
const tui_style = @import("../style.zig");

const StylePalette = tui_style.Palette;

const secondary_column: u16 = 52;

pub const Shell = struct {
    child: vxfw.Widget,

    pub fn widget(self: *Shell) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Shell = @ptrCast(@alignCast(ptr));
        var border: vxfw.Border = .{ .child = self.child, .style = StylePalette.tool };
        return border.widget().draw(ctx);
    }
};

pub fn listSurface(ctx: vxfw.DrawContext, owner: vxfw.Widget, list: vxfw.Widget) !vxfw.Surface {
    const width = ctx.max.width orelse 0;
    const height = ctx.max.height orelse 0;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{
        .origin = .{ .row = 0, .col = 0 },
        .surface = try list.draw(ctx.withConstraints(
            .{ .width = width, .height = height },
            .{ .width = width, .height = height },
        )),
        .z_index = 0,
    };
    return vxfw.Surface.initWithChildren(ctx.arena, owner, .{ .width = width, .height = height }, children);
}

pub const ViewportWindow = struct {
    scroll_top: u32,
    start_index: u32,
    end_index: u32,
    visible_height: u32,

    pub fn compute(selection: u32, total_count: u32, height: u16) ViewportWindow {
        const visible_height: u32 = height;
        if (visible_height == 0 or total_count == 0) {
            return .{ .scroll_top = 0, .start_index = 0, .end_index = 0, .visible_height = 0 };
        }

        var scroll_top: u32 = 0;
        if (selection >= visible_height) {
            scroll_top = selection - visible_height + 1;
        }

        const end_index = @min(total_count, scroll_top + visible_height);
        return .{
            .scroll_top = scroll_top,
            .start_index = scroll_top,
            .end_index = end_index,
            .visible_height = visible_height,
        };
    }

    pub fn screenRow(self: ViewportWindow, index: u32) u16 {
        return @intCast(index - self.scroll_top);
    }
};

pub fn secondaryColumn(width: u16) u16 {
    return @min(secondary_column, width / 2);
}

pub fn commandLine(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, selected: bool) !void {
    try lineAt(surface, row, text, ctx, selected, message.ConversationLayout.left -| 1);
}

pub fn fillRow(surface: *vxfw.Surface, row: u16, style: vaxis.Style) void {
    if (row >= surface.size.height) return;
    var col: u16 = 0;
    while (col < surface.size.width) : (col += 1) {
        surface.writeCell(col, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
    }
}

pub fn lineAt(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, selected: bool, start_col: u16) !void {
    if (selected) fillRow(surface, row, StylePalette.selected);
    const active_style = if (selected) StylePalette.selected_item else StylePalette.thinking_body;
    try lineStyledAt(surface, row, text, ctx, start_col, active_style);
}

pub fn lineStyledAt(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, start_col: u16, active_style: vaxis.Style) !void {
    if (row >= surface.size.height) return;
    const stable_text = try ctx.arena.dupe(u8, text);
    var col: u16 = start_col;
    var iter = ctx.graphemeIterator(stable_text);
    while (iter.next()) |grapheme| {
        if (col + 1 >= surface.size.width) return;
        const bytes = grapheme.bytes(stable_text);
        const width: u8 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = bytes, .width = width },
            .style = active_style,
        });
        col += width;
    }
}

pub fn right(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, selected: bool) !void {
    const active_style = if (selected) StylePalette.selected_item else StylePalette.thinking_body;
    try rightStyled(surface, row, text, ctx, active_style);
}

pub fn rightStyled(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, active_style: vaxis.Style) !void {
    if (row >= surface.size.height) return;
    const stable_text = try ctx.arena.dupe(u8, text);
    const text_width: u16 = @intCast(@min(ctx.stringWidth(stable_text), std.math.maxInt(u16)));
    const end_col = surface.size.width -| message.ConversationLayout.right;
    if (text_width >= end_col) return;
    var col = end_col - text_width;
    var iter = ctx.graphemeIterator(stable_text);
    while (iter.next()) |grapheme| {
        if (col >= surface.size.width) return;
        const bytes = grapheme.bytes(stable_text);
        const width: u8 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        if (col + width > surface.size.width) return;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = bytes, .width = width },
            .style = active_style,
        });
        col += width;
    }
}

/// Draw `text` on `row` so its last cell ends at `end_col` (inclusive), filling
/// leftward. Returns the first column the text occupies — or `end_col + 1` when
/// nothing was drawn — so a caller can place another label further left.
pub fn writeBorderTextEndingAt(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, end_col: u16, text: []const u8, style: vaxis.Style) u16 {
    if (text.len == 0 or row >= surface.size.height) return end_col + 1;
    const text_w: u16 = @intCast(ctx.stringWidth(text));
    if (text_w == 0 or text_w > end_col + 1) return end_col + 1;
    const start: u16 = end_col + 1 - text_w;
    var col = start;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const width: u16 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = bytes, .width = @intCast(width) },
            .style = style,
        });
        col += width;
    }
    return start;
}

pub fn writeBorderLabelRight(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, text: []const u8, style: vaxis.Style) void {
    if (text.len == 0 or row >= surface.size.height) return;
    const w = surface.size.width;
    if (w < 4) return;
    const max_w: u16 = w -| 3;
    const text_w: u16 = @intCast(@min(ctx.stringWidth(text), @as(usize, max_w)));
    if (text_w == 0) return;
    var col: u16 = w -| 2 -| text_w;
    var used: u16 = 0;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const width: u16 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        if (used + width > text_w) break;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = bytes, .width = @intCast(width) },
            .style = style,
        });
        col += width;
        used += width;
    }
}
