//! Command router for the TUI mode-dispatch switch.
//!
//! Pulled out of `tui.zig` (R2 of `_pm/Projects/tui-split`) — the original
//! `handleCommandKey` dispatched to seven per-mode arm functions
//! (`handleTreePickerKey`, `handleProviderPickerKey`, etc.) which all lived
//! as private methods on `App`. Centralising the dispatch as a free function
//! in a dedicated module makes the mode table visible at a glance and lets
//! each mode evolve into a focused struct with its own state and helpers.
//!
//! Behavioural identity is preserved: every key combo, every side effect
//! matches the pre-refactor implementation. Only the location changed.
//!
//! ## Structure
//!
//! One struct per `App.Mode` variant. Each struct owns a `handle` method
//! that used to be a private method on `App`. Sub-steps R2.1 through R2.8
//! move each arm in turn, replacing this stub with the real implementation
//! and removing the corresponding method from `tui.zig`.
//!
//! ## Why a free dispatcher, not a method
//!
//! `App.handleCommandKey` is invoked from inline tests in `tui.zig:7106-7693`
//! and from `event_router.routeKey`. Keeping a one-line delegate on `App`
//! preserves both call sites without exposing the dispatcher internals.

const std = @import("std");
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");

const App = tui.App;
const Mode = App.Mode;
const provider_model = @import("provider_model.zig");
const clipboard_helper = @import("clipboard_helper.zig");
const help_picker = @import("widgets/help_picker.zig");
const theme_lifecycle = @import("theme_lifecycle.zig");
const theme_picker = @import("widgets/theme_picker.zig");
const plugin_store_job = @import("plugin_store_job.zig");
const plugin_store = @import("../plugin_store.zig");
const log = std.log.scoped(.tui);
const previousIndex = tui.previousIndex;
const nextIndex = tui.nextIndex;

/// Top-level dispatch: routes a key to the per-mode handler for the current
/// `App.mode`. Returns true when visible state changed (caller redraws).
pub fn handleCommandKey(app: *App, key: vaxis.Key) !bool {
    return switch (app.getMode()) {
        .provider_picker => try ProviderPicker.handle(app, key),
        .model_picker => try ModelPicker.handle(app, key),
        .session_picker => try SessionPicker.handle(app, key),
        .tree_picker => try TreePicker.handle(app, key),
        .lanes => try Lanes.handle(app, key),
        .help => try HelpPicker.handle(app, key),
        .command => try CommandMenu.handle(app, key),
        .settings => try SettingsMode.handle(app, key),
        .mcp => try McpMode.handle(app, key),
        .plugins => try PluginsMode.handle(app, key),
        .search => try SearchMode.handle(app, key),
        .theme_picker => try ThemePicker.handle(app, key),
        // The diff viewer owns its keys directly in `captureEvent`; nothing
        // reaches the generic dispatch.
        .diff_viewer => false,
        // The save prompt is a plain text field: Enter/Esc are handled in
        // submit/cancel; every other key falls through to the focused input.
        .save_message => false,
        .normal => try Transcript.handle(app, key),
    };
}

/// File-tree picker mode (overlay search + tree state).
///
/// Keys: up/down move the cursor; left/right cycle the filter; tab toggles
/// the fold state of the currently selected node. Every other key falls
/// through to the input.
const TreePicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.up, .{})) {
            app.getTreeState().moveUp();
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            app.getTreeState().moveDown();
            return true;
        }
        if (key.matches(vaxis.Key.left, .{})) {
            const filter = try app.peekPaletteInput();
            defer app.gpa.free(filter);
            try app.getTreeState().cycleFilter(filter, false);
            return true;
        }
        if (key.matches(vaxis.Key.right, .{})) {
            const filter = try app.peekPaletteInput();
            defer app.gpa.free(filter);
            try app.getTreeState().cycleFilter(filter, true);
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            const filter = try app.peekPaletteInput();
            defer app.gpa.free(filter);
            try app.getTreeState().toggleFoldSelected(filter);
            return true;
        }
        return false;
    }
};

/// Check if a key event corresponds to Enter/Return across terminal protocols and encodings.
pub fn isEnterKey(key: vaxis.Key) bool {
    if (key.matches(vaxis.Key.enter, .{})) return true;
    if (key.codepoint == '\r' or key.codepoint == '\n') return true;
    if (key.codepoint == vaxis.Key.enter) return true;
    if (key.text) |text| {
        if (std.mem.eql(u8, text, "\r") or std.mem.eql(u8, text, "\n") or std.mem.eql(u8, text, "\r\n")) return true;
    }
    return false;
}

/// Outcome of feeding one key to a `FormField`. `consumed` covers both a
/// real edit (append/backspace) and a swallowed key (routeKey owns Enter
/// upstream: submitMode is the single wiring site for Enter submit, so the
/// per-mode `.submit` arms below are defensive parity for direct callers).
pub const FormAction = enum { consumed, submit, cancel };

