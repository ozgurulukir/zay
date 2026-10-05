const std = @import("std");

const ai = @import("ai.zig");
const compaction = @import("context/compaction.zig");
const db = @import("db.zig");

const assert = std.debug.assert;

const session_type = @import("session/types.zig");
const session_migration = @import("session/migration.zig");
const session_backend = @import("session/backend.zig");
const serialize = @import("session/serialize.zig");
const session_writer = @import("session/writer.zig");
const paths = @import("paths.zig");

pub const SessionWriter = session_writer.SessionWriter;
pub const SessionBackend = session_backend.SessionBackend;
pub const BackendKind = session_backend.BackendKind;
const backend_mod = session_backend;

pub const entry_id_len = session_type.entry_id_len;
const session_id_len = session_type.session_id_len;
pub const path_entries_max = session_type.path_entries_max;
pub const EntryId = session_type.EntryId;
pub const SessionId = session_type.SessionId;
pub const Error = session_type.Error;
const EntryQueue = session_type.EntryQueue;
pub const QueuedEntry = session_type.QueuedEntry;
pub const CreateOptions = session_type.CreateOptions;
pub const SessionSummary = session_type.SessionSummary;
pub const ProjectKey = session_type.ProjectKey;
pub const ProjectLocation = session_type.ProjectLocation;
pub const ProjectRoot = session_type.ProjectRoot;
pub const PendingProjectBinding = session_type.PendingProjectBinding;
pub const ResumeResolution = session_type.ResumeResolution;
pub const project_key_len = session_type.project_key_len;
pub const lane_manifest = @import("session/lane_manifest.zig");
pub const review_runs = @import("session/review_runs.zig");
pub const EntryRecord = session_type.EntryRecord;
pub const UserEntryRef = session_type.UserEntryRef;
pub const CompactionBoundary = session_type.CompactionBoundary;
pub const CompactionCut = session_type.CompactionCut;
pub const EntryKind = session_type.EntryKind;
pub const EntrySummary = session_type.EntrySummary;

