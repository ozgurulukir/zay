//! Plugins Status Overlay Widget.
//! Displays loaded Lua plugins, their state, and permissions.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const panel = @import("panel.zig");
const tui_style = @import("../style.zig");

pub const State = struct {
    pub const View = enum { installed, store };

    selection: usize = 0,
    view: View = .installed,
    adding: bool = false,

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
    /// Catalog entries are a borrowed render snapshot owned by the TUI job
    /// state. Drawing never performs catalog I/O or touches PluginManager.
    available: []const StoreEntry = &.{},
    store_url_input: []const u8 = "",
    notice: ?[]const u8 = null,
    installing: bool = false,

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
        const tabs = if (self.state.view == .installed) "[Installed]  Store" else "Installed  [Store]";
        try panel.lineStyledAt(&surface, 1, tabs, ctx, 2, p.info);
        const summary = if (self.state.view == .installed)
            try std.fmt.allocPrint(ctx.arena, "Loaded: {d}", .{self.plugins.len})
        else
            try std.fmt.allocPrint(ctx.arena, "Available: {d}", .{self.available.len});
        try panel.lineStyledAt(&surface, 2, summary, ctx, 2, p.info);

        if (self.state.adding) {
            try panel.lineStyledAt(&surface, 4, "Store URL:", ctx, 2, p.notice);
            const input = try std.fmt.allocPrint(ctx.arena, "  {s}", .{self.store_url_input});
            try panel.lineStyledAt(&surface, 5, input, ctx, 2, p.selected_item);
            try panel.lineStyledAt(&surface, height -| 2, "[Enter] Add  [Esc] Cancel", ctx, 2, p.thinking_body);
            return surface;
        }

        var row: u16 = 4;
        var line_buf: [256]u8 = undefined;
        if (self.state.view == .installed) {
            for (self.plugins, 0..) |plugin, i| {
                if (row >= height -| 3) break;
                const is_selected = i == self.state.selection;
                const style = if (is_selected) p.selected_item else p.thinking_body;
                const status_icon = if (plugin.active) "●" else "○";
                // A name longer than line_buf falls back to a per-frame
                // allocation so the entry is never dropped from the list;
                // the common path stays allocation-free.
                const line = std.fmt.bufPrint(&line_buf, "  {s} {s}", .{ status_icon, plugin.name }) catch
                    try std.fmt.allocPrint(ctx.arena, "  {s} {s}", .{ status_icon, plugin.name });
                try panel.lineStyledAt(&surface, row, line, ctx, 2, style);
                row += 1;
            }
            if (self.plugins.len == 0) {
                try panel.lineStyledAt(&surface, 4, "No plugins loaded. Install one into <project>/plugins.", ctx, 2, p.notice);
            }
        } else {
            for (self.available, 0..) |plugin, i| {
                if (row >= height -| 3) break;
                const is_selected = i == self.state.selection;
                const style = if (is_selected) p.selected_item else p.thinking_body;
                const marker = if (plugin.installed) "●" else "+";
                const line = std.fmt.bufPrint(&line_buf, "  {s} {s} v{s} — {s}", .{ marker, plugin.name, plugin.version, plugin.store }) catch
                    try std.fmt.allocPrint(ctx.arena, "  {s} {s} v{s} — {s}", .{ marker, plugin.name, plugin.version, plugin.store });
                try panel.lineStyledAt(&surface, row, line, ctx, 2, style);
                row += 1;
            }
            if (self.available.len == 0) {
                try panel.lineStyledAt(&surface, 4, "No catalogs loaded. Press [a] to add a store.", ctx, 2, p.notice);
            }
        }

        if (self.notice) |notice| try panel.lineStyledAt(&surface, height -| 3, notice, ctx, 2, p.notice);
        const footer = if (self.state.view == .installed)
            "[Tab] Store  [Esc] Close"
        else if (self.installing)
            "Installing..."
        else
            "[Enter] Install  [a] Add store  [r] Refresh  [Tab] Installed";
        try panel.lineStyledAt(&surface, height -| 2, footer, ctx, 2, p.thinking_body);
        return surface;
    }
};

pub const PluginEntry = struct {
    name: []const u8,
    active: bool,
};

pub const StoreEntry = struct {
    name: []const u8,
    version: []const u8,
    store: []const u8,
    installed: bool,
};

test "plugins_status Content.draw renders plugins list correctly" {
    const CountingAllocator = @import("counting_allocator").CountingAllocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var state: State = .{ .selection = 1 };
    const plugins = [_]PluginEntry{
        .{ .name = "hello-world", .active = true },
        .{ .name = "git-tools", .active = false },
    };
    var content: Content = .{
        .state = &state,
        .plugins = &plugins,
    };

    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 10 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    var counting: CountingAllocator = .{ .child = arena.allocator() };
    const counting_ctx: vxfw.DrawContext = .{
        .arena = counting.allocator(),
        .min = ctx.min,
        .max = ctx.max,
        .cell_size = ctx.cell_size,
    };

    const surface = try content.widget().draw(counting_ctx);
    try std.testing.expectEqual(@as(u16, 40), surface.size.width);
    try std.testing.expectEqual(@as(u16, 10), surface.size.height);

    // Read row 4 ("  ● hello-world")
    var buf4: [64]u8 = undefined;
    const line4 = panel.readRow(&surface, 4, &buf4);
    try std.testing.expectEqualStrings("  ● hello-world", line4);

    // Read row 5 ("  ○ git-tools")
    var buf5: [64]u8 = undefined;
    const line5 = panel.readRow(&surface, 5, &buf5);
    try std.testing.expectEqualStrings("  ○ git-tools", line5);
}

test "plugins_status renders plugin names longer than the stack buffer" {
    const CountingAllocator = @import("counting_allocator").CountingAllocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var state: State = .{ .selection = 0 };
    var long_name: [300]u8 = undefined;
    @memset(&long_name, 'x');
    const plugins = [_]PluginEntry{
        .{ .name = &long_name, .active = true },
    };
    var content: Content = .{
        .state = &state,
        .plugins = &plugins,
    };

    var counting: CountingAllocator = .{ .child = arena.allocator() };
    const ctx: vxfw.DrawContext = .{
        .arena = counting.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 8 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try content.widget().draw(ctx);

    // The oversized name must still render (clipped to the surface width):
    // the old `catch continue` dropped the entry from the list entirely.
    var row_buf: [128]u8 = undefined;
    const rendered = panel.readRow(&surface, 4, &row_buf);
    try std.testing.expect(rendered.len >= 20);
    try std.testing.expect(std.mem.startsWith(u8, rendered, "  ● "));
    try std.testing.expect(std.mem.startsWith(u8, rendered[6..], long_name[0..16]));
}
