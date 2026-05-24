const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui_style = @import("../style.zig");

pub const Shell = struct {
    child: vxfw.Widget,

    pub fn widget(self: *Shell) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Shell = @ptrCast(@alignCast(ptr));
        var border: vxfw.Border = .{ .child = self.child, .style = tui_style.Palette.tool };
        return border.widget().draw(ctx);
    }
};
