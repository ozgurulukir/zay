//! MCP Status Overlay Widget.
//! Displays real-time server badges, connection state, tool counts, and latency.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const panel = @import("panel.zig");
const tui_style = @import("../style.zig");

pub const ServerEntry = struct {
    badge: []const u8,
    name: []const u8,
    transport_tag: []const u8,
    tool_count: usize,
    latency_ms: u64,
    error_reason: ?[]const u8 = null,
};

pub const State = struct {
    selection: usize = 0,
    scroll: panel.ListScrollState = .{},
    /// True while the "add server by URL" form is open. The overlay swaps the
    /// server list for a single-line URL input; Enter submits, Esc cancels.
    adding: bool = false,

    pub fn reset(self: *State) void {
        self.selection = 0;
        self.scroll = .{};
        self.adding = false;
    }

    pub fn moveUp(self: *State) void {
        if (self.selection > 0) self.selection -= 1;
    }

    pub fn moveDown(self: *State, count: usize) void {
        if (count > 0 and self.selection + 1 < count) {
            self.selection += 1;
        }
    }
};

pub const Content = struct {
    state: *const State,
    servers: []const ServerEntry = &.{},
    active_server_count: usize = 0,
    total_active_tools: usize = 0,
    /// Current text of the "add server by URL" form (borrowed from the App's
    /// `mcp_url_input` buffer). Only rendered while `state.adding`.
    url_input: []const u8 = "",
    palette: *const tui_style.Palette = &tui_style.default_palette,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const p = self.palette;
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(
            ctx.arena,
            self.widget(),
            .{ .width = width, .height = height },
            &.{},
        );

        try panel.lineStyledAt(&surface, 0, "MODEL CONTEXT PROTOCOL (MCP) SERVERS", ctx, 2, p.panel_header);
        const summary = try std.fmt.allocPrint(ctx.arena, "Active Servers: {d} | Active Tools: {d}", .{
            self.active_server_count,
            self.total_active_tools,
        });
        try panel.lineStyledAt(&surface, 2, summary, ctx, 2, p.info);

        // The add-server form replaces the list while active.
        if (self.state.adding) {
            try panel.lineStyledAt(&surface, 4, "Add remote MCP server (Streamable HTTP):", ctx, 2, p.panel_header);
            const prompt = try std.fmt.allocPrint(ctx.arena, "  > {s}_", .{self.url_input});
            try panel.lineStyledAt(&surface, 6, prompt, ctx, 2, p.selected_item);
            try panel.lineStyledAt(&surface, height -| 2, "[Enter] Add Server  |  [Esc] Cancel", ctx, 2, p.thinking_body);
            return surface;
        }

        const list_start_row: u16 = 4;
        if (self.servers.len == 0) {
            try panel.lineStyledAt(&surface, list_start_row, "No MCP servers configured. Press [a] to add a remote server by URL.", ctx, 2, p.muted);
            try panel.lineStyledAt(&surface, height -| 2, "[a] Add Server  |  [Esc] Close", ctx, 2, p.muted);
            return surface;
        }

        const footer_reserved: u16 = 2;
        const avail_rows: u16 = height -| (list_start_row + footer_reserved);
        const visible_items: u16 = @max(@as(u16, 1), avail_rows / 2);
        const total_items: u32 = @intCast(self.servers.len);
        const viewport = panel.ViewportWindow.computeWithScroll(@intCast(self.state.selection), total_items, visible_items, self.state.scroll.scroll_top);

        var idx = viewport.start_index;
        while (idx < viewport.end_index) : (idx += 1) {
            const entry = self.servers[idx];
            const row: u16 = list_start_row + viewport.screenRow(idx) * 2;
            if (row >= height -| footer_reserved) break;
            const is_selected = idx == self.state.selection;
            if (is_selected) panel.fillRow(&surface, row, p.selected);

            const line = if (entry.error_reason) |reason|
                try std.fmt.allocPrint(
                    ctx.arena,
                    "  [{s}] {s} ({s}) - {d} tools ({d}ms)  ERROR: {s}",
                    .{ entry.badge, entry.name, entry.transport_tag, entry.tool_count, entry.latency_ms, reason },
                )
            else
                try std.fmt.allocPrint(
                    ctx.arena,
                    "  [{s}] {s} ({s}) - {d} tools ({d}ms)",
                    .{ entry.badge, entry.name, entry.transport_tag, entry.tool_count, entry.latency_ms },
                );
            const style = if (is_selected) p.selected_item else p.muted;
            try panel.lineStyledAt(&surface, row, line, ctx, 2, style);
        }
        if (total_items > visible_items) {
            panel.drawViewportScrollbarAt(&surface, list_start_row, avail_rows, viewport, total_items, p);
        }

        try panel.lineStyledAt(&surface, height -| 2, "[Space] Toggle  |  [a] Add Server  |  [Ctrl+R] Reconnect  |  [Esc] Close", ctx, 2, p.muted);

        return surface;
    }
};

test "State cursor clamps to the server count" {
    var state: State = .{};
    try std.testing.expectEqual(@as(usize, 0), state.selection);

    // Moving down in an empty list stays put.
    state.moveDown(0);
    try std.testing.expectEqual(@as(usize, 0), state.selection);

    state.moveDown(3);
    state.moveDown(3);
    try std.testing.expectEqual(@as(usize, 2), state.selection);
    // The last row is a hard stop.
    state.moveDown(3);
    try std.testing.expectEqual(@as(usize, 2), state.selection);

    state.moveUp();
    state.moveUp();
    state.moveUp();
    try std.testing.expectEqual(@as(usize, 0), state.selection);

    state.reset();
    try std.testing.expectEqual(@as(usize, 0), state.selection);
    try std.testing.expect(!state.adding);
}
