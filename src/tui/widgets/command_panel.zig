const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");

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
            // Two-space indent; selection is shown by the row's background fill.
            const prefix = "  ";
            const text = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, entry.name });
            try panel.commandLine(surface, row, text, ctx, selected);
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

test "command panel filters entries case-insensitively" {
    const entries = [_]Entry{ .{ .name = "Connect" }, .{ .name = "Resume" } };
    try std.testing.expect(startsWithIgnoreCase(entries[0].name, "co"));
    try std.testing.expect(!startsWithIgnoreCase(entries[1].name, "co"));
}
