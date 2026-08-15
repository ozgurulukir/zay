const std = @import("std");
const vaxis = @import("vaxis");
const log = std.log.scoped(.tui);

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
    const trimmed = std.mem.trim(u8, n, " \t\r\n");
    if (trimmed.len == 0) return default_theme;
    for (themes) |t| if (std.ascii.eqlIgnoreCase(trimmed, t.name)) return t;
    return default_theme;
}

/// Parse a user theme from a JSON object. Comptime-driven over `Theme`'s 18
/// `Rgb` slots, so adding a future color slot requires no parser change; only
/// `name` is special-cased (an owned string). Validation is parity with the
/// builtin suite (`style.zig:410-418`): body/background WCAG contrast >= 4.5
/// and a `selection_bg`/`background` channel delta >= 20 so a selected picker
/// row stays visible against a coincident card.
pub fn parseThemeJson(gpa: std.mem.Allocator, value: std.json.Value) !Theme {
    if (value != .object) return error.InvalidTheme;
    var theme: Theme = undefined;

    const name_val = value.object.get("name") orelse return error.InvalidTheme;
    if (name_val != .string) return error.InvalidTheme;
    if (name_val.string.len == 0) return error.InvalidTheme;
    theme.name = try gpa.dupe(u8, name_val.string);
    errdefer gpa.free(theme.name);

    inline for (@typeInfo(Theme).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "name")) continue;
        if (field.type != Rgb) continue;
        const color_val = value.object.get(field.name) orelse return error.InvalidTheme;
        if (color_val != .array) return error.InvalidTheme;
        if (color_val.array.items.len != 3) return error.InvalidTheme;
        var rgb: Rgb = undefined;
        for (color_val.array.items, 0..) |channel, i| {
            if (channel != .integer) return error.InvalidTheme;
            if (channel.integer < 0 or channel.integer > 255) return error.InvalidTheme;
            rgb[i] = @intCast(channel.integer);
        }
        @field(theme, field.name) = rgb;
    }

    if (contrastRatio(theme.body, theme.background) < 4.5) {
        log.warn("theme '{s}' rejected: body/background contrast below 4.5:1", .{theme.name});
        return error.InsufficientContrast;
    }
    if (maxChannelDelta(theme.selection_bg, theme.background) < 20) {
        log.warn("theme '{s}' rejected: selection_bg/background channel delta below 20", .{theme.name});
        return error.InsufficientContrast;
    }
    return theme;
}

