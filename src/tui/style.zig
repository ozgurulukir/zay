const std = @import("std");
const vaxis = @import("vaxis");

/// A pure RGB color: one of the ~15 named base colors a theme author edits.
/// `vaxis.Color` is a tagged union, so every theme color must be wrapped as
/// `.{ .rgb = theme.X }` when it lands in a style — never used bare.
pub const Rgb = [3]u8;

/// A named theme: the SSOT a theme author edits. `buildPalette` derives the
/// full runtime `Palette` from these ~15 slots, so the color→style mapping
/// lives in one place and a theme is a short, readable color table.
pub const Theme = struct {
    name: []const u8,
    thinking_blue: Rgb,
    user_yellow: Rgb,
    success_green: Rgb,
    failure_red: Rgb,
    accent_orange: Rgb,
    skill_purple: Rgb,
    lane_pink: Rgb,
    muted_gray: Rgb,
    selection_bg: Rgb,
    amber_yellow: Rgb,
    white: Rgb,
    code_blue: Rgb,
    faint_add_bg: Rgb,
    faint_del_bg: Rgb,
    body: Rgb,
    background: Rgb,
    blackhole_orange: Rgb,
    markdown_heading: Rgb,
};

/// The current look, byte-identical to the pre-theme literals (plus the
/// markdown heading's `.{252,211,77}` folded in from `message.zig`).
pub const default_theme: Theme = .{
    .name = "default",
    .thinking_blue = .{ 96, 165, 250 },
    .user_yellow = .{ 212, 175, 55 },
    .success_green = .{ 34, 197, 94 },
    .failure_red = .{ 239, 68, 68 },
    .accent_orange = .{ 249, 115, 22 },
    .skill_purple = .{ 168, 85, 247 },
    .lane_pink = .{ 244, 114, 182 },
    .muted_gray = .{ 138, 138, 138 },
    .selection_bg = .{ 38, 38, 38 },
    .amber_yellow = .{ 245, 158, 11 },
    .white = .{ 255, 255, 255 },
    .code_blue = .{ 147, 197, 253 },
    .faint_add_bg = .{ 22, 43, 30 },
    .faint_del_bg = .{ 52, 27, 27 },
    .body = .{ 255, 255, 255 },
    .background = .{ 17, 17, 20 },
    .blackhole_orange = .{ 255, 106, 61 },
    .markdown_heading = .{ 252, 211, 77 },
};

/// A Catppuccin Mocha variant, user-facing name "cappuccino".
pub const cappuccino_theme: Theme = .{
    .name = "cappuccino",
    .thinking_blue = .{ 137, 180, 250 }, // blue
    .user_yellow = .{ 249, 226, 175 }, // yellow
    .success_green = .{ 166, 227, 161 }, // green
    .failure_red = .{ 243, 139, 168 }, // red
    .accent_orange = .{ 250, 179, 135 }, // peach
    .skill_purple = .{ 203, 166, 247 }, // mauve
    .lane_pink = .{ 245, 194, 231 }, // pink
    .muted_gray = .{ 147, 153, 178 }, // overlay2
    .selection_bg = .{ 49, 50, 68 }, // surface0
    .amber_yellow = .{ 249, 226, 175 }, // yellow
    .white = .{ 205, 214, 244 }, // text
    .code_blue = .{ 148, 226, 213 }, // teal
    .faint_add_bg = .{ 40, 59, 47 },
    .faint_del_bg = .{ 62, 46, 54 },
    .body = .{ 205, 214, 244 }, // text
    .background = .{ 17, 17, 27 }, // crust
    .blackhole_orange = .{ 250, 179, 135 }, // peach
    .markdown_heading = .{ 249, 226, 175 }, // yellow
};

/// Tokyo Night (dark) — https://github.com/enkia/tokyo-night-vscode-theme
pub const tokyo_night: Theme = .{
    .name = "tokyo_night",
    .thinking_blue = .{ 122, 162, 247 }, // blue
    .user_yellow = .{ 224, 175, 104 }, // yellow
    .success_green = .{ 158, 206, 106 }, // green
    .failure_red = .{ 247, 118, 142 }, // red
    .accent_orange = .{ 255, 158, 100 }, // orange
    .skill_purple = .{ 187, 154, 247 }, // magenta
    .lane_pink = .{ 255, 0, 124 }, // magenta2
    .muted_gray = .{ 86, 95, 137 }, // comment
    .selection_bg = .{ 41, 46, 66 }, // bg_highlight
    .amber_yellow = .{ 224, 175, 104 }, // yellow
    .white = .{ 192, 202, 245 }, // fg
    .code_blue = .{ 137, 221, 255 }, // blue5
    .faint_add_bg = .{ 30, 44, 40 }, // derived: green-tinted bg
    .faint_del_bg = .{ 52, 34, 42 }, // derived: red-tinted bg
    .body = .{ 192, 202, 245 }, // fg
    .background = .{ 26, 27, 38 }, // bg
    .blackhole_orange = .{ 255, 158, 100 }, // orange
    .markdown_heading = .{ 224, 175, 104 }, // yellow
};

