//! Background session writer thread.
//!
//! `SessionWriter` owns a dedicated thread that drains a bounded queue of
//! entries and persists them to sqlite, decoupling the hot agent turn path
//! from disk I/O. Extracted from `session.zig` to keep the parent file
//! focused on `SessionManager` and `Session` (the read/append API).

const std = @import("std");
const log = std.log.scoped(.session);

const ai = @import("../ai.zig");

const session_type = @import("types.zig");
const serialize = @import("serialize.zig");
const tool_results = @import("tool_results.zig");
const SkillContext = @import("../context/skill_context.zig").SkillContext;

const entry_id_len = session_type.entry_id_len;
const Error = session_type.Error;
const EntryQueue = session_type.EntryQueue;
const QueuedEntry = session_type.QueuedEntry;
const EntryRecord = session_type.EntryRecord;
const CompactionCut = session_type.CompactionCut;

const assert = std.debug.assert;

const session_mod = @import("../session.zig");
const SessionManager = session_mod.SessionManager;
const Session = session_mod.Session;

pub const SessionWriter = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    manager: SessionManager,
    session: Session,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    queue: []QueuedEntry,
    entry_queue: EntryQueue = .{},
    stopping: bool = false,
    title_written: bool = false,
    thread: ?std.Thread = null,
    write_failure: ?anyerror = null,
    failed_entry: ?QueuedEntry = null,

    pub const queue_capacity_default: u32 = 256;

    pub fn initDefault(target: *SessionWriter, gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, cwd: []const u8) Error!void {
        return initDefaultWithCapacity(target, gpa, io, home_dir, cwd, queue_capacity_default);
    }

    pub fn initResumeDefault(target: *SessionWriter, gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, session_id: []const u8) Error!void {
        return initResumeDefaultWithCapacity(target, gpa, io, home_dir, session_id, queue_capacity_default);
    }

    pub fn initDefaultWithCapacity(target: *SessionWriter, gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, cwd: []const u8, capacity: u32) Error!void {
        assert(home_dir.len > 0);
        assert(cwd.len > 0);
        assert(capacity > 0);
        var manager = try SessionManager.initDefault(gpa, io, home_dir);
        errdefer manager.deinit();
        const session = try manager.create(cwd, .{});
        try target.initWithSession(gpa, io, manager, session, capacity);
    }

    pub fn initResumeDefaultWithCapacity(target: *SessionWriter, gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, session_id: []const u8, capacity: u32) Error!void {
        assert(home_dir.len > 0);
        assert(session_id.len > 0);
        assert(capacity > 0);
        var manager = try SessionManager.initDefault(gpa, io, home_dir);
        errdefer manager.deinit();
        const session = try manager.@"resume"(session_id);
        try target.initWithSession(gpa, io, manager, session, capacity);
    }

    /// Open the session store from an explicit store spec (INV-BACKEND: the
    /// caller's already-resolved backend selection, not a re-read of config)
    /// and create a new session in it. Host identity is explicit — never
    /// resolved from a null env_map at this depth (INV-HOST-ID).
    pub fn initFromStore(
        target: *SessionWriter,
        gpa: std.mem.Allocator,
        io: std.Io,
        home_dir: []const u8,
        cwd: []const u8,
        store: session_mod.SessionStore,
        host_id: []const u8,
    ) Error!void {
        assert(home_dir.len > 0);
        assert(cwd.len > 0);
        assert(host_id.len > 0);
        var manager = try SessionManager.initStore(gpa, io, home_dir, store, host_id, true);
        errdefer manager.deinit();
        const session = try manager.create(cwd, .{});
        try target.initWithSession(gpa, io, manager, session, queue_capacity_default);
    }

    /// Resume through an explicit store spec. A configured remote store that
    /// cannot be reached FAILS here — the session id is never attempted
    /// against a fallback local database, which would surface a misleading
    /// `MissingSession` (INV-BACKEND).
    pub fn initResumeFromStore(
        target: *SessionWriter,
        gpa: std.mem.Allocator,
        io: std.Io,
        home_dir: []const u8,
        session_id: []const u8,
        store: session_mod.SessionStore,
        host_id: []const u8,
    ) Error!void {
        assert(home_dir.len > 0);
        assert(session_id.len > 0);
        assert(host_id.len > 0);
        var manager = try SessionManager.initStore(gpa, io, home_dir, store, host_id, false);
        errdefer manager.deinit();
        const session = try manager.@"resume"(session_id);
        try target.initWithSession(gpa, io, manager, session, queue_capacity_default);
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
        tool_results.maintain(&target.manager.backend, io, tool_results.nowMs(io)) catch |err| {
            log.warn("tool result maintenance failed err={s}", .{@errorName(err)});
        };
        target.thread = try std.Thread.spawn(.{}, runWriter, .{target});
    }

    pub fn deinit(self: *SessionWriter) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        if (self.write_failure) |failure| {
            const unwritten_count = self.entry_queue.len() + @as(u32, @intFromBool(self.failed_entry != null));
            log.warn("session writer stopped with {d} unpersisted entries: {s}", .{ unwritten_count, @errorName(failure) });
        }
        if (self.failed_entry) |*entry| {
            entry.deinit(self.gpa);
        }
        while (self.entry_queue.pop(self.queue)) |entry| {
            var owned = entry;
            owned.deinit(self.gpa);
        }
        self.gpa.free(self.queue);
        self.manager.deinit();
        self.* = undefined;
    }

    pub fn append(self: *SessionWriter, message: ai.ChatMessage) Error!void {
        if (message.role() == .system) return;
        const payload = try serialize.messageToJson(self.gpa, message);
        errdefer self.gpa.free(payload);
        const role = try self.gpa.dupe(u8, message.role().label());
        errdefer self.gpa.free(role);
        const title_candidate = if (message.role() == .user)
            try serialize.titleFromUserMessage(self.gpa, message.text())
        else
            null;
        errdefer if (title_candidate) |title| self.gpa.free(title);
        try self.enqueue(.{ .kind = "message", .role = role, .payload_json = payload, .title_candidate = title_candidate });
    }

    /// Usage is session metadata, never a message projected into a prompt.
    pub fn recordUsage(self: *SessionWriter, usage: ai.Usage) Error!void {
        const payload = try std.json.Stringify.valueAlloc(self.gpa, usage, .{});
        errdefer self.gpa.free(payload);
        try self.enqueue(.{ .kind = "request_usage", .role = null, .payload_json = payload });
    }

    /// Enqueue a compaction boundary for the background writer. Mirrors
    /// `append`: builds the payload and hands it to the writer thread. The
    /// branch on which it lands is whatever leaf is current when the writer
    /// drains it; a stale boundary is ignored at projection time, so no
    /// quiesce is needed here.
    pub fn appendCompaction(self: *SessionWriter, first_kept_id: []const u8, summary: []const u8) Error!void {
        assert(first_kept_id.len == entry_id_len);
        assert(summary.len > 0);
        const payload = try serialize.compactionToJson(self.gpa, first_kept_id, summary);
        errdefer self.gpa.free(payload);
        try self.enqueue(.{ .kind = "compaction", .role = null, .payload_json = payload });
    }

    pub fn appendSkillContext(self: *SessionWriter, context: *const SkillContext) Error!void {
        const payload = try context.toJson(self.gpa);
        errdefer self.gpa.free(payload);
        try self.enqueue(.{ .kind = "skill_context", .role = null, .payload_json = payload });
    }

    /// Persist a large tool result while this writer exclusively owns the
    /// session backend connection.
    pub fn storeToolResult(
        self: *SessionWriter,
        result_id: []const u8,
        tool_name: []const u8,
        exit_code: u8,
        content: []const u8,
        inline_limit: usize,
    ) !tool_results.Metadata {
        try self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        return tool_results.storeWithLimit(
            self.gpa,
            self.io,
            &self.manager.backend,
            self.session.id.slice(),
            result_id,
            tool_name,
            exit_code,
            content,
            inline_limit,
        );
    }

    /// Bind a git snapshot id to the current leaf entry, race-free. Flushes
    /// queued writes first so the leaf reflects the entries the turn just wrote,
    /// then annotates that entry. No-op if the session has no leaf yet.
    pub fn setLeafSnapshot(self: *SessionWriter, sha: []const u8) Error!void {
        try self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        const leaf_id = self.session.leaf() orelse return;
        return self.session.setSnapshot(leaf_id, sha);
    }

    /// Race-free `Session.snapshotAt`: the git snapshot bound to the active
    /// conversation position (nearest entry at/above the leaf). Caller owns it.
    pub fn snapshotAt(self: *SessionWriter, gpa: std.mem.Allocator) Error!?[]u8 {
        try self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        return self.session.snapshotAt(gpa);
    }

    /// Save a prompt to the session's prompt history, race-free. A plain
    /// append — no dedup (the table is a per-session log; only the UI ring
    /// dedups).
    pub fn savePromptHistory(self: *SessionWriter, prompt: []const u8) Error!void {
        try self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        try self.session.savePromptHistory(prompt);
    }

    /// Load the prompt history for this session, race-free. Caller owns the
    /// slice and each string.
    pub fn loadPromptHistory(self: *SessionWriter, gpa: std.mem.Allocator) Error![][]u8 {
        try self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        return self.session.loadPromptHistory(gpa);
    }

    /// Drop the newest prompt-history row, race-free. `/undo`'s second half:
    /// keeps `[0]` tracking the active branch across chained undos. Idempotent.
    pub fn deleteNewestPromptHistory(self: *SessionWriter) Error!void {
        try self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        try self.session.deleteNewestPromptHistory();
    }

    /// Race-free `Session.lastUserEntry`: the newest user message entry on the
    /// active path, or null when the session holds none. Allocation-free.
    pub fn lastUserEntry(self: *SessionWriter) Error!?session_type.UserEntryRef {
        try self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        return self.session.lastUserEntry();
    }

    /// Load the whole session tree, race-free. Stops the background writer so
    /// the read has exclusive access to the connection, then restarts it.
    pub fn entries(self: *SessionWriter, gpa: std.mem.Allocator) Error![]EntryRecord {
        try self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        return self.session.entries(gpa);
    }

    /// Reconstruct the active-path messages (leaf→root), race-free. Used after
    /// `navigate` to rehydrate the agent's conversation from the new branch.
    pub fn messages(self: *SessionWriter, gpa: std.mem.Allocator) Error![]ai.ChatMessage {
        try self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        return self.session.messages(gpa);
    }

    pub const Conversation = struct {
        messages: []ai.ChatMessage,
        skill_context: SkillContext,

        pub fn deinit(self: *Conversation, gpa: std.mem.Allocator) void {
            for (self.messages) |*message| message.deinit(gpa);
            gpa.free(self.messages);
            self.skill_context.deinit(gpa);
            self.* = undefined;
        }
    };

    /// Keep the writer stopped until both projections have been constructed.
    /// Callers own the result and swap it only after all fallible work succeeds.
    pub fn conversation(self: *SessionWriter, gpa: std.mem.Allocator) Error!Conversation {
        try self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        const projected = try self.session.messages(gpa);
        errdefer {
            for (projected) |*message| message.deinit(gpa);
            gpa.free(projected);
        }
        return .{ .messages = projected, .skill_context = try self.session.skillContext(gpa) };
    }

    /// Race-free `Session.compactionCut`: flushes queued writes so the cut is
    /// computed against the persisted tree, then restarts the writer.
    pub fn compactionCut(self: *SessionWriter, gpa: std.mem.Allocator, keep_recent_tokens: u32) Error!?CompactionCut {
        try self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        return self.session.compactionCut(gpa, keep_recent_tokens);
    }

    /// Move the session leaf to `entry_id` (branch switch, no summary),
    /// race-free with the background writer. The next appended message becomes
    /// a child of `entry_id`, forming a new branch.
    pub fn navigate(self: *SessionWriter, entry_id: []const u8) Error!void {
        try self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        try self.session.branch(entry_id, null, null);
    }

    /// Update the model provider, ID, and reasoning effort for the current
    /// session. Called when the model selection changes during a session.
    pub fn updateModel(self: *SessionWriter, provider: []const u8, model_id: []const u8, effort_label: ?[]const u8) Error!void {
        try self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        try self.session.updateModel(provider, model_id, effort_label);
    }

    pub fn leaf(self: *const SessionWriter) ?[]const u8 {
        return self.session.leaf();
    }

    /// Stop the writer thread and flush any queued entries synchronously,
    /// leaving the calling thread sole owner of the sqlite connection. Pair
    /// with `restart`. Queued entries are written (not dropped) so an
    /// in-flight assistant turn isn't lost.
    fn quiesce(self: *SessionWriter) Error!void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.write_failure) |failure| return failure;
        while (self.entry_queue.pop(self.queue)) |entry| {
            var owned = entry;
            writeQueuedEntry(self, &owned) catch |err| {
                self.recordFailure(owned, err);
                return err;
            };
            owned.deinit(self.gpa);
        }
    }

    /// An uncertain HTTP commit must not be blindly retried or overtaken by
    /// later entries. Keep the failed payload and make every caller observe
    /// the failure before it can replace history from the durable tree.
    fn recordFailure(self: *SessionWriter, entry: QueuedEntry, failure: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        assert(self.failed_entry == null);
        self.failed_entry = entry;
        self.write_failure = failure;
        self.mutex.unlock(self.io);
        log.warn("session writer failed; further writes suspended: {s}", .{@errorName(failure)});
    }

    fn restart(self: *SessionWriter) Error!void {
        assert(self.thread == null);
        if (self.write_failure) |failure| return failure;
        self.stopping = false;
        self.thread = std.Thread.spawn(.{}, runWriter, .{self}) catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.write_failure = err;
            self.mutex.unlock(self.io);
            return err;
        };
    }

    fn enqueue(self: *SessionWriter, entry: QueuedEntry) Error!void {
        try self.mutex.lock(self.io);
        if (self.write_failure) |failure| {
            self.mutex.unlock(self.io);
            return failure;
        }
        if (!self.entry_queue.push(self.queue, entry)) {
            self.mutex.unlock(self.io);
            return error.QueueFull;
        }
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
    }
};