/// Single-line form text input shared by every one-line editor form
/// (provider key, session rename, project-root bind, MCP add, plugins add).
///
/// Semantics reproduced verbatim from the pre-refactor handlers: Enter
/// reports `.submit`, Esc reports `.cancel`, backspace pops one UTF-8
/// grapheme, `key.text` payloads append after CR/LF trimming, printable
/// ASCII codepoints (32..126, no ctrl/alt/super) append as bytes, and
/// everything else is swallowed as `.consumed`. The optional `dirty` flag
/// (only the provider key form uses it) is set on every real edit and left
/// untouched on Enter, Esc, and swallowed keys.
pub const FormField = struct {
    buf: *std.ArrayList(u8),
    dirty: ?*bool = null,

    pub fn feed(self: *FormField, gpa: std.mem.Allocator, key: vaxis.Key) !FormAction {
        if (key.matches(vaxis.Key.escape, .{})) return .cancel;
        if (isEnterKey(key)) return .submit;
        if (key.matches(vaxis.Key.backspace, .{})) {
            popUtf8Tail(self.buf);
            if (self.dirty) |dirty| dirty.* = true;
            return .consumed;
        }
        if (key.text) |text| {
            const trimmed = std.mem.trim(u8, text, "\r\n");
            if (trimmed.len > 0) {
                try self.buf.appendSlice(gpa, trimmed);
                if (self.dirty) |dirty| dirty.* = true;
                return .consumed;
            }
        } else if (key.codepoint >= 32 and key.codepoint <= 126 and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
            const byte: u8 = @intCast(key.codepoint);
            try self.buf.append(gpa, byte);
            if (self.dirty) |dirty| dirty.* = true;
            return .consumed;
        }
        return .consumed;
    }
};

/// Pop one UTF-8 tail off `buf`: remove the last codepoint by stepping back
/// over continuation bytes (0b10xxxxxx), leaving an empty buffer intact.
/// Combining-mark grapheme clusters split; that matches the old handlers.
pub fn popUtf8Tail(buf: *std.ArrayList(u8)) void {
    const items = buf.items;
    if (items.len == 0) return;
    var cut = items.len - 1;
    while (cut > 0 and (items[cut] & 0xC0) == 0x80) cut -= 1;
    buf.shrinkRetainingCapacity(cut);
}

/// Enter submit for the MCP overlay, owned by `submitMode`. The add form
/// while `adding`, the selected client's connect toggle otherwise. Always
/// true: Enter is consumed in these overlays even when the action is a
/// no-op (the old routeKey exception consumed it the same way).
pub fn submitMcp(app: *App) !bool {
    if (app.pickers.mcp.adding) {
        try McpMode.addMcpFromForm(app);
        return true;
    }
    _ = try McpMode.toggleSelectedMcpClient(app);
    return true;
}

/// Enter submit for the plugins overlay, owned by `submitMode`: no-op
/// during uninstall confirm ('y'/'n' own it), the add form while `adding`,
/// install in the store view, no-op in the sources and installed views
/// (space owns their toggle). Always true — Enter is consumed in these
/// overlays even when the action is a no-op.
pub fn submitPlugins(app: *App) !bool {
    if (app.pickers.plugins.confirming_uninstall) return true;
    if (app.pickers.plugins.adding) {
        try PluginsMode.addPluginFromForm(app);
        return true;
    }
    if (app.pickers.plugins.view == .store) PluginsMode.startStoreInstall(app);
    return true;
}

/// Provider picker mode (provider list + API-key setup form).
const ProviderPicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (app.getProviderPicker().stage == .form) {
            app.getProviderPicker().form_error = null;
            var field = FormField{
                .buf = app.getProviderKeyInput(),
                .dirty = &app.getProviderPicker().key_dirty,
            };
            return switch (try field.feed(app.gpa, key)) {
                .consumed => true,
                // Esc and Enter are handled upstream (close menu / submit).
                .submit, .cancel => false,
            };
        }
        const filter = try app.peekPaletteInput();
        defer app.gpa.free(filter);
        return app.getProviderPicker().handleKey(key, app.isCodexSignedIn(), filter);
    }
};

/// Model picker mode (column switcher + row navigation + reasoning/scope).
///
/// Left/right move between model columns; tab cycles the active column's
/// value (column -> reasoning -> scope -> column); up/down step the
/// selection through filtered entries.
const ModelPicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        const models = app.getModels();
        if (key.matches(vaxis.Key.left, .{})) {
            models.model_column = models.model_column.previous();
            return true;
        }
        if (key.matches(vaxis.Key.right, .{})) {
            if (models.len() > 0) models.model_column = models.model_column.next();
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            switch (models.model_column) {
                .model => models.model_column = models.model_column.next(),
                .reasoning => try provider_model.cycleSelectedReasoning(app),
            }
            return true;
        }
        // Ctrl+S cycles the save scope (global → project → session) from the
        // picker. The scope no longer has a table column — it's shown in the
        // footer status line instead.
        if (key.matches('s', .{ .ctrl = true })) {
            provider_model.cycleModelScope(app);
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            try provider_model.stepModelSelection(app, false);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            try provider_model.stepModelSelection(app, true);
            return true;
        }
        return false;
    }
};