/// Dracula — https://draculatheme.com/contribute
pub const dracula: Theme = .{
    .name = "dracula",
    .thinking_blue = .{ 139, 233, 253 }, // cyan
    .user_yellow = .{ 241, 250, 140 }, // yellow
    .success_green = .{ 80, 250, 123 }, // green
    .failure_red = .{ 255, 85, 85 }, // red
    .accent_orange = .{ 255, 184, 108 }, // orange
    .skill_purple = .{ 189, 147, 249 }, // purple
    .lane_pink = .{ 255, 121, 198 }, // pink
    .muted_gray = .{ 98, 114, 164 }, // comment
    .selection_bg = .{ 68, 71, 90 }, // currentLine
    .amber_yellow = .{ 241, 250, 140 }, // yellow
    .white = .{ 248, 248, 242 }, // foreground
    .code_blue = .{ 139, 233, 253 }, // cyan
    .faint_add_bg = .{ 36, 52, 42 }, // derived: green-tinted bg
    .faint_del_bg = .{ 58, 40, 45 }, // derived: red-tinted bg
    .body = .{ 248, 248, 242 }, // foreground
    .background = .{ 40, 42, 54 }, // background
    .blackhole_orange = .{ 255, 184, 108 }, // orange
    .markdown_heading = .{ 241, 250, 140 }, // yellow
};

/// Nord — https://www.nordtheme.com/docs/colors-and-palettes
pub const nord: Theme = .{
    .name = "nord",
    .thinking_blue = .{ 136, 192, 208 }, // nord8 frost cyan
    .user_yellow = .{ 235, 203, 139 }, // nord13 aurora yellow
    .success_green = .{ 163, 190, 140 }, // nord14 aurora green
    .failure_red = .{ 191, 97, 106 }, // nord11 aurora red
    .accent_orange = .{ 208, 135, 112 }, // nord12 aurora orange
    .skill_purple = .{ 180, 142, 173 }, // nord15 aurora purple
    .lane_pink = .{ 207, 138, 155 }, // derived rose (no nord pink)
    .muted_gray = .{ 76, 86, 106 }, // nord3
    .selection_bg = .{ 67, 76, 94 }, // nord2
    .amber_yellow = .{ 235, 203, 139 }, // nord13 aurora yellow
    .white = .{ 236, 239, 244 }, // nord6 snow storm
    .code_blue = .{ 129, 161, 193 }, // nord9 frost blue
    .faint_add_bg = .{ 46, 55, 47 }, // derived: green-tinted bg
    .faint_del_bg = .{ 61, 47, 49 }, // derived: red-tinted bg
    .body = .{ 236, 239, 244 }, // nord6 snow storm
    .background = .{ 46, 52, 64 }, // nord0 polar night
    .blackhole_orange = .{ 208, 135, 112 }, // nord12 aurora orange
    .markdown_heading = .{ 235, 203, 139 }, // nord13 aurora yellow
};

/// Gruvbox Dark — https://github.com/morhetz/gruvbox (dark, bright accents)
pub const gruvbox_dark: Theme = .{
    .name = "gruvbox_dark",
    .thinking_blue = .{ 131, 165, 152 }, // blue
    .user_yellow = .{ 250, 189, 47 }, // yellow
    .success_green = .{ 184, 187, 38 }, // bright green
    .failure_red = .{ 251, 73, 52 }, // bright red
    .accent_orange = .{ 254, 128, 25 }, // bright orange
    .skill_purple = .{ 211, 134, 155 }, // purple
    .lane_pink = .{ 219, 137, 150 }, // derived rose (no gruvbox pink)
    .muted_gray = .{ 146, 131, 116 }, // gray
    .selection_bg = .{ 60, 56, 54 }, // bg1
    .amber_yellow = .{ 250, 189, 47 }, // yellow
    .white = .{ 251, 241, 199 }, // fg0 warm cream
    .code_blue = .{ 131, 165, 152 }, // blue
    .faint_add_bg = .{ 46, 55, 35 }, // derived: green-tinted bg
    .faint_del_bg = .{ 66, 44, 38 }, // derived: red-tinted bg
    .body = .{ 251, 241, 199 }, // fg0 warm cream
    .background = .{ 29, 32, 33 }, // bg0
    .blackhole_orange = .{ 214, 93, 14 }, // dark0+ burnt orange
    .markdown_heading = .{ 250, 189, 47 }, // yellow
};

