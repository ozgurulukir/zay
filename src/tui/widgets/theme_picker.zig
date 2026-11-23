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
const tui_style = @import("../style.zig");
const config_mod = @import("../../config/config.zig");

/// Selection state kept on `App` — mirrors `model_selection`/`command_selection`.
pub const State = struct {
    selection: u32 = 0,
    scroll: panel.ListScrollState = .{},
};

/// Per-frame presentation data for the overlay draw.
pub const Content = struct {
    themes: []const tui_style.Theme,
    selection: u32,
    scroll: ?*panel.ListScrollState = null,
    active_name: []const u8,
    filter: []const u8,
    highlight_enabled: bool = true,
    highlight_style: config_mod.FuzzyHighlightStyle = .accent,
    palette: *const tui_style.Palette = &tui_style.default_palette,

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
        const p = self.palette;
        const height = surface.size.height;
        if (height == 0) return;

        // 1. Collect and score matching themes — same rule `countMatching` uses.
        var matching_themes: std.ArrayList(ScoredTheme) = .empty;
        defer matching_themes.deinit(ctx.arena);
        for (self.themes, 0..) |theme, idx| {
            if (scoreTheme(theme, self.filter)) |s| {
                try matching_themes.append(ctx.arena, .{ .idx = idx, .score = s });
            }
        }
        if (scoreAuto(self.filter)) |s| {
            try matching_themes.append(ctx.arena, .{ .idx = self.themes.len, .score = s });
        }

        const total_matches: u32 = @intCast(matching_themes.items.len);
        if (total_matches == 0) {
            try panel.lineStyledAt(surface, 0, "  No matching themes", ctx, 1, p.muted);
            return;
        }

        std.mem.sort(ScoredTheme, matching_themes.items, {}, ScoredTheme.lessThan);

        const viewport = if (self.scroll) |s|
            panel.ViewportWindow.computeStateful(self.selection, total_matches, height, s)
        else
            panel.ViewportWindow.compute(self.selection, total_matches, height);
        var match_idx = viewport.start_index;
        while (match_idx < viewport.end_index) : (match_idx += 1) {
            const theme_idx = matching_themes.items[match_idx].idx;
            const selected = match_idx == self.selection;
            const screen_row = viewport.screenRow(match_idx);

            const is_auto = theme_idx == self.themes.len;
            const name: []const u8 = if (is_auto) auto_name else self.themes[theme_idx].name;
            const mark: ?[]const u8 = if (is_auto)
                (if (std.ascii.eqlIgnoreCase(self.active_name, auto_name)) "  [auto]  ✓ current" else "  [auto]")
            else blk: {
                const theme = self.themes[theme_idx];
                break :blk if (std.mem.eql(u8, theme.name, self.active_name))
                    (if (tui_style.isLight(theme)) "  [light]  ✓ current" else "  [dark]  ✓ current")
                else
                    (if (tui_style.isLight(theme)) "  [light]" else "  [dark]");
            };

            try panel.drawFuzzyListRow(surface, screen_row, ctx, .{
                .prefix = "  ./",
                .text = name,
                .query = self.filter,
                .selected = selected,
                .start_col = 1,
                // Mark the currently-active theme and its light/dark mode.
                .trailing_mark = mark,
                .highlight_enabled = self.highlight_enabled,
                .highlight_style = self.highlight_style,
                .palette = p,
            });
        }
        panel.drawViewportScrollbar(surface, viewport, total_matches, p);
    }
};

const ScoredTheme = struct {
    idx: usize,
    score: f64,

    fn lessThan(_: void, a: ScoredTheme, b: ScoredTheme) bool {
        if (a.score != b.score) return a.score > b.score;
        return a.idx < b.idx;
    }
};

pub const auto_name = "auto";

/// Score the virtual `"auto"` entry against the picker filter.
fn scoreAuto(filter: []const u8) ?f64 {
    if (filter.len == 0) return 0.0;
    return panel.fzyScore(filter, auto_name);
}

/// Score a theme against the picker filter. Empty filter matches all with score 0;
/// otherwise a ranked fuzzy match on the theme slug.
fn scoreTheme(theme: tui_style.Theme, filter: []const u8) ?f64 {
    if (filter.len == 0) return 0.0;
    return panel.fzyScore(filter, theme.name);
}

/// Whether a theme matches the picker filter.
fn matchesTheme(theme: tui_style.Theme, filter: []const u8) bool {
    return scoreTheme(theme, filter) != null;
}

/// Count the themes that the picker filter selects. Pure and shared — the
/// clamps and the Enter-apply map selection into the filtered list with it.
pub fn countMatching(themes: []const tui_style.Theme, filter: []const u8) u32 {
    var count: u32 = 0;
    for (themes) |theme| {
        if (matchesTheme(theme, filter)) count += 1;
    }
    if (scoreAuto(filter) != null) count += 1;
    return count;
}

/// The `name` of the theme the given selection points at within the filtered
/// list, or null when the selection is out of range. The Enter-apply path
/// resolves this to a concrete theme before submitting.
pub fn selectedName(themes: []const tui_style.Theme, filter: []const u8, selection: u32) ?[]const u8 {
    var buf: [256]ScoredTheme = undefined;
    var count: usize = 0;
    for (themes, 0..) |theme, idx| {
        if (scoreTheme(theme, filter)) |s| {
            if (count < buf.len) {
                buf[count] = .{ .idx = idx, .score = s };
                count += 1;
            }
        }
    }
    if (scoreAuto(filter)) |s| {
        if (count < buf.len) {
            buf[count] = .{ .idx = themes.len, .score = s };
            count += 1;
        }
    }
    if (selection >= count) return null;

    std.mem.sort(ScoredTheme, buf[0..count], {}, ScoredTheme.lessThan);
    const idx = buf[selection].idx;
    return if (idx == themes.len) auto_name else themes[idx].name;
}

test "countMatching returns 0 for a filter matching nothing" {
    try std.testing.expectEqual(@as(u32, 0), countMatching(tui_style.allThemes(), "zzzz"));
}

test "countMatching counts partial matches" {
    try std.testing.expectEqual(@as(u32, 2), countMatching(tui_style.allThemes(), "tok"));
    try std.testing.expectEqual(@as(u32, 1), countMatching(tui_style.allThemes(), "drac"));
}

test "countMatching returns the full count for an empty filter" {
    try std.testing.expectEqual(@as(u32, @intCast(tui_style.allThemes().len + 1)), countMatching(tui_style.allThemes(), ""));
}

test "selectedName maps a selection into the filtered list" {
    const themes = tui_style.allThemes();
    // An empty filter lists all themes in canonical order, plus "auto" at the end.
    try std.testing.expectEqualStrings("tokyo_night", selectedName(themes, "", 2).?);
    try std.testing.expectEqualStrings("auto", selectedName(themes, "", @intCast(themes.len)).?);
    // A filtering selection points at the Nth matching row.
    try std.testing.expectEqualStrings("tokyo_night", selectedName(themes, "to", 0).?);
    // An out-of-range selection yields null.
    try std.testing.expect(selectedName(themes, "", 99) == null);
}