/// Resume-session picker mode (project grouping + selection navigation).
///
/// Ctrl+A toggles global vs project-scoped resume list (and reloads from
/// disk); tab toggles fold of the selected project when in global mode;
/// up/down step the selection through the visible (filtered) entries.
/// 'd' enters a delete-confirmation sub-state; 'r' enters a rename
/// sub-state with a prefilled text buffer. Sub-states capture all keys
/// until submitted (Enter / y) or cancelled (Esc / n).
const SessionPicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        switch (app.nav.session_action) {
            .renaming => return handleRenameInput(app, key),
            .deleting => return handleDeleteConfirm(app, key),
            .locating_project => return handleProjectRootInput(app, key),
            .blocked => {
                // Any key dismisses the blocked-action popup.
                app.cancelSessionAction();
                return true;
            },
            .browsing => {},
        }

        if (key.matches('a', .{ .ctrl = true })) {
            app.toggleResumeGroupBy();
            app.setResumeSelection(0);
            app.resumeClearFolds();
            try app.reloadResumeSessions();
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            // In project mode, tab folds/unfolds the selected project.
            // In date mode, tab is a no-op (no folding by date).
            if (app.getResumeGroupBy() == .project) try app.toggleSelectedResumeProject();
            return true;
        }
        if (key.matches('d', .{})) {
            try app.beginDeleteSelectedSession();
            return true;
        }
        if (key.matches('r', .{})) {
            try app.beginRenameSelectedSession();
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            const next = previousIndex(app.getResumeSelection(), try app.visibleResumeCount());
            app.setResumeSelection(next);
            app.syncResumeListCursor();
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            const next = nextIndex(app.getResumeSelection(), try app.visibleResumeCount());
            app.setResumeSelection(next);
            app.syncResumeListCursor();
            return true;
        }
        return false;
    }

    /// Text input for the rename form. Esc cancels; printable keys append
    /// to the rename buffer and everything else is swallowed.
    fn handleRenameInput(app: *App, key: vaxis.Key) !bool {
        var field = FormField{ .buf = &app.input_buffers.session_rename_text };
        switch (try field.feed(app.gpa, key)) {
            .cancel => app.cancelSessionAction(),
            // Enter delivery is owned by submitMode's session_picker dispatch
            // (confirmRenameSelectedSession lives there); swallow it here so
            // the raw key doesn't re-submit. Same convention as the
            // project-root and provider forms.
            .submit => {},
            .consumed => {},
        }
        // The rename buffer is the sole input target while this sub-state is
        // active: every key changes visible state (or closes the sub-state).
        return true;
    }

    /// Delete confirmation: 'y' confirms, Esc/'n' cancels. All other keys
    /// are swallowed so the user can't accidentally navigate away.
    fn handleDeleteConfirm(app: *App, key: vaxis.Key) !bool {
        if (key.matches('y', .{}) or key.matches('y', .{ .shift = true })) {
            try app.confirmDeleteSelectedSession();
            return true;
        }
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('n', .{}) or key.matches('n', .{ .shift = true })) {
            app.cancelSessionAction();
            return true;
        }
        return true;
    }

    /// Text input for the project-root bind form. Enter submits (routed via
    /// submitMode), Esc cancels without any mutation; printable keys append
    /// to the buffer and everything else is swallowed.
    fn handleProjectRootInput(app: *App, key: vaxis.Key) !bool {
        var field = FormField{ .buf = &app.input_buffers.project_root_text };
        switch (try field.feed(app.gpa, key)) {
            .cancel => app.cancelProjectRootBinding(),
            // Enter is handled by the submitMode session_picker dispatch;
            // swallow it here so the raw key doesn't re-submit.
            .submit => {},
            .consumed => {},
        }
        // The bind form is the sole input target while this sub-state is
        // active: every key changes visible state (or leaves the sub-state).
        return true;
    }
};

/// Lanes manager mode (parallel-lane picker + parked-lane management).
///
/// Up/down move the selection; in manage-purpose (parked lanes view)
/// 'm' merges the selected parked lane back into the active lane, and
/// 'x' deletes it. Lane errors are routed through the existing reporter.
const Lanes = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.up, .{})) {
            if (app.getLanesSelection() > 0) {
                app.setLanesSelection(app.getLanesSelection() - 1);
            }
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            const count = app.laneEntryCount();
            if (count > 0 and app.getLanesSelection() + 1 < count) {
                app.setLanesSelection(app.getLanesSelection() + 1);
            }
            return true;
        }
        if (app.getLanesPurpose() == .manage) {
            if (key.matches('m', .{}) or key.matches('m', .{ .shift = true })) {
                app.mergeSelectedParked() catch |err| try app.reportLaneError(err);
                return true;
            }
            if (key.matches('x', .{}) or key.matches('x', .{ .shift = true })) {
                app.deleteSelectedParked() catch |err| try app.reportLaneError(err);
                return true;
            }
            if (key.matches('o', .{}) or key.matches('o', .{ .shift = true })) {
                // Open the selected parked worktree (or idle lane) as a live
                // lane, resuming its linked conversation when one exists.
                app.openSelectedLane() catch |err| try app.reportLaneError(err);
                return true;
            }
        }
        return false;
    }
};

/// Slash-command menu mode.
///
/// Up/down move the cursor through the filtered command list. The
/// filter itself is owned by the input widget; this struct only owns
/// the selection.
const CommandMenu = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.up, .{})) {
            const next = previousIndex(app.getCommandSelection(), tui.commandMatchesCount(app));
            app.setCommandSelection(next);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            const next = nextIndex(app.getCommandSelection(), tui.commandMatchesCount(app));
            app.setCommandSelection(next);
            return true;
        }
        return false;
    }
};

/// Theme picker mode.
///
/// Up/down move the cursor through the filtered theme list; Enter applies the
/// selected theme (via `theme_lifecycle.applyTheme`) and is handled by
/// `submitMode`, not here. Esc is handled by the `cancelMode` fallthrough.
/// Other keys fall through to the focused palette input for filtering.
const ThemePicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.up, .{})) {
            const next = previousIndex(app.pickers.theme.selection, theme_pickerMatchingCount(app));
            app.pickers.theme.selection = next;
            try previewSelected(app);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            const next = nextIndex(app.pickers.theme.selection, theme_pickerMatchingCount(app));
            app.pickers.theme.selection = next;
            try previewSelected(app);
            return true;
        }
        return false;
    }

    /// Live-recolor to the newly selected theme when `tui.theme_live_preview`
    /// is enabled. No-op otherwise (and when the selection doesn't resolve).
    fn previewSelected(app: *App) !void {
        if (!app.cached_config.tui.theme_live_preview) return;
        const filter = app.peekPaletteInput() catch return;
        defer app.gpa.free(filter);
        if (theme_picker.selectedName(app.theme_registry.slice(), filter, app.pickers.theme.selection)) |name| {
            theme_lifecycle.previewTheme(app, app.theme_registry.resolve(name));
        }
    }

    /// The number of themes the current palette filter selects — zero-division
    /// safe (previousIndex/nextIndex guard on count == 0).
    fn theme_pickerMatchingCount(app: *App) u32 {
        const filter = app.peekPaletteInput() catch return 0;
        defer app.gpa.free(filter);
        return theme_picker.countMatching(app.theme_registry.slice(), filter);
    }
};

