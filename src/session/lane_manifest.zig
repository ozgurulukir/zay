//! Lane crash-recovery manifest storage (`lanes` + `driver_pins` tables).
//!
//! Git (`git worktree list`) remains THE AUTHORITY on whether a worktree
//! exists; this module only ENRICHES that view with the data git does not
//! carry — the linked session, a display title, and the open/parked
//! lifecycle state. Two invariants follow:
//!
//!  1. Every write is best-effort for its caller. Lane spawn, teardown, and
//!     the shutdown sweep must never fail because enrichment did, so the
//!     wrapper functions (`record*`, `parkAllOpenBestEffort`) swallow and
//!     log every error; a lost row degrades crash recovery, never the
//!     operation that produced it.
//!  2. The manifest can lag reality. A worktree deleted by hand keeps its
//!     stale row until reconciliation, so readers must re-check git before
//!     acting on what a recovered row claims.
//!
//! The core ops take a `*db.Connection` directly and surface errors — that
//! is the testable seam. The wrappers own the logging policy.

const std = @import("std");
const log = std.log.scoped(.lane_manifest);

const db = @import("../db.zig");
const session_mod = @import("../session.zig");

const assert = std.debug.assert;

pub const Error = db.Error;

/// Lifecycle states of a lane row. Only these two values are valid; writers
/// assert them (the DB column carries no CHECK constraint).
pub const state_open = "open";
pub const state_parked = "parked";

fn isValidState(state: []const u8) bool {
    return std.mem.eql(u8, state, state_open) or std.mem.eql(u8, state, state_parked);
}

/// One row of the `lanes` manifest. All strings are owned by the record;
/// free with `deinit` (or `freeRows` for a whole slice).
pub const LaneRow = struct {
    worktree_path: []u8,
    repo_key: []u8,
    session_id: ?[]u8,
    title: ?[]u8,
    state: []u8,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn deinit(self: *LaneRow, gpa: std.mem.Allocator) void {
        gpa.free(self.worktree_path);
        gpa.free(self.repo_key);
        gpa.free(self.state);
        if (self.session_id) |id| gpa.free(id);
        if (self.title) |title| gpa.free(title);
        self.* = undefined;
    }
};

/// Borrowed-input mirror of LaneRow for writes. `state` is one of
/// `state_open`/`state_parked`.
pub const LaneInput = struct {
    worktree_path: []const u8,
    repo_key: []const u8,
    session_id: ?[]const u8,
    title: ?[]const u8,
    state: []const u8,
    now_ms: i64,
};

/// Free a slice returned by `loadOpenRows` (and every record in it).
pub fn freeRows(gpa: std.mem.Allocator, rows: []LaneRow) void {
    for (rows) |*row| row.deinit(gpa);
    gpa.free(rows);
}

/// The `worktree_path` primary key is matched byte-exactly by SQL, but its
/// two producers disagree on separators: lanes store the native form
/// (`std.fs.path.join`, backslashes on Windows) while git-derived callers
/// pass forward slashes (`git worktree list --porcelain`). Normalize to
/// forward slashes at this boundary so every producer addresses the same
/// row. Worktree paths are always `<config>/worktrees/<hex>` — a literal
/// backslash can never be meaningful in them. `repo_key` is deliberately
/// NOT normalized: both of its producers use the same launch-cwd string.
const PathKey = struct { slice: []const u8, owned: bool };

fn pathKey(gpa: std.mem.Allocator, path: []const u8) Error!PathKey {
    if (std.mem.indexOfScalar(u8, path, '\\') == null) return .{ .slice = path, .owned = false };
    const out = try gpa.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return .{ .slice = out, .owned = true };
}

fn releaseKey(gpa: std.mem.Allocator, key: PathKey) void {
    if (key.owned) gpa.free(key.slice);
}

