//! Database schema migration for the session store.

const std = @import("std");
const db = @import("../db.zig");
const paths = @import("../paths.zig");

const assert = std.debug.assert;

/// Current schema version for the sessions database.
pub const schema_version: u32 = 8;

const backend_mod = @import("backend.zig");

/// Resolve the default sessions database path under `home_dir`.
/// Platform-correct base: Windows -> %APPDATA%\zay, POSIX -> ~/.config/zay.
/// Caller must pass a non-empty home_dir (the `assert` guards the contract;
/// `initDefault` validates upstream).
pub fn defaultPath(gpa: std.mem.Allocator, home_dir: []const u8) Error![]u8 {
    assert(home_dir.len > 0);
    const base = try paths.platformConfigDir(gpa, home_dir);
    errdefer gpa.free(base);
    const path = try std.fs.path.join(gpa, &.{ base, "sessions.sqlite" });
    gpa.free(base);
    errdefer gpa.free(path);
    return path;
}

test "defaultPath: resolves to sessions.sqlite under the platform config dir" {
    const gpa = std.testing.allocator;
    const path = try defaultPath(gpa, "PREFIX");
    defer gpa.free(path);
    // Must end in sessions.sqlite and live under the platform config base
    // (Windows: PREFIX/AppData/Roaming/zay, POSIX: PREFIX/.config/zay).
    try std.testing.expect(std.mem.endsWith(u8, path, "sessions.sqlite"));
    const base = try paths.platformConfigDir(gpa, "PREFIX");
    defer gpa.free(base);
    const expected = try std.fs.path.join(gpa, &.{ base, "sessions.sqlite" });
    defer gpa.free(expected);
    try std.testing.expect(paths.pathsEqual(path, expected));
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
    try connection.exec("create table if not exists sessions(id text primary key, title text, cwd text not null, created_at_ms integer not null, updated_at_ms integer not null, leaf_entry_id text, model_provider text, model_id text, reasoning_effort text, foreign key(id, leaf_entry_id) references session_entries(session_id, id))");
    try connection.exec("create table if not exists session_entries(id text not null, session_id text not null, parent_id text, kind text not null, role text, payload_json text not null, created_at_ms integer not null, snapshot text, primary key(session_id, id), foreign key(session_id) references sessions(id) on delete cascade, foreign key(session_id, parent_id) references session_entries(session_id, id))");
    // Upgrade DBs created before the git-shadow model: add the `snapshot` column
    // (a git commit id binding the entry to its code state). On a fresh DB the
    // column already exists, so the ALTER fails with "duplicate column" — ignore.
    connection.exec("alter table session_entries add column snapshot text") catch {};
    // Upgrade DBs from schema v3 to v4: add model_provider and model_id columns
    connection.exec("alter table sessions add column model_provider text") catch {};
    connection.exec("alter table sessions add column model_id text") catch {};
    // Upgrade DBs from schema v4 to v5: add the session-scoped reasoning effort
    // label. Nullable (NULL = "use config/default"). On a fresh DB the column
    // already exists in the CREATE TABLE, so the ALTER fails — ignore.
    connection.exec("alter table sessions add column reasoning_effort text") catch {};
    try connection.exec("create index if not exists session_entries_parent on session_entries(session_id, parent_id)");
    try connection.exec("create index if not exists session_entries_kind on session_entries(session_id, kind)");
    try connection.exec("create index if not exists session_entries_role on session_entries(session_id, role)");
    try connection.exec("create index if not exists sessions_cwd_updated on sessions(cwd, updated_at_ms)");
    try connection.exec("create table if not exists prompt_history(id integer primary key autoincrement, session_id text not null, prompt_text text not null, created_at_ms integer not null, foreign key(session_id) references sessions(id) on delete cascade)");
    try connection.exec("create index if not exists prompt_history_session on prompt_history(session_id, created_at_ms)");

    // Schema v6: lane crash-recovery manifest + driver session pin. Git
    // (`git worktree list`) remains the authority for whether a worktree
    // exists — these tables only enrich it (session link, title, open/parked
    // state), so every write against them is best-effort. `worktree_path` is
    // the primary key (unique by construction; the hex lane id is its last
    // path segment). `branch` is deliberately NOT stored: branches rename
    // asynchronously (`zay/<hex>` → `zay/<slug>`), and the worktree list
    // always carries the current name.
    try connection.exec("create table if not exists lanes(worktree_path text primary key, repo_key text not null, session_id text, title text, state text not null, created_at_ms integer not null, updated_at_ms integer not null, foreign key(session_id) references sessions(id) on delete set null)");
    try connection.exec("create index if not exists lanes_repo_state on lanes(repo_key, state, updated_at_ms)");
    try connection.exec("create table if not exists driver_pins(repo_key text primary key, session_id text, updated_at_ms integer not null, foreign key(session_id) references sessions(id) on delete set null)");
    // Schema v7: durable review runs are separate from the worktree-keyed
    // lane manifest because one lane can accumulate many snapshot reviews.
    try connection.exec("create table if not exists lane_reviews(id text primary key, lane_id text not null, repo_key text not null, worktree_path text not null, base_oid text not null, head_oid text not null, source_session_id text, reviewer_session_id text, status text not null, report_json text, error_text text, created_at_ms integer not null, updated_at_ms integer not null, foreign key(source_session_id) references sessions(id) on delete set null, foreign key(reviewer_session_id) references sessions(id) on delete set null)");
    try connection.exec("create index if not exists lane_reviews_lane_created on lane_reviews(repo_key, lane_id, created_at_ms)");

    // Upgrade DBs from schema v7 to v8: add host_id for roaming users
    connection.exec("alter table sessions add column host_id text") catch {};
    connection.exec("alter table lanes add column host_id text") catch {};

    var statement = try connection.prepare("insert or ignore into schema_migrations(version, applied_at_ms) values (?, ?)");
    defer statement.finalize();
    try statement.bindValue(1, .{ .int = schema_version });
    try statement.bindValue(2, .{ .int = @intCast(std.Io.Clock.now(.real, io).toMilliseconds()) });
    while (true) {
        if (try statement.step()) |_| {} else break;
    }
}