/// The registry-aware theme catalogue: the 6 builtins seeded by `init` (gpa
/// only), then user JSON themes loaded by `loadCustom` from the standard
/// directories (or an explicit `customThemesDir`, which replaces the default
/// scan — m5). `slice()`/`resolve()` are the registry-aware views; the pure
/// `resolveTheme` stays for builtins/tests. Custom theme `name`s are owned and
/// freed via `custom_names` — builtin names are static and never freed.
pub const ThemeRegistry = struct {
    all_themes: std.ArrayList(Theme) = .empty,
    custom_names: std.ArrayList([]const u8) = .empty,

    /// Seed the 6 builtins. Needs only `gpa` (no `io`/paths), so `App.init`
    /// and tests can build a non-empty registry without a runtime. A missing
    /// themes dir is a no-op, never a startup failure.
    pub fn init(gpa: std.mem.Allocator) !ThemeRegistry {
        var registry: ThemeRegistry = .{};
        errdefer registry.deinit(gpa);
        for (allThemes()) |theme| try registry.all_themes.append(gpa, theme);
        return registry;
    }

    /// Scan custom theme JSON files. When `custom_themes_dir` is set it
    /// REPLACES the default scan (m5); otherwise scan `~/.config/nova/themes/`
    /// and `<cwd>/.nova/themes/`. Missing directories are a no-op.
    pub fn loadCustom(self: *ThemeRegistry, gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, cwd: []const u8, custom_themes_dir: ?[]const u8) !void {
        if (custom_themes_dir) |dir| {
            try self.loadThemesFromDir(gpa, io, dir);
            return;
        }
        const home_path = try std.fs.path.join(gpa, &.{ home_dir, ".config", "nova", "themes" });
        defer gpa.free(home_path);
        try self.loadThemesFromDir(gpa, io, home_path);
        const cwd_path = try std.fs.path.join(gpa, &.{ cwd, ".nova", "themes" });
        defer gpa.free(cwd_path);
        try self.loadThemesFromDir(gpa, io, cwd_path);
    }

    pub fn deinit(self: *ThemeRegistry, gpa: std.mem.Allocator) void {
        for (self.custom_names.items) |name| gpa.free(name);
        self.custom_names.deinit(gpa);
        self.all_themes.deinit(gpa);
        self.* = undefined;
    }

    pub fn slice(self: *const ThemeRegistry) []const Theme {
        return self.all_themes.items;
    }

    /// Resolve a theme name over the full catalogue (builtins + custom),
    /// case-insensitive; unknown/empty/null fall back to `default_theme`.
    pub fn resolve(self: *const ThemeRegistry, name: ?[]const u8) Theme {
        const n = name orelse return default_theme;
        const trimmed = std.mem.trim(u8, n, " \t\r\n");
        if (trimmed.len == 0) return default_theme;
        for (self.all_themes.items) |t| {
            if (std.ascii.eqlIgnoreCase(trimmed, t.name)) return t;
        }
        return default_theme;
    }

    fn loadThemesFromDir(self: *ThemeRegistry, gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
        if (dir_path.len == 0) return;
        var dir = std.Io.Dir.openDir(.cwd(), io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            const file_path = std.fs.path.join(gpa, &.{ dir_path, entry.name }) catch continue;
            defer gpa.free(file_path);
            self.loadThemeFile(gpa, io, file_path) catch continue;
        }
    }

    fn loadThemeFile(self: *ThemeRegistry, gpa: std.mem.Allocator, io: std.Io, file_path: []const u8) !void {
        const file = std.Io.Dir.openFile(.cwd(), io, file_path, .{}) catch return;
        defer file.close(io);
        const stat = file.stat(io) catch return;
        if (stat.size <= 0) {
            log.warn("theme file {s}: empty, skipped", .{file_path});
            return;
        }
        if (stat.size > 64 * 1024) {
            log.warn("theme file {s}: {d} bytes exceeds the 64KB cap, skipped", .{ file_path, stat.size });
            return;
        }
        const bytes = try gpa.alloc(u8, @intCast(stat.size));
        defer gpa.free(bytes);
        var reader = file.reader(io, &.{});
        const n = try reader.interface.readSliceShort(bytes);
        const source = bytes[0..n];
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, source, .{}) catch |err| {
            log.warn("theme file {s}: invalid JSON ({s}), skipped", .{ file_path, @errorName(err) });
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            log.warn("theme file {s}: top-level value is not an object, skipped", .{file_path});
            return;
        }
        const theme = parseThemeJson(gpa, parsed.value) catch |err| {
            log.warn("theme file {s}: rejected ({s}), skipped", .{ file_path, @errorName(err) });
            return;
        };
        try self.appendCustom(gpa, theme);
    }

    /// Append a parsed custom theme, transferring ownership of its duped name
    /// to `custom_names` so `deinit` frees exactly the owned names.
    fn appendCustom(self: *ThemeRegistry, gpa: std.mem.Allocator, theme: Theme) !void {
        self.custom_names.append(gpa, theme.name) catch |err| {
            gpa.free(theme.name);
            return err;
        };
        self.all_themes.append(gpa, theme) catch |err| {
            const name = self.custom_names.pop().?;
            gpa.free(name);
            return err;
        };
    }
};

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

/// Absolute maximum single-channel delta between two RGB colors.
pub fn maxChannelDelta(a: Rgb, b: Rgb) u16 {
    const r: u16 = @intCast(@abs(@as(i16, a[0]) - @as(i16, b[0])));
    const g: u16 = @intCast(@abs(@as(i16, a[1]) - @as(i16, b[1])));
    const bl: u16 = @intCast(@abs(@as(i16, a[2]) - @as(i16, b[2])));
    return @max(r, @max(g, bl));
}

/// Convert an 8-bit sRGB channel (0..255) to linear light intensity (0.0..1.0).
fn linearizeChannel(c: u8) f32 {
    const s: f32 = @as(f32, @floatFromInt(c)) / 255.0;
    if (s <= 0.04045) {
        return s / 12.92;
    } else {
        return std.math.pow(f32, (s + 0.055) / 1.055, 2.4);
    }
}

