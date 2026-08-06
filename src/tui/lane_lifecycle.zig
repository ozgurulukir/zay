//! Lane lifecycle: lane naming, cycling, closing, merging, and the `/lanes`
//! overlay. Free functions taking `*App` — extracted from `tui.zig` (Phase 1 of
//! `_pm/Projects/tui-domain-extract`).

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const agent_mod = @import("../agent.zig");
const agent_worker = @import("agent_worker.zig");
const lane_bridge = tui.lane_bridge_mod;
const lanes_util = @import("lanes.zig");
const lanes_picker = @import("widgets/lanes_picker.zig");
const naming_mod = @import("naming.zig");
const turn_view_mod = @import("turn_view.zig");
const queue_mod = @import("queue.zig");
const runtime_mod = @import("../runtime.zig");
const command_router = @import("command_router.zig");
const vcs = @import("../vcs.zig");

const App = tui.App;
const Thread = tui.Thread;

// ---------------------------------------------------------------------------
// Internal helpers (no delegate — called only within this module)
// ---------------------------------------------------------------------------

pub fn activeIndex(app: *const App) usize {
    for (app.threads.items, 0..) |lane, index| {
        if (lane == app.thread) return index;
    }
    return 0;
}

/// The directory to run a merge in for `lane` as the destination: its
/// worktree path, or the repo root for the primary lane.
fn laneMergeDir(app: *App, lane: *Thread) ?[]const u8 {
    if (lanes_util.workingLaneOf(lane)) |w| return w.path;
    return app.repoRoot();
}

/// Whether an open lane's worktree lives at `path`. Compares the final path
/// segment (the unique lane id) so it survives git reporting forward slashes
/// where the stored path uses the platform separator.
fn laneOpenAtPath(app: *App, path: []const u8) bool {
    for (app.threads.items) |lane| {
        if (lanes_util.workingLaneOf(lane)) |w| {
            if (std.mem.eql(u8, lanes_util.lastPathSegment(w.path), lanes_util.lastPathSegment(path))) return true;
        }
    }
    return false;
}

/// Point `lane`'s working branch at `nova/<slug>` — the git rename plus the
/// lane's own records (branch string, label). False when the lane has no
/// working branch or the new name is taken.
fn renameLaneBranch(app: *App, lane: *Thread, slug: []const u8) !bool {
    const live = switch (lane.engine) {
        .live => |*l| l,
        .idle => return false,
    };
    const working = switch (live.lane) {
        .working => |*w| w,
        .primary => return false,
    };

    const branch = try std.fmt.allocPrint(app.gpa, "nova/{s}", .{slug});
    errdefer app.gpa.free(branch);
    const title = try app.gpa.dupe(u8, branch);
    errdefer app.gpa.free(title);

    vcs.renameBranch(app.gpa, app.io, live.runtime.cwd, working.branch, branch) catch {
        // Taken (or git refused) — the hex branch stays; not an error.
        app.gpa.free(branch);
        app.gpa.free(title);
        return false;
    };

    app.gpa.free(working.branch);
    working.branch = branch;
    // The lane's label is its branch from here on.
    if (lane.title) |old| app.gpa.free(old);
    lane.title = title;
    return true;
}

/// Tear down the working lane at `index` and DELETE its git worktree +
/// branch. Used for a merged source (its work now lives in the destination) —
/// unlike `/close`, which parks. Caller must ensure `index != 0` (never the
/// primary) and, if `index` is the active lane, point `app.thread` at a
/// survivor first.
fn abandonLane(app: *App, index: usize) !void {
    const lane = app.threads.items[index];
    var branch: ?[]u8 = null;
    var dir: ?[]u8 = null;
    if (lanes_util.workingLaneOf(lane)) |w| {
        branch = try app.gpa.dupe(u8, w.branch);
        dir = try app.gpa.dupe(u8, w.path);
    }
    defer if (branch) |b| app.gpa.free(b);
    defer if (dir) |d| app.gpa.free(d);

    cancelLaneNaming(app, lane);
    _ = app.threads.orderedRemove(index);
    lane.deinit(app.gpa);
    app.gpa.destroy(lane);

    if (app.repoRoot()) |repo| {
        if (dir) |d| vcs.worktreeRemove(app.gpa, app.io, repo, d) catch {};
        if (branch) |b| vcs.deleteBranch(app.gpa, app.io, repo, b) catch {};
    }
}

/// On-disk `nova/*` worktrees that are NOT currently open as lanes — the
/// parked lanes. Caller owns the result (free via `vcs.freeWorktreeList`).
/// Pub: the lane-bridge `list` op surfaces them to the model (L1).
pub fn collectParkedLanes(app: *App, repo: []const u8) ![]vcs.WorktreeEntry {
    const all = try vcs.worktreeList(app.gpa, app.io, repo);
    defer vcs.freeWorktreeList(app.gpa, all);

    var out: std.ArrayList(vcs.WorktreeEntry) = .empty;
    errdefer {
        for (out.items) |*entry| entry.deinit(app.gpa);
        out.deinit(app.gpa);
    }
    for (all) |entry| {
        if (!std.mem.startsWith(u8, entry.branch, "nova/")) continue;
        if (laneOpenAtPath(app, entry.path)) continue;
        const path_dup = try app.gpa.dupe(u8, entry.path);
        errdefer app.gpa.free(path_dup);
        const branch_dup = try app.gpa.dupe(u8, entry.branch);
        errdefer app.gpa.free(branch_dup);
        try out.append(app.gpa, .{ .path = path_dup, .branch = branch_dup });
    }
    return out.toOwnedSlice(app.gpa);
}

/// Reload the parked-lane list in place (after a merge/delete) and clamp the
/// selection. Keeps the `/lanes` window open.
fn reloadParkedLanes(app: *App) !void {
    const repo = app.repoRoot() orelse return;
    if (app.parked_lanes.len > 0) {
        vcs.freeWorktreeList(app.gpa, app.parked_lanes);
        app.parked_lanes = &.{};
    }
    app.parked_lanes = try collectParkedLanes(app, repo);
    if (app.nav.lanes_selection >= app.parked_lanes.len) {
        app.nav.lanes_selection = if (app.parked_lanes.len == 0) 0 else @intCast(app.parked_lanes.len - 1);
    }
}

/// S17 invariant 1: a lane whose worktree path some agent's `workspace`
/// borrows may not be torn down while that agent's turn is active (the
/// in-flight batch's executor holds the path borrow — freeing it mid-batch
/// would dangle every call after the `lane` tool in the same batch). Once the
/// owner is idle the borrow is dropped first: refuse-then-reset, never
/// reset-through. Only the driver enters lanes, so this is a single owner in
/// practice, but it scans every agent defensively. Every path that frees a
/// lane worktree checks this — open lanes and parked lanes alike (parked
/// lanes can't be entered, so the parked check is defense in depth).
fn clearWorkspaceBorrowForPath(app: *App, path: []const u8) !void {
    for (app.threads.items) |other| {
        const agent = other.agent orelse continue;
        const ws = agent.workspaceBorrow() orelse continue;
        if (!std.mem.eql(u8, ws, path)) continue;
        if (other.turn.isActive()) return error.InFlightTurn;
        agent.setWorkspace(null);
    }
}

fn clearWorkspaceBorrows(app: *App, lane: *Thread) !void {
    const path = if (lanes_util.workingLaneOf(lane)) |w| w.path else return;
    return clearWorkspaceBorrowForPath(app, path);
}

/// Merge `source` into `dest`, then remove the source lane (its work now
/// lives in the destination). Refused if either lane has a turn in flight, or
/// if the merge conflicts (rolled back — the destination is untouched). On
/// success `dest` becomes the active lane. Leaves `mode`/picker state to the
/// caller so `/lanes` can stay open while `/merge` closes.
fn mergeLane(app: *App, source: lanes_util.MergeSource, dest: *Thread) !void {
    if (dest.turn.isActive()) return error.InFlightTurn;
    if (source.active_index) |si| {
        if (app.threads.items[si].turn.isActive()) return error.InFlightTurn;
    }
    // S17: the source path may be the driver's workspace borrow — checked for
    // open and parked sources alike (see `clearWorkspaceBorrowForPath`).
    try clearWorkspaceBorrowForPath(app, source.path);
    const dest_dir = laneMergeDir(app, dest) orelse return error.NoActiveRuntime;

    if (try vcs.workingTreeDirty(app.gpa, app.io, source.path)) {
        try vcs.commitAll(app.gpa, app.io, source.path, "nova: merge lane");
    }

    switch (try vcs.merge(app.gpa, app.io, dest_dir, source.branch)) {
        .conflict => return error.MergeConflict,
        .ok => {},
    }

    app.thread = dest;
    if (source.active_index) |si| {
        try abandonLane(app, si);
    } else if (app.repoRoot()) |repo| {
        vcs.worktreeRemove(app.gpa, app.io, repo, source.path) catch {};
        vcs.deleteBranch(app.gpa, app.io, repo, source.branch) catch {};
    }

    if (app.threads.items.len < 2) app.split = false;
    app.nav.block_nav = false;
}

// ---------------------------------------------------------------------------
// Delegated public functions
// ---------------------------------------------------------------------------

/// Cycle to the next lane (wrapping). No-op with a single lane.
pub fn switchToNextLane(app: *App) void {
    cycleLane(app, 1);
}

/// Copy the tail of the current lane's conversation (user + agent text,
/// oldest first) as naming context for a lane forked from it.
pub fn captureLaneContext(app: *App, max: usize) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |message| app.gpa.free(message);
        out.deinit(app.gpa);
    }
    const messages = app.thread.transcript.messages.items;
    var index = messages.len;
    while (index > 0 and out.items.len < max) {
        index -= 1;
        const message = messages[index];
        if (message != .user and message != .agent) continue;
        const body: []const u8 = switch (message) {
            .user => |m| m.body,
            .agent => |m| m.body,
            else => continue,
        };
        if (body.len == 0) continue;
        try out.append(app.gpa, try app.gpa.dupe(u8, body));
    }
    std.mem.reverse([]u8, out.items);
    return out.toOwnedSlice(app.gpa);
}

/// Ask the session's model (via the lane runtime's dedicated naming
/// client) to name the lane's branch from its first prompt + the captured
/// parent context. Fire-and-forget: the turn runs regardless, and
/// `drainLaneNaming` renames the hex branch when the result lands.
pub fn scheduleLaneNaming(app: *App, lane: *Thread, first_message: []const u8) !void {
    if (lane.naming_future != null) return;
    const runtime = switch (lane.engine) {
        .live => |live| live.runtime,
        .idle => return,
    };
    if (runtime.naming_client == .none) return;

    const first = try app.gpa.dupe(u8, first_message);
    errdefer app.gpa.free(first);
    const job = try app.gpa.create(naming_mod.BranchJob);
    job.* = .{
        .gpa = app.gpa,
        .io = app.io,
        .client = runtime.naming_client,
        .limiter = app.request_limiter,
        .context = lane.parent_context,
        .first_message = first,
        .done = &lane.naming_done,
    };
    lane.parent_context = &.{};
    lane.naming_done.store(false, .release);
    lane.naming_future = app.io.concurrent(naming_mod.runBranchJob, .{job}) catch |err| {
        job.deinit();
        app.gpa.destroy(job);
        return err;
    };
}

/// Called from the tick handler: rename any lane whose branch name landed —
/// `nova/<hex>` becomes `nova/<slug>` in place (worktree HEADs follow), and
/// the branch becomes the lane's label. A rejected or colliding name simply
/// leaves the hex branch.
pub fn drainLaneNaming(app: *App) !bool {
    var changed = false;
    for (app.threads.items) |lane| {
        if (lane.naming_future == null) continue;
        if (!lane.naming_done.load(.acquire)) continue;
        var outcome = lane.naming_future.?.await(app.io);
        lane.naming_future = null;
        lane.naming_done.store(false, .release);
        defer outcome.deinit(app.gpa);
        const slug = outcome.slug orelse continue;
        if (try renameLaneBranch(app, lane, slug)) changed = true;
    }
    return changed;
}

/// Cancel an in-flight branch-naming future for `lane`. Safe to call when
/// there is none (no-op).
pub fn cancelLaneNaming(app: *App, lane: *Thread) void {
    if (lane.naming_future) |*future| {
        var outcome = future.cancel(app.io);
        outcome.deinit(app.gpa);
        lane.naming_future = null;
    }
    lane.naming_done.store(false, .release);
}

/// Whether any lane has an async branch-naming job in flight — the tick
/// must stay alive for the result to be drained.
pub fn namingActive(app: *const App) bool {
    for (app.threads.items) |lane| {
        if (lane.naming_future != null) return true;
    }
    return false;
}

/// Surface a lane-operation error in the transcript and reset to normal mode.
pub fn reportLaneError(app: *App, err: anyerror) !void {
    app.mode = .normal;
    app.clearInput();
    clearLanesState(app);
    const message = try std.fmt.allocPrint(app.gpa, "Lane operation failed: {s}", .{lanes_util.laneErrorText(err)});
    defer app.gpa.free(message);
    _ = try app.thread.transcript.append(app.gpa, .agent, "agent", message);
}

/// True while any lane has a turn in flight — keeps the drain/animation tick
/// alive so background lanes' events (and their terminal `turn_finished`)
/// keep draining even when the visible lane is idle.
pub fn anyTurnActive(app: *const App) bool {
    for (app.threads.items) |lane| {
        if (lane.turn.state != .idle) return true;
    }
    return false;
}

/// Cycle the active lane by `delta` (+1 next, -1 previous), wrapping at both
/// ends. No-op with a single lane.
pub fn cycleLane(app: *App, delta: i32) void {
    const n = app.threads.items.len;
    if (n < 2) return;
    const cur: i32 = @intCast(activeIndex(app));
    const next: usize = @intCast(@mod(cur + delta, @as(i32, @intCast(n))));
    app.thread = app.threads.items[next];
    app.nav.block_nav = false;
    app.clearInput();
}

/// Toggle between the tiled split view and fullscreening the active lane.
pub fn toggleLaneFullscreen(app: *App) void {
    if (app.threads.items.len < 2) return;
    app.split = !app.split;
}

/// Close the active lane by *parking* it: tear down its runtime and drop it
/// from the split grid, but PRESERVE its git worktree and branch on disk so it
/// can be merged or deleted later from `/lanes`. Its conversation stays
/// resumable via `/resume`. The primary lane (index 0) can't be closed.
/// Refused mid-turn.
pub fn closeActiveLane(app: *App) !void {
    if (app.thread.turn.isActive()) return error.InFlightTurn;
    const index = activeIndex(app);
    if (index == 0) return error.CannotClosePrimaryLane;

    const lane = app.threads.items[index];
    // S17: the driver's workspace may borrow this lane's path — refuse while
    // the owner's turn is active, drop the borrow once it is idle.
    try clearWorkspaceBorrows(app, lane);
    cancelLaneNaming(app, lane);
    app.thread = app.threads.items[index - 1];
    _ = app.threads.orderedRemove(index);
    lane.deinit(app.gpa);
    app.gpa.destroy(lane);

    app.nav.block_nav = false;
    app.clearInput();
}

