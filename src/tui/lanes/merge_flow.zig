//! Merge flow subsystem for parallel lanes — extracted from `lane_lifecycle.zig`.
//!
//! Handles merge destination picking, workspace borrow checks, git merge execution,
//! conflict detection, and parked worktree merging.

const std = @import("std");
const tui = @import("../../tui.zig");
const lanes_util = @import("../lanes.zig");
const lanes_picker = @import("../widgets/lanes_picker.zig");
const vcs = @import("../../vcs.zig");
const command_router = @import("../command_router.zig");
const vaxis = @import("vaxis");
const worktree_job = @import("worktree_job.zig");
const branch_naming = @import("branch_naming.zig");

const App = tui.App;
const Thread = tui.Thread;
const max_threads = tui.max_threads;

pub fn activeIndex(app: *const App) u32 {
    std.debug.assert(app.threads.len() > 0);
    std.debug.assert(app.threads.len() <= max_threads);
    for (app.threads.slice(), 0..) |lane, index| {
        if (lane == app.thread) return @intCast(index);
    }
    return 0;
}

pub fn laneMergeDir(app: *App, lane: *Thread) ?[]const u8 {
    if (lanes_util.workingLaneOf(lane)) |w| return w.path;
    return app.repoRoot();
}

pub fn laneOpenAtPath(app: *App, path: []const u8) bool {
    for (app.threads.slice()) |lane| {
        if (lanes_util.workingLaneOf(lane)) |w| {
            if (lanes_util.pathsEqual(w.path, path)) return true;
        }
    }
    return false;
}

pub fn clearWorkspaceBorrowForPath(app: *App, path: []const u8) !void {
    std.debug.assert(app.threads.len() <= max_threads);
    std.debug.assert(path.len > 0);
    for (app.threads.slice()) |other| {
        const agent = other.agent orelse continue;
        const ws = agent.workspaceBorrow() orelse continue;
        if (!lanes_util.pathsEqual(ws, path)) continue;
        if (other.turn.isActive()) return error.InFlightTurn;
        agent.setWorkspace(null);
    }
}

pub fn clearWorkspaceBorrows(app: *App, lane: *Thread) !void {
    const path = if (lanes_util.workingLaneOf(lane)) |w| w.path else return;
    return clearWorkspaceBorrowForPath(app, path);
}

pub fn collectParkedLanes(app: *App, repo: []const u8) ![]vcs.WorktreeEntry {
    const all = try vcs.worktreeList(app.gpa, app.io, repo);
    defer vcs.freeWorktreeList(app.gpa, all);

    var out: std.ArrayList(vcs.WorktreeEntry) = .empty;
    errdefer {
        for (out.items) |*entry| entry.deinit(app.gpa);
        out.deinit(app.gpa);
    }
    for (all) |entry| {
        if (!std.mem.startsWith(u8, entry.branch, "zay/")) continue;
        if (laneOpenAtPath(app, entry.path)) continue;
        const path_dup = try app.gpa.dupe(u8, entry.path);
        errdefer app.gpa.free(path_dup);
        const branch_dup = try app.gpa.dupe(u8, entry.branch);
        errdefer app.gpa.free(branch_dup);
        try out.append(app.gpa, .{ .path = path_dup, .branch = branch_dup });
    }
    return out.toOwnedSlice(app.gpa);
}

pub fn reloadParkedLanes(app: *App) !void {
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

pub fn laneEntryCount(app: *const App) u32 {
    return switch (app.nav.lanes_purpose) {
        .manage => @intCast(app.parked_lanes.len),
        .merge_dest => @intCast(app.merge_dest_indices.len),
    };
}

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
                const lane = app.threads.slice()[ti];
                out[i] = .{
                    .title = lane.title orelse (if (ti == 0) "primary" else "lane"),
                    .subtitle = if (lanes_util.workingLaneOf(lane)) |w| w.branch else "(primary working copy)",
                };
            }
            return out;
        },
    }
}

pub fn handleLanesKey(app: *App, key: vaxis.Key) !bool {
    return command_router.Lanes.handle(app, key);
}

pub fn laneIdOf(lane: *Thread) ?[]const u8 {
    const working = lanes_util.workingLaneOf(lane) orelse return null;
    return lanes_util.lastPathSegment(working.path);
}

pub fn discardUndeliveredCompletion(app: *App, lane: *Thread) void {
    if (lane.spawned_by_generation == null) return;
    if (lane.completion_delivered) return;
    const finished = (lane.engine == .idle) or
        (lane.engine == .live and lane.turn.state == .idle and
            lane.transcript.messages.items.len > 0);
    if (!finished) return;
    const spawner = app.laneByGeneration(lane.spawned_by_generation.?) orelse {
        lane.completion_delivered = true;
        return;
    };
    const id = laneIdOf(lane) orelse {
        lane.completion_delivered = true;
        return;
    };
    const title = lane.title orelse id;
    const note = std.fmt.allocPrint(app.gpa, "Lane {s} ({s}) was closed before its completion was delivered — result discarded.", .{ title, id }) catch {
        lane.completion_delivered = true;
        return;
    };
    defer app.gpa.free(note);
    _ = spawner.transcript.append(app.gpa, .notice, "lane", note) catch {};
    lane.completion_delivered = true;
}

