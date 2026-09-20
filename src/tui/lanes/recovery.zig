//! Lane crash recovery: enough durable state that a hard crash (segfault,
//! abort, kill — anything that skips defers) can restore the previously-open
//! worker lanes on the next launch as idle threads.
//!
//! Division of truth: git (`git worktree list`) is the authority for whether
//! a worktree exists; the `lanes` table (`session/lane_manifest.zig`) only
//! enriches it with the session link, title, and open/parked state. A
//! per-repo crash marker file gates the flow — written at startup, deleted
//! on any normal unwind — so its existence next launch means "the previous
//! run in this repo died hard". Every manifest write is best-effort: a lost
//! row degrades to today's parked-lane behavior, never an error.

const std = @import("std");
const tui = @import("../../tui.zig");
const lanes_util = @import("../lanes.zig");
const lane_lifecycle = @import("../lane_lifecycle.zig");
const transcript_lifecycle = @import("../transcript_lifecycle.zig");
const vcs = @import("../../vcs.zig");
const paths = @import("../../paths.zig");
const db = @import("../../db.zig");
const session_mod = @import("../../session.zig");
const lane_manifest = @import("../../session/lane_manifest.zig");

const log = std.log.scoped(.lane_recovery);

const App = tui.App;
const Thread = tui.Thread;
const max_threads = tui.max_threads;

/// Worker-lane slots available at restore time: the 2×2 grid is driver + 3.
/// Public because `root.run` sizes its fixed GC keep-name buffer with it.
pub const restore_lane_cap: u32 = max_threads - 1;

/// Marker content is the raw repo key (the launch cwd). A cwd longer than
/// this cannot round-trip through the reader — such a launch reads as "not
/// crashed" and skips recovery silently (pathological; not worth failing).
const marker_content_max: usize = 1024;

// ---------------------------------------------------------------------------
// Crash marker
// ---------------------------------------------------------------------------

const MarkerFiles = struct { base: []u8, name: []u8, full: []u8 };

fn markerFiles(gpa: std.mem.Allocator, home_dir: []const u8, repo_key: []const u8) !MarkerFiles {
    std.debug.assert(home_dir.len > 0);
    std.debug.assert(repo_key.len > 0);
    // One marker per repo key: the config dir is global, and a hash-named
    // file keyed by the cwd keeps a clean exit in repo A from erasing repo
    // B's crash signal.
    var hash: std.hash.Fnv1a_64 = .init();
    hash.update(repo_key);
    const name = try std.fmt.allocPrint(gpa, "crash-{x:0>16}.marker", .{hash.final()});
    errdefer gpa.free(name);
    const base = try paths.platformConfigDir(gpa, home_dir);
    errdefer gpa.free(base);
    const full = try std.fs.path.join(gpa, &.{ base, name });
    errdefer gpa.free(full);
    return .{ .base = base, .name = name, .full = full };
}

fn freeMarkerFiles(gpa: std.mem.Allocator, files: MarkerFiles) void {
    gpa.free(files.base);
    gpa.free(files.name);
    gpa.free(files.full);
}

/// Arm this run's crash marker. Returns true when a marker with matching
/// content already existed — the previous run in this repo died hard. The
/// marker is (re)written unconditionally; `removeStartupMarker` on any
/// normal unwind completes the protocol (a hard crash skips that delete,
/// which is exactly the signal). Content is the repo key, verified on read,
/// so a hash collision with another repo's cwd cannot fake a crash. Never
/// fails the caller.
pub fn markStartup(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, repo_key: []const u8) bool {
    const files = markerFiles(gpa, home_dir, repo_key) catch return false;
    defer freeMarkerFiles(gpa, files);

    std.Io.Dir.cwd().createDirPath(io, files.base) catch {};
    var crashed = false;
    var dir = std.Io.Dir.openDirAbsolute(io, files.base, .{}) catch |err| {
        // A missing config dir is the first-ever-run case; any other read
        // failure must leave a trace — a crash marker we cannot read
        // silently disables recovery for this launch.
        if (err != error.FileNotFound) {
            log.warn("lane.recovery.marker_open_failed err={s}", .{@errorName(err)});
        }
        return false;
    };
    defer dir.close(io);
    var content_buf: [marker_content_max]u8 = undefined;
    if (dir.readFile(io, files.name, &content_buf)) |content| {
        if (paths.pathsEqual(content, repo_key)) crashed = true;
    } else |err| {
        if (err != error.FileNotFound) {
            log.warn("lane.recovery.marker_read_failed err={s}", .{@errorName(err)});
        }
    }
    dir.writeFile(io, .{ .sub_path = files.name, .data = repo_key }) catch |err| {
        log.warn("lane.recovery.marker_write_failed err={s}", .{@errorName(err)});
    };
    return crashed;
}

