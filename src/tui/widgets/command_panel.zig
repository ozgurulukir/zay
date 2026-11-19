//! Interactive Slash Command Palette list widget.
//!
//! Renders filtered slash commands with scrollable ViewportWindow math,
//! category labels, and descriptions.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");
const tui_style = @import("../style.zig");
const config_mod = @import("../../config/config.zig");

pub const Entry = struct {
    name: []const u8,
    description: []const u8 = "",
    category: []const u8 = "",
};

pub const Content = struct {
    entries: []const Entry,
    filter: []const u8,
    selection: u32,
    highlight_enabled: bool = true,
    highlight_style: config_mod.FuzzyHighlightStyle = .accent,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        if (width == 0 or height == 0) return surface;
        const empty_cell = vaxis.Cell{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{},
        };
        @memset(surface.buffer, empty_cell);

        try self.drawEntries(&surface, ctx);
        return surface;
    }

    fn drawEntries(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const p = tui_style.activePalette();
        const height = surface.size.height;
        if (height == 0) return;

        // 1. Collect and score matching command entries.
        const ScoredEntry = struct {
            idx: usize,
            score: f64,
        };
        var matching_entries: std.ArrayList(ScoredEntry) = .empty;
        defer matching_entries.deinit(ctx.arena);

        for (self.entries, 0..) |entry, idx| {
            if (panel.scoreCandidate(self.filter, entry.name, entry.description)) |score| {
                try matching_entries.append(ctx.arena, .{ .idx = idx, .score = score });
            }
        }

        const total_matches: u32 = @intCast(matching_entries.items.len);
        if (total_matches == 0) {
            try panel.lineStyledAt(surface, 0, "  No matching commands", ctx, 1, p.thinking_body);
            return;
        }

        // Sort by score descending; stable tie-break on original table order.
        const Sorter = struct {
            fn lessThan(_: void, a: ScoredEntry, b: ScoredEntry) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.idx < b.idx;
            }
        };
        std.mem.sort(ScoredEntry, matching_entries.items, {}, Sorter.lessThan);

        // 2. Viewport window calculation for smooth scrolling.
        const viewport = panel.ViewportWindow.compute(self.selection, total_matches, height);

        var match_idx = viewport.start_index;
        while (match_idx < viewport.end_index) : (match_idx += 1) {
            const entry_idx = matching_entries.items[match_idx].idx;
            const entry = self.entries[entry_idx];
            const selected = match_idx == self.selection;
            const screen_row = viewport.screenRow(match_idx);

            try panel.drawFuzzyListRow(surface, screen_row, ctx, .{
                .prefix = "  /",
                .text = entry.name,
                .query = self.filter,
                .selected = selected,
                .start_col = 1,
                .trailing_mark = if (entry.description.len > 0 and surface.size.width > 24) entry.description else null,
                .highlight_enabled = self.highlight_enabled,
                .highlight_style = self.highlight_style,
            });
        }
    }
};

pub fn matchesCommandFilter(name: []const u8, description: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    return panel.scoreCandidate(filter, name, description) != null;
}

test "matchesCommandFilter matches slash prefix, descriptions and fuzzy subsequences" {
    try std.testing.expect(matchesCommandFilter("settings", "View and edit settings", "set"));
    try std.testing.expect(matchesCommandFilter("help", "Show help guide", "guide"));
    try std.testing.expect(matchesCommandFilter("Settings", "View and edit settings", "stg"));
    try std.testing.expect(!matchesCommandFilter("clear", "Clear transcript", "xyz"));
}