pub fn migrateBackend(backend: *backend_mod.SessionBackend, io: std.Io) !void {
    if (backend.kind == .local_sqlite) {
        if (backend.local) |*conn| {
            return migrate(conn, io);
        }
        return error.MissingConnection;
    }

    var is_postgres = false;
    if (backend.kind == .turso_http) {
        const client = backend.turso orelse return error.MissingConnection;
        var health = try client.health(io);
        defer health.deinit();
        if (!std.mem.eql(u8, health.status, "ok")) return error.UnavailableBackend;
        is_postgres = false;
    } else if (backend.kind == .d1_http) {
        const client = backend.d1 orelse return error.MissingConnection;
        var health = try client.health(io);
        defer health.deinit();
        if (!std.mem.eql(u8, health.status, "ok")) return error.UnavailableBackend;
        is_postgres = false;
    } else {
        const service = backend.remote orelse return error.MissingConnection;
        var health = try service.health(io);
        defer health.deinit();
        if (!std.mem.eql(u8, health.status, "ok")) return error.UnavailableBackend;
        is_postgres = std.mem.eql(u8, health.backend, "postgres");
        if (!is_postgres and !std.mem.eql(u8, health.backend, "sqlite")) return error.UnsupportedBackend;
    }

    // Versioned, failure-safe remote migrations (#161): the recorded version
    // is read first, only pending units apply, each unit lands as ONE atomic
    // batch, and a unit's version row is written only after the unit
    // succeeded — auth/transport/SQL errors propagate instead of being
    // swallowed as "duplicate column".
    try migrateRemote(BackendTarget{ .backend = backend }, backend.gpa, io, is_postgres);
}

/// One versioned migration unit for remote backends (#161). Statements are
/// idempotent (`create ... if not exists`); column guards run their ALTER
/// only when the column is missing and tolerate exactly the
/// concurrent-application race (a failed ALTER is accepted only when a
/// re-check shows the column arrived). A unit that crashes mid-way is safely
/// retried on the next startup: idempotent DDL plus guards heal any partial
/// application, and the recorded version keeps healthy databases from ever
/// re-running history.
const RemoteMigration = struct {
    version: u32,
    /// SQLite-dialect statements (turso_http, d1_http, sqlite remote service).
    sqlite_sql: []const []const u8,
    /// PostgreSQL override (remote service); null -> sqlite_sql.
    postgres_sql: ?[]const []const u8 = null,
    /// ALTERs guarded by column presence — legacy databases already carry
    /// these columns, fresh ones get them in the v1 CREATE TABLE.
    column_guards: []const ColumnGuard = &.{},
    /// Legacy PostgreSQL prompt_history used a bare integer id without a
    /// generator; upgrade it under an is_identity guard when this unit runs.
    postgres_prompt_history_identity: bool = false,
};