const themes = [_]Theme{ default_theme, cappuccino_theme, tokyo_night, dracula, nord, gruvbox_dark };

/// The authoritative builtin theme list, in canonical order. Exposed for the
/// theme picker so it lists exactly the themes `resolveTheme` validates
/// against — a single source of truth, never a duplicated literal.
pub fn allThemes() []const Theme {
    return themes[0..];
}

/// Resolve a user-supplied theme name to a `Theme`. Case-insensitive;
/// unknown, empty, and `null` names fall back to `default_theme`. Theme-name
/// validation lives here (a UI concern), not in `config.validate`.
pub fn resolveTheme(name: ?[]const u8) Theme {
    const n = name orelse return default_theme;
    for (themes) |t| if (std.ascii.eqlIgnoreCase(n, t.name)) return t;
    return default_theme;
}

/// The runtime palette: every style the widgets draw with. Instance fields so
/// the whole UI can be recolored by rebuilding it from a different `Theme`.
pub const Palette = struct {
    selected: vaxis.Style,
    selected_item: vaxis.Style,
    user: vaxis.Style,
    skill: vaxis.Style,
    tool: vaxis.Style,
    tool_failed: vaxis.Style,
    success: vaxis.Style,
    notice: vaxis.Style,
    warning: vaxis.Style,
    error_style: vaxis.Style,
    info: vaxis.Style,
    border_label: vaxis.Style,
    background_badge: vaxis.Style,
    lanes_badge: vaxis.Style,
    model_status: vaxis.Style,
    thinking_label: vaxis.Style,
    thinking_body: vaxis.Style,
    body: vaxis.Style,
    background: vaxis.Style,
    intro_accent: vaxis.Style,
    checkpoint: vaxis.Style,
    checkpoint_mark: vaxis.Style,
    thinking_bar: vaxis.Style,
    markdown_code: vaxis.Style,
    panel_header: vaxis.Style,
    diff_file_header: vaxis.Style,
    diff_hunk: vaxis.Style,
    diff_gutter: vaxis.Style,
    diff_bracket: vaxis.Style,
    diff_comment: vaxis.Style,
    diff_bracket_active: vaxis.Style,
    diff_comment_active: vaxis.Style,
    diff_added_row: vaxis.Style,
    diff_removed_row: vaxis.Style,
    diff_inline_del: vaxis.Style,
    diff_inline_add: vaxis.Style,
    // Newly centralized stray literals:
    markdown_heading: vaxis.Style,
    settings_active_tab: vaxis.Style,
    permission_approve: vaxis.Style,
};

