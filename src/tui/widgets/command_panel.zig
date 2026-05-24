const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui_style = @import("../style.zig");

const StylePalette = tui_style.Palette;

pub const Entry = struct { name: []const u8 };

pub const Content = struct {
    entries: []const Entry,
    filter: []const u8,
    selection: u32,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        try self.drawEntries(&surface, ctx);
        return surface;
    }

    fn drawEntries(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        var row: u16 = 0;
        var index: u32 = 0;
        for (self.entries) |entry| {
            if (!startsWithIgnoreCase(entry.name, self.filter)) continue;
            const selected = index == self.selection;
            const prefix = if (selected) "‣ " else "  ";
            const text = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, entry.name });
            writePanelLine(surface, row, text, ctx, selected);
            row += 1;
            index += 1;
            if (row >= surface.size.height) return;
        }
    }
};

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (prefix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn writePanelLine(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, selected: bool) void {
    if (row >= surface.size.height) return;
    var col: u16 = 1;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        if (col >= surface.size.width) return;
        const bytes = grapheme.bytes(text);
        const width: u8 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        if (col + width > surface.size.width) return;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = bytes, .width = width },
            .style = if (selected) StylePalette.tool else StylePalette.thinking_body,
        });
        col += width;
    }
}

test "command panel filters entries case-insensitively" {
    const entries = [_]Entry{ .{ .name = "Connect" }, .{ .name = "Resume" } };
    try std.testing.expect(startsWithIgnoreCase(entries[0].name, "co"));
    try std.testing.expect(!startsWithIgnoreCase(entries[1].name, "co"));
}