const ColumnGuard = struct {
    table: []const u8,
    column: []const u8,
    /// `alter table ... add column ... text` — valid in both dialects.
    ddl: []const u8,
};

const remote_migrations = [_]RemoteMigration{
    .{
        .version = 1,
        .sqlite_sql = &.{
            "create table if not exists sessions(id text primary key, title text, cwd text not null, created_at_ms bigint not null, updated_at_ms bigint not null, leaf_entry_id text, model_provider text, model_id text, reasoning_effort text, host_id text)",
            "create table if not exists session_entries(id text not null, session_id text not null, parent_id text, kind text not null, role text, payload_json text not null, created_at_ms bigint not null, snapshot text, primary key(session_id, id))",
            "create index if not exists session_entries_parent on session_entries(session_id, parent_id)",
            "create index if not exists session_entries_kind on session_entries(session_id, kind)",
            "create index if not exists session_entries_role on session_entries(session_id, role)",
            "create index if not exists sessions_cwd_updated on sessions(cwd, updated_at_ms)",
        },
    },
    .{
        .version = 2,
        .sqlite_sql = &.{},
        .column_guards = &.{
            .{ .table = "session_entries", .column = "snapshot", .ddl = "alter table session_entries add column snapshot text" },
        },
    },
    .{
        .version = 3,
        .sqlite_sql = &.{},
        .column_guards = &.{
            .{ .table = "sessions", .column = "model_provider", .ddl = "alter table sessions add column model_provider text" },
            .{ .table = "sessions", .column = "model_id", .ddl = "alter table sessions add column model_id text" },
        },
    },
    .{
        .version = 4,
        .sqlite_sql = &.{},
        .column_guards = &.{
            .{ .table = "sessions", .column = "reasoning_effort", .ddl = "alter table sessions add column reasoning_effort text" },
        },
    },
    .{
        .version = 5,
        .sqlite_sql = &.{
            "create table if not exists prompt_history(id integer primary key autoincrement, session_id text not null, prompt_text text not null, created_at_ms bigint not null)",
            "create index if not exists prompt_history_session on prompt_history(session_id, created_at_ms)",
        },
        .postgres_sql = &.{
            "create table if not exists prompt_history(id bigint generated by default as identity primary key, session_id text not null, prompt_text text not null, created_at_ms bigint not null)",
            "create index if not exists prompt_history_session on prompt_history(session_id, created_at_ms)",
        },
        .postgres_prompt_history_identity = true,
    },
    .{
        .version = 6,
        .sqlite_sql = &.{
            "create table if not exists lanes(worktree_path text primary key, repo_key text not null, session_id text, title text, state text not null, created_at_ms bigint not null, updated_at_ms bigint not null, host_id text)",
            "create index if not exists lanes_repo_state on lanes(repo_key, state, updated_at_ms)",
            "create table if not exists driver_pins(repo_key text primary key, session_id text, updated_at_ms bigint not null)",
        },
    },
    .{
        .version = 7,
        .sqlite_sql = &.{
            "create table if not exists lane_reviews(id text primary key, lane_id text not null, repo_key text not null, worktree_path text not null, base_oid text not null, head_oid text not null, source_session_id text, reviewer_session_id text, status text not null, report_json text, error_text text, created_at_ms bigint not null, updated_at_ms bigint not null)",
            "create index if not exists lane_reviews_lane_created on lane_reviews(repo_key, lane_id, created_at_ms)",
        },
    },
    .{
        .version = 8,
        .sqlite_sql = &.{},
        .column_guards = &.{
            .{ .table = "sessions", .column = "host_id", .ddl = "alter table sessions add column host_id text" },
            .{ .table = "lanes", .column = "host_id", .ddl = "alter table lanes add column host_id text" },
        },
    },
};

// The steady-state gate compares against `schema_version`; the unit list must
// end exactly there, or a unit added beyond it would never apply to databases
// already recorded at `schema_version`.
comptime {
    assert(remote_migrations[remote_migrations.len - 1].version == schema_version);
}

/// Adapter presenting a `*SessionBackend` as the migration engine's executor.
/// The engine is generic over this shape so tests can drive the exact same
/// code against a local SQLite connection (no sockets).
const BackendTarget = struct {
    backend: *backend_mod.SessionBackend,

    pub fn exec(self: BackendTarget, io: std.Io, sql: []const u8, params: []const backend_mod.SqlParam) !void {
        return self.backend.exec(io, sql, params);
    }

    pub fn batch(self: BackendTarget, io: std.Io, statements: []const db.service.BatchStatement) !void {
        return self.backend.execBatch(io, statements);
    }

    pub fn query(self: BackendTarget, io: std.Io, sql: []const u8, params: []const backend_mod.SqlParam) !backend_mod.QueryResult {
        return self.backend.query(io, sql, params);
    }
};