/// `/merge`: fold the current (working) lane into another. Refused mid-turn or
/// from the primary lane. With exactly one other lane, merge immediately;
/// otherwise open the destination picker (`Mode.lanes`, `.merge_dest`).
pub fn createMergePicker(app: *App) !void {
    if (app.thread.turn.isActive()) return error.InFlightTurn;
    const src_index = activeIndex(app);
    if (src_index == 0) return error.CannotMergePrimaryLane;
    const src = lanes_util.workingLaneOf(app.thread) orelse return error.CannotMergePrimaryLane;
    if (app.threads.items.len < 2) return error.NoMergeDestination;

    const source: lanes_util.MergeSource = .{ .branch = src.branch, .path = src.path, .active_index = src_index };

    if (app.threads.items.len == 2) {
        const dest = app.threads.items[if (src_index == 0) 1 else 0];
        defer {
            app.clearPaletteInput();
            clearLanesState(app);
        }
        try mergeLane(app, source, dest);
        app.mode = .normal;
        app.clearInput();
        return;
    }

    var dests: std.ArrayList(usize) = .empty;
    errdefer dests.deinit(app.gpa);
    for (app.threads.items, 0..) |_, i| {
        if (i != src_index) try dests.append(app.gpa, i);
    }
    clearLanesState(app);
    app.merge_dest_indices = try dests.toOwnedSlice(app.gpa);
    app.merge_source_index = src_index;
    app.nav.lanes_purpose = .merge_dest;
    app.nav.lanes_selection = 0;
    app.mode = .lanes;
    app.clearInput();
    app.clearPaletteInput();
}

/// Enter in the `/merge` destination picker: merge the source lane into the
/// selected destination and close the picker.
pub fn confirmMergeDest(app: *App) !void {
    defer {
        app.clearPaletteInput();
        clearLanesState(app);
    }
    if (app.merge_dest_indices.len == 0 or app.nav.lanes_selection >= app.merge_dest_indices.len) {
        app.mode = .normal;
        app.clearInput();
        return;
    }
    const dest = app.threads.items[app.merge_dest_indices[app.nav.lanes_selection]];
    const src = lanes_util.workingLaneOf(app.threads.items[app.merge_source_index]) orelse {
        app.mode = .normal;
        app.clearInput();
        return;
    };
    const source: lanes_util.MergeSource = .{ .branch = src.branch, .path = src.path, .active_index = app.merge_source_index };
    mergeLane(app, source, dest) catch |err| {
        try reportLaneError(app, err);
        return;
    };
    app.mode = .normal;
    app.clearInput();
}

/// `/lanes`: list parked `nova/*` worktrees (closed lanes still on disk) for
/// merge (M) or deletion (X).
pub fn openLanesPicker(app: *App) !void {
    const repo = app.repoRoot() orelse return error.NoActiveRuntime;
    clearLanesState(app);
    app.parked_lanes = try collectParkedLanes(app, repo);
    app.nav.lanes_purpose = .manage;
    app.nav.lanes_selection = 0;
    app.mode = .lanes;
    app.clearInput();
    app.clearPaletteInput();
}

/// `/lanes` → M: merge the selected parked worktree into the current lane,
/// remove it, and keep the window open on the reloaded list.
pub fn mergeSelectedParked(app: *App) !void {
    if (app.nav.lanes_selection >= app.parked_lanes.len) return;
    const entry = app.parked_lanes[app.nav.lanes_selection];
    const source: lanes_util.MergeSource = .{ .branch = entry.branch, .path = entry.path, .active_index = null };
    try mergeLane(app, source, app.thread);
    try reloadParkedLanes(app);
}

/// `/lanes` → X: delete the selected parked worktree and its branch.
pub fn deleteSelectedParked(app: *App) !void {
    if (app.nav.lanes_selection >= app.parked_lanes.len) return;
    const entry = app.parked_lanes[app.nav.lanes_selection];
    // S17 (defensive): a parked lane can't be entered, so this never holds a
    // borrow in practice — but every path that frees a lane path checks.
    try clearWorkspaceBorrowForPath(app, entry.path);
    if (app.repoRoot()) |repo| {
        vcs.worktreeRemove(app.gpa, app.io, repo, entry.path) catch {};
        vcs.deleteBranch(app.gpa, app.io, repo, entry.branch) catch {};
    }
    try reloadParkedLanes(app);
}

/// Number of rows in the lanes overlay for the current purpose.
pub fn laneEntryCount(app: *const App) u32 {
    return switch (app.nav.lanes_purpose) {
        .manage => @intCast(app.parked_lanes.len),
        .merge_dest => @intCast(app.merge_dest_indices.len),
    };
}

/// Free the lanes-overlay working state (parked list + destination indices).
pub fn clearLanesState(app: *App) void {
    if (app.parked_lanes.len > 0) {
        vcs.freeWorktreeList(app.gpa, app.parked_lanes);
        app.parked_lanes = &.{};
    }
    if (app.merge_dest_indices.len > 0) {
        app.gpa.free(app.merge_dest_indices);
        app.merge_dest_indices = &.{};
    }
    app.nav.lanes_selection = 0;
}

/// Rows for the lanes overlay, arena-allocated each draw (strings borrowed
/// from `parked_lanes` / `threads`).
pub fn buildLaneEntries(app: *App, arena: std.mem.Allocator) ![]lanes_picker.Entry {
    switch (app.nav.lanes_purpose) {
        .manage => {
            const out = try arena.alloc(lanes_picker.Entry, app.parked_lanes.len);
            for (app.parked_lanes, 0..) |entry, i| {
                out[i] = .{ .title = entry.branch, .subtitle = entry.path };
            }
            return out;
        },
        .merge_dest => {
            const out = try arena.alloc(lanes_picker.Entry, app.merge_dest_indices.len);
            for (app.merge_dest_indices, 0..) |ti, i| {
                const lane = app.threads.items[ti];
                out[i] = .{
                    .title = lane.title orelse (if (ti == 0) "primary" else "lane"),
                    .subtitle = if (lanes_util.workingLaneOf(lane)) |w| w.branch else "(primary working copy)",
                };
            }
            return out;
        },
    }
}

/// Route a `/lanes` key event. Returns true when the key changed visible
/// state (caller redraws).
pub fn handleLanesKey(app: *App, key: vaxis.Key) !bool {
    return command_router.Lanes.handle(app, key);
}

// ---------------------------------------------------------------------------
// Model-driven lanes: the `lane` tool's bridge service (S1-S15)
// ---------------------------------------------------------------------------

const Resp = lane_bridge.Response;

/// Response builders that trap on OOM — if the allocator is gone while
/// building a lane response the process is doomed anyway, and trapping beats
/// leaving a worker blocked on the bridge forever.
fn resp(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype, lane_id: ?[]const u8, path: ?[]const u8) Resp {
    return lane_bridge.response(gpa, fmt, args, lane_id, path) catch unreachable;
}

