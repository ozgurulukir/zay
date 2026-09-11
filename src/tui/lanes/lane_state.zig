//! Lane state and navigation management — extracted from `lane_lifecycle.zig`.
//!
//! Handles activeIndex, cycling lanes, cycling split modes (dual/grid/tab),
//! and shifting focused worker panes.

const std = @import("std");
const tui = @import("../../tui.zig");

const App = tui.App;
const Thread = tui.Thread;
const max_threads = tui.max_threads;
const branch_naming = @import("branch_naming.zig");
const merge_flow = @import("merge_flow.zig");

pub fn activeIndex(app: *const App) u32 {
    std.debug.assert(app.threads.len() > 0);
    std.debug.assert(app.threads.len() <= max_threads);
    for (app.threads.slice(), 0..) |lane, index| {
        if (lane == app.thread) return @intCast(index);
    }
    return 0;
}

pub fn cycleLane(app: *App, delta: i32) void {
    const n = app.threads.len();
    std.debug.assert(n >= 1);
    std.debug.assert(n <= max_threads);
    if (n < 2) return;
    if (app.split_mode == .dual) {
        shiftFocusedWorker(app, delta);
        return;
    }
    const cur: i32 = @intCast(activeIndex(app));
    const next: usize = @intCast(@mod(cur + delta, @as(i32, @intCast(n))));
    app.thread = app.threads.slice()[next];
    app.nav.block_nav = false;
    app.clearInput();
}

pub fn cycleSplitMode(app: *App) void {
    if (app.threads.len() < 2) return;
    switch (app.split_mode) {
        .dual => app.split_mode = .grid,
        .grid => app.split_mode = .tab,
        .tab => enterDual(app),
    }
}

pub fn enterDual(app: *App) void {
    if (app.threads.len() < 2) return;
    app.split_mode = .dual;
    app.thread = app.threads.slice()[0];
    app.clearInput();
}

pub fn cycleFocusedWorker(app: *App) void {
    shiftFocusedWorker(app, 1);
}

pub fn shiftFocusedWorker(app: *App, delta: i32) void {
    const n = app.threads.len();
    if (n < 2) return;
    const max_worker: i32 = @intCast(n - 1);
    const cur: i32 = @intCast(app.focused_worker_index);
    app.focused_worker_index = @intCast(@mod(cur - 1 + delta, max_worker) + 1);
}

pub fn switchToNextLane(app: *App) void {
    cycleLane(app, 1);
}

pub fn anyLaneTurnActive(app: *const App) bool {
    std.debug.assert(app.threads.len() > 0);
    std.debug.assert(app.threads.len() <= max_threads);
    for (app.threads.slice()) |lane| {
        if (lane.turn.isActive()) return true;
    }
    return false;
}

pub fn anyTurnActive(app: *const App) bool {
    std.debug.assert(app.threads.len() > 0);
    std.debug.assert(app.threads.len() <= max_threads);
    for (app.threads.slice()) |lane| {
        if (lane.turn.state != .idle) return true;
    }
    return false;
}

pub fn closeActiveLane(app: *App) !void {
    // `cancel_job` covers the post-idle window where an interrupted worker is
    // still unwinding — its runtime must not be torn down under it.
    if (app.thread.turn.isActive() or app.thread.cancel_job != null) return error.InFlightTurn;
    const index: u32 = activeIndex(app);
    std.debug.assert(index < app.threads.len());
    if (index == 0) return error.CannotClosePrimaryLane;

    const lane = app.threads.slice()[index];
    try merge_flow.clearWorkspaceBorrows(app, lane);
    branch_naming.cancelLaneNaming(app, lane);
    app.thread = app.threads.slice()[index - 1];
    merge_flow.discardUndeliveredCompletion(app, lane);
    _ = app.threads.orderedRemove(index);
    lane.deinit(app.gpa);
    app.gpa.destroy(lane);

    app.nav.block_nav = false;
    app.clearInput();
}