/// The backend selection a caller wants the session store to come from.
/// Borrowed strings — a picker builds it from the live config right before
/// use. `kind == null` falls back to `remote_service` when a url is present,
/// else `local_sqlite`.
pub const SessionStore = struct {
    kind: ?BackendKind = null,
    url: ?[]const u8 = null,
    token: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

pub const resolveHostId = backend_mod.resolveHostId;

pub const SessionManager = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    backend: SessionBackend,
    connection: db.Connection,
    host_id: []const u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Error!SessionManager {
        return initWithHost(gpa, io, path, "default-host");
    }

    pub fn initWithHost(gpa: std.mem.Allocator, io: std.Io, path: []const u8, host_id: []const u8) Error!SessionManager {
        assert(path.len > 0);
        // :memory: is a special SQLite path — no filesystem directory needed.
        if (!std.mem.eql(u8, path, ":memory:")) {
            const dirname = std.fs.path.dirname(path) orelse ".";
            std.Io.Dir.createDirPath(.cwd(), io, dirname) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                error.FileNotFound,
                error.NotDir,
                error.BadPathName,
                => return error.InvalidPath,
                error.Canceled => return error.Canceled,
                else => return error.SystemResources,
            };
        }
        // In-memory sessions can share this connection with the database tool.
        var connection = try db.Connection.open(path, .{ .full_mutex = true });
        var b = SessionBackend.openLocal(gpa, connection, host_id, path) catch |err| {
            connection.close();
            return err;
        };
        errdefer b.deinit();
        try session_migration.migrateBackend(&b, io);
        return .{
            .gpa = gpa,
            .io = io,
            .backend = b,
            .connection = connection,
            .host_id = b.host_id,
        };
    }

    pub fn initDefault(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) Error!SessionManager {
        assert(home_dir.len > 0);
        const db_path = try session_migration.defaultPath(gpa, home_dir);
        defer gpa.free(db_path);
        return init(gpa, io, db_path);
    }

    pub fn initDefaultWithHost(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, host_id: []const u8) Error!SessionManager {
        assert(home_dir.len > 0);
        const db_path = try session_migration.defaultPath(gpa, home_dir);
        defer gpa.free(db_path);
        return initWithHost(gpa, io, db_path, host_id);
    }

    fn initConfiguredLocal(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, host_id: []const u8, custom_path: ?[]const u8) Error!SessionManager {
        if (custom_path) |path| {
            if (path.len > 0) return initWithHost(gpa, io, path, host_id);
        }
        return initDefaultWithHost(gpa, io, home_dir, host_id);
    }

    pub fn initRemote(gpa: std.mem.Allocator, io: std.Io, url: []const u8, auth_token: ?[]const u8, host_id: []const u8) Error!SessionManager {
        assert(url.len > 0);
        var b = try SessionBackend.openRemote(gpa, url, auth_token, host_id);
        errdefer b.deinit();
        try session_migration.migrateBackend(&b, io);
        const conn = db.Connection.open(":memory:", .{}) catch return error.SystemResources;
        return .{
            .gpa = gpa,
            .io = io,
            .backend = b,
            .connection = conn,
            .host_id = b.host_id,
        };
    }

    pub fn initTurso(gpa: std.mem.Allocator, io: std.Io, url: []const u8, auth_token: ?[]const u8, host_id: []const u8) Error!SessionManager {
        assert(url.len > 0);
        var b = try SessionBackend.openTurso(gpa, url, auth_token, host_id);
        errdefer b.deinit();
        try session_migration.migrateBackend(&b, io);
        const conn = db.Connection.open(":memory:", .{}) catch return error.SystemResources;
        return .{
            .gpa = gpa,
            .io = io,
            .backend = b,
            .connection = conn,
            .host_id = b.host_id,
        };
    }

    pub fn initD1(gpa: std.mem.Allocator, io: std.Io, url: []const u8, auth_token: ?[]const u8, host_id: []const u8) Error!SessionManager {
        assert(url.len > 0);
        var b = try SessionBackend.openD1(gpa, url, auth_token, host_id);
        errdefer b.deinit();
        try session_migration.migrateBackend(&b, io);
        const conn = db.Connection.open(":memory:", .{}) catch return error.SystemResources;
        return .{
            .gpa = gpa,
            .io = io,
            .backend = b,
            .connection = conn,
            .host_id = b.host_id,
        };
    }

    pub fn initFromConfig(
        gpa: std.mem.Allocator,
        io: std.Io,
        home_dir: []const u8,
        database_server_url: ?[]const u8,
        database_auth_token: ?[]const u8,
        env_map: ?*const std.process.Environ.Map,
    ) Error!SessionManager {
        return initFromModularConfig(gpa, io, home_dir, null, database_server_url, database_auth_token, null, env_map);
    }

    /// One config-aware session-store open used by EVERY picker surface
    /// (list, rename, delete, bind, resume — INV-BACKEND). `fallback_ok`
    /// controls the fail-safe behavior when a configured remote store cannot
    /// be reached: `true` warns and opens local SQLite (startup / new-session
    /// semantics); `false` propagates the error so a remote session id is
    /// never accidentally resolved against an unrelated local database.
    pub fn initStore(
        gpa: std.mem.Allocator,
        io: std.Io,
        home_dir: []const u8,
        store: SessionStore,
        host_id: []const u8,
        fallback_ok: bool,
    ) Error!SessionManager {
        const kind: BackendKind = store.kind orelse (if (store.url != null and store.url.?.len > 0) .remote_service else .local_sqlite);
        switch (kind) {
            .local_sqlite => return initConfiguredLocal(gpa, io, home_dir, host_id, store.path),
            .postgres_native => {
                const log = std.log.scoped(.session);
                log.warn("session.backend_not_implemented backend=postgres_native", .{});
                // Honor fallback_ok like every other remote arm: a resume/picker
                // open must never quietly talk to local SQLite when the
                // configured backend is a different (unimplemented) store —
                // the id would resolve against the wrong database.
                if (!fallback_ok) return error.BackendNotImplemented;
                return initConfiguredLocal(gpa, io, home_dir, host_id, store.path);
            },
            .remote_service, .turso_http, .d1_http => {
                const url = store.url orelse "";
                if (url.len == 0) {
                    if (!fallback_ok) return error.MissingDatabaseUrl;
                    return initConfiguredLocal(gpa, io, home_dir, host_id, store.path);
                }
                if (openRemoteStore(gpa, io, kind, url, store.token, host_id)) |manager| {
                    return manager;
                } else |err| {
                    if (!fallback_ok) return err;
                    const log = std.log.scoped(.session);
                    log.warn("session.external_db_fallback url={s} err={s}", .{ url, @errorName(err) });
                    return initConfiguredLocal(gpa, io, home_dir, host_id, store.path);
                }
            },
        }
    }

    fn openRemoteStore(
        gpa: std.mem.Allocator,
        io: std.Io,
        kind: BackendKind,
        url: []const u8,
        token: ?[]const u8,
        host_id: []const u8,
    ) Error!SessionManager {
        return switch (kind) {
            .remote_service => initRemote(gpa, io, url, token, host_id),
            .turso_http => initTurso(gpa, io, url, token, host_id),
            .d1_http => initD1(gpa, io, url, token, host_id),
            else => unreachable,
        };
    }

    pub fn initFromModularConfig(
        gpa: std.mem.Allocator,
        io: std.Io,
        home_dir: []const u8,
        backend_opt: ?backend_mod.BackendKind,
        url_opt: ?[]const u8,
        token_opt: ?[]const u8,
        custom_path: ?[]const u8,
        env_map: ?*const std.process.Environ.Map,
    ) Error!SessionManager {
        const host_id = backend_mod.resolveHostId(gpa, env_map) catch null;
        defer if (host_id) |h| gpa.free(h);
        const host_slice = host_id orelse "default-host";

        var resolved_backend = backend_opt;
        var resolved_url = url_opt;
        var resolved_token = token_opt;
        var resolved_path = custom_path;

        if (env_map) |em| {
            if (em.get("ZAY_DATABASE_BACKEND")) |b_str| {
                if (b_str.len > 0) resolved_backend = backend_mod.BackendKind.fromString(b_str) orelse return error.InvalidDatabaseBackend;
            }
            if (em.get("ZAY_DATABASE_URL")) |u| {
                if (u.len > 0) resolved_url = u;
            } else if (em.get("ZAY_DATABASE_SERVER_URL")) |u| {
                if (u.len > 0) resolved_url = u;
            }
            if (em.get("ZAY_DATABASE_AUTH_TOKEN")) |t| {
                if (t.len > 0) resolved_token = t;
            }
            if (em.get("ZAY_DATABASE_PATH")) |p| {
                if (p.len > 0) resolved_path = p;
            }
        }

        const fallback_kind: backend_mod.BackendKind = if (resolved_url != null and resolved_url.?.len > 0) .remote_service else .local_sqlite;
        const kind = resolved_backend orelse fallback_kind;

        return initStore(gpa, io, home_dir, .{
            .kind = kind,
            .url = resolved_url,
            .token = resolved_token,
            .path = resolved_path,
        }, host_slice, true);
    }

    pub fn deinit(self: *SessionManager) void {
        if (self.backend.kind != .local_sqlite) {
            self.connection.close();
        }
        self.backend.deinit();
        self.* = undefined;
    }

    pub fn create(self: *SessionManager, cwd: []const u8, options: CreateOptions) Error!Session {
        assert(cwd.len > 0);
        var id_buffer: [session_id_len]u8 = undefined;
        const session_id = if (options.id) |id| blk: {
            if (id.len != session_id_len) return error.BadSessionId;
            @memcpy(id_buffer[0..], id);
            break :blk id_buffer[0..];
        } else blk: {
            fillHex(self.io, &id_buffer);
            break :blk id_buffer[0..];
        };

        const timestamp_ms = nowMs(self.io);
        const host = options.host_id orelse self.host_id;

        // Project association (INV-PROJECT-ID): an explicit key wins (it is
        // validated); otherwise reuse the most recent current-host binding
        // for this cwd's normalized key, or mint a fresh opaque key. The
        // location write (when needed) and the session insert land as ONE
        // atomic unit (INV-DB-BATCH).
        var minted_buffer: [project_key_len]u8 = undefined;
        var minted = false;
        var reused_key: ?[]u8 = null;
        defer if (reused_key) |key| self.gpa.free(key);
        const project_key: []const u8 = blk: {
            if (options.project_key) |explicit| {
                _ = try session_type.ProjectKey.validate(explicit);
                break :blk explicit;
            }
            const cwd_key = try paths.cwdKeyForHost(self.gpa, cwd);
            defer self.gpa.free(cwd_key);
            // The lookup's allocation outlives this block (project_key reads
            // it for the insert below), so free happens via `reused_key`.
            reused_key = try self.lookupProjectKeyForCwdKey(cwd_key);
            if (reused_key) |existing| {
                break :blk existing;
            }
            self.mintProjectKey(&minted_buffer);
            minted = true;
            break :blk minted_buffer[0..];
        };
        // An explicit key may be new to this host+cwd — map it. A reused
        // binding's location row already exists and is left untouched.
        const write_location = minted or options.project_key != null;

        const sql = "insert into sessions(id, title, cwd, project_key, created_at_ms, updated_at_ms, leaf_entry_id, model_provider, model_id, host_id) values (?, ?, ?, ?, ?, ?, null, ?, ?, ?)";
        const params = [_]backend_mod.SqlParam{
            .{ .text = session_id },
            if (options.title) |t| .{ .text = t } else .null,
            .{ .text = cwd },
            .{ .text = project_key },
            .{ .int = timestamp_ms },
            .{ .int = timestamp_ms },
            if (options.model_provider) |mp| .{ .text = mp } else .null,
            if (options.model_id) |mid| .{ .text = mid } else .null,
            if (host.len > 0) .{ .text = host } else .null,
        };

        if (write_location) {
            const cwd_key = try paths.cwdKeyForHost(self.gpa, cwd);
            defer self.gpa.free(cwd_key);
            if (self.backend.kind == .local_sqlite) {
                try self.backend.beginTransaction(self.io);
                errdefer self.backend.rollbackTransaction(self.io) catch {};
                try self.upsertProjectLocationExec(project_key, cwd, cwd_key, timestamp_ms);
                try self.backend.exec(self.io, sql, &params);
                try self.backend.commitTransaction(self.io);
            } else {
                // Locations are CURRENT-host bindings (`self.host_id`) —
                // never the session row's origin `host` (INV-HOST-BINDING).
                const del_params = [_]backend_mod.SqlParam{
                    .{ .text = project_key },
                    .{ .text = self.host_id },
                    .{ .text = cwd_key },
                };
                const ins_params = [_]backend_mod.SqlParam{
                    .{ .text = project_key },
                    .{ .text = self.host_id },
                    .{ .text = cwd },
                    .{ .text = cwd_key },
                    .{ .int = timestamp_ms },
                };
                const statements = [_]db.service.BatchStatement{
                    .{ .sql = "delete from project_locations where project_key = ? and host_id = ? and cwd_key = ?", .params = &del_params },
                    .{ .sql = "insert into project_locations(project_key, host_id, cwd, cwd_key, updated_at_ms) values (?, ?, ?, ?, ?)", .params = &ins_params },
                    .{ .sql = sql, .params = &params },
                };
                try self.backend.execBatch(self.io, &statements);
            }
        } else {
            try self.backend.exec(self.io, sql, &params);
        }

        const session = Session{
            .manager = self,
            .id = .{ .bytes = id_buffer },
            .leaf_entry_id = null,
        };
        assert(session.id.bytes.len == session_id_len);
        return session;
    }

    fn mintProjectKey(self: *SessionManager, buffer: *[project_key_len]u8) void {
        const prefix = session_type.project_key_prefix;
        @memcpy(buffer[0..prefix.len], prefix);
        fillHex(self.io, buffer[prefix.len..]);
    }

    /// Newest `project_key` bound to `(current host, cwd_key)`, or null.
    fn lookupProjectKeyForCwdKey(self: *SessionManager, cwd_key: []const u8) Error!?[]u8 {
        const sql = "select project_key from project_locations where host_id = ? and cwd_key = ? order by updated_at_ms desc limit 1";
        var qres = try self.backend.query(self.io, sql, &.{ .{ .text = self.host_id }, .{ .text = cwd_key } });
        defer qres.deinit();
        if (qres.rows.len == 0) return null;
        return switch (qres.rows[0][0]) {
            .text => |t| try self.gpa.dupe(u8, t),
            else => null,
        };
    }

    /// Local-exec dialect upsert of one `(project_key, host, cwd)` binding.
    /// Caller owns the surrounding transaction.
    fn upsertProjectLocationExec(self: *SessionManager, project_key: []const u8, cwd: []const u8, cwd_key: []const u8, timestamp_ms: i64) Error!void {
        const sql = "insert or replace into project_locations(project_key, host_id, cwd, cwd_key, updated_at_ms) values (?, ?, ?, ?, ?)";
        try self.backend.exec(self.io, sql, &.{
            .{ .text = project_key },
            .{ .text = self.host_id },
            .{ .text = cwd },
            .{ .text = cwd_key },
            .{ .int = timestamp_ms },
        });
    }

    pub fn @"resume"(self: *SessionManager, session_id: []const u8) Error!Session {
        assert(session_id.len > 0);
        if (session_id.len != session_id_len) return error.BadSessionId;

        const sql = "select leaf_entry_id from sessions where id = ?";
        var qres = try self.backend.query(self.io, sql, &.{.{ .text = session_id }});
        defer qres.deinit();

        if (qres.rows.len == 0) return error.MissingSession;
        const row = qres.rows[0];

        const id = try SessionId.fromSlice(session_id);
        var leaf_buffer: [entry_id_len]u8 = undefined;
        const leaf = switch (row[0]) {
            .null => null,
            .text => |value| blk: {
                if (value.len != entry_id_len) return error.BadEntryId;
                @memcpy(leaf_buffer[0..], value);
                break :blk EntryId{ .bytes = leaf_buffer };
            },
            else => return error.BadEntryId,
        };
        return .{ .manager = self, .id = id, .leaf_entry_id = leaf };
    }

    pub fn list(self: *SessionManager, gpa: std.mem.Allocator, cwd: ?[]const u8) Error![]SessionSummary {
        const sql = if (cwd == null)
            "select id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id, model_provider, model_id, reasoning_effort, host_id, project_key from sessions where leaf_entry_id is not null order by updated_at_ms desc, id desc"
        else
            "select id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id, model_provider, model_id, reasoning_effort, host_id, project_key from sessions where cwd = ? and leaf_entry_id is not null order by updated_at_ms desc, id desc";

        const params = if (cwd) |path|
            &[_]backend_mod.SqlParam{.{ .text = path }}
        else
            &[_]backend_mod.SqlParam{};

        var qres = try self.backend.query(self.io, sql, params);
        defer qres.deinit();

        var summaries: std.ArrayList(SessionSummary) = .empty;
        errdefer {
            for (summaries.items) |*summary| summary.deinit(gpa);
            summaries.deinit(gpa);
        }
        for (qres.rows) |row| {
            try summaries.append(gpa, try readSummaryFromRow(gpa, row));
        }
        try fillLocalCwds(self, gpa, summaries.items);
        return summaries.toOwnedSlice(gpa);
    }

    /// Attach each summary's current-host mapped directory (`local_cwd`) so
    /// the resume picker can show the local basename for a roaming project.
    /// One query over this host's bindings; unbound or foreign-only projects
    /// stay null. Best-effort: a failed lookup leaves the field null (the
    /// list itself never fails) — but it is logged, because a silent null
    /// makes every bound project render as "project root required".
    fn fillLocalCwds(self: *SessionManager, gpa: std.mem.Allocator, summaries: []SessionSummary) Error!void {
        var has_key = false;
        for (summaries) |*s| {
            if (s.project_key != null) has_key = true;
        }
        if (!has_key) return;
        const sql = "select project_key, cwd from project_locations where host_id = ? order by updated_at_ms desc";
        var qres = self.backend.query(self.io, sql, &.{.{ .text = self.host_id }}) catch |err| {
            const log = std.log.scoped(.session);
            log.warn("session.picker.local_cwd_fill_failed err={s}", .{@errorName(err)});
            return;
        };
        defer qres.deinit();
        var map = std.StringHashMap([]const u8).init(gpa);
        defer map.deinit();
        for (qres.rows) |row| {
            const key = switch (row[0]) {
                .text => |t| t,
                else => continue,
            };
            const cwd = switch (row[1]) {
                .text => |t| t,
                else => continue,
            };
            // Rows are newest-first: keep the first (newest) binding per project.
            const entry = try map.getOrPut(key);
            if (!entry.found_existing) entry.value_ptr.* = cwd;
        }
        for (summaries) |*s| {
            if (s.local_cwd != null) continue;
            const key = s.project_key orelse continue;
            if (map.get(key)) |cwd| {
                s.local_cwd = try gpa.dupe(u8, cwd);
            }
        }
    }

    /// Find the most recently updated session for the given cwd. Returns null
    /// when no session exists for this directory. Caller owns the returned id.
    pub fn findLatest(self: *SessionManager, gpa: std.mem.Allocator, cwd: []const u8) Error!?[]u8 {
        const sql = "select id from sessions where cwd = ? and leaf_entry_id is not null order by updated_at_ms desc, id desc limit 1";
        var qres = try self.backend.query(self.io, sql, &.{.{ .text = cwd }});
        defer qres.deinit();

        if (qres.rows.len == 0) return null;
        switch (qres.rows[0][0]) {
            .text => |t| return try gpa.dupe(u8, t),
            else => return null,
        }
    }

    // === project identity & host-local binding (schema v9) ==================
    //
    // A session belongs to a logical project (`sessions.project_key`, opaque);
    // each host binds that project to one or more local roots in
    // `project_locations`. A foreign or missing cwd is never used as a
    // runtime root (INV-RESUME-CWD) — resolution returns
    // `.needs_project_root` and the TUI asks for a verified local directory.

    /// The current host's binding for `cwd`, or null. Caller owns the key.
    pub fn projectKeyForCwd(self: *SessionManager, gpa: std.mem.Allocator, cwd: []const u8) Error!?[]u8 {
        const cwd_key = try paths.cwdKeyForHost(self.gpa, cwd);
        defer self.gpa.free(cwd_key);
        const found = try self.lookupProjectKeyForCwdKey(cwd_key);
        if (found) |key| {
            defer self.gpa.free(key);
            return try gpa.dupe(u8, key);
        }
        return null;
    }

    /// Reuse the current-host binding for `cwd` or mint + persist a new one.
    /// Caller owns the returned key.
    pub fn ensureProjectForCwd(self: *SessionManager, gpa: std.mem.Allocator, cwd: []const u8) Error![]u8 {
        const cwd_key = try paths.cwdKeyForHost(self.gpa, cwd);
        defer self.gpa.free(cwd_key);
        if (try self.lookupProjectKeyForCwdKey(cwd_key)) |existing| {
            defer self.gpa.free(existing);
            return try gpa.dupe(u8, existing);
        }
        var buffer: [project_key_len]u8 = undefined;
        self.mintProjectKey(&buffer);
        const timestamp_ms = nowMs(self.io);
        if (self.backend.kind == .local_sqlite) {
            try self.backend.beginTransaction(self.io);
            errdefer self.backend.rollbackTransaction(self.io) catch {};
            try self.upsertProjectLocationExec(buffer[0..], cwd, cwd_key, timestamp_ms);
            try self.backend.commitTransaction(self.io);
        } else {
            const del_params = [_]backend_mod.SqlParam{
                .{ .text = buffer[0..] },
                .{ .text = self.host_id },
                .{ .text = cwd_key },
            };
            const ins_params = [_]backend_mod.SqlParam{
                .{ .text = buffer[0..] },
                .{ .text = self.host_id },
                .{ .text = cwd },
                .{ .text = cwd_key },
                .{ .int = timestamp_ms },
            };
            const statements = [_]db.service.BatchStatement{
                .{ .sql = "delete from project_locations where project_key = ? and host_id = ? and cwd_key = ?", .params = &del_params },
                .{ .sql = "insert into project_locations(project_key, host_id, cwd, cwd_key, updated_at_ms) values (?, ?, ?, ?, ?)", .params = &ins_params },
            };
            try self.backend.execBatch(self.io, &statements);
        }
        return try gpa.dupe(u8, buffer[0..]);
    }

    /// Bind `project_key` (minted when null) to `cwd` on this host and stamp
    /// the selected session row with it — the user-confirmed half of the lazy
    /// legacy backfill. Binding + session update are one atomic unit. Caller
    /// owns the returned key.
    pub fn bindProjectCwd(
        self: *SessionManager,
        gpa: std.mem.Allocator,
        session_id: []const u8,
        project_key: ?[]const u8,
        cwd: []const u8,
    ) Error![]u8 {
        assert(session_id.len > 0);
        assert(cwd.len > 0);
        const cwd_key = try paths.cwdKeyForHost(self.gpa, cwd);
        defer self.gpa.free(cwd_key);

        // Resolve a null key without writing anything first. The mapping and
        // the selected-session stamp must share one transaction/batch; an
        // earlier ensureProjectForCwd call could leave a location behind when
        // the subsequent session update failed.
        var owned_key: ?[]u8 = null;
        var minted_buffer: [project_key_len]u8 = undefined;
        const resolved: []const u8 = if (project_key) |key| blk: {
            _ = try session_type.ProjectKey.validate(key);
            break :blk key;
        } else blk: {
            owned_key = try self.lookupProjectKeyForCwdKey(cwd_key);
            if (owned_key) |existing| break :blk existing;
            self.mintProjectKey(&minted_buffer);
            break :blk minted_buffer[0..];
        };
        defer if (owned_key) |key| self.gpa.free(key);

        const timestamp_ms = nowMs(self.io);

        const update_sql = "update sessions set project_key = ?, updated_at_ms = ? where id = ?";
        const update_params = [_]backend_mod.SqlParam{
            .{ .text = resolved },
            .{ .int = timestamp_ms },
            .{ .text = session_id },
        };
        if (self.backend.kind == .local_sqlite) {
            try self.backend.beginTransaction(self.io);
            errdefer self.backend.rollbackTransaction(self.io) catch {};
            try self.upsertProjectLocationExec(resolved, cwd, cwd_key, timestamp_ms);
            try self.backend.exec(self.io, update_sql, &update_params);
            try self.backend.commitTransaction(self.io);
        } else {
            const del_params = [_]backend_mod.SqlParam{
                .{ .text = resolved },
                .{ .text = self.host_id },
                .{ .text = cwd_key },
            };
            const ins_params = [_]backend_mod.SqlParam{
                .{ .text = resolved },
                .{ .text = self.host_id },
                .{ .text = cwd },
                .{ .text = cwd_key },
                .{ .int = timestamp_ms },
            };
            const statements = [_]db.service.BatchStatement{
                .{ .sql = "delete from project_locations where project_key = ? and host_id = ? and cwd_key = ?", .params = &del_params },
                .{ .sql = "insert into project_locations(project_key, host_id, cwd, cwd_key, updated_at_ms) values (?, ?, ?, ?, ?)", .params = &ins_params },
                .{ .sql = update_sql, .params = &update_params },
            };
            try self.backend.execBatch(self.io, &statements);
        }
        return try gpa.dupe(u8, resolved);
    }

    /// Resolve where the selected session should run on THIS host. Preference
    /// order: the current runtime root when bound to the project; the newest
    /// existing current-host location; otherwise an explicit request for a
    /// project root. A legacy unbound row whose origin cwd still exists on
    /// this host is lazily bound (same-host rows only — foreign rows keep
    /// `default-host` ambiguity and always ask).
    pub fn resolveProjectCwd(
        self: *SessionManager,
        gpa: std.mem.Allocator,
        session_id: []const u8,
        summary_cwd: []const u8,
        summary_host_id: ?[]const u8,
        project_key: ?[]const u8,
        current_root: []const u8,
    ) Error!ResumeResolution {
        if (project_key) |key| {
            _ = try session_type.ProjectKey.validate(key);
            // 1. The current root, when this host already binds it.
            const current_key = try paths.cwdKeyForHost(self.gpa, current_root);
            defer self.gpa.free(current_key);
            const bound_sql = "select cwd from project_locations where project_key = ? and host_id = ? and cwd_key = ?";
            var bound = try self.backend.query(self.io, bound_sql, &.{
                .{ .text = key }, .{ .text = self.host_id }, .{ .text = current_key },
            });
            defer bound.deinit();
            if (bound.rows.len > 0) {
                return .{ .ready = .{ .cwd = try gpa.dupe(u8, current_root) } };
            }
            // 2. The newest existing current-host location.
            const list_sql = "select cwd from project_locations where project_key = ? and host_id = ? order by updated_at_ms desc";
            var locations = try self.backend.query(self.io, list_sql, &.{ .{ .text = key }, .{ .text = self.host_id } });
            defer locations.deinit();
            for (locations.rows) |row| {
                const cwd = switch (row[0]) {
                    .text => |t| t,
                    else => continue,
                };
                if (directoryExists(self.io, cwd)) {
                    return .{ .ready = .{ .cwd = try gpa.dupe(u8, cwd) } };
                }
            }
            // 3. Ask the user.
            return .{ .needs_project_root = .{
                .session_id = try gpa.dupe(u8, session_id),
                .project_key = try gpa.dupe(u8, key),
                .origin_cwd = try gpa.dupe(u8, summary_cwd),
                .origin_host_id = if (summary_host_id) |h| try gpa.dupe(u8, h) else null,
            } };
        }

        // Legacy row (project_key null). Same-host + existing cwd: lazily
        // bind and resume there. Foreign/missing: ask — a SQL-only backfill
        // on `default-host` rows could silently merge unrelated projects.
        const same_host = summary_host_id == null or
            std.ascii.eqlIgnoreCase(summary_host_id.?, self.host_id);
        if (same_host and directoryExists(self.io, summary_cwd)) {
            // The verified legacy bind uses the same atomic path as the
            // explicit picker bind, so a roaming write cannot leave a
            // project_locations row without stamping this session.
            const key = try self.bindProjectCwd(self.gpa, session_id, null, summary_cwd);
            self.gpa.free(key);
            return .{ .ready = .{ .cwd = try gpa.dupe(u8, summary_cwd) } };
        }
        return .{ .needs_project_root = .{
            .session_id = try gpa.dupe(u8, session_id),
            .project_key = null,
            .origin_cwd = try gpa.dupe(u8, summary_cwd),
            .origin_host_id = if (summary_host_id) |h| try gpa.dupe(u8, h) else null,
        } };
    }

    /// All sessions of one logical project, newest first — every host, since
    /// the project key is the cross-host identity. Caller owns the slice.
    pub fn listByProject(self: *SessionManager, gpa: std.mem.Allocator, project_key: []const u8) Error![]SessionSummary {
        const sql = "select id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id, model_provider, model_id, reasoning_effort, host_id, project_key from sessions where project_key = ? and leaf_entry_id is not null order by updated_at_ms desc, id desc";
        var qres = try self.backend.query(self.io, sql, &.{.{ .text = project_key }});
        defer qres.deinit();
        var summaries: std.ArrayList(SessionSummary) = .empty;
        errdefer {
            for (summaries.items) |*summary| summary.deinit(gpa);
            summaries.deinit(gpa);
        }
        for (qres.rows) |row| {
            try summaries.append(gpa, try readSummaryFromRow(gpa, row));
        }
        try fillLocalCwds(self, gpa, summaries.items);
        return summaries.toOwnedSlice(gpa);
    }

    /// Newest session of one logical project (startup auto-resume when the
    /// launch root already has a binding). Caller owns the returned id.
    pub fn findLatestByProject(self: *SessionManager, gpa: std.mem.Allocator, project_key: []const u8) Error!?[]u8 {
        const sql = "select id from sessions where project_key = ? and leaf_entry_id is not null order by updated_at_ms desc, id desc limit 1";
        var qres = try self.backend.query(self.io, sql, &.{.{ .text = project_key }});
        defer qres.deinit();
        if (qres.rows.len == 0) return null;
        switch (qres.rows[0][0]) {
            .text => |t| return try gpa.dupe(u8, t),
            else => return null,
        }
    }

    /// Delete a session and its entries (cascade delete handles entries via
    /// the `on delete cascade` foreign key). Safe to call on a non-existent
    /// id — the statement simply matches no rows.
    pub fn deleteSession(self: *SessionManager, session_id: []const u8) Error!void {
        if (self.backend.kind != .local_sqlite) {
            const params = [_]backend_mod.SqlParam{.{ .text = session_id }};
            const statements = [_]db.service.BatchStatement{
                .{ .sql = "delete from prompt_history where session_id = ?", .params = &params },
                .{ .sql = "delete from session_entries where session_id = ?", .params = &params },
                .{ .sql = "delete from sessions where id = ?", .params = &params },
            };
            return self.backend.execBatch(self.io, &statements);
        }
        const sql = "delete from sessions where id = ?";
        try self.backend.exec(self.io, sql, &.{.{ .text = session_id }});
    }

    /// Rename a session by id. The title is overwritten (or set if null).
    /// `new_title` must be non-empty — the caller validates.
    pub fn renameSession(self: *SessionManager, session_id: []const u8, new_title: []const u8) Error!void {
        assert(new_title.len > 0);
        const sql = "update sessions set title = ?, updated_at_ms = ? where id = ?";
        try self.backend.exec(self.io, sql, &.{
            .{ .text = new_title },
            .{ .int = nowMs(self.io) },
            .{ .text = session_id },
        });
    }
};
pub const Session = struct {
    manager: *SessionManager,
    id: SessionId,
    leaf_entry_id: ?EntryId,

    pub fn append(self: *Session, message: ai.ChatMessage, id_out: *[entry_id_len]u8) Error!void {
        fillHex(self.manager.io, id_out);
        const payload = try serialize.messageToJson(self.manager.gpa, message);
        defer self.manager.gpa.free(payload);
        try self.insertEntry(id_out, "message", message.role().label(), payload);
    }

    pub fn appendPayload(self: *Session, kind: []const u8, role: ?[]const u8, payload_json: []const u8, id_out: *[entry_id_len]u8) Error!void {
        assert(kind.len > 0);
        assert(payload_json.len > 0);
        fillHex(self.manager.io, id_out);
        try self.insertEntry(id_out, kind, role, payload_json);
    }

    pub fn appendQueuedPayload(self: *Session, kind: []const u8, role: ?[]const u8, payload_json: []const u8, title: ?[]const u8, id_out: *[entry_id_len]u8) Error!void {
        assert(self.manager.backend.kind != .local_sqlite);
        assert(kind.len > 0);
        assert(payload_json.len > 0);
        fillHex(self.manager.io, id_out);
        const parent: ?[]const u8 = if (self.leaf_entry_id) |*leaf_id| leaf_id.slice() else null;
        try self.insertEntryWithParentAndTitle(id_out, parent, kind, role, payload_json, title);
    }

    pub fn info(self: *Session, title: []const u8, id_out: *[entry_id_len]u8) Error!void {
        assert(title.len > 0);
        fillHex(self.manager.io, id_out);
        const payload = try serialize.titleToJson(self.manager.gpa, title);
        defer self.manager.gpa.free(payload);
        try self.insertEntry(id_out, "session_info", null, payload);

        const sql = "update sessions set title = ?, updated_at_ms = ? where id = ?";
        try self.manager.backend.exec(self.manager.io, sql, &.{
            .{ .text = title },
            .{ .int = nowMs(self.manager.io) },
            .{ .text = self.id.slice() },
        });
    }

    pub fn branch(self: *Session, entry_id: []const u8, branch_summary: ?[]const u8, id_out: ?*[entry_id_len]u8) Error!void {
        assert(entry_id.len > 0);
        if (entry_id.len != entry_id_len) return error.BadEntryId;
        try self.requireEntry(entry_id);
        if (branch_summary) |text| {
            const out = id_out orelse return error.BadEntryId;
            fillHex(self.manager.io, out);
            const payload = try serialize.branchSummaryToJson(self.manager.gpa, entry_id, text);
            defer self.manager.gpa.free(payload);
            try self.insertEntryWithParent(out, entry_id, "branch_summary", null, payload);
        } else {
            var buffer: [entry_id_len]u8 = undefined;
            @memcpy(buffer[0..], entry_id);
            self.leaf_entry_id = .{ .bytes = buffer };
            try self.updateLeaf(entry_id);
        }
    }

    /// Append a compaction boundary as a child of the current leaf. `summary`
    /// (with any handover framing already applied by the caller) stands in for
    /// every entry before `first_kept_id` in the projected context. Validates
    /// that `first_kept_id` exists in this session before writing — the
    /// write-time half of the branch-safety guarantee whose read-time half is
    /// `findCompactionBoundary`.
    pub fn appendCompaction(self: *Session, first_kept_id: []const u8, compaction_summary: []const u8, id_out: *[entry_id_len]u8) Error!void {
        assert(first_kept_id.len == entry_id_len);
        assert(compaction_summary.len > 0);
        try self.requireEntry(first_kept_id);
        fillHex(self.manager.io, id_out);
        const payload = try serialize.compactionToJson(self.manager.gpa, first_kept_id, compaction_summary);
        defer self.manager.gpa.free(payload);
        try self.insertEntry(id_out, "compaction", null, payload);
    }

    // === git-shadow snapshots ==============================================
    //
    // Each entry can carry a git commit id (`snapshot`) binding it to the code
    // state *at* that conversation node. Unlike the old `checkpoint` child
    // entries, the id lives ON the entry, so navigating to a node reads its own
    // (or its nearest ancestor's) snapshot directly — no descendant scan, no
    // off-by-one. Written by the harness after a file-changing step.

    /// Record `sha` (a git commit id) as the code state at `entry_id`.
    pub fn setSnapshot(self: *Session, entry_id: []const u8, sha: []const u8) Error!void {
        assert(entry_id.len == entry_id_len);
        assert(sha.len > 0);
        const sql = "update session_entries set snapshot = ? where session_id = ? and id = ?";
        try self.manager.backend.exec(self.manager.io, sql, &.{
            .{ .text = sha },
            .{ .text = self.id.slice() },
            .{ .text = entry_id },
        });
    }

    /// Save a prompt to the session's prompt history. A plain append: the table
    /// is a per-session log of prompts as typed (no dedup — consecutive
    /// identical prompts each get their own row; only the UI ring dedups).
    pub fn savePromptHistory(self: *Session, prompt: []const u8) Error!void {
        assert(prompt.len > 0);
        const timestamp_ms = nowMs(self.manager.io);
        const sql = "insert into prompt_history(session_id, prompt_text, created_at_ms) values (?, ?, ?)";
        try self.manager.backend.exec(self.manager.io, sql, &.{
            .{ .text = self.id.slice() },
            .{ .text = prompt },
            .{ .int = timestamp_ms },
        });
    }

    /// Load the prompt history for this session, newest first. Ordered by the
    /// monotonic autoincrement `id`, not `created_at_ms`: millisecond ties and
    /// clock skew would leave the order unspecified, and `/undo` relies on
    /// `[0]` agreeing with `deleteNewestPromptHistory`'s victim. Caller owns
    /// the slice and each string.
    pub fn loadPromptHistory(self: *Session, gpa: std.mem.Allocator) Error![][]u8 {
        const sql = "select prompt_text from prompt_history where session_id = ? order by id desc";
        var qres = try self.manager.backend.query(self.manager.io, sql, &.{.{ .text = self.id.slice() }});
        defer qres.deinit();

        var prompts: std.ArrayList([]u8) = .empty;
        errdefer {
            for (prompts.items) |p| gpa.free(p);
            prompts.deinit(gpa);
        }
        for (qres.rows) |row| {
            switch (row[0]) {
                .text => |t| try prompts.append(gpa, try gpa.dupe(u8, t)),
                else => {},
            }
        }
        return prompts.toOwnedSlice(gpa);
    }

    /// Drop the newest prompt-history row. `/undo` calls this after a
    /// successful rewind so the table's `[0]` tracks the newest prompt *on the
    /// active branch* — without it, a chained undo would restore the prompt of
    /// the turn it already discarded. Idempotent by construction: deleting
    /// from an empty table is a no-op.
    pub fn deleteNewestPromptHistory(self: *Session) Error!void {
        const sql = "delete from prompt_history where session_id = ? and id = (select id from prompt_history where session_id = ? order by id desc limit 1)";
        try self.manager.backend.exec(self.manager.io, sql, &.{
            .{ .text = self.id.slice() },
            .{ .text = self.id.slice() },
        });
    }

    /// Update the model provider, ID, and reasoning effort for this session.
    /// `effort_label` is null to clear a stored override (use config/default).
    pub fn updateModel(self: *Session, provider: []const u8, model_id: []const u8, effort_label: ?[]const u8) Error!void {
        assert(self.id.slice().len > 0);
        const sql = "update sessions set model_provider = ?, model_id = ?, reasoning_effort = ?, updated_at_ms = ? where id = ?";
        try self.manager.backend.exec(self.manager.io, sql, &.{
            .{ .text = provider },
            .{ .text = model_id },
            if (effort_label) |label| .{ .text = label } else .null,
            .{ .int = nowMs(self.manager.io) },
            .{ .text = self.id.slice() },
        });
    }

    /// Load the summary for this session. Caller owns the memory.
    pub fn summary(self: *Session, gpa: std.mem.Allocator) Error!SessionSummary {
        const sql = "select id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id, model_provider, model_id, reasoning_effort, host_id, project_key from sessions where id = ?";
        var qres = try self.manager.backend.query(self.manager.io, sql, &.{.{ .text = self.id.slice() }});
        defer qres.deinit();
        if (qres.rows.len == 0) return error.MissingSession;
        var out = try readSummaryFromRow(gpa, qres.rows[0]);
        errdefer out.deinit(gpa);
        // Best-effort current-host mapping for display (resume picker): the
        // project's NEWEST binding on this host — the origin cwd's key is
        // meaningless here, it belongs to whichever machine created the row.
        if (out.project_key) |key| {
            const loc_sql = "select cwd from project_locations where project_key = ? and host_id = ? order by updated_at_ms desc limit 1";
            var loc = self.manager.backend.query(self.manager.io, loc_sql, &.{
                .{ .text = key }, .{ .text = self.manager.host_id },
            }) catch return out;
            defer loc.deinit();
            if (loc.rows.len > 0) {
                switch (loc.rows[0][0]) {
                    .text => |t| out.local_cwd = try gpa.dupe(u8, t),
                    else => {},
                }
            }
        }
        return out;
    }

    /// The git commit id of the nearest entry at or above the current leaf that
    /// carries a snapshot (walking leaf→root) — the code state bound to the
    /// active conversation position. Null when no ancestor has one (a brand-new
    /// session before any file change). Caller owns the returned string.
    pub fn snapshotAt(self: *Session, gpa: std.mem.Allocator) Error!?[]u8 {
        const leaf_id = self.leaf_entry_id orelse return null;
        const sql =
            \\with recursive anc(id, parent_id, snapshot, depth) as (
            \\  select id, parent_id, snapshot, 0 from session_entries
            \\    where session_id = ? and id = ?
            \\  union all
            \\  select e.id, e.parent_id, e.snapshot, anc.depth + 1
            \\    from session_entries e join anc on e.id = anc.parent_id
            \\    where e.session_id = ?
            \\)
            \\select snapshot from anc where snapshot is not null order by depth limit 1
        ;
        var qres = try self.manager.backend.query(self.manager.io, sql, &.{
            .{ .text = self.id.slice() },
            .{ .text = leaf_id.slice() },
            .{ .text = self.id.slice() },
        });
        defer qres.deinit();
        if (qres.rows.len == 0) return null;
        return switch (qres.rows[0][0]) {
            .text => |t| try gpa.dupe(u8, t),
            else => null,
        };
    }

    /// The newest user message entry on the active root→leaf path (walking
    /// leaf→root), or null when the path holds none (a fresh session). `/undo`'s
    /// target selection: everything after this entry is the last turn, so the
    /// undo target is its `parent_id`. The role filter is pure SQL — compaction
    /// boundaries (role null) and legacy non-message kinds are skipped by the
    /// database itself. Allocation-free: ids are fixed-size.
    pub fn lastUserEntry(self: *Session) Error!?UserEntryRef {
        const leaf_id = self.leaf_entry_id orelse return null;
        const sql =
            \\with recursive anc(id, parent_id, kind, role, depth) as (
            \\  select id, parent_id, kind, role, 0 from session_entries
            \\    where session_id = ? and id = ?
            \\  union all
            \\  select e.id, e.parent_id, e.kind, e.role, anc.depth + 1
            \\    from session_entries e join anc on e.id = anc.parent_id
            \\    where e.session_id = ?
            \\)
            \\select id, parent_id from anc
            \\  where kind = 'message' and role = 'user' order by depth limit 1
        ;
        var qres = try self.manager.backend.query(self.manager.io, sql, &.{
            .{ .text = self.id.slice() },
            .{ .text = leaf_id.slice() },
            .{ .text = self.id.slice() },
        });
        defer qres.deinit();
        if (qres.rows.len == 0) return null;
        const row = qres.rows[0];
        const id_str = switch (row[0]) {
            .text => |t| t,
            else => return error.BadEntryId,
        };
        const id = try EntryId.fromSlice(id_str);
        const parent_id: ?EntryId = switch (row[1]) {
            .text => |t| try EntryId.fromSlice(t),
            else => null,
        };
        return .{ .id = id, .parent_id = parent_id };
    }

    /// Project the active branch into the message list the model sees. The
    /// durable tree is the source of truth; this is the derived view. When the
    /// branch carries a compaction boundary, the summarized prefix is replaced
    /// by the summary message and everything from the first kept entry onward
    /// is emitted verbatim (see `findCompactionBoundary`). Without a boundary
    /// the whole branch is emitted, preserving the pre-compaction behavior.
    pub fn messages(self: *Session, gpa: std.mem.Allocator) Error![]ai.ChatMessage {
        const path = try self.loadBranch(gpa);
        defer {
            for (path) |*entry| entry.deinit(gpa);
            gpa.free(path);
        }
        assert(path.len <= path_entries_max);

        const boundary = try findCompactionBoundary(gpa, path);
        const emit_start: u32 = if (boundary) |b| b.first_kept_index else 0;

        var messages_list: std.ArrayList(ai.ChatMessage) = .empty;
        errdefer {
            for (messages_list.items) |*message| deinitMessage(gpa, message);
            messages_list.deinit(gpa);
        }
        if (boundary) |b| {
            try messages_list.append(gpa, try serialize.compactionSummaryToMessage(gpa, path[b.summary_index].payload_json));
        }
        for (path[emit_start..]) |entry| {
            try appendProjectedEntry(gpa, &messages_list, entry);
        }
        return messages_list.toOwnedSlice(gpa);
    }

    /// Compute where to cut the active branch for compaction: the entry that
    /// becomes the first kept message, plus the rendered text of everything
    /// before it (including any prior summary, folded in). Works in tree-space
    /// so the boundary references a real entry id — the cache never needs to
    /// track ids. Returns null when the kept-recent budget already covers the
    /// branch (nothing worth summarizing). Caller owns `prefix_text`.
    pub fn compactionCut(self: *Session, gpa: std.mem.Allocator, keep_recent_tokens: u32) Error!?CompactionCut {
        const path = try self.loadBranch(gpa);
        defer {
            for (path) |*entry| entry.deinit(gpa);
            gpa.free(path);
        }
        assert(path.len <= path_entries_max);

        const boundary = try findCompactionBoundary(gpa, path);
        const emit_start: u32 = if (boundary) |b| b.first_kept_index else 0;

        var msgs: std.ArrayList(ai.ChatMessage) = .empty;
        defer {
            for (msgs.items) |*message| deinitMessage(gpa, message);
            msgs.deinit(gpa);
        }
        var ids: std.ArrayList(EntryId) = .empty;
        defer ids.deinit(gpa);
        for (path[emit_start..]) |entry| {
            if (std.mem.eql(u8, entry.kind, "message")) {
                try msgs.append(gpa, try serialize.jsonToMessage(gpa, entry.payload_json));
                try ids.append(gpa, .{ .bytes = entry.id });
            } else if (std.mem.eql(u8, entry.kind, "branch_summary")) {
                try msgs.append(gpa, try serialize.branchSummaryToMessage(gpa, entry.payload_json));
                try ids.append(gpa, .{ .bytes = entry.id });
            }
        }
        if (msgs.items.len == 0) return null;

        const cut = compaction.findCutIndex(msgs.items, keep_recent_tokens);
        if (cut == 0) return null;
        assert(cut < msgs.items.len);

        const prefix_text = try renderCompactionPrefix(gpa, path, boundary, msgs.items[0..cut]);
        return .{ .first_kept_id = ids.items[cut], .prefix_text = prefix_text };
    }

    pub fn leaf(self: *const Session) ?[]const u8 {
        if (self.leaf_entry_id) |*id| return id.slice();
        return null;
    }

    fn insertEntry(self: *Session, id: *const [entry_id_len]u8, kind: []const u8, role: ?[]const u8, payload_json: []const u8) Error!void {
        const parent: ?[]const u8 = if (self.leaf_entry_id) |*leaf_id| leaf_id.slice() else null;
        try self.insertEntryWithParent(id, parent, kind, role, payload_json);
    }

    fn insertEntryWithParent(self: *Session, id: *const [entry_id_len]u8, parent_id: ?[]const u8, kind: []const u8, role: ?[]const u8, payload_json: []const u8) Error!void {
        try self.insertEntryWithParentAndTitle(id, parent_id, kind, role, payload_json, null);
    }

    fn insertEntryWithParentAndTitle(self: *Session, id: *const [entry_id_len]u8, parent_id: ?[]const u8, kind: []const u8, role: ?[]const u8, payload_json: []const u8, title: ?[]const u8) Error!void {
        assert(kind.len > 0);
        assert(payload_json.len > 0);
        const timestamp_ms = nowMs(self.manager.io);
        const sql = "insert into session_entries(id, session_id, parent_id, kind, role, payload_json, created_at_ms) values (?, ?, ?, ?, ?, ?, ?)";
        const insert_params = [_]backend_mod.SqlParam{
            .{ .text = id[0..] },
            .{ .text = self.id.slice() },
            if (parent_id) |parent| .{ .text = parent } else .null,
            .{ .text = kind },
            if (role) |r| .{ .text = r } else .null,
            .{ .text = payload_json },
            .{ .int = timestamp_ms },
        };
        if (self.manager.backend.kind != .local_sqlite) {
            const update_params = [_]backend_mod.SqlParam{
                .{ .text = id[0..] },
                .{ .int = timestamp_ms },
                .{ .text = self.id.slice() },
            };
            const title_params = [_]backend_mod.SqlParam{
                .{ .text = title orelse "" },
                .{ .int = timestamp_ms },
                .{ .text = self.id.slice() },
            };
            const statements = [_]db.service.BatchStatement{
                .{ .sql = sql, .params = &insert_params },
                .{ .sql = "update sessions set leaf_entry_id = ?, updated_at_ms = ? where id = ?", .params = &update_params },
                .{ .sql = "update sessions set title = ?, updated_at_ms = ? where id = ?", .params = &title_params },
            };
            const count: usize = if (title == null) 2 else 3;
            try self.manager.backend.execBatch(self.manager.io, statements[0..count]);
        } else {
            assert(title == null);
            try self.manager.backend.exec(self.manager.io, sql, &insert_params);
            try self.updateLeaf(id[0..]);
        }
        self.leaf_entry_id = .{ .bytes = id.* };
    }

    pub fn setTitle(self: *Session, title: []const u8) Error!void {
        assert(title.len > 0);
        const sql = "update sessions set title = ?, updated_at_ms = ? where id = ?";
        try self.manager.backend.exec(self.manager.io, sql, &.{
            .{ .text = title },
            .{ .int = nowMs(self.manager.io) },
            .{ .text = self.id.slice() },
        });
    }

    pub fn hasTitle(self: *Session) Error!bool {
        const sql = "select title from sessions where id = ?";
        var qres = try self.manager.backend.query(self.manager.io, sql, &.{.{ .text = self.id.slice() }});
        defer qres.deinit();
        if (qres.rows.len == 0) return error.MissingSession;
        return switch (qres.rows[0][0]) {
            .text => |t| t.len > 0,
            else => false,
        };
    }

    fn updateLeaf(self: *Session, leaf_id: []const u8) Error!void {
        assert(leaf_id.len == entry_id_len);
        const sql = "update sessions set leaf_entry_id = ?, updated_at_ms = ? where id = ?";
        try self.manager.backend.exec(self.manager.io, sql, &.{
            .{ .text = leaf_id },
            .{ .int = nowMs(self.manager.io) },
            .{ .text = self.id.slice() },
        });
    }

    fn requireEntry(self: *Session, entry_id: []const u8) Error!void {
        const sql = "select 1 from session_entries where session_id = ? and id = ?";
        var qres = try self.manager.backend.query(self.manager.io, sql, &.{
            .{ .text = self.id.slice() },
            .{ .text = entry_id },
        });
        defer qres.deinit();
        if (qres.rows.len > 0) return;
        return error.MissingEntry;
    }

    /// Load every entry in the session (the whole tree, not just the active
    /// path). Callers build the parent→children structure themselves. Entries
    /// are returned oldest-first by creation time so siblings keep a stable
    /// order. Caller owns the slice and each record.
    pub fn entries(self: *Session, gpa: std.mem.Allocator) Error![]EntryRecord {
        const sql = "select id, parent_id, kind, role, payload_json, created_at_ms, snapshot from session_entries where session_id = ? order by created_at_ms, rowid";
        var qres = try self.manager.backend.query(self.manager.io, sql, &.{.{ .text = self.id.slice() }});
        defer qres.deinit();

        var records: std.ArrayList(EntryRecord) = .empty;
        errdefer {
            for (records.items) |*record| record.deinit(gpa);
            records.deinit(gpa);
        }
        for (qres.rows) |row| {
            try records.append(gpa, try readEntryFromRow(gpa, row));
        }
        return records.toOwnedSlice(gpa);
    }

    fn loadBranch(self: *Session, gpa: std.mem.Allocator) Error![]EntryRecord {
        const leaf_id = self.leaf_entry_id orelse return try gpa.alloc(EntryRecord, 0);

        const sql =
            \\with recursive branch(session_id, id, parent_id, kind, role, payload_json, created_at_ms, snapshot, rowid) as (
            \\  select session_id, id, parent_id, kind, role, payload_json, created_at_ms, snapshot, rowid
            \\    from session_entries where session_id = ? and id = ?
            \\  union all
            \\  select e.session_id, e.id, e.parent_id, e.kind, e.role, e.payload_json, e.created_at_ms, e.snapshot, e.rowid
            \\    from session_entries e join branch
            \\      on e.session_id = branch.session_id and e.id = branch.parent_id
            \\    where branch.parent_id is not null
            \\)
            \\select id, parent_id, kind, role, payload_json, created_at_ms, snapshot from branch order by created_at_ms, rowid
        ;
        var qres = try self.manager.backend.query(self.manager.io, sql, &.{
            .{ .text = self.id.slice() },
            .{ .text = leaf_id.slice() },
        });
        defer qres.deinit();

        if (qres.rows.len == 0) return error.MissingEntry;

        var records: std.ArrayList(EntryRecord) = .empty;
        errdefer {
            for (records.items) |*record| record.deinit(gpa);
            records.deinit(gpa);
        }
        for (qres.rows) |row| {
            try records.append(gpa, try readEntryFromRow(gpa, row));
        }
        return records.toOwnedSlice(gpa);
    }
};