fn failResp(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Resp {
    return lane_bridge.fail(gpa, fmt, args) catch unreachable;
}

/// A running worker that has emitted NO event for this long is reported as
/// possibly stalled to an orchestrator (`lane read`/`await`/`list`). Generous:
/// model requests legitimately stream for minutes and a long bash call (raised
/// timeout) is silent for its whole run; the stall signal is "zero events at
/// all", which a blocked network read or hung tool produces indefinitely.
const worker_stall_ms: i64 = 180 * std.time.ms_per_s;

/// Whether `lane`'s active turn has produced no event for at least
/// `worker_stall_ms` — the signal an orchestrator uses to stop polling and act
/// (`lane cancel` / `lane steer`). `last_activity_ms == 0` means no baseline
/// yet (fresh worker awaiting its first token), never a stall.
fn laneStalled(lane: *const Thread, now_ms: i64) bool {
    if (lane.turn.state != .active) return false;
    if (lane.last_activity_ms == 0) return false;
    return now_ms - lane.last_activity_ms >= worker_stall_ms;
}

/// One-line activity summary for a lane, surfaced by `lane list` and as the
/// status prefix of `lane read`/`await`. For a running worker it reports how
/// far it has gotten (tool-call count) and how long since its last output —
/// and flags a worker silent past `worker_stall_ms` as stalled, so an
/// orchestrator can tell busy from stuck instead of polling a "running" that
/// means nothing. Owned; the caller frees it.
fn laneStatus(app: *App, lane: *Thread) []u8 {
    const now_ms = std.Io.Clock.now(.awake, app.io).toMilliseconds();
    switch (lane.turn.state) {
        .idle => {
            if (lane.turn_tool_calls > 0) {
                return std.fmt.allocPrint(app.gpa, "idle — {d} tool calls", .{lane.turn_tool_calls}) catch unreachable;
            }
            return app.gpa.dupe(u8, "idle") catch unreachable;
        },
        .interrupting => return app.gpa.dupe(u8, "cancelling") catch unreachable,
        .active => {},
    }
    // A worker blocked on a tool approval is waiting on the human, not stuck —
    // report it before the stall check so the orchestrator gets an honest
    // signal instead of a fake "STALLED" after `worker_stall_ms`.
    if (lane.worker_context) |*worker| {
        if (worker.approval.pending(worker.io)) {
            return app.gpa.dupe(u8, "running — waiting for approval (a tool needs your OK in that lane's pane)") catch unreachable;
        }
    }
    if (lane.last_activity_ms == 0) {
        return std.fmt.allocPrint(app.gpa, "running — {d} tool calls", .{lane.turn_tool_calls}) catch unreachable;
    }
    const silent_s: i64 = @max(0, @divTrunc(now_ms - lane.last_activity_ms, std.time.ms_per_s));
    if (now_ms - lane.last_activity_ms >= worker_stall_ms) {
        return std.fmt.allocPrint(
            app.gpa,
            "running — STALLED: {d} tool calls, no output for {d}s — `lane cancel` to stop",
            .{ lane.turn_tool_calls, silent_s },
        ) catch unreachable;
    }
    return std.fmt.allocPrint(
        app.gpa,
        "running — {d} tool calls, last output {d}s ago",
        .{ lane.turn_tool_calls, silent_s },
    ) catch unreachable;
}

/// Service the in-flight `lane` bridge request, if any. Called every UI tick
/// (see `handleTick`); a worker lane is blocked on the bridge until this
/// resolves it.
pub fn serviceLaneBridge(app: *App) void {
    const bridge = app.lane_bridge orelse return;
    bridge.service(app.io, app, handleLaneRequest);
}

fn handleLaneRequest(ctx: *anyopaque, req: *const lane_bridge.Request) ?Resp {
    const app: *App = @ptrCast(@alignCast(ctx));
    const requester_lane = app.laneForAgent(@ptrCast(@alignCast(req.requester)));
    return dispatchLaneOp(app, req, requester_lane);
}

fn dispatchLaneOp(app: *App, req: *const lane_bridge.Request, requester_lane: ?*Thread) ?Resp {
    // F2: nested orchestration is impossible by construction. Every op except
    // `list`/`read` is driver-only; a worker that tries is refused crisply so
    // it does not retry.
    if (req.op != .list and req.op != .read) {
        if (!requesterIsPrimary(app, requester_lane)) {
            return failResp(
                app.gpa,
                "lane: {s} is available only to the driver lane; you are a worker — complete your task instead.\n",
                .{@tagName(req.op)},
            );
        }
    }
    return switch (req.op) {
        .list => listLanes(app),
        .create => createLane(app, req),
        .enter => enterLane(app, req),
        .leave => leaveLane(app),
        .merge => mergeLaneOp(app, req),
        .spawn => spawnLane(app, req, requester_lane),
        .read => readLaneOp(app, req),
        .cancel => cancelLaneOp(app, req),
        .await => awaitLaneOp(app, req),
        .steer => steerLaneOp(app, req),
    };
}

/// The requester must be the driver lane: `threads[0]` (the primary). A lane
/// is never demoted by entering it — workspace mode is tool scoping, not a
/// role change, so the driver keeps full capability while entered.
fn requesterIsPrimary(app: *App, requester_lane: ?*Thread) bool {
    const lane = requester_lane orelse return false;
    return app.threads.items.len > 0 and lane == app.threads.items[0];
}

/// Resolve a lane id (the worktree's last path segment — the hex id, durable
/// across the async `nova/<slug>` branch rename) to an open lane.
fn resolveLane(app: *App, id_in: []const u8) ?*Thread {
    const id = std.mem.trim(u8, id_in, " \t\r\n");
    for (app.threads.items) |lane| {
        if (lanes_util.workingLaneOf(lane)) |w| {
            if (std.mem.eql(u8, lanes_util.lastPathSegment(w.path), id)) return lane;
        }
    }
    return null;
}

fn indexOfLane(app: *App, target: *Thread) ?usize {
    for (app.threads.items, 0..) |lane, i| {
        if (lane == target) return i;
    }
    return null;
}

/// The hex id of a working lane (its worktree path's last segment), or null
/// for the primary (which has no worktree).
fn laneIdOf(lane: *Thread) ?[]const u8 {
    const working = lanes_util.workingLaneOf(lane) orelse return null;
    return lanes_util.lastPathSegment(working.path);
}

/// The driver's workspace borrow, if any. Only the driver (threads[0]) enters
/// lanes, so its agent is the only one that can hold a workspace.
fn driverWorkspace(app: *const App) ?[]const u8 {
    if (app.threads.items.len == 0) return null;
    const agent = app.threads.items[0].agent orelse return null;
    return agent.workspaceBorrow();
}

fn listLanes(app: *App) ?Resp {
    const gpa = app.gpa;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // NOTE: the Allocating writer's vtable derives the owning struct via
    // @fieldParentPtr, so `out.writer` must be used IN PLACE — never copied.
    out.writer.writeAll("open lanes:\n") catch return failResp(gpa, "lane: out of memory\n", .{});
    const driver_ws = driverWorkspace(app);
    const active_idx = activeIndex(app);
    for (app.threads.items, 0..) |lane, i| {
        const id = laneIdOf(lane) orelse "0";
        const title = lane.title orelse "";
        const branch = if (lanes_util.workingLaneOf(lane)) |wl| wl.branch else "(primary)";
        const status = laneStatus(app, lane);
        defer app.gpa.free(status);
        const ws_marker: []const u8 = if (driver_ws) |ws| blk: {
            if (lanes_util.workingLaneOf(lane)) |wl| {
                if (std.mem.eql(u8, ws, wl.path)) break :blk "  <- workspace";
            }
            break :blk "";
        } else "";
        const active_marker = if (i == active_idx) "  <- active" else "";
        out.writer.print("  [{d}] {s} {s} ({s}) {s}{s}{s}\n", .{ i, id, title, branch, status, active_marker, ws_marker }) catch return failResp(gpa, "lane: out of memory\n", .{});
    }
    if (driver_ws) |ws| {
        out.writer.print("workspace root: {s}\n", .{ws}) catch return failResp(gpa, "lane: out of memory\n", .{});
    } else if (app.repoRoot()) |root| {
        out.writer.print("workspace root: {s} (repo root)\n", .{root}) catch return failResp(gpa, "lane: out of memory\n", .{});
    }

    if (app.repoRoot()) |repo| {
        const parked = collectParkedLanes(app, repo) catch @as([]vcs.WorktreeEntry, &.{});
        defer vcs.freeWorktreeList(app.gpa, parked);
        if (parked.len > 0) {
            out.writer.writeAll("parked lanes (on disk, not open):\n") catch return failResp(gpa, "lane: out of memory\n", .{});
            for (parked) |p| {
                out.writer.print("  {s} @ {s}\n", .{ p.branch, p.path }) catch return failResp(gpa, "lane: out of memory\n", .{});
            }
            if (parked.len >= 3) {
                out.writer.print("  (note: {d} parked lanes — merge or delete unneeded ones with /lanes)\n", .{parked.len}) catch return failResp(gpa, "lane: out of memory\n", .{});
            }
        }
    }
    return .{ .text = out.toOwnedSlice() catch return failResp(gpa, "lane: out of memory\n", .{}) };
}

/// The git side of opening a lane — shared by `createParallelLane`-style user
/// flow (which additionally attaches a runtime) and the model-driven `create`
/// / `spawn` (which build their own engines). Returns the owned branch + dest.
fn createLaneWorktree(app: *App, repo: []const u8, home: []const u8) !struct { branch: []u8, dest: []u8 } {
    var raw: [6]u8 = undefined;
    app.io.random(&raw);
    const id = std.fmt.bytesToHex(raw, .lower);

    const branch = try std.fmt.allocPrint(app.gpa, "nova/{s}", .{id[0..]});
    errdefer app.gpa.free(branch);
    const parent = try std.fs.path.join(app.gpa, &.{ home, ".config", "nova", "worktrees" });
    defer app.gpa.free(parent);
    std.Io.Dir.cwd().createDirPath(app.io, parent) catch {};
    const dest = try std.fs.path.join(app.gpa, &.{ parent, id[0..] });
    errdefer app.gpa.free(dest);
    try vcs.worktreeAdd(app.gpa, app.io, repo, dest, branch);
    errdefer vcs.worktreeRemove(app.gpa, app.io, repo, dest) catch {};
    return .{ .branch = branch, .dest = dest };
}

/// Free a captured parent-context list (the `captureLaneContext` shape).
fn freeLaneContext(gpa: std.mem.Allocator, context: [][]u8) void {
    for (context) |message| gpa.free(message);
    if (context.len > 0) gpa.free(context);
}

/// `lane create {purpose}`: open a NEW idle lane (worktree + branch, no
/// runtime) for the driver to work in. `self.thread` stays on the driver —
/// unlike the user `/parallel` flow, which switches.
fn createLane(app: *App, req: *const lane_bridge.Request) ?Resp {
    const repo = app.repoRoot() orelse return failResp(app.gpa, "lane: no active runtime\n", .{});
    const home = (app.templateRuntime() orelse return failResp(app.gpa, "lane: no active runtime\n", .{})).home_dir;
    if (!vcs.isRepo(app.gpa, app.io, repo)) return failResp(app.gpa, "lane: not a git repo — lanes need one\n", .{});
    // The cap counts the DRIVER's main lane too: threads.len starts at 1
    // (the primary), so >= 4 means "driver + 3 lanes" — a 4th lane would need
    // a 5th pane in the 2×2 grid.
    if (app.threads.items.len >= 4) return failResp(app.gpa, "lane: too many lanes open (max 4 total: driver + 3)\n", .{});

    const wt = createLaneWorktree(app, repo, home) catch |err| return failResp(app.gpa, "lane: worktree create failed: {s}\n", .{@errorName(err)});
    // Every failure path below returns a `Resp` (never an error), so cleanup
    // is explicit at each site — an `errdefer` would never fire here.
    const lane = app.gpa.create(Thread) catch {
        app.gpa.free(wt.branch);
        app.gpa.free(wt.dest);
        return failResp(app.gpa, "lane: out of memory\n", .{});
    };
    lane.* = .{ .engine = .{ .idle = .{ .working = .{ .branch = wt.branch, .path = wt.dest } } } };
    lane.generation = app.nextLaneGeneration();
    // An idle lane has no runtime to name itself — `purpose` becomes its
    // visible title instead, so the split grid reads as the task, not
    // "untitled".
    if (req.purpose) |purpose| {
        const trimmed = std.mem.trim(u8, purpose, " \t\r\n");
        if (trimmed.len > 0) lane.title = app.gpa.dupe(u8, trimmed) catch null;
    }
    app.threads.append(app.gpa, lane) catch {
        lane.deinit(app.gpa); // frees the adopted branch + path (+ title)
        app.gpa.destroy(lane);
        return failResp(app.gpa, "lane: out of memory\n", .{});
    };
    app.split = true;

    const id = lanes_util.lastPathSegment(wt.dest);
    const path = wt.dest; // now owned by the lane
    const root = app.repoRoot() orelse ".";
    return resp(
        app.gpa,
        "Created lane {s} at {s} (branch {s}). Working root is still {s} (repo root). Work here with `lane enter {s}`; fold back with `lane merge {s}`.\n",
        .{ id, path, wt.branch, root, id, id },
        id,
        path,
    );
}

/// `lane enter {lane}`: validate the target (an idle open lane) and hand its
/// path back so the tool can borrow it as the driver's workspace. The next
/// tool batch's executor re-roots at the lane (S5).
fn enterLane(app: *App, req: *const lane_bridge.Request) ?Resp {
    const id = req.lane orelse return failResp(app.gpa, "lane: enter needs a `lane` id\n", .{});
    const target = resolveLane(app, id) orelse return failResp(app.gpa, "lane: no open lane with id '{s}'\n", .{id});
    // M5: entering a running lane would put two agents writing the same
    // worktree concurrently.
    if (target.turn.isActive()) return failResp(app.gpa, "lane: lane {s} is running — enter an idle lane\n", .{id});
    const working = lanes_util.workingLaneOf(target) orelse return failResp(app.gpa, "lane: lane {s} is the primary — nothing to enter\n", .{id});
    const root = app.repoRoot() orelse ".";
    return resp(
        app.gpa,
        "Entered lane {s}: working root is now {s} (branch {s}); repo root is {s}. git here is on the lane branch — `lane merge` folds it back. `lane leave` returns you to the repo root.\n",
        .{ id, working.path, working.branch, root },
        id,
        working.path,
    );
}

/// `lane leave`: return the driver's tools to the repo root. The tool clears
/// the workspace borrow; this response just confirms + re-announces it.
fn leaveLane(app: *App) ?Resp {
    const root = app.repoRoot() orelse ".";
    return resp(app.gpa, "Left the lane: working root is back to {s} (repo root).\n", .{root}, null, null);
}

/// `lane merge {lane}`: fold a finished lane's branch into the primary tree
/// and remove the lane. Distinct from the user-driven `mergeLane` (which must
/// never bypass `InFlightTurn`): the driver's own turn is active here by
/// definition, so the git fold is safe at the lane level.
fn mergeLaneOp(app: *App, req: *const lane_bridge.Request) ?Resp {
    const id = req.lane orelse return failResp(app.gpa, "lane: merge needs a `lane` id\n", .{});
    const target = resolveLane(app, id) orelse return failResp(app.gpa, "lane: no open lane with id '{s}'\n", .{id});
    // H5b: leave-before-merge. Merging frees the lane's worktree, and the
    // current tool batch's executor is still rooted in it.
    if (driverWorkspace(app)) |ws| {
        if (lanes_util.workingLaneOf(target)) |tw| {
            if (std.mem.eql(u8, ws, tw.path)) {
                return failResp(app.gpa, "lane: call `lane leave` first — merging frees lane {s}'s worktree, and the current tool batch is still rooted in it.\n", .{id});
            }
        }
    }
    if (target.turn.isActive()) return failResp(app.gpa, "lane: lane {s} is still running — cancel or wait before merging\n", .{id});
    const index = indexOfLane(app, target) orelse return failResp(app.gpa, "lane: lane {s} vanished\n", .{id});
    const working = lanes_util.workingLaneOf(target) orelse return failResp(app.gpa, "lane: can't merge the primary lane\n", .{});
    const repo = app.repoRoot() orelse return failResp(app.gpa, "lane: no repo\n", .{});
    // M3: a dirty destination would be misread by vcs.merge as a content
    // conflict. Refuse with a distinct message instead.
    if (vcs.workingTreeDirty(app.gpa, app.io, repo) catch false) {
        return failResp(app.gpa, "lane: the primary tree has uncommitted changes — commit or stash first; this is not a merge conflict.\n", .{});
    }
    // Commit the source if dirty.
    if (vcs.workingTreeDirty(app.gpa, app.io, working.path) catch false) {
        vcs.commitAll(app.gpa, app.io, working.path, "nova: merge lane") catch {};
    }
    switch (vcs.merge(app.gpa, app.io, repo, working.branch) catch |err| return failResp(app.gpa, "lane: merge failed: {s}\n", .{@errorName(err)})) {
        .conflict => return failResp(app.gpa, "lane: merge conflict — rolled back, nothing lost. Lane {s} is still open; resolve and retry.\n", .{id}),
        .ok => {},
    }
    abandonLane(app, index) catch {};
    if (app.threads.items.len < 2) app.split = false;
    // Report the driver's REAL workspace root: it may hold a borrow in another
    // lane (H5b only refuses merging the lane the driver is currently entered
    // in), so claiming the repo root would lie to the model.
    const ws_root = driverWorkspace(app) orelse repo;
    const suffix: []const u8 = if (driverWorkspace(app) != null) "" else " (repo root)";
    return resp(app.gpa, "Merged lane {s} into the primary tree and removed it. Working root is {s}{s}.\n", .{ id, ws_root, suffix }, null, null);
}

/// `lane spawn {task}`: start an independent worker agent in a fresh live
/// lane. The worker runs its own turn on its own thread; the driver's lane
/// stays put. Completion is delivered back to the driver (S11).
fn spawnLane(app: *App, req: *const lane_bridge.Request, requester_lane: ?*Thread) ?Resp {
    const task = req.task orelse return failResp(app.gpa, "lane: spawn needs a `task` (the worker's first prompt)\n", .{});
    const repo = app.repoRoot() orelse return failResp(app.gpa, "lane: no active runtime\n", .{});
    if (!vcs.isRepo(app.gpa, app.io, repo)) return failResp(app.gpa, "lane: not a git repo — lanes need one\n", .{});

    // H2: the naming context comes from the SPAWNER lane, not whatever lane
    // the user is currently viewing. Scope-swap app.thread for the capture.
    // Captured once up front; the req.lane branch passes it to `wakeIdleLane`
    // (which adopts it), the fresh-worktree branch passes it to `Thread.initLive`
    // (which adopts it). Every failure path below returns a `Resp` (never an
    // error), so cleanup is explicit at each site — an `errdefer` would never
    // fire here. `context` is freed by the caller on each pre-adoption failure.
    const spawner = requester_lane orelse return failResp(app.gpa, "lane: no spawner lane\n", .{});
    const prev_thread = app.thread;
    app.thread = spawner;
    const context = app.captureLaneContext(tui.lane_naming_context_max) catch @as([][]u8, &.{});
    app.thread = prev_thread;

    // H1: if req.lane targets an existing idle lane, reuse its worktree+
    // branch and wake it as a worker (TD-3/TD-4). Null or unresolvable
    // req.lane falls through to the fresh-worktree path (current behavior).
    if (req.lane) |target_id| {
        const target = resolveLane(app, target_id) orelse {
            freeLaneContext(app.gpa, context);
            return failResp(app.gpa, "lane: no open lane with id '{s}' — `lane list` shows open lanes\n", .{target_id});
        };
        // TD-6: refuse on the primary (no worktree to reuse).
        if (lanes_util.workingLaneOf(target) == null) {
            freeLaneContext(app.gpa, context);
            return failResp(app.gpa, "lane: can't spawn into the primary lane — spawn creates a worker in an isolated worktree\n", .{});
        }
        // TD-6: refuse on a running/live lane (would race on the worktree).
        if (target.engine != .idle) {
            freeLaneContext(app.gpa, context);
            return failResp(app.gpa, "lane: lane {s} is already running — spawn targets an idle lane\n", .{target_id});
        }
        if (target.turn.isActive()) {
            freeLaneContext(app.gpa, context);
            return failResp(app.gpa, "lane: lane {s} is still running — wait or cancel before re-tasking\n", .{target_id});
        }
        // The cap counts the driver too; reusing an idle lane does NOT
        // add a new Thread, so the cap check is skipped here (the lane
        // is already in the grid).

        wakeIdleLane(app, target, repo, context) catch |err| {
            // `context` is still caller-owned on failure — `wakeIdleLane`
            // only adopts it on success.
            freeLaneContext(app.gpa, context);
            return failResp(app.gpa, "lane: wake idle lane failed: {s}\n", .{@errorName(err)});
        };
        // `target` is now live; `target.agent`/`worker_context` are set.
        target.spawned_by_generation = spawner.generation;
        const id = laneIdOf(target) orelse target_id;
        const working = lanes_util.workingLaneOf(target).?;
        const path = working.path;
        const branch = working.branch;

        const framed = std.fmt.allocPrint(
            app.gpa,
            "You are a worker agent in lane {s} on branch {s}. Your working directory is {s} — an isolated git worktree of the repo at {s}; work ONLY with relative paths inside it. The main tree is off-limits. Complete this task and report the result concisely. You cannot create lanes or worktrees.\n\n{s}",
            .{ id, branch, path, repo, task },
        ) catch {
            // Rollback: re-park the lane to idle (frees the runtime we just
            // attached). `context` is owned by `lane.parent_context` now;
            // `parkFinishedWorker` leaves the lane idle and does not touch
            // parent_context, so it survives.
            parkFinishedWorker(app, target);
            return failResp(app.gpa, "lane: out of memory\n", .{});
        };
        defer app.gpa.free(framed);
        startTurnForLane(app, target, framed, task) catch |err| {
            parkFinishedWorker(app, target);
            return failResp(app.gpa, "lane: worker start failed: {s}\n", .{@errorName(err)});
        };
        return resp(
            app.gpa,
            "Spawned worker into existing lane {s} (branch {s}, path {s}) — running in the background; results arrive as a message. Read with `lane read {s}`, wait with `lane await {s}`, fold back with `lane merge {s}`.\n",
            .{ id, branch, path, id, id, id },
            id,
            path,
        );
    }

    // --- fresh-worktree path (current behavior, unchanged) ---
    // The cap counts the DRIVER's main lane too: threads.len starts at 1
    // (the primary), so >= 4 means "driver + 3 lanes" — a 4th lane would need
    // a 5th pane in the 2×2 grid.
    if (app.threads.items.len >= 4) {
        freeLaneContext(app.gpa, context);
        return failResp(app.gpa, "lane: too many lanes open (max 4 total: driver + 3)\n", .{});
    }

    // `home` is only needed for creating a new worktree; compute it here.
    const home = (app.templateRuntime() orelse {
        freeLaneContext(app.gpa, context);
        return failResp(app.gpa, "lane: no active runtime\n", .{});
    }).home_dir;

    const wt = createLaneWorktree(app, repo, home) catch |err| {
        freeLaneContext(app.gpa, context);
        return failResp(app.gpa, "lane: worktree create failed: {s}\n", .{@errorName(err)});
    };
    const runtime = app.createRuntime(wt.dest, repo, null) catch |err| {
        freeLaneContext(app.gpa, context);
        app.gpa.free(wt.branch);
        app.gpa.free(wt.dest);
        return failResp(app.gpa, "lane: runtime create failed: {s}\n", .{@errorName(err)});
    };
    runtime.agent.background_manager = app.background;
    runtime.agent.mcp_manager = &app.mcp_manager;
    runtime.agent.tool_registry = app.tool_registry;
    runtime.agent.plugin_manager = &app.plugin_manager;
    runtime.agent.lane_bridge = app.lane_bridge;
    // A spawned worker is root-contained: its bash tool refuses `cd` out of the
    // worktree, so a task prompt leaking the main-tree path can't drift the
    // worker's writes into the main tree (L2).
    runtime.agent.contained = true;

    const lane = app.gpa.create(Thread) catch {
        freeLaneContext(app.gpa, context);
        app.gpa.free(wt.branch);
        app.gpa.free(wt.dest);
        runtime.deinit();
        app.gpa.destroy(runtime);
        return failResp(app.gpa, "lane: out of memory\n", .{});
    };
    lane.* = Thread.initLive(
        runtime.session_writer.session.id,
        &runtime.agent,
        app.io,
        runtime.gpa,
        context, // adopted by the lane
        wt.branch, // adopted by the lane
        wt.dest, // adopted by the lane
        runtime,
    );
    lane.generation = app.nextLaneGeneration();
    lane.spawned_by_generation = spawner.generation;
    app.threads.append(app.gpa, lane) catch {
        lane.deinit(app.gpa); // frees the adopted runtime, context, branch, path
        app.gpa.destroy(lane);
        return failResp(app.gpa, "lane: out of memory\n", .{});
    };
    app.split = true;

    const id = lanes_util.lastPathSegment(wt.dest);
    const path = wt.dest; // now owned by the lane
    // F2: worker-role framing makes the role unambiguous from turn one. It
    // also names the worker's ACTUAL working directory (its isolated worktree)
    // so a task that mentions the main tree's absolute path — e.g. the driver's
    // own cwd — doesn't steer the worker into `cd`-ing there. The bash
    // containment guard is the mechanical backstop (L2).
    const framed = std.fmt.allocPrint(
        app.gpa,
        "You are a worker agent in lane {s} on branch {s}. Your working directory is {s} — an isolated git worktree of the repo at {s}; work ONLY with relative paths inside it. The main tree is off-limits. Complete this task and report the result concisely. You cannot create lanes or worktrees.\n\n{s}",
        .{ id, wt.branch, wt.dest, repo, task },
    ) catch {
        removeFailedSpawn(app, lane);
        return failResp(app.gpa, "lane: out of memory\n", .{});
    };
    defer app.gpa.free(framed);
    startTurnForLane(app, lane, framed, task) catch |err| {
        removeFailedSpawn(app, lane);
        return failResp(app.gpa, "lane: worker start failed: {s}\n", .{@errorName(err)});
    };

    return resp(
        app.gpa,
        "Spawned worker lane {s} (branch {s}, path {s}) — running in the background; results arrive as a message. Read with `lane read {s}`, wait with `lane await {s}`, fold back with `lane merge {s}`.\n",
        .{ id, wt.branch, path, id, id, id },
        id,
        path,
    );
}

/// Remove a just-spawned lane whose first turn failed to start. Without this
/// the lane lingers in the grid — and if `turn.submit()` landed before the
/// failure, stuck `.active` with no future (`anyTurnActive` would then keep
/// the tick alive forever and the lane would read as running). `abandonLane`
/// covers the naming cancel, runtime teardown, worktree removal, and branch
/// deletion.
fn removeFailedSpawn(app: *App, lane: *Thread) void {
    const index = indexOfLane(app, lane) orelse return;
    abandonLane(app, index) catch {};
    if (app.threads.items.len < 2) app.split = false;
}

/// Attach a runtime to an existing idle `Thread`, turning it live. Reuses
/// the lane's worktree+branch (already owned via `engine.idle.working`) —
/// no new worktree is created. Mirrors `spawnLane`'s runtime wiring (lines
/// 916-930) but mutates the `Thread` in place instead of creating a new one
/// (TD-3). The caller must `startTurnForLane` after this returns.
fn wakeIdleLane(app: *App, lane: *Thread, repo: []const u8, context: [][]u8) !void {
    // Read the working out of the idle engine BEFORE overwriting it.
    // `vcs.Lane.Working` is two owned slices (branch, path); copying the
    // struct copies the pointers, not the backing memory. The lane owns
    // the backing memory for the lifetime of the Thread, so the move is
    // safe across the union overwrite.
    const working = lane.engine.idle.working;
    const runtime = try app.createRuntime(working.path, repo, null);
    errdefer {
        runtime.deinit();
        app.gpa.destroy(runtime);
    }
    runtime.agent.background_manager = app.background;
    runtime.agent.mcp_manager = &app.mcp_manager;
    runtime.agent.tool_registry = app.tool_registry;
    runtime.agent.plugin_manager = &app.plugin_manager;
    runtime.agent.lane_bridge = app.lane_bridge;
    // A spawned worker is root-contained: its bash tool refuses `cd` out
    // of the worktree (L2), so a task prompt leaking the main-tree path
    // can't drift the worker's writes into the main tree.
    runtime.agent.contained = true;

    // Adopt the spawner's naming context so the first turn can rename the
    // `nova/<hex>` branch, just like the fresh-worktree path. The caller
    // already captured it from the spawner; we take ownership here.
    lane.parent_context = context;

    lane.agent = &runtime.agent;
    lane.worker_context = .{ .io = app.io, .gpa = runtime.gpa };
    lane.engine = .{ .live = .{
        .lane = .{ .working = working },
        .runtime = runtime,
        .owns = true,
    } };
}

/// Start a turn on `lane` with `prompt` (duped into the lane worker's
/// allocator). Mirrors `turn_lifecycle.beginSubmit`/`startTurn` for the spawn
/// path: the task is appended to the lane's transcript, the lane gets a title
/// + branch naming, and the worker starts on its own thread. Title and naming
/// derive from `title_source` (the raw task), not the framed prompt — the
/// role framing would otherwise become the lane's visible label.
fn startTurnForLane(app: *App, lane: *Thread, prompt: []const u8, title_source: []const u8) !void {
    const owned = try lane.worker_context.?.gpa.dupe(u8, prompt);
    errdefer lane.worker_context.?.gpa.free(owned);
    _ = try lane.transcript.append(app.gpa, .user, "you", prompt);
    // Title + naming helpers read `app.thread`; scope-swap for the call.
    const prev = app.thread;
    app.thread = lane;
    defer app.thread = prev;
    app.setLaneTitleIfUnset(title_source) catch {};
    if (lanes_util.workingLaneOf(lane) != null) {
        app.scheduleLaneNaming(lane, title_source) catch {};
    }
    // `app.thread` is scope-swapped to `lane` above, so `resetTurnState`
    // operates on the lane: it picks the spinner word, frees any prior
    // `turn_failed`, anchors the activity clock, and zeroes the tool-call
    // tally + stall latch — exactly the bookkeeping the spawn path used to
    // hand-roll. `awaitModel` follows, as in `beginSubmit`.
    app.resetTurnState();
    app.thread.turn_view.awaitModel();
    lane.turn.submit();
    lane.turn_future = try app.getIo().concurrent(agent_worker.runAgentTurn, .{
        lane.agent.?,
        &lane.worker_context.?,
        owned,
        false,
    });
}

/// `lane read {lane}`: snapshot the tail of a worker lane's conversation.
/// Works on live, rested, and (in-memory) parked-by-rest lanes alike.
fn readLaneOp(app: *App, req: *const lane_bridge.Request) ?Resp {
    const id = req.lane orelse return failResp(app.gpa, "lane: read needs a `lane` id\n", .{});
    const target = resolveLane(app, id) orelse return failResp(app.gpa, "lane: no open lane with id '{s}'\n", .{id});
    const status = laneStatus(app, target);
    defer app.gpa.free(status);
    const tail = transcriptTail(app, target, 8);
    defer app.gpa.free(tail);
    // M2: only an idle (finished) read consumes the result — peeking at a
    // running worker (the poll-until-done pattern) must not suppress its
    // eventual completion delivery.
    if (target.turn.state == .idle) target.acknowledged = true;
    return resp(app.gpa, "Lane {s} ({s}): {s}\n", .{ id, status, tail }, id, null);
}

/// Tail of a lane's transcript (last `max` user/agent bodies, oldest first).
/// Always returns an owned slice — the caller frees it.
fn transcriptTail(app: *App, lane: *Thread, max: usize) []u8 {
    const messages = lane.transcript.messages.items;
    var bodies: std.ArrayList([]const u8) = .empty;
    defer bodies.deinit(app.gpa); // borrows the transcript's bodies
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(app.gpa);
    var i = messages.len;
    while (i > 0 and bodies.items.len < max) {
        i -= 1;
        const m = messages[i];
        // Include tool titles (and lane notices) alongside user/agent text:
        // a worker whose tail would otherwise be just its initial prompt
        // ("You are a worker agent in lane …") shows its actual activity —
        // an orchestrator must see progress, not a silent blank.
        const body: []const u8 = switch (m) {
            .user => |x| x.body,
            .agent => |x| x.body,
            .tool => |x| x.title,
            .notice => |x| x.body,
            else => continue,
        };
        if (body.len == 0) continue;
        bodies.append(app.gpa, body) catch break;
    }
    // Collected newest-first; emit oldest-first so the tail reads
    // chronologically (the `captureLaneContext` shape).
    var index = bodies.items.len;
    while (index > 0) {
        index -= 1;
        out.appendSlice(app.gpa, bodies.items[index]) catch break;
        out.append(app.gpa, '\n') catch break;
    }
    return out.toOwnedSlice(app.gpa) catch return app.gpa.alloc(u8, 0) catch unreachable;
}

/// `lane cancel {lane}`: two-phase interrupt of the target lane's turn (S10).
fn cancelLaneOp(app: *App, req: *const lane_bridge.Request) ?Resp {
    const id = req.lane orelse return failResp(app.gpa, "lane: cancel needs a `lane` id\n", .{});
    const target = resolveLane(app, id) orelse return failResp(app.gpa, "lane: no open lane with id '{s}'\n", .{id});
    cancelLaneTurn(app, target);
    target.acknowledged = true; // the orchestrator knows it was cancelled
    return resp(app.gpa, "Cancelled lane {s}.\n", .{id}, id, null);
}

/// Two-phase interrupt of a target lane's turn, mirroring
/// `turn_lifecycle.handleInterrupt`/`discardAbandonedTurn` parameterized to
/// the lane. `requestCancel` alone only takes effect at the worker's next
/// `emit`; between stream chunks (and for the whole duration of a running
/// tool) the worker is blocked in a read and emits nothing — so the future is
/// force-cancelled and the turn reset UI-side.
fn cancelLaneTurn(app: *App, lane: *Thread) void {
    if (lane.turn.state != .active and lane.turn.state != .interrupting) return;
    if (lane.worker_context) |*worker| worker.requestCancel();
    // Project the cancel notice onto the lane's transcript and mark it
    // interrupting (before the discard, whose reset only clears that state).
    const message = app.gpa.dupe(u8, agent_worker.cancel_message) catch return;
    var event: agent_mod.Agent.Event = .{ .turn_failed = message };
    defer event.deinit(app.gpa);
    _ = lane.turn_view.apply(app.gpa, &lane.transcript, event) catch {};
    // Record the interrupt as a failure so completion delivery reports the
    // worker honestly ("FAILED — Interrupted.") instead of "final state: done".
    // The event's copy is freed by `event.deinit`; this is a second dupe owned
    // by `lane.turn_failed` (reset by the next `resetTurnState`).
    if (lane.turn_failed) |old| app.gpa.free(old);
    lane.turn_failed = app.gpa.dupe(u8, agent_worker.cancel_message) catch null;
    if (lane.turn.state == .active) lane.turn.interrupt();
    discardAbandonedTurnOnLane(app, lane);
}

fn discardAbandonedTurnOnLane(app: *App, lane: *Thread) void {
    if (lane.turn.state != .interrupting and lane.turn_future == null) return;
    if (lane.turn_future) |*future| {
        _ = future.cancel(app.io);
        lane.turn_future = null;
    }
    var batch: std.ArrayList(*agent_mod.Agent.Event) = .empty;
    defer batch.deinit(app.gpa);
    if (lane.worker_context) |*worker| {
        worker.queue.drainInto(worker.io, worker.gpa, &batch) catch {};
        for (batch.items) |event_ptr| {
            event_ptr.deinit(worker.gpa);
            worker.gpa.destroy(event_ptr);
        }
    }
    if (lane.turn.state == .interrupting) lane.turn.reset();
}

/// `lane await {lane}`: resolve once the target lane's turn is idle (or the
/// lane is rested — S11's park is transparent). Returns null while the target
/// is still running; the tick stays alive because the awaiting orchestrator's
/// own turn is active. A worker silent past the stall window resolves ONCE
/// with a stall notice (latched by `stall_warned`) so the orchestrator can
/// cancel/steer instead of blocking here forever.
fn awaitLaneOp(app: *App, req: *const lane_bridge.Request) ?Resp {
    const id = req.lane orelse return failResp(app.gpa, "lane: await needs a `lane` id\n", .{});
    const target = resolveLane(app, id) orelse return failResp(app.gpa, "lane: no open lane with id '{s}'\n", .{id});
    const now_ms = std.Io.Clock.now(.awake, app.io).toMilliseconds();
    if (target.turn.state == .active and laneStalled(target, now_ms) and !target.stall_warned) {
        target.stall_warned = true;
        const silent_s: i64 = @max(0, @divTrunc(now_ms - target.last_activity_ms, std.time.ms_per_s));
        return resp(
            app.gpa,
            "Lane {s} may be stalled — still running, no output for {d}s ({d} tool calls so far). Stop it with `lane cancel`, redirect with `lane steer`, or keep waiting.\n",
            .{ id, silent_s, target.turn_tool_calls },
            id,
            null,
        );
    }
    if (target.turn.state != .idle) return null; // poll again next tick
    target.acknowledged = true; // M2: the result was consumed
    const tail = transcriptTail(app, target, 12);
    defer app.gpa.free(tail);
    if (tail.len == 0) {
        return resp(app.gpa, "Lane {s}: (no turn yet)\n", .{id}, id, null);
    }
    return resp(app.gpa, "Lane {s}: {s}\n", .{ id, tail }, id, null);
}

/// `lane steer {lane} {text}`: inject a short message into a running worker
/// mid-turn (S15). Dual write: the agent queue gets the message marked to
/// steer (drained after the next tool batch), and the lane's UI mirror
/// appends it so the flushed event renders it.
fn steerLaneOp(app: *App, req: *const lane_bridge.Request) ?Resp {
    const id = req.lane orelse return failResp(app.gpa, "lane: steer needs a `lane` id\n", .{});
    const text = req.steer orelse return failResp(app.gpa, "lane: steer needs a `steer` message\n", .{});
    const target = resolveLane(app, id) orelse return failResp(app.gpa, "lane: no open lane with id '{s}'\n", .{id});
    const agent = target.agent orelse return failResp(app.gpa, "lane: lane {s} is not running — nothing to steer\n", .{id});
    if (target.turn.state != .active) return failResp(app.gpa, "lane: lane {s} is not mid-turn\n", .{id});
    agent.enqueueSteer(text) catch |err| switch (err) {
        error.QueueFull => return failResp(app.gpa, "lane: steer queue full\n", .{}),
        else => return failResp(app.gpa, "lane: steer failed: {s}\n", .{@errorName(err)}),
    };
    // UI mirror for the queued-messages-flush render path.
    const owned = app.gpa.dupe(u8, text) catch return failResp(app.gpa, "lane: out of memory\n", .{});
    target.queued.append(app.gpa, .{ .text = owned, .steer = true }) catch app.gpa.free(owned);
    return resp(app.gpa, "Steered lane {s}: {s}\n", .{ id, text }, id, null);
}

// ---------------------------------------------------------------------------
// S11 — completion delivery + auto-park
// ---------------------------------------------------------------------------

/// Rest a finished spawned worker: free its runtime + worker context, keep
/// the Thread + transcript + worktree identity as an idle engine. The lane
/// stays in the grid (distinct from `/close`, which removes it), read/await/
/// merge keep working on the in-memory transcript, and `laneByGeneration` can
/// no longer match the freed agent's lane (M7).
fn parkFinishedWorker(app: *App, lane: *Thread) void {
    const live = switch (lane.engine) {
        .live => |*l| l,
        .idle => return,
    };
    app.cancelLaneNaming(lane);
    live.runtime.deinit();
    app.gpa.destroy(live.runtime);
    if (lane.worker_context) |*worker| {
        worker.approval.deinit(worker.io, worker.gpa);
        worker.queue.deinit(worker.io, worker.gpa);
    }
    lane.worker_context = null;
    lane.agent = null;
    lane.turn_future = null;
    lane.engine = .{ .idle = live.lane };
}

/// Deliver finished spawned-worker completions to the spawner (S11): parked
/// workers are rested, then a terse notice + raw message is enqueued into the
/// spawner's agent and an answer turn starts. An acknowledged worker (M2) or
/// a gone spawner (M7) drops the model turn; a busy spawner waits.
pub fn deliverPendingLaneCompletions(app: *App) !bool {
    var changed = false;
    const active = app.thread;
    defer app.thread = active;

    // 1. Rest finished spawned workers.
    for (app.threads.items) |lane| {
        if (lane.spawned_by_generation == null) continue;
        if (lane.completion_delivered) continue;
        if (lane.engine == .live and lane.turn.state == .idle and lane.transcript.messages.items.len > 0) {
            parkFinishedWorker(app, lane);
            changed = true;
        }
    }

    // 2. Deliver parked completions to idle spawners.
    for (app.threads.items) |lane| {
        if (lane.spawned_by_generation == null) continue;
        if (lane.completion_delivered) continue;
        if (lane.engine != .idle) continue; // still running / not yet parked
        const spawner = app.laneByGeneration(lane.spawned_by_generation.?) orelse {
            lane.completion_delivered = true; // spawner gone — drop it (M7)
            continue;
        };
        const id = laneIdOf(lane) orelse continue;
        const title = lane.title orelse id;
        // Acknowledged (await/read/merge consumed the result): notice only.
        if (lane.acknowledged) {
            const note = try std.fmt.allocPrint(app.gpa, "Lane {s} ({s}) finished — result consumed. Fold back with `lane merge {s}` or delete with /lanes.", .{ title, id, id });
            defer app.gpa.free(note);
            _ = spawner.transcript.append(app.gpa, .notice, "lane", note) catch {};
            if (spawner == active) changed = true;
            lane.completion_delivered = true;
            continue;
        }
        if (spawner.turn.state != .idle) continue; // back-pressure: wait
        var tool_count: u32 = 0;
        for (lane.transcript.messages.items) |m| {
            if (m.kind() == .tool) tool_count += 1;
        }
        // A worker that failed mid-turn gets an honest completion — reporting
        // it as "final state: done" hides the failure from the spawner, which
        // then has no reason to read the lane or clean it up. The reason also
        // sits in the lane's transcript as a notice, so `lane read` shows the
        // full detail.
        const message = if (lane.turn_failed) |reason|
            try std.fmt.allocPrint(app.gpa, "Lane {s} ({s}) FAILED after {d} tool calls: {s}. Read with `lane read {s}`; the worker did not complete — fold what's salvageable with `lane merge {s}` or /close it.", .{ title, id, tool_count, reason, id, id })
        else
            try std.fmt.allocPrint(app.gpa, "Lane {s} ({s}) finished — {d} tool calls, final state: done. Read with `lane read {s}`; fold back with `lane merge {s}`.", .{ title, id, tool_count, id, id });
        defer app.gpa.free(message);
        // Enqueue FIRST, then notice, then mark delivered: if the spawner's
        // queue is full, nothing has been written yet (agent queue and mirror
        // alike) and the next tick retries — the worker's result is never
        // dropped while a notice claims delivery.
        if (!queue_mod.enqueueRawMirrored(app, spawner, message)) continue;
        _ = spawner.transcript.append(app.gpa, .notice, "lane", message) catch {};
        if (spawner == active) changed = true;
        lane.completion_delivered = true;
        app.thread = spawner;
        app.startDeliveryTurnOnCurrentThread() catch {};
        return true;
    }
    return changed;
}

test "serviceLaneBridge resolves a list request against a test App" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    const bridge = app.lane_bridge.?;
    var req = lane_bridge.Request{ .op = .list, .requester = &agent };
    defer req.deinit(gpa);
    bridge.mutex.lock(std.testing.io) catch unreachable;
    bridge.pending = &req;
    bridge.mutex.unlock(std.testing.io);

    serviceLaneBridge(&app);

    try std.testing.expect(bridge.pending == null);
    const result = req.response.?;
    defer app.gpa.free(result.text);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "open lanes:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "(primary)") != null);
}

