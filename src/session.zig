const std = @import("std");

const bounded_queue = @import("bounded_queue");
const ai = @import("ai.zig");
const db = @import("db.zig");

const assert = std.debug.assert;

const schema_version: u32 = 1;
pub const entry_id_len: u32 = 8;
const session_id_len: u32 = 32;

pub const EntryId = struct {
    bytes: [entry_id_len]u8,

    pub fn fromSlice(value: []const u8) Error!EntryId {
        if (value.len != entry_id_len) return error.BadEntryId;
        var bytes: [entry_id_len]u8 = undefined;
        @memcpy(bytes[0..], value);
        return .{ .bytes = bytes };
    }

    pub fn slice(self: *const EntryId) []const u8 {
        return self.bytes[0..];
    }
};

pub const SessionId = struct {
    bytes: [session_id_len]u8,

    pub fn fromSlice(value: []const u8) Error!SessionId {
        if (value.len != session_id_len) return error.BadSessionId;
        var bytes: [session_id_len]u8 = undefined;
        @memcpy(bytes[0..], value);
        return .{ .bytes = bytes };
    }

    pub fn slice(self: *const SessionId) []const u8 {
        return self.bytes[0..];
    }
};
const default_db_relative_path = ".nova/sessions.sqlite";
const EntryQueue = bounded_queue.BoundedQueue(QueuedEntry);

pub const Error = db.Error || error{
    BadSessionId,
    BadEntryId,
    MissingSession,
    MissingEntry,
    UnsupportedEntryKind,
    CorruptPayload,
    OutOfMemory,
    WriteFailed,
    SystemResources,
    Unexpected,
    LockedMemoryLimitExceeded,
    ThreadQuotaExceeded,
};

