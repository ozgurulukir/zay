//! Settings mode lifecycle — key handling, toggle logic, and config
//! persistence for the `/settings` overlay.
//!
//! Keeps all settings-related mutation in one place so `tui.zig` and
//! `command_router.zig` stay thin: they just delegate here.

const std = @import("std");
const log = std.log.scoped(.tui);
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");
const config_mod = @import("../config/config.zig");
const settings_widget = @import("widgets/settings.zig");
const toast = @import("toast.zig");

const App = tui.App;
const State = settings_widget.State;
const Tab = settings_widget.Tab;
const EditTarget = settings_widget.EditTarget;

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------

/// Check if pending values differ from current config values. A null
/// pending means "not touched"; an empty-string pending means "cleared"
/// and compares as a change against any non-empty current value.
fn hasActualChanges(state: *const State, config: *const config_mod.Config) bool {
    if (state.pending_use_responses_endpoint) |v| {
        const current_value = if (config.model_selection) |ms| ms.useResponsesEndpoint() else config.use_responses_endpoint orelse false;
        if (v != current_value) return true;
    }
    if (state.pending_system_prompt) |s| {
        const current_value = if (config.model_selection) |ms| ms.systemPrompt() else config.system_prompt;
        const current_prompt = current_value orelse "";
        if (!std.mem.eql(u8, s, current_prompt)) return true;
    }
    if (state.pending_bash_classifier_url) |s| {
        const current_value = if (config.model_selection) |ms| ms.bashClassifierUrl() else config.bash_classifier_url;
        const current_url = current_value orelse "";
        if (!std.mem.eql(u8, s, current_url)) return true;
    }
    if (state.pending_toast_enabled) |v| {
        if (v != (config.toast.enabled orelse true)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/// User-facing validation messages, shared by the commit-time (Enter) and
/// save-time (Ctrl+S) checks so both surfaces say exactly the same thing.
const url_invalid_msg = "URL must start with http:// or https://";
const url_too_long_msg = "URL is too long (max 2048 characters)";
const prompt_too_long_msg = std.fmt.comptimePrint("System prompt is too long (max {d} characters)", .{config_mod.max_system_prompt_chars});

/// Validate bash classifier URL format.
fn validateBashClassifierUrl(url: []const u8) !void {
    if (url.len == 0) return;
    // Must start with http:// or https://
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return error.InvalidUrl;
    }
    // Basic length check
    if (url.len > 2048) return error.UrlTooLong;
}

/// Validate system prompt content. Counts UTF-8 code points to match the
/// parser's drop rule (`parse.max_system_prompt_chars`): a byte-length check
/// would falsely reject a CJK prompt three bytes per char.
fn validateSystemPrompt(prompt: []const u8) !void {
    const len_chars = std.unicode.utf8CountCodepoints(prompt) catch prompt.len;
    if (len_chars > config_mod.max_system_prompt_chars) {
        return error.PromptTooLong;
    }
}

// ---------------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------------

pub fn openSettings(app: *App) void {
    // Free any unsaved pendings from a previous visit: the widget's
    // reset() clears state without an allocator, so this is the only
    // place the owned strings can be released.
    if (app.pickers.settings.pending_system_prompt) |old| app.gpa.free(old);
    if (app.pickers.settings.pending_bash_classifier_url) |old| app.gpa.free(old);
    app.mode = .settings;
    app.pickers.settings.reset();
    app.clearInput();
    app.clearPaletteInput();
}

pub fn closeSettings(app: *App) void {
    app.mode = .normal;
    app.clearInput();
    app.clearPaletteInput();
}

// ---------------------------------------------------------------------------
// Enter key — toggle or begin editing
// ---------------------------------------------------------------------------

pub fn submitSettings(app: *App) !void {
    const state = &app.pickers.settings;
    switch (state.tab) {
        .general => try submitGeneralItem(app, state),
        .prompt => submitPromptItem(app, state),
        .advanced => submitAdvancedItem(app, state),
        .about => {}, // read-only
    }
}

fn submitGeneralItem(app: *App, state: *State) !void {
    switch (state.selection[@intFromEnum(Tab.general)]) {
        0 => {
            // Toggle use_responses_endpoint.
            const current = state.pending_use_responses_endpoint orelse
                (if (app.cached_config.model_selection) |ms| ms.useResponsesEndpoint() else app.cached_config.use_responses_endpoint orelse false);
            const new_value = !current;
            state.pending_use_responses_endpoint = new_value;
            // Only mark dirty if the new value differs from the config
            const config_value = if (app.cached_config.model_selection) |ms| ms.useResponsesEndpoint() else app.cached_config.use_responses_endpoint orelse false;
            state.dirty = (new_value != config_value);
        },
        1 => {
            // Toggle toast notifications.
            const current = state.pending_toast_enabled orelse
                (app.cached_config.toast.enabled orelse true);
            const new_value = !current;
            state.pending_toast_enabled = new_value;
            const config_value = app.cached_config.toast.enabled orelse true;
            state.dirty = (new_value != config_value);
        },
        else => {},
    }
}

fn submitPromptItem(app: *App, state: *State) void {
    switch (state.selection[@intFromEnum(Tab.prompt)]) {
        0 => {
            // Enter edit mode for system prompt.
            state.edit_target = .system_prompt;
            const current = if (app.cached_config.model_selection) |ms|
                (ms.systemPrompt() orelse "")
            else
                "";
            app.input_buffers.settings_text.clearRetainingCapacity();
            app.input_buffers.settings_text.appendSlice(app.gpa, current) catch {};
        },
        else => {},
    }
}

fn submitAdvancedItem(app: *App, state: *State) void {
    switch (state.selection[@intFromEnum(Tab.advanced)]) {
        0 => {
            // Enter edit mode for bash_classifier_url.
            state.edit_target = .bash_classifier_url;
            const current = if (app.cached_config.model_selection) |ms|
                (ms.bashClassifierUrl() orelse "")
            else
                "";
            app.input_buffers.settings_text.clearRetainingCapacity();
            app.input_buffers.settings_text.appendSlice(app.gpa, current) catch {};
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Delete key — clear a text field
// ---------------------------------------------------------------------------

pub fn clearCurrentField(app: *App) void {
    const state = &app.pickers.settings;
    switch (state.tab) {
        .prompt => {
            // "Cleared" is the empty string, NOT null: a null pending means
            // "not touched" and never reaches the save path.
            const cleared = app.gpa.dupe(u8, "") catch return;
            if (state.pending_system_prompt) |old| app.gpa.free(old);
            state.pending_system_prompt = cleared;
            state.dirty = hasActualChanges(state, &app.cached_config);
        },
        .advanced => {
            const cleared = app.gpa.dupe(u8, "") catch return;
            if (state.pending_bash_classifier_url) |old| app.gpa.free(old);
            state.pending_bash_classifier_url = cleared;
            state.dirty = hasActualChanges(state, &app.cached_config);
        },
        .general, .about => {},
    }
}

// ---------------------------------------------------------------------------
// Ctrl+S — save pending changes
// ---------------------------------------------------------------------------

/// Save all pending settings to the global config file (and the project
/// config if one exists) and update the live cached_config. Returns true
/// if anything was written.
///
/// Only writes the fields that the settings panel manages
/// (use_responses_endpoint, system_prompt, bash_classifier_url). Provider
/// and model selection are managed by the model picker, not here — cloning
/// the merged model_selection would leak project-level overrides into the
/// global config.
pub fn saveSettings(app: *App) !bool {
    const state = &app.pickers.settings;
    if (!state.dirty and state.edit_target == .none) return false;

    // Flush any in-progress text edit before saving.
    if (state.edit_target != .none) try commitTextEdit(app);

    // Check if there are actual changes vs just toggling back.
    if (!hasActualChanges(state, &app.cached_config)) {
        // No real changes, just reset pending state (freeing what the
        // pendings own — the success path below frees them the same way).
        state.dirty = false;
        state.pending_use_responses_endpoint = null;
        if (state.pending_system_prompt) |old| app.gpa.free(old);
        state.pending_system_prompt = null;
        if (state.pending_bash_classifier_url) |old| app.gpa.free(old);
        state.pending_bash_classifier_url = null;
        state.pending_toast_enabled = null;
        _ = try app.thread.transcript.append(app.gpa, .info, "Settings", "No changes to save");
        return false;
    }

    // Validate inputs before saving.
    if (state.pending_bash_classifier_url) |url| {
        validateBashClassifierUrl(url) catch |err| {
            log.warn("settings.validation.url_failed err={s}", .{@errorName(err)});
            const msg = switch (err) {
                error.InvalidUrl => url_invalid_msg,
                error.UrlTooLong => url_too_long_msg,
            };
            _ = try app.thread.transcript.append(app.gpa, .notice, "Settings", msg);
            return false;
        };
    }
    if (state.pending_system_prompt) |prompt| {
        validateSystemPrompt(prompt) catch |err| {
            log.warn("settings.validation.prompt_failed err={s}", .{@errorName(err)});
            const msg = switch (err) {
                error.PromptTooLong => prompt_too_long_msg,
            };
            _ = try app.thread.transcript.append(app.gpa, .notice, "Settings", msg);
            return false;
        };
    }

    // Build updates with only the fields the settings panel manages.
    // Do NOT clone model_selection from cached_config — that would
    // copy project-level provider/model overrides into the global config.
    var updates: config_mod.Config = .{};
    defer updates.deinit(app.gpa);
    if (state.pending_use_responses_endpoint) |v| {
        updates.use_responses_endpoint = v;
    }
    if (state.pending_system_prompt) |s| {
        // "" flows through as the clear marker (see applyTextOverlay in
        // parse.zig); mapping it to null would silently skip the clear.
        updates.system_prompt = try app.gpa.dupe(u8, s);
    }
    if (state.pending_bash_classifier_url) |s| {
        // Same clear-marker contract as the prompt above.
        updates.bash_classifier_url = try app.gpa.dupe(u8, s);
    }
    if (state.pending_toast_enabled) |v| {
        updates.toast.enabled = v;
    }

    const runtime = app.liveRuntime() orelse return false;

    // Write to global config only. Settings are user-level preferences,
    // not project-specific configuration. Provider/model selection can be
    // project-specific, but use_responses_endpoint, system_prompt, etc. should
    // apply globally across all projects.
    config_mod.mergeAndWriteGlobal(app.gpa, app.io, runtime.home_dir, updates) catch |err| {
        log.warn("settings.save.failed err={s}", .{@errorName(err)});
        var buf: [256]u8 = undefined;
        // The merge refuses to rewrite a config whose on-disk values would
        // be dropped by the loader (error.ConfigRoundTripLoss) — say that
        // instead of the raw error name.
        const msg = if (err == error.ConfigRoundTripLoss)
            "config.json contains values that would be dropped on load — fix the file and save again"
        else
            std.fmt.bufPrint(&buf, "Failed to save settings: {s}", .{@errorName(err)}) catch "Failed to save settings";
        _ = try app.thread.transcript.append(app.gpa, .notice, "Settings", msg);
        return false;
    };

    // Update the live cached_config so the running agent picks up the
    // changes without a restart.
    try applyToCachedConfig(app, state);
    app.mcp_manager.syncFromConfig(app.io, &app.cached_config) catch {};

    // Apply the toast toggle live to the global bus.
    if (state.pending_toast_enabled) |v| toast.global.enabled = v;

    // Reset pending state.
    if (state.pending_system_prompt) |old| app.gpa.free(old);
    if (state.pending_bash_classifier_url) |old| app.gpa.free(old);
    state.dirty = false;
    state.pending_use_responses_endpoint = null;
    state.pending_system_prompt = null;
    state.pending_bash_classifier_url = null;
    state.pending_toast_enabled = null;
    state.edit_target = .none;

    // Show success feedback to user.
    _ = try app.thread.transcript.append(app.gpa, .success, "Settings", "Settings saved successfully");

    return true;
}

fn commitTextEdit(app: *App) !void {
    const state = &app.pickers.settings;
    const text = app.input_buffers.settings_text.items;
    switch (state.edit_target) {
        .system_prompt => {
            // Validate before committing; the editor stays open with the
            // text intact, so surface why nothing was committed instead of
            // refusing silently.
            validateSystemPrompt(text) catch |err| {
                log.warn("settings.validation.prompt_failed err={s}", .{@errorName(err)});
                _ = try app.thread.transcript.append(app.gpa, .notice, "Settings", prompt_too_long_msg);
                return;
            };
            // Allocate BEFORE freeing the old value: on OOM the pending
            // field must keep pointing at memory the reset paths can free.
            // An empty buffer commits as "" — the "cleared" marker.
            const next_prompt: []u8 = try app.gpa.dupe(u8, text);
            if (state.pending_system_prompt) |old| app.gpa.free(old);
            state.pending_system_prompt = next_prompt;
            state.dirty = true;
        },
        .bash_classifier_url => {
            // Validate before committing; same surfacing rule as above.
            validateBashClassifierUrl(text) catch |err| {
                log.warn("settings.validation.url_failed err={s}", .{@errorName(err)});
                const msg = switch (err) {
                    error.InvalidUrl => url_invalid_msg,
                    error.UrlTooLong => url_too_long_msg,
                };
                _ = try app.thread.transcript.append(app.gpa, .notice, "Settings", msg);
                return;
            };
            // Same alloc-before-free order as above.
            const next_url: ?[]u8 = try app.gpa.dupe(u8, text);
            if (state.pending_bash_classifier_url) |old| app.gpa.free(old);
            state.pending_bash_classifier_url = next_url;
            state.dirty = true;
        },
        .none => {},
    }
    state.edit_target = .none;
    app.input_buffers.settings_text.clearRetainingCapacity();
}

/// Mirror of `applyTextOverlay`'s contract (parse.zig) for the in-memory
/// cached config: a null pending means "not touched", an empty pending
/// clears the field, anything else replaces it. Inlined per field here
/// because the cached config lives outside parse.zig's overlay path.
fn applyPendingText(gpa: std.mem.Allocator, target: *?[]u8, pending: ?[]const u8) !void {
    const s = pending orelse return;
    const next: ?[]u8 = if (s.len > 0) try gpa.dupe(u8, s) else null;
    if (target.*) |old| gpa.free(old);
    target.* = next;
}

fn applyToCachedConfig(app: *App, state: *const State) !void {
    if (!app.cached_config_owned) return;
    if (app.cached_config.model_selection) |*ms| {
        // Model selection exists: update it directly
        switch (ms.*) {
            .builtin => |*b| {
                if (state.pending_use_responses_endpoint) |v| b.use_responses_endpoint = v;
                try applyPendingText(app.gpa, &b.system_prompt, state.pending_system_prompt);
                try applyPendingText(app.gpa, &b.bash_classifier_url, state.pending_bash_classifier_url);
            },
            .custom => |*c| {
                if (state.pending_use_responses_endpoint) |v| c.use_responses_endpoint = v;
                try applyPendingText(app.gpa, &c.system_prompt, state.pending_system_prompt);
                try applyPendingText(app.gpa, &c.bash_classifier_url, state.pending_bash_classifier_url);
            },
        }
    } else {
        // Legacy config: update legacy fields directly
        if (state.pending_use_responses_endpoint) |v| app.cached_config.use_responses_endpoint = v;
        try applyPendingText(app.gpa, &app.cached_config.system_prompt, state.pending_system_prompt);
        try applyPendingText(app.gpa, &app.cached_config.bash_classifier_url, state.pending_bash_classifier_url);
        // Sync legacy field updates to model_selection for consistency
        try config_mod.syncModelSelectionFromLegacy(app.gpa, &app.cached_config);
    }
    // Toast toggle applies regardless of model_selection shape.
    if (state.pending_toast_enabled) |v| app.cached_config.toast.enabled = v;
}

// ---------------------------------------------------------------------------
// Escape — cancel text edit or close
// ---------------------------------------------------------------------------

pub fn cancelSettings(app: *App) void {
    const state = &app.pickers.settings;
    if (state.edit_target != .none) {
        state.edit_target = .none;
        app.input_buffers.settings_text.clearRetainingCapacity();
        return;
    }
    closeSettings(app);
}

// ---------------------------------------------------------------------------
// Text editing key handling (when edit_target != .none)
// ---------------------------------------------------------------------------

/// Returns true when the key was consumed by the text editor.
/// When edit_target is .none this function returns false immediately.
pub fn handleTextEditKey(app: *App, key: vaxis.Key) !bool {
    const state = &app.pickers.settings;
    if (state.edit_target == .none) return false;

    if (key.matches(vaxis.Key.escape, .{})) {
        // Cancel — discard changes.
        state.edit_target = .none;
        app.input_buffers.settings_text.clearRetainingCapacity();
        return true;
    }
    if (key.matches('s', .{ .ctrl = true })) {
        // Ctrl+S while editing: commit, and only save when the commit
        // landed — a failed validation keeps the editor open and must not
        // run saveSettings' re-validation (it would append the same notice
        // a second time).
        try commitTextEdit(app);
        if (state.edit_target == .none) _ = try saveSettings(app);
        return true;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (state.edit_target == .system_prompt) {
            try app.input_buffers.settings_text.append(app.gpa, '\n');
            return true;
        }
        // Enter commits the text edit without saving to disk (user must
        // press Ctrl+S to persist). This gives a chance to edit multiple
        // fields before saving.
        try commitTextEdit(app);
        return true;
    }
    if (key.matches(vaxis.Key.backspace, .{})) {
        popSettingsTextInput(app);
        return true;
    }
    if (key.text) |text| {
        if (text.len > 0) {
            try app.input_buffers.settings_text.appendSlice(app.gpa, text);
            return true;
        }
    } else if (key.codepoint >= 32 and key.codepoint <= 126 and
        !key.mods.ctrl and !key.mods.alt and !key.mods.super)
    {
        const byte: u8 = @intCast(key.codepoint);
        try app.input_buffers.settings_text.append(app.gpa, byte);
        return true;
    }
    // Swallow all remaining keys while in text-edit mode so they do not
    // propagate to the structural navigation handlers.
    return true;
}

fn popSettingsTextInput(app: *App) void {
    const items = app.input_buffers.settings_text.items;
    if (items.len == 0) return;
    // Walk back over continuation bytes to preserve UTF-8 codepoint boundary.
    var cut = items.len - 1;
    while (cut > 0 and (items[cut] & 0xC0) == 0x80) cut -= 1;
    app.input_buffers.settings_text.shrinkRetainingCapacity(cut);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const agent_mod = @import("../agent.zig");

test "handleTextEditKey Enter inserts newline for system_prompt" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Set up text editing mode for system prompt
    app.mode = .settings;
    app.pickers.settings.edit_target = .system_prompt;

    // Simulate Enter key
    const handled = try handleTextEditKey(&app, .{ .codepoint = vaxis.Key.enter, .mods = .{} });

    // It should have handled the key, the mode should still be system_prompt, and the buffer should have a newline
    try std.testing.expect(handled);
    try std.testing.expect(app.pickers.settings.edit_target == .system_prompt);
    try std.testing.expectEqualStrings("\n", app.input_buffers.settings_text.items);
}

test "handleTextEditKey Enter commits for bash_classifier_url" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Set up text editing mode for bash_classifier_url
    app.mode = .settings;
    app.pickers.settings.edit_target = .bash_classifier_url;
    try app.input_buffers.settings_text.appendSlice(gpa, "https://example.com");

    // Simulate Enter key
    const handled = try handleTextEditKey(&app, .{ .codepoint = vaxis.Key.enter, .mods = .{} });

    // It should have handled the key, committed the text, and cleared the edit target
    try std.testing.expect(handled);
    try std.testing.expect(app.pickers.settings.edit_target == .none);
    try std.testing.expectEqualStrings("https://example.com", app.pickers.settings.pending_bash_classifier_url.?);

    // Free the committed allocated memory since we don't save to disk in this test
    gpa.free(app.pickers.settings.pending_bash_classifier_url.?);
}

test "validateSystemPrompt counts UTF-8 code points like the parser" {
    // 6 000 CJK chars = 18 000 bytes: under the 10 000-char limit although
    // over the byte count the old check compared against.
    const cjk = "界" ** 6_000;
    try validateSystemPrompt(cjk);
    const ascii_edge = "a" ** config_mod.max_system_prompt_chars;
    try validateSystemPrompt(ascii_edge);
    const ascii_over = "a" ** (config_mod.max_system_prompt_chars + 1);
    try std.testing.expectError(error.PromptTooLong, validateSystemPrompt(ascii_over));
}

test "clearCurrentField marks a set field cleared and dirty" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Non-owned cached config with duplicated values the test frees itself.
    app.cached_config_owned = false;
    app.cached_config.system_prompt = try gpa.dupe(u8, "custom prompt");
    app.cached_config.bash_classifier_url = try gpa.dupe(u8, "http://127.0.0.1:8765/classify");
    app.mode = .settings;

    app.pickers.settings.tab = .prompt;
    clearCurrentField(&app);
    // "Cleared" is the empty string, not null — null would mean "untouched"
    // and the save path would report "No changes to save".
    try std.testing.expectEqualStrings("", app.pickers.settings.pending_system_prompt.?);
    try std.testing.expect(app.pickers.settings.dirty);

    app.pickers.settings.tab = .advanced;
    clearCurrentField(&app);
    try std.testing.expectEqualStrings("", app.pickers.settings.pending_bash_classifier_url.?);
    try std.testing.expect(app.pickers.settings.dirty);

    // Clearing an already-empty field is not a change.
    if (app.cached_config.system_prompt) |s| gpa.free(s);
    app.cached_config.system_prompt = null;
    if (app.cached_config.bash_classifier_url) |s| gpa.free(s);
    app.cached_config.bash_classifier_url = null;
    app.pickers.settings.dirty = false;
    app.pickers.settings.tab = .prompt;
    clearCurrentField(&app);
    try std.testing.expect(!app.pickers.settings.dirty);

    // clearCurrentField's pendings are owned by the save-reset path — free
    // the last ones here the same way.
    gpa.free(app.pickers.settings.pending_system_prompt.?);
    gpa.free(app.pickers.settings.pending_bash_classifier_url.?);
}

test "hasActualChanges includes the toast toggle" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.cached_config_owned = false;
    app.mode = .settings;
    const state = &app.pickers.settings;

    // A toggled toast must pass the gate — without this check a toast-only
    // change always reported "No changes to save".
    state.pending_toast_enabled = true;
    app.cached_config.toast.enabled = false;
    try std.testing.expect(hasActualChanges(state, &app.cached_config));

    state.pending_toast_enabled = false;
    try std.testing.expect(!hasActualChanges(state, &app.cached_config));
}