/// Normal-mode transcript navigation (block nav, @-mention popup, lane switch).
///
/// The largest arm — split into three sub-handlers (R2.8a/b/c) that each
/// own one concern: mention popup selection, block navigation, and
/// multi-lane switching. Each sub-handler returns true if it consumed
/// the key; Transcript.handle short-circuits and returns. The full arm
/// body still lives in `App.handleTranscriptKey` for the bits not yet
/// extracted.
pub const Transcript = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        // Prompt history navigation: Ctrl+Up / Alt+Up (previous prompt), Ctrl+Down / Alt+Down (next prompt).
        if (key.matches(vaxis.Key.up, .{ .ctrl = true }) or key.matches(vaxis.Key.up, .{ .alt = true })) {
            if (try app.navigatePromptHistory(.up)) return true;
        }
        if (key.matches(vaxis.Key.down, .{ .ctrl = true }) or key.matches(vaxis.Key.down, .{ .alt = true })) {
            if (try app.navigatePromptHistory(.down)) return true;
        }
        // R2.8a: @-mention popup owns up/down while active.
        if (try MentionPopup.handle(app, key)) return true;
        // R2.8b: block navigation owns shift+down and plain up/down.
        if (try BlockNav.handle(app, key)) return true;
        // R2.8c: lane switching and transcript toggle.
        if (try LaneSwitch.handle(app, key)) return true;
        return false;
    }
};

/// R2.8a: @-mention popup selection.
///
/// When the @-mention popup is open with results, up/down move the
/// selection through the result list. Other keys fall through.
pub const MentionPopup = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (!app.isAtSearchActive() or !app.atSearchHasResults()) return false;
        if (key.matches(vaxis.Key.up, .{})) {
            const next = previousIndex(app.getAtSelection(), @intCast(app.atResultsLen()));
            app.setAtSelection(next);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            const next = nextIndex(app.getAtSelection(), @intCast(app.atResultsLen()));
            app.setAtSelection(next);
            return true;
        }
        return false;
    }
};

/// R2.8b: Block navigation through the transcript.
///
/// Shift+Down jumps to the bottom (re-entering the input when needed).
/// Plain Up/Down walks blocks: stepping down past the last block (when
/// it can't scroll further) re-enters the input and traps the cursor
/// there. Auto-scroll follows the navigation state.
pub const BlockNav = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        // Copy selected message block to clipboard via 'y', 'c', or Ctrl+C in block nav.
        if (app.getBlockNav()) {
            if (key.matches('y', .{}) or key.matches('c', .{}) or key.matches('c', .{ .ctrl = true })) {
                if (try clipboard_helper.copySelectedTranscriptBlock(app)) return true;
            }
        }
        if (key.matches(vaxis.Key.down, .{ .shift = true })) {
            app.jumpTranscriptToBottom();
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            _ = app.navigateTranscript(.previous);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            // Stepping down past the last block (when it can't scroll further)
            // re-enters the input and traps the cursor there again.
            if (app.getBlockNav() and app.selectionIsLastMessage() and !app.selectedMessageCanScrollDown()) {
                app.clearBlockNav();
                app.setThreadAutoScroll(true);
                _ = try app.moveInputCursorVertical(.down);
                return true;
            }
            const scrolled = app.navigateTranscript(.next);
            app.setThreadAutoScroll(!scrolled and app.selectionIsLastMessage() and !app.selectedMessageIsLong());
            return true;
        }
        return false;
    }
};

/// R2.8c: Lane switching and transcript toggle.
///
/// With multiple lanes, Shift+Tab/Shift+Right cycle forward, Shift+Left
/// cycles back. Plain Tab toggles the currently selected transcript
/// block (used to copy from the transcript).
pub const LaneSwitch = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (app.threadsCount() > 1) {
            if (key.matches(vaxis.Key.tab, .{ .shift = true }) or key.matches(vaxis.Key.right, .{ .shift = true })) {
                app.cycleLane(1);
                return true;
            }
            if (key.matches(vaxis.Key.left, .{ .shift = true })) {
                app.cycleLane(-1);
                return true;
            }
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            app.toggleSelectedTranscriptBlock();
            return true;
        }
        return false;
    }
};

pub const HelpPicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        // Same body-row derivation `Content.draw` renders with — the keyboard
        // and mouse clamps must agree or the last items become unreachable.
        const body_height: u16 = help_picker.bodyRows(help_picker.help_overlay_height);
        if (key.matches(vaxis.Key.escape, .{}) or key.matches(vaxis.Key.enter, .{}) or key.matches('q', .{})) {
            app.setMode(.normal);
            app.pickers.help.reset();
            return true;
        }
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            app.pickers.help.scrollUp(1);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            app.pickers.help.scrollDown(1, body_height);
            return true;
        }
        if (key.matches(vaxis.Key.page_up, .{})) {
            app.pickers.help.scrollUp(8);
            return true;
        }
        if (key.matches(vaxis.Key.page_down, .{})) {
            app.pickers.help.scrollDown(8, body_height);
            return true;
        }
        if (key.matches(vaxis.Key.home, .{})) {
            app.pickers.help.scroll = 0;
            return true;
        }
        if (key.matches(vaxis.Key.end, .{})) {
            app.pickers.help.scroll = help_picker.State.maxScroll(body_height);
            return true;
        }
        return false;
    }
};