test "serviceLaneBridge refuses a non-primary spawn with the crisp F2 message" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // A requester that matches no open lane (not threads[0]'s agent): the role
    // guard must refuse without dereferencing it.
    const NotALane = struct { _: u64 };
    var stranger: NotALane = .{ ._ = 0 };
    const bridge = app.lane_bridge.?;
    var req = lane_bridge.Request{ .op = .spawn, .task = try gpa.dupe(u8, "do work"), .requester = &stranger };
    defer req.deinit(gpa);
    bridge.mutex.lock(std.testing.io) catch unreachable;
    bridge.pending = &req;
    bridge.mutex.unlock(std.testing.io);

    serviceLaneBridge(&app);

    try std.testing.expect(bridge.pending == null);
    const result = req.response.?;
    defer app.gpa.free(result.text);
    try std.testing.expect(result.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "only to the driver lane") != null);
}

/// Run a git command in `cwd`, asserting success. Test helper.
fn gitOk(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, args);
    const result = std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
    }) catch return error.GitSpawnFailed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.GitCommandFailed;
}

/// Post a request to the app's bridge and service it inline (the UI tick).
fn postAndService(io: std.Io, app: *App, req: *lane_bridge.Request) lane_bridge.Response {
    const bridge = app.lane_bridge.?;
    bridge.mutex.lock(io) catch unreachable;
    bridge.pending = req;
    bridge.mutex.unlock(io);
    serviceLaneBridge(app);
    std.debug.assert(bridge.pending == null);
    const out = req.response.?;
    return out;
}

