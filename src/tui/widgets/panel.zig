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