/// Insert or update one lane row, keyed by `worktree_path`. On conflict the
/// update preserves the row's birth facts (`created_at_ms`, the original
/// `repo_key`) and keeps the stored `title` when `input.title` is null — a
/// caller that doesn't know the title must not erase one already recorded.
pub fn upsertLane(gpa: std.mem.Allocator, conn: *db.Connection, input: LaneInput) Error!void {
    assert(isValidState(input.state));
    const key = try pathKey(gpa, input.worktree_path);
    defer releaseKey(gpa, key);
    var statement = try conn.prepare(
        "insert into lanes(worktree_path, repo_key, session_id, title, state, created_at_ms, updated_at_ms) values (?, ?, ?, ?, ?, ?, ?) " ++
            "on conflict(worktree_path) do update set session_id = excluded.session_id, title = coalesce(excluded.title, title), state = excluded.state, updated_at_ms = excluded.updated_at_ms",
    );
    defer statement.finalize();
    try statement.bindText(1, key.slice);
    try statement.bindText(2, input.repo_key);
    if (input.session_id) |id| {
        try statement.bindText(3, id);
    } else {
        try statement.bindNull(3);
    }
    if (input.title) |title| {
        try statement.bindText(4, title);
    } else {
        try statement.bindNull(4);
    }
    try statement.bindText(5, input.state);
    try statement.bindInt(6, input.now_ms);
    try statement.bindInt(7, input.now_ms);
    try expectDone(&statement);
}

/// Remove one lane row. Matching no rows is fine — teardown cleanup is
/// idempotent by contract (a previous crash may have deleted it already).
pub fn deleteLane(gpa: std.mem.Allocator, conn: *db.Connection, worktree_path: []const u8) Error!void {
    const key = try pathKey(gpa, worktree_path);
    defer releaseKey(gpa, key);
    var statement = try conn.prepare("delete from lanes where worktree_path = ?");
    defer statement.finalize();
    try statement.bindText(1, key.slice);
    try expectDone(&statement);
}

/// Flip one lane's lifecycle state (open <-> parked) and bump its
/// `updated_at_ms`. A no-op when the row is absent.
pub fn markLaneState(gpa: std.mem.Allocator, conn: *db.Connection, worktree_path: []const u8, state: []const u8, now_ms: i64) Error!void {
    assert(isValidState(state));
    const key = try pathKey(gpa, worktree_path);
    defer releaseKey(gpa, key);
    var statement = try conn.prepare("update lanes set state = ?, updated_at_ms = ? where worktree_path = ?");
    defer statement.finalize();
    try statement.bindText(1, state);
    try statement.bindInt(2, now_ms);
    try statement.bindText(3, key.slice);
    try expectDone(&statement);
}

/// Park every still-open lane of `repo_key` — the shutdown sweep. A clean
/// exit parks all open lanes, so an "open" row found later means a crash,
/// not a normal exit.
pub fn parkAllOpen(conn: *db.Connection, repo_key: []const u8, now_ms: i64) Error!void {
    var statement = try conn.prepare("update lanes set state = ?, updated_at_ms = ? where repo_key = ? and state = ?");
    defer statement.finalize();
    try statement.bindText(1, state_parked);
    try statement.bindInt(2, now_ms);
    try statement.bindText(3, repo_key);
    try statement.bindText(4, state_open);
    try expectDone(&statement);
}

/// Load the repo's open lane rows, newest activity first — the
/// crash-recovery candidates. Caller owns the slice; free with `freeRows`.
pub fn loadOpenRows(gpa: std.mem.Allocator, conn: *db.Connection, repo_key: []const u8) Error![]LaneRow {
    var statement = try conn.prepare("select worktree_path, repo_key, session_id, title, state, created_at_ms, updated_at_ms from lanes where repo_key = ? and state = ? order by updated_at_ms desc");
    defer statement.finalize();
    try statement.bindText(1, repo_key);
    try statement.bindText(2, state_open);

    var rows: std.ArrayList(LaneRow) = .empty;
    errdefer {
        for (rows.items) |*row| row.deinit(gpa);
        rows.deinit(gpa);
    }
    while (try statement.step()) |row| {
        try rows.append(gpa, try readLaneRow(gpa, &row));
    }
    return rows.toOwnedSlice(gpa);
}

