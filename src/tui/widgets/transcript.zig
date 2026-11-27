//! The transcript pane widget: scrollable list of messages per lane.
//!
//! Pulled out of `tui.zig` (R5.1d of `_pm/Projects/tui-split`) — the widget
//! reads the `Thread` lane state, drives the underlying vxfw list view, and
//! handles viewport/cursor sync. INV-WIDGET-1: it carries only scalars and
//! the `Thread` handle (no `App` reference); the per-frame construction site
//! computes them, and `blackhole_visible` writes back into `App.metrics` via
//! pointer so the intro-animation tick can stop.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui_message = @import("message.zig");
const tui_metrics = @import("../metrics.zig");
const tui_style = @import("../style.zig");
const panel = @import("panel.zig");
const app_state = @import("../app_state.zig");
const transcript_mod = @import("../../transcript.zig");

const MessageWidget = tui_message.MessageWidget;
const ConversationLayout = tui_message.ConversationLayout;
const messageRowsCached = tui_metrics.messageRowsCached;

pub const SearchHit = struct {
    message_index: u32,
    start: usize,
    end: usize,
};

pub const TranscriptProps = struct {
    /// Narrow presentation inputs from the lane (INV-WIDGET-1 — no `*Thread`).
    messages: []transcript_mod.Message,
    selected: ?u32 = null,
    auto_scroll: bool = true,
    transcript_list: *vxfw.ListView,
    /// `tui_status.modelStatus(live_runtime, cached_config) != null` —
    /// precomputed so this leaf never touches the App or config modules.
    has_model_configured: bool,
    loading_frame: u8,
    blackhole_frame: u16,
    /// The active input has text — the splash yields its rows while typing.
    /// Computed at the construction site (INV-WIDGET-1 scalar).
    splash_suppressed: bool = false,
    search_query: ?[]const u8 = null,
    active_search_hit: ?SearchHit = null,
    now_ms: i64 = 0,
    body_selection: ?transcript_mod.BodySelection = null,
    palette: *const tui_style.Palette = &tui_style.default_palette,
    presentation: tui_metrics.PresentationConfig = .{},
};