test "lane workspace ops create → enter → merge(refused) → leave → merge end-to-end" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!vcs.isAvailable(gpa, io)) return error.SkipZigTest;

    // A throwaway git repo with one commit (HEAD is required for worktree add).
    // Paths are made ABSOLUTE (via the process cwd): `git worktree add`
    // resolves a relative destination against the *repo* dir, not the process
    // cwd, so a relative home would nest the worktree inside the repo. The
    // production home is always absolute, so only the test needs this.
    const test_cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(test_cwd);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(repo);
    try gitOk(gpa, io, repo, &.{ "init", "-q" });
    try gitOk(gpa, io, repo, &.{ "config", "user.name", "t" });
    try gitOk(gpa, io, repo, &.{ "config", "user.email", "t@t" });
    try gitOk(gpa, io, repo, &.{ "commit", "--allow-empty", "-qm", "baseline" });

    // A throwaway HOME so lane worktrees land somewhere disposable.
    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    const home_dir = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &home_tmp.sub_path });
    defer gpa.free(home_dir);

    // A live primary runtime rooted at `repo` (owns=false: the test frees it).
    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.gpa = gpa;
    runtime.io = io;
    runtime.cwd = repo;
    runtime.home_dir = home_dir;
    runtime.client = .none;
    runtime.base_system_prompt = "test";
    runtime.system_prompt = "test";
    runtime.session_writer = undefined;
    runtime.agent = agent_mod.Agent.init(gpa, io, repo, .none);
    defer runtime.agent.deinit();
    runtime.diagnostics = &.{};
    runtime.owned_client = null;
    runtime.owned_compaction_client = null;
    runtime.owned_naming_client = null;
    runtime.naming_client = .none;
    var app = try tui.App.init(io, gpa, &runtime.agent);
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    defer app.deinit();
    defer runtime.disconnectClient();

    // ── lane create: an idle working lane appears; the worktree exists.
    var create_req = lane_bridge.Request{
        .op = .create,
        .purpose = try gpa.dupe(u8, "workspace test"),
        .requester = &runtime.agent,
    };
    defer create_req.deinit(gpa);
    const create_resp = postAndService(io, &app, &create_req);
    defer app.gpa.free(create_resp.text);
    try std.testing.expectEqual(@as(u8, 0), create_resp.code);
    try std.testing.expectEqual(@as(usize, 2), app.threads.items.len);
    const lane = app.threads.items[1];
    const working = lanes_util.workingLaneOf(lane).?;
    const id = lanes_util.lastPathSegment(working.path);
    try std.testing.expect(std.mem.startsWith(u8, working.branch, "nova/"));
    try std.testing.expect(vcs.isRepo(gpa, io, working.path)); // worktree on disk
    // F1: the create response announces the workspace.
    try std.testing.expect(std.mem.indexOf(u8, create_resp.text, "repo root") != null);

    // ── lane enter: the response hands the tool the lane's path to adopt as
    // the workspace borrow (the tool-side write is covered by the lane.zig
    // enter/leave test; `serviceLaneBridge` only resolves the request).
    var enter_req = lane_bridge.Request{ .op = .enter, .lane = try gpa.dupe(u8, id), .requester = &runtime.agent };
    defer enter_req.deinit(gpa);
    const enter_resp = postAndService(io, &app, &enter_req);
    defer app.gpa.free(enter_resp.text);
    try std.testing.expectEqual(@as(u8, 0), enter_resp.code);
    try std.testing.expectEqualStrings(working.path, enter_resp.path.?);
    try std.testing.expect(std.mem.indexOf(u8, enter_resp.text, "working root is now") != null);
    // The tool-side workspace write (tested in lane.zig) is what adopts the
    // returned path — simulate it here so the H5b merge guard sees it.
    runtime.agent.setWorkspace(working.path);

    // ── lane merge while entered: refused with the leave-first message (H5b).
    var merge_entered_req = lane_bridge.Request{ .op = .merge, .lane = try gpa.dupe(u8, id), .requester = &runtime.agent };
    defer merge_entered_req.deinit(gpa);
    const merge_entered_resp = postAndService(io, &app, &merge_entered_req);
    defer app.gpa.free(merge_entered_resp.text);
    try std.testing.expect(merge_entered_resp.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, merge_entered_resp.text, "lane leave") != null);
    try std.testing.expectEqual(@as(usize, 2), app.threads.items.len); // lane intact

    // ── lane leave: the tool clears the borrow; the response confirms.
    var leave_req = lane_bridge.Request{ .op = .leave, .requester = &runtime.agent };
    defer leave_req.deinit(gpa);
    const leave_resp = postAndService(io, &app, &leave_req);
    defer app.gpa.free(leave_resp.text);
    try std.testing.expectEqual(@as(u8, 0), leave_resp.code);
    try std.testing.expect(std.mem.indexOf(u8, leave_resp.text, "repo root") != null);
    // Simulate the tool clearing the borrow (see the lane.zig leave test).
    runtime.agent.setWorkspace(null);

    // ── lane merge: the branch folds back and the lane is removed.
    var merge_req = lane_bridge.Request{ .op = .merge, .lane = try gpa.dupe(u8, id), .requester = &runtime.agent };
    defer merge_req.deinit(gpa);
    const merge_resp = postAndService(io, &app, &merge_req);
    defer app.gpa.free(merge_resp.text);
    try std.testing.expectEqual(@as(u8, 0), merge_resp.code);
    try std.testing.expectEqual(@as(usize, 1), app.threads.items.len);

    // ── F3: the 4-lane cap is enforced against model-driven create too.
    _ = try addFakeWorkingLane(gpa, &app, "cap1");
    _ = try addFakeWorkingLane(gpa, &app, "cap2");
    _ = try addFakeWorkingLane(gpa, &app, "cap3");
    var cap_req = lane_bridge.Request{ .op = .create, .requester = &runtime.agent };
    defer cap_req.deinit(gpa);
    const cap_resp = postAndService(io, &app, &cap_req);
    defer app.gpa.free(cap_resp.text);
    try std.testing.expect(cap_resp.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, cap_resp.text, "too many lanes") != null);
    try std.testing.expectEqual(@as(usize, 4), app.threads.items.len); // refused, not added
}