fn expectDone(statement: *db.Statement) Error!void {
    if (try statement.step()) |_| return error.Sqlite;
}

/// Emit one branch entry into the projected message list, dispatching on its
/// kind. Compaction entries are skipped: they are represented by the summary
/// message emitted in `messages`, not by a message of their own.
fn appendProjectedEntry(gpa: std.mem.Allocator, list: *std.ArrayList(ai.ChatMessage), entry: EntryRecord) Error!void {
    assert(entry.kind.len > 0);
    assert(entry.payload_json.len > 0);
    if (std.mem.eql(u8, entry.kind, "message")) {
        try list.append(gpa, try serialize.jsonToMessage(gpa, entry.payload_json));
        return;
    }
    if (std.mem.eql(u8, entry.kind, "branch_summary")) {
        try list.append(gpa, try serialize.branchSummaryToMessage(gpa, entry.payload_json));
        return;
    }
}

/// Locate the active compaction boundary in a root→leaf `path`: the newest
/// `compaction` entry whose `first_kept_id` still resolves to an entry on the
/// path. Returns null when there is no compaction entry, or when the named
/// boundary is not on this branch (a stale boundary left by a branch switch —
/// ignored so the full history projects instead).
fn findCompactionBoundary(gpa: std.mem.Allocator, path: []const EntryRecord) Error!?CompactionBoundary {
    assert(path.len <= path_entries_max);
    var summary_index: u32 = 0;
    var found = false;
    var scan: u32 = @intCast(path.len);
    while (scan > 0) {
        scan -= 1;
        if (std.mem.eql(u8, path[scan].kind, "compaction")) {
            summary_index = scan;
            found = true;
            break;
        }
    }
    if (!found) return null;

    const first_kept_id = try serialize.compactionFirstKeptId(gpa, path[summary_index].payload_json);
    const first_kept_index = indexOfEntry(path, first_kept_id[0..]) orelse return null;
    if (first_kept_index > summary_index) return null;
    assert(first_kept_index <= summary_index);
    return .{ .summary_index = summary_index, .first_kept_index = first_kept_index };
}