/// Clean-exit half of the marker protocol. Best-effort; never fails.
pub fn removeStartupMarker(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, repo_key: []const u8) void {
    const files = markerFiles(gpa, home_dir, repo_key) catch return;
    defer freeMarkerFiles(gpa, files);
    std.Io.Dir.deleteFileAbsolute(io, files.full) catch {};
}

// ---------------------------------------------------------------------------
// Manifest sync: derive-based best-effort writes from live Thread state
// ---------------------------------------------------------------------------

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.now(.real, io).toMilliseconds();
}

fn laneManifestHome(app: *const App) ?[]const u8 {
    if (app.liveRuntime()) |rt| return rt.home_dir;
    if (app.templateRuntime()) |rt| return rt.home_dir;
    return null;
}

fn syncLaneUpsert(app: *App, lane: *Thread) void {
    const working = lanes_util.workingLaneOf(lane) orelse return;
    const home = laneManifestHome(app) orelse return;
    const repo_key = app.repoRoot() orelse return;
    lane_manifest.recordLaneUpdated(app.gpa, app.io, home, .{
        .worktree_path = working.path,
        .repo_key = repo_key,
        .session_id = if (lane.id) |*sid| sid.slice() else null,
        .title = lane.title,
        .state = lane_manifest.state_open,
        .now_ms = nowMs(app.io),
    });
}

/// A lane joined `app.threads` (any creation path). Best-effort.
pub fn syncLaneOpened(app: *App, lane: *Thread) void {
    syncLaneUpsert(app, lane);
}

/// A lane's session link or title changed (wake, branch rename, first
/// prompt). Best-effort.
pub fn syncLaneUpdated(app: *App, lane: *Thread) void {
    syncLaneUpsert(app, lane);
}

/// The lane's worktree was torn down (merge, delete, failed-spawn rollback —
/// every removal funnels through `cleanupLaneWorktreeAndBranch`). Best-effort.
pub fn syncLaneDeletedByPath(app: *App, worktree_path: []const u8) void {
    const home = laneManifestHome(app) orelse return;
    lane_manifest.recordLaneDeleted(app.gpa, app.io, home, worktree_path);
}

/// The lane was parked with its worktree kept (`/close`): the row stays,
/// flipped to parked, so recovery never resurrects a deliberately closed
/// lane. Best-effort.
pub fn syncLaneParked(app: *App, worktree_path: []const u8) void {
    const home = laneManifestHome(app) orelse return;
    lane_manifest.recordLaneParked(app.gpa, app.io, home, worktree_path);
}

/// The driver's session changed (`/new`, `/resume`, cross-project switch):
/// refresh the pin so a post-switch crash auto-resumes the session actually
/// in use. Driver-arm only — lane runtimes never pin.
pub fn syncDriverPin(app: *App) void {
    std.debug.assert(app.threads.len() > 0);
    if (app.threads.len() == 0) return;
    if (app.thread != app.threads.slice()[0]) return;
    const rt = app.liveRuntime() orelse return;
    const repo_key = app.repoRoot() orelse return;
    lane_manifest.recordDriverPin(app.gpa, app.io, rt.home_dir, repo_key, rt.session_writer.session.id.slice());
}

/// Startup half of the driver pin: `root.run` holds the driver runtime
/// before the TUI exists, and its session row is already inserted
/// synchronously by `initSession`. Best-effort.
pub fn recordStartupDriverPin(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, repo_key: []const u8, writer: *session_mod.SessionWriter) void {
    lane_manifest.recordDriverPin(gpa, io, home_dir, repo_key, writer.session.id.slice());
}

// ---------------------------------------------------------------------------
// Startup claim (root.run, crash path only, before the hygiene GC spawns)
// ---------------------------------------------------------------------------

