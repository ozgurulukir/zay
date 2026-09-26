//! Durable snapshot review records. Unlike the lane manifest, review history
//! is one-to-many per worktree and keeps immutable commit identities.

const std = @import("std");
const db = @import("../db.zig");

const assert = std.debug.assert;

pub const Error = db.Error;
pub const Input = struct {
    id: []const u8,
    lane_id: []const u8,
    repo_key: []const u8,
    worktree_path: []const u8,
    base_oid: []const u8,
    head_oid: []const u8,
    source_session_id: ?[]const u8,
    now_ms: i64,
};

pub fn create(gpa: std.mem.Allocator, conn: *db.Connection, input: Input) Error!void {
    assert(input.id.len == 12);
    assert(input.lane_id.len > 0);
    assert(input.repo_key.len > 0);
    assert(input.worktree_path.len > 0);
    assert(validOid(input.base_oid));
    assert(validOid(input.head_oid));
    const worktree_path = try normalizePathKey(gpa, input.worktree_path);
    defer if (worktree_path.owned) gpa.free(worktree_path.slice);
    var statement = try conn.prepare(
        "insert into lane_reviews(id,lane_id,repo_key,worktree_path,base_oid,head_oid,source_session_id,status,created_at_ms,updated_at_ms) values(?,?,?,?,?,?,?,'pending',?,?)",
    );
    defer statement.finalize();
    try statement.bindText(1, input.id);
    try statement.bindText(2, input.lane_id);
    try statement.bindText(3, input.repo_key);
    try statement.bindText(4, worktree_path.slice);
    try statement.bindText(5, input.base_oid);
    try statement.bindText(6, input.head_oid);
    if (input.source_session_id) |id| try statement.bindText(7, id) else try statement.bindNull(7);
    try statement.bindInt(8, input.now_ms);
    try statement.bindInt(9, input.now_ms);
    try expectDone(&statement);
}

const PathKey = struct { slice: []const u8, owned: bool };

fn normalizePathKey(gpa: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!PathKey {
    if (std.mem.indexOfScalar(u8, path, '\\') == null) return .{ .slice = path, .owned = false };
    const normalized = try gpa.dupe(u8, path);
    for (normalized) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };
    return .{ .slice = normalized, .owned = true };
}

pub fn setRunning(conn: *db.Connection, id: []const u8, session_id: []const u8, now_ms: i64) Error!void {
    assert(id.len == 12);
    assert(session_id.len > 0);
    try update(conn, id, "running", session_id, null, null, now_ms);
}

pub fn complete(conn: *db.Connection, id: []const u8, report_json: []const u8, now_ms: i64) Error!void {
    assert(id.len == 12);
    assert(report_json.len > 0);
    try update(conn, id, "completed", null, report_json, null, now_ms);
}

pub fn stale(conn: *db.Connection, id: []const u8, report_json: []const u8, now_ms: i64) Error!void {
    assert(id.len == 12);
    assert(report_json.len > 0);
    try update(conn, id, "stale", null, report_json, "lane changed after snapshot", now_ms);
}

pub fn fail(conn: *db.Connection, id: []const u8, reason: []const u8, now_ms: i64) Error!void {
    assert(id.len == 12);
    assert(reason.len > 0);
    try update(conn, id, "failed", null, null, reason, now_ms);
}

pub fn readJson(gpa: std.mem.Allocator, conn: *db.Connection, id: []const u8) Error!?[]u8 {
    if (!validRunId(id)) return null;
    var statement = try conn.prepare("select status,head_oid,report_json,error_text from lane_reviews where id=?");
    defer statement.finalize();
    try statement.bindText(1, id);
    const row = (try statement.step()) orelse return null;
    const status = row.text(0);
    const head_oid = row.text(1);
    const report_json = if (row.columnType(2) == .text) row.text(2) else "(no report)";
    const error_text = if (row.columnType(3) == .text) row.text(3) else "none";
    return try std.fmt.allocPrint(gpa, "review {s}: status={s}, head={s}, error={s}\nreport: {s}", .{ id, status, head_oid, error_text, report_json });
}

/// Restore the pre-review session link and fail abandoned runs for one repo.
/// Repeating this after a crash is safe: only pending/running rows match.
pub fn recoverRepo(conn: *db.Connection, repo_key: []const u8, now_ms: i64) Error!void {
    assert(repo_key.len > 0);
    var restore = try conn.prepare("update lanes set session_id=(select source_session_id from lane_reviews r where r.repo_key=? and r.worktree_path=lanes.worktree_path and (r.status in ('pending','running') or r.reviewer_session_id=lanes.session_id) order by r.created_at_ms desc limit 1), updated_at_ms=? where repo_key=? and exists(select 1 from lane_reviews r where r.repo_key=? and r.worktree_path=lanes.worktree_path and (r.status in ('pending','running') or r.reviewer_session_id=lanes.session_id))");
    defer restore.finalize();
    try restore.bindText(1, repo_key);
    try restore.bindInt(2, now_ms);
    try restore.bindText(3, repo_key);
    try restore.bindText(4, repo_key);
    try expectDone(&restore);
    var fail_pending = try conn.prepare("update lane_reviews set status='failed', error_text='interrupted by process restart', updated_at_ms=? where repo_key=? and status in ('pending','running')");
    defer fail_pending.finalize();
    try fail_pending.bindInt(1, now_ms);
    try fail_pending.bindText(2, repo_key);
    try expectDone(&fail_pending);
}

fn update(
    conn: *db.Connection,
    id: []const u8,
    status: []const u8,
    session_id: ?[]const u8,
    report_json: ?[]const u8,
    error_text: ?[]const u8,
    now_ms: i64,
) Error!void {
    var statement = try conn.prepare("update lane_reviews set status=?, reviewer_session_id=coalesce(?,reviewer_session_id), report_json=coalesce(?,report_json), error_text=?, updated_at_ms=? where id=?");
    defer statement.finalize();
    try statement.bindText(1, status);
    if (session_id) |value| try statement.bindText(2, value) else try statement.bindNull(2);
    if (report_json) |value| try statement.bindText(3, value) else try statement.bindNull(3);
    if (error_text) |value| try statement.bindText(4, value) else try statement.bindNull(4);
    try statement.bindInt(5, now_ms);
    try statement.bindText(6, id);
    try expectDone(&statement);
}

fn validOid(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    }
    return true;
}

fn validRunId(value: []const u8) bool {
    if (value.len != 12) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    }
    return true;
}

fn expectDone(statement: *db.Statement) Error!void {
    if (try statement.step() != null) return error.Misuse;
}

test "review run stores immutable snapshot and restart marks unfinished runs failed" {
    const gpa = std.testing.allocator;
    const session_mod = @import("../session.zig");
    var manager = try session_mod.SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    const conn = &manager.connection;
    const oid = "0123456789012345678901234567890123456789";
    try create(gpa, conn, .{
        .id = "0123456789ab",
        .lane_id = "aabbccdd",
        .repo_key = "/repo",
        .worktree_path = "/repo/wt",
        .base_oid = oid,
        .head_oid = oid,
        .source_session_id = null,
        .now_ms = 1,
    });
    const pending = (try readJson(gpa, conn, "0123456789ab")).?;
    defer gpa.free(pending);
    try std.testing.expect(std.mem.indexOf(u8, pending, "status=pending") != null);
    try recoverRepo(conn, "/repo", 2);
    const failed = (try readJson(gpa, conn, "0123456789ab")).?;
    defer gpa.free(failed);
    try std.testing.expect(std.mem.indexOf(u8, failed, "status=failed") != null);
}