/// Transcript search mode (Ctrl+F / /search).
///
/// Up/down step the match selection. Enter jumps (routed through `submitMode`
/// in `mode_lifecycle`), Esc cancels, and every other key falls through to the
/// palette input, whose `paletteInputChanged` hook re-filters live.
const SearchMode = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        const state = &app.pickers.search;
        if (key.matches(vaxis.Key.up, .{})) {
            if (state.matches.items.len > 0) {
                state.selection = previousIndex(state.selection, @intCast(state.matches.items.len));
            }
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            if (state.matches.items.len > 0) {
                state.selection = nextIndex(state.selection, @intCast(state.matches.items.len));
            }
            return true;
        }
        return false;
    }
};

/// Settings panel mode — tab navigation, toggle, text edit, save.
const SettingsMode = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        // Text-edit mode: delegate all keys to the inline editor.
        if (try tui.handleSettingsTextEditKey(app, key)) return true;

        // Ctrl+S: save settings.
        if (key.matches('s', .{ .ctrl = true })) {
            _ = try tui.saveSettings(app);
            return true;
        }
        // Delete / Backspace on a non-editing row: clear the field.
        if (key.matches(vaxis.Key.delete, .{})) {
            tui.clearSettingsField(app);
            return true;
        }
        // Delegate structural navigation to the State's handleKey.
        if (app.pickers.settings.handleKey(key)) return true;
        return false;
    }
};

const McpMode = struct {
    fn handle(app: *App, key: vaxis.Key) !bool {
        // The add-server form owns all keys until it is submitted or cancelled.
        if (app.pickers.mcp.adding) return handleAddInput(app, key);
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            tui.closeMcp(app);
            return true;
        }
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            app.pickers.mcp.moveUp();
            return true;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            app.pickers.mcp.moveDown(app.mcp_manager.clients.items.len);
            return true;
        }
        if (key.matches(' ', .{}) or key.matches(vaxis.Key.enter, .{})) {
            if (try toggleSelectedMcpClient(app)) return true;
        }
        if (key.matches('r', .{ .ctrl = true }) or key.matches('r', .{})) {
            if (app.pickers.mcp.selection < app.mcp_manager.clients.items.len) {
                app.mcp_manager.reconnectClient(app.io, app.pickers.mcp.selection);
                provider_model.injectMcpTools(app);
            }
            return true;
        }
        if (key.matches('d', .{})) {
            if (app.pickers.mcp.selection < app.mcp_manager.clients.items.len) {
                app.mcp_manager.disconnectClient(app.io, app.pickers.mcp.selection);
                provider_model.injectMcpTools(app);
            }
            return true;
        }
        if (key.matches('a', .{})) {
            app.pickers.mcp.adding = true;
            app.input_buffers.mcp_url.clearRetainingCapacity();
            return true;
        }
        return false;
    }

    /// Toggle (connect/disconnect/reconnect) the selected MCP client.
    /// False with an out-of-range selection: the caller may fall through to
    /// the next binding.
    fn toggleSelectedMcpClient(app: *App) !bool {
        if (app.pickers.mcp.selection >= app.mcp_manager.clients.items.len) return false;
        const client = app.mcp_manager.clients.items[app.pickers.mcp.selection];
        switch (client.status()) {
            .connected => {
                // Disconnect through the manager, never with an inline stop:
                // the discovery cache must be cleared WITH the transport, or
                // the next reconcile wedges the server in CONNECTING with
                // stale tools (#384 bug 1).
                app.mcp_manager.disconnectClient(app.io, app.pickers.mcp.selection);
            },
            .failed => {
                // Reconnect on toggle when failed
                app.mcp_manager.reconnectClient(app.io, app.pickers.mcp.selection);
            },
            else => {
                client.markConnecting(app.io);
            },
        }
        provider_model.injectMcpTools(app);
        return true;
    }

    /// The add form's submit action: trim the URL, hand it to
    /// `addMcpServerByUrl` (which owns validation and failure projection),
    /// and close the form. Reached through `submitMcp` (submitMode) in
    /// production; the `handleAddInput` `.submit` arm keeps the same action
    /// for direct callers as defensive parity.
    fn addMcpFromForm(app: *App) !void {
        const url = std.mem.trim(u8, app.input_buffers.mcp_url.items, " \t\r\n");
        if (url.len > 0) provider_model.addMcpServerByUrl(app, url) catch {};
        app.pickers.mcp.adding = false;
        app.input_buffers.mcp_url.clearRetainingCapacity();
    }

    /// Text input for the "add server by URL" form. Enter submits, Esc cancels;
    /// printable keys append to the URL buffer and everything else is swallowed.
    fn handleAddInput(app: *App, key: vaxis.Key) !bool {
        var field = FormField{ .buf = &app.input_buffers.mcp_url };
        switch (try field.feed(app.gpa, key)) {
            // Enter delivery is owned by submitMode → submitMcp; this arm
            // stays for direct callers so the form cannot drift from the
            // owning path.
            .submit => try addMcpFromForm(app),
            .cancel => {
                app.pickers.mcp.adding = false;
                app.input_buffers.mcp_url.clearRetainingCapacity();
            },
            .consumed => {},
        }
        return true;
    }
};