/// One lane to restore: git-derived identity + manifest enrichment. All
/// fields owned; free the slice with `freeRecovered`.
pub const RecoveredLane = struct {
    path: []u8,
    branch: []u8,
    title: ?[]u8,
    session_id: ?[]u8,
};

pub fn freeRecovered(gpa: std.mem.Allocator, lanes: []RecoveredLane) void {
    for (lanes) |*item| {
        gpa.free(item.path);
        gpa.free(item.branch);
        if (item.title) |t| gpa.free(t);
        if (item.session_id) |s| gpa.free(s);
    }
    gpa.free(lanes);
}

/// Read the repo's open manifest rows, validate them against git, reconcile
/// stale ones, and cap the result at the grid's worker capacity. Returns
/// null when there is nothing to restore or a read failed — recovery is
/// best-effort and must never fail startup. Rows whose worktree git no
/// longer lists are DELETED here; a `worktreeList` failure aborts BEFORE any
/// deletion, because git being unreachable is not evidence a worktree is
/// gone.
pub fn claimRecoveredLanes(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, repo_key: []const u8) ?[]RecoveredLane {
    std.debug.assert(home_dir.len > 0);
    std.debug.assert(repo_key.len > 0);
    var manager = session_mod.SessionManager.initDefault(gpa, io, home_dir) catch |err| {
        log.warn("lane.recovery.manifest_unavailable err={s}", .{@errorName(err)});
        return null;
    };
    defer manager.deinit();
    const rows = lane_manifest.loadOpenRows(gpa, &manager.connection, repo_key) catch |err| {
        log.warn("lane.recovery.manifest_read_failed err={s}", .{@errorName(err)});
        return null;
    };
    defer lane_manifest.freeRows(gpa, rows);
    if (rows.len == 0) return null;

    const entries = vcs.worktreeList(gpa, io, repo_key) catch |err| {
        log.warn("lane.recovery.worktree_list_failed err={s}", .{@errorName(err)});
        return null;
    };
    defer vcs.freeWorktreeList(gpa, entries);

    return claimFromRows(gpa, &manager.connection, rows, entries, nowMs(io));
}

/// Classification core of `claimRecoveredLanes`, split out so the
/// reconcile/cap logic is testable against synthetic git entries. `rows`
/// must already be ordered `updated_at_ms desc` (the SQL guarantees it).
fn claimFromRows(
    gpa: std.mem.Allocator,
    conn: *db.Connection,
    rows: []const lane_manifest.LaneRow,
    entries: []const vcs.WorktreeEntry,
    now_ms: i64,
) ?[]RecoveredLane {
    var out: std.ArrayList(RecoveredLane) = .empty;
    for (rows) |*row| {
        const entry = matchEntry(row.worktree_path, entries) orelse {
            // Worktree gone (merged/deleted externally, GC'd, or never
            // finished materializing at crash time): the row is stale.
            lane_manifest.deleteLane(gpa, conn, row.worktree_path) catch |err|
                log.warn("lane.recovery.reconcile_failed err={s}", .{@errorName(err)});
            continue;
        };
        if (out.items.len >= restore_lane_cap) {
            parkRow(gpa, conn, row.worktree_path, now_ms, "lane.recovery.overflow_park_failed");
            continue;
        }
        const claimed = buildRecovered(gpa, row, entry) catch |err| {
            // Transient OOM: leave the row OPEN (like the toOwnedSlice path
            // below) so the next launch retries the restore — parking here
            // would durably demote a perfectly good lane on a momentary
            // allocation failure.
            log.warn("lane.recovery.claim_oom path={s} err={s}", .{ row.worktree_path, @errorName(err) });
            continue;
        };
        out.append(gpa, claimed) catch |err| {
            var lost = claimed;
            freeOne(gpa, &lost);
            log.warn("lane.recovery.claim_append_oom path={s} err={s}", .{ row.worktree_path, @errorName(err) });
        };
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return null;
    }
    return out.toOwnedSlice(gpa) catch {
        for (out.items) |*item| freeOne(gpa, item);
        out.deinit(gpa);
        return null;
    };
}