/// Derive the full runtime palette from a theme. For `default_theme` this
/// reproduces the exact pre-theme styles. Pure and comptime-evaluable, so it
/// is valid as the global `active` initializer.
pub fn buildPalette(theme: Theme) Palette {
    return .{
        .selected = .{ .bg = .{ .rgb = theme.selection_bg } },
        .selected_item = .{ .fg = .{ .rgb = theme.accent_orange }, .bg = .{ .rgb = theme.selection_bg } },

        .user = .{ .fg = .{ .rgb = theme.user_yellow }, .italic = true },
        .skill = .{ .fg = .{ .rgb = theme.skill_purple }, .bold = true },
        .tool = .{ .fg = .{ .rgb = theme.success_green } },
        .tool_failed = .{ .fg = .{ .rgb = theme.failure_red } },
        .success = .{ .fg = .{ .rgb = theme.success_green } },
        .notice = .{ .fg = .{ .rgb = theme.amber_yellow } },
        .warning = .{ .fg = .{ .rgb = theme.amber_yellow }, .bold = true },
        // Toast error accent — the failure red, bold so it reads as an error.
        .error_style = .{ .fg = .{ .rgb = theme.failure_red }, .bold = true },
        .info = .{ .fg = .{ .rgb = theme.white } },
        .border_label = .{ .fg = .{ .rgb = theme.accent_orange } },
        // Bottom-left background-jobs badge: black text on the thinking-blue
        // fill, so the live-job count reads as a status pill, not body text.
        .background_badge = .{ .fg = .{ .rgb = .{ 0, 0, 0 } }, .bg = .{ .rgb = theme.thinking_blue } },
        .lanes_badge = .{ .fg = .{ .rgb = .{ 0, 0, 0 } }, .bg = .{ .rgb = theme.lane_pink } },
        .model_status = .{ .fg = .{ .rgb = theme.thinking_blue } },
        .thinking_label = .{ .fg = .{ .rgb = theme.thinking_blue } },
        .thinking_body = .{ .fg = .{ .rgb = theme.muted_gray } },
        .body = .{ .fg = .{ .rgb = theme.body } },
        .background = .{ .bg = .{ .rgb = theme.background } },
        .intro_accent = .{ .fg = .{ .rgb = theme.blackhole_orange } },
        .checkpoint = .{ .fg = .{ .rgb = theme.thinking_blue } },
        .checkpoint_mark = .{ .fg = .{ .rgb = theme.code_blue } },
        .thinking_bar = .{ .fg = .{ .rgb = theme.thinking_blue } },
        .markdown_code = .{ .fg = .{ .rgb = theme.code_blue } },
        .panel_header = .{ .fg = .{ .rgb = theme.white } },

        .diff_file_header = .{ .fg = .{ .rgb = theme.code_blue }, .bold = true },
        .diff_hunk = .{ .fg = .{ .rgb = theme.muted_gray }, .dim = true },
        .diff_gutter = .{ .fg = .{ .rgb = theme.muted_gray }, .dim = true },
        .diff_bracket = .{ .fg = .{ .rgb = theme.white } },
        .diff_comment = .{ .fg = .{ .rgb = theme.white }, .italic = true },
        .diff_bracket_active = .{ .fg = .{ .rgb = theme.user_yellow }, .bold = true },
        .diff_comment_active = .{ .fg = .{ .rgb = theme.user_yellow }, .bold = true },
        .diff_added_row = .{ .bg = .{ .rgb = theme.faint_add_bg } },
        .diff_removed_row = .{ .bg = .{ .rgb = theme.faint_del_bg } },
        .diff_inline_del = .{ .fg = .{ .rgb = theme.failure_red }, .bg = .{ .rgb = theme.faint_del_bg } },
        .diff_inline_add = .{ .fg = .{ .rgb = theme.success_green }, .bg = .{ .rgb = theme.faint_add_bg } },

        .markdown_heading = .{ .bold = true, .fg = .{ .rgb = theme.markdown_heading } },
        .settings_active_tab = .{ .fg = .{ .rgb = theme.accent_orange }, .ul_style = .single, .bold = true },
        .permission_approve = .{ .fg = .{ .rgb = theme.success_green }, .bold = true },
    };
}

/// Cheap perceptual-contrast check: max-channel absolute delta between two RGBs.
/// A floor here is a soft guard that theme data actually keeps readable
/// foreground-on-background pairs, far below any real gap.
fn contrastFloor(a: Rgb, b: Rgb) u16 {
    const r: u16 = @intCast(@abs(@as(i16, a[0]) - @as(i16, b[0])));
    const g: u16 = @intCast(@abs(@as(i16, a[1]) - @as(i16, b[1])));
    const bl: u16 = @intCast(@abs(@as(i16, a[2]) - @as(i16, b[2])));
    return @max(r, @max(g, bl));
}

/// The active runtime palette, installed once at startup by `tui.run`. Render
/// is single-threaded on the UI thread; mutations happen only there.
pub var active: Palette = buildPalette(default_theme);

/// Fetch a pointer to the active palette for reading during draw.
pub fn activePalette() *const Palette {
    return &active;
}

/// Rebuild the active palette from a theme. Called on the UI thread only.
pub fn setActive(theme: Theme) void {
    active = buildPalette(theme);
}

/// Merge a selection background into a row style when the row is selected.
pub fn onSelectionBg(style: vaxis.Style, selected: bool) vaxis.Style {
    var merged = style;
    if (selected) merged.bg = active.selected.bg;
    return merged;
}

pub fn mergedSelectedStyle(style: vaxis.Style, selected: bool) vaxis.Style {
    var merged = style;
    if (!selected) merged.dim = true;
    return merged;
}

test "resolveTheme falls back to default for null, empty, unknown" {
    try std.testing.expectEqual(default_theme, resolveTheme(null));
    try std.testing.expectEqual(default_theme, resolveTheme(""));
    try std.testing.expectEqual(default_theme, resolveTheme("bogus"));
}