/// Read the highest applied migration version, or null when nothing has been
/// recorded yet (fresh database, or a legacy database that predates
/// versioned migrations).
fn remoteAppliedVersion(target: anytype, io: std.Io) !?u32 {
    var res = try target.query(io, "select max(version) from schema_migrations", &.{});
    defer res.deinit();
    if (res.rows.len == 0 or res.rows[0].len == 0) return null;
    return switch (res.rows[0][0]) {
        .int => |v| if (v > 0) @intCast(v) else null,
        else => null,
    };
}

fn remoteColumnExists(target: anytype, io: std.Io, table: []const u8, column: []const u8, is_postgres: bool) !bool {
    const sql = if (is_postgres)
        "select count(*) from information_schema.columns where table_name = ? and column_name = ?"
    else
        "select count(*) from pragma_table_info(?) where name = ?";
    var res = try target.query(io, sql, &.{ .{ .text = table }, .{ .text = column } });
    defer res.deinit();
    if (res.rows.len == 0 or res.rows[0].len == 0) return false;
    return switch (res.rows[0][0]) {
        .int => |v| v > 0,
        else => false,
    };
}

fn remotePromptHistoryHasIdentity(target: anytype, io: std.Io) !bool {
    var res = try target.query(io, "select count(*) from information_schema.columns where table_name = 'prompt_history' and column_name = 'id' and is_identity = 'YES'", &.{});
    defer res.deinit();
    if (res.rows.len == 0 or res.rows[0].len == 0) return false;
    return switch (res.rows[0][0]) {
        .int => |v| v > 0,
        else => false,
    };
}

fn migrateRemote(target: anytype, gpa: std.mem.Allocator, io: std.Io, is_postgres: bool) !void {
    // Bootstrap the version table itself (idempotent, one cheap statement).
    try target.exec(io, "create table if not exists schema_migrations(version integer primary key, applied_at_ms bigint not null)", &.{});
    const current = try remoteAppliedVersion(target, io);
    if (current) |v| {
        // Steady state: history never re-runs; no further roundtrips.
        if (v >= schema_version) return;
    }
    for (remote_migrations) |unit| {
        if (current != null and unit.version <= current.?) continue;
        try applyRemoteMigration(target, gpa, io, unit, is_postgres);
    }
}

fn applyRemoteMigration(target: anytype, gpa: std.mem.Allocator, io: std.Io, unit: RemoteMigration, is_postgres: bool) !void {
    var stmts: std.ArrayList(db.service.BatchStatement) = .empty;
    defer stmts.deinit(gpa);

    for (unit.column_guards) |guard| {
        if (try remoteColumnExists(target, io, guard.table, guard.column, is_postgres)) continue;
        try stmts.append(gpa, .{ .sql = guard.ddl, .params = &.{} });
    }

    if (unit.postgres_prompt_history_identity and is_postgres) {
        if (!(try remotePromptHistoryHasIdentity(target, io))) {
            try stmts.append(gpa, .{ .sql = "alter table prompt_history alter column id add generated by default as identity", .params = &.{} });
        }
    }

    const sql_list = if (is_postgres) (unit.postgres_sql orelse unit.sqlite_sql) else unit.sqlite_sql;
    for (sql_list) |sql| {
        try stmts.append(gpa, .{ .sql = sql, .params = &.{} });
    }

    // One atomic batch per unit: a network failure mid-unit cannot leave a
    // half-applied schema, and idempotent statements make a retry safe.
    if (stmts.items.len > 0) try target.batch(io, stmts.items);

    // Record the unit only after it landed. A primary-key violation here
    // means a CONCURRENT client recorded the same unit — tolerate exactly
    // that case and nothing else.
    target.exec(io, "insert into schema_migrations(version, applied_at_ms) values (?, ?)", &.{
        .{ .int = @intCast(unit.version) },
        .{ .int = @intCast(std.Io.Clock.now(.real, io).toMilliseconds()) },
    }) catch |err| {
        const recorded = remoteAppliedVersion(target, io) catch return err;
        if (recorded != null and recorded.? >= unit.version) return;
        return err;
    };
}

pub const Error = db.Error || error{MissingConnection};

