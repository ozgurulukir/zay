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
const agent_mod = @import("../agent.zig");
const runtime_mod = @import("../runtime.zig");

const App = tui.App;

/// Open the interactive theme picker, seeding the selection at the row of the
/// currently-active theme so the current look is the one highlighted on open.
pub fn openThemePicker(app: *App) void {
    app.mode = .theme_picker;
    app.clearInput();
    app.clearPaletteInput();
    const active_name = tui_style.resolveTheme(app.cached_config.theme).name;
    app.pickers.theme.selection = 0;
    for (tui_style.allThemes(), 0..) |theme, index| {
        if (std.mem.eql(u8, theme.name, active_name)) {
            app.pickers.theme.selection = @intCast(index);
            break;
        }
    }
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
/// rebuild the live palette, persist the canonical slug to the project config
/// (if project config defines `theme`) or global config otherwise, reconcile
/// `cached_config.theme`, and post the transcript notices.
///
/// `setActive` cannot fail; config persistence errors are swallowed to `warn`
/// (never crash). The only error this can propagate is `error.OutOfMemory`
/// from the dupes/allocPrint — a last-resort guard for callers.
pub fn applyTheme(app: *App, raw_name: []const u8) !void {
    const theme = tui_style.resolveTheme(raw_name);
    tui_style.setActive(theme);

    var persist_err: ?anyerror = null;
    if (app.liveRuntime()) |rt| {
        // The canonical slug is always non-empty, so `serialize` will write it.
        var updates: config_mod.Config = .{};
        defer updates.deinit(app.gpa);
        updates.theme = try app.gpa.dupe(u8, theme.name);

        var is_project_theme = false;
        if (config_mod.readProject(app.gpa, app.io, rt.cwd)) |proj_cfg| {
            var mut_proj = proj_cfg;
            defer mut_proj.deinit(app.gpa);
            if (mut_proj.theme != null) {
                is_project_theme = true;
            }
        } else |_| {}

        if (is_project_theme) {
            config_mod.mergeAndWriteProject(app.gpa, app.io, rt.cwd, updates) catch |err| {
                log.warn("theme.persist.project.failed err={s}", .{@errorName(err)});
                persist_err = err;
            };
        } else {
            config_mod.mergeAndWriteGlobal(app.gpa, app.io, rt.home_dir, updates) catch |err| {
                log.warn("theme.persist.global.failed err={s}", .{@errorName(err)});
                persist_err = err;
            };
        }
    }

    // Reconcile the in-memory value so a later read matches what we persisted.
    if (app.cached_config_owned) {
        if (app.cached_config.theme) |old| app.gpa.free(old);
        app.cached_config.theme = try app.gpa.dupe(u8, theme.name);
    }

    // User notification reflecting persistence status
    if (persist_err == null) {
        const changed = std.fmt.allocPrint(app.gpa, "Theme switched to {s}", .{theme.name}) catch return error.OutOfMemory;
        defer app.gpa.free(changed);
        _ = app.thread.transcript.append(app.gpa, .success, "theme", changed) catch return error.OutOfMemory;
    } else {
        const changed = std.fmt.allocPrint(app.gpa, "Theme switched to {s} (not saved)", .{theme.name}) catch return error.OutOfMemory;
        defer app.gpa.free(changed);
        _ = app.thread.transcript.append(app.gpa, .notice, "theme", changed) catch return error.OutOfMemory;
    }

    // Fallback notification for invalid / unknown / typoed theme names
    const trimmed = std.mem.trim(u8, raw_name, " \t\r\n");
    if (!std.ascii.eqlIgnoreCase(trimmed, theme.name)) {
        const fallback = std.fmt.allocPrint(app.gpa, "Theme '{s}' not found; using default", .{trimmed}) catch return error.OutOfMemory;
        defer app.gpa.free(fallback);
        _ = app.thread.transcript.append(app.gpa, .notice, "theme", fallback) catch return error.OutOfMemory;
    }
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

test "parseThemeArg handles whitespace and tabs" {
    try std.testing.expectEqualStrings("cappuccino", parseThemeArg("/theme    cappuccino   ").?);
    try std.testing.expectEqualStrings("nord", parseThemeArg("theme \t nord \r\n").?);
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

test "openThemePicker clears inputs and selects active theme" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.cached_config.theme = @constCast("dracula");
    try app.inputs.input.insertSliceAtCursor("some prompt text");
    try app.inputs.palette.insertSliceAtCursor("filter text");

    openThemePicker(&app);

    try std.testing.expectEqual(.theme_picker, app.mode);
    const in_text = try app.peekInput();
    defer gpa.free(in_text);
    try std.testing.expectEqual(@as(usize, 0), in_text.len);

    const pal_len = app.inputs.palette.buf.firstHalf().len + app.inputs.palette.buf.secondHalf().len;
    try std.testing.expectEqual(@as(usize, 0), pal_len);

    // Dracula is at index 3 in themes array [default, cappuccino, tokyo_night, dracula, nord, gruvbox_dark]
    try std.testing.expectEqual(@as(u32, 3), app.pickers.theme.selection);
}

test "applyTheme updates live palette, cached_config_owned, and transcript" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    defer tui_style.setActive(tui_style.default_theme);

    app.cached_config_owned = true;
    app.cached_config.theme = try gpa.dupe(u8, "default");

    try applyTheme(&app, "cappuccino");

    // Palette updated
    try std.testing.expectEqual(tui_style.cappuccino_theme.body, tui_style.activePalette().body.fg.rgb);
    // Cached config updated
    try std.testing.expectEqualStrings("cappuccino", app.cached_config.theme.?);
    // Transcript has success notice
    try std.testing.expect(app.thread.transcript.messages.items.len > 0);
    const last_row = app.thread.transcript.messages.items[app.thread.transcript.messages.items.len - 1].mirror();
    try std.testing.expectEqualStrings("Theme switched to cappuccino", last_row.body);
    try std.testing.expectEqual(.success, last_row.kind);
}

test "applyTheme with cached_config_owned=false does not alter cached_config.theme" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    defer tui_style.setActive(tui_style.default_theme);

    app.cached_config_owned = false;
    app.cached_config.theme = null;

    try applyTheme(&app, "dracula");

    // Palette is updated
    try std.testing.expectEqual(tui_style.dracula.body, tui_style.activePalette().body.fg.rgb);
    // Cached config remained null because cached_config_owned was false
    try std.testing.expect(app.cached_config.theme == null);
}

