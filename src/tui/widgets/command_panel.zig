//! Interactive Slash Command Palette list widget.
//!
//! Renders filtered slash commands with scrollable ViewportWindow math,
//! category labels, and descriptions.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");
const tui_style = @import("../style.zig");

const StylePalette = tui_style.Palette;

pub const Entry = struct {
    name: []const u8,
    description: []const u8 = "",
    category: []const u8 = "",
};

pub const Content = struct {
    entries: []const Entry,
    filter: []const u8,
    selection: u32,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        if (width == 0 or height == 0) return surface;

        try self.drawEntries(&surface, ctx);
        return surface;
    }

    fn drawEntries(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const height = surface.size.height;
        if (height == 0) return;

        // 1. Collect matching command indices.
        var matching_indices: std.ArrayList(usize) = .empty;
        defer matching_indices.deinit(ctx.arena);

        for (self.entries, 0..) |entry, idx| {
            if (matchesCommandFilter(entry.name, entry.description, self.filter)) {
                try matching_indices.append(ctx.arena, idx);
            }
        }

        const total_matches: u32 = @intCast(matching_indices.items.len);
        if (total_matches == 0) {
            try panel.lineStyledAt(surface, 0, "  No matching commands", ctx, 1, StylePalette.thinking_body);
            return;
        }

        // 2. Viewport window calculation for smooth scrolling.
        const viewport = panel.ViewportWindow.compute(self.selection, total_matches, height);

        var match_idx = viewport.start_index;
        while (match_idx < viewport.end_index) : (match_idx += 1) {
            const entry_idx = matching_indices.items[match_idx];
            const entry = self.entries[entry_idx];
            const selected = match_idx == self.selection;
            const screen_row = viewport.screenRow(match_idx);

            const text = try std.fmt.allocPrint(ctx.arena, "  /{s}", .{entry.name});
            try panel.commandLine(surface, screen_row, text, ctx, selected);
            if (entry.description.len > 0 and surface.size.width > 24) {
                const desc_style = if (selected) StylePalette.selected_item else StylePalette.thinking_body;
                _ = panel.writeBorderTextEndingAt(surface, ctx, screen_row, surface.size.width -| 2, entry.description, desc_style);
            }
        }
    }
};

pub fn matchesCommandFilter(name: []const u8, description: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (startsWithIgnoreCase(name, filter)) return true;
    if (containsIgnoreCase(name, filter)) return true;
    if (containsIgnoreCase(description, filter)) return true;
    return false;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.startsWithIgnoreCase(haystack, needle);
}

/// Case-insensitive substring match, shared by the command-palette filter and
/// the transcript-search matcher (`widgets/search.zig`) so the two never drift.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "matchesCommandFilter matches slash prefix and descriptions" {
    try std.testing.expect(matchesCommandFilter("settings", "View and edit settings", "set"));
    try std.testing.expect(matchesCommandFilter("help", "Show help guide", "guide"));
    try std.testing.expect(!matchesCommandFilter("clear", "Clear transcript", "xyz"));
}
