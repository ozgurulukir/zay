//! MCP Status Overlay Widget.
//! Displays real-time server badges, connection state, tool counts, and latency.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const mcp_manager = @import("../../mcp/manager.zig");
const panel = @import("panel.zig");
const tui_style = @import("../style.zig");

pub const State = struct {
    selection: usize = 0,
    /// True while the "add server by URL" form is open. The overlay swaps the
    /// server list for a single-line URL input; Enter submits, Esc cancels.
    adding: bool = false,

    pub fn reset(self: *State) void {
        self.selection = 0;
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
    state: *State,
    manager: *const mcp_manager.McpManager,
    /// Current text of the "add server by URL" form (borrowed from the App's
    /// `mcp_url_input` buffer). Only rendered while `state.adding`.
    url_input: []const u8 = "",

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
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
            self.manager.activeServerCount(),
            self.manager.totalActiveTools(),
        });
        try panel.lineStyledAt(&surface, 2, summary, ctx, 2, p.info);

        // The add-server form replaces the list while active.
        if (self.state.adding) {
            try panel.lineStyledAt(&surface, 4, "Add remote MCP server (Streamable HTTP):", ctx, 2, p.panel_header);
            const prompt = try std.fmt.allocPrint(ctx.arena, "  > {s}_", .{self.url_input});
            try panel.lineStyledAt(&surface, 6, prompt, ctx, 2, p.selected_item);
            try panel.lineStyledAt(&surface, height - 2, "[Enter] Add Server  |  [Esc] Cancel", ctx, 2, p.thinking_body);
            return surface;
        }

        var row: u16 = 4;
        if (self.manager.clients.items.len == 0) {
            try panel.lineStyledAt(&surface, row, "No MCP servers configured. Press [a] to add a remote server by URL.", ctx, 2, p.thinking_body);
            try panel.lineStyledAt(&surface, height - 2, "[a] Add Server  |  [Esc] Close", ctx, 2, p.thinking_body);
            return surface;
        }

        for (self.manager.clients.items, 0..) |client, i| {
            if (row >= height - 2) break;
            const is_selected = i == self.state.selection;
            if (is_selected) panel.fillRow(&surface, row, p.selected);

            const badge = client.status().label();
            const tool_count = client.tools.items.len;
            const transport_tag: []const u8 = switch (client.transport) {
                .stdio => "stdio",
                .sse => "remote",
            };
            const line = if (client.lifecycle == .failed)
                try std.fmt.allocPrint(
                    ctx.arena,
                    "  [{s}] {s} ({s}) - {d} tools ({d}ms)  ERROR: {s}",
                    .{ badge, client.name, transport_tag, tool_count, client.latency_ms, client.lifecycle.failed.reason },
                )
            else
                try std.fmt.allocPrint(
                    ctx.arena,
                    "  [{s}] {s} ({s}) - {d} tools ({d}ms)",
                    .{ badge, client.name, transport_tag, tool_count, client.latency_ms },
                );
            const style = if (is_selected) p.selected_item else p.thinking_body;
            try panel.lineStyledAt(&surface, row, line, ctx, 2, style);
            row += 2;
        }

        try panel.lineStyledAt(&surface, height - 2, "[Space] Toggle  |  [a] Add Server  |  [Ctrl+R] Reconnect  |  [Esc] Close", ctx, 2, p.thinking_body);

        return surface;
    }
};