pub const SessionManager = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    connection: db.Connection,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Error!SessionManager {
        assert(path.len > 0);
        var connection = try db.Connection.open(path, .{});
        errdefer connection.close();
        try migrate(&connection, io);
        return .{ .gpa = gpa, .io = io, .connection = connection };
    }

    pub fn initDefault(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) Error!SessionManager {
        assert(cwd.len > 0);
        const db_path = try defaultPath(gpa, io, cwd);
        defer gpa.free(db_path);
        return init(gpa, io, db_path);
    }

    pub fn deinit(self: *SessionManager) void {
        self.connection.close();
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
        var statement = try self.connection.prepare("insert into sessions(id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id) values (?, ?, ?, ?, ?, null)");
        defer statement.finalize();
        try statement.bindText(1, session_id);
        if (options.title) |title| {
            try statement.bindText(2, title);
        } else {
            try statement.bindNull(2);
        }
        try statement.bindText(3, cwd);
        try statement.bindInt(4, timestamp_ms);
        try statement.bindInt(5, timestamp_ms);
        try expectDone(&statement);

        return .{
            .manager = self,
            .id = .{ .bytes = id_buffer },
            .leaf_entry_id = null,
        };
    }

    pub fn @"resume"(self: *SessionManager, session_id: []const u8) Error!Session {
        assert(session_id.len > 0);
        if (session_id.len != session_id_len) return error.BadSessionId;

        var statement = try self.connection.prepare("select leaf_entry_id from sessions where id = ?");
        defer statement.finalize();
        try statement.bindText(1, session_id);
        const row = (try statement.step()) orelse return error.MissingSession;

        const id = try SessionId.fromSlice(session_id);
        var leaf_buffer: [entry_id_len]u8 = undefined;
        const leaf = switch (row.columnType(0)) {
            .null => null,
            .text => blk: {
                const value = row.text(0);
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
            "select id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id from sessions where leaf_entry_id is not null order by updated_at_ms desc"
        else
            "select id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id from sessions where cwd = ? and leaf_entry_id is not null order by updated_at_ms desc";
        var statement = try self.connection.prepare(sql);
        defer statement.finalize();
        if (cwd) |path| try statement.bindText(1, path);

        var summaries: std.ArrayList(SessionSummary) = .empty;
        errdefer {
            for (summaries.items) |*summary| summary.deinit(gpa);
            summaries.deinit(gpa);
        }
        while (try statement.step()) |row| {
            try summaries.append(gpa, try readSummary(gpa, &row));
        }
        return summaries.toOwnedSlice(gpa);
    }
};

pub const CreateOptions = struct {
    id: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

pub const SessionSummary = struct {
    id: []u8,
    title: ?[]u8,
    cwd: []u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    leaf_entry_id: ?[]u8,

    pub fn deinit(self: *SessionSummary, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        if (self.title) |title| gpa.free(title);
        gpa.free(self.cwd);
        if (self.leaf_entry_id) |id| gpa.free(id);
        self.* = undefined;
    }
};

pub const Session = struct {
    manager: *SessionManager,
    id: SessionId,
    leaf_entry_id: ?EntryId,

    pub fn append(self: *Session, message: ai.ChatMessage, id_out: *[entry_id_len]u8) Error!void {
        fillHex(self.manager.io, id_out);
        const payload = try messageToJson(self.manager.gpa, message);
        defer self.manager.gpa.free(payload);
        try self.insertEntry(id_out, "message", message.role.label(), payload);
    }

    pub fn appendPayload(self: *Session, kind: []const u8, role: ?[]const u8, payload_json: []const u8, id_out: *[entry_id_len]u8) Error!void {
        assert(kind.len > 0);
        assert(payload_json.len > 0);
        fillHex(self.manager.io, id_out);
        try self.insertEntry(id_out, kind, role, payload_json);
    }

    pub fn info(self: *Session, title: []const u8, id_out: *[entry_id_len]u8) Error!void {
        assert(title.len > 0);
        fillHex(self.manager.io, id_out);
        const payload = try titleToJson(self.manager.gpa, title);
        defer self.manager.gpa.free(payload);
        try self.insertEntry(id_out, "session_info", null, payload);

        var statement = try self.manager.connection.prepare("update sessions set title = ?, updated_at_ms = ? where id = ?");
        defer statement.finalize();
        try statement.bindText(1, title);
        try statement.bindInt(2, nowMs(self.manager.io));
        try statement.bindText(3, self.id.slice());
        try expectDone(&statement);
    }

    pub fn branch(self: *Session, entry_id: []const u8, summary: ?[]const u8, id_out: ?*[entry_id_len]u8) Error!void {
        assert(entry_id.len > 0);
        if (entry_id.len != entry_id_len) return error.BadEntryId;
        try self.requireEntry(entry_id);
        if (summary) |text| {
            const out = id_out orelse return error.BadEntryId;
            fillHex(self.manager.io, out);
            const payload = try branchSummaryToJson(self.manager.gpa, entry_id, text);
            defer self.manager.gpa.free(payload);
            try self.insertEntryWithParent(out, entry_id, "branch_summary", null, payload);
        } else {
            var buffer: [entry_id_len]u8 = undefined;
            @memcpy(buffer[0..], entry_id);
            self.leaf_entry_id = .{ .bytes = buffer };
            try self.updateLeaf(entry_id);
        }
    }

    pub fn messages(self: *Session, gpa: std.mem.Allocator) Error![]ai.ChatMessage {
        const path = try self.loadBranch(gpa);
        defer {
            for (path) |*entry| entry.deinit(gpa);
            gpa.free(path);
        }

        var messages_list: std.ArrayList(ai.ChatMessage) = .empty;
        errdefer {
            for (messages_list.items) |*message| deinitMessage(gpa, message);
            messages_list.deinit(gpa);
        }
        for (path) |entry| {
            if (std.mem.eql(u8, entry.kind, "message")) {
                try messages_list.append(gpa, try jsonToMessage(gpa, entry.payload_json));
            } else {
                if (std.mem.eql(u8, entry.kind, "branch_summary")) {
                    try messages_list.append(gpa, try branchSummaryToMessage(gpa, entry.payload_json));
                }
            }
        }
        return messages_list.toOwnedSlice(gpa);
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
        assert(kind.len > 0);
        assert(payload_json.len > 0);
        const timestamp_ms = nowMs(self.manager.io);
        var statement = try self.manager.connection.prepare("insert into session_entries(id, session_id, parent_id, kind, role, payload_json, created_at_ms) values (?, ?, ?, ?, ?, ?, ?)");
        defer statement.finalize();
        try statement.bindText(1, id[0..]);
        try statement.bindText(2, self.id.slice());
        if (parent_id) |parent| {
            try statement.bindText(3, parent);
        } else {
            try statement.bindNull(3);
        }
        try statement.bindText(4, kind);
        if (role) |value| {
            try statement.bindText(5, value);
        } else {
            try statement.bindNull(5);
        }
        try statement.bindText(6, payload_json);
        try statement.bindInt(7, timestamp_ms);
        try expectDone(&statement);
        self.leaf_entry_id = .{ .bytes = id.* };
        try self.updateLeaf(id[0..]);
    }

    pub fn setTitle(self: *Session, title: []const u8) Error!void {
        assert(title.len > 0);
        var statement = try self.manager.connection.prepare("update sessions set title = ?, updated_at_ms = ? where id = ?");
        defer statement.finalize();
        try statement.bindText(1, title);
        try statement.bindInt(2, nowMs(self.manager.io));
        try statement.bindText(3, self.id.slice());
        try expectDone(&statement);
    }

    pub fn hasTitle(self: *Session) Error!bool {
        var statement = try self.manager.connection.prepare("select title from sessions where id = ?");
        defer statement.finalize();
        try statement.bindText(1, self.id.slice());
        const row = (try statement.step()) orelse return error.MissingSession;
        return row.columnType(0) != .null and row.text(0).len > 0;
    }

    fn updateLeaf(self: *Session, leaf_id: []const u8) Error!void {
        assert(leaf_id.len == entry_id_len);
        var statement = try self.manager.connection.prepare("update sessions set leaf_entry_id = ?, updated_at_ms = ? where id = ?");
        defer statement.finalize();
        try statement.bindText(1, leaf_id);
        try statement.bindInt(2, nowMs(self.manager.io));
        try statement.bindText(3, self.id.slice());
        try expectDone(&statement);
    }

    fn requireEntry(self: *Session, entry_id: []const u8) Error!void {
        var statement = try self.manager.connection.prepare("select 1 from session_entries where session_id = ? and id = ?");
        defer statement.finalize();
        try statement.bindText(1, self.id.slice());
        try statement.bindText(2, entry_id);
        if (try statement.step()) |_| return;
        return error.MissingEntry;
    }

    /// Load every entry in the session (the whole tree, not just the active
    /// path). Callers build the parent→children structure themselves. Entries
    /// are returned oldest-first by creation time so siblings keep a stable
    /// order. Caller owns the slice and each record.
    pub fn entries(self: *Session, gpa: std.mem.Allocator) Error![]EntryRecord {
        var statement = try self.manager.connection.prepare("select id, parent_id, kind, role, payload_json, created_at_ms from session_entries where session_id = ? order by created_at_ms");
        defer statement.finalize();
        try statement.bindText(1, self.id.slice());

        var records: std.ArrayList(EntryRecord) = .empty;
        errdefer {
            for (records.items) |*record| record.deinit(gpa);
            records.deinit(gpa);
        }
        while (try statement.step()) |row| {
            try records.append(gpa, try readEntry(gpa, &row));
        }
        return records.toOwnedSlice(gpa);
    }

    fn loadBranch(self: *Session, gpa: std.mem.Allocator) Error![]EntryRecord {
        const leaf_id = self.leaf_entry_id orelse return try gpa.alloc(EntryRecord, 0);
        var records: std.ArrayList(EntryRecord) = .empty;
        errdefer {
            for (records.items) |*record| record.deinit(gpa);
            records.deinit(gpa);
        }

        var current = leaf_id;
        while (true) {
            const record = try self.loadEntry(gpa, current.slice());
            const parent = record.parent_id;
            try records.append(gpa, record);
            if (parent) |value| {
                current = .{ .bytes = value };
            } else {
                break;
            }
        }
        std.mem.reverse(EntryRecord, records.items);
        return records.toOwnedSlice(gpa);
    }

    fn loadEntry(self: *Session, gpa: std.mem.Allocator, entry_id: []const u8) Error!EntryRecord {
        var statement = try self.manager.connection.prepare("select id, parent_id, kind, role, payload_json, created_at_ms from session_entries where session_id = ? and id = ?");
        defer statement.finalize();
        try statement.bindText(1, self.id.slice());
        try statement.bindText(2, entry_id);
        const row = (try statement.step()) orelse return error.MissingEntry;
        return readEntry(gpa, &row);
    }
};

pub const SessionWriter = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    manager: SessionManager,
    session: Session,
    mutex: std.atomic.Mutex = .unlocked,
    queue: []QueuedEntry,
    entry_queue: EntryQueue = .{},
    stopping: bool = false,
    title_written: bool = false,
    thread: ?std.Thread = null,

    pub const queue_capacity_default: u32 = 256;

    pub fn initDefault(target: *SessionWriter, gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) Error!void {
        return initDefaultWithCapacity(target, gpa, io, cwd, queue_capacity_default);
    }

    pub fn initResumeDefault(target: *SessionWriter, gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, session_id: []const u8) Error!void {
        return initResumeDefaultWithCapacity(target, gpa, io, cwd, session_id, queue_capacity_default);
    }

    pub fn initDefaultWithCapacity(target: *SessionWriter, gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, capacity: u32) Error!void {
        assert(cwd.len > 0);
        assert(capacity > 0);
        var manager = try SessionManager.initDefault(gpa, io, cwd);
        errdefer manager.deinit();
        const session = try manager.create(cwd, .{});
        try target.initWithSession(gpa, io, manager, session, capacity);
    }

    pub fn initResumeDefaultWithCapacity(target: *SessionWriter, gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, session_id: []const u8, capacity: u32) Error!void {
        assert(cwd.len > 0);
        assert(session_id.len > 0);
        assert(capacity > 0);
        var manager = try SessionManager.initDefault(gpa, io, cwd);
        errdefer manager.deinit();
        const session = try manager.@"resume"(session_id);
        try target.initWithSession(gpa, io, manager, session, capacity);
    }

    fn initWithSession(target: *SessionWriter, gpa: std.mem.Allocator, io: std.Io, manager: SessionManager, session: Session, capacity: u32) Error!void {
        const queue = try gpa.alloc(QueuedEntry, capacity);
        errdefer gpa.free(queue);
        target.* = .{
            .gpa = gpa,
            .io = io,
            .manager = manager,
            .session = session,
            .queue = queue,
        };
        target.session.manager = &target.manager;
        target.title_written = try target.session.hasTitle();
        target.thread = try std.Thread.spawn(.{}, runWriter, .{target});
    }

    pub fn deinit(self: *SessionWriter) void {
        lockWriter(self);
        self.stopping = true;
        self.mutex.unlock();
        if (self.thread) |thread| thread.join();
        while (self.entry_queue.pop(self.queue)) |entry| {
            var owned = entry;
            owned.deinit(self.gpa);
        }
        self.gpa.free(self.queue);
        self.manager.deinit();
        self.* = undefined;
    }

    pub fn append(self: *SessionWriter, message: ai.ChatMessage) Error!void {
        if (message.role == .system) return;
        const payload = try messageToJson(self.gpa, message);
        errdefer self.gpa.free(payload);
        const role = try self.gpa.dupe(u8, message.role.label());
        errdefer self.gpa.free(role);
        const title_candidate = if (message.role == .user)
            try titleFromUserMessage(self.gpa, message.text())
        else
            null;
        errdefer if (title_candidate) |title| self.gpa.free(title);
        try self.enqueue(.{ .kind = "message", .role = role, .payload_json = payload, .title_candidate = title_candidate });
    }

    /// Load the whole session tree, race-free. Stops the background writer so
    /// the read has exclusive access to the connection, then restarts it.
    pub fn entries(self: *SessionWriter, gpa: std.mem.Allocator) Error![]EntryRecord {
        self.quiesce();
        defer self.restart() catch {};
        return self.session.entries(gpa);
    }

    /// Reconstruct the active-path messages (leaf→root), race-free. Used after
    /// `navigate` to rehydrate the agent's conversation from the new branch.
    pub fn messages(self: *SessionWriter, gpa: std.mem.Allocator) Error![]ai.ChatMessage {
        self.quiesce();
        defer self.restart() catch {};
        return self.session.messages(gpa);
    }

    /// Move the session leaf to `entry_id` (branch switch, no summary),
    /// race-free with the background writer. The next appended message becomes
    /// a child of `entry_id`, forming a new branch.
    pub fn navigate(self: *SessionWriter, entry_id: []const u8) Error!void {
        self.quiesce();
        defer self.restart() catch {};
        try self.session.branch(entry_id, null, null);
    }

    pub fn leaf(self: *const SessionWriter) ?[]const u8 {
        return self.session.leaf();
    }

    /// Stop the writer thread and flush any queued entries synchronously,
    /// leaving the calling thread sole owner of the sqlite connection. Pair
    /// with `restart`. Queued entries are written (not dropped) so an
    /// in-flight assistant turn isn't lost.
    fn quiesce(self: *SessionWriter) void {
        lockWriter(self);
        self.stopping = true;
        self.mutex.unlock();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        while (self.entry_queue.pop(self.queue)) |entry| {
            var owned = entry;
            defer owned.deinit(self.gpa);
            writeQueuedEntry(self, &owned) catch {};
        }
    }

    fn restart(self: *SessionWriter) Error!void {
        assert(self.thread == null);
        self.stopping = false;
        self.thread = try std.Thread.spawn(.{}, runWriter, .{self});
    }

    fn enqueue(self: *SessionWriter, entry: QueuedEntry) Error!void {
        while (true) {
            lockWriter(self);
            if (self.entry_queue.push(self.queue, entry)) {
                self.mutex.unlock();
                return;
            }
            self.mutex.unlock();
            std.Thread.yield() catch {};
        }
    }
};

const QueuedEntry = struct {
    kind: []const u8,
    role: ?[]u8,
    payload_json: []u8,
    title_candidate: ?[]u8 = null,

    fn deinit(self: *QueuedEntry, gpa: std.mem.Allocator) void {
        if (self.role) |role| gpa.free(role);
        gpa.free(self.payload_json);
        if (self.title_candidate) |title| gpa.free(title);
        self.* = undefined;
    }
};

fn runWriter(writer: *SessionWriter) void {
    while (true) {
        if (takeQueuedEntry(writer)) |entry| {
            var owned = entry;
            defer owned.deinit(writer.gpa);
            writeQueuedEntry(writer, &owned) catch continue;
        } else {
            lockWriter(writer);
            const done = writer.stopping and writer.entry_queue.empty();
            writer.mutex.unlock();
            if (done) return;
            std.Thread.yield() catch {};
        }
    }
}

fn writeQueuedEntry(writer: *SessionWriter, entry: *const QueuedEntry) Error!void {
    assert(entry.kind.len > 0);
    assert(entry.payload_json.len > 0);

    const previous_leaf = writer.session.leaf_entry_id;
    try writer.manager.connection.exec("begin immediate");
    errdefer {
        writer.manager.connection.exec("rollback") catch {};
        writer.session.leaf_entry_id = previous_leaf;
    }

    var id: [entry_id_len]u8 = undefined;
    try writer.session.appendPayload(entry.kind, entry.role, entry.payload_json, &id);
    const should_write_title = !writer.title_written and entry.title_candidate != null;
    if (should_write_title) try writer.session.setTitle(entry.title_candidate.?);

    try writer.manager.connection.exec("commit");
    if (should_write_title) writer.title_written = true;
}

fn takeQueuedEntry(writer: *SessionWriter) ?QueuedEntry {
    lockWriter(writer);
    defer writer.mutex.unlock();
    return writer.entry_queue.pop(writer.queue);
}

fn lockWriter(writer: *SessionWriter) void {
    while (!writer.mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

pub const EntryRecord = struct {
    id: [entry_id_len]u8,
    parent_id: ?[entry_id_len]u8,
    kind: []u8,
    role: ?[]u8,
    payload_json: []u8,
    created_at_ms: i64,

    pub fn deinit(self: *EntryRecord, gpa: std.mem.Allocator) void {
        gpa.free(self.kind);
        if (self.role) |role| gpa.free(role);
        gpa.free(self.payload_json);
        self.* = undefined;
    }
};

fn migrate(connection: *db.Connection, io: std.Io) Error!void {
    try connection.exec("pragma foreign_keys = on");
    try connection.exec("pragma journal_mode = wal");
    try connection.exec("create table if not exists schema_migrations(version integer primary key, applied_at_ms integer not null)");
    try connection.exec("create table if not exists sessions(id text primary key, title text, cwd text not null, created_at_ms integer not null, updated_at_ms integer not null, leaf_entry_id text, foreign key(id, leaf_entry_id) references session_entries(session_id, id))");
    try connection.exec("create table if not exists session_entries(id text not null, session_id text not null, parent_id text, kind text not null, role text, payload_json text not null, created_at_ms integer not null, primary key(session_id, id), foreign key(session_id) references sessions(id) on delete cascade, foreign key(session_id, parent_id) references session_entries(session_id, id))");
    try connection.exec("create index if not exists session_entries_parent on session_entries(session_id, parent_id)");
    try connection.exec("create index if not exists session_entries_kind on session_entries(session_id, kind)");
    try connection.exec("create index if not exists session_entries_role on session_entries(session_id, role)");
    try connection.exec("create index if not exists sessions_cwd_updated on sessions(cwd, updated_at_ms)");

    var statement = try connection.prepare("insert or ignore into schema_migrations(version, applied_at_ms) values (?, ?)");
    defer statement.finalize();
    try statement.bindInt(1, schema_version);
    try statement.bindInt(2, nowMs(io));
    try expectDone(&statement);
}

fn defaultPath(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) Error![]u8 {
    assert(cwd.len > 0);
    const dir = try std.fs.path.join(gpa, &.{ cwd, ".nova" });
    defer gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch return error.Sqlite;
    return std.fs.path.join(gpa, &.{ cwd, default_db_relative_path });
}

fn expectDone(statement: *db.Statement) Error!void {
    if (try statement.step()) |_| return error.Sqlite;
}

fn messageToJson(gpa: std.mem.Allocator, message: ai.ChatMessage) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(message.role.label(), .{}, writer);
    if (message.call_id) |id| {
        try writer.writeAll(",\"call_id\":");
        try std.json.Stringify.value(id, .{}, writer);
    }
    if (message.tool_display_label) |label| {
        try writer.writeAll(",\"tool_display_label\":");
        try std.json.Stringify.value(label, .{}, writer);
    }
    try writer.writeAll(",\"content\":[");
    for (message.content, 0..) |block, index| {
        if (index > 0) try writer.writeByte(',');
        try block.writeJson(writer);
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn jsonToMessage(gpa: std.mem.Allocator, payload_json: []const u8) Error!ai.ChatMessage {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload_json, .{}) catch return error.CorruptPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CorruptPayload;
    const role_value = parsed.value.object.get("role") orelse return error.CorruptPayload;
    if (role_value != .string) return error.CorruptPayload;
    const role = ai.Role.fromString(role_value.string) catch return error.CorruptPayload;
    const call_id = try optionalString(gpa, parsed.value, "call_id");
    errdefer if (call_id) |id| gpa.free(id);
    const tool_display_label = try optionalString(gpa, parsed.value, "tool_display_label");
    errdefer if (tool_display_label) |label| gpa.free(label);
    const content_value = parsed.value.object.get("content") orelse return error.CorruptPayload;
    const content = try parseContentBlocks(gpa, content_value);
    errdefer freeContentBlocks(gpa, content);
    return .{ .role = role, .content = content, .call_id = call_id, .tool_display_label = tool_display_label };
}

fn branchSummaryToMessage(gpa: std.mem.Allocator, payload_json: []const u8) Error!ai.ChatMessage {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload_json, .{}) catch return error.CorruptPayload;
    defer parsed.deinit();
    const summary = parsed.value.object.get("summary") orelse return error.CorruptPayload;
    if (summary != .string) return error.CorruptPayload;
    const content = try std.fmt.allocPrint(gpa, "Branch summary: {s}", .{summary.string});
    errdefer gpa.free(content);
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = content } };
    return .{ .role = .user, .content = blocks };
}