/// Single lane row by primary key, or null when absent (git deleted the
/// worktree, or the manifest never recorded it). Caller owns the record.
pub fn lookupLane(gpa: std.mem.Allocator, conn: *db.Connection, worktree_path: []const u8) Error!?LaneRow {
    const key = try pathKey(gpa, worktree_path);
    defer releaseKey(gpa, key);
    var statement = try conn.prepare("select worktree_path, repo_key, session_id, title, state, created_at_ms, updated_at_ms from lanes where worktree_path = ?");
    defer statement.finalize();
    try statement.bindText(1, key.slice);
    const row = (try statement.step()) orelse return null;
    return try readLaneRow(gpa, &row);
}

/// Pin the driver session for `repo_key` (insert or overwrite). The pin
/// names the session a crash-recovery prompt should resume into.
pub fn upsertDriverPin(conn: *db.Connection, repo_key: []const u8, session_id: []const u8, now_ms: i64) Error!void {
    var statement = try conn.prepare(
        "insert into driver_pins(repo_key, session_id, updated_at_ms) values (?, ?, ?) " ++
            "on conflict(repo_key) do update set session_id = excluded.session_id, updated_at_ms = excluded.updated_at_ms",
    );
    defer statement.finalize();
    try statement.bindText(1, repo_key);
    try statement.bindText(2, session_id);
    try statement.bindInt(3, now_ms);
    try expectDone(&statement);
}

/// The pinned session id for `repo_key`, or null when unpinned (no row, or
/// the pinned session was deleted and the FK nulled the column). Caller
/// owns the returned string.
pub fn loadDriverPin(gpa: std.mem.Allocator, conn: *db.Connection, repo_key: []const u8) Error!?[]u8 {
    var statement = try conn.prepare("select session_id from driver_pins where repo_key = ?");
    defer statement.finalize();
    try statement.bindText(1, repo_key);
    const row = (try statement.step()) orelse return null;
    if (row.columnType(0) == .null) return null;
    return try gpa.dupe(u8, row.text(0));
}

/// Column read mirrors `session.readSummary`: nullable columns checked by
/// type, owned strings duped off the statement's transient buffers. Each
/// dupe registers its own errdefer so an OOM partway through cannot leak
/// the earlier ones.
fn readLaneRow(gpa: std.mem.Allocator, row: *const db.Row) Error!LaneRow {
    const worktree_path = try gpa.dupe(u8, row.text(0));
    errdefer gpa.free(worktree_path);
    const repo_key = try gpa.dupe(u8, row.text(1));
    errdefer gpa.free(repo_key);
    const session_id: ?[]u8 = if (row.columnType(2) == .null) null else try gpa.dupe(u8, row.text(2));
    errdefer if (session_id) |id| gpa.free(id);
    const title: ?[]u8 = if (row.columnType(3) == .null) null else try gpa.dupe(u8, row.text(3));
    errdefer if (title) |t| gpa.free(t);
    const state = try gpa.dupe(u8, row.text(4));
    errdefer gpa.free(state);
    return .{
        .worktree_path = worktree_path,
        .repo_key = repo_key,
        .session_id = session_id,
        .title = title,
        .state = state,
        .created_at_ms = row.int(5),
        .updated_at_ms = row.int(6),
    };
}

fn expectDone(statement: *db.Statement) Error!void {
    if (try statement.step()) |_| return error.Sqlite;
}

/// Wall-clock milliseconds, mirroring `session.zig`'s `nowMs`.
fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.now(.real, io).toMilliseconds();
}

// === best-effort wrappers =====================================================
//
// The only surface TUI/startup call sites use. Each opens a short-lived
// default manager and turns every failure into a `warn` — enrichment must
// never fail its caller, so none of these propagate errors.