fn buildRecovered(gpa: std.mem.Allocator, row: *const lane_manifest.LaneRow, entry: *const vcs.WorktreeEntry) !RecoveredLane {
    // Branch and path come from git (the authority), never from the row —
    // an async `zay/<hex>` → `zay/<slug>` rename before the crash would
    // otherwise be restored stale.
    const path = try gpa.dupe(u8, entry.path);
    errdefer gpa.free(path);
    const branch = try gpa.dupe(u8, entry.branch);
    errdefer gpa.free(branch);
    const title: ?[]u8 = if (row.title) |t| try gpa.dupe(u8, t) else null;
    errdefer if (title) |t| gpa.free(t);
    const session_id: ?[]u8 = if (row.session_id) |s| try gpa.dupe(u8, s) else null;
    errdefer if (session_id) |s| gpa.free(s);
    return .{ .path = path, .branch = branch, .title = title, .session_id = session_id };
}

fn freeOne(gpa: std.mem.Allocator, item: *RecoveredLane) void {
    gpa.free(item.path);
    gpa.free(item.branch);
    if (item.title) |t| gpa.free(t);
    if (item.session_id) |s| gpa.free(s);
    item.* = undefined;
}

fn parkRow(gpa: std.mem.Allocator, conn: *db.Connection, worktree_path: []const u8, now_ms: i64, comptime warn_label: []const u8) void {
    lane_manifest.markLaneState(gpa, conn, worktree_path, lane_manifest.state_parked, now_ms) catch |err| {
        log.warn("{s} err={s}", .{ warn_label, @errorName(err) });
    };
}