fn parseContentBlocks(gpa: std.mem.Allocator, value: std.json.Value) Error![]ai.ContentBlock {
    if (value == .string) {
        const blocks = try gpa.alloc(ai.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, value.string) } };
        return blocks;
    }
    if (value != .array) return error.CorruptPayload;
    const blocks = try gpa.alloc(ai.ContentBlock, value.array.items.len);
    var initialized: usize = 0;
    errdefer freeContentBlocks(gpa, blocks[0..initialized]);
    for (value.array.items) |item| {
        blocks[initialized] = try ai.ContentBlock.fromJson(gpa, item);
        initialized += 1;
    }
    return blocks;
}

fn freeContentBlocks(gpa: std.mem.Allocator, blocks: []ai.ContentBlock) void {
    for (blocks) |*block| block.deinit(gpa);
    gpa.free(blocks);
}

fn parseToolCalls(gpa: std.mem.Allocator, value: std.json.Value) Error![]const ai.ToolCall {
    const calls_value = value.object.get("tool_calls") orelse return &.{};
    if (calls_value != .array) return error.CorruptPayload;
    const calls = try gpa.alloc(ai.ToolCall, calls_value.array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (calls[0..initialized]) |*call| call.deinit(gpa);
        gpa.free(calls);
    }
    for (calls_value.array.items) |item| {
        if (item != .object) return error.CorruptPayload;
        const id = item.object.get("id") orelse return error.CorruptPayload;
        const name = item.object.get("name") orelse return error.CorruptPayload;
        const arguments = item.object.get("arguments") orelse return error.CorruptPayload;
        if (id != .string) return error.CorruptPayload;
        if (name != .string) return error.CorruptPayload;
        if (arguments != .string) return error.CorruptPayload;
        calls[initialized] = .{
            .call_id = try gpa.dupe(u8, id.string),
            .name = try gpa.dupe(u8, name.string),
            .arguments = try gpa.dupe(u8, arguments.string),
        };
        initialized += 1;
    }
    return calls;
}

