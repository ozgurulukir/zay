//! Settings mode lifecycle — key handling, toggle logic, and config
//! persistence for the `/settings` overlay.
//!
//! Keeps all settings-related mutation in one place so `tui.zig` and
//! `command_router.zig` stay thin: they just delegate here.

const std = @import("std");
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");
const config_mod = @import("../config.zig");
const settings_widget = @import("widgets/settings.zig");

const App = tui.App;
const State = settings_widget.State;
const Tab = settings_widget.Tab;
const EditTarget = settings_widget.EditTarget;

// ---------------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------------

pub fn openSettings(app: *App) void {
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
            // Toggle enable_thinking. Pending value overrides the config.
            const current = state.pending_enable_thinking orelse
                (if (app.cached_config.model_selection) |ms| ms.enable_thinking else false);
            state.pending_enable_thinking = !current;
            state.dirty = true;
        },
        1 => {
            // Toggle use_responses_endpoint.
            const current = state.pending_use_responses_endpoint orelse
                (if (app.cached_config.model_selection) |ms| ms.use_responses_endpoint else false);
            state.pending_use_responses_endpoint = !current;
            state.dirty = true;
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
                (ms.system_prompt orelse "")
            else
                "";
            app.settings_text_input.clearRetainingCapacity();
            app.settings_text_input.appendSlice(app.gpa, current) catch {};
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
                (ms.bash_classifier_url orelse "")
            else
                "";
            app.settings_text_input.clearRetainingCapacity();
            app.settings_text_input.appendSlice(app.gpa, current) catch {};
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
            // Free pending value if any was set.
            if (state.pending_system_prompt) |old| {
                app.gpa.free(old);
                state.pending_system_prompt = null;
            }
            if (app.cached_config.model_selection != null and
                app.cached_config.model_selection.?.system_prompt != null) state.dirty = true;
        },
        .advanced => {
            if (state.pending_bash_classifier_url) |old| {
                app.gpa.free(old);
                state.pending_bash_classifier_url = null;
            }
            if (app.cached_config.model_selection != null and
                app.cached_config.model_selection.?.bash_classifier_url != null) state.dirty = true;
        },
        .general, .about => {},
    }
}

// ---------------------------------------------------------------------------
// Ctrl+S — save pending changes
// ---------------------------------------------------------------------------

/// Save all pending settings to the global config file and update the live
/// cached_config. Returns true if anything was written.
pub fn saveSettings(app: *App) !bool {
    const state = &app.pickers.settings;
    if (!state.dirty and state.edit_target == .none) return false;

    // Flush any in-progress text edit before saving.
    if (state.edit_target != .none) try commitTextEdit(app);

    // Build the updates from the cached model_selection (so the merge
    // preserves the full selection) plus the pending toggles/text fields.
    // We mutate the model_selection copy rather than carrying both forms.
    var updates: config_mod.Config = .{};
    defer updates.deinit(app.gpa);
    if (app.cached_config.model_selection) |ms| {
        updates.model_selection = try ms.clone(app.gpa);
    }
    if (state.pending_enable_thinking) |v| {
        if (updates.model_selection) |*ms| ms.enable_thinking = v;
    }
    if (state.pending_use_responses_endpoint) |v| {
        if (updates.model_selection) |*ms| ms.use_responses_endpoint = v;
    }
    if (state.pending_system_prompt) |s| {
        if (updates.model_selection) |*ms| {
            if (ms.system_prompt) |old| app.gpa.free(old);
            ms.system_prompt = try app.gpa.dupe(u8, s);
        }
    }
    if (state.pending_bash_classifier_url) |s| {
        if (updates.model_selection) |*ms| {
            if (ms.bash_classifier_url) |old| app.gpa.free(old);
            ms.bash_classifier_url = if (s.len > 0) try app.gpa.dupe(u8, s) else null;
        }
    }

    const runtime = app.liveRuntime() orelse return false;
    config_mod.mergeAndWriteGlobal(app.gpa, app.io, runtime.home_dir, updates) catch |err| {
        std.log.warn("settings.save.failed err={s}", .{@errorName(err)});
        return false;
    };

    // Update the live cached_config so the running agent picks up the
    // changes without a restart.
    try applyToCachedConfig(app, state);
    app.mcp_manager.syncFromConfig(app.io, &app.cached_config) catch {};

    // Reset pending state.
    if (state.pending_system_prompt) |old| app.gpa.free(old);
    if (state.pending_bash_classifier_url) |old| app.gpa.free(old);
    state.dirty = false;
    state.pending_enable_thinking = null;
    state.pending_use_responses_endpoint = null;
    state.pending_system_prompt = null;
    state.pending_bash_classifier_url = null;
    state.edit_target = .none;

    return true;
}

