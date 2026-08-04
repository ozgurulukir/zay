//! ContextManager — owns the message list the model is prompted with and keeps
//! it in sync with the durable session tree.
//!
//! The session tree (`session.zig`) is the source of truth for a conversation;
//! this in-memory list is its cached projection. A live turn is dual-written:
//! appended to the cached list AND handed to the `SessionWriter` for the tree
//! (`appendPersisted`). Rehydration after a branch switch or resume rebuilds
//! the cached list from the tree projection, appending each already-persisted
//! message with `appendUnpersisted`.
//!
//! System messages are never persisted (the tree reconstructs the system
//! prompt separately, and `SessionWriter.append` skips role `.system`), so
//! `appendPersisted` is safe to call for any role.

const std = @import("std");

const ai = @import("../ai.zig");
const session_mod = @import("../session.zig");

const assert = std.debug.assert;

pub const ContextManager = struct {
    gpa: std.mem.Allocator,
    messages: std.ArrayList(ai.ChatMessage) = .empty,
    session_writer: ?*session_mod.SessionWriter = null,

    pub fn deinit(self: *ContextManager) void {
        for (self.messages.items) |*message| message.deinit(self.gpa);
        self.messages.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn attachSessionWriter(self: *ContextManager, session_writer: *session_mod.SessionWriter) void {
        assert(self.session_writer == null);
        self.session_writer = session_writer;
    }

    /// The cached projection the model is prompted with.
    pub fn items(self: *const ContextManager) []ai.ChatMessage {
        return self.messages.items;
    }

    pub fn count(self: *const ContextManager) u32 {
        return @intCast(self.messages.items.len);
    }

    /// Append to the cached list only — for messages that already live in the
    /// tree (rehydration) or are never persisted (the system prompt during
    /// init). Takes ownership of `message`.
    pub fn appendUnpersisted(self: *ContextManager, message: ai.ChatMessage) !void {
        try self.messages.append(self.gpa, message);
    }

    /// Append to the cached list AND persist to the tree — the dual-write for
    /// a live conversation turn. Takes ownership of `message`.
    ///
    /// Persists FIRST: the tree is the source of truth. On cache-append failure
    /// (OOM) the tree is momentarily ahead — healable via `reloadFromSession` —
    /// whereas the reverse (cache ahead) is undetectable. The writer holds its
    /// own serialized copy (`messageToJson`), so caller cleanup on failure never
    /// dangles the tree.
    pub fn appendPersisted(self: *ContextManager, message: ai.ChatMessage) !void {
        if (self.session_writer) |sw| try sw.append(message);
        try self.messages.append(self.gpa, message);
    }

    /// Drop every non-system message, freeing it; keep the system prompt(s) so
    /// the conversation can be rehydrated from a different branch. Only safe at
    /// a turn boundary, when no stream is active and every message is persisted
    /// — never while a response is streaming into the cached list.
    pub fn clearNonSystem(self: *ContextManager) void {
        var kept: usize = 0;
        for (self.messages.items) |*message| {
            if (message.* == .system) {
                self.messages.items[kept] = message.*;
                kept += 1;
            } else {
                message.deinit(self.gpa);
            }
        }
        self.messages.shrinkRetainingCapacity(kept);
    }
};

test "context manager appends and clears keeping system" {
    const gpa = std.testing.allocator;
    var context: ContextManager = .{ .gpa = gpa };
    defer context.deinit();

    try context.appendUnpersisted(try textMessage(gpa, .system, "system prompt"));
    try context.appendUnpersisted(try textMessage(gpa, .user, "hello"));
    try context.appendUnpersisted(try textMessage(gpa, .assistant, "hi"));
    try std.testing.expectEqual(@as(u32, 3), context.count());

    context.clearNonSystem();
    try std.testing.expectEqual(@as(u32, 1), context.count());
    try std.testing.expectEqual(.system, context.items()[0].role());
}

fn textMessage(gpa: std.mem.Allocator, role: ai.Role, text: []const u8) !ai.ChatMessage {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    errdefer gpa.free(blocks);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, text) } };
    return switch (role) {
        .system => .{ .system = .{ .content = blocks } },
        .user => .{ .user = .{ .content = blocks } },
        .assistant => .{ .assistant = .{ .content = blocks } },
        .tool => error.InvalidToolRole,
    };
}

test "appendPersisted leaves the cache empty when persistence fails" {
    // Persistence (serialization) fails with OOM: the cache must stay empty so
    // the caller's `errdefer message.deinit` frees a message nothing references
    // — no UAF under the testing allocator.
    const gpa = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(gpa, .{});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".config/nova");
    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var writer: session_mod.SessionWriter = undefined;
    try session_mod.SessionWriter.initDefault(&writer, failing.allocator(), std.testing.io, home_dir, "/tmp");
    defer writer.deinit();
    // Fail the first allocation of the append's serialization.
    failing.fail_index = failing.alloc_index;

    var context: ContextManager = .{ .gpa = gpa };
    defer context.deinit();
    context.attachSessionWriter(&writer);

    var message = try textMessage(gpa, .user, "hello");
    defer message.deinit(gpa);
    // The serializer's allocating writer maps OOM to error.WriteFailed.
    try std.testing.expectError(error.WriteFailed, context.appendPersisted(message));
    try std.testing.expectEqual(@as(u32, 0), context.count());
}

test "appendPersisted persists before caching" {
    // The writer's append succeeds (tree gains the entry) even when the cache
    // append fails: the tree is the source of truth and stays ahead, never the
    // cache. The message remains freeable by the caller.
    const gpa = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".config/nova");
    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var writer: session_mod.SessionWriter = undefined;
    try session_mod.SessionWriter.initDefault(&writer, gpa, std.testing.io, home_dir, "/tmp");
    defer writer.deinit();

    var context: ContextManager = .{ .gpa = failing.allocator() };
    defer context.deinit();
    context.attachSessionWriter(&writer);

    var message = try textMessage(gpa, .user, "hello");
    defer message.deinit(gpa);
    try std.testing.expectError(error.OutOfMemory, context.appendPersisted(message));
    try std.testing.expectEqual(@as(u32, 0), context.count());

    // The tree still gained the entry despite the cache append failing.
    const persisted = try writer.messages(gpa);
    defer {
        for (persisted) |*m| m.deinit(gpa);
        gpa.free(persisted);
    }
    try std.testing.expectEqual(@as(usize, 1), persisted.len);
    try std.testing.expectEqual(.user, persisted[0].role());
}
