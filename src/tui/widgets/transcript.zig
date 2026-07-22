//! The transcript pane widget: scrollable list of messages per lane.
//!
//! Pulled out of `tui.zig` (R5.1d of `_pm/Projects/tui-split`) — the widget
//! reads `App.metrics` and the `Thread` lane state, drives the underlying
//! vxfw list view, and handles viewport/cursor sync, so it earns its own
//! file under `widgets/`.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../../tui.zig");
const tui_message = @import("message.zig");
const tui_metrics = @import("../metrics.zig");

const App = tui.App;
const Thread = tui.Thread;
const MessageWidget = tui_message.MessageWidget;
const ConversationLayout = tui_message.ConversationLayout;
const messageRowsCached = tui_metrics.messageRowsCached;

pub const TranscriptWidget = struct {
    app: *App,
    /// The lane this pane renders — the active lane today; any lane once tiled.
    thread: *Thread,

    pub fn widget(self: *TranscriptWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawTranscript,
        };
    }

    fn drawTranscript(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *TranscriptWidget = @ptrCast(@alignCast(ptr));
        self.syncViewport(ctx);

        var builder: MessageListBuilder = .{
            .arena = ctx.arena,
            .messages = self.thread.transcript.messages.items,
            .selected = self.thread.transcript.selected,
            .loading_frame = self.app.metrics.loading_frame,
            .blackhole_frame = self.app.metrics.blackhole_frame,
            .gpa = self.app.gpa,
            .app = self.app,
        };
        self.thread.transcript_list.children = .{ .builder = .{ .userdata = &builder, .buildFn = MessageListBuilder.build } };
        self.thread.transcript_list.item_count = @intCast(self.thread.transcript.messages.items.len);
        self.syncCursor(ctx);

        var list_padding: vxfw.Padding = .{
            .child = self.thread.transcript_list.widget(),
            .padding = ConversationLayout.verticalPadding(),
        };
        const surface = try list_padding.widget().draw(ctx);
        self.updateBlackholeVisibility();
        return surface;
    }

    // The intro animation only runs while the startup logo (message 0) is the
    // first item the list view is rendering. Once a turn pushes it off the top,
    // `scroll.top` advances and the animation tick is allowed to stop.
    fn updateBlackholeVisibility(self: *TranscriptWidget) void {
        const messages = self.thread.transcript.messages.items;
        self.app.metrics.blackhole_visible = messages.len > 0 and
            messages[0].kind == .logo and
            self.thread.transcript_list.scroll.top == 0;
    }

    fn syncViewport(self: *TranscriptWidget, ctx: vxfw.DrawContext) void {
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        self.thread.transcript_view_width = max_width;
        self.thread.transcript_view_height = max_height -| ConversationLayout.top -| ConversationLayout.bottom;
        if (self.thread.transcript_view_height == 0) self.thread.transcript_view_height = 1;
    }

    fn syncCursor(self: *TranscriptWidget, ctx: vxfw.DrawContext) void {
        const messages = self.thread.transcript.messages.items;
        if (messages.len == 0) return;
        if (self.thread.auto_scroll) {
            const cursor: u32 = @intCast(messages.len - 1);
            self.thread.transcript_list.cursor = cursor;
            self.scrollCursorToTail(ctx, cursor);
            return;
        }
        const cursor = self.thread.transcript.selected orelse 0;
        const cursor_changed = self.thread.transcript_list.cursor != cursor;
        self.thread.transcript_list.cursor = cursor;
        if (cursor_changed) self.thread.transcript_list.ensureScroll();
    }

    fn scrollCursorToTail(self: *TranscriptWidget, ctx: vxfw.DrawContext, cursor: u32) void {
        const message_count: u32 = @intCast(self.thread.transcript.messages.items.len);
        if (cursor >= message_count) return;
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        const list_height = max_height -| ConversationLayout.top -| ConversationLayout.bottom;
        const message_height = messageRowsCached(&self.thread.transcript.messages.items[cursor], ConversationLayout.contentWidth(max_width));
        self.thread.transcript_list.scroll.top = cursor;
        self.thread.transcript_list.scroll.pending_lines = 0;
        self.thread.transcript_list.scroll.wants_cursor = false;
        if (message_height > list_height) {
            self.thread.transcript_list.scroll.offset = @intCast(message_height - list_height);
        } else {
            self.thread.transcript_list.scroll.offset = 0;
        }
    }
};

const MessageListBuilder = struct {
    arena: std.mem.Allocator,
    messages: []tui.transcript_mod.Message,
    selected: ?u32,
    loading_frame: u8,
    blackhole_frame: u16,
    gpa: std.mem.Allocator,
    app: ?*const tui.App = null,

    fn build(ptr: *const anyopaque, idx: usize, cursor: usize) ?vxfw.Widget {
        _ = cursor;
        const self: *const MessageListBuilder = @ptrCast(@alignCast(ptr));
        if (idx >= self.messages.len) return null;
        const body = self.arena.create(MessageWidget) catch return null;
        body.* = .{
            .message = &self.messages[idx],
            .selected = if (self.selected) |selected| selected == idx else false,
            .loading_frame = self.loading_frame,
            .blackhole_frame = self.blackhole_frame,
            .gpa = self.gpa,
            .app = self.app,
        };
        return body.widget();
    }
};