const PluginsMode = struct {
    fn handle(app: *App, key: vaxis.Key) !bool {
        if (app.pickers.plugins.confirming_uninstall) {
            if (key.matches(vaxis.Key.escape, .{}) or key.matches('n', .{})) {
                app.pickers.plugins.confirming_uninstall = false;
                app.pickers.plugins.confirmed_path = null;
                return true;
            }
            if (key.matches('y', .{})) {
                app.pickers.plugins.confirming_uninstall = false;
                if (app.pickers.plugins.confirmed_path) |path| app.uninstallPlugin(path);
                app.pickers.plugins.confirmed_path = null;
            }
            return true;
        }
        if (app.pickers.plugins.adding) return handleAddInput(app, key);
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            tui.closePlugins(app);
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            app.pickers.plugins.view = switch (app.pickers.plugins.view) {
                .installed => .store,
                .store => .sources,
                .sources => .installed,
            };
            app.pickers.plugins.reset();
            return true;
        }
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            app.pickers.plugins.moveUp();
            return true;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            const count = if (app.pickers.plugins.view == .installed) blk: {
                const rows = try plugin_store_job.installedPlugins(app.gpa, app);
                defer app.gpa.free(rows);
                break :blk rows.len;
            } else if (app.plugin_store.catalogs) |*catalogs| switch (app.pickers.plugins.view) {
                .store => catalogs.entryCount(),
                .sources => catalogs.stores.len,
                .installed => 0,
            } else 0;
            app.pickers.plugins.moveDown(count);
            return true;
        }
        if (app.pickers.plugins.view == .store and
            app.plugin_store.operation == .idle and
            key.matches('a', .{}))
        {
            app.pickers.plugins.adding = true;
            app.input_buffers.plugin_store_url.clearRetainingCapacity();
            return true;
        }
        if (app.pickers.plugins.view == .store and key.matches('r', .{})) {
            // startRefresh projects setup failures into the overlay notice.
            app.refreshPluginStore() catch |err| {
                log.warn("plugin_store.refresh.failed err={s}", .{@errorName(err)});
            };
            return true;
        }
        if (app.pickers.plugins.view == .sources and key.matches('s', .{})) {
            app.pickers.plugins.view = .store;
            app.pickers.plugins.reset();
            return true;
        }
        if (app.pickers.plugins.view == .sources and
            app.plugin_store.operation == .idle and
            key.matches(' ', .{}))
        {
            const bundle = app.plugin_store.catalogs orelse return true;
            if (app.pickers.plugins.selection < bundle.stores.len) {
                const source = &bundle.stores[app.pickers.plugins.selection];
                const runtime = app.liveRuntime() orelse app.templateRuntime() orelse return true;
                plugin_store.setStoreUrlEnabled(app.gpa, app.io, runtime.home_dir, source.url, !source.enabled) catch |err| {
                    const notice = std.fmt.allocPrint(app.gpa, "Could not update store: {s}", .{@errorName(err)}) catch null;
                    if (notice) |owned| setPluginStoreNotice(app, owned);
                    return true;
                };
                const enabled = !source.enabled;
                setPluginStoreNotice(app, app.gpa.dupe(u8, if (enabled) "Store enabled; refreshing catalogs..." else "Store disabled.") catch return true);
                app.refreshPluginStore() catch |err| log.warn("plugin_store.refresh.failed err={s}", .{@errorName(err)});
            }
            return true;
        }
        if (app.pickers.plugins.view == .sources and
            app.plugin_store.operation == .idle and
            key.matches('r', .{}))
        {
            app.refreshPluginStore() catch |err| log.warn("plugin_store.retry.failed err={s}", .{@errorName(err)});
            return true;
        }
        if (app.pickers.plugins.view == .sources and
            app.plugin_store.operation == .idle and
            key.matches('x', .{}))
        {
            const bundle = app.plugin_store.catalogs orelse return true;
            if (app.pickers.plugins.selection < bundle.stores.len) {
                const source = bundle.stores[app.pickers.plugins.selection].url;
                const runtime = app.liveRuntime() orelse app.templateRuntime() orelse return true;
                plugin_store.removeStoreUrl(app.gpa, app.io, runtime.home_dir, source) catch |err| {
                    const notice = std.fmt.allocPrint(app.gpa, "Could not remove store: {s}", .{@errorName(err)}) catch null;
                    if (notice) |owned| setPluginStoreNotice(app, owned);
                    return true;
                };
                if (app.gpa.dupe(u8, "Store removed; refreshing catalogs...")) |notice| {
                    setPluginStoreNotice(app, notice);
                } else |_| {}
                app.refreshPluginStore() catch |err| log.warn("plugin_store.refresh.failed err={s}", .{@errorName(err)});
                app.pickers.plugins.selection = 0;
            }
            return true;
        }
        if (app.pickers.plugins.view == .store and isEnterKey(key)) {
            startStoreInstall(app);
            return true;
        }
        if (app.pickers.plugins.view == .installed and app.plugin_store.operation == .idle and key.matches(' ', .{})) {
            if (try selectedInstalledPlugin(app)) |plugin| app.togglePluginEnabled(plugin.name);
            return true;
        }
        if (app.pickers.plugins.view == .installed and app.plugin_store.operation == .idle and key.matches('x', .{})) {
            if (try selectedInstalledPlugin(app)) |plugin| {
                if (plugin.path.len == 0) {
                    plugin_store_job.forgetMissingPlugin(app, plugin.name);
                    app.pickers.plugins.reset();
                } else if (plugin_store_job.configuredEnabled(&app.cached_config, plugin.name)) {
                    app.pickers.plugins.confirming_uninstall = false;
                    app.uninstallPlugin(plugin.path);
                } else if (app.plugin_manager.get(plugin.name) != null) {
                    app.pickers.plugins.confirming_uninstall = false;
                    app.uninstallPlugin(plugin.path);
                } else {
                    app.pickers.plugins.confirming_uninstall = true;
                    app.pickers.plugins.confirmed_path = plugin.path;
                }
            }
            return true;
        }
        return false;
    }

    fn selectedInstalledPlugin(app: *App) !?plugin_store_job.InstalledPlugin {
        const rows = try plugin_store_job.installedPlugins(app.gpa, app);
        defer app.gpa.free(rows);
        if (app.pickers.plugins.selection >= rows.len) return null;
        return rows[app.pickers.plugins.selection];
    }

    /// Start installing the selected store plugin. Projects setup failures
    /// into the overlay notice; worker failures are adopted and reported by
    /// the lifecycle.
    fn startStoreInstall(app: *App) void {
        app.installSelectedPlugin() catch |err| {
            log.warn("plugin_store.install.start_failed err={s}", .{@errorName(err)});
        };
    }

    /// The add form's submit action: trim the URL, hand it to `addStore`
    /// (which owns validation and projects failures into the notice), and
    /// close the form. Reached through `submitPlugins` (submitMode) in
    /// production; the `handleAddInput` `.submit` arm keeps the same action
    /// for direct callers as defensive parity.
    fn addPluginFromForm(app: *App) !void {
        const url = std.mem.trim(u8, app.input_buffers.plugin_store_url.items, " \t\r\n");
        app.addPluginStore(url) catch {};
        app.pickers.plugins.adding = false;
        app.input_buffers.plugin_store_url.clearRetainingCapacity();
    }

    fn handleAddInput(app: *App, key: vaxis.Key) !bool {
        var field = FormField{ .buf = &app.input_buffers.plugin_store_url };
        switch (try field.feed(app.gpa, key)) {
            // Enter delivery is owned by submitMode → submitPlugins; this
            // arm stays for direct callers so the form cannot drift from
            // the owning path.
            .submit => try addPluginFromForm(app),
            .cancel => {
                app.pickers.plugins.adding = false;
                app.input_buffers.plugin_store_url.clearRetainingCapacity();
            },
            .consumed => {},
        }
        return true;
    }
};