fn commitTextEdit(app: *App) !void {
    const state = &app.pickers.settings;
    const text = app.settings_text_input.items;
    switch (state.edit_target) {
        .system_prompt => {
            if (state.pending_system_prompt) |old| app.gpa.free(old);
            if (text.len > 0) {
                state.pending_system_prompt = try app.gpa.dupe(u8, text);
            } else {
                state.pending_system_prompt = null;
            }
            state.dirty = true;
        },
        .bash_classifier_url => {
            if (state.pending_bash_classifier_url) |old| app.gpa.free(old);
            state.pending_bash_classifier_url = try app.gpa.dupe(u8, text);
            state.dirty = true;
        },
        .none => {},
    }
    state.edit_target = .none;
    app.settings_text_input.clearRetainingCapacity();
}

fn applyToCachedConfig(app: *App, state: *const State) !void {
    if (!app.cached_config_owned) return;
    if (app.cached_config.model_selection) |*ms| {
        if (state.pending_enable_thinking) |v| ms.enable_thinking = v;
        if (state.pending_use_responses_endpoint) |v| ms.use_responses_endpoint = v;
        if (state.pending_system_prompt) |s| {
            if (ms.system_prompt) |old| app.gpa.free(old);
            ms.system_prompt = try app.gpa.dupe(u8, s);
        }
        if (state.pending_bash_classifier_url) |s| {
            if (ms.bash_classifier_url) |old| app.gpa.free(old);
            ms.bash_classifier_url = if (s.len > 0) try app.gpa.dupe(u8, s) else null;
        }
    }
}

// ---------------------------------------------------------------------------
// Escape — cancel text edit or close
// ---------------------------------------------------------------------------

pub fn cancelSettings(app: *App) void {
    const state = &app.pickers.settings;
    if (state.edit_target != .none) {
        state.edit_target = .none;
        app.settings_text_input.clearRetainingCapacity();
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
        app.settings_text_input.clearRetainingCapacity();
        return true;
    }
    if (key.matches('s', .{ .ctrl = true })) {
        // Ctrl+S while editing: commit + save.
        try commitTextEdit(app);
        _ = try saveSettings(app);
        return true;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
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
            try app.settings_text_input.appendSlice(app.gpa, text);
            return true;
        }
    } else if (key.codepoint >= 32 and key.codepoint <= 126 and
        !key.mods.ctrl and !key.mods.alt and !key.mods.super)
    {
        const byte: u8 = @intCast(key.codepoint);
        try app.settings_text_input.append(app.gpa, byte);
        return true;
    }
    // Swallow all remaining keys while in text-edit mode so they do not
    // propagate to the structural navigation handlers.
    return true;
}

fn popSettingsTextInput(app: *App) void {
    const items = app.settings_text_input.items;
    if (items.len == 0) return;
    // Walk back over continuation bytes to preserve UTF-8 codepoint boundary.
    var cut = items.len - 1;
    while (cut > 0 and (items[cut] & 0xC0) == 0x80) cut -= 1;
    app.settings_text_input.shrinkRetainingCapacity(cut);
}