pub const TranscriptWidget = struct {
    /// Narrow presentation inputs from the lane (INV-WIDGET-1 — no `*Thread`).
    messages: []transcript_mod.Message,
    selected: ?u32 = null,
    auto_scroll: bool = true,
    transcript_list: *vxfw.ListView,
    /// `tui_status.modelStatus(live_runtime, cached_config) != null` —
    /// precomputed so this leaf never touches the App or config modules.
    has_model_configured: bool,
    loading_frame: u8,
    blackhole_frame: u16,
    /// The active input has text — the splash yields its rows while typing.
    /// Computed at the construction site (INV-WIDGET-1 scalar).
    splash_suppressed: bool = false,
    search_query: ?[]const u8 = null,
    active_search_hit: ?SearchHit = null,
    now_ms: i64 = 0,
    body_selection: ?transcript_mod.BodySelection = null,
    palette: *const tui_style.Palette = &tui_style.default_palette,
    presentation: tui_metrics.PresentationConfig = .{},

    pub fn fromProps(props: TranscriptProps) TranscriptWidget {
        return .{
            .messages = props.messages,
            .selected = props.selected,
            .auto_scroll = props.auto_scroll,
            .transcript_list = props.transcript_list,
            .has_model_configured = props.has_model_configured,
            .loading_frame = props.loading_frame,
            .blackhole_frame = props.blackhole_frame,
            .splash_suppressed = props.splash_suppressed,
            .search_query = props.search_query,
            .active_search_hit = props.active_search_hit,
            .now_ms = props.now_ms,
            .body_selection = props.body_selection,
            .palette = props.palette,
            .presentation = props.presentation,
        };
    }

    pub fn widget(self: *TranscriptWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawTranscript,
        };
    }

    fn drawTranscript(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *TranscriptWidget = @ptrCast(@alignCast(ptr));
        const max_height = ctx.max.height orelse ctx.min.height;
        const splash_viewport_height: u16 = @max(max_height -| ConversationLayout.top -| ConversationLayout.bottom, 1);

        const messages = self.messages;
        // Splash-only state: the logo is the sole message and the user hasn't
        // started typing, so the intro block centers in the viewport.
        const splash_fills = messages.len == 1 and messages[0] == .logo and !self.splash_suppressed;

        var builder: MessageListBuilder = .{
            .arena = ctx.arena,
            .messages = messages,
            .selected = self.selected,
            .loading_frame = self.loading_frame,
            .blackhole_frame = self.blackhole_frame,
            .has_model_configured = self.has_model_configured,
            .splash_fills_viewport = splash_fills,
            .splash_viewport_height = splash_viewport_height,
            .splash_suppressed = self.splash_suppressed,
            .search_query = self.search_query,
            .active_search_hit = self.active_search_hit,
            .now_ms = self.now_ms,
            .body_selection = self.body_selection,
            .palette = self.palette,
            .presentation = self.presentation,
        };
        self.transcript_list.children = .{ .builder = .{ .userdata = &builder, .buildFn = MessageListBuilder.build } };
        defer self.transcript_list.children = .{ .slice = &.{} };
        self.transcript_list.item_count = @intCast(messages.len);
        self.syncCursor(ctx);

        var list_padding: vxfw.Padding = .{
            .child = self.transcript_list.widget(),
            .padding = ConversationLayout.verticalPadding(self.presentation),
        };
        var surface = try list_padding.widget().draw(ctx);

        // 1. Draw thin scrollbar if transcript overflows viewport
        const total_items: u16 = @intCast(messages.len);
        const view_height = surface.size.height;
        const view_width = surface.size.width;
        const needs_scrollbar = view_height > 0 and view_width > 0 and total_items > 0 and (self.transcript_list.scroll.has_more or self.transcript_list.scroll.top > 0 or self.transcript_list.scroll.offset > 0);

        // 2. "↓ new output" pill when auto-scroll is paused and unseen/new messages exist
        const is_last = if (self.selected) |sel| sel + 1 >= messages.len else true;
        const pill_text = " ↓ new output ";
        const pill_len: u16 = @intCast(pill_text.len);
        const needs_pill = !self.auto_scroll and (self.transcript_list.scroll.has_more or !is_last) and view_width > pill_len + 4 and view_height > 2;

        if (!needs_scrollbar and !needs_pill) {
            return surface;
        }

        const extra_children: usize = @as(usize, @intFromBool(needs_scrollbar)) + @as(usize, @intFromBool(needs_pill));
        const new_children = try ctx.arena.alloc(vxfw.SubSurface, surface.children.len + extra_children);
        @memcpy(new_children[0..surface.children.len], surface.children);
        var idx: usize = surface.children.len;

        if (needs_scrollbar) {
            const sb_metrics = scrollbarMetrics(
                messages,
                self.transcript_list.scroll.top,
                self.transcript_list.scroll.offset,
                view_height,
                view_width,
                self.presentation,
            );
            var sb_surf = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = 1, .height = view_height });
            panel.drawScrollbar(&sb_surf, view_height, sb_metrics.scroll_pos, sb_metrics.total, self.palette);
            new_children[idx] = .{
                .origin = .{ .row = 0, .col = @intCast(view_width -| 1) },
                .surface = sb_surf,
                .z_index = 10,
            };
            idx += 1;
        }

        if (needs_pill) {
            const p = self.palette;
            const pill_row = view_height -| 2;
            const pill_col = view_width -| pill_len -| 2;
            var pill_surf = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = pill_len, .height = 1 });
            panel.lineStyledAt(&pill_surf, 0, pill_text, ctx, 0, p.permission_approve) catch {};
            new_children[idx] = .{
                .origin = .{ .row = @intCast(pill_row), .col = @intCast(pill_col) },
                .surface = pill_surf,
                .z_index = 11,
            };
            idx += 1;
        }

        surface.children = new_children[0..idx];
        return surface;
    }

    fn syncCursor(self: *TranscriptWidget, ctx: vxfw.DrawContext) void {
        const messages = self.messages;
        if (messages.len == 0) return;
        if (self.auto_scroll) {
            const cursor: u32 = @intCast(messages.len - 1);
            self.transcript_list.cursor = cursor;
            self.scrollCursorToTail(ctx, cursor);
            return;
        }
        const cursor = self.selected orelse 0;
        const cursor_changed = self.transcript_list.cursor != cursor;
        self.transcript_list.cursor = cursor;
        if (cursor_changed) self.transcript_list.ensureScroll();
    }

    fn scrollCursorToTail(self: *TranscriptWidget, ctx: vxfw.DrawContext, cursor: u32) void {
        const message_count: u32 = @intCast(self.messages.len);
        if (cursor >= message_count) return;
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        const list_height = max_height -| ConversationLayout.top -| ConversationLayout.bottom;
        const message_height = messageRowsCached(&self.messages[cursor], ConversationLayout.contentWidth(max_width, self.presentation.max_content_width), self.presentation);
        self.transcript_list.scroll.top = cursor;
        self.transcript_list.scroll.pending_lines = 0;
        self.transcript_list.scroll.wants_cursor = false;
        if (message_height > list_height) {
            self.transcript_list.scroll.offset = @intCast(message_height - list_height);
        } else {
            self.transcript_list.scroll.offset = 0;
        }
    }
};