/// Index of the entry whose id equals `id` in `path`, or null if absent.
fn indexOfEntry(path: []const EntryRecord, id: []const u8) ?u32 {
    assert(id.len == entry_id_len);
    assert(path.len <= path_entries_max);
    for (path, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.id[0..], id)) return @intCast(index);
    }
    return null;
}

/// Render the text handed to the summarizer: any prior summary (folded in so
/// repeated compactions stay cumulative) followed by the rendered prefix
/// messages. Caller owns the result.
fn renderCompactionPrefix(gpa: std.mem.Allocator, path: []const EntryRecord, boundary: ?CompactionBoundary, prefix_msgs: []const ai.ChatMessage) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    if (boundary) |b| {
        const prev_summary = try serialize.compactionSummaryText(gpa, path[b.summary_index].payload_json);
        defer gpa.free(prev_summary);
        // Fold in only the inner summary, not the handover template's framing,
        // so repeated compactions don't re-ingest the boilerplate (M7).
        const inner = compaction.stripSummaryFraming(prev_summary);
        try out.writer.print("{s}\n", .{inner});
    }
    const rendered = try compaction.serializePrefix(gpa, prefix_msgs);
    defer gpa.free(rendered);
    try out.writer.writeAll(rendered);
    return out.toOwnedSlice();
}