test "M3: merge reports the driver's real workspace, not the repo root" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!vcs.isAvailable(gpa, io)) return error.SkipZigTest;
    var fx = try GitFixture.init(gpa, io);
    defer fx.deinit(gpa);
    const app = &fx.app;

    // Two working lanes: A (the driver enters it) and B (the merge target).
    var create_a = lane_bridge.Request{ .op = .create, .purpose = try gpa.dupe(u8, "lane A"), .requester = &fx.runtime.agent };
    defer create_a.deinit(gpa);
    const resp_a = postAndService(io, app, &create_a);
    defer app.gpa.free(resp_a.text);
    try std.testing.expectEqual(@as(u8, 0), resp_a.code);
    const lane_a = app.threads.items[1];
    const path_a = try gpa.dupe(u8, lanes_util.workingLaneOf(lane_a).?.path);
    defer gpa.free(path_a);
    const id_a = try gpa.dupe(u8, resp_a.lane_id.?);
    defer gpa.free(id_a);

    var create_b = lane_bridge.Request{ .op = .create, .purpose = try gpa.dupe(u8, "lane B"), .requester = &fx.runtime.agent };
    defer create_b.deinit(gpa);
    const resp_b = postAndService(io, app, &create_b);
    defer app.gpa.free(resp_b.text);
    try std.testing.expectEqual(@as(u8, 0), resp_b.code);
    const id_b = try gpa.dupe(u8, resp_b.lane_id.?);
    defer gpa.free(id_b);

    // The driver enters lane A (simulate the tool-side workspace write).
    var enter_a = lane_bridge.Request{ .op = .enter, .lane = try gpa.dupe(u8, id_a), .requester = &fx.runtime.agent };
    defer enter_a.deinit(gpa);
    const enter_resp = postAndService(io, app, &enter_a);
    defer app.gpa.free(enter_resp.text);
    try std.testing.expectEqual(@as(u8, 0), enter_resp.code);
    fx.runtime.agent.setWorkspace(path_a);

    // Merge lane B while entered in A: H5b only refuses merging the lane the
    // driver is currently entered in, so B merges — and the response must
    // name A's path, not the repo root.
    var merge_b = lane_bridge.Request{ .op = .merge, .lane = try gpa.dupe(u8, id_b), .requester = &fx.runtime.agent };
    defer merge_b.deinit(gpa);
    const merge_resp = postAndService(io, app, &merge_b);
    defer app.gpa.free(merge_resp.text);
    try std.testing.expectEqual(@as(u8, 0), merge_resp.code);
    try std.testing.expectEqual(@as(usize, 2), app.threads.items.len); // B removed
    try std.testing.expect(std.mem.indexOf(u8, merge_resp.text, path_a) != null);
    try std.testing.expect(std.mem.indexOf(u8, merge_resp.text, "repo root") == null);
}

test "I1: a freshly spawned lane resets turn bookkeeping via resetTurnState" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!vcs.isAvailable(gpa, io)) return error.SkipZigTest;
    var fx = try GitFixture.init(gpa, io);
    defer fx.deinit(gpa);
    const app = &fx.app;

    // A spawned worker lane with a real runtime, then start its turn.
    const wt = try createLaneWorktree(app, fx.repo, fx.home_dir);
    const rt = app.createRuntime(wt.dest, fx.repo, null) catch |err| {
        app.gpa.free(wt.branch);
        app.gpa.free(wt.dest);
        return err;
    };
    const lane = try gpa.create(Thread);
    lane.* = Thread.initLive(rt.session_writer.session.id, &rt.agent, io, rt.gpa, &.{}, wt.branch, wt.dest, rt);
    lane.spawned_by_generation = 1; // the primary is the spawner
    // Simulate a prior failure record that a fresh turn must clear.
    lane.turn_failed = try gpa.dupe(u8, "stale failure");
    try app.threads.append(gpa, lane);

    try startTurnForLane(app, lane, "do the work", "do the work");
    defer {
        // The turn future is cancelled by deinitApp; nothing to join here.
    }
    try std.testing.expectEqual(@as(u32, 0), lane.turn_tool_calls);
    try std.testing.expect(lane.turn_failed == null);
    try std.testing.expect(lane.turn_view.loading_word_index < turn_view_mod.loading_spinners.len);
    try std.testing.expect(lane.turn.state == .active);
}

test "S17: teardown of a lane the workspace borrows is refused while the owner's turn is active" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // A second "working" lane whose path the driver (threads[0]) borrows.
    const lane2 = try gpa.create(Thread);
    lane2.* = .{ .engine = .{ .idle = .{ .working = .{
        .branch = try gpa.dupe(u8, "nova/x"),
        .path = try gpa.dupe(u8, "/tmp/lane-x"),
    } } } };
    try app.threads.append(gpa, lane2);
    app.thread = lane2; // the driver's view is on this lane
    agent.setWorkspace("/tmp/lane-x"); // simulate `lane enter`

    // Owner's turn active → teardown refused (H5a), the borrow stays.
    app.threads.items[0].turn.submit();
    try std.testing.expectError(error.InFlightTurn, clearWorkspaceBorrows(&app, lane2));
    try std.testing.expect(agent.workspaceBorrow() != null);

    // Owner idle → the borrow is dropped first, then teardown proceeds.
    app.threads.items[0].turn.reset();
    try clearWorkspaceBorrows(&app, lane2);
    try std.testing.expect(agent.workspaceBorrow() == null);
}

test "S17: collectParkedLanes surfaces a nova/* worktree not open as a lane" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!vcs.isAvailable(gpa, io)) return error.SkipZigTest;

    const test_cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(test_cwd);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(repo);
    try gitOk(gpa, io, repo, &.{ "init", "-q" });
    try gitOk(gpa, io, repo, &.{ "config", "user.name", "t" });
    try gitOk(gpa, io, repo, &.{ "config", "user.email", "t@t" });
    try gitOk(gpa, io, repo, &.{ "commit", "--allow-empty", "-qm", "baseline" });

    // A crash-simulated orphan: a nova/* worktree on disk, not open as a lane.
    const orphan_path = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", "orphan-wt" });
    defer gpa.free(orphan_path);
    std.Io.Dir.cwd().deleteTree(io, orphan_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, orphan_path) catch {};
    try gitOk(gpa, io, repo, &.{ "worktree", "add", "-b", "nova/orphan", orphan_path });

    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    const parked = try collectParkedLanes(&app, repo);
    defer vcs.freeWorktreeList(app.gpa, parked);
    try std.testing.expectEqual(@as(usize, 1), parked.len);
    try std.testing.expect(std.mem.eql(u8, "nova/orphan", parked[0].branch));
}

// ---------------------------------------------------------------------------
// S8–S15 op-level tests (no git fixture needed)
// ---------------------------------------------------------------------------

/// Append a fake idle working lane whose id (last path segment) is `id`.
/// Test helper — `app.deinit` frees it along with the real lanes.
fn addFakeWorkingLane(gpa: std.mem.Allocator, app: *App, id: []const u8) !*Thread {
    const lane = try gpa.create(Thread);
    errdefer gpa.destroy(lane);
    const branch = try std.fmt.allocPrint(gpa, "nova/{s}", .{id});
    errdefer gpa.free(branch);
    const path = try std.fmt.allocPrint(gpa, "/tmp/nova-lanes/{s}", .{id});
    errdefer gpa.free(path);
    lane.* = .{ .engine = .{ .idle = .{ .working = .{ .branch = branch, .path = path } } } };
    try app.threads.append(gpa, lane);
    return lane;
}

fn transcriptContains(lane: *Thread, needle: []const u8) bool {
    for (lane.transcript.messages.items) |m| {
        const body: []const u8 = switch (m) {
            .user => |x| x.body,
            .agent => |x| x.body,
            .notice => |x| x.body,
            else => continue,
        };
        if (std.mem.indexOf(u8, body, needle) != null) return true;
    }
    return false;
}

test "serviceLaneBridge refuses a driver spawn without a task" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    var req = lane_bridge.Request{ .op = .spawn, .requester = &agent };
    defer req.deinit(gpa);
    const result = postAndService(std.testing.io, &app, &req);
    defer app.gpa.free(result.text);
    try std.testing.expect(result.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "needs a `task`") != null);
    try std.testing.expectEqual(@as(usize, 1), app.threads.items.len); // no lane created
}

test "lane create uses purpose as the idle lane's title" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!vcs.isAvailable(gpa, io)) return error.SkipZigTest;

    const test_cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(test_cwd);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(repo);
    try gitOk(gpa, io, repo, &.{ "init", "-q" });
    try gitOk(gpa, io, repo, &.{ "config", "user.name", "t" });
    try gitOk(gpa, io, repo, &.{ "config", "user.email", "t@t" });
    try gitOk(gpa, io, repo, &.{ "commit", "--allow-empty", "-qm", "baseline" });
    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    const home_dir = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &home_tmp.sub_path });
    defer gpa.free(home_dir);

    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.gpa = gpa;
    runtime.io = io;
    runtime.cwd = repo;
    runtime.home_dir = home_dir;
    runtime.client = .none;
    runtime.base_system_prompt = "test";
    runtime.system_prompt = "test";
    runtime.session_writer = undefined;
    runtime.agent = agent_mod.Agent.init(gpa, io, repo, .none);
    defer runtime.agent.deinit();
    runtime.diagnostics = &.{};
    runtime.owned_client = null;
    runtime.owned_compaction_client = null;
    runtime.owned_naming_client = null;
    runtime.naming_client = .none;
    runtime.skills = &.{};
    runtime.plugin_prompts = &.{};
    var app = try tui.App.init(io, gpa, &runtime.agent);
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    defer app.deinit();

    var req = lane_bridge.Request{
        .op = .create,
        .purpose = try gpa.dupe(u8, "evaluate PR #82"),
        .requester = &runtime.agent,
    };
    defer req.deinit(gpa);
    const result = postAndService(io, &app, &req);
    defer app.gpa.free(result.text);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    const lane = app.threads.items[1];
    try std.testing.expectEqualStrings("evaluate PR #82", lane.title.?);
}

test "lane read returns the transcript tail and marks the lane acknowledged" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    const lane = try addFakeWorkingLane(gpa, &app, "readme");
    _ = try lane.transcript.append(gpa, .user, "you", "first user line");
    _ = try lane.transcript.append(gpa, .agent, "agent", "first agent line");
    _ = try lane.transcript.append(gpa, .user, "you", "second user line");

    var req = lane_bridge.Request{ .op = .read, .lane = try gpa.dupe(u8, "readme"), .requester = &agent };
    defer req.deinit(gpa);
    const result = postAndService(io, &app, &req);
    defer app.gpa.free(result.text);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "first user line") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "second user line") != null);
    // The tail is oldest-first.
    const first = std.mem.indexOf(u8, result.text, "first user line").?;
    const second = std.mem.indexOf(u8, result.text, "second user line").?;
    try std.testing.expect(first < second);
    try std.testing.expect(lane.acknowledged); // M2: the result was consumed
}

test "beginSubmit refuses on an idle lane with a guiding notice, not a crash" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    // An idle lane (the `lane create` shape): engine idle, no worker_context.
    _ = try addFakeWorkingLane(gpa, &app, "idle1");
    app.thread = app.threads.items[1]; // focus the idle lane (cycleLane shape)
    try std.testing.expect(app.thread.worker_context == null);

    // Seed the input so we can assert it is preserved (TD-2).
    try app.inputs.input.insertSliceAtCursor("let me work here");
    const started = try app.beginSubmit();
    try std.testing.expect(!started);
    // The notice names both escape hatches.
    try std.testing.expect(transcriptContains(app.thread, "idle"));
    try std.testing.expect(transcriptContains(app.thread, "lane enter"));
    try std.testing.expect(transcriptContains(app.thread, "lane spawn"));
    // Input preserved — not consumed by toOwnedSlice.
    try std.testing.expectEqualStrings("let me work here", app.inputs.input.buf.firstHalf());
}

test "lane spawn reuses an existing idle lane and wakes it as a worker" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!vcs.isAvailable(gpa, io)) return error.SkipZigTest;
    var fx = try GitFixture.init(gpa, io);
    defer fx.deinit(gpa);
    const app = &fx.app;

    // Seed a user message on the driver so `captureLaneContext` has a
    // non-empty parent context to copy into the woken lane.
    _ = try app.thread.transcript.append(gpa, .user, "you", "driver context");

    // Create an idle lane via the tool (real worktree + branch).
    var create_req = lane_bridge.Request{
        .op = .create,
        .purpose = try gpa.dupe(u8, "scratch work"),
        .requester = &fx.runtime.agent,
    };
    defer create_req.deinit(gpa);
    const create_resp = postAndService(io, app, &create_req);
    defer app.gpa.free(create_resp.text);
    try std.testing.expectEqual(@as(u8, 0), create_resp.code);
    try std.testing.expectEqual(@as(usize, 2), app.threads.items.len);
    const idle_lane = app.threads.items[1];
    try std.testing.expect(idle_lane.engine == .idle);
    try std.testing.expect(idle_lane.worker_context == null);
    const idle_id = laneIdOf(idle_lane).?;
    const idle_gen = idle_lane.generation;

    // Spawn a worker INTO that idle lane.
    var spawn_req = lane_bridge.Request{
        .op = .spawn,
        .task = try gpa.dupe(u8, "run the tests and report"),
        .lane = try gpa.dupe(u8, idle_id),
        .requester = &fx.runtime.agent,
    };
    defer spawn_req.deinit(gpa);
    const spawn_resp = postAndService(io, app, &spawn_req);
    defer app.gpa.free(spawn_resp.text);
    try std.testing.expectEqual(@as(u8, 0), spawn_resp.code);
    // No new lane was created — the idle one was woken in place.
    try std.testing.expectEqual(@as(usize, 2), app.threads.items.len);
    const woken = app.threads.items[1];
    try std.testing.expect(woken == idle_lane); // same Thread pointer
    try std.testing.expect(woken.engine == .live);
    try std.testing.expect(woken.worker_context != null);
    try std.testing.expect(woken.agent != null);
    try std.testing.expectEqual(idle_gen, woken.generation); // generation stable
    try std.testing.expect(woken.spawned_by_generation == app.threads.items[0].generation);
    // The worktree path is the same one `lane create` made.
    try std.testing.expectEqualStrings(idle_id, laneIdOf(woken).?);
    // Parent context was copied in, not left empty.
    try std.testing.expect(woken.parent_context.len > 0);
    var has_driver_ctx = false;
    for (woken.parent_context) |m| {
        if (std.mem.indexOf(u8, m, "driver context") != null) has_driver_ctx = true;
    }
    try std.testing.expect(has_driver_ctx);
}