fn optionalString(gpa: std.mem.Allocator, value: std.json.Value, name: []const u8) Error!?[]u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return error.CorruptPayload;
    return try gpa.dupe(u8, field.string);
}

fn titleToJson(gpa: std.mem.Allocator, title: []const u8) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"title\":");
    try std.json.Stringify.value(title, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn branchSummaryToJson(gpa: std.mem.Allocator, from_id: []const u8, summary: []const u8) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"from_id\":");
    try std.json.Stringify.value(from_id, .{}, &out.writer);
    try out.writer.writeAll(",\"summary\":");
    try std.json.Stringify.value(summary, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

/// Classification of a session entry, used by the `/tree` view to drive filter
/// modes and to hide tool-call-only assistant turns by default.
pub const EntryKind = enum {
    user,
    assistant,
    /// Assistant turn that carried only tool calls (no visible text).
    assistant_empty,
    tool,
    branch_summary,
    session_info,
    other,
};

pub const EntrySummary = struct {
    kind: EntryKind,
    /// One-line display text, owned by the caller.
    text: []u8,
};

/// Classify an entry and produce its one-line `/tree` summary in a single
/// parse. Whitespace is collapsed and the text truncated to one row. Caller
/// owns `text`.
pub fn entrySummary(gpa: std.mem.Allocator, record: EntryRecord) Error!EntrySummary {
    const display_max: u32 = 120;
    if (std.mem.eql(u8, record.kind, "branch_summary")) {
        return .{ .kind = .branch_summary, .text = try gpa.dupe(u8, "branch summary") };
    }
    if (std.mem.eql(u8, record.kind, "session_info")) {
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, record.payload_json, .{}) catch
            return .{ .kind = .session_info, .text = try gpa.dupe(u8, "title") };
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("title")) |title| {
                if (title == .string) {
                    const collapsed = try collapseWhitespace(gpa, title.string, display_max);
                    defer gpa.free(collapsed);
                    return .{ .kind = .session_info, .text = try std.fmt.allocPrint(gpa, "title: {s}", .{collapsed}) };
                }
            }
        }
        return .{ .kind = .session_info, .text = try gpa.dupe(u8, "title") };
    }
    if (!std.mem.eql(u8, record.kind, "message")) {
        return .{ .kind = .other, .text = try gpa.dupe(u8, record.kind) };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, record.payload_json, .{}) catch
        return .{ .kind = .other, .text = try gpa.dupe(u8, "message") };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .kind = .other, .text = try gpa.dupe(u8, "message") };
    const object = parsed.value.object;

    const role = if (object.get("role")) |value| (if (value == .string) value.string else "") else "";
    if (std.mem.eql(u8, role, "tool")) {
        if (object.get("tool_display_label")) |label| {
            if (label == .string and label.string.len > 0) {
                return .{ .kind = .tool, .text = try collapseWhitespace(gpa, label.string, display_max) };
            }
        }
        return .{ .kind = .tool, .text = try gpa.dupe(u8, "tool result") };
    }

    const is_user = std.mem.eql(u8, role, "user");
    const prefix = if (is_user) "you: " else "agent: ";
    const text = firstTextBlock(object);
    if (text.len == 0) {
        const kind: EntryKind = if (is_user) .user else .assistant_empty;
        return .{ .kind = kind, .text = try gpa.dupe(u8, std.mem.trimEnd(u8, prefix, " :")) };
    }
    const collapsed = try collapseWhitespace(gpa, text, display_max);
    defer gpa.free(collapsed);
    return .{
        .kind = if (is_user) .user else .assistant,
        .text = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, collapsed }),
    };
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

