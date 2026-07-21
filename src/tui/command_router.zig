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
        .command => try CommandMenu.handle(app, key),
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

/// Provider picker mode (provider list + API-key setup form).
///
/// The setup form hosts its own inline API-key editor: capture typed text
/// and backspace here so nothing leaks to the (unused) overlay search row.
/// In list stage, delegate to the picker widget's own handleKey.
const ProviderPicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (app.getProviderPicker().stage == .form) {
            if (key.matches(vaxis.Key.backspace, .{})) {
                app.popProviderKeyInput();
                return true;
            }
            if (key.text) |text| {
                try app.getProviderKeyInput().appendSlice(app.gpa, text);
                return true;
            }
            // Swallow everything else (arrows, tab) — Enter/Esc are handled upstream.
            return true;
        }
        return app.getProviderPicker().handleKey(key, app.isCodexSignedIn());
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
                .reasoning => try app.cycleSelectedReasoning(),
                .scope => app.cycleModelScope(),
            }
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            try app.stepModelSelection(false);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            try app.stepModelSelection(true);
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
const SessionPicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (key.matches('a', .{ .ctrl = true })) {
            app.toggleResumeGlobal();
            app.setResumeSelection(0);
            app.resumeClearFolds();
            try app.reloadResumeSessions();
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            // global mode means: the resume list is grouped by project, so
            // tab folds/unfolds the selected project. Otherwise tab is a
            // no-op (the picker has no other column to switch to).
            if (app.getResumeGlobal()) try app.toggleSelectedResumeProject();
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

/// Normal-mode transcript navigation (block nav, @-mention popup, lane switch).
///
/// The largest arm — split into three sub-handlers (R2.8a/b/c) that each
/// own one concern: mention popup selection, block navigation, and
/// multi-lane switching. Each sub-handler returns true if it consumed
/// the key; Transcript.handle short-circuits and returns. The full arm
/// body still lives in `App.handleTranscriptKey` for the bits not yet
/// extracted.
const Transcript = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        // R2.8a: @-mention popup owns up/down while active.
        if (try MentionPopup.handle(app, key)) return true;
        // R2.8b: block navigation owns shift+down and plain up/down.
        if (try BlockNav.handle(app, key)) return true;
        // R2.8c: lane switching and transcript toggle (lands later).
        return app.handleTranscriptKey(key);
    }
};

/// R2.8a: @-mention popup selection.
///
/// When the @-mention popup is open with results, up/down move the
/// selection through the result list. Other keys fall through.
const MentionPopup = struct {
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
const BlockNav = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
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
                app.setBlockNav(false);
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

/// R2.8c stub: still in App.handleTranscriptKey. Lands in R2.8c.
const LaneSwitch = struct {
    pub fn handle(_: *App, _: vaxis.Key) !bool {
        @panic("LaneSwitch.handle: R2.8b stub — implementation lands in R2.8c");
    }
};