test "lane spawn with req.lane refuses on a running lane" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!vcs.isAvailable(gpa, io)) return error.SkipZigTest;
    var fx = try GitFixture.init(gpa, io);
    defer fx.deinit(gpa);
    const app = &fx.app;

    // A fake live lane with an active turn. Keep the fake idle's branch/path
    // (last segment "busy") so `resolveLane` matches the id.
    const lane = try addFakeWorkingLane(gpa, app, "busy");
    const branch = lane.engine.idle.working.branch;
    const path = lane.engine.idle.working.path;
    lane.engine = .{ .live = .{ .lane = .{ .working = .{ .branch = branch, .path = path } }, .runtime = undefined, .owns = false } };
    lane.worker_context = .{ .io = io, .gpa = gpa };
    lane.turn.submit(); // mark active

    var req = lane_bridge.Request{
        .op = .spawn,
        .task = try gpa.dupe(u8, "do something"),
        .lane = try gpa.dupe(u8, "busy"),
        .requester = &fx.runtime.agent,
    };
    defer req.deinit(gpa);
    const result = postAndService(io, app, &req);
    defer app.gpa.free(result.text);
    try std.testing.expect(result.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "already running") != null);
}

test "lane spawn with req.lane refuses on the primary lane" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!vcs.isAvailable(gpa, io)) return error.SkipZigTest;
    var fx = try GitFixture.init(gpa, io);
    defer fx.deinit(gpa);
    const app = &fx.app;
    // An unresolvable id exercises the "no open lane" refuse path.
    var req = lane_bridge.Request{
        .op = .spawn,
        .task = try gpa.dupe(u8, "x"),
        .lane = try gpa.dupe(u8, "nonexistent"),
        .requester = &fx.runtime.agent,
    };
    defer req.deinit(gpa);
    const result = postAndService(io, app, &req);
    defer app.gpa.free(result.text);
    try std.testing.expect(result.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "no open lane") != null);
}

test "lane spawn into a rested worker preserves the transcript and appends" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!vcs.isAvailable(gpa, io)) return error.SkipZigTest;
    var fx = try GitFixture.init(gpa, io);
    defer fx.deinit(gpa);
    const app = &fx.app;

    // Spawn a worker, let it finish, rest it (the S11 shape).
    const wt = try createLaneWorktree(app, fx.repo, fx.home_dir);
    const rt = app.createRuntime(wt.dest, fx.repo, null) catch |err| {
        app.gpa.free(wt.branch);
        app.gpa.free(wt.dest);
        return err;
    };
    const lane = try gpa.create(Thread);
    lane.* = Thread.initLive(rt.session_writer.session.id, &rt.agent, io, rt.gpa, &.{}, wt.branch, wt.dest, rt);
    lane.spawned_by_generation = 1;
    try app.threads.append(gpa, lane);
    _ = try lane.transcript.append(gpa, .user, "you", "first task");
    _ = try lane.transcript.append(gpa, .agent, "agent", "first result");
    _ = try deliverPendingLaneCompletions(app); // rests the lane

    try std.testing.expect(lane.engine == .idle);
    const id = laneIdOf(lane).?;
    const old_msg_count = lane.transcript.messages.items.len;

    // Re-task the rested lane.
    var spawn_req = lane_bridge.Request{
        .op = .spawn,
        .task = try gpa.dupe(u8, "second task"),
        .lane = try gpa.dupe(u8, id),
        .requester = &fx.runtime.agent,
    };
    defer spawn_req.deinit(gpa);
    const spawn_resp = postAndService(io, app, &spawn_req);
    defer app.gpa.free(spawn_resp.text);
    try std.testing.expectEqual(@as(u8, 0), spawn_resp.code);
    try std.testing.expect(lane.engine == .live);
    // Transcript preserved (TD-5): old messages still there + new ones appended.
    try std.testing.expect(lane.transcript.messages.items.len > old_msg_count);
    try std.testing.expect(transcriptContains(lane, "first result"));
    try std.testing.expect(transcriptContains(lane, "second task"));
}

test "lane await resolves an idle lane immediately and polls a running one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    // A lane that never ran resolves with "(no turn yet)" — the orchestrator
    // is never wedged (S12).
    const fresh = try addFakeWorkingLane(gpa, &app, "fresh");
    _ = fresh;
    var fresh_req = lane_bridge.Request{ .op = .await, .lane = try gpa.dupe(u8, "fresh"), .requester = &agent };
    defer fresh_req.deinit(gpa);
    const fresh_resp = postAndService(io, &app, &fresh_req);
    defer app.gpa.free(fresh_resp.text);
    try std.testing.expectEqual(@as(u8, 0), fresh_resp.code);
    try std.testing.expect(std.mem.indexOf(u8, fresh_resp.text, "no turn yet") != null);

    // A finished (idle) lane resolves immediately with its transcript tail.
    const done = try addFakeWorkingLane(gpa, &app, "done");
    _ = try done.transcript.append(gpa, .agent, "agent", "done work");
    var done_req = lane_bridge.Request{ .op = .await, .lane = try gpa.dupe(u8, "done"), .requester = &agent };
    defer done_req.deinit(gpa);
    const done_resp = postAndService(io, &app, &done_req);
    defer app.gpa.free(done_resp.text);
    try std.testing.expectEqual(@as(u8, 0), done_resp.code);
    try std.testing.expect(std.mem.indexOf(u8, done_resp.text, "done work") != null);
    try std.testing.expect(done.acknowledged); // M2: the result was consumed

    // A running lane keeps the request in flight (poll again next tick).
    const running = try addFakeWorkingLane(gpa, &app, "running");
    running.turn.submit();
    var run_req = lane_bridge.Request{ .op = .await, .lane = try gpa.dupe(u8, "running"), .requester = &agent };
    defer run_req.deinit(gpa);
    const bridge = app.lane_bridge.?;
    bridge.mutex.lock(io) catch unreachable;
    bridge.pending = &run_req;
    bridge.mutex.unlock(io);
    serviceLaneBridge(&app);
    try std.testing.expect(bridge.pending == &run_req); // still in flight
    bridge.pending = null; // test teardown: drop the poll
}

test "lane await resolves a stalled worker once, then latches the stall warning" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    // A worker that has emitted nothing past the stall window: the wait must
    // resolve once with a stall notice so the orchestrator can cancel/steer
    // instead of blocking forever.
    const stalled = try addFakeWorkingLane(gpa, &app, "stalled");
    stalled.turn.submit();
    stalled.turn_tool_calls = 4;
    stalled.last_activity_ms = std.Io.Clock.now(.awake, io).toMilliseconds() - worker_stall_ms - 1000;

    var req = lane_bridge.Request{ .op = .await, .lane = try gpa.dupe(u8, "stalled"), .requester = &agent };
    defer req.deinit(gpa);
    const result = postAndService(io, &app, &req);
    defer app.gpa.free(result.text);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "may be stalled") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "4 tool calls") != null);
    try std.testing.expect(stalled.stall_warned);

    // Re-awaiting while the same silent stretch continues must NOT resolve
    // again every tick — it commits to waiting (the latch held until the
    // worker emits again).
    var req2 = lane_bridge.Request{ .op = .await, .lane = try gpa.dupe(u8, "stalled"), .requester = &agent };
    defer req2.deinit(gpa);
    const bridge = app.lane_bridge.?;
    bridge.mutex.lock(io) catch unreachable;
    bridge.pending = &req2;
    bridge.mutex.unlock(io);
    serviceLaneBridge(&app);
    try std.testing.expect(bridge.pending == &req2); // back to blocking
    bridge.pending = null;
}

test "lane read reports activity and does not acknowledge a running worker" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    // A running worker with progress: read surfaces the activity so the
    // orchestrator can see it is busy, and must NOT consume its eventual
    // result (M2 is gated on idle).
    const busy = try addFakeWorkingLane(gpa, &app, "busy");
    busy.turn.submit();
    busy.turn_tool_calls = 3;
    busy.last_activity_ms = std.Io.Clock.now(.awake, io).toMilliseconds() - 2000;
    var busy_req = lane_bridge.Request{ .op = .read, .lane = try gpa.dupe(u8, "busy"), .requester = &agent };
    defer busy_req.deinit(gpa);
    const busy_resp = postAndService(io, &app, &busy_req);
    defer app.gpa.free(busy_resp.text);
    try std.testing.expectEqual(@as(u8, 0), busy_resp.code);
    try std.testing.expect(std.mem.indexOf(u8, busy_resp.text, "running — 3 tool calls") != null);
    try std.testing.expect(!busy.acknowledged); // running: result not yet consumed

    // A stalled worker is flagged with an actionable hint.
    const stuck = try addFakeWorkingLane(gpa, &app, "stuck");
    stuck.turn.submit();
    stuck.turn_tool_calls = 1;
    stuck.last_activity_ms = std.Io.Clock.now(.awake, io).toMilliseconds() - worker_stall_ms - 1000;
    var stuck_req = lane_bridge.Request{ .op = .read, .lane = try gpa.dupe(u8, "stuck"), .requester = &agent };
    defer stuck_req.deinit(gpa);
    const stuck_resp = postAndService(io, &app, &stuck_req);
    defer app.gpa.free(stuck_resp.text);
    try std.testing.expect(std.mem.indexOf(u8, stuck_resp.text, "STALLED") != null);
    try std.testing.expect(std.mem.indexOf(u8, stuck_resp.text, "lane cancel") != null);

    // An idle finished worker reads back its tool-call tally.
    const done = try addFakeWorkingLane(gpa, &app, "done2");
    done.turn_tool_calls = 9;
    _ = try done.transcript.append(gpa, .agent, "agent", "final verdict");
    var done_req = lane_bridge.Request{ .op = .read, .lane = try gpa.dupe(u8, "done2"), .requester = &agent };
    defer done_req.deinit(gpa);
    const done_resp = postAndService(io, &app, &done_req);
    defer app.gpa.free(done_resp.text);
    try std.testing.expect(std.mem.indexOf(u8, done_resp.text, "idle — 9 tool calls") != null);
    try std.testing.expect(done.acknowledged); // idle read consumed the result
}

test "lane list surfaces worker activity in the status column" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    const busy = try addFakeWorkingLane(gpa, &app, "busy2");
    busy.turn.submit();
    busy.turn_tool_calls = 5;
    busy.last_activity_ms = std.Io.Clock.now(.awake, io).toMilliseconds() - 5000;

    var req = lane_bridge.Request{ .op = .list, .requester = &agent };
    defer req.deinit(gpa);
    const result = postAndService(io, &app, &req);
    defer app.gpa.free(result.text);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "busy2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "running — 5 tool calls") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "last output") != null);
}

test "lane steer is refused on a rested lane and reaches a running worker" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    // Rested (engine idle, no agent) → crisp refusal.
    const rested = try addFakeWorkingLane(gpa, &app, "rested");
    _ = rested;
    var rested_req = lane_bridge.Request{
        .op = .steer,
        .lane = try gpa.dupe(u8, "rested"),
        .steer = try gpa.dupe(u8, "keep it small"),
        .requester = &agent,
    };
    defer rested_req.deinit(gpa);
    const rested_resp = postAndService(io, &app, &rested_req);
    defer app.gpa.free(rested_resp.text);
    try std.testing.expect(rested_resp.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, rested_resp.text, "nothing to steer") != null);

    // Running → the steer lands in the agent's queue (marked steer) and the
    // lane's UI mirror.
    var worker_agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer worker_agent.deinit();
    const running = try addFakeWorkingLane(gpa, &app, "steerme");
    running.agent = &worker_agent;
    running.turn.submit(); // mid-turn
    var run_req = lane_bridge.Request{
        .op = .steer,
        .lane = try gpa.dupe(u8, "steerme"),
        .steer = try gpa.dupe(u8, "keep it small"),
        .requester = &agent,
    };
    defer run_req.deinit(gpa);
    const run_resp = postAndService(io, &app, &run_req);
    defer app.gpa.free(run_resp.text);
    try std.testing.expectEqual(@as(u8, 0), run_resp.code);
    try std.testing.expect(worker_agent.hasQueuedMessages());
    try std.testing.expectEqual(@as(usize, 1), running.queued.items.len);
    try std.testing.expect(running.queued.items[0].steer);
}

test "lane cancel reaches idle with a visible cancel notice" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    const lane = try addFakeWorkingLane(gpa, &app, "cancelme");
    lane.worker_context = .{ .io = io, .gpa = gpa };
    lane.turn.submit(); // mid-turn

    var req = lane_bridge.Request{ .op = .cancel, .lane = try gpa.dupe(u8, "cancelme"), .requester = &agent };
    defer req.deinit(gpa);
    const result = postAndService(io, &app, &req);
    defer app.gpa.free(result.text);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(lane.turn.state == .idle); // the two-phase reset landed
    try std.testing.expect(transcriptContains(lane, agent_worker.cancel_message));
    try std.testing.expect(lane.acknowledged);
}

test "S11: a gone spawner drops the completion without crashing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    // A spawner generation that matches no open lane (its lane was closed).
    const lane = try addFakeWorkingLane(gpa, &app, "orphaned");
    lane.spawned_by_generation = 999; // no live lane has this generation
    _ = try lane.transcript.append(gpa, .agent, "agent", "late result");

    const changed = try deliverPendingLaneCompletions(&app);
    try std.testing.expect(!changed);
    try std.testing.expect(lane.completion_delivered); // dropped, not delivered
    try std.testing.expect(!transcriptContains(app.threads.items[0], "late result"));
}

test "M1: completion routes to the spawner by generation, not by agent pointer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    // A fake spawner lane with a distinct generation (not the primary's 1).
    const spawner = try addFakeWorkingLane(gpa, &app, "spawner");
    spawner.generation = 7;

    // A finished worker whose completion routes to generation 7. Acknowledged
    // so delivery takes the notice-only path (no answer turn / worker context
    // needed) — the routing lookup still runs first.
    const worker = try addFakeWorkingLane(gpa, &app, "worker");
    worker.spawned_by_generation = 7;
    worker.acknowledged = true;

    _ = try deliverPendingLaneCompletions(&app);
    try std.testing.expect(worker.completion_delivered);
    // The notice landed on the spawner lane (generation 7), not the primary.
    try std.testing.expect(transcriptContains(spawner, "result consumed"));
    try std.testing.expect(!transcriptContains(app.threads.items[0], "result consumed"));
}