pub fn abandonLane(app: *App, index: u32) !void {
    std.debug.assert(index > 0);
    std.debug.assert(index < app.threads.len());
    std.debug.assert(app.threads.len() <= max_threads);
    const lane = app.threads.slice()[index];
    var branch: ?[]u8 = null;
    var dir: ?[]u8 = null;
    if (lanes_util.workingLaneOf(lane)) |w| {
        branch = try app.gpa.dupe(u8, w.branch);
        dir = try app.gpa.dupe(u8, w.path);
    }
    defer if (branch) |b| app.gpa.free(b);
    defer if (dir) |d| app.gpa.free(d);

    branch_naming.cancelLaneNaming(app, lane);
    discardUndeliveredCompletion(app, lane);
    _ = app.threads.orderedRemove(index);
    lane.deinit(app.gpa);
    app.gpa.destroy(lane);

    if (app.repoRoot()) |repo| {
        worktree_job.cleanupLaneWorktreeAndBranch(app, repo, dir, branch);
    }
}

pub fn reportLaneError(app: *App, err: anyerror) !void {
    app.mode = .normal;
    app.clearInput();
    clearLanesState(app);
    var buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "Lane operation failed: {s}", .{lanes_util.laneErrorText(err)}) catch blk: {
        break :blk try std.fmt.allocPrint(app.gpa, "Lane operation failed: {s}", .{lanes_util.laneErrorText(err)});
    };
    defer if (message.ptr != &buf) app.gpa.free(message);
    _ = try app.thread.transcript.append(app.gpa, .agent, "agent", message);
}

pub fn mergeLane(app: *App, source: lanes_util.MergeSource, dest: *Thread) !void {
    std.debug.assert(app.threads.len() <= max_threads);
    if (dest.turn.isActive()) return error.InFlightTurn;
    if (source.active_index) |si| {
        if (app.threads.slice()[si].turn.isActive()) return error.InFlightTurn;
    }
    try clearWorkspaceBorrowForPath(app, source.path);
    const dest_dir = laneMergeDir(app, dest) orelse return error.NoActiveRuntime;

    if (try vcs.workingTreeDirty(app.gpa, app.io, source.path)) {
        return error.DirtySourceLane;
    }

    switch (try vcs.merge(app.gpa, app.io, dest_dir, source.branch)) {
        .conflict => return error.MergeConflict,
        .ok => {},
    }

    app.thread = dest;
    if (source.active_index) |si| {
        try abandonLane(app, @intCast(si));
    } else if (app.repoRoot()) |repo| {
        worktree_job.cleanupLaneWorktreeAndBranch(app, repo, source.path, source.branch);
    }

    if (app.threads.len() < 2) app.split_mode = .tab;
    app.nav.block_nav = false;
}

pub fn createMergePicker(app: *App) !void {
    std.debug.assert(app.threads.len() >= 2);
    std.debug.assert(app.threads.len() <= max_threads);
    if (app.thread.turn.isActive()) return error.InFlightTurn;
    const src_index = activeIndex(app);
    if (src_index == 0) return error.CannotMergePrimaryLane;
    const src = lanes_util.workingLaneOf(app.thread) orelse return error.CannotMergePrimaryLane;
    if (app.threads.len() < 2) return error.NoMergeDestination;

    const source: lanes_util.MergeSource = .{ .branch = src.branch, .path = src.path, .active_index = src_index };

    if (app.threads.len() == 2) {
        const dest = app.threads.slice()[if (src_index == 0) 1 else 0];
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
    for (app.threads.slice(), 0..) |_, i| {
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
    const dest = app.threads.slice()[app.merge_dest_indices[app.nav.lanes_selection]];
    const src = lanes_util.workingLaneOf(app.threads.slice()[app.merge_source_index]) orelse {
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

pub fn mergeSelectedParked(app: *App) !void {
    if (app.nav.lanes_selection >= app.parked_lanes.len) return;
    const entry = app.parked_lanes[app.nav.lanes_selection];
    const source: lanes_util.MergeSource = .{ .branch = entry.branch, .path = entry.path, .active_index = null };
    try mergeLane(app, source, app.thread);
    try reloadParkedLanes(app);
}

pub fn deleteSelectedParked(app: *App) !void {
    if (app.nav.lanes_selection >= app.parked_lanes.len) return;
    const entry = app.parked_lanes[app.nav.lanes_selection];
    try clearWorkspaceBorrowForPath(app, entry.path);
    if (app.repoRoot()) |repo| {
        worktree_job.cleanupLaneWorktreeAndBranch(app, repo, entry.path, entry.branch);
    }
    try reloadParkedLanes(app);
}