pub const MessageListBuilder = struct {
    arena: std.mem.Allocator,
    messages: []transcript_mod.Message,
    selected: ?u32 = null,
    loading_frame: u8 = 0,
    blackhole_frame: u16 = 0,
    has_model_configured: bool = false,
    splash_fills_viewport: bool = false,
    splash_viewport_height: u16 = 0,
    splash_suppressed: bool = false,
    search_query: ?[]const u8 = null,
    active_search_hit: ?SearchHit = null,
    now_ms: i64 = 0,
    body_selection: ?transcript_mod.BodySelection = null,
    palette: *const tui_style.Palette = &tui_style.default_palette,
    presentation: tui_metrics.PresentationConfig = .{},

    pub fn build(ptr: *const anyopaque, idx: usize, cursor: usize) ?vxfw.Widget {
        _ = cursor;
        const self: *const MessageListBuilder = @ptrCast(@alignCast(ptr));
        if (idx >= self.messages.len) return null;
        const body = self.arena.create(MessageWidget) catch return null;
        body.* = .{
            .message = &self.messages[idx],
            .selected = if (self.selected) |selected| selected == idx else false,
            .loading_frame = self.loading_frame,
            .blackhole_frame = self.blackhole_frame,
            .has_model_configured = self.has_model_configured,
            .splash_fills_viewport = self.splash_fills_viewport,
            .splash_viewport_height = self.splash_viewport_height,
            .splash_suppressed = self.splash_suppressed,
            .search_query = self.search_query,
            .active_search_range = active_range: {
                const hit = self.active_search_hit orelse break :active_range null;
                if (hit.message_index != idx) break :active_range null;
                break :active_range .{ hit.start, hit.end };
            },
            .now_ms = self.now_ms,
            .selection_range = selection_range: {
                const selection = self.body_selection orelse break :selection_range null;
                if (selection.message_index != idx) break :selection_range null;
                break :selection_range selection.range();
            },
            .palette = self.palette,
            .presentation = self.presentation,
        };
        return body.widget();
    }
};

test "MessageListBuilder.build returns null for out-of-bounds index" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .user, "user", "hello");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const builder: MessageListBuilder = .{
        .arena = arena.allocator(),
        .messages = transcript.messages.items,
        .selected = null,
        .has_model_configured = true,
    };

    try std.testing.expect(MessageListBuilder.build(&builder, 0, 0) != null);
    try std.testing.expect(MessageListBuilder.build(&builder, 1, 0) == null);
    try std.testing.expect(MessageListBuilder.build(&builder, 999, 0) == null);
}