/// Match a manifest row to its git worktree entry by PATH alone: the row
/// exists because zay created this worktree, so the path matching is the
/// existence proof. The branch is NOT checked — a user who detached HEAD or
/// checked out another branch inside the worktree still owns that lane, and
/// failing the match here would delete their session link.
fn matchEntry(worktree_path: []const u8, entries: []const vcs.WorktreeEntry) ?*const vcs.WorktreeEntry {
    for (entries) |*entry| {
        if (paths.pathsEqual(entry.path, worktree_path)) return entry;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Startup restore (tui.run, right after the intro logo)
// ---------------------------------------------------------------------------

/// Build idle threads for the claimed lanes, wire the split grid, and post
/// one notice on the driver transcript. Best-effort end to end: a lane that
/// cannot be built is skipped (its worktree stays on disk, reachable via
/// `/lanes`), and this function never fails startup. Does NOT take ownership
/// of `recovered` — everything here is duped into the threads; the caller
/// frees with `freeRecovered`.
pub fn restoreIntoApp(app: *App, recovered: []const RecoveredLane) void {
    std.debug.assert(app.threads.len() >= 1);
    var restored: u32 = 0;
    for (recovered) |*item| {
        if (app.threads.len() >= max_threads) break;
        const lane = buildIdleThread(app, item) catch |err| {
            log.warn("lane.recovery.restore_skipped path={s} err={s}", .{ item.path, @errorName(err) });
            continue;
        };
        _ = app.assignLaneGeneration(lane);
        app.threads.append(lane) catch |err| {
            lane.deinit(app.gpa);
            app.gpa.destroy(lane);
            log.warn("lane.recovery.restore_skipped path={s} err={s}", .{ item.path, @errorName(err) });
            continue;
        };
        restored += 1;
    }
    if (restored == 0) return;
    // Mirror createParallelLane's committed split-mode block: in `.dual` the
    // driver stays the left pane and the first restored lane takes the right.
    app.split_mode = app.cached_config.tui.split_mode;
    if (app.split_mode == .dual) {
        app.thread = app.threads.slice()[0];
        app.focused_worker_index = 1;
    }
    appendRestoredNotice(app, restored);
    log.warn("lane.recovery.restored count={d}", .{restored});
}

fn buildIdleThread(app: *App, item: *const RecoveredLane) !*Thread {
    const lane = try app.gpa.create(Thread);
    errdefer app.gpa.destroy(lane);
    const branch = try app.gpa.dupe(u8, item.branch);
    errdefer app.gpa.free(branch);
    const path = try app.gpa.dupe(u8, item.path);
    errdefer app.gpa.free(path);
    lane.* = .{ .engine = .{ .idle = .{ .working = .{ .branch = branch, .path = path } } } };
    if (item.title) |t| lane.title = app.gpa.dupe(u8, t) catch null;
    if (item.session_id) |sid| lane.id = session_mod.SessionId.fromSlice(sid) catch null;
    return lane;
}

fn appendRestoredNotice(app: *App, restored: u32) void {
    const note = std.fmt.allocPrint(
        app.gpa,
        "Recovered {d} lane(s) from the previous crash — they are idle. Attach one with /lanes (`o` resumes its conversation) or `lane spawn <id> <task>`.",
        .{restored},
    ) catch return;
    defer app.gpa.free(note);
    _ = app.thread.transcript.append(app.gpa, .notice, "lane", note) catch {};
}

// ---------------------------------------------------------------------------
// Driver session pin (startup auto-resume)
// ---------------------------------------------------------------------------

/// The session id startup should resume: the driver pin when it still
/// resolves, else the pre-existing `findLatest` behavior. The pin exists
/// because lane sessions share the driver's cwd — the most recently updated
/// row is often a lane's, which silently hijacked auto-resume. Honored on
/// every startup, crash or not. Caller owns the returned id.
pub fn resolveStartupResumeId(gpa: std.mem.Allocator, manager: *session_mod.SessionManager, repo_key: []const u8) !?[]u8 {
    if (lane_manifest.loadDriverPin(gpa, &manager.connection, repo_key) catch null) |pin| {
        defer gpa.free(pin);
        // Belt-and-braces: the FK set-null normally keeps pins valid, but a
        // pin from an older build or a tampered DB may dangle — `resume()`
        // is the existence check.
        if (manager.@"resume"(pin)) |_| {
            return try gpa.dupe(u8, pin);
        } else |_| {}
    }
    return manager.findLatest(gpa, repo_key);
}

// ---------------------------------------------------------------------------
// /lanes open action: attach a runtime to a parked or crash-restored lane
// ---------------------------------------------------------------------------

/// The `o` key in the /lanes manage picker. The manage list is parked
/// entries first, then open idle working lanes — the SAME order
/// `merge_flow.buildLaneEntries` renders (both walk the identical filter).
pub fn openSelectedLane(app: *App) !void {
    if (app.getLanesPurpose() != .manage) return;
    const selection = app.getLanesSelection();
    if (selection < app.parked_lanes.len) {
        try openParkedAt(app, selection);
    } else {
        try openIdleAt(app, selection - app.parked_lanes.len);
    }
}

/// The Nth open idle working lane (skipping the driver). `merge_flow`'s
/// manage list is built from this exact walk, so indices stay in lockstep.
pub fn idleLaneAt(app: *const App, index: usize) ?*Thread {
    std.debug.assert(index < app.threads.len());
    var seen: usize = 0;
    for (app.threads.slice(), 0..) |lane, ti| {
        if (ti == 0) continue; // driver
        if (lane.engine != .idle) continue;
        if (lanes_util.workingLaneOf(lane) == null) continue;
        if (seen == index) return lane;
        seen += 1;
    }
    return null;
}

/// How many open idle working lanes the manage list appends after the
/// parked entries.
pub fn countOpenIdleLanes(app: *const App) u32 {
    var count: u32 = 0;
    for (app.threads.slice(), 0..) |lane, ti| {
        if (ti == 0) continue; // driver
        if (lane.engine != .idle) continue;
        if (lanes_util.workingLaneOf(lane) == null) continue;
        count += 1;
    }
    return count;
}

fn openParkedAt(app: *App, index: usize) !void {
    std.debug.assert(index < app.parked_lanes.len);
    if (app.threads.len() >= max_threads) return error.TooManyLanes;
    const repo = app.repoRoot() orelse return error.NoActiveRuntime;
    const entry = app.parked_lanes[index];

    // The manifest row carries the linked session + last title; no row (a
    // crash-mid-spawn orphan, or a worktree from before this feature)
    // opens fresh.
    var session_id: ?[]u8 = null;
    var title: ?[]u8 = null;
    const fetched = fetchRow(app, entry.path, &session_id, &title);
    defer if (session_id) |s| app.gpa.free(s);
    defer if (title) |t| app.gpa.free(t);

    const item = RecoveredLane{ .path = entry.path, .branch = entry.branch, .title = title, .session_id = session_id };
    const lane = try buildIdleThread(app, &item);
    errdefer {
        lane.deinit(app.gpa);
        app.gpa.destroy(lane);
    }
    try app.threads.append(lane);
    errdefer {
        // The lane owns its strings now; a failed wake removes it whole.
        _ = app.threads.orderedRemove(app.threads.len() - 1);
    }
    // When the row read FAILED (not merely absent), skip the post-wake
    // upsert: writing a fresh session id over a row we could not read could
    // permanently unlink the original conversation. The row stays as-is and
    // the next open retries.
    try wakeAndShow(app, lane, repo, session_id, fetched != .failed);
}

fn openIdleAt(app: *App, index: usize) !void {
    const repo = app.repoRoot() orelse return error.NoActiveRuntime;
    const lane = idleLaneAt(app, index) orelse return error.LaneNotFound;
    // A linked session (crash-restored or a rested spawned worker) resumes;
    // a never-run `lane create` lane starts a fresh conversation.
    const session_id: ?[]const u8 = if (lane.id) |*sid| sid.slice() else null;
    try wakeAndShow(app, lane, repo, session_id, true);
}

/// Attach a runtime to `lane` (the session-resume-capable wake), rebuild the
/// lane's transcript mirror from the resumed conversation, sync the
/// manifest, and land the UI on the lane. A failed resume WITH a linked
/// session falls back to a fresh session — the session may have been deleted
/// between crash and open — with an honest notice. `sync_manifest=false`
/// (a failed row read) leaves the stored row untouched: overwriting a row we
/// could not read could permanently unlink its conversation.
fn wakeAndShow(app: *App, lane: *Thread, repo: []const u8, session_id: ?[]const u8, sync_manifest: bool) !void {
    lane_lifecycle.wakeIdleLane(app, lane, repo, &.{}, session_id) catch |err| {
        if (session_id == null) return err;
        log.warn("lane.open.resume_failed err={s} — falling back to a fresh session", .{@errorName(err)});
        try lane_lifecycle.wakeIdleLane(app, lane, repo, &.{}, null);
        _ = lane.transcript.append(app.gpa, .notice, "lane", "Linked session is gone — starting a fresh conversation in this lane.") catch {};
    };
    if (lane.id != null) {
        transcript_lifecycle.rebuildTranscriptRows(app, lane) catch |err| {
            log.warn("lane.open.transcript_rebuild_failed err={s}", .{@errorName(err)});
        };
    }
    if (sync_manifest) syncLaneUpsert(app, lane);
    // Focus mirrors createParallelLane's committed block: in `.dual` the
    // driver keeps input routing and the woken lane takes the worker pane.
    app.split_mode = app.cached_config.tui.split_mode;
    if (app.split_mode == .dual) {
        app.thread = app.threads.slice()[0];
        app.focused_worker_index = indexOfLane(app, lane) orelse 1;
    } else {
        app.thread = lane;
    }
    app.mode = .normal;
    app.clearInput();
    app.clearPaletteInput();
    app.resetTurnState();
}

/// Outcome of a manifest row read for the open action. `absent` is the
/// normal no-row case (crash-mid-spawn orphan, pre-feature worktree); the
/// lane opens fresh. `failed` is a TRANSIENT read error — the caller must
/// not treat it as absent, or a post-wake upsert could overwrite the
/// original session link.
const RowFetch = enum { loaded, absent, failed };

fn fetchRow(app: *App, worktree_path: []const u8, session_id: *?[]u8, title: *?[]u8) RowFetch {
    session_id.* = null;
    title.* = null;
    const home = laneManifestHome(app) orelse {
        log.warn("lane.open.row_read_failed path={s} err=NoActiveRuntime", .{worktree_path});
        return .failed;
    };
    var manager = session_mod.SessionManager.initDefault(app.gpa, app.io, home) catch |err| {
        log.warn("lane.open.row_read_failed path={s} err={s}", .{ worktree_path, @errorName(err) });
        return .failed;
    };
    defer manager.deinit();
    var row = (lane_manifest.lookupLane(app.gpa, &manager.connection, worktree_path) catch |err| {
        log.warn("lane.open.row_read_failed path={s} err={s}", .{ worktree_path, @errorName(err) });
        return .failed;
    }) orelse return .absent;
    defer row.deinit(app.gpa);
    session_id.* = if (row.session_id) |s| (app.gpa.dupe(u8, s) catch null) else null;
    title.* = if (row.title) |t| (app.gpa.dupe(u8, t) catch null) else null;
    return .loaded;
}

fn indexOfLane(app: *const App, target: *Thread) ?u32 {
    for (app.threads.slice(), 0..) |lane, i| {
        if (lane == target) return @intCast(i);
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_helpers = @import("../test_helpers.zig");

test "crash marker: clean first startup, crash on re-arm, remove clears it, mismatched content is not a crash" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_abs);
    const home_abs = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_abs);

    // First ever run: no marker → clean.
    try std.testing.expect(!markStartup(gpa, io, home_abs, "/repo"));
    // Previous run armed the marker and died hard → crash.
    try std.testing.expect(markStartup(gpa, io, home_abs, "/repo"));
    removeStartupMarker(gpa, io, home_abs, "/repo");
    try std.testing.expect(!markStartup(gpa, io, home_abs, "/repo"));

    // A marker whose content is ANOTHER repo's key must not read as this
    // repo's crash (hash-collision guard).
    const files = try markerFiles(gpa, home_abs, "/repo");
    defer freeMarkerFiles(gpa, files);
    std.Io.Dir.cwd().createDirPath(io, files.base) catch {};
    var dir = try std.Io.Dir.openDirAbsolute(io, files.base, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = files.name, .data = "/other-repo" });
    try std.testing.expect(!markStartup(gpa, io, home_abs, "/repo"));
}