test "S11: an acknowledged worker delivers a notice only — no answer turn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    // Rested shape: engine idle, completion pending, result already consumed
    // via await/read (M2).
    const lane = try addFakeWorkingLane(gpa, &app, "acked");
    lane.spawned_by_generation = 1; // the primary is the spawner
    lane.acknowledged = true;
    const before = app.threads.items[0].transcript.messages.items.len;

    const changed = try deliverPendingLaneCompletions(&app);
    try std.testing.expect(changed);
    try std.testing.expect(lane.completion_delivered);
    try std.testing.expectEqual(before + 1, app.threads.items[0].transcript.messages.items.len);
    try std.testing.expect(transcriptContains(app.threads.items[0], "result consumed"));
    try std.testing.expect(app.threads.items[0].turn.state == .idle); // no answer turn
}

/// Write a file at an absolute path (test helper for the git fixtures).
fn writeAbs(io: std.Io, path: []const u8, content: []const u8) !void {
    var f = try std.Io.Dir.createFile(.cwd(), io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, content);
}

/// Shared git fixture: a throwaway repo with one commit + a throwaway HOME
/// for lane worktrees + a live primary runtime rooted at the repo. The
/// runtime's skills/plugin_prompts are valid empty slices because
/// `createRuntime` clones them from the template runtime.
const GitFixture = struct {
    tmp: std.testing.TmpDir,
    home_tmp: std.testing.TmpDir,
    repo: []u8,
    home_dir: []u8,
    /// Heap-allocated: the lane engine borrows its address, so it must
    /// outlive `init`'s frame (the pointer-capture footgun).
    runtime: *runtime_mod.AgentRuntime,
    app: tui.App,

    fn init(gpa: std.mem.Allocator, io: std.Io) !GitFixture {
        const test_cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(test_cwd);
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const repo = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &tmp.sub_path });
        errdefer gpa.free(repo);
        try gitOk(gpa, io, repo, &.{ "init", "-q" });
        try gitOk(gpa, io, repo, &.{ "config", "user.name", "t" });
        try gitOk(gpa, io, repo, &.{ "config", "user.email", "t@t" });
        try gitOk(gpa, io, repo, &.{ "commit", "--allow-empty", "-qm", "baseline" });

        var home_tmp = std.testing.tmpDir(.{});
        errdefer home_tmp.cleanup();
        const home_dir = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &home_tmp.sub_path });
        errdefer gpa.free(home_dir);

        const runtime = try gpa.create(runtime_mod.AgentRuntime);
        errdefer gpa.destroy(runtime);
        runtime.gpa = gpa;
        runtime.io = io;
        runtime.cwd = repo;
        runtime.home_dir = home_dir;
        runtime.client = .none;
        runtime.base_system_prompt = "test";
        runtime.system_prompt = "test";
        runtime.session_writer = undefined;
        runtime.agent = agent_mod.Agent.init(gpa, io, repo, .none);
        runtime.diagnostics = &.{};
        runtime.owned_client = null;
        runtime.owned_compaction_client = null;
        runtime.owned_naming_client = null;
        runtime.naming_client = .none;
        runtime.skills = &.{};
        runtime.plugin_prompts = &.{};

        var app = try tui.App.init(io, gpa, &runtime.agent);
        app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = runtime, .owns = false } };
        return .{ .tmp = tmp, .home_tmp = home_tmp, .repo = repo, .home_dir = home_dir, .runtime = runtime, .app = app };
    }

    fn deinit(self: *GitFixture, gpa: std.mem.Allocator) void {
        self.app.deinit();
        self.runtime.agent.deinit();
        gpa.destroy(self.runtime);
        gpa.free(self.repo);
        gpa.free(self.home_dir);
        self.tmp.cleanup();
        self.home_tmp.cleanup();
    }
};

test "S11: a finished spawned worker rests — runtime freed, transcript + worktree intact" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!vcs.isAvailable(gpa, io)) return error.SkipZigTest;
    var fx = try GitFixture.init(gpa, io);
    defer fx.deinit(gpa);
    const app = &fx.app;

    // A spawned worker lane with a real runtime (the production path:
    // `createRuntime` rooted at the lane worktree) and a finished turn.
    const wt = try createLaneWorktree(app, fx.repo, fx.home_dir);
    const rt = app.createRuntime(wt.dest, fx.repo, null) catch |err| {
        app.gpa.free(wt.branch);
        app.gpa.free(wt.dest);
        return err;
    };
    const lane = try gpa.create(Thread);
    lane.* = Thread.initLive(rt.session_writer.session.id, &rt.agent, io, rt.gpa, &.{}, wt.branch, wt.dest, rt);
    lane.spawned_by_generation = 1; // the primary is the spawner
    try app.threads.append(gpa, lane);
    _ = try lane.transcript.append(gpa, .user, "you", "worker task");
    _ = try lane.transcript.append(gpa, .agent, "agent", "worker result");
    const lane_path = try gpa.dupe(u8, wt.dest);
    defer gpa.free(lane_path);

    const changed = try deliverPendingLaneCompletions(app);
    try std.testing.expect(changed);
    // The worker rested (M7-complete): engine idle, runtime gone, no handles
    // into it left behind.
    try std.testing.expect(lane.engine == .idle);
    try std.testing.expect(lane.agent == null);
    try std.testing.expect(lane.worker_context == null);
    try std.testing.expect(lane.turn_future == null);
    // ...but the transcript and the worktree survived — read/await/merge
    // keep working (F3).
    try std.testing.expectEqual(@as(usize, 2), lane.transcript.messages.items.len);
    try std.testing.expect(vcs.isRepo(gpa, io, lane_path));
    try std.testing.expect(lane.completion_delivered);
    // The spawner got the completion notice.
    try std.testing.expect(transcriptContains(app.threads.items[0], "finished"));
}

test "S11: a failed spawned worker is reported honestly, not as done" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!vcs.isAvailable(gpa, io)) return error.SkipZigTest;
    var fx = try GitFixture.init(gpa, io);
    defer fx.deinit(gpa);
    const app = &fx.app;

    // A spawned worker lane (real runtime, finished turn) whose turn FAILED —
    // e.g. the model request errored out. The failure reason is recorded on
    // the lane by `applyAgentEvent` before delivery.
    const wt = try createLaneWorktree(app, fx.repo, fx.home_dir);
    const rt = app.createRuntime(wt.dest, fx.repo, null) catch |err| {
        app.gpa.free(wt.branch);
        app.gpa.free(wt.dest);
        return err;
    };
    const lane = try gpa.create(Thread);
    lane.* = Thread.initLive(rt.session_writer.session.id, &rt.agent, io, rt.gpa, &.{}, wt.branch, wt.dest, rt);
    lane.spawned_by_generation = 1; // the primary is the spawner
    lane.turn_failed = try gpa.dupe(u8, "agent turn failed: ConnectionLost");
    try app.threads.append(gpa, lane);
    _ = try lane.transcript.append(gpa, .user, "you", "worker task");

    const changed = try deliverPendingLaneCompletions(app);
    try std.testing.expect(changed);
    try std.testing.expect(lane.completion_delivered);
    // The spawner is told the truth: FAILED + the reason, never "done".
    const spawner = app.threads.items[0];
    try std.testing.expect(transcriptContains(spawner, "FAILED"));
    try std.testing.expect(transcriptContains(spawner, "ConnectionLost"));
    try std.testing.expect(!transcriptContains(spawner, "final state: done"));
}

test "S11: a cancelled spawned worker is delivered as FAILED, not done" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!vcs.isAvailable(gpa, io)) return error.SkipZigTest;
    var fx = try GitFixture.init(gpa, io);
    defer fx.deinit(gpa);
    const app = &fx.app;

    // A spawned worker lane with a real runtime and an ACTIVE turn, cancelled
    // via the model-driven `lane cancel` path. `cancelLaneTurn` must record
    // the interrupt as a failure so delivery reports it honestly.
    const wt = try createLaneWorktree(app, fx.repo, fx.home_dir);
    const rt = app.createRuntime(wt.dest, fx.repo, null) catch |err| {
        app.gpa.free(wt.branch);
        app.gpa.free(wt.dest);
        return err;
    };
    const lane = try gpa.create(Thread);
    lane.* = Thread.initLive(rt.session_writer.session.id, &rt.agent, io, rt.gpa, &.{}, wt.branch, wt.dest, rt);
    lane.spawned_by_generation = 1; // the primary is the spawner
    lane.turn.state = .active;
    try app.threads.append(gpa, lane);
    _ = try lane.transcript.append(gpa, .user, "you", "worker task");

    cancelLaneTurn(app, lane);
    try std.testing.expect(lane.turn_failed != null);
    try std.testing.expect(std.mem.indexOf(u8, lane.turn_failed.?, "Interrupted.") != null);

    const changed = try deliverPendingLaneCompletions(app);
    try std.testing.expect(changed);
    try std.testing.expect(lane.completion_delivered);
    const spawner = app.threads.items[0];
    try std.testing.expect(transcriptContains(spawner, "FAILED"));
    try std.testing.expect(transcriptContains(spawner, "Interrupted."));
    try std.testing.expect(!transcriptContains(spawner, "final state: done"));
}

test "lane merge: dirty primary refused (M3), conflict rolls back, dirty source auto-commits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!vcs.isAvailable(gpa, io)) return error.SkipZigTest;
    var fx = try GitFixture.init(gpa, io);
    defer fx.deinit(gpa);
    const app = &fx.app;

    var create_req = lane_bridge.Request{ .op = .create, .requester = &fx.runtime.agent };
    defer create_req.deinit(gpa);
    const create_resp = postAndService(io, app, &create_req);
    defer app.gpa.free(create_resp.text);
    try std.testing.expectEqual(@as(u8, 0), create_resp.code);
    const lane = app.threads.items[1];
    const lane_path = try gpa.dupe(u8, lanes_util.workingLaneOf(lane).?.path);
    defer gpa.free(lane_path);
    const id = try gpa.dupe(u8, create_resp.lane_id.?);
    defer gpa.free(id);

    // ── M3: a dirty primary tree is refused with its own message (not a
    // misread "conflict").
    const dirty_path = try std.fs.path.join(gpa, &.{ fx.repo, "dirty.txt" });
    defer gpa.free(dirty_path);
    try writeAbs(io, dirty_path, "uncommitted\n");
    var dirty_req = lane_bridge.Request{ .op = .merge, .lane = try gpa.dupe(u8, id), .requester = &fx.runtime.agent };
    defer dirty_req.deinit(gpa);
    const dirty_resp = postAndService(io, app, &dirty_req);
    defer app.gpa.free(dirty_resp.text);
    try std.testing.expect(dirty_resp.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, dirty_resp.text, "uncommitted changes") != null);
    try std.testing.expectEqual(@as(usize, 2), app.threads.items.len); // lane intact
    std.Io.Dir.cwd().deleteFile(io, dirty_path) catch {};

    // ── Conflict: both sides change the same file → rolled back, lane kept.
    const lane_conflict = try std.fs.path.join(gpa, &.{ lane_path, "conflict.txt" });
    defer gpa.free(lane_conflict);
    try writeAbs(io, lane_conflict, "lane side\n");
    try gitOk(gpa, io, lane_path, &.{ "add", "-A" });
    try gitOk(gpa, io, lane_path, &.{ "commit", "-qm", "lane change" });
    const primary_conflict = try std.fs.path.join(gpa, &.{ fx.repo, "conflict.txt" });
    defer gpa.free(primary_conflict);
    try writeAbs(io, primary_conflict, "primary side\n");
    try gitOk(gpa, io, fx.repo, &.{ "add", "-A" });
    try gitOk(gpa, io, fx.repo, &.{ "commit", "-qm", "primary change" });

    var conflict_req = lane_bridge.Request{ .op = .merge, .lane = try gpa.dupe(u8, id), .requester = &fx.runtime.agent };
    defer conflict_req.deinit(gpa);
    const conflict_resp = postAndService(io, app, &conflict_req);
    defer app.gpa.free(conflict_resp.text);
    try std.testing.expect(conflict_resp.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, conflict_resp.text, "rolled back") != null);
    try std.testing.expectEqual(@as(usize, 2), app.threads.items.len); // lane intact
    // The primary tree is untouched — its own version still on disk.
    var buf: [64]u8 = undefined;
    const primary_content = std.Io.Dir.cwd().readFile(io, primary_conflict, &buf) catch unreachable;
    try std.testing.expectEqualStrings("primary side\n", primary_content);

    // ── Resolve + dirty source: the lane adopts primary's content and adds
    // UNCOMMITTED work — the merge auto-commits the source and folds back.
    try writeAbs(io, lane_conflict, "primary side\n");
    const lane_extra = try std.fs.path.join(gpa, &.{ lane_path, "extra.txt" });
    defer gpa.free(lane_extra);
    try writeAbs(io, lane_extra, "new work\n");
    var final_req = lane_bridge.Request{ .op = .merge, .lane = try gpa.dupe(u8, id), .requester = &fx.runtime.agent };
    defer final_req.deinit(gpa);
    const final_resp = postAndService(io, app, &final_req);
    defer app.gpa.free(final_resp.text);
    try std.testing.expectEqual(@as(u8, 0), final_resp.code);
    try std.testing.expectEqual(@as(usize, 1), app.threads.items.len); // lane removed
    // The auto-committed lane work landed in the primary tree.
    const primary_extra = try std.fs.path.join(gpa, &.{ fx.repo, "extra.txt" });
    defer gpa.free(primary_extra);
    const extra_content = std.Io.Dir.cwd().readFile(io, primary_extra, &buf) catch unreachable;
    try std.testing.expectEqualStrings("new work\n", extra_content);
}

test "laneStatus reports waiting-for-approval before stall" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    const lane = try addFakeWorkingLane(gpa, &app, "abc123");
    lane.worker_context = .{ .io = io, .gpa = gpa };
    lane.turn.state = .active;
    // Anchor activity far enough in the past that the stall check would fire —
    // the approval branch must win over it.
    const now_ms = std.Io.Clock.now(.awake, io).toMilliseconds();
    lane.last_activity_ms = now_ms - worker_stall_ms - 1;
    lane.worker_context.?.approval.command = try gpa.dupe(u8, "rm -rf /scratch");

    const status = laneStatus(&app, lane);
    defer app.gpa.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "waiting for approval") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "STALLED") == null);
}
