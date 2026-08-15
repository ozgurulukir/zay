//! Plugins Status Overlay Widget.
//! Displays loaded Lua plugins, their state, and permissions.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const panel = @import("panel.zig");
const tui_style = @import("../style.zig");

pub const State = struct {
    selection: usize = 0,

    pub fn reset(self: *State) void {
        self.selection = 0;
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
    /// Plugin names and their active state, borrowed from the plugin manager.
    plugins: []const PluginEntry = &.{},

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

        try panel.lineStyledAt(&surface, 0, "LUA PLUGINS", ctx, 2, p.panel_header);
        const summary = try std.fmt.allocPrint(ctx.arena, "Loaded: {d}", .{self.plugins.len});
        try panel.lineStyledAt(&surface, 2, summary, ctx, 2, p.info);

        if (self.plugins.len == 0) {
            try panel.lineStyledAt(&surface, 4, "No plugins loaded. Add plugins to ~/.config/nova/plugins/ or .nova/plugins/.", ctx, 2, p.thinking_body);
            try panel.lineStyledAt(&surface, height - 2, "[Esc] Close", ctx, 2, p.thinking_body);
            return surface;
        }

        var row: u16 = 4;
        for (self.plugins, 0..) |plugin, i| {
            if (row >= height - 2) break;
            const is_selected = i == self.state.selection;
            const style = if (is_selected) p.selected_item else p.thinking_body;
            const status_icon = if (plugin.active) "●" else "○";
            const line = try std.fmt.allocPrint(ctx.arena, "  {s} {s}", .{ status_icon, plugin.name });
            try panel.lineStyledAt(&surface, row, line, ctx, 2, style);
            row += 1;
        }

        try panel.lineStyledAt(&surface, height - 2, "[Esc] Close", ctx, 2, p.thinking_body);
        return surface;
    }
};

pub const PluginEntry = struct {
    name: []const u8,
    active: bool,
};
