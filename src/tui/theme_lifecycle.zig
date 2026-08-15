//! Theme mode lifecycle — open/close/apply/parse for the `/theme` overlay
//! and the `/theme <name>` inline fast-path.
//!
//! Keeps all theme mutation in one place so `tui.zig`, `mode_lifecycle.zig`,
//! and `command_router.zig` stay thin: they just delegate here. `setActive`
//! is UI-thread-only, and every caller below runs on the UI thread.

const std = @import("std");
const log = std.log.scoped(.tui);
const tui = @import("../tui.zig");
const config_mod = @import("../config/config.zig");
const tui_style = @import("style.zig");

const App = tui.App;

/// Open the interactive theme picker, seeding the selection at the row of the
/// currently-active theme so the current look is the one highlighted on open.
pub fn openThemePicker(app: *App) void {
    app.mode = .theme_picker;
    const active_name = tui_style.resolveTheme(app.cached_config.theme).name;
    app.pickers.theme.selection = 0;
    for (tui_style.allThemes(), 0..) |theme, index| {
        if (std.mem.eql(u8, theme.name, active_name)) {
            app.pickers.theme.selection = @intCast(index);
            break;
        }
    }
    app.clearInput();
    app.clearPaletteInput();
}

/// Dismiss the theme picker. Esc fallthrough in `cancelMode` reaches the
/// generic default (`mode = .normal`; clear inputs) even without this, but the
/// explicit close keeps the symmetry with the other picker lifecycle fns.
pub fn closeThemePicker(app: *App) void {
    app.mode = .normal;
    app.clearInput();
    app.clearPaletteInput();
}

/// Parse a `/theme <name>` argument from the palette value. The leading `/`
/// is optional (the palette filter in `.command` mode drops it). Returns the
/// non-empty name token, or null when the value is not a `theme <name>` form:
/// a bare `theme`, an empty arg, a trailing-space-only arg, or any value that
/// starts with a different command name (`/model`, `/themplate`). The command
/// token itself is case-insensitive (`THEME DRACULA` works).
pub fn parseThemeArg(filter: []const u8) ?[]const u8 {
    var value = filter;
    // Optionally strip a leading '/'.
    if (value.len > 0 and value[0] == '/') value = value[1..];
    value = std.mem.trimStart(u8, value, " \t");
    if (value.len < 5) return null;
    if (!std.ascii.eqlIgnoreCase(value[0..5], "theme")) return null;
    // A bare `theme` or a command whose name merely *starts* with `theme`
    // (themplate, them… ) must not be treated as a `/theme <name>` form.
    if (value.len == 5) return null;
    if (value[5] != ' ' and value[5] != '\t') return null;
    const arg = std.mem.trim(u8, value[5..], " \t\r\n");
    if (arg.len == 0) return null;
    return arg;
}

/// Apply a theme by name: resolve (falling back to default on unknown names),
/// rebuild the live palette, persist the canonical slug to the global config,
/// reconcile `cached_config.theme`, and post the transcript notices.
///
/// `setActive` cannot fail; config persistence errors are swallowed to `warn`
/// (never crash). The only error this can propagate is `error.OutOfMemory`
/// from the dupes/allocPrint — a last-resort guard for callers.
pub fn applyTheme(app: *App, raw_name: []const u8) !void {
    const theme = tui_style.resolveTheme(raw_name);
    tui_style.setActive(theme);

    // The canonical slug is always non-empty, so `serialize` will write it.
    var updates: config_mod.Config = .{};
    defer updates.deinit(app.gpa);
    updates.theme = try app.gpa.dupe(u8, theme.name);
    if (app.liveRuntime()) |rt| {
        config_mod.mergeAndWriteGlobal(app.gpa, app.io, rt.home_dir, updates) catch |err| {
            // Poisonous? No — degrade to a live-only switch, warn, notice below.
            log.warn("theme.persist.failed err={s}", .{@errorName(err)});
        };
    }

    // Reconcile the in-memory value so a later read matches what we persisted.
    if (app.cached_config_owned) {
        if (app.cached_config.theme) |old| app.gpa.free(old);
        app.cached_config.theme = try app.gpa.dupe(u8, theme.name);
    }

    // Tell the user the theme changed.
    const changed = std.fmt.allocPrint(app.gpa, "Theme switched to {s}", .{theme.name}) catch return error.OutOfMemory;
    defer app.gpa.free(changed);
    _ = app.thread.transcript.append(app.gpa, .success, "theme", changed) catch return error.OutOfMemory;

    // Warn about a fallback-to-default on an unknown name, unless the user
    // literally asked for "default" (which is a real, unchanged choice).
    if (theme.name.len == 0 or !std.mem.eql(u8, theme.name, "default")) return;
    const trimmed = std.mem.trim(u8, raw_name, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "default")) return;
    const fallback = std.fmt.allocPrint(app.gpa, "Theme '{s}' not found; using default", .{trimmed}) catch return error.OutOfMemory;
    defer app.gpa.free(fallback);
    _ = app.thread.transcript.append(app.gpa, .notice, "theme", fallback) catch return error.OutOfMemory;
}

/// Report a failure to switch the theme. The only error `applyTheme` can
/// propagate is OOM, so this is a last-resort notice, not a primary path.
pub fn reportThemeError(app: *App, err: anyerror) !void {
    app.mode = .normal;
    app.clearInput();
    var buf: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "Failed to switch theme: {s}", .{@errorName(err)}) catch "Failed to switch theme";
    _ = try app.thread.transcript.append(app.gpa, .notice, "theme", message);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseThemeArg returns the argument for theme <name> forms" {
    try std.testing.expectEqualStrings("tokyo_night", parseThemeArg("/theme tokyo_night").?);
    try std.testing.expectEqualStrings("tokyo_night", parseThemeArg("theme tokyo_night").?);
    try std.testing.expectEqualStrings("gruvbox_dark", parseThemeArg("/theme gruvbox_dark").?);
}

test "parseThemeArg is case-insensitive for the command token" {
    try std.testing.expectEqualStrings("DRACULA", parseThemeArg("THEME DRACULA").?);
}

test "parseThemeArg returns null for bare, empty, or unrelated filters" {
    try std.testing.expect(parseThemeArg("") == null);
    try std.testing.expect(parseThemeArg("/theme") == null);
    try std.testing.expect(parseThemeArg("theme") == null);
    try std.testing.expect(parseThemeArg("theme ") == null);
    try std.testing.expect(parseThemeArg("/model") == null);
    try std.testing.expect(parseThemeArg("/themplate") == null);
    try std.testing.expect(parseThemeArg("/them") == null);
}

test "applyTheme resolution: unknown names resolve to default_theme" {
    // The apply-path resolution contract: an unknown name resolves to the
    // default theme (matching `resolveTheme`), so the fallback notice fires.
    const resolved = tui_style.resolveTheme("no_such_theme");
    try std.testing.expectEqual(tui_style.resolveTheme(null).name, resolved.name);
    try std.testing.expectEqualStrings("default", resolved.name);
}
