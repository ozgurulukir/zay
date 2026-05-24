const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const message = @import("message.zig");
const panel = @import("panel.zig");

pub const Field = enum { base_url, api_key };

pub const Content = struct {
    field: Field,
    base_marker: []const u8,
    key_marker: []const u8,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        const base_focused = self.field == .base_url;
        const key_focused = self.field == .api_key;
        const base_prefix = if (base_focused) "‣ " else "  ";
        const key_prefix = if (key_focused) "‣ " else "  ";
        const base_text = try std.fmt.allocPrint(ctx.arena, "{s}{s} Base URL", .{ base_prefix, self.base_marker });
        const key_text = try std.fmt.allocPrint(ctx.arena, "{s}{s} API Key", .{ key_prefix, self.key_marker });
        try panel.commandLine(&surface, 0, base_text, ctx, base_focused);
        try panel.commandLine(&surface, 1, key_text, ctx, key_focused);
        try panel.lineAt(&surface, 3, "Enter a value below.", ctx, false, message.ConversationLayout.left -| 1);
        return surface;
    }
};