fn setPluginStoreNotice(app: *App, owned_message: []u8) void {
    if (app.plugin_store.notice) |old| app.gpa.free(old);
    app.plugin_store.notice = owned_message;
}

const agent_mod = @import("../agent.zig");

test "provider picker setup form captures key codepoints and text without swallowing Enter" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.pickers.provider.stage = .form;

    try std.testing.expect(try ProviderPicker.handle(&app, .{ .codepoint = 's' }));
    try std.testing.expectEqualStrings("s", app.input_buffers.provider_key.items);

    try std.testing.expect(try ProviderPicker.handle(&app, .{ .codepoint = 'k' }));
    try std.testing.expectEqualStrings("sk", app.input_buffers.provider_key.items);

    try std.testing.expect(try ProviderPicker.handle(&app, .{ .codepoint = vaxis.Key.backspace }));
    try std.testing.expectEqualStrings("s", app.input_buffers.provider_key.items);

    try std.testing.expect(!try ProviderPicker.handle(&app, .{ .codepoint = vaxis.Key.enter }));
}

test "provider picker setup form marks the key dirty on any edit" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.pickers.provider.stage = .form;
    try std.testing.expect(!app.pickers.provider.key_dirty);

    // A codepoint edit marks it dirty.
    _ = try ProviderPicker.handle(&app, .{ .codepoint = 's' });
    try std.testing.expect(app.pickers.provider.key_dirty);

    // Backspace keeps it dirty.
    _ = try ProviderPicker.handle(&app, .{ .codepoint = vaxis.Key.backspace });
    try std.testing.expect(app.pickers.provider.key_dirty);

    // Enter does not mark it dirty (it submits, not edits).
    app.pickers.provider.key_dirty = false;
    _ = try ProviderPicker.handle(&app, .{ .codepoint = vaxis.Key.enter });
    try std.testing.expect(!app.pickers.provider.key_dirty);

    // A non-editing key (arrow) does not mark it dirty — a pre-filled key
    // must stay masked until an actual edit.
    app.pickers.provider.key_dirty = false;
    _ = try ProviderPicker.handle(&app, .{ .codepoint = vaxis.Key.down });
    try std.testing.expect(!app.pickers.provider.key_dirty);
}

test "provider picker setup form submit with empty key sets form_error" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .provider_picker;
    app.pickers.provider.stage = .form;
    app.pickers.provider.form_handle = .{ .builtin = .openrouter };

    provider_model.submitProviderSetup(&app, .openrouter) catch {};
    try std.testing.expect(app.pickers.provider.form_error != null);

    _ = try ProviderPicker.handle(&app, .{ .codepoint = 'a' });
    try std.testing.expect(app.pickers.provider.form_error == null);
}

/// A `vaxis.Key` carrying a two-byte UTF-8 text payload ('ğ'), as terminals
/// send it for pasted or IME-entered multibyte input.
fn multibyteKey() vaxis.Key {
    var key: vaxis.Key = .{ .codepoint = 0 };
    key.text = "ğ";
    return key;
}

