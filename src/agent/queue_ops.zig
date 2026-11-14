//! Agent-bound queue operations: enqueue, drain, steer and clear paths over the
//! `message_queue` fields Agent owns. The data structure lives in
//! `agent/queue.zig` (`QueuedUserMessage` + `MessageQueue`); this module holds
//! the operations.
//!
//! Ownership: imports agent.zig only for the `Agent` type — the queue fields
//! stay on the owner struct, and the one dependency out of the seam
//! (`drainQueuedUserMessage` → `addUser`/`addUserPrompt`, the message-append +
//! skill-prefixing concern that remains on Agent) is a type-level call, the
//! same shape as `tool_batch.runToolBatch` → `takeToolResults` (#367 slice 7).
//! The deinit queue-drain block stays on Agent: it differs subtly from
//! `clearQueue` on lock failure (deinit skips the section and continues
//! cleanup; `clearQueue` no-ops) and sits outside this seam.
//!
//! Invariants carried by this module (do not split across modules): the
//! lock-failure-tolerant no-op paths (`hasQueuedMessages` → false,
//! `clearQueue`/`setQueuedSteer` → no-op, `takeQueuedUserMessage` → null;
//! documented contextually in agent.zig and the concurrency test below), the
//! FIFO-steer drain contract, the atomic `enqueueSteer` push+mark under one
//! lock, and the `raw` bypass of `@`-mention expansion / skill prefixing.

const std = @import("std");
const agent_mod = @import("../agent.zig");
const agent_queue = @import("queue.zig");

const Agent = agent_mod.Agent;
const QueuedUserMessage = agent_queue.QueuedUserMessage;
const assert = std.debug.assert;

pub fn enqueueUser(self: *Agent, content: []const u8) !void {
    assert(content.len > 0);
    const owned = try self.gpa.dupe(u8, content);
    errdefer self.gpa.free(owned);
    try self.message_queue_mutex.lock(self.io);
    defer self.message_queue_mutex.unlock(self.io);
    if (!self.message_queue.push(&self.message_queue_storage, .{ .prompt = owned })) return error.QueueFull;
}

/// Queue a machine-generated user message delivered verbatim (no `@`-mention
/// expansion or skill prefixing) at the next turn boundary. Thread-safe — the
/// `BackgroundManager` callers reach it from the UI thread while the worker
/// may be draining the same queue. See `QueuedUserMessage.raw`.
pub fn enqueueRaw(self: *Agent, content: []const u8) !void {
    assert(content.len > 0);
    const owned = try self.gpa.dupe(u8, content);
    errdefer self.gpa.free(owned);
    try self.message_queue_mutex.lock(self.io);
    defer self.message_queue_mutex.unlock(self.io);
    if (!self.message_queue.push(&self.message_queue_storage, .{ .prompt = owned, .raw = true })) return error.QueueFull;
}

/// Queue a user message marked to steer (inject after the next tool batch).
/// Atomic push + mark under one lock, so the lane-steer path can't
/// interleave a concurrent drain between `enqueueUser` and `setQueuedSteer`.
pub fn enqueueSteer(self: *Agent, content: []const u8) !void {
    assert(content.len > 0);
    const owned = try self.gpa.dupe(u8, content);
    errdefer self.gpa.free(owned);
    try self.message_queue_mutex.lock(self.io);
    defer self.message_queue_mutex.unlock(self.io);
    if (!self.message_queue.push(&self.message_queue_storage, .{ .prompt = owned, .steer = true })) return error.QueueFull;
}

/// Whether any user message is waiting in the queue. The UI uses this to
/// decide whether an idle lane should start a turn to deliver a background
/// completion that was enqueued while no turn was running.
pub fn hasQueuedMessages(self: *Agent) bool {
    self.message_queue_mutex.lock(self.io) catch return false;
    defer self.message_queue_mutex.unlock(self.io);
    return self.message_queue.len() > 0;
}

pub fn drainQueuedUserMessage(self: *Agent, steer_only: bool) !u32 {
    const queued = takeQueuedUserMessage(self, steer_only) orelse return 0;
    defer self.gpa.free(queued.prompt);
    // Raw (machine-generated) messages bypass `@`-mention expansion and skill
    // prefixing so their body is never reinterpreted; user-typed prompts go
    // through the full expansion path.
    if (queued.raw) try self.addUser(queued.prompt) else try self.addUserPrompt(queued.prompt);
    return 1;
}

