//! Database schema migration for the session store.

const std = @import("std");
const db = @import("../db.zig");

const assert = std.debug.assert;

/// Current schema version for the sessions database.
pub const schema_version: u32 = 4;

/// Default path relative to the nova home directory.
pub const default_db_relative_path = ".nova/sessions.sqlite";

/// Resolve the default sessions database path under `home_dir`.
pub fn defaultPath(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    assert(home_dir.len > 0);
    const path = try std.fs.path.join(gpa, &.{ home_dir, default_db_relative_path });
    errdefer gpa.free(path);
    return path;
}

/// Migrate the database to the latest schema version.
pub fn migrate(connection: *db.Connection, io: std.Io) !void {
    // Lanes share one repo-level DB; each lane's background writer holds its own
    // connection, so a busy timeout makes concurrent writes wait (WAL serializes
    // writers) instead of failing with SQLITE_BUSY and dropping a session entry.
    try connection.exec("pragma busy_timeout = 5000");
    try connection.exec("pragma foreign_keys = on");
    try connection.exec("pragma journal_mode = wal");
    try connection.exec("create table if not exists schema_migrations(version integer primary key, applied_at_ms integer not null)");
    try connection.exec("create table if not exists sessions(id text primary key, title text, cwd text not null, created_at_ms integer not null, updated_at_ms integer not null, leaf_entry_id text, model_provider text, model_id text, foreign key(id, leaf_entry_id) references session_entries(session_id, id))");
    try connection.exec("create table if not exists session_entries(id text not null, session_id text not null, parent_id text, kind text not null, role text, payload_json text not null, created_at_ms integer not null, snapshot text, primary key(session_id, id), foreign key(session_id) references sessions(id) on delete cascade, foreign key(session_id, parent_id) references session_entries(session_id, id))");
    // Upgrade DBs created before the git-shadow model: add the `snapshot` column
    // (a git commit id binding the entry to its code state). On a fresh DB the
    // column already exists, so the ALTER fails with "duplicate column" — ignore.
    connection.exec("alter table session_entries add column snapshot text") catch {};
    // Upgrade DBs from schema v3 to v4: add model_provider and model_id columns
    connection.exec("alter table sessions add column model_provider text") catch {};
    connection.exec("alter table sessions add column model_id text") catch {};
    try connection.exec("create index if not exists session_entries_parent on session_entries(session_id, parent_id)");
    try connection.exec("create index if not exists session_entries_kind on session_entries(session_id, kind)");
    try connection.exec("create index if not exists session_entries_role on session_entries(session_id, role)");
    try connection.exec("create index if not exists sessions_cwd_updated on sessions(cwd, updated_at_ms)");
    try connection.exec("create table if not exists prompt_history(id integer primary key autoincrement, session_id text not null, prompt_text text not null, created_at_ms integer not null, foreign key(session_id) references sessions(id) on delete cascade)");
    try connection.exec("create index if not exists prompt_history_session on prompt_history(session_id, created_at_ms)");

    var statement = try connection.prepare("insert or ignore into schema_migrations(version, applied_at_ms) values (?, ?)");
    defer statement.finalize();
    _ = io;
}

pub const Error = db.Error || error{};