test "MessageListBuilder.build constructs widget with correct message and selection state" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .user, "user", "first");
    _ = try transcript.append(gpa, .agent, "agent", "second");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const builder: MessageListBuilder = .{
        .arena = arena.allocator(),
        .messages = transcript.messages.items,
        .selected = 1,
        .loading_frame = 3,
        .blackhole_frame = 7,
        .has_model_configured = true,
    };

    const widget0 = MessageListBuilder.build(&builder, 0, 0);
    try std.testing.expect(widget0 != null);
    const msg0: *const MessageWidget = @ptrCast(@alignCast(widget0.?.userdata));
    try std.testing.expectEqual(false, msg0.selected);
    try std.testing.expectEqual(true, msg0.has_model_configured);
    try std.testing.expectEqual(@as(u8, 3), msg0.loading_frame);
    try std.testing.expectEqual(@as(u16, 7), msg0.blackhole_frame);

    const widget1 = MessageListBuilder.build(&builder, 1, 0);
    try std.testing.expect(widget1 != null);
    const msg1: *const MessageWidget = @ptrCast(@alignCast(widget1.?.userdata));
    try std.testing.expectEqual(true, msg1.selected);
    try std.testing.expectEqualStrings("second", msg1.message.bodyPtr().*);
}

test "MessageListBuilder.build handles empty transcript cleanly" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const builder: MessageListBuilder = .{
        .arena = arena.allocator(),
        .messages = &.{},
        .selected = null,
        .has_model_configured = true,
    };

    try std.testing.expect(MessageListBuilder.build(&builder, 0, 0) == null);
    try std.testing.expect(MessageListBuilder.build(&builder, 1, 0) == null);
}

test "MessageListBuilder.build handles out-of-range selection index" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .user, "user", "msg1");
    _ = try transcript.append(gpa, .agent, "agent", "msg2");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const builder: MessageListBuilder = .{
        .arena = arena.allocator(),
        .messages = transcript.messages.items,
        .selected = 100, // Deliberately out of bounds
        .has_model_configured = true,
    };

    const w0 = MessageListBuilder.build(&builder, 0, 0);
    try std.testing.expect(w0 != null);
    const m0: *const MessageWidget = @ptrCast(@alignCast(w0.?.userdata));
    try std.testing.expectEqual(false, m0.selected);

    const w1 = MessageListBuilder.build(&builder, 1, 0);
    try std.testing.expect(w1 != null);
    const m1: *const MessageWidget = @ptrCast(@alignCast(w1.?.userdata));
    try std.testing.expectEqual(false, m1.selected);
}

fn scrollbarMetrics(
    messages: []transcript_mod.Message,
    scroll_top: usize,
    scroll_offset: i17,
    view_height: u16,
    view_width: u16,
    presentation: tui_metrics.PresentationConfig,
) struct { scroll_pos: u16, total: u16 } {
    const content_width = ConversationLayout.contentWidth(view_width, presentation.max_content_width);
    var total_rows: usize = 0;
    for (messages) |*msg| {
        total_rows += messageRowsCached(msg, content_width, presentation);
    }
    const top_index = @min(messages.len, scroll_top);
    var scroll_row: usize = @intCast(@max(0, scroll_offset));
    for (messages[0..top_index]) |*msg| {
        scroll_row += messageRowsCached(msg, content_width, presentation);
    }
    const max_u16 = std.math.maxInt(u16);
    const total: u16 = @intCast(@min(max_u16, @max(total_rows, @as(usize, view_height) + 1)));
    const scroll_pos: u16 = @intCast(@min(total -| view_height, scroll_row));
    return .{ .scroll_pos = scroll_pos, .total = total };
}

test "TranscriptWidget scrollbar reflects visual rows for a single long message" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const long_msg = "line\n" ** 20;
    _ = try transcript.append(gpa, .user, "user", long_msg);

    const m_mid = scrollbarMetrics(transcript.messages.items, 0, 10, 6, 40, .{});
    try std.testing.expectEqual(@as(u16, 22), m_mid.total);
    try std.testing.expectEqual(@as(u16, 10), m_mid.scroll_pos);

    const m_top = scrollbarMetrics(transcript.messages.items, 0, 0, 6, 40, .{});
    try std.testing.expectEqual(@as(u16, 0), m_top.scroll_pos);

    const m_past_end = scrollbarMetrics(transcript.messages.items, 0, 100, 6, 40, .{});
    try std.testing.expectEqual(@as(u16, 16), m_past_end.scroll_pos);
}