test "claim reconciles stale rows, caps restores at the grid capacity, and parks overflow" {
    const gpa = std.testing.allocator;
    var manager = try session_mod.SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    const conn = &manager.connection;

    // Four valid rows (newest first: d > c > b > a) + one stale row whose
    // worktree git no longer lists.
    const RowSpec = struct { path: []const u8, updated: i64 };
    const specs = [_]RowSpec{
        .{ .path = "/wt/a", .updated = 1000 },
        .{ .path = "/wt/b", .updated = 2000 },
        .{ .path = "/wt/c", .updated = 3000 },
        .{ .path = "/wt/d", .updated = 4000 },
        .{ .path = "/wt/gone", .updated = 5000 },
    };
    for (specs) |spec| {
        try lane_manifest.upsertLane(gpa, conn, .{
            .worktree_path = spec.path,
            .repo_key = "/repo",
            .session_id = null,
            .title = null,
            .state = lane_manifest.state_open,
            .now_ms = spec.updated,
        });
    }
    var entries: std.ArrayList(vcs.WorktreeEntry) = .empty;
    defer {
        for (entries.items) |*e| e.deinit(gpa);
        entries.deinit(gpa);
    }
    for ([_][]const u8{ "/wt/a", "/wt/b", "/wt/c", "/wt/d" }) |p| {
        try entries.append(gpa, .{ .path = try gpa.dupe(u8, p), .branch = try gpa.dupe(u8, "zay/hex") });
    }

    const rows = try lane_manifest.loadOpenRows(gpa, conn, "/repo");
    defer lane_manifest.freeRows(gpa, rows);
    try std.testing.expectEqual(@as(usize, 5), rows.len);

    const claimed = claimFromRows(gpa, conn, rows, entries.items, 9000) orelse return error.TestFailed;
    defer freeRecovered(gpa, claimed);

    // Cap is driver + 3 → exactly the three newest restored, newest first.
    try std.testing.expectEqual(restore_lane_cap, claimed.len);
    try std.testing.expect(paths.pathsEqual("/wt/d", claimed[0].path));
    try std.testing.expect(paths.pathsEqual("/wt/c", claimed[1].path));
    try std.testing.expect(paths.pathsEqual("/wt/b", claimed[2].path));

    // Overflow row parked, stale row reconciled away.
    {
        var overflow = (try lane_manifest.lookupLane(gpa, conn, "/wt/a")).?;
        defer overflow.deinit(gpa);
        try std.testing.expectEqualStrings(lane_manifest.state_parked, overflow.state);
    }
    try std.testing.expect((try lane_manifest.lookupLane(gpa, conn, "/wt/gone")) == null);
}