/// Collapse runs of whitespace to single spaces and truncate to `max` columns
/// (byte-approximate; trailing "..." added when cut). Caller owns the result.
fn collapseWhitespace(gpa: std.mem.Allocator, text: []const u8, max: u32) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pending_space = false;
    var started = false;
    for (text) |byte| {
        const is_space = byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
        if (is_space) {
            pending_space = started;
            continue;
        }
        if (pending_space) {
            try out.append(gpa, ' ');
            pending_space = false;
        }
        try out.append(gpa, byte);
        started = true;
        if (out.items.len >= max) {
            try out.appendSlice(gpa, "...");
            break;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn titleFromUserMessage(gpa: std.mem.Allocator, content: []const u8) Error!?[]u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return null;
    const line_end = std.mem.findScalar(u8, trimmed, '\n') orelse trimmed.len;
    const line = std.mem.trim(u8, trimmed[0..line_end], " \t\r");
    if (line.len == 0) return null;
    const title_max: u32 = 80;
    if (line.len <= title_max) return try gpa.dupe(u8, line);
    const cut = utf8PrefixLen(line, title_max - 3);
    return try std.fmt.allocPrint(gpa, "{s}...", .{line[0..cut]});
}

fn utf8PrefixLen(text: []const u8, limit: u32) u32 {
    assert(limit < text.len);
    var end: u32 = limit;
    while (end > 0) : (end -= 1) {
        if ((text[end] & 0xc0) != 0x80) return end;
    }
    return limit;
}

fn readSummary(gpa: std.mem.Allocator, row: *const db.Row) Error!SessionSummary {
    return .{
        .id = try gpa.dupe(u8, row.text(0)),
        .title = if (row.columnType(1) == .null) null else try gpa.dupe(u8, row.text(1)),
        .cwd = try gpa.dupe(u8, row.text(2)),
        .created_at_ms = row.int(3),
        .updated_at_ms = row.int(4),
        .leaf_entry_id = if (row.columnType(5) == .null) null else try gpa.dupe(u8, row.text(5)),
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
    var session = try manager.create("/tmp/nova", .{ .id = "0123456789abcdef0123456789abcdef", .title = "Test" });

    var id: [entry_id_len]u8 = undefined;
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "hello") } };
    try session.append(.{ .role = .user, .content = blocks }, &id);
    for (blocks) |*block| block.deinit(std.testing.allocator);
    std.testing.allocator.free(blocks);
    const messages = try session.messages(std.testing.allocator);
    defer {
        for (messages) |*message| deinitMessage(std.testing.allocator, message);
        std.testing.allocator.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(.user, messages[0].role);
    try std.testing.expectEqualStrings("hello", messages[0].text());
}