/// Open a short-lived default manager for the wrappers. Null on any failure
/// (already logged). The empty-home check exists because `initDefault`
/// asserts on it — an assert would panic instead of degrading to the logged
/// no-op the best-effort contract requires.
fn openManager(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, comptime op_name: []const u8) ?session_mod.SessionManager {
    if (home_dir.len == 0) {
        log.warn("lane_manifest." ++ op_name ++ ".failed err=NoHomeDir", .{});
        return null;
    }
    return session_mod.SessionManager.initDefault(gpa, io, home_dir) catch |err| {
        log.warn("lane_manifest." ++ op_name ++ ".failed err={s}", .{@errorName(err)});
        return null;
    };
}

/// Record a freshly spawned lane. Best effort.
pub fn recordLaneOpened(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, input: LaneInput) void {
    var manager = openManager(gpa, io, home_dir, "recordLaneOpened") orelse return;
    defer manager.deinit();
    upsertLane(gpa, &manager.connection, input) catch |err| {
        log.warn("lane_manifest.recordLaneOpened.failed err={s}", .{@errorName(err)});
    };
}

/// Record a lane mutation (session link, title, state change). Best effort;
/// same upsert as `recordLaneOpened` — the separate name documents intent at
/// call sites.
pub fn recordLaneUpdated(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, input: LaneInput) void {
    var manager = openManager(gpa, io, home_dir, "recordLaneUpdated") orelse return;
    defer manager.deinit();
    upsertLane(gpa, &manager.connection, input) catch |err| {
        log.warn("lane_manifest.recordLaneUpdated.failed err={s}", .{@errorName(err)});
    };
}

/// Forget a lane whose worktree is gone. Best effort; idempotent.
pub fn recordLaneDeleted(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, worktree_path: []const u8) void {
    var manager = openManager(gpa, io, home_dir, "recordLaneDeleted") orelse return;
    defer manager.deinit();
    deleteLane(gpa, &manager.connection, worktree_path) catch |err| {
        log.warn("lane_manifest.recordLaneDeleted.failed err={s}", .{@errorName(err)});
    };
}

/// Park one lane (worker finished without crashing). Best effort.
pub fn recordLaneParked(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, worktree_path: []const u8) void {
    var manager = openManager(gpa, io, home_dir, "recordLaneParked") orelse return;
    defer manager.deinit();
    markLaneState(gpa, &manager.connection, worktree_path, state_parked, nowMs(io)) catch |err| {
        log.warn("lane_manifest.recordLaneParked.failed err={s}", .{@errorName(err)});
    };
}

/// Pin the driver session for `repo_key`. Best effort.
pub fn recordDriverPin(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, repo_key: []const u8, session_id: []const u8) void {
    var manager = openManager(gpa, io, home_dir, "recordDriverPin") orelse return;
    defer manager.deinit();
    upsertDriverPin(&manager.connection, repo_key, session_id, nowMs(io)) catch |err| {
        log.warn("lane_manifest.recordDriverPin.failed err={s}", .{@errorName(err)});
    };
}

/// Park every open lane of `repo_key` (clean-shutdown sweep). Best effort.
pub fn parkAllOpenBestEffort(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, repo_key: []const u8) void {
    var manager = openManager(gpa, io, home_dir, "parkAllOpenBestEffort") orelse return;
    defer manager.deinit();
    parkAllOpen(&manager.connection, repo_key, nowMs(io)) catch |err| {
        log.warn("lane_manifest.parkAllOpenBestEffort.failed err={s}", .{@errorName(err)});
    };
}