// ─────────────────────────────────────────────────────────────────────────
// Tests drive `migrateRemote` against local SQLite through the same executor
// shape as `BackendTarget` — the versioned engine itself is what needs
// restart/concurrency coverage, and the HTTP backends share SQLite's dialect.
// ─────────────────────────────────────────────────────────────────────────

const SqliteTarget = struct {
    conn: *db.Connection,
    query_count: usize = 0,

    pub fn exec(self: SqliteTarget, io: std.Io, sql: []const u8, params: []const backend_mod.SqlParam) !void {
        _ = io;
        var stmt = try self.conn.prepare(sql);
        defer stmt.finalize();
        for (params, 0..) |p, idx| {
            try stmt.bindValue(@intCast(idx + 1), p);
        }
        while (true) {
            if (try stmt.step()) |_| {} else break;
        }
    }

    /// Local stand-in for the remote backends' atomic single-request batch:
    /// BEGIN … statements … COMMIT with a rollback on any failure.
    pub fn batch(self: SqliteTarget, io: std.Io, statements: []const db.service.BatchStatement) !void {
        _ = io;
        try self.conn.exec("BEGIN");
        errdefer self.conn.exec("ROLLBACK") catch {};
        for (statements) |s| {
            var stmt = try self.conn.prepare(s.sql);
            defer stmt.finalize();
            for (s.params, 0..) |p, idx| {
                try stmt.bindValue(@intCast(idx + 1), p);
            }
            while (true) {
                if (try stmt.step()) |_| {} else break;
            }
        }
        try self.conn.exec("COMMIT");
    }

    pub fn query(self: *SqliteTarget, io: std.Io, sql: []const u8, params: []const backend_mod.SqlParam) !backend_mod.QueryResult {
        _ = io;
        self.query_count += 1;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        var stmt = try self.conn.prepare(sql);
        defer stmt.finalize();
        for (params, 0..) |p, idx| {
            try stmt.bindValue(@intCast(idx + 1), p);
        }

        const num_cols: usize = @intCast(stmt.columnCount());
        var columns = try aa.alloc([]const u8, num_cols);
        for (0..num_cols) |i| {
            columns[i] = try aa.dupe(u8, stmt.columnName(@intCast(i)));
        }

        var rows: std.ArrayList([]backend_mod.SqlParam) = .empty;
        while (try stmt.step()) |row| {
            var cells = try aa.alloc(backend_mod.SqlParam, num_cols);
            for (0..num_cols) |i| {
                const col: i32 = @intCast(i);
                cells[i] = switch (row.columnType(col)) {
                    .null => .null,
                    .int => .{ .int = row.int(col) },
                    .float => .{ .float = row.float(col) },
                    .text => .{ .text = try aa.dupe(u8, row.text(col)) },
                    .blob => .{ .blob = try aa.dupe(u8, row.blob(col)) },
                };
            }
            try rows.append(aa, cells);
        }

        const rows_slice = try aa.alloc([]backend_mod.SqlParam, rows.items.len);
        @memcpy(rows_slice, rows.items);
        return .{
            .arena = arena,
            .columns = columns,
            .types = try aa.alloc(db.ColumnType, num_cols),
            .rows = rows_slice,
            .count = rows_slice.len,
        };
    }
};

fn recordedVersion(target: *SqliteTarget, io: std.Io) !?u32 {
    return remoteAppliedVersion(target, io);
}

test "remote migrations build a fresh schema, then skip history on restart" {
    const io = std.testing.io;
    var conn = try db.Connection.open(":memory:", .{});
    defer conn.close();
    var target = SqliteTarget{ .conn = &conn };

    // Fresh database: the full sequence applies and records v8.
    try migrateRemote(&target, std.testing.allocator, io, false);
    try std.testing.expectEqual(@as(?u32, 8), try recordedVersion(&target, io));

    // Restart: exactly ONE read query (the version probe) — history is never
    // re-executed on a healthy database.
    const before = target.query_count;
    try migrateRemote(&target, std.testing.allocator, io, false);
    try std.testing.expectEqual(@as(usize, 1), target.query_count - before);

    // The engine's tables actually exist (spot-check via the version probe's
    // own table plus one guard query).
    try std.testing.expect(try remoteColumnExists(&target, io, "sessions", "host_id", false));
}