fn runWriter(writer: *SessionWriter) void {
    while (true) {
        if (takeQueuedEntry(writer)) |entry| {
            var owned = entry;
            writeQueuedEntry(writer, &owned) catch |err| {
                writer.recordFailure(owned, err);
                return;
            };
            owned.deinit(writer.gpa);
        } else {
            // Queue is empty: wait for a signal rather than busy-yielding.
            // We hold the lock around the check+wait so we can't miss a
            // signal that lands between the check and the wait.
            writer.mutex.lockUncancelable(writer.io);
            while (writer.entry_queue.empty() and !writer.stopping) {
                writer.condition.waitUncancelable(writer.io, &writer.mutex);
            }
            const done = writer.stopping and writer.entry_queue.empty();
            writer.mutex.unlock(writer.io);
            if (done) return;
        }
    }
}

fn writeQueuedEntry(writer: *SessionWriter, entry: *const QueuedEntry) Error!void {
    assert(entry.kind.len > 0);
    assert(entry.payload_json.len > 0);

    const should_write_title = !writer.title_written and entry.title_candidate != null;
    if (writer.manager.backend.kind != .local_sqlite) {
        var id: [entry_id_len]u8 = undefined;
        const title = if (should_write_title) entry.title_candidate else null;
        try writer.session.appendQueuedPayload(entry.kind, entry.role, entry.payload_json, title, &id);
        if (should_write_title) writer.title_written = true;
        return;
    }

    const previous_leaf = writer.session.leaf_entry_id;
    try writer.manager.backend.beginTransaction(writer.io);
    errdefer {
        writer.manager.backend.rollbackTransaction(writer.io) catch {};
        writer.session.leaf_entry_id = previous_leaf;
    }

    var id: [entry_id_len]u8 = undefined;
    try writer.session.appendPayload(entry.kind, entry.role, entry.payload_json, &id);
    if (should_write_title) try writer.session.setTitle(entry.title_candidate.?);

    try writer.manager.backend.commitTransaction(writer.io);
    if (should_write_title) writer.title_written = true;
}

