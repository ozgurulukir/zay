const std = @import("std");

const bounded_queue = @import("bounded_queue");
const agent_mod = @import("../agent.zig");

const event_queue_capacity: u32 = 4096;
const EventQueueStorage = bounded_queue.BoundedQueue(*agent_mod.Agent.Event);

pub const EventQueue = struct {
    mutex: std.Io.Mutex = .init,
    event_queue: EventQueueStorage = .{},
    storage: [event_queue_capacity]*agent_mod.Agent.Event = undefined,

    pub fn push(
        self: *EventQueue,
        io: std.Io,
        gpa: std.mem.Allocator,
        event: *agent_mod.Agent.Event,
    ) !void {
        _ = gpa;
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        if (!self.event_queue.push(&self.storage, event)) return error.QueueFull;
    }

    pub fn drainInto(
        self: *EventQueue,
        io: std.Io,
        gpa: std.mem.Allocator,
        sink: *std.ArrayList(*agent_mod.Agent.Event),
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        while (self.event_queue.pop(&self.storage)) |event| {
            try sink.append(gpa, event);
        }
    }

    pub fn deinit(self: *EventQueue, io: std.Io, gpa: std.mem.Allocator) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        while (self.event_queue.pop(&self.storage)) |event_ptr| {
            event_ptr.deinit(gpa);
            gpa.destroy(event_ptr);
        }
    }
};

pub const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    queue: EventQueue = .{},
    cancel_requested: std.atomic.Value(bool) = .init(false),
    cancel_signaled: std.atomic.Value(bool) = .init(false),

    pub fn requestCancel(self: *Context) void {
        self.cancel_requested.store(true, .release);
    }

    pub fn resetCancel(self: *Context) void {
        self.cancel_requested.store(false, .release);
        self.cancel_signaled.store(false, .release);
    }
};

pub const cancel_message = "Interrupted.";

/// `pending_prompt`, when present, is raw user text owned by `worker_context.gpa`.
/// It is expanded (file embedding / image attachment) and appended to history
/// here, on the worker thread, so the UI thread never blocks on that I/O.
pub fn runAgentTurn(agent: *agent_mod.Agent, worker_context: *Context, pending_prompt: ?[]u8) void {
    if (pending_prompt) |prompt| {
        defer worker_context.gpa.free(prompt);
        agent.addUserPrompt(prompt) catch |err| {
            const message_text = std.fmt.allocPrint(
                worker_context.gpa,
                "agent turn failed: {s}",
                .{@errorName(err)},
            ) catch return;
            postAgentEvent(worker_context, .{ .turn_failed = message_text }) catch {
                worker_context.gpa.free(message_text);
            };
            postAgentEvent(worker_context, .turn_finished) catch {};
            return;
        };
    }
    agent.run(.{
        .ptr = worker_context,
        .on_event = postAgentEvent,
    }) catch |err| {
        const message_text = if (err == error.TurnCancelled)
            worker_context.gpa.dupe(u8, cancel_message) catch return
        else if (agent.client.lastErrorDetail()) |detail|
            worker_context.gpa.dupe(u8, detail) catch return
        else
            std.fmt.allocPrint(
                worker_context.gpa,
                "agent turn failed: {s}",
                .{@errorName(err)},
            ) catch return;
        postAgentEvent(worker_context, .{ .turn_failed = message_text }) catch {
            worker_context.gpa.free(message_text);
            return;
        };
    };
    postAgentEvent(worker_context, .turn_finished) catch {};
}

const queue_full_backoff_ms: u64 = 2;

fn postAgentEvent(context: *anyopaque, event: agent_mod.Agent.Event) anyerror!void {
    const worker_context: *Context = @ptrCast(@alignCast(context));
    if (worker_context.cancel_requested.load(.acquire) and
        !worker_context.cancel_signaled.swap(true, .acq_rel))
    {
        var owned = event;
        owned.deinit(worker_context.gpa);
        return error.TurnCancelled;
    }
    var owned_event = event;
    errdefer owned_event.deinit(worker_context.gpa);
    const event_ptr = try worker_context.gpa.create(agent_mod.Agent.Event);
    errdefer worker_context.gpa.destroy(event_ptr);
    event_ptr.* = owned_event;
    owned_event = .delta_end;
    errdefer event_ptr.deinit(worker_context.gpa);

    // Block until the event lands. Dropping it would corrupt the rendered turn,
    // and dropping the terminal `turn_finished` would strand the UI's Turn in
    // the active state forever (spinner never stops, no further submits). The
    // worker is inside the network read loop here, so waiting just applies
    // normal backpressure to the stream.
    //
    // We don't bail on cancel here: the top-of-function check already aborts the
    // turn, and `turn_finished` is posted *during* that unwind (with
    // `cancel_requested` already set) — it must still be delivered. The UI keeps
    // draining every ~30 ms while the turn is active, so a full queue clears.
    while (true) {
        worker_context.queue.push(worker_context.io, worker_context.gpa, event_ptr) catch |err| switch (err) {
            error.QueueFull => {
                worker_context.io.sleep(.fromMilliseconds(queue_full_backoff_ms), .awake) catch {};
                continue;
            },
            else => return err,
        };
        return;
    }
}