test "remote migrations heal a legacy database with unrecorded versions" {
    const io = std.testing.io;
    var conn = try db.Connection.open(":memory:", .{});
    defer conn.close();

    // A pre-versioning remote database: old column set, no schema_migrations.
    try conn.exec("create table sessions(id text primary key, title text, cwd text not null, created_at_ms bigint not null, updated_at_ms bigint not null, leaf_entry_id text)");
    try conn.exec("create table lanes(worktree_path text primary key, repo_key text not null, session_id text, title text, state text not null, created_at_ms bigint not null, updated_at_ms bigint not null)");

    var target = SqliteTarget{ .conn = &conn };
    try migrateRemote(&target, std.testing.allocator, io, false);

    // The missing columns were added by the guards, not blindly re-ALTERed.
    try std.testing.expect(try remoteColumnExists(&target, io, "sessions", "host_id", false));
    try std.testing.expect(try remoteColumnExists(&target, io, "sessions", "reasoning_effort", false));
    try std.testing.expect(try remoteColumnExists(&target, io, "lanes", "host_id", false));
    try std.testing.expectEqual(@as(?u32, 8), try recordedVersion(&target, io));
}

/// A target whose batch fails whenever a statement contains `fail_marker` —
/// standing in for a mid-sequence network failure.
const FailOnBatchTarget = struct {
    inner: *SqliteTarget,
    fail_marker: []const u8,

    pub fn exec(self: FailOnBatchTarget, io: std.Io, sql: []const u8, params: []const backend_mod.SqlParam) !void {
        return self.inner.exec(io, sql, params);
    }

    pub fn batch(self: FailOnBatchTarget, io: std.Io, statements: []const db.service.BatchStatement) !void {
        for (statements) |s| {
            if (std.mem.indexOf(u8, s.sql, self.fail_marker) != null) return error.QueryFailed;
        }
        return self.inner.batch(io, statements);
    }

    pub fn query(self: FailOnBatchTarget, io: std.Io, sql: []const u8, params: []const backend_mod.SqlParam) !backend_mod.QueryResult {
        return self.inner.query(io, sql, params);
    }
};

test "a failed migration unit is not recorded and retries safely" {
    const io = std.testing.io;
    var conn = try db.Connection.open(":memory:", .{});
    defer conn.close();
    var target = SqliteTarget{ .conn = &conn };

    // v6 (lanes) fails: the version row must stay at 5 and the error must
    // propagate — never swallowed as a duplicate-schema condition.
    var failing = FailOnBatchTarget{ .inner = &target, .fail_marker = "create table if not exists lanes" };
    try std.testing.expectError(error.QueryFailed, migrateRemote(&failing, std.testing.allocator, io, false));
    try std.testing.expectEqual(@as(?u32, 5), try recordedVersion(&target, io));

    // After the "network" recovers, a restart completes the sequence.
    try migrateRemote(&target, std.testing.allocator, io, false);
    try std.testing.expectEqual(@as(?u32, 8), try recordedVersion(&target, io));
}

/// Simulates the concurrent-client race on the version row: the injected
/// failure performs the insert itself (as the "other" client) and then
/// returns a primary-key-conflict-shaped error.
const RacingVersionTarget = struct {
    inner: *SqliteTarget,
    raced: bool = false,

    pub fn exec(self: *RacingVersionTarget, io: std.Io, sql: []const u8, params: []const backend_mod.SqlParam) !void {
        if (std.mem.startsWith(u8, sql, "insert into schema_migrations") and !self.raced) {
            self.raced = true;
            try self.inner.exec(io, sql, params); // the "other" client records it
            return error.ConstraintFailed; // ...and ours then conflicts
        }
        return self.inner.exec(io, sql, params);
    }

    pub fn batch(self: *RacingVersionTarget, io: std.Io, statements: []const db.service.BatchStatement) !void {
        return self.inner.batch(io, statements);
    }

    pub fn query(self: *RacingVersionTarget, io: std.Io, sql: []const u8, params: []const backend_mod.SqlParam) !backend_mod.QueryResult {
        return self.inner.query(io, sql, params);
    }
};

test "concurrent version-row recording is tolerated via recheck" {
    const io = std.testing.io;
    var conn = try db.Connection.open(":memory:", .{});
    defer conn.close();
    var target = SqliteTarget{ .conn = &conn };

    // The first version insert "loses the race": the recheck finds the row
    // the concurrent client wrote and migration continues instead of failing.
    var racing = RacingVersionTarget{ .inner = &target };
    try migrateRemote(&racing, std.testing.allocator, io, false);
    try std.testing.expect(racing.raced);
    try std.testing.expectEqual(@as(?u32, 8), try recordedVersion(&target, io));
}