test "lane upsert inserts, then updates preserve birth facts and coalesce the title" {
    const gpa = std.testing.allocator;
    var manager = try session_mod.SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    const conn = &manager.connection;

    // Sessions exist first: lanes.session_id is a real foreign key.
    const sid_a = "1" ** 32; // 32 = session_id_len
    const sid_b = "2" ** 32;
    _ = try manager.create("/tmp/zay", .{ .id = sid_a });
    _ = try manager.create("/tmp/zay", .{ .id = sid_b });

    try upsertLane(gpa, conn, .{
        .worktree_path = "/repo/.worktrees/aaa",
        .repo_key = "/repo",
        .session_id = sid_a,
        .title = "first title",
        .state = state_open,
        .now_ms = 1000,
    });
    {
        var row = (try lookupLane(gpa, conn, "/repo/.worktrees/aaa")) orelse return error.TestFailed;
        defer row.deinit(gpa);
        try std.testing.expectEqual(@as(i64, 1000), row.created_at_ms);
        try std.testing.expectEqual(@as(i64, 1000), row.updated_at_ms);
        try std.testing.expectEqualStrings("/repo", row.repo_key);
        try std.testing.expectEqualStrings("open", row.state);
        try std.testing.expectEqualStrings("first title", row.title.?);
        try std.testing.expectEqualStrings(sid_a, row.session_id.?);
    }

    // Update: new session id + state; null title keeps the stored one;
    // created_at_ms and the original repo_key survive the conflict path.
    try upsertLane(gpa, conn, .{
        .worktree_path = "/repo/.worktrees/aaa",
        .repo_key = "/somewhere/else",
        .session_id = sid_b,
        .title = null,
        .state = state_parked,
        .now_ms = 2000,
    });
    {
        var row = (try lookupLane(gpa, conn, "/repo/.worktrees/aaa")) orelse return error.TestFailed;
        defer row.deinit(gpa);
        try std.testing.expectEqual(@as(i64, 1000), row.created_at_ms);
        try std.testing.expectEqual(@as(i64, 2000), row.updated_at_ms);
        try std.testing.expectEqualStrings("/repo", row.repo_key);
        try std.testing.expectEqualStrings("parked", row.state);
        try std.testing.expectEqualStrings("first title", row.title.?);
        try std.testing.expectEqualStrings(sid_b, row.session_id.?);
    }

    // A non-null title replaces the stored one; null session_id unlinks.
    try upsertLane(gpa, conn, .{
        .worktree_path = "/repo/.worktrees/aaa",
        .repo_key = "/repo",
        .session_id = null,
        .title = "second title",
        .state = state_open,
        .now_ms = 3000,
    });
    {
        var row = (try lookupLane(gpa, conn, "/repo/.worktrees/aaa")) orelse return error.TestFailed;
        defer row.deinit(gpa);
        try std.testing.expectEqualStrings("second title", row.title.?);
        try std.testing.expect(row.session_id == null);
    }
}

test "deleteLane removes the row and is idempotent" {
    const gpa = std.testing.allocator;
    var manager = try session_mod.SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    const conn = &manager.connection;

    try std.testing.expect((try lookupLane(gpa, conn, "/repo/wt/a")) == null);

    try upsertLane(gpa, conn, .{
        .worktree_path = "/repo/wt/a",
        .repo_key = "/repo",
        .session_id = null,
        .title = null,
        .state = state_open,
        .now_ms = 1000,
    });
    try deleteLane(gpa, conn, "/repo/wt/a");
    try std.testing.expect((try lookupLane(gpa, conn, "/repo/wt/a")) == null);

    // Second delete matches no rows and still succeeds (idempotent cleanup).
    try deleteLane(gpa, conn, "/repo/wt/a");
}

