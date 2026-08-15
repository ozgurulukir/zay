//! Color theme picker list widget.
//!
//! A lean, flat list (modeled on `command_panel.zig`, not the heavy
//! `model_picker.zig`) that shows every builtin theme as a `./<slug>` row,
//! highlights the currently-active theme, and filters by the palette-input
//! text. `countMatching` is the single source of truth for the number of
//! filtered rows — the draw, the selection clamps (`syncModeWithInput`,
//! `paletteInputChanged`), and the Enter-apply all consume it so they can
//! never disagree about how many rows match.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");
const command_panel = @import("command_panel.zig");
const tui_style = @import("../style.zig");
const config_mod = @import("../../config/config.zig");

/// Selection state kept on `App` — mirrors `model_selection`/`command_selection`.
pub const State = struct {
    selection: u32 = 0,
};

/// Per-frame presentation data for the overlay draw.
pub const Content = struct {
    themes: []const tui_style.Theme,
    selection: u32,
    active_name: []const u8,
    filter: []const u8,
    highlight_enabled: bool = true,
    highlight_style: config_mod.FuzzyHighlightStyle = .accent,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        if (width == 0 or height == 0) return surface;

        try self.drawEntries(&surface, ctx);
        return surface;
    }

    fn drawEntries(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const p = tui_style.activePalette();
        const height = surface.size.height;
        if (height == 0) return;

        // 1. Collect matching theme indices — same rule `countMatching` uses.
        var matching_indices: std.ArrayList(usize) = .empty;
        defer matching_indices.deinit(ctx.arena);
        for (self.themes, 0..) |theme, idx| {
            if (matchesTheme(theme, self.filter)) {
                try matching_indices.append(ctx.arena, idx);
            }
        }

        const total_matches: u32 = @intCast(matching_indices.items.len);
        if (total_matches == 0) {
            try panel.lineStyledAt(surface, 0, "  No matching themes", ctx, 1, p.thinking_body);
            return;
        }

        const viewport = panel.ViewportWindow.compute(self.selection, total_matches, height);
        var match_idx = viewport.start_index;
        while (match_idx < viewport.end_index) : (match_idx += 1) {
            const theme_idx = matching_indices.items[match_idx];
            const theme = self.themes[theme_idx];
            const selected = match_idx == self.selection;
            const screen_row = viewport.screenRow(match_idx);

            try panel.drawFuzzyListRow(surface, screen_row, ctx, .{
                .prefix = "  ./",
                .text = theme.name,
                .query = self.filter,
                .selected = selected,
                .start_col = 1,
                // Mark the currently-active theme so the highlighted row is
                // obvious even when the cursor still sits elsewhere.
                .trailing_mark = if (std.mem.eql(u8, theme.name, self.active_name)) "  ✓ current" else null,
                .highlight_enabled = self.highlight_enabled,
                .highlight_style = self.highlight_style,
            });
        }
    }
};

/// Whether a theme matches the picker filter. Empty filter matches all;
/// otherwise a case-insensitive prefix or substring match on the slug — the
/// same rule `command_panel.matchesCommandFilter` applies to command names.
fn matchesTheme(theme: tui_style.Theme, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (std.ascii.startsWithIgnoreCase(theme.name, filter)) return true;
    return command_panel.containsIgnoreCase(theme.name, filter);
}

/// Count the themes that the picker filter selects. Pure and shared — the
/// clamps and the Enter-apply map selection into the filtered list with it.
pub fn countMatching(themes: []const tui_style.Theme, filter: []const u8) u32 {
    var count: u32 = 0;
    for (themes) |theme| {
        if (matchesTheme(theme, filter)) count += 1;
    }
    return count;
}

/// The `name` of the theme the given selection points at within the filtered
/// list, or null when the selection is out of range. The Enter-apply path
/// resolves this to a concrete theme before submitting.
pub fn selectedName(themes: []const tui_style.Theme, filter: []const u8, selection: u32) ?[]const u8 {
    var match_index: u32 = 0;
    for (themes) |theme| {
        if (!matchesTheme(theme, filter)) continue;
        if (match_index == selection) return theme.name;
        match_index += 1;
    }
    return null;
}

test "countMatching returns 0 for a filter matching nothing" {
    try std.testing.expectEqual(@as(u32, 0), countMatching(tui_style.allThemes(), "zzzz"));
}

test "countMatching counts partial matches" {
    try std.testing.expectEqual(@as(u32, 1), countMatching(tui_style.allThemes(), "tok"));
}

test "countMatching returns the full count for an empty filter" {
    try std.testing.expectEqual(@as(u32, @intCast(tui_style.allThemes().len)), countMatching(tui_style.allThemes(), ""));
}

test "selectedName maps a selection into the filtered list" {
    const themes = tui_style.allThemes();
    // An empty filter lists all themes in canonical order.
    try std.testing.expectEqualStrings("tokyo_night", selectedName(themes, "", 2).?);
    // A filtering selection points at the Nth matching row.
    try std.testing.expectEqualStrings("tokyo_night", selectedName(themes, "to", 0).?);
    // An out-of-range selection yields null.
    try std.testing.expect(selectedName(themes, "", 99) == null);
}