test "session rename form appends printable and multibyte text, pops UTF-8 tails, submits and cancels" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.nav.session_action = .renaming;

    // Printable ASCII appends.
    try std.testing.expect(try SessionPicker.handleRenameInput(&app, .{ .codepoint = 'a' }));
    try std.testing.expectEqualStrings("a", app.input_buffers.session_rename_text.items);

    // Multibyte text appends whole graphemes.
    try std.testing.expect(try SessionPicker.handleRenameInput(&app, multibyteKey()));
    try std.testing.expectEqualStrings("ağ", app.input_buffers.session_rename_text.items);

    // Backspace pops the whole multibyte tail, not a partial byte.
    try std.testing.expect(try SessionPicker.handleRenameInput(&app, .{ .codepoint = vaxis.Key.backspace }));
    try std.testing.expectEqualStrings("a", app.input_buffers.session_rename_text.items);

    // Enter is swallowed (submitMode's session_picker dispatch owns the
    // rename confirm — handleRenameInput must not re-submit it), so the
    // sub-state stays open and the buffer is untouched.
    _ = try SessionPicker.handleRenameInput(&app, .{ .codepoint = vaxis.Key.backspace });
    try std.testing.expect(try SessionPicker.handleRenameInput(&app, .{ .codepoint = vaxis.Key.enter }));
    try std.testing.expectEqual(.renaming, app.nav.session_action);
    try std.testing.expectEqualStrings("", app.input_buffers.session_rename_text.items);

    // Esc also exits the sub-state and clears the buffer.
    app.nav.session_action = .renaming;
    _ = try SessionPicker.handleRenameInput(&app, .{ .codepoint = 'x' });
    try std.testing.expect(try SessionPicker.handleRenameInput(&app, .{ .codepoint = vaxis.Key.escape }));
    try std.testing.expectEqual(.browsing, app.nav.session_action);
    try std.testing.expectEqualStrings("", app.input_buffers.session_rename_text.items);

    // Non-editing keys (arrows, tab) are swallowed and report a change so the
    // overlay redraws.
    app.nav.session_action = .renaming;
    try std.testing.expect(try SessionPicker.handleRenameInput(&app, .{ .codepoint = vaxis.Key.down }));
}

test "project-root bind form appends printable and multibyte text, pops UTF-8 tails, swallows Enter and cancels" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.nav.session_action = .locating_project;

    try std.testing.expect(try SessionPicker.handleProjectRootInput(&app, .{ .codepoint = 'C' }));
    try std.testing.expectEqualStrings("C", app.input_buffers.project_root_text.items);

    try std.testing.expect(try SessionPicker.handleProjectRootInput(&app, multibyteKey()));
    try std.testing.expectEqualStrings("Cğ", app.input_buffers.project_root_text.items);

    try std.testing.expect(try SessionPicker.handleProjectRootInput(&app, .{ .codepoint = vaxis.Key.backspace }));
    try std.testing.expectEqualStrings("C", app.input_buffers.project_root_text.items);

    // Enter is swallowed here — the submitMode dispatch owns submission —
    // and the raw key must not append to the buffer.
    try std.testing.expect(try SessionPicker.handleProjectRootInput(&app, .{ .codepoint = vaxis.Key.enter }));
    try std.testing.expectEqualStrings("C", app.input_buffers.project_root_text.items);
    try std.testing.expectEqual(.locating_project, app.nav.session_action);

    // Esc cancels: buffer cleared and sub-state left.
    try std.testing.expect(try SessionPicker.handleProjectRootInput(&app, .{ .codepoint = vaxis.Key.escape }));
    try std.testing.expectEqual(.browsing, app.nav.session_action);
    try std.testing.expectEqualStrings("", app.input_buffers.project_root_text.items);
}

test "plugins add form appends printable and multibyte text, pops UTF-8 tails, confirms and cancels" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.pickers.plugins.adding = true;

    try std.testing.expect(try PluginsMode.handleAddInput(&app, .{ .codepoint = 'h' }));
    try std.testing.expectEqualStrings("h", app.input_buffers.plugin_store_url.items);

    try std.testing.expect(try PluginsMode.handleAddInput(&app, multibyteKey()));
    try std.testing.expectEqualStrings("hğ", app.input_buffers.plugin_store_url.items);

    try std.testing.expect(try PluginsMode.handleAddInput(&app, .{ .codepoint = vaxis.Key.backspace }));
    try std.testing.expectEqualStrings("h", app.input_buffers.plugin_store_url.items);

    // Enter confirms (empty store URL fails validation internally and is
    // swallowed) and closes the form.
    try std.testing.expect(try PluginsMode.handleAddInput(&app, .{ .codepoint = vaxis.Key.enter }));
    try std.testing.expect(!app.pickers.plugins.adding);
    try std.testing.expectEqualStrings("", app.input_buffers.plugin_store_url.items);

    // Esc cancels the form too.
    app.pickers.plugins.adding = true;
    _ = try PluginsMode.handleAddInput(&app, .{ .codepoint = 'x' });
    try std.testing.expect(try PluginsMode.handleAddInput(&app, .{ .codepoint = vaxis.Key.escape }));
    try std.testing.expect(!app.pickers.plugins.adding);
    try std.testing.expectEqualStrings("", app.input_buffers.plugin_store_url.items);
}

test "mcp add form appends printable and multibyte text, pops UTF-8 tails, confirms and cancels" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.pickers.mcp.adding = true;

    try std.testing.expect(try McpMode.handleAddInput(&app, .{ .codepoint = 'h' }));
    try std.testing.expectEqualStrings("h", app.input_buffers.mcp_url.items);

    try std.testing.expect(try McpMode.handleAddInput(&app, multibyteKey()));
    try std.testing.expectEqualStrings("hğ", app.input_buffers.mcp_url.items);

    try std.testing.expect(try McpMode.handleAddInput(&app, .{ .codepoint = vaxis.Key.backspace }));
    try std.testing.expectEqualStrings("h", app.input_buffers.mcp_url.items);

    // Enter confirms (empty server URL fails validation internally and is
    // swallowed) and closes the form.
    try std.testing.expect(try McpMode.handleAddInput(&app, .{ .codepoint = vaxis.Key.enter }));
    try std.testing.expect(!app.pickers.mcp.adding);
    try std.testing.expectEqualStrings("", app.input_buffers.mcp_url.items);

    // Esc cancels the form too.
    app.pickers.mcp.adding = true;
    _ = try McpMode.handleAddInput(&app, .{ .codepoint = 'x' });
    try std.testing.expect(try McpMode.handleAddInput(&app, .{ .codepoint = vaxis.Key.escape }));
    try std.testing.expect(!app.pickers.mcp.adding);
    try std.testing.expectEqualStrings("", app.input_buffers.mcp_url.items);
}