/// Classify an entry and produce its one-line `/timeline` summary in a single
/// parse. Whitespace is collapsed and the text truncated to one row. Caller
/// owns `text`.
pub fn entrySummary(gpa: std.mem.Allocator, record: EntryRecord) Error!EntrySummary {
    const display_max: u32 = 120;
    if (std.mem.eql(u8, record.kind, "request_usage")) {
        // Informational rows are hidden by the default timeline filter.
        return .{ .session_info = .{ .text = try gpa.dupe(u8, "token usage") } };
    }
    if (std.mem.eql(u8, record.kind, "branch_summary")) {
        return .{ .branch_summary = .{ .text = try gpa.dupe(u8, "branch summary") } };
    }
    if (std.mem.eql(u8, record.kind, "session_info")) {
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, record.payload_json, .{}) catch
            return .{ .session_info = .{ .text = try gpa.dupe(u8, "title") } };
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("title")) |title| {
                if (title == .string) {
                    const collapsed = try collapseWhitespace(gpa, title.string, display_max);
                    defer gpa.free(collapsed);
                    return .{ .session_info = .{ .text = try std.fmt.allocPrint(gpa, "title: {s}", .{collapsed}) } };
                }
            }
        }
        return .{ .session_info = .{ .text = try gpa.dupe(u8, "title") } };
    }
    if (std.mem.eql(u8, record.kind, "checkpoint")) {
        return .{ .checkpoint = .{ .text = try gpa.dupe(u8, "checkpoint") } };
    }
    if (!std.mem.eql(u8, record.kind, "message")) {
        return .{ .other = .{ .text = try gpa.dupe(u8, record.kind) } };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, record.payload_json, .{}) catch
        return .{ .other = .{ .text = try gpa.dupe(u8, "message") } };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .other = .{ .text = try gpa.dupe(u8, "message") } };
    const object = parsed.value.object;

    const role = if (object.get("role")) |value| (if (value == .string) value.string else "") else "";
    if (std.mem.eql(u8, role, "tool")) {
        const tool_failed = if (object.get("tool_failed")) |field| field == .bool and field.bool else false;
        if (object.get("tool_display_label")) |label| {
            if (label == .string and label.string.len > 0) {
                return .{ .tool = .{ .text = try collapseWhitespace(gpa, label.string, display_max), .failed = tool_failed } };
            }
        }
        return .{ .tool = .{ .text = try gpa.dupe(u8, "tool result"), .failed = tool_failed } };
    }

    const is_user = std.mem.eql(u8, role, "user");
    const prefix = if (is_user) "you: " else "agent: ";
    const text = firstTextBlock(object);
    if (text.len == 0) {
        if (is_user) {
            return .{ .user = .{ .text = try gpa.dupe(u8, std.mem.trimEnd(u8, prefix, " :")) } };
        } else {
            return .{ .assistant_empty = .{ .text = try gpa.dupe(u8, std.mem.trimEnd(u8, prefix, " :")) } };
        }
    }
    const collapsed = try collapseWhitespace(gpa, text, display_max);
    defer gpa.free(collapsed);
    const allocated_text = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, collapsed });
    if (is_user) {
        return .{ .user = .{ .text = allocated_text } };
    } else {
        return .{ .assistant = .{ .text = allocated_text } };
    }
}

/// First `text` block of a message's content array, or "" if none.
fn firstTextBlock(object: std.json.ObjectMap) []const u8 {
    const content = object.get("content") orelse return "";
    if (content == .string) return content.string;
    if (content != .array) return "";
    for (content.array.items) |block| {
        if (block != .object) continue;
        const kind = block.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "text")) continue;
        const value = block.object.get("text") orelse continue;
        if (value == .string and value.string.len > 0) return value.string;
    }
    return "";
}

/// Collapse runs of whitespace to single spaces and truncate to `max` columns.
/// Trailing "..." is added when cut and counts toward the `max` budget. Caller
/// owns the result.
fn collapseWhitespace(gpa: std.mem.Allocator, text: []const u8, max: u32) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pending_space = false;
    var started = false;
    // Reserve 3 bytes for the "..." suffix so the total output never exceeds
    // `max`. Without this, a byte that pushes past max is appended first, then
    // "..." adds 3 more bytes — producing max + 3 (or max + 4 with a pending
    // space).
    const cap = max -| 3;
    for (text) |byte| {
        const is_space = byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
        if (is_space) {
            pending_space = started;
            continue;
        }
        if (pending_space) {
            if (out.items.len >= cap) {
                try out.appendSlice(gpa, "...");
                break;
            }
            try out.append(gpa, ' ');
            pending_space = false;
        }
        if (out.items.len >= cap) {
            try out.appendSlice(gpa, "...");
            break;
        }
        try out.append(gpa, byte);
        started = true;
    }
    return out.toOwnedSlice(gpa);
}

fn readSummary(gpa: std.mem.Allocator, row: *const db.Row) Error!SessionSummary {
    var leaf_buffer: [entry_id_len]u8 = undefined;
    return .{
        .id = try gpa.dupe(u8, row.text(0)),
        .title = if (row.columnType(1) == .null) null else try gpa.dupe(u8, row.text(1)),
        .cwd = try gpa.dupe(u8, row.text(2)),
        .created_at_ms = row.int(3),
        .updated_at_ms = row.int(4),
        .leaf_entry_id = if (row.columnType(5) == .null) null else blk: {
            const value = row.text(5);
            // A wrong-length leaf_entry_id is corrupt data (e.g. a test row or a
            // leftover from an older schema). Treat it as null so one bad row
            // doesn't crash the entire resume picker; the session still shows up
            // and a resume attempt fails gracefully via manager.@"resume".
            if (value.len != entry_id_len) break :blk null;
            @memcpy(leaf_buffer[0..], value);
            break :blk EntryId{ .bytes = leaf_buffer };
        },
        .model_provider = if (row.columnType(6) == .null) null else try gpa.dupe(u8, row.text(6)),
        .model_id = if (row.columnType(7) == .null) null else try gpa.dupe(u8, row.text(7)),
        .reasoning_effort = if (row.columnType(8) == .null) null else try gpa.dupe(u8, row.text(8)),
    };
}

fn readEntry(gpa: std.mem.Allocator, row: *const db.Row) Error!EntryRecord {
    var id: [entry_id_len]u8 = undefined;
    const id_text = row.text(0);
    if (id_text.len != entry_id_len) return error.BadEntryId;
    @memcpy(id[0..], id_text);

    var parent_id: ?[entry_id_len]u8 = null;
    if (row.columnType(1) != .null) {
        const parent_text = row.text(1);
        if (parent_text.len != entry_id_len) return error.BadEntryId;
        var parent_buffer: [entry_id_len]u8 = undefined;
        @memcpy(parent_buffer[0..], parent_text);
        parent_id = parent_buffer;
    }

    return .{
        .id = id,
        .parent_id = parent_id,
        .kind = try gpa.dupe(u8, row.text(2)),
        .role = if (row.columnType(3) == .null) null else try gpa.dupe(u8, row.text(3)),
        .payload_json = try gpa.dupe(u8, row.text(4)),
        .created_at_ms = row.int(5),
        .snapshot = if (row.columnType(6) == .null) null else try gpa.dupe(u8, row.text(6)),
    };
}

fn readSummaryFromRow(gpa: std.mem.Allocator, row: []const backend_mod.Value) Error!SessionSummary {
    var leaf_buffer: [entry_id_len]u8 = undefined;
    const id_str = switch (row[0]) {
        .text => |t| t,
        else => return error.CorruptData,
    };
    const title_opt = switch (row[1]) {
        .text => |t| try gpa.dupe(u8, t),
        else => null,
    };
    const cwd_str = switch (row[2]) {
        .text => |t| t,
        else => return error.CorruptData,
    };
    const created_at_ms = switch (row[3]) {
        .int => |v| v,
        else => 0,
    };
    const updated_at_ms = switch (row[4]) {
        .int => |v| v,
        else => 0,
    };
    const leaf_entry_id = switch (row[5]) {
        .text => |t| blk: {
            if (t.len != entry_id_len) break :blk null;
            @memcpy(leaf_buffer[0..], t);
            break :blk EntryId{ .bytes = leaf_buffer };
        },
        else => null,
    };
    const model_provider = switch (row[6]) {
        .text => |t| try gpa.dupe(u8, t),
        else => null,
    };
    const model_id = switch (row[7]) {
        .text => |t| try gpa.dupe(u8, t),
        else => null,
    };
    const reasoning_effort = switch (row[8]) {
        .text => |t| try gpa.dupe(u8, t),
        else => null,
    };
    const host_id = if (row.len > 9) switch (row[9]) {
        .text => |t| try gpa.dupe(u8, t),
        else => null,
    } else null;
    const project_key = if (row.len > 10) switch (row[10]) {
        .text => |t| try gpa.dupe(u8, t),
        else => null,
    } else null;

    return .{
        .id = try gpa.dupe(u8, id_str),
        .title = title_opt,
        .cwd = try gpa.dupe(u8, cwd_str),
        .created_at_ms = created_at_ms,
        .updated_at_ms = updated_at_ms,
        .leaf_entry_id = leaf_entry_id,
        .model_provider = model_provider,
        .model_id = model_id,
        .reasoning_effort = reasoning_effort,
        .host_id = host_id,
        .project_key = project_key,
    };
}