fn takeQueuedEntry(writer: *SessionWriter) ?QueuedEntry {
    writer.mutex.lockUncancelable(writer.io);
    defer writer.mutex.unlock(writer.io);
    return writer.entry_queue.pop(writer.queue);
}

test "session writer skill context projection and failed admission preserve state" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    const session = try manager.create("/tmp/zay", .{});
    var writer: SessionWriter = .{
        .gpa = gpa,
        .io = std.testing.io,
        .manager = manager,
        .session = session,
        .queue = try gpa.alloc(QueuedEntry, 4),
    };
    writer.session.manager = &writer.manager;
    defer writer.deinit();
    var ledger: SkillContext = .{};
    defer ledger.deinit(gpa);
    _ = try ledger.activate(gpa, "how", "durable instructions");
    try writer.appendSkillContext(&ledger);
    var projected = try writer.conversation(gpa);
    defer projected.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), projected.messages.len);
    try std.testing.expectEqualStrings("durable instructions", projected.skill_context.body("how").?);
    try writer.quiesce();
    writer.write_failure = error.Sqlite;
    const leaf_before = writer.session.leaf_entry_id;
    try std.testing.expectError(error.Sqlite, writer.appendSkillContext(&ledger));
    try std.testing.expectError(error.Sqlite, writer.conversation(gpa));
    try std.testing.expectEqual(leaf_before, writer.session.leaf_entry_id);
    try std.testing.expectEqual(@as(u32, 0), writer.entry_queue.len());
    writer.write_failure = null;
}

