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
const agent_mod = @import("../agent.zig");
const blackhole = @import("../tui/blackhole.zig");
const codex = @import("../codex.zig");

const App = tui.App;
const RootWidget = tui.RootWidget;

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

/// Periodic frame-level tick: drain agent events, model loads, diff refreshes,
/// lanes naming, background completion, spinner animation, and the black-hole
/// intro. Re-schedules itself when work is still pending.
pub fn handleTick(root: *RootWidget, ctx: *vxfw.EventContext) !void {
    var visible_change = try drainAgentEvents(root, ctx);
    if (try root.app.drainModelLoad()) visible_change = true;
    if (try root.app.drainDiffRefresh()) visible_change = true;
    // Lanes whose branch name landed get renamed in place.
    if (try root.app.drainLaneNaming()) visible_change = true;
    // Collect any finished background jobs, then deliver buffered completions
    // to idle lanes (notice + a turn to answer them).
    if (try root.app.pollBackgroundJobs()) visible_change = true;
    if (try root.app.deliverPendingBackground()) visible_change = true;

    if (root.app.thread.turn_view.awaitingOutput() or root.app.thread.transcript.hasRunningTool()) {
        root.spinner_tick_accum += RootWidget.drain_tick_ms;
        if (root.spinner_tick_accum >= RootWidget.spinner_tick_threshold_ms) {
            root.spinner_tick_accum = 0;
            root.app.advanceLoadingFrame();
            visible_change = true;
        }
    } else {
        root.spinner_tick_accum = 0;
    }

    if (root.diff_refresh_pending) {
        root.diff_tick_accum += RootWidget.drain_tick_ms;
        if (root.diff_tick_accum >= RootWidget.diff_tick_threshold_ms) {
            root.diff_tick_accum = 0;
            root.diff_refresh_pending = false;
            try root.app.scheduleDiffRefresh();
        }
    } else {
        root.diff_tick_accum = 0;
    }

    if (root.app.metrics.blackhole_visible) {
        // Carry the remainder so the average interval tracks ~24 fps even
        // though the host tick (30 ms) is coarser than the frame interval.
        root.blackhole_tick_accum += RootWidget.drain_tick_ms;
        while (root.blackhole_tick_accum >= blackhole.frame_interval_ms) {
            root.blackhole_tick_accum -= blackhole.frame_interval_ms;
            root.app.advanceBlackholeFrame();
            visible_change = true;
        }
    } else {
        root.blackhole_tick_accum = 0;
    }

    const model_loading = root.app.pickers.models.model_load_future != null;
    const diff_loading = root.app.metrics.diff_refresh_future != null;
    // Keep ticking while a turn is active OR interrupting, so the worker's
    // remaining events (and its terminal `turn_finished`) get drained.
    const should_tick = root.app.anyTurnActive() or
        model_loading or
        diff_loading or
        root.app.metrics.blackhole_visible or
        root.diff_refresh_pending or
        root.app.backgroundActive() or
        root.app.namingActive();
    if (should_tick) {
        try ctx.tick(RootWidget.drain_tick_ms, root.widget());
    } else {
        root.app.metrics.loading_tick_active = false;
    }

    if (visible_change) {
        ctx.consumeAndRedraw();
    } else {
        ctx.consumeEvent();
    }
}

/// Drain all agent events queued on every lane's worker and project them onto
/// the relevant lane's thread state. Returns true when any visible state changed.
fn drainAgentEvents(root: *RootWidget, ctx: *vxfw.EventContext) !bool {
    var visible_change = false;
    var refresh_diff = false;
    const active = root.app.thread;
    // Each lane runs its own turn, so drain every lane's queue and apply its
    // events to *that* lane. The Turn machine operates on `self.thread`, so
    // scope-swap it to the lane being processed (UI-thread only) and restore
    // the visible lane afterward.
    for (root.app.threads.items) |lane| {
        const worker = if (lane.worker_context) |*wc| wc else continue;
        var batch: std.ArrayList(*agent_mod.Agent.Event) = .empty;
        defer batch.deinit(worker.gpa);
        try worker.queue.drainInto(worker.io, worker.gpa, &batch);
        if (batch.items.len == 0) continue;

        root.app.thread = lane;
        defer root.app.thread = active;
        for (batch.items) |event_ptr| {
            defer worker.gpa.destroy(event_ptr);
            defer event_ptr.deinit(worker.gpa);

            // A discarded (interrupted) turn's events are swallowed inside
            // applyAgentEvent — the Turn machine refuses to project them.
            const changed = try root.app.applyAgentEvent(event_ptr.*);
            if (lane != active) continue; // a background lane never touches the view
            if (changed) visible_change = true;
            switch (event_ptr.*) {
                .tool_call_finished => refresh_diff = true,
                else => {},
            }
            if (lane.turn_view.awaitingOutput()) try tui.RootWidget.ensureTick(root, ctx);
        }
    }
    if (refresh_diff) {
        root.diff_refresh_pending = true;
    }
    return visible_change;
}