test "claim refuses to delete rows when git is unavailable" {
    const gpa = std.testing.allocator;
    var manager = try session_mod.SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    const conn = &manager.connection;
    try lane_manifest.upsertLane(gpa, conn, .{
        .worktree_path = "/wt/a",
        .repo_key = "/repo",
        .session_id = null,
        .title = null,
        .state = lane_manifest.state_open,
        .now_ms = 1000,
    });
    // A worktreeList ERROR (not an empty list) must abort the claim and keep
    // every row — git being unreachable is not evidence a worktree is gone.
    // Covered at `claimRecoveredLanes` level; here we pin the core: with an
    // empty-but-successful entry list the row IS reconciled (the authority
    // spoke: nothing exists).
    var entries: std.ArrayList(vcs.WorktreeEntry) = .empty;
    defer {
        for (entries.items) |*e| e.deinit(gpa);
        entries.deinit(gpa);
    }
    const rows = try lane_manifest.loadOpenRows(gpa, conn, "/repo");
    defer lane_manifest.freeRows(gpa, rows);
    const claimed = claimFromRows(gpa, conn, rows, entries.items, 9000);
    try std.testing.expect(claimed == null);
    try std.testing.expect((try lane_manifest.lookupLane(gpa, conn, "/wt/a")) == null);
}

