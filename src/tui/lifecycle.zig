//! App lifecycle entrypoints — deinit and the periodic tick handler.
//!
//! Pulled out of `tui.zig` (R6.3 of `_pm/Projects/tui-split`) — free functions
//! taking `*App` so the two directions of the `App`/module boundary stay clean:
//! the function reads `App` fields and calls pub methods; `tui.zig` keeps a
//! one-line delegate so existing inline tests resolve via the struct.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const codex = @import("../codex.zig");

const App = tui.App;

/// Tear down every lane, background job, picker, cache, and input buffer.
/// Called once at clean exit (or when switching to a new `initRuntime` session).
pub fn deinitApp(self: *App) void {
    // Cancel every lane's in-flight turn (background lanes may still be
    // running) so no worker thread outlives the App.
    for (self.threads.items) |lane| {
        if (lane.turn_future) |*future| {
            if (lane.worker_context) |*worker| worker.requestCancel();
            _ = future.cancel(self.io);
            lane.turn_future = null;
        }
        self.cancelLaneNaming(lane);
    }
    // Now that no worker can still be inside `manager.start`, terminate and
    // join every background job (kills the whole process tree on Windows via
    // the per-job Job Object). Jobs hold an opaque owner token that is never
    // dereferenced, so this is independent of lane/agent teardown order.
    if (self.background) |manager| {
        manager.deinit();
        self.gpa.destroy(manager);
        self.background = null;
    }
    for (self.background_modal_state.pending.items) |*delivery| self.freeDelivery(delivery);
    self.background_modal_state.pending.deinit(self.gpa);
    // Cancel the in-flight load first (it needs `io`), then free the
    // catalogue's owned lists + error in one pass.
    self.cancelModelLoad();
    for (self.retired_transcripts.items) |*transcript| transcript.deinit(self.gpa);
    self.retired_transcripts.deinit(self.gpa);
    self.resumeClear();
    self.resumeClearFolds();
    self.resume_folded_projects.deinit(self.gpa);
    self.pickers.tree.deinit();
    self.cancelDiffRefresh();
    // Non-empty labels are always heap-allocated by `loadGitLabel`; the
    // empty default is a literal, so guard on length before freeing.
    if (self.metrics.git_label.len > 0) self.gpa.free(self.metrics.git_label);
    if (self.metrics.diff_cache) |raw| self.gpa.free(raw);
    self.pickers.models.deinit(self.gpa);
    codex.freeApiKeyMap(self.gpa, &self.provider_api_keys);
    self.provider_key_input.deinit(self.gpa);
    if (self.cached_config_owned) {
        self.cached_config.deinit(self.gpa);
        self.cached_config_owned = false;
    }
    self.closeAtSearch();
    self.at_search.results.deinit(self.gpa);
    self.clearLanesState();
    for (self.threads.items) |lane| {
        lane.deinit(self.gpa);
        self.gpa.destroy(lane);
    }
    self.threads.deinit(self.gpa);
    self.diff.deinit(self.gpa);
    self.inputs.input.deinit();
    self.inputs.palette.deinit();
    self.inputs.comment.deinit();
    self.* = undefined;
}