/// Existence check for a directory path (the verified part of a binding:
/// a stale location on this host is skipped during resolution, never
/// executed as a runtime root).
fn directoryExists(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn readEntryFromRow(gpa: std.mem.Allocator, row: []const backend_mod.Value) Error!EntryRecord {
    var id: [entry_id_len]u8 = undefined;
    const id_text = switch (row[0]) {
        .text => |t| t,
        else => return error.BadEntryId,
    };
    if (id_text.len != entry_id_len) return error.BadEntryId;
    @memcpy(id[0..], id_text);

    var parent_id: ?[entry_id_len]u8 = null;
    switch (row[1]) {
        .text => |parent_text| {
            if (parent_text.len != entry_id_len) return error.BadEntryId;
            var parent_buffer: [entry_id_len]u8 = undefined;
            @memcpy(parent_buffer[0..], parent_text);
            parent_id = parent_buffer;
        },
        else => {},
    }

    const kind_text = switch (row[2]) {
        .text => |t| t,
        else => return error.CorruptData,
    };
    const role_opt = switch (row[3]) {
        .text => |t| try gpa.dupe(u8, t),
        else => null,
    };
    const payload_text = switch (row[4]) {
        .text => |t| t,
        else => return error.CorruptData,
    };
    const created_at_ms = switch (row[5]) {
        .int => |v| v,
        else => 0,
    };
    const snapshot_opt = switch (row[6]) {
        .text => |t| try gpa.dupe(u8, t),
        else => null,
    };

    return .{
        .id = id,
        .parent_id = parent_id,
        .kind = try gpa.dupe(u8, kind_text),
        .role = role_opt,
        .payload_json = try gpa.dupe(u8, payload_text),
        .created_at_ms = created_at_ms,
        .snapshot = snapshot_opt,
    };
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.now(.real, io).toMilliseconds();
}

fn fillHex(io: std.Io, buffer: []u8) void {
    assert(buffer.len > 0);
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    const alphabet = "0123456789abcdef";
    for (buffer, 0..) |*byte, index| {
        const value = bytes[index / 2];
        const nibble = if (index % 2 == 0) value >> 4 else value & 0x0f;
        byte.* = alphabet[nibble];
    }
}

fn deinitMessage(gpa: std.mem.Allocator, message: *ai.ChatMessage) void {
    message.deinit(gpa);
}

fn freeToolCalls(gpa: std.mem.Allocator, calls: []const ai.ToolCall) void {
    if (calls.len == 0) return;
    for (calls) |call| {
        var owned = call;
        owned.deinit(gpa);
    }
    gpa.free(calls);
}

test "session persists and loads messages" {
    var manager = try SessionManager.init(std.testing.allocator, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/zay", .{ .id = "0123456789abcdef0123456789abcdef", .title = "Test" });

    var id: [entry_id_len]u8 = undefined;
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "hello") } };
    try session.append(.{ .user = .{ .content = blocks } }, &id);
    for (blocks) |*block| block.deinit(std.testing.allocator);
    std.testing.allocator.free(blocks);
    const messages = try session.messages(std.testing.allocator);
    defer {
        for (messages) |*message| deinitMessage(std.testing.allocator, message);
        std.testing.allocator.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(.user, messages[0].role());
    try std.testing.expectEqualStrings("hello", messages[0].text());
}

test "request usage metadata is durable but never projected into model history" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(test_cwd);
    const session_cwd = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(session_cwd);
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    const session = try manager.create(session_cwd, .{});
    var writer: SessionWriter = .{
        .gpa = gpa,
        .io = std.testing.io,
        .manager = manager,
        .session = session,
        .queue = try gpa.alloc(session_type.QueuedEntry, 4),
    };
    defer writer.deinit();
    writer.session.manager = &writer.manager;
    try writer.recordUsage(.{ .input_tokens = 68000, .output_tokens = 40, .total_tokens = 68040 });
    const entries = try writer.entries(gpa);
    defer {
        for (entries) |*record| record.deinit(gpa);
        gpa.free(entries);
    }
    try std.testing.expectEqualStrings("request_usage", entries[0].kind);
    var summary = try entrySummary(gpa, entries[0]);
    defer summary.deinit(gpa);
    try std.testing.expectEqual(EntryKind.session_info, summary.kind());
    const parsed = try std.json.parseFromSlice(ai.Usage, gpa, entries[0].payload_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 68000), parsed.value.input_tokens);
    const messages = try writer.messages(gpa);
    defer gpa.free(messages);
    try std.testing.expectEqual(@as(usize, 0), messages.len);
}

test "session persists tool display labels and failures" {
    var manager = try SessionManager.init(std.testing.allocator, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/zay", .{ .id = "11111111111111111111111111111111", .title = "Tools" });

    var id: [entry_id_len]u8 = undefined;
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "contents") } };
    const call_id = try std.testing.allocator.dupe(u8, "call_1");
    const label = try std.testing.allocator.dupe(u8, "read AGENTS.md");
    try session.append(.{ .tool = .{ .content = blocks, .call_id = .{ .value = call_id }, .display_label = label, .failed = true } }, &id);
    for (blocks) |*block| block.deinit(std.testing.allocator);
    std.testing.allocator.free(blocks);
    std.testing.allocator.free(call_id);
    std.testing.allocator.free(label);

    const messages = try session.messages(std.testing.allocator);
    defer {
        for (messages) |*message| deinitMessage(std.testing.allocator, message);
        std.testing.allocator.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(.tool, messages[0].role());
    try std.testing.expectEqualStrings("call_1", messages[0].tool.call_id.slice());
    try std.testing.expectEqualStrings("read AGENTS.md", messages[0].tool.display_label.?);
    try std.testing.expect(messages[0].tool.failed);
}

test "session branch with summary changes context" {
    var manager = try SessionManager.init(std.testing.allocator, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/zay", .{ .id = "fedcba9876543210fedcba9876543210" });

    var first: [entry_id_len]u8 = undefined;
    var second: [entry_id_len]u8 = undefined;
    var summary: [entry_id_len]u8 = undefined;
    const root_blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    root_blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "root") } };
    try session.append(.{ .user = .{ .content = root_blocks } }, &first);
    for (root_blocks) |*block| block.deinit(std.testing.allocator);
    std.testing.allocator.free(root_blocks);
    const old_blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    old_blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "old branch") } };
    try session.append(.{ .assistant = .{ .content = old_blocks } }, &second);
    for (old_blocks) |*block| block.deinit(std.testing.allocator);
    std.testing.allocator.free(old_blocks);
    try session.branch(first[0..], "old branch was abandoned", &summary);

    const messages = try session.messages(std.testing.allocator);
    defer {
        for (messages) |*message| deinitMessage(std.testing.allocator, message);
        std.testing.allocator.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("root", messages[0].text());
    try std.testing.expectEqualStrings("Branch summary: old branch was abandoned", messages[1].text());
}

fn appendTextEntry(session: *Session, gpa: std.mem.Allocator, role: ai.Role, text: []const u8, id_out: *[entry_id_len]u8) !void {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    defer {
        for (blocks) |*block| block.deinit(gpa);
        gpa.free(blocks);
    }
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, text) } };
    const message: ai.ChatMessage = switch (role) {
        .system => .{ .system = .{ .content = blocks } },
        .user => .{ .user = .{ .content = blocks } },
        .assistant => .{ .assistant = .{ .content = blocks } },
        .tool => return error.InvalidRole,
    };
    try session.append(message, id_out);
}

test "session branch remains scoped when entry ids collide across sessions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = try SessionManager.init(gpa, io, ":memory:");
    defer manager.deinit();

    var session = try manager.create("/tmp/zay", .{ .id = "0123456789abcdef0123456789abcdef" });
    var root_id: [entry_id_len]u8 = undefined;
    var leaf_id: [entry_id_len]u8 = undefined;
    try appendTextEntry(&session, gpa, .user, "root", &root_id);
    try appendTextEntry(&session, gpa, .assistant, "leaf", &leaf_id);

    var other = try manager.create("/tmp/zay", .{ .id = "fedcba9876543210fedcba9876543210" });
    var other_id: [entry_id_len]u8 = undefined;
    try appendTextEntry(&other, gpa, .user, "foreign", &other_id);
    try manager.backend.exec(io,
        \\insert into session_entries(id, session_id, parent_id, kind, role, payload_json, created_at_ms, snapshot)
        \\select ?, session_id, parent_id, kind, role, payload_json, created_at_ms, snapshot
        \\from session_entries where session_id = ? and id = ?
    , &.{
        .{ .text = root_id[0..] },
        .{ .text = other.id.slice() },
        .{ .text = other_id[0..] },
    });

    const messages = try session.messages(gpa);
    defer {
        for (messages) |*message| deinitMessage(gpa, message);
        gpa.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("root", messages[0].text());
    try std.testing.expectEqualStrings("leaf", messages[1].text());
}

test "session compaction boundary replaces summarized prefix" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/zay", .{ .id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" });

    var id_old_user: [entry_id_len]u8 = undefined;
    var id_old_agent: [entry_id_len]u8 = undefined;
    var id_kept: [entry_id_len]u8 = undefined;
    var id_compaction: [entry_id_len]u8 = undefined;
    try appendTextEntry(&session, gpa, .user, "old one", &id_old_user);
    try appendTextEntry(&session, gpa, .assistant, "old two", &id_old_agent);
    try appendTextEntry(&session, gpa, .user, "keep me", &id_kept);
    try session.appendCompaction(id_kept[0..], "SUMMARY TEXT", &id_compaction);

    const messages = try session.messages(gpa);
    defer {
        for (messages) |*message| deinitMessage(gpa, message);
        gpa.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(.user, messages[0].role());
    try std.testing.expectEqualStrings("SUMMARY TEXT", messages[0].text());
    try std.testing.expectEqualStrings("keep me", messages[1].text());
}

test "session compaction boundary keeps entries appended after it" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/zay", .{ .id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" });

    var id_old: [entry_id_len]u8 = undefined;
    var id_kept: [entry_id_len]u8 = undefined;
    var id_compaction: [entry_id_len]u8 = undefined;
    var id_after: [entry_id_len]u8 = undefined;
    try appendTextEntry(&session, gpa, .user, "old one", &id_old);
    try appendTextEntry(&session, gpa, .user, "keep me", &id_kept);
    try session.appendCompaction(id_kept[0..], "SUMMARY", &id_compaction);
    try appendTextEntry(&session, gpa, .assistant, "after compaction", &id_after);

    const messages = try session.messages(gpa);
    defer {
        for (messages) |*message| deinitMessage(gpa, message);
        gpa.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqualStrings("SUMMARY", messages[0].text());
    try std.testing.expectEqualStrings("keep me", messages[1].text());
    try std.testing.expectEqualStrings("after compaction", messages[2].text());
}

test "compaction cut splits the branch at the keep-recent budget" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/zay", .{ .id = "cccccccccccccccccccccccccccccccc" });

    var id_first: [entry_id_len]u8 = undefined;
    var id_second: [entry_id_len]u8 = undefined;
    var id_third: [entry_id_len]u8 = undefined;
    try appendTextEntry(&session, gpa, .user, "a" ** 40, &id_first);
    try appendTextEntry(&session, gpa, .assistant, "b" ** 40, &id_second);
    try appendTextEntry(&session, gpa, .user, "c" ** 40, &id_third);

    // keep_recent of 15 tokens keeps the last two (~10 tokens each); the cut
    // lands on the second entry and the first is summarized.
    const cut = (try session.compactionCut(gpa, 15)) orelse return error.TestFailed;
    defer gpa.free(cut.prefix_text);
    try std.testing.expectEqualSlices(u8, id_second[0..], cut.first_kept_id.slice());
    try std.testing.expect(std.mem.indexOf(u8, cut.prefix_text, "aaaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut.prefix_text, "bbbb") == null);
}

test "compaction cut returns null when the budget covers the branch" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/zay", .{ .id = "dddddddddddddddddddddddddddddddd" });

    var id_only: [entry_id_len]u8 = undefined;
    try appendTextEntry(&session, gpa, .user, "small", &id_only);
    const result = try session.compactionCut(gpa, 100_000);
    try std.testing.expect(result == null);
}

