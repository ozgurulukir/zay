//! Branch naming subsystem for parallel lanes — extracted from `lane_lifecycle.zig`.
//!
//! Handles capturing parent context, scheduling naming via LLM naming client,
//! draining naming results during ticks, and renaming lane branches.

const std = @import("std");
const tui = @import("../../tui.zig");
const naming_mod = @import("../naming.zig");
const vcs = @import("../../vcs.zig");

const App = tui.App;
const Thread = tui.Thread;
const max_threads = tui.max_threads;

/// Point `lane`'s working branch at `zay/<slug>` — the git rename plus the
/// lane's own records (branch string, label). False when the lane has no
/// working branch or the new name is taken.
pub fn renameLaneBranch(app: *App, lane: *Thread, slug: []const u8) !bool {
    const live = switch (lane.engine) {
        .live => |*l| l,
        .idle => return false,
    };
    const working = switch (live.lane) {
        .working => |*w| w,
        .primary => return false,
    };

    const branch = try app.gpa.alloc(u8, "zay/".len + slug.len);
    errdefer app.gpa.free(branch);
    @memcpy(branch[0.."zay/".len], "zay/");
    @memcpy(branch["zay/".len..], slug);
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
/// `zay/<hex>` becomes `zay/<slug>` in place (worktree HEADs follow), and
/// the branch becomes the lane's label. A rejected or colliding name simply
/// leaves the hex branch.
pub fn drainLaneNaming(app: *App) !bool {
    var changed = false;
    for (app.threads.slice()) |lane| {
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
    std.debug.assert(app.threads.len() > 0);
    std.debug.assert(app.threads.len() <= max_threads);
    for (app.threads.slice()) |lane| {
        if (lane.naming_future != null) return true;
    }
    return false;
}
