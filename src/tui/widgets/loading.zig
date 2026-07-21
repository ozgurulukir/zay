//! The transcript loading-spinner widget.
//!
//! Pulled out of `tui.zig` (R5.1c of `_pm/Projects/tui-split`) — the widget
//! is a 27-line wrapper that delegates the actual frame rendering to
//! `tui_message.MessageWidget.drawLoading`, so it earns its own file.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../../tui.zig");
const tui_message = @import("message.zig");
const tui_turn_view = @import("../turn_view.zig");

const App = tui.App;

const loading_spinners = tui_turn_view.loading_spinners;

pub const LoadingWidget = struct {
    app: *App,

    pub fn widget(self: *LoadingWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawLoading,
        };
    }

    fn drawLoading(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *LoadingWidget = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse ctx.min.width;
        const height = ctx.max.height orelse ctx.min.height;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = width,
            .height = height,
        });
        if (height > 0) {
            var row: u16 = if (height > 1) 1 else 0;
            const word = loading_spinners[self.app.thread.turn_view.loading_word_index];
            tui_message.MessageWidget.drawLoading(&surface, word, self.app.metrics.loading_frame, &row, ctx);
        }
        return surface;
    }
};
