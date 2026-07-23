//! MCP Status Overlay Widget.
//! Displays real-time server badges, connection state, tool counts, and latency.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const mcp_manager = @import("../../mcp/manager.zig");
const panel = @import("panel.zig");
const StylePalette = @import("../style.zig").StylePalette;

pub const State = struct {
    selection: usize = 0,

    pub fn reset(self: *State) void {
        self.selection = 0;
    }
};

pub const Content = struct {
    state: *State,
    manager: *const mcp_manager.McpManager,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(
            ctx.arena,
            self.widget(),
            .{ .width = width, .height = height },
            &.{},
        );

        try panel.lineStyledAt(&surface, 0, "MODEL CONTEXT PROTOCOL (MCP) SERVERS", ctx, 2, StylePalette.panel_header);
        const summary = try std.fmt.allocPrint(ctx.arena, "Active Servers: {d} | Active Tools: {d}", .{
            self.manager.activeServerCount(),
            self.manager.totalActiveTools(),
        });
        try panel.lineStyledAt(&surface, 2, summary, ctx, 2, StylePalette.info);

        var row: u16 = 4;
        if (self.manager.clients.items.len == 0) {
            try panel.lineStyledAt(&surface, row, "No MCP servers configured in config.json under \"mcp_servers\".", ctx, 2, StylePalette.thinking_body);
            return surface;
        }

        for (self.manager.clients.items, 0..) |client, i| {
            if (row >= height - 2) break;
            const is_selected = i == self.state.selection;
            if (is_selected) panel.fillRow(&surface, row, StylePalette.selected);

            const badge = client.status.label();
            const line = try std.fmt.allocPrint(
                ctx.arena,
                "  [{s}] {s} - {d} tools ({d}ms)",
                .{ badge, client.name, client.tools.items.len, client.latency_ms },
            );
            const style = if (is_selected) StylePalette.selected_item else StylePalette.thinking_body;
            try panel.lineStyledAt(&surface, row, line, ctx, 2, style);
            row += 2;
        }

        try panel.lineStyledAt(&surface, height - 2, "[Space] Toggle Enable/Disable  |  [Ctrl+R] Reconnect  |  [Esc] Close", ctx, 2, StylePalette.thinking_body);

        return surface;
    }
};