test "applyTheme persists to project config when project defines theme" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);

    const proj_dir = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path, "proj" });
    defer gpa.free(proj_dir);
    const home_dir = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path, "home" });
    defer gpa.free(home_dir);

    // Initial project config with theme="cappuccino"
    var initial_proj: config_mod.Config = .{};
    defer initial_proj.deinit(gpa);
    initial_proj.theme = try gpa.dupe(u8, "cappuccino");
    try config_mod.writeProject(gpa, std.testing.io, proj_dir, initial_proj);

    // Initial global config with theme="default"
    var initial_global: config_mod.Config = .{};
    defer initial_global.deinit(gpa);
    initial_global.theme = try gpa.dupe(u8, "default");
    try config_mod.writeGlobal(gpa, std.testing.io, home_dir, initial_global);

    var agent = agent_mod.Agent.init(gpa, std.testing.io, proj_dir, .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    defer tui_style.setActive(tui_style.default_theme);

    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.cwd = proj_dir;
    runtime.home_dir = home_dir;
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };

    try applyTheme(&app, "nord");

    // Project config should have been updated to "nord"
    var read_proj = try config_mod.readProject(gpa, std.testing.io, proj_dir);
    defer read_proj.deinit(gpa);
    try std.testing.expectEqualStrings("nord", read_proj.theme.?);

    // Global config should have remained "default"
    var read_global = try config_mod.readGlobal(gpa, std.testing.io, home_dir);
    defer read_global.deinit(gpa);
    try std.testing.expectEqualStrings("default", read_global.theme.?);
}