/// Move every queued message into history in FIFO order, returning how many
/// were drained. Used to deliver a stranded queue as a fresh turn (e.g.
/// after a user interrupt): the leading messages become context and the
/// last one is the latest user message the next prompt answers.
pub fn drainAllQueuedToHistory(self: *Agent) !u32 {
    var count: u32 = 0;
    while ((try drainQueuedUserMessage(self, false)) > 0) count += 1;
    return count;
}

/// Drop every queued message without delivering it. Thread-safe; the worker
/// drains under the same mutex.
pub fn clearQueue(self: *Agent) void {
    if (self.message_queue_mutex.lock(self.io) catch null) |_| {
        defer self.message_queue_mutex.unlock(self.io);
        while (self.message_queue.pop(&self.message_queue_storage)) |queued| {
            self.gpa.free(queued.prompt);
        }
    }
}

/// Pop and return the front queued message. When `steer_only` is set, only
/// pops if the front message is marked to steer (otherwise returns null,
/// leaving the queue untouched). Caller owns `queued.prompt`.
pub fn takeQueuedUserMessage(self: *Agent, steer_only: bool) ?QueuedUserMessage {
    if (self.message_queue_mutex.lock(self.io)) |_| {
        defer self.message_queue_mutex.unlock(self.io);
        if (steer_only) {
            const front = self.message_queue.peek(&self.message_queue_storage) orelse return null;
            if (!front.steer) return null;
        }
        return self.message_queue.pop(&self.message_queue_storage);
    } else |_| {
        return null;
    }
}

/// Mark the queued message at logical `index` to steer (inject after the
/// next tool batch). Called from the UI thread; guarded by the queue mutex
/// the worker also holds while draining.
pub fn setQueuedSteer(self: *Agent, index: u32) void {
    if (self.message_queue_mutex.lock(self.io) catch null) |_| {
        defer self.message_queue_mutex.unlock(self.io);
        if (self.message_queue.at(&self.message_queue_storage, index)) |entry| entry.steer = true;
    }
}

// ── Tests ──────────────────────────────────────────────────────────

test "queued user messages drain one at a time" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try enqueueUser(&agent, "first");
    try enqueueUser(&agent, "second");

    try std.testing.expectEqual(@as(u32, 1), try drainQueuedUserMessage(&agent, false));
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expectEqual(@as(u32, 1), agent.message_queue.len());
    try std.testing.expectEqualStrings("first", agent.messages()[0].text());
}

test "steer-only drain pops a steered front but leaves default-queued messages" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try enqueueUser(&agent, "steer me");
    try enqueueUser(&agent, "later");
    setQueuedSteer(&agent, 0);

    // The steered front injects mid-turn...
    try std.testing.expectEqual(@as(u32, 1), try drainQueuedUserMessage(&agent, true));
    try std.testing.expectEqualStrings("steer me", agent.messages()[0].text());
    // ...but the default-queued one behind it waits for turn end.
    try std.testing.expectEqual(@as(u32, 0), try drainQueuedUserMessage(&agent, true));
    try std.testing.expectEqual(@as(u32, 1), agent.message_queue.len());
    // The turn-end drain (steer_only = false) takes it.
    try std.testing.expectEqual(@as(u32, 1), try drainQueuedUserMessage(&agent, false));
    try std.testing.expectEqualStrings("later", agent.messages()[1].text());
}

test "drain all queued moves the whole queue to history in FIFO order" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try enqueueUser(&agent, "a");
    try enqueueUser(&agent, "b");
    try enqueueUser(&agent, "c");

    try std.testing.expectEqual(@as(u32, 3), try drainAllQueuedToHistory(&agent));
    try std.testing.expectEqual(@as(usize, 3), agent.messages().len);
    try std.testing.expectEqualStrings("a", agent.messages()[0].text());
    try std.testing.expectEqualStrings("c", agent.messages()[2].text());
    try std.testing.expectEqual(@as(u32, 0), agent.message_queue.len());
}