/// Calculate the WCAG 2.1 relative luminance of an sRGB color (0.0 = black, 1.0 = white).
pub fn relativeLuminance(rgb: Rgb) f32 {
    const r = linearizeChannel(rgb[0]);
    const g = linearizeChannel(rgb[1]);
    const b = linearizeChannel(rgb[2]);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// Calculate the WCAG 2.1 contrast ratio between two colors (range: 1.0 to 21.0).
pub fn contrastRatio(a: Rgb, b: Rgb) f32 {
    const l1 = relativeLuminance(a);
    const l2 = relativeLuminance(b);
    const lighter = @max(l1, l2);
    const darker = @min(l1, l2);
    return (lighter + 0.05) / (darker + 0.05);
}

/// The active runtime palette, installed once at startup by `tui.run`.
///
/// Thread Safety Invariant:
/// - `active` is a mutable global read and written EXCLUSIVELY on the main UI/event-loop thread.
/// - Background workers, lanes, and HTTP streams MUST NOT read or mutate `active`.
/// - Render passes are synchronous on the UI thread and consume `activePalette()`.
/// - Unit tests modifying `active` via `setActive` MUST restore `default_theme` via `defer setActive(default_theme)`.
pub var active: Palette = buildPalette(default_theme);

/// Fetch a pointer to the active palette for reading during UI draw passes.
/// Must only be called from the UI thread.
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
    try std.testing.expectEqual(default_theme, resolveTheme("   "));
    try std.testing.expectEqual(default_theme, resolveTheme("bogus"));
}

test "resolveTheme trims whitespace" {
    try std.testing.expectEqual(tokyo_night, resolveTheme("  tokyo_night  "));
    try std.testing.expectEqual(dracula, resolveTheme("\t\nDRACULA\r "));
    try std.testing.expectEqual(default_theme, resolveTheme("   \t\r\n  "));
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

test "WCAG relative luminance and contrast ratio calculations" {
    // Black (0,0,0) luminance is 0.0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), relativeLuminance(.{ 0, 0, 0 }), 0.0001);
    // White (255,255,255) luminance is 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), relativeLuminance(.{ 255, 255, 255 }), 0.0001);
    // Contrast ratio between pure white and pure black is 21.0:1
    try std.testing.expectApproxEqAbs(@as(f32, 21.0), contrastRatio(.{ 0, 0, 0 }, .{ 255, 255, 255 }), 0.01);
    // Same color contrast ratio is 1.0:1
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), contrastRatio(.{ 128, 128, 128 }, .{ 128, 128, 128 }), 0.0001);
}

test "every theme's body/background stays readable (WCAG contrast and channel delta)" {
    for (themes) |t| {
        // body vs background: WCAG AA contrast ratio >= 4.5:1
        try std.testing.expect(contrastRatio(t.body, t.background) >= 4.5);
        // selection_bg vs background must differ significantly so a selected picker row is
        // visible against a coincident card.
        try std.testing.expect(maxChannelDelta(t.selection_bg, t.background) >= 20);
    }
}