test "session writer failure preserves ordering and refuses incomplete reprojection" {
    for ([_]session_mod.BackendKind{ .local_sqlite, .remote_service, .turso_http, .d1_http }) |kind| {
        try testWriteFailure(kind);
    }
}

fn testWriteFailure(kind: session_mod.BackendKind) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(test_cwd);
    const session_cwd = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(session_cwd);
    var manager = try SessionManager.init(gpa, io, ":memory:");
    const session = try manager.create(session_cwd, .{});
    var writer: SessionWriter = .{
        .gpa = gpa,
        .io = io,
        .manager = manager,
        .session = session,
        .queue = try gpa.alloc(QueuedEntry, 4),
    };
    writer.session.manager = &writer.manager;
    defer writer.deinit();
    // A failed batch must stop the common writer for every HTTP backend.
    // Missing clients make the failure deterministic without real sockets.
    const original_kind = writer.manager.backend.kind;
    defer writer.manager.backend.kind = original_kind;
    writer.manager.backend.kind = kind;
    const expected_failure = if (kind == .local_sqlite) error.Sqlite else error.MissingConnection;
    if (kind == .local_sqlite) try writer.manager.backend.exec(io, "pragma query_only = on", &.{});
    try writer.recordUsage(.{ .input_tokens = 68000, .output_tokens = 40, .total_tokens = 68040 });
    try writer.recordUsage(.{ .input_tokens = 68001, .output_tokens = 40, .total_tokens = 68041 });
    runWriter(&writer);
    try std.testing.expectEqual(expected_failure, writer.write_failure.?);
    try std.testing.expect(writer.failed_entry != null);
    try std.testing.expectEqual(@as(u32, 1), writer.entry_queue.len());
    try std.testing.expectError(expected_failure, writer.messages(gpa));
    try std.testing.expectError(expected_failure, writer.recordUsage(.{
        .input_tokens = 1,
        .output_tokens = 1,
        .total_tokens = 2,
    }));
    try std.testing.expectEqual(@as(u32, 1), writer.entry_queue.len());
}