test "snapshotAt reads the nearest ancestor-or-self snapshot, branch-aware" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/zay", .{ .id = "5" ** session_id_len });

    const sha_a = "a" ** 40;
    const sha_b = "b" ** 40;
    var user_id: [entry_id_len]u8 = undefined;
    var asst_id: [entry_id_len]u8 = undefined;
    var scratch: [entry_id_len]u8 = undefined;

    // No entries yet → no snapshot.
    try std.testing.expect((try session.snapshotAt(gpa)) == null);

    try appendTextEntry(&session, gpa, .user, "first", &user_id);
    try session.setSnapshot(user_id[0..], sha_a);
    try appendTextEntry(&session, gpa, .assistant, "second", &asst_id);

    // a1 carries no snapshot → nearest ancestor (u1) wins.
    {
        const got = (try session.snapshotAt(gpa)) orelse return error.TestFailed;
        defer gpa.free(got);
        try std.testing.expectEqualStrings(sha_a, got);
    }
    // Annotate the assistant entry → self wins.
    try session.setSnapshot(asst_id[0..], sha_b);
    {
        const got = (try session.snapshotAt(gpa)) orelse return error.TestFailed;
        defer gpa.free(got);
        try std.testing.expectEqualStrings(sha_b, got);
    }
    // Fork off u1: the new branch's leaf has no snapshot, so it inherits u1's —
    // never a1's (which is on the other branch). This is the binding that the
    // old descendant-checkpoint model got wrong.
    try session.branch(user_id[0..], null, null);
    try appendTextEntry(&session, gpa, .user, "alt", &scratch);
    {
        const got = (try session.snapshotAt(gpa)) orelse return error.TestFailed;
        defer gpa.free(got);
        try std.testing.expectEqualStrings(sha_a, got);
    }
}

test "lastUserEntry walks the active path to the newest user message" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/zay", .{ .id = "e" ** session_id_len });

    var user1: [entry_id_len]u8 = undefined;
    var asst1: [entry_id_len]u8 = undefined;
    var user2: [entry_id_len]u8 = undefined;
    var asst2: [entry_id_len]u8 = undefined;
    var scratch: [entry_id_len]u8 = undefined;

    // Fresh session: no entries → no user entry.
    try std.testing.expect((try session.lastUserEntry()) == null);

    try appendTextEntry(&session, gpa, .user, "one", &user1);
    try appendTextEntry(&session, gpa, .assistant, "two", &asst1);
    try appendTextEntry(&session, gpa, .user, "three", &user2);
    try appendTextEntry(&session, gpa, .assistant, "four", &asst2);

    // Leaf is a2: the newest user entry on the path is u2, its parent asst1 is
    // exactly the /undo target (the last entry of the previous turn).
    {
        const got = (try session.lastUserEntry()) orelse return error.TestFailed;
        try std.testing.expectEqualSlices(u8, user2[0..], got.id.slice());
        try std.testing.expectEqualSlices(u8, asst1[0..], got.parent_id.?.slice());
    }

    // A compaction boundary appended after the leaf must be skipped by the
    // kind/role filters (compaction rows are kind='compaction', role null).
    try session.appendCompaction(asst2[0..], "SUMMARY", &scratch);
    {
        const got = (try session.lastUserEntry()) orelse return error.TestFailed;
        try std.testing.expectEqualSlices(u8, user2[0..], got.id.slice());
    }

    // Rewind to a1 (the /undo navigation): u2 is off-path, u1 is the newest
    // user entry — and its null parent is the "first prompt" discriminator.
    try session.branch(asst1[0..], null, null);
    {
        const got = (try session.lastUserEntry()) orelse return error.TestFailed;
        try std.testing.expectEqualSlices(u8, user1[0..], got.id.slice());
        try std.testing.expect(got.parent_id == null);
    }
}

test "deleteNewestPromptHistory removes exactly the newest row" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/zay", .{ .id = "f" ** session_id_len });

    try session.savePromptHistory("first");
    try session.savePromptHistory("second");
    try session.savePromptHistory("third");

    {
        const prompts = try session.loadPromptHistory(gpa);
        defer {
            for (prompts) |p| gpa.free(p);
            gpa.free(prompts);
        }
        try std.testing.expectEqual(@as(usize, 3), prompts.len);
        try std.testing.expectEqualStrings("third", prompts[0]);
    }
    try session.deleteNewestPromptHistory();
    {
        const prompts = try session.loadPromptHistory(gpa);
        defer {
            for (prompts) |p| gpa.free(p);
            gpa.free(prompts);
        }
        try std.testing.expectEqual(@as(usize, 2), prompts.len);
        try std.testing.expectEqualStrings("second", prompts[0]);
        try std.testing.expectEqualStrings("first", prompts[1]);
    }

    // Drain to empty, then one more delete: a no-op, not an error.
    try session.deleteNewestPromptHistory();
    try session.deleteNewestPromptHistory();
    try session.deleteNewestPromptHistory();
    {
        const prompts = try session.loadPromptHistory(gpa);
        defer {
            for (prompts) |p| gpa.free(p);
            gpa.free(prompts);
        }
        try std.testing.expectEqual(@as(usize, 0), prompts.len);
    }
}

test "prompt history newest-first order is insertion-stable under millisecond ties" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/zay", .{ .id = "6" ** session_id_len });

    // Two rows sharing created_at_ms: the order must fall back to insertion
    // order (autoincrement id) — the agreement point between
    // loadPromptHistory[0] and deleteNewestPromptHistory's victim.
    {
        var stmt = try manager.connection.prepare(
            "insert into prompt_history(session_id, prompt_text, created_at_ms) values (?, ?, 0)",
        );
        defer stmt.finalize();
        try stmt.bindText(1, session.id.slice());
        try stmt.bindText(2, "older insert");
        try expectDone(&stmt);
    }
    {
        var stmt = try manager.connection.prepare(
            "insert into prompt_history(session_id, prompt_text, created_at_ms) values (?, ?, 0)",
        );
        defer stmt.finalize();
        try stmt.bindText(1, session.id.slice());
        try stmt.bindText(2, "newer insert");
        try expectDone(&stmt);
    }
    const prompts = try session.loadPromptHistory(gpa);
    defer {
        for (prompts) |p| gpa.free(p);
        gpa.free(prompts);
    }
    try std.testing.expectEqual(@as(usize, 2), prompts.len);
    try std.testing.expectEqualStrings("newer insert", prompts[0]);
    try std.testing.expectEqualStrings("older insert", prompts[1]);
}

test "initDefault creates directory and initializes database" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var manager = try SessionManager.initDefault(gpa, std.testing.io, home_dir);
    defer manager.deinit();

    // Verify the file was actually created in the right spot — under the
    // platform config dir (Windows: AppData/Roaming/zay, POSIX: .config/zay),
    // relative to the tmp home_dir. Resolve the expected path against cwd so the
    // access check is absolute and host-separator agnostic (no fragile strip).
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    const abs_home = try std.fs.path.join(gpa, &.{ cwd, home_dir });
    defer gpa.free(abs_home);
    const expected_path = try session_migration.defaultPath(gpa, abs_home);
    defer gpa.free(expected_path);
    try std.Io.Dir.accessAbsolute(std.testing.io, expected_path, .{});

    const sessions = try manager.list(gpa, null);
    defer {
        for (sessions) |*s| s.deinit(gpa);
        gpa.free(sessions);
    }
    try std.testing.expectEqual(@as(usize, 0), sessions.len);
}

test "create rejects session id with wrong length" {
    var manager = try SessionManager.init(std.testing.allocator, std.testing.io, ":memory:");
    defer manager.deinit();
    try std.testing.expectError(error.BadSessionId, manager.create("/tmp/zay", .{ .id = "short" }));
}

test "list treats corrupt leaf_entry_id as null instead of crashing" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();

    // Valid session: create + append an entry so it has a proper 8-char leaf.
    var session = try manager.create("/tmp/zay", .{ .id = "a" ** session_id_len });
    var id: [entry_id_len]u8 = undefined;
    try appendTextEntry(&session, gpa, .user, "hello", &id);

    // Corrupt session: mimic the production write order (insert session with
    // null leaf, insert entry, then update leaf) but end with a wrong-length
    // leaf_entry_id, simulating stale test data or an older-schema leftover.
    // The composite FK on sessions(id, leaf_entry_id) → session_entries(session_id, id)
    // requires the entry row to exist before the update.
    var sess_stmt = try manager.connection.prepare(
        "insert into sessions(id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id) values (?, null, ?, 0, 0, null)",
    );
    defer sess_stmt.finalize();
    try sess_stmt.bindText(1, "b" ** session_id_len);
    try sess_stmt.bindText(2, "/tmp/zay");
    try expectDone(&sess_stmt);

    var entry_stmt = try manager.connection.prepare(
        "insert into session_entries(id, session_id, parent_id, kind, role, payload_json, created_at_ms) values (?, ?, null, 'message', 'user', '{}', 0)",
    );
    defer entry_stmt.finalize();
    try entry_stmt.bindText(1, "entry-123"); // 9 chars, not 8
    try entry_stmt.bindText(2, "b" ** session_id_len);
    try expectDone(&entry_stmt);

    var upd_stmt = try manager.connection.prepare("update sessions set leaf_entry_id = ? where id = ?");
    defer upd_stmt.finalize();
    try upd_stmt.bindText(1, "entry-123");
    try upd_stmt.bindText(2, "b" ** session_id_len);
    try expectDone(&upd_stmt);

    const summaries = try manager.list(gpa, null);
    defer {
        for (summaries) |*s| s.deinit(gpa);
        gpa.free(summaries);
    }
    // Both sessions are returned — the corrupt one must not crash the list.
    try std.testing.expectEqual(@as(usize, 2), summaries.len);
    for (summaries) |s| {
        if (std.mem.eql(u8, s.id, "b" ** session_id_len)) {
            try std.testing.expect(s.leaf_entry_id == null);
        }
    }
}

test "deleteSession removes a session and its entries" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();

    var session = try manager.create("/tmp/zay", .{ .id = "a" ** session_id_len });
    var id: [entry_id_len]u8 = undefined;
    try appendTextEntry(&session, gpa, .user, "hello", &id);

    // The session shows up in list.
    {
        const summaries = try manager.list(gpa, null);
        defer {
            for (summaries) |*s| s.deinit(gpa);
            gpa.free(summaries);
        }
        try std.testing.expectEqual(@as(usize, 1), summaries.len);
    }

    // Delete it.
    try manager.deleteSession("a" ** session_id_len);

    // The list is now empty.
    {
        const summaries = try manager.list(gpa, null);
        defer {
            for (summaries) |*s| s.deinit(gpa);
            gpa.free(summaries);
        }
        try std.testing.expectEqual(@as(usize, 0), summaries.len);
    }
}

test "updateModel persists reasoning effort and summary reads it back" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/zay", .{ .id = "e" ** session_id_len });

    // Direct session-row update (no writer thread in this harness).
    try session.updateModel("ollama", "llama3.1:8b", "high");

    var summary = try session.summary(gpa);
    defer summary.deinit(gpa);
    try std.testing.expectEqualStrings("ollama", summary.model_provider.?);
    try std.testing.expectEqualStrings("llama3.1:8b", summary.model_id.?);
    try std.testing.expectEqualStrings("high", summary.reasoning_effort.?);

    // Clearing the override (null) round-trips back to NULL — resume then
    // falls back to config/default.
    try session.updateModel("ollama", "llama3.1:8b", null);
    var summary2 = try session.summary(gpa);
    defer summary2.deinit(gpa);
    try std.testing.expect(summary2.reasoning_effort == null);
    try std.testing.expectEqualStrings("ollama", summary2.model_provider.?);
}

test "renameSession updates the title" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();

    _ = try manager.create("/tmp/zay", .{ .id = "b" ** session_id_len });

    // No title initially.
    {
        const summaries = try manager.list(gpa, null);
        defer {
            for (summaries) |*s| s.deinit(gpa);
            gpa.free(summaries);
        }
        try std.testing.expectEqual(@as(usize, 0), summaries.len);
    }

    // Rename (set a title). But list filters by leaf_entry_id is not null,
    // so we need an entry. Use a direct insert + update like the corrupt test.
    var sess_stmt = try manager.connection.prepare(
        "insert into sessions(id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id) values (?, null, ?, 0, 0, null)",
    );
    defer sess_stmt.finalize();
    try sess_stmt.bindText(1, "c" ** session_id_len);
    try sess_stmt.bindText(2, "/tmp/zay");
    try expectDone(&sess_stmt);

    var entry_stmt = try manager.connection.prepare(
        "insert into session_entries(id, session_id, parent_id, kind, role, payload_json, created_at_ms) values (?, ?, null, 'message', 'user', '{}', 0)",
    );
    defer entry_stmt.finalize();
    try entry_stmt.bindText(1, "12345678");
    try entry_stmt.bindText(2, "c" ** session_id_len);
    try expectDone(&entry_stmt);

    var upd_stmt = try manager.connection.prepare("update sessions set leaf_entry_id = ? where id = ?");
    defer upd_stmt.finalize();
    try upd_stmt.bindText(1, "12345678");
    try upd_stmt.bindText(2, "c" ** session_id_len);
    try expectDone(&upd_stmt);

    // Rename the session.
    try manager.renameSession("c" ** session_id_len, "My Renamed Session");

    // The list now shows the new title.
    {
        const summaries = try manager.list(gpa, null);
        defer {
            for (summaries) |*s| s.deinit(gpa);
            gpa.free(summaries);
        }
        try std.testing.expectEqual(@as(usize, 1), summaries.len);
        try std.testing.expect(summaries[0].title != null);
        try std.testing.expectEqualStrings("My Renamed Session", summaries[0].title.?);
    }
}