test "markLaneState and parkAllOpen flip only the targeted rows" {
    const gpa = std.testing.allocator;
    var manager = try session_mod.SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    const conn = &manager.connection;

    try upsertLane(gpa, conn, .{ .worktree_path = "/repo/wt/a", .repo_key = "/repo", .session_id = null, .title = null, .state = state_open, .now_ms = 1000 });
    try upsertLane(gpa, conn, .{ .worktree_path = "/repo/wt/b", .repo_key = "/repo", .session_id = null, .title = null, .state = state_open, .now_ms = 1000 });
    try upsertLane(gpa, conn, .{ .worktree_path = "/other/wt/c", .repo_key = "/other", .session_id = null, .title = null, .state = state_open, .now_ms = 1000 });

    try markLaneState(gpa, conn, "/repo/wt/a", state_parked, 2000);
    {
        var row = (try lookupLane(gpa, conn, "/repo/wt/a")) orelse return error.TestFailed;
        defer row.deinit(gpa);
        try std.testing.expectEqualStrings("parked", row.state);
        try std.testing.expectEqual(@as(i64, 2000), row.updated_at_ms);
    }
    {
        var row = (try lookupLane(gpa, conn, "/repo/wt/b")) orelse return error.TestFailed;
        defer row.deinit(gpa);
        try std.testing.expectEqualStrings("open", row.state);
        try std.testing.expectEqual(@as(i64, 1000), row.updated_at_ms);
    }

    try parkAllOpen(conn, "/repo", 3000);
    {
        var row = (try lookupLane(gpa, conn, "/repo/wt/b")) orelse return error.TestFailed;
        defer row.deinit(gpa);
        try std.testing.expectEqualStrings("parked", row.state);
        try std.testing.expectEqual(@as(i64, 3000), row.updated_at_ms);
    }
    // The other repo's open lane is untouched by the /repo sweep.
    {
        var row = (try lookupLane(gpa, conn, "/other/wt/c")) orelse return error.TestFailed;
        defer row.deinit(gpa);
        try std.testing.expectEqualStrings("open", row.state);
    }
}