test "session persists tool display labels" {
    var manager = try SessionManager.init(std.testing.allocator, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/nova", .{ .id = "11111111111111111111111111111111", .title = "Tools" });

    var id: [entry_id_len]u8 = undefined;
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "contents") } };
    const call_id = try std.testing.allocator.dupe(u8, "call_1");
    const label = try std.testing.allocator.dupe(u8, "read AGENTS.md");
    try session.append(.{ .role = .tool, .content = blocks, .call_id = call_id, .tool_display_label = label }, &id);
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
    try std.testing.expectEqual(.tool, messages[0].role);
    try std.testing.expectEqualStrings("call_1", messages[0].call_id.?);
    try std.testing.expectEqualStrings("read AGENTS.md", messages[0].tool_display_label.?);
}

test "session branch with summary changes context" {
    var manager = try SessionManager.init(std.testing.allocator, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/nova", .{ .id = "fedcba9876543210fedcba9876543210" });

    var first: [entry_id_len]u8 = undefined;
    var second: [entry_id_len]u8 = undefined;
    var summary: [entry_id_len]u8 = undefined;
    const root_blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    root_blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "root") } };
    try session.append(.{ .role = .user, .content = root_blocks }, &first);
    for (root_blocks) |*block| block.deinit(std.testing.allocator);
    std.testing.allocator.free(root_blocks);
    const old_blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    old_blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "old branch") } };
    try session.append(.{ .role = .assistant, .content = old_blocks }, &second);
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