test "setTitle updates session title and persistence state" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();

    var session = try manager.create("/tmp/zay", .{ .id = "d" ** session_id_len });

    // Session has no title initially.
    try std.testing.expect(!try session.hasTitle());

    // Set title for the session.
    try session.setTitle("Initial Session Title");
    try std.testing.expect(try session.hasTitle());

    {
        var summary = try session.summary(gpa);
        defer summary.deinit(gpa);
        try std.testing.expect(summary.title != null);
        try std.testing.expectEqualStrings("Initial Session Title", summary.title.?);
    }

    // Update title again.
    try session.setTitle("Updated Session Title");
    try std.testing.expect(try session.hasTitle());

    {
        var summary = try session.summary(gpa);
        defer summary.deinit(gpa);
        try std.testing.expect(summary.title != null);
        try std.testing.expectEqualStrings("Updated Session Title", summary.title.?);
    }
}

test "hasTitle returns expected boolean based on title existence" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();

    // 1. Session created without a title should return false for hasTitle().
    var untitled_session = try manager.create("/tmp/zay", .{
        .id = "1" ** session_id_len,
        .title = null,
    });
    try std.testing.expect(!try untitled_session.hasTitle());

    // 2. Session created with a title should return true for hasTitle().
    var titled_session = try manager.create("/tmp/zay", .{
        .id = "2" ** session_id_len,
        .title = "Initial Title",
    });
    try std.testing.expect(try titled_session.hasTitle());

    // 3. Updating the title via setTitle() on an untitled session should make hasTitle() return true.
    try untitled_session.setTitle("Updated Title");
    try std.testing.expect(try untitled_session.hasTitle());
}

test "session tracks host_id for roaming users" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.initWithHost(gpa, std.testing.io, ":memory:", "laptop-42");
    defer manager.deinit();

    var session = try manager.create("/tmp/zay", .{
        .id = "h" ** session_id_len,
        .title = "Roaming Session",
    });

    var summary = try session.summary(gpa);
    defer summary.deinit(gpa);
    try std.testing.expect(summary.host_id != null);
    try std.testing.expectEqualStrings("laptop-42", summary.host_id.?);
}

test "initFromConfig gracefully falls back to local storage when external service is offline" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    // Provide an unreachable localhost port where no db server is running
    var manager = try SessionManager.initFromConfig(
        gpa,
        std.testing.io,
        home_dir,
        "http://127.0.0.1:59999",
        null,
        null,
    );
    defer manager.deinit();

    try std.testing.expectEqual(BackendKind.local_sqlite, manager.backend.kind);

    var session = try manager.create("/tmp/zay", .{
        .id = "f" ** session_id_len,
        .title = "Fallback Session",
    });
    var summary = try session.summary(gpa);
    defer summary.deinit(gpa);
    try std.testing.expectEqualStrings("Fallback Session", summary.title.?);
}

test "initFromModularConfig with custom path initializes local sqlite at custom path" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);
    const custom_db = try std.fs.path.join(gpa, &.{ home_dir, "custom_sessions.db" });
    defer gpa.free(custom_db);

    var manager = try SessionManager.initFromModularConfig(
        gpa,
        std.testing.io,
        home_dir,
        .local_sqlite,
        null,
        null,
        custom_db,
        null,
    );
    defer manager.deinit();

    try std.testing.expectEqual(BackendKind.local_sqlite, manager.backend.kind);
    try std.testing.expect(manager.backend.local_path != null);
    try std.testing.expectEqualStrings(custom_db, manager.backend.local_path.?);
}

test "initFromModularConfig with unimplemented backend gracefully falls back to local storage" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    // Pass .turso_http which is stubbed
    var manager = try SessionManager.initFromModularConfig(
        gpa,
        std.testing.io,
        home_dir,
        .turso_http,
        "https://example.turso.io",
        "secret",
        null,
        null,
    );
    defer manager.deinit();

    try std.testing.expectEqual(BackendKind.local_sqlite, manager.backend.kind);
}

// ─────────────────────────────────────────────────────────────────────────
// Project identity & host-local bindings (schema v9).
// ─────────────────────────────────────────────────────────────────────────

test "create reuses the binding for a cwd and mints distinct keys otherwise" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.initWithHost(gpa, std.testing.io, ":memory:", "laptop");
    defer manager.deinit();

    var first = try manager.create("/work/repo", .{ .id = "a" ** session_id_len });
    var second = try manager.create("/work/repo", .{ .id = "b" ** session_id_len });
    var other = try manager.create("/work/other", .{ .id = "c" ** session_id_len });

    var summary_a = try first.summary(gpa);
    defer summary_a.deinit(gpa);
    var summary_b = try second.summary(gpa);
    defer summary_b.deinit(gpa);
    var summary_c = try other.summary(gpa);
    defer summary_c.deinit(gpa);

    try std.testing.expect(summary_a.project_key != null);
    try std.testing.expectEqualStrings(summary_a.project_key.?, summary_b.project_key.?);
    try std.testing.expect(!std.mem.eql(u8, summary_a.project_key.?, summary_c.project_key.?));
    // Keys match the validated opaque shape, never a path.
    _ = try session_type.ProjectKey.validate(summary_a.project_key.?);
    try std.testing.expectError(error.BadProjectKey, session_type.ProjectKey.validate("/work/repo"));
}

test "create accepts separator/trailing-slash spellings of the same directory" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.initWithHost(gpa, std.testing.io, ":memory:", "laptop");
    defer manager.deinit();

    var first = try manager.create("/work/repo", .{ .id = "a" ** session_id_len });
    // Same directory, different spelling: the binding must be reused.
    var second = try manager.create("/work/repo/", .{ .id = "b" ** session_id_len });

    var summary_a = try first.summary(gpa);
    defer summary_a.deinit(gpa);
    var summary_b = try second.summary(gpa);
    defer summary_b.deinit(gpa);
    try std.testing.expectEqualStrings(summary_a.project_key.?, summary_b.project_key.?);

    // The lookup resolves across spellings too.
    const key = (try manager.projectKeyForCwd(gpa, "/work/repo/")).?;
    defer gpa.free(key);
    try std.testing.expectEqualStrings(summary_a.project_key.?, key);
}

test "bindProjectCwd persists a binding and resolveProjectCwd returns the local root" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.Io.Dir.createDirPath(tmp.dir, std.testing.io, "checkout");

    var manager = try SessionManager.initWithHost(gpa, std.testing.io, ":memory:", "laptop");
    defer manager.deinit();

    // Foreign-origin session: created under a path that does not exist here.
    var session = try manager.create("/original/host/path", .{
        .id = "d" ** session_id_len,
        .host_id = "desktop",
    });

    var resolution = try manager.resolveProjectCwd(
        gpa,
        session.id.slice(),
        "/original/host/path",
        "desktop",
        null,
        ".",
    );
    defer resolution.deinit(gpa);
    // Foreign row + missing cwd: an explicit request, never a fallback.
    try std.testing.expect(resolution == .needs_project_root);
    const pending = resolution.needs_project_root;
    try std.testing.expectEqualStrings(session.id.slice(), pending.session_id);
    try std.testing.expect(pending.project_key == null);
    try std.testing.expectEqualStrings("desktop", pending.origin_host_id.?);

    // The user binds a local root: the binding persists and the row is stamped.
    const key = try manager.bindProjectCwd(gpa, session.id.slice(), pending.project_key, "checkout");
    defer gpa.free(key);
    _ = try session_type.ProjectKey.validate(key);

    var stamped = try session.summary(gpa);
    defer stamped.deinit(gpa);
    try std.testing.expectEqualStrings(key, stamped.project_key.?);
    try std.testing.expect(stamped.local_cwd != null);

    // Re-resolution now finds the binding (current root "checkout" is bound).
    {
        var resolved = try manager.resolveProjectCwd(
            gpa,
            session.id.slice(),
            "/original/host/path",
            "desktop",
            key,
            "checkout",
        );
        defer resolved.deinit(gpa);
        try std.testing.expect(resolved == .ready);
        try std.testing.expect(paths.pathsEqual("checkout", resolved.ready.cwd));
    }
}

test "resolveProjectCwd lazily binds a same-host legacy row with an existing cwd" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.Io.Dir.createDirPath(tmp.dir, std.testing.io, "repo");
    const cwd = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    defer gpa.free(cwd);

    var manager = try SessionManager.initWithHost(gpa, std.testing.io, ":memory:", "laptop");
    defer manager.deinit();
    var session = try manager.create(cwd, .{ .id = "e" ** session_id_len });

    // Force the legacy state: project_key null, host recorded.
    try manager.backend.exec(std.testing.io, "update sessions set project_key = null where id = ?", &.{.{ .text = session.id.slice() }});

    var resolution = try manager.resolveProjectCwd(
        gpa,
        session.id.slice(),
        cwd,
        "laptop",
        null,
        ".",
    );
    defer resolution.deinit(gpa);
    try std.testing.expect(resolution == .ready);
    try std.testing.expect(paths.pathsEqual(cwd, resolution.ready.cwd));

    // The lazy bind stamped the row and created the host binding.
    var summary = try session.summary(gpa);
    defer summary.deinit(gpa);
    try std.testing.expect(summary.project_key != null);
    const key_opt = try manager.projectKeyForCwd(gpa, cwd);
    defer if (key_opt) |k| gpa.free(k);
    try std.testing.expect(key_opt != null);
    try std.testing.expectEqualStrings(summary.project_key.?, key_opt.?);
}

test "resolveProjectCwd prefers the current root, then the newest existing location" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Real directories: resolution's existence check is cwd-relative, so the
    // bind paths must exist relative to the process cwd (the tmpDir layout).
    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const dir_a = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path, "checkout-a" });
    defer gpa.free(dir_a);
    const dir_b = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path, "checkout-b" });
    defer gpa.free(dir_b);
    try std.Io.Dir.createDirPath(tmp.dir, std.testing.io, "checkout-a");
    try std.Io.Dir.createDirPath(tmp.dir, std.testing.io, "checkout-b");

    var manager = try SessionManager.initWithHost(gpa, std.testing.io, ":memory:", "laptop");
    defer manager.deinit();
    var session = try manager.create("/elsewhere", .{ .id = "f" ** session_id_len });

    // Two checkouts of one project.
    const key = try manager.bindProjectCwd(gpa, session.id.slice(), null, dir_a);
    defer gpa.free(key);
    const key2 = try manager.bindProjectCwd(gpa, session.id.slice(), key, dir_b);
    defer gpa.free(key2);
    try std.testing.expectEqualStrings(key, key2);
    // Make the tie on updated_at_ms deterministic: checkout-b is newer.
    const b_key = try paths.cwdKeyForHost(gpa, dir_b);
    defer gpa.free(b_key);
    try manager.backend.exec(std.testing.io, "update project_locations set updated_at_ms = 9999999999999 where cwd_key = ?", &.{.{ .text = b_key }});

    // Current root bound → returned as-is.
    {
        var resolution = try manager.resolveProjectCwd(gpa, session.id.slice(), "/elsewhere", "laptop", key, dir_b);
        defer resolution.deinit(gpa);
        try std.testing.expect(resolution == .ready);
        try std.testing.expect(paths.pathsEqual(dir_b, resolution.ready.cwd));
    }
    // Current root unbound but stale-free locations exist → newest wins.
    {
        var resolution = try manager.resolveProjectCwd(gpa, session.id.slice(), "/elsewhere", "laptop", key, "not-a-root");
        defer resolution.deinit(gpa);
        try std.testing.expect(resolution == .ready);
        try std.testing.expect(paths.pathsEqual(dir_b, resolution.ready.cwd));
    }
}

test "resolveProjectCwd skips stale locations and asks for a project root" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.initWithHost(gpa, std.testing.io, ":memory:", "laptop");
    defer manager.deinit();
    var session = try manager.create("/elsewhere", .{ .id = "7" ** session_id_len });

    // The only binding points at a directory that no longer exists here.
    const key = try manager.bindProjectCwd(gpa, session.id.slice(), null, "/gone/checkout");
    defer gpa.free(key);

    var resolution = try manager.resolveProjectCwd(
        gpa,
        session.id.slice(),
        "/elsewhere",
        "laptop",
        key,
        "/also-not-a-root",
    );
    defer resolution.deinit(gpa);
    // A stale mapping is never executed as a runtime root — ask instead.
    try std.testing.expect(resolution == .needs_project_root);
    try std.testing.expectEqualStrings(session.id.slice(), resolution.needs_project_root.session_id);
    try std.testing.expectEqualStrings(key, resolution.needs_project_root.project_key.?);
}

test "projectKeyForCwd is host-scoped: another host sees no binding" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "sessions.db" });
    defer gpa.free(db_path);

    // Host "laptop" creates a session and its local binding.
    {
        var manager = try SessionManager.initWithHost(gpa, std.testing.io, db_path, "laptop");
        defer manager.deinit();
        _ = try manager.create("/work/repo", .{ .id = "9" ** session_id_len });
        const key = try manager.projectKeyForCwd(gpa, "/work/repo");
        defer if (key) |k| gpa.free(k);
        try std.testing.expect(key != null);
    }
    // Host "desktop" opens the SAME store: no binding for it exists — its own
    // cwd mapping must come from its own verified bind (INV-RESUME-CWD).
    {
        var manager = try SessionManager.initWithHost(gpa, std.testing.io, db_path, "desktop");
        defer manager.deinit();
        const key = try manager.projectKeyForCwd(gpa, "/work/repo");
        defer if (key) |k| gpa.free(k);
        try std.testing.expect(key == null);
    }
}

test {
    // Silent-drop guard (AGENTS.md §Test runner quirks): the `lane_manifest`
    // re-export above is never analyzed by itself — root.zig's refAllDecls
    // only reaches one level down — so without this reference the module's
    // inline storage tests silently vanish from `zig build test`.
    _ = lane_manifest;
    _ = @import("session/backend.zig");
}