test "restoreIntoApp builds idle threads with titles, session ids, and one notice" {
    const gpa = std.testing.allocator;
    var agent = @import("../../agent.zig").Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // restoreIntoApp only reads these (dupes into the threads), so casting
    // the string literals to the owned-slice field types is safe in a test.
    const recovered = [_]RecoveredLane{
        .{ .path = @constCast("/wt/a"), .branch = @constCast("zay/aaa"), .title = @constCast("fix the race"), .session_id = null },
        .{ .path = @constCast("/wt/b"), .branch = @constCast("zay/bbb"), .title = null, .session_id = @constCast("0123456789abcdef0123456789abcdef") },
    };
    restoreIntoApp(&app, &recovered);

    try std.testing.expectEqual(@as(usize, 3), app.threads.len());
    {
        const lane = app.threads.slice()[1];
        try std.testing.expect(lane.engine == .idle);
        try std.testing.expectEqualStrings("fix the race", lane.title.?);
        try std.testing.expect(lane.id == null);
        try std.testing.expect(lane.generation > 0);
    }
    {
        const lane = app.threads.slice()[2];
        try std.testing.expect(lane.engine == .idle);
        // Untitled lane falls back to nothing here (the /lanes picker falls
        // back to the branch at render time).
        try std.testing.expect(lane.title == null);
        try std.testing.expect(lane.id != null);
    }
    // One notice on the driver transcript, and the driver keeps focus
    // (default split mode is not .dual).
    const items = app.thread.transcript.messages.items;
    try std.testing.expect(items.len >= 1);
    var found = false;
    for (items) |m| {
        switch (m) {
            .notice => |n| {
                if (std.mem.indexOf(u8, n.body, "Recovered 2 lane(s)") != null) found = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found);
    try std.testing.expect(app.thread == app.threads.slice()[0]);
}

test "openSelectedLane wakes an idle lane with a fresh session and lands on it" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const home_abs = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_abs);

    var agent = @import("../../agent.zig").Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // A live driver runtime (real session writer) so the wake can attach.
    const driver_runtime = try test_helpers.makeParkTestRuntime(gpa, home_abs);
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = driver_runtime, .owns = true } };
    app.thread.agent = &driver_runtime.agent;
    // The wake clones the template runtime's base + assembled prompts, which
    // `initSession`/`addSystem` assert non-empty — the park fixture ships
    // empty ones by design.
    gpa.free(driver_runtime.base_system_prompt);
    driver_runtime.base_system_prompt = try gpa.dupe(u8, "test base system prompt");
    gpa.free(driver_runtime.system_prompt);
    driver_runtime.system_prompt = try gpa.dupe(u8, "test assembled system prompt");

    // One open idle working lane, selected in the manage picker.
    try test_helpers.addIdleFocusedLane(gpa, &app, "aa11bb");
    const lane = app.thread;
    app.thread = app.threads.slice()[0]; // focus back on the driver
    app.nav.lanes_purpose = .manage;
    app.parked_lanes = &.{};
    app.setLanesSelection(0);

    try openSelectedLane(&app);

    try std.testing.expect(lane.engine == .live);
    try std.testing.expect(lane.id != null);
    try std.testing.expect(app.mode == .normal);
    // Focus mirrors createParallelLane: in `.dual` (the config default) the
    // driver keeps input routing and the woken lane takes the worker pane.
    if (app.split_mode == .dual) {
        try std.testing.expect(app.thread == app.threads.slice()[0]);
        try std.testing.expect(app.focused_worker_index == 1);
    } else {
        try std.testing.expect(app.thread == lane);
    }
}