/// Mutex-wrapped allocator facade for the concurrency test below: the raw
/// testing allocator is not thread-safe, and both the enqueuer and the
/// drainer allocate through `agent.gpa`. (Same shape as tui/test_helpers'
/// `LockedAllocator`, re-declared here so agent tests don't import the TUI.)
const TestLockedAllocator = struct {
    child: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub fn allocator(self: *TestLockedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TestLockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TestLockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TestLockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TestLockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "concurrent enqueue and drain never deadlock or lose messages" {
    // Test-gap closure (PRIORITY_ACTIONS): the UI thread enqueues while a
    // worker-shaped task drains — the queue mutex guards only push/pop, and
    // the lock-failure-tolerant paths (`clearQueue`/`setQueuedSteer` treat
    // lock failure as a no-op) must not drop or corrupt entries under
    // contention. FIFO order and the exact count are the assertion; a
    // deadlock surfaces as the test runner's timeout.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var safe_gpa = TestLockedAllocator{ .child = gpa, .io = io };
    const alg = safe_gpa.allocator();

    var agent = Agent.init(alg, io, ".", .none);
    defer agent.deinit();

    const Drainer = struct {
        fn run(a: *Agent, done: *std.atomic.Value(bool)) void {
            var spins: u32 = 0;
            while (!done.load(.acquire)) : (spins += 1) {
                if (spins > 100_000) return; // bounded: never spin forever
                _ = drainAllQueuedToHistory(a) catch return;
                std.testing.io.sleep(.fromMilliseconds(1), .awake) catch return;
            }
        }
    };
    var done = std.atomic.Value(bool).init(false);
    var task = try io.concurrent(Drainer.run, .{ &agent, &done });

    const total: usize = 200;
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    // Block-scoped errdefer: an enqueue-section failure still stops and joins
    // the drainer before `agent.deinit` (the block exit guarantees it can
    // never double-await the post-join section).
    {
        errdefer {
            done.store(true, .release);
            task.await(io);
        }
        while (i < total) : (i += 1) {
            const text = try std.fmt.bufPrint(&buf, "m{d}", .{i});
            // Retry on QueueFull: the drainer is consuming concurrently, so
            // the 64-slot queue drains — the loop terminates.
            var spins: u32 = 0;
            while (true) : (spins += 1) {
                try std.testing.expect(spins < 100_000);
                enqueueUser(&agent, text) catch |err| switch (err) {
                    error.QueueFull => {
                        io.sleep(.fromMilliseconds(1), .awake) catch {};
                        continue;
                    },
                    else => return err,
                };
                break;
            }
            // Exercise the steer-marking path under contention too (mark the
            // front entry; `drainAllQueuedToHistory` drains it regardless).
            if (i % 50 == 0) setQueuedSteer(&agent, 0);
        }
    }
    done.store(true, .release);
    // Single await: the drainer exits within one 1 ms sleep of the flag.
    task.await(io);
    // Drain whatever the drainer hadn't reached when the flag flipped.
    while (agent.message_queue.len() > 0) {
        try std.testing.expect(try drainAllQueuedToHistory(&agent) > 0);
    }

    // No loss, FIFO preserved, nothing left behind.
    const messages = agent.messages();
    try std.testing.expectEqual(total, messages.len);
    try std.testing.expectEqualStrings("m0", messages[0].text());
    try std.testing.expectEqualStrings("m199", messages[total - 1].text());
    try std.testing.expectEqual(@as(u32, 0), agent.message_queue.len());
}

test "raw enqueued messages are delivered verbatim without @-mention expansion" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try std.testing.expect(!hasQueuedMessages(&agent));
    // A background completion notice may contain an `@` that must not be treated
    // as a file mention.
    try enqueueRaw(&agent, "Background command bg_1 (`echo @no/such/file`) finished — exit 0");
    try std.testing.expect(hasQueuedMessages(&agent));

    try std.testing.expectEqual(@as(u32, 1), try drainQueuedUserMessage(&agent, false));
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expectEqualStrings(
        "Background command bg_1 (`echo @no/such/file`) finished — exit 0",
        agent.messages()[0].text(),
    );
    try std.testing.expect(!hasQueuedMessages(&agent));
}

test "clear queue drops messages without delivering them" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try enqueueUser(&agent, "x");
    try enqueueUser(&agent, "y");
    clearQueue(&agent);

    try std.testing.expectEqual(@as(u32, 0), agent.message_queue.len());
    try std.testing.expectEqual(@as(usize, 0), agent.messages().len);
}