test "applyTheme persists to global config when project does not define theme" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);

    const proj_dir = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path, "proj" });
    defer gpa.free(proj_dir);
    const home_dir = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path, "home" });
    defer gpa.free(home_dir);

    // Initial project config without theme
    var initial_proj: config_mod.Config = .{};
    defer initial_proj.deinit(gpa);
    initial_proj.system_prompt = try gpa.dupe(u8, "custom prompt");
    try config_mod.writeProject(gpa, std.testing.io, proj_dir, initial_proj);

    // Initial global config with theme="default"
    var initial_global: config_mod.Config = .{};
    defer initial_global.deinit(gpa);
    initial_global.theme = try gpa.dupe(u8, "default");
    try config_mod.writeGlobal(gpa, std.testing.io, home_dir, initial_global);

    var agent = agent_mod.Agent.init(gpa, std.testing.io, proj_dir, .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    defer tui_style.setActive(tui_style.default_theme);

    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.cwd = proj_dir;
    runtime.home_dir = home_dir;
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };

    try applyTheme(&app, "tokyo_night");

    // Global config should be updated to "tokyo_night"
    var read_global = try config_mod.readGlobal(gpa, std.testing.io, home_dir);
    defer read_global.deinit(gpa);
    try std.testing.expectEqualStrings("tokyo_night", read_global.theme.?);

    // Project config should still not have a theme
    var read_proj = try config_mod.readProject(gpa, std.testing.io, proj_dir);
    defer read_proj.deinit(gpa);
    try std.testing.expect(read_proj.theme == null);
}

test "applyTheme surfaces (not saved) notice when persistence fails" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);

    // Create a regular file so attempting to create subdirectories under it fails cleanly with NotDir
    {
        var file = try tmp.dir.createFile(std.testing.io, "blocker_file", .{});
        file.close(std.testing.io);
    }
    const blocker_path = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path, "blocker_file" });
    defer gpa.free(blocker_path);

    var agent = agent_mod.Agent.init(gpa, std.testing.io, blocker_path, .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    defer tui_style.setActive(tui_style.default_theme);

    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.cwd = blocker_path;
    runtime.home_dir = blocker_path;
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };

    try applyTheme(&app, "gruvbox_dark");

    // Live palette is still updated
    try std.testing.expectEqual(tui_style.gruvbox_dark.body, tui_style.activePalette().body.fg.rgb);

    // Transcript has the "(not saved)" notice
    const count = app.thread.transcript.messages.items.len;
    try std.testing.expect(count > 0);
    const last = app.thread.transcript.messages.items[count - 1].mirror();
    try std.testing.expectEqualStrings("Theme switched to gruvbox_dark (not saved)", last.body);
    try std.testing.expectEqual(.notice, last.kind);
}

test "applyTheme fallback notice behavior for default vs unknown themes" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    defer tui_style.setActive(tui_style.default_theme);

    // 1. Explicit "default" theme: only success message, no fallback notice
    try applyTheme(&app, "default");
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqualStrings("Theme switched to default", app.thread.transcript.messages.items[0].mirror().body);
    try std.testing.expectEqual(.success, app.thread.transcript.messages.items[0].mirror().kind);

    // 2. Unknown theme: success message for default fallback AND fallback notice
    try applyTheme(&app, "nonexistent_theme");
    try std.testing.expectEqual(@as(usize, 3), app.thread.transcript.messages.items.len);
    try std.testing.expectEqualStrings("Theme switched to default", app.thread.transcript.messages.items[1].mirror().body);
    try std.testing.expectEqual(.success, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqualStrings("Theme 'nonexistent_theme' not found; using default", app.thread.transcript.messages.items[2].mirror().body);
    try std.testing.expectEqual(.notice, app.thread.transcript.messages.items[2].mirror().kind);
}