test "buildPalette exhaustively references every Theme color slot" {
    const probe_theme: Theme = .{
        .name = "probe",
        .thinking_blue = .{ 1, 0, 0 },
        .user_yellow = .{ 2, 0, 0 },
        .success_green = .{ 3, 0, 0 },
        .failure_red = .{ 4, 0, 0 },
        .accent_orange = .{ 5, 0, 0 },
        .skill_purple = .{ 6, 0, 0 },
        .lane_pink = .{ 7, 0, 0 },
        .muted_gray = .{ 8, 0, 0 },
        .selection_bg = .{ 9, 0, 0 },
        .amber_yellow = .{ 10, 0, 0 },
        .white = .{ 11, 0, 0 },
        .code_blue = .{ 12, 0, 0 },
        .faint_add_bg = .{ 13, 0, 0 },
        .faint_del_bg = .{ 14, 0, 0 },
        .body = .{ 15, 0, 0 },
        .background = .{ 16, 0, 0 },
        .blackhole_orange = .{ 17, 0, 0 },
        .markdown_heading = .{ 18, 0, 0 },
    };

    const palette = buildPalette(probe_theme);
    const palette_fields = @typeInfo(Palette).@"struct".fields;

    // Verify slots 1..18 are each referenced in at least one Palette style
    inline for (1..19) |slot_tag| {
        var found = false;
        inline for (palette_fields) |field| {
            const style: vaxis.Style = @field(palette, field.name);
            switch (style.fg) {
                .rgb => |rgb| if (rgb[0] == slot_tag) {
                    found = true;
                },
                else => {},
            }
            switch (style.bg) {
                .rgb => |rgb| if (rgb[0] == slot_tag) {
                    found = true;
                },
                else => {},
            }
        }
        try std.testing.expect(found);
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

/// A structurally valid user-theme JSON (default_theme's values) with the
/// three validation-relevant slots parameterized: `body`, `background`, and
/// `selection_bg`. Used by the parseThemeJson tests to drive the contrast and
/// channel-delta rejection paths.
fn validThemeJson(gpa: std.mem.Allocator, name: []const u8, body: Rgb, background: Rgb, selection_bg: Rgb) ![]const u8 {
    const fmt =
        \\{{"name":"{s}","thinking_blue":[96,165,250],"user_yellow":[212,175,55],"success_green":[34,197,94],"failure_red":[239,68,68],"accent_orange":[249,115,22],"skill_purple":[168,85,247],"lane_pink":[244,114,182],"muted_gray":[138,138,138],"selection_bg":[{d},{d},{d}],"amber_yellow":[245,158,11],"white":[255,255,255],"code_blue":[147,197,253],"faint_add_bg":[22,43,30],"faint_del_bg":[52,27,27],"body":[{d},{d},{d}],"background":[{d},{d},{d}],"blackhole_orange":[255,106,61],"markdown_heading":[252,211,77]}}
    ;
    return std.fmt.allocPrint(gpa, fmt, .{ name, selection_bg[0], selection_bg[1], selection_bg[2], body[0], body[1], body[2], background[0], background[1], background[2] });
}

/// Like `validThemeJson` but with a caller-supplied raw `selection_bg` array
/// (e.g. `"[1,2]"` or `"[1,2,\"x\"]"`), for the malformed-array rejection tests.
fn themeJsonWithSelection(gpa: std.mem.Allocator, name: []const u8, selection_bg: []const u8) ![]const u8 {
    const fmt =
        \\{{"name":"{s}","thinking_blue":[96,165,250],"user_yellow":[212,175,55],"success_green":[34,197,94],"failure_red":[239,68,68],"accent_orange":[249,115,22],"skill_purple":[168,85,247],"lane_pink":[244,114,182],"muted_gray":[138,138,138],"selection_bg":{s},"amber_yellow":[245,158,11],"white":[255,255,255],"code_blue":[147,197,253],"faint_add_bg":[22,43,30],"faint_del_bg":[52,27,27],"body":[{d},{d},{d}],"background":[{d},{d},{d}],"blackhole_orange":[255,106,61],"markdown_heading":[252,211,77]}}
    ;
    return std.fmt.allocPrint(gpa, fmt, .{ name, selection_bg, default_theme.body[0], default_theme.body[1], default_theme.body[2], default_theme.background[0], default_theme.background[1], default_theme.background[2] });
}

test "parseThemeJson round-trips a valid JSON theme" {
    const gpa = std.testing.allocator;
    const json = try validThemeJson(gpa, "my_theme", default_theme.body, default_theme.background, default_theme.selection_bg);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const theme = try parseThemeJson(gpa, parsed.value);
    defer gpa.free(theme.name);
    try std.testing.expectEqualStrings("my_theme", theme.name);
    try std.testing.expectEqual(default_theme.body, theme.body);
    try std.testing.expectEqual(default_theme.selection_bg, theme.selection_bg);
    try std.testing.expectEqual(default_theme.markdown_heading, theme.markdown_heading);
}

test "parseThemeJson rejects a missing name" {
    const gpa = std.testing.allocator;
    const json = "{\"body\":[255,255,255],\"background\":[17,17,20]}";
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidTheme, parseThemeJson(gpa, parsed.value));
}

test "parseThemeJson rejects a short RGB array" {
    const gpa = std.testing.allocator;
    const json = try themeJsonWithSelection(gpa, "short", "[1,2]");
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidTheme, parseThemeJson(gpa, parsed.value));
}

test "parseThemeJson rejects a non-integer array element" {
    const gpa = std.testing.allocator;
    const json = try themeJsonWithSelection(gpa, "mixed", "[1,2,\"x\"]");
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidTheme, parseThemeJson(gpa, parsed.value));
}

test "parseThemeJson rejects low body/background contrast" {
    const gpa = std.testing.allocator;
    // body == background → contrast 1.0, below the 4.5:1 floor.
    const json = try validThemeJson(gpa, "low_contrast", .{ 255, 255, 255 }, .{ 255, 255, 255 }, .{ 38, 38, 38 });
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InsufficientContrast, parseThemeJson(gpa, parsed.value));
}