test "resolveTheme matches case-insensitively" {
    try std.testing.expectEqual(cappuccino_theme, resolveTheme("Cappuccino"));
    try std.testing.expectEqual(cappuccino_theme, resolveTheme("CAPPUCCINO"));
}

test "buildPalette(default_theme) preserves the original look" {
    // Spot-check the pre-theme literals: thinking_blue on the thinking label,
    // user_yellow on user rows, and the folded-in markdown heading yellow.
    const p = buildPalette(default_theme);
    try std.testing.expectEqual(@as(Rgb, .{ 96, 165, 250 }), p.thinking_label.fg.rgb);
    try std.testing.expectEqual(@as(Rgb, .{ 212, 175, 55 }), p.user.fg.rgb);
    try std.testing.expectEqual(@as(Rgb, .{ 252, 211, 77 }), p.markdown_heading.fg.rgb);
    // The three new defaults: agent body = white, card = near-black,
    // intro accent = unchanged orange.
    try std.testing.expectEqual(@as(Rgb, .{ 255, 255, 255 }), p.body.fg.rgb);
    try std.testing.expectEqual(@as(Rgb, .{ 17, 17, 20 }), p.background.bg.rgb);
    try std.testing.expectEqual(@as(Rgb, .{ 255, 106, 61 }), p.intro_accent.fg.rgb);
}

test "palette body/background derive per-theme" {
    // Pure derivation round-trip: each new palette style comes from its theme slot.
    const p = buildPalette(nord);
    try std.testing.expectEqual(nord.body, p.body.fg.rgb);
    try std.testing.expectEqual(nord.background, p.background.bg.rgb);
    try std.testing.expectEqual(nord.blackhole_orange, p.intro_accent.fg.rgb);
}

test "every theme's body/background stays readable (min channel contrast)" {
    for (themes) |t| {
        // body vs background: near-white on a dark card → far above any floor.
        try std.testing.expect(contrastFloor(t.body, t.background) > 60);
        // selection_bg vs background must differ so a selected picker row is
        // visible against a coincident card.
        try std.testing.expect(contrastFloor(t.selection_bg, t.background) > 8);
    }
}

test "themes array has unique non-empty names" {
    var seen: [16][]const u8 = undefined; // max themes (bounded by the array)
    var seen_count: usize = 0;
    for (themes) |t| {
        try std.testing.expect(t.name.len > 0);
        for (seen[0..seen_count]) |prev| {
            try std.testing.expect(!std.mem.eql(u8, prev, t.name));
        }
        seen[seen_count] = t.name;
        seen_count += 1;
    }
}

test "resolveTheme matches each builtin theme case-insensitively" {
    const cases = [_]struct { name: []const u8, theme: Theme }{
        .{ .name = "default", .theme = default_theme },
        .{ .name = "cappuccino", .theme = cappuccino_theme },
        .{ .name = "Tokyo_Night", .theme = tokyo_night },
        .{ .name = "TOKYO_NIGHT", .theme = tokyo_night },
        .{ .name = "Dracula", .theme = dracula },
        .{ .name = "DRACULA", .theme = dracula },
        .{ .name = "nord", .theme = nord },
        .{ .name = "NORD", .theme = nord },
        .{ .name = "gruvbox_dark", .theme = gruvbox_dark },
        .{ .name = "GRUVBOX_DARK", .theme = gruvbox_dark },
    };
    for (cases) |c| try std.testing.expectEqual(c.theme, resolveTheme(c.name));
}

test "spaced theme names do not match (underscore convention)" {
    try std.testing.expectEqual(default_theme, resolveTheme("Tokyo Night"));
    try std.testing.expectEqual(default_theme, resolveTheme("Gruvbox Dark"));
}

test "allThemes returns the exact builtin set with unique non-empty names" {
    const list = allThemes();
    try std.testing.expectEqual(@as(usize, 6), list.len);
    const expected = [_][]const u8{ "default", "cappuccino", "tokyo_night", "dracula", "nord", "gruvbox_dark" };
    for (list, expected) |theme, name| {
        try std.testing.expectEqualStrings(name, theme.name);
        try std.testing.expect(theme.name.len > 0);
    }
    // Names must be pairwise unique (an earlier duplicate would make the
    // picker's current-theme highlight ambiguous).
    var seen: [16][]const u8 = undefined;
    var seen_count: usize = 0;
    for (list) |t| {
        for (seen[0..seen_count]) |prev| {
            try std.testing.expect(!std.mem.eql(u8, prev, t.name));
        }
        seen[seen_count] = t.name;
        seen_count += 1;
    }
}