test "loadOpenRows filters by repo and state, newest activity first" {
    const gpa = std.testing.allocator;
    var manager = try session_mod.SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    const conn = &manager.connection;

    // No rows yet: an empty (but owned) slice.
    {
        const rows = try loadOpenRows(gpa, conn, "/repo");
        defer freeRows(gpa, rows);
        try std.testing.expectEqual(@as(usize, 0), rows.len);
    }

    try upsertLane(gpa, conn, .{ .worktree_path = "/repo/wt/newest", .repo_key = "/repo", .session_id = null, .title = null, .state = state_open, .now_ms = 3000 });
    try upsertLane(gpa, conn, .{ .worktree_path = "/repo/wt/oldest", .repo_key = "/repo", .session_id = null, .title = null, .state = state_open, .now_ms = 1000 });
    // Parked rows and other repos' rows are filtered out.
    try upsertLane(gpa, conn, .{ .worktree_path = "/repo/wt/parked", .repo_key = "/repo", .session_id = null, .title = null, .state = state_parked, .now_ms = 9999 });
    try upsertLane(gpa, conn, .{ .worktree_path = "/other/wt/d", .repo_key = "/other", .session_id = null, .title = null, .state = state_open, .now_ms = 5000 });

    const rows = try loadOpenRows(gpa, conn, "/repo");
    defer freeRows(gpa, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("/repo/wt/newest", rows[0].worktree_path);
    try std.testing.expectEqualStrings("/repo/wt/oldest", rows[1].worktree_path);
    try std.testing.expectEqual(@as(i64, 3000), rows[0].updated_at_ms);
    try std.testing.expectEqual(@as(i64, 1000), rows[1].updated_at_ms);
}

test "deleting the linked session nulls the lane and driver-pin foreign keys" {
    const gpa = std.testing.allocator;
    var manager = try session_mod.SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    const conn = &manager.connection;

    var linked = try manager.create("/tmp/zay", .{});
    const linked_id = try gpa.dupe(u8, linked.id.slice());
    defer gpa.free(linked_id);

    try upsertLane(gpa, conn, .{
        .worktree_path = "/repo/wt/a",
        .repo_key = "/repo",
        .session_id = linked_id,
        .title = null,
        .state = state_open,
        .now_ms = 1000,
    });
    try upsertDriverPin(conn, "/repo", linked_id, 1000);

    // `on delete set null`: the manifest rows survive, the links don't.
    try manager.deleteSession(linked_id);

    {
        var row = (try lookupLane(gpa, conn, "/repo/wt/a")) orelse return error.TestFailed;
        defer row.deinit(gpa);
        try std.testing.expect(row.session_id == null);
    }
    try std.testing.expect((try loadDriverPin(gpa, conn, "/repo")) == null);
}

test "worktree_path keys match across native and git separator spellings" {
    const gpa = std.testing.allocator;
    var manager = try session_mod.SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    const conn = &manager.connection;

    // Written with the lane's native (backslash) form — Windows — the row
    // must be reachable by the forward-slash form git prints, and deletable
    // by the mixed form, because SQL matches the key byte-exactly.
    try upsertLane(gpa, conn, .{
        .worktree_path = "C:\\Users\\dev\\AppData\\Roaming\\zay\\worktrees\\aa11bb",
        .repo_key = "C:/repo",
        .session_id = null,
        .title = null,
        .state = state_open,
        .now_ms = 1000,
    });
    {
        var row = (try lookupLane(gpa, conn, "C:/Users/dev/AppData/Roaming/zay/worktrees/aa11bb")) orelse return error.TestFailed;
        defer row.deinit(gpa);
        // The STORED key is the normalized form; later reads by any spelling
        // hit the same row (no duplicate inserts).
        try std.testing.expectEqualStrings("C:/Users/dev/AppData/Roaming/zay/worktrees/aa11bb", row.worktree_path);
    }
    // A second upsert in git form must UPDATE, not insert a duplicate row.
    try upsertLane(gpa, conn, .{
        .worktree_path = "C:/Users/dev/AppData/Roaming/zay/worktrees/aa11bb",
        .repo_key = "C:/repo",
        .session_id = null,
        .title = "renamed",
        .state = state_open,
        .now_ms = 2000,
    });
    {
        var row = (try lookupLane(gpa, conn, "C:\\Users\\dev\\AppData\\Roaming\\zay\\worktrees\\aa11bb")) orelse return error.TestFailed;
        defer row.deinit(gpa);
        try std.testing.expectEqualStrings("renamed", row.title.?);
        try std.testing.expectEqual(@as(i64, 1000), row.created_at_ms);
    }
    try markLaneState(gpa, conn, "C:/Users/dev/AppData/Roaming/zay/worktrees/aa11bb", state_parked, 3000);
    try deleteLane(gpa, conn, "C:\\Users\\dev\\AppData\\Roaming\\zay\\worktrees\\aa11bb");
    try std.testing.expect((try lookupLane(gpa, conn, "C:/Users/dev/AppData/Roaming/zay/worktrees/aa11bb")) == null);
}

test "driver pin round-trips: absent, set, re-pinned, and deleted-session nulling" {
    const gpa = std.testing.allocator;
    var manager = try session_mod.SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    const conn = &manager.connection;

    // Absent → null.
    try std.testing.expect((try loadDriverPin(gpa, conn, "/repo")) == null);

    // Set → id.
    _ = try manager.create("/tmp/zay", .{ .id = "4" ** 32 });
    try upsertDriverPin(conn, "/repo", "4" ** 32, 1000);
    {
        const pin = (try loadDriverPin(gpa, conn, "/repo")) orelse return error.TestFailed;
        defer gpa.free(pin);
        try std.testing.expectEqualStrings("4" ** 32, pin);
    }

    // Re-pinning the same repo overwrites the old pin.
    _ = try manager.create("/tmp/zay", .{ .id = "5" ** 32 });
    try upsertDriverPin(conn, "/repo", "5" ** 32, 2000);
    {
        const pin = (try loadDriverPin(gpa, conn, "/repo")) orelse return error.TestFailed;
        defer gpa.free(pin);
        try std.testing.expectEqualStrings("5" ** 32, pin);
    }

    // Deleting the pinned session nulls the FK → unpinned again.
    try manager.deleteSession("5" ** 32);
    try std.testing.expect((try loadDriverPin(gpa, conn, "/repo")) == null);
}
