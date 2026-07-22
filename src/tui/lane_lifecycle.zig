//! Lane lifecycle: lane naming, cycling, closing, merging, and the `/lanes`
//! overlay. Free functions taking `*App` — extracted from `tui.zig` (Phase 1 of
//! `_pm/Projects/tui-domain-extract`).

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const agent_mod = @import("../agent.zig");
const agent_worker = @import("agent_worker.zig");
const lanes_util = @import("lanes.zig");
const lanes_picker = @import("widgets/lanes_picker.zig");
const naming_mod = @import("naming.zig");
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
fn collectParkedLanes(app: *App, repo: []const u8) ![]vcs.WorktreeEntry {
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
        if (message.kind != .user and message.kind != .agent) continue;
        if (message.body.len == 0) continue;
        try out.append(app.gpa, try app.gpa.dupe(u8, message.body));
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
        .client = runtime.naming_client,
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