test "parseThemeJson rejects low selection_bg/background channel delta (m6)" {
    const gpa = std.testing.allocator;
    // body/background pass contrast (white on black) but selection_bg equals
    // background → channel delta 0, below the 20 floor.
    const json = try validThemeJson(gpa, "low_selection", .{ 255, 255, 255 }, .{ 0, 0, 0 }, .{ 0, 0, 0 });
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InsufficientContrast, parseThemeJson(gpa, parsed.value));
}

test "ThemeRegistry.init seeds the 6 builtins (gpa only)" {
    const gpa = std.testing.allocator;
    var registry = try ThemeRegistry.init(gpa);
    defer registry.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 6), registry.slice().len);
    try std.testing.expectEqualStrings("default", registry.slice()[0].name);
    try std.testing.expectEqualStrings("gruvbox_dark", registry.slice()[5].name);
}

test "ThemeRegistry.loadCustom with missing dirs is a no-op (n2)" {
    // First-run / Windows path: a nonexistent themes dir must not error or
    // panic — only the builtins remain.
    const gpa = std.testing.allocator;
    var registry = try ThemeRegistry.init(gpa);
    defer registry.deinit(gpa);
    try registry.loadCustom(gpa, std.testing.io, "/nonexistent/home", "/nonexistent/cwd", null);
    try std.testing.expectEqual(@as(usize, 6), registry.slice().len);
}

test "ThemeRegistry.loadCustom loads a custom theme and resolve finds it case-insensitively" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);
    const themes_path = try std.fs.path.join(gpa, &.{ home_dir, ".config", "nova", "themes" });
    defer gpa.free(themes_path);
    try std.Io.Dir.createDirPath(.cwd(), io, themes_path);
    const file_path = try std.fs.path.join(gpa, &.{ themes_path, "my_theme.json" });
    defer gpa.free(file_path);
    const contents = try validThemeJson(gpa, "my_theme", default_theme.body, default_theme.background, default_theme.selection_bg);
    defer gpa.free(contents);
    {
        var file = try std.Io.Dir.createFile(.cwd(), io, file_path, .{ .truncate = true });
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writer.interface.writeAll(contents);
        try writer.interface.flush();
    }

    var registry = try ThemeRegistry.init(gpa);
    defer registry.deinit(gpa);
    try registry.loadCustom(gpa, io, home_dir, "/nonexistent/cwd", null);
    try std.testing.expectEqual(@as(usize, 7), registry.slice().len);
    // Case-insensitive resolve finds the custom slug.
    const resolved = registry.resolve("MY_THEME");
    try std.testing.expectEqualStrings("my_theme", resolved.name);
}

test "ThemeRegistry.loadCustom customThemesDir replaces the default scan (m5)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A theme in the default location (home/.config/nova/themes)…
    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);
    const default_themes = try std.fs.path.join(gpa, &.{ home_dir, ".config", "nova", "themes" });
    defer gpa.free(default_themes);
    try std.Io.Dir.createDirPath(.cwd(), io, default_themes);
    const default_file = try std.fs.path.join(gpa, &.{ default_themes, "from_default.json" });
    defer gpa.free(default_file);
    const default_contents = try validThemeJson(gpa, "from_default", default_theme.body, default_theme.background, default_theme.selection_bg);
    defer gpa.free(default_contents);
    {
        var file = try std.Io.Dir.createFile(.cwd(), io, default_file, .{ .truncate = true });
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writer.interface.writeAll(default_contents);
        try writer.interface.flush();
    }

    // …and a separate explicit custom dir.
    const custom_dir = try std.fs.path.join(gpa, &.{ home_dir, "custom-themes" });
    defer gpa.free(custom_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, custom_dir);
    const custom_file = try std.fs.path.join(gpa, &.{ custom_dir, "from_custom.json" });
    defer gpa.free(custom_file);
    const custom_contents = try validThemeJson(gpa, "from_custom", default_theme.body, default_theme.background, default_theme.selection_bg);
    defer gpa.free(custom_contents);
    {
        var file = try std.Io.Dir.createFile(.cwd(), io, custom_file, .{ .truncate = true });
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writer.interface.writeAll(custom_contents);
        try writer.interface.flush();
    }

    var registry = try ThemeRegistry.init(gpa);
    defer registry.deinit(gpa);
    // Setting customThemesDir scans ONLY that dir — the default-location theme
    // is ignored.
    try registry.loadCustom(gpa, io, home_dir, "/nonexistent/cwd", custom_dir);
    try std.testing.expectEqual(@as(usize, 7), registry.slice().len);
    try std.testing.expect(registry.resolve("from_custom").name.len > 0);
    try std.testing.expectEqual(default_theme, registry.resolve("from_default"));
}
