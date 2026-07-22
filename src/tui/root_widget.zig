//! RootWidget — the top-level vxfw widget that owns the App reference and
//! delegates events/layout to the per-concern modules.
//!
//! Extracted from `tui.zig` (Adım 3 of refactor plan). Uses a comptime type
//! parameter to avoid circular imports: `tui.zig` instantiates this as
//! `pub const RootWidget = RootWidgetType(App);` after `App` is defined.

const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const event_router = @import("event_router.zig");
const lifecycle = @import("lifecycle.zig");
const root_layout_widget = @import("root_layout.zig");
const tui_message = @import("widgets/message.zig");

const loading_frame_ms = tui_message.loading_frame_ms;

pub fn RootWidgetType(comptime AppType: type) type {
    return struct {
        const Self = @This();

        app: *AppType,
        spinner_tick_accum_ms: u32 = 0,
        blackhole_tick_accum_ms: u32 = 0,
        diff_tick_accum_ms: u32 = 0,
        diff_refresh_pending: bool = false,

        pub const drain_tick_ms: u32 = 30;
        pub const spinner_tick_threshold_ms: u32 = loading_frame_ms;
        pub const diff_tick_threshold_ms: u32 = 300;

        pub fn widget(self: *Self) vxfw.Widget {
            return .{
                .userdata = self,
                .captureHandler = captureEvent,
                .eventHandler = handleEvent,
                .drawFn = drawRoot,
            };
        }

        pub fn captureEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            // Assert: the widget userdata pointer round-trips correctly.
            assert(@intFromPtr(self) == @intFromPtr(ptr));
            try event_router.captureEvent(self.app, self, ctx, event);
        }

        fn handleEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            switch (event) {
                .tick => try lifecycle.handleTick(self, ctx),
                else => {},
            }
        }

        fn handleTick(self: *Self, ctx: *vxfw.EventContext) !void {
            try lifecycle.handleTick(self, ctx);
        }

        pub fn ensureTick(self: *Self, ctx: *vxfw.EventContext) !void {
            try lifecycle.ensureTick(self, ctx);
        }

        pub fn submit(self: *Self, ctx: *vxfw.EventContext) !void {
            try lifecycle.submit(self, ctx);
        }

        pub fn syncFocus(self: *Self, ctx: *vxfw.EventContext) !void {
            try lifecycle.syncFocus(self, ctx);
        }

        fn drainAgentEvents(self: *Self, ctx: *vxfw.EventContext) !bool {
            return lifecycle.drainAgentEvents(self, ctx);
        }

        fn drawRoot(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return root_layout_widget.drawRoot(self.app, self.widget(), ctx);
        }

        // --- Diff viewer --------------------------------------------------

        pub fn handleDiffViewerEvent(self: *Self, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
            try lifecycle.handleDiffViewerEvent(self, ctx, key);
        }

        fn handleDiffBrowseKey(self: *Self, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
            try lifecycle.handleDiffBrowseKey(self, ctx, key);
        }

        fn handleDiffSearchKey(self: *Self, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
            try lifecycle.handleDiffSearchKey(self, ctx, key);
        }

        fn handleDiffCommentKey(self: *Self, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
            try lifecycle.handleDiffCommentKey(self, ctx, key);
        }

        fn closeDiff(self: *Self, ctx: *vxfw.EventContext, send: bool) !void {
            try lifecycle.closeDiff(self, ctx, send);
        }
    };
}
