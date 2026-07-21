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
/// R2.1 stub: forwards to `App.handleTreePickerKey`. Real implementation
/// lands in R2.2.
const TreePicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        return app.handleTreePickerKey(key);
    }
};

/// Provider picker mode (provider list + API-key setup form).
///
/// R2.1 stub: forwards to `App.handleProviderPickerKey`. Real
/// implementation lands in R2.3.
const ProviderPicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        return app.handleProviderPickerKey(key);
    }
};

/// Model picker mode (column switcher + row navigation + reasoning/scope).
///
/// R2.1 stub: forwards to `App.handleModelPickerKey`. Real implementation
/// lands in R2.4.
const ModelPicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        return app.handleModelPickerKey(key);
    }
};

/// Resume-session picker mode (project grouping + selection navigation).
///
/// R2.1 stub: forwards to `App.handleSessionPickerKey`. Real implementation
/// lands in R2.5.
const SessionPicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        return app.handleSessionPickerKey(key);
    }
};

/// Lanes manager mode (parallel-lane picker + parked-lane management).
///
/// R2.1 stub: forwards to `App.handleLanesKey`. Real implementation lands
/// in R2.6.
const Lanes = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        return app.handleLanesKey(key);
    }
};

/// Slash-command menu mode.
///
/// R2.1 stub: forwards to `App.handleCommandMenuKey`. Real implementation
/// lands in R2.7.
const CommandMenu = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        return app.handleCommandMenuKey(key);
    }
};

/// Normal-mode transcript navigation (block nav, @-mention popup, lane switch).
///
/// R2.1 stub: forwards to `App.handleTranscriptKey`. Real implementation
/// lands in R2.8. The largest arm — handles the most keys and the most
/// state transitions.
const Transcript = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        return app.handleTranscriptKey(key);
    }
};
