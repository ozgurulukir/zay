//! Job(T) — the one convention for App-level background futures: arm a
//! worker on the Io implementation's concurrent lane, poll completion
//! non-blockingly from the tick, adopt the result exactly once, and join at
//! teardown. The five App-level families (diff refresh, models.dev registry,
//! model load, git label, codex login) build on this; their debounce,
//! generation/session drops, adopt protocols, and result projections stay in
//! the family lifecycle files — those are behaviour, not plumbing.

const std = @import("std");

pub fn Job(comptime T: type) type {
    return struct {
        future: std.Io.Future(T) = undefined,
        /// Set by the worker wrapper immediately before it returns (stored
        /// LAST, .release) so the UI thread can poll it non-blockingly
        /// (.acquire) before awaiting.
        done: std.atomic.Value(bool) = .init(false),
        /// Set by cancel before joining a worker that opted into cooperative
        /// cancellation. The worker owns the interpretation of the flag.
        cancel_requested: std.atomic.Value(bool) = .init(false),

        const Self = @This();

        /// Arm in place: run `worker(ctx)` on `io`'s concurrent lane.
        ///
        /// THE INVARIANT: `self` must already live at its final address —
        /// the spawned task captures `&self.done`, so the owning union arm
        /// or optional may not be reassigned until adopt() or cancel() has
        /// completed. Assign the owning state FIRST, then spawn through a
        /// pointer into it. Spawn failure resets the pair to disarmed, so
        /// the caller's fallback (move the union out, re-raise) never leaves
        /// an armed state with an undefined future.
        pub fn spawn(self: *Self, io: std.Io, ctx: anytype, comptime worker: fn (@TypeOf(ctx)) T) !void {
            std.debug.assert(!self.done.load(.acquire)); // no double-spawn on an armed job
            self.* = .{};
            const Ctx = @TypeOf(ctx);
            self.future = try io.concurrent(struct {
                fn run(job: *Self, worker_ctx: Ctx) T {
                    const result = worker(worker_ctx);
                    job.done.store(true, .release);
                    return result;
                }
            }.run, .{ self, ctx });
        }

        /// Arm a worker that must cooperatively interrupt blocking OS work.
        pub fn spawnCancelable(
            self: *Self,
            io: std.Io,
            ctx: anytype,
            comptime worker: fn (@TypeOf(ctx), *const std.atomic.Value(bool)) T,
        ) !void {
            std.debug.assert(!self.done.load(.acquire));
            self.* = .{};
            const Ctx = @TypeOf(ctx);
            self.future = try io.concurrent(struct {
                fn run(job: *Self, worker_ctx: Ctx) T {
                    const result = worker(worker_ctx, &job.cancel_requested);
                    job.done.store(true, .release);
                    return result;
                }
            }.run, .{ self, ctx });
        }

        /// Non-blocking completion poll.
        pub fn isDone(self: *const Self) bool {
            return self.done.load(.acquire);
        }

        /// Adopt the worker's result — exactly once, only after isDone().
        /// ADOPT CONSUMES THE JOB: `done` stays true afterwards, so the
        /// owner must discard the slot (its union moves out, the optional
        /// nulls) instead of re-spawning in place.
        pub fn adopt(self: *Self, io: std.Io) T {
            std.debug.assert(self.done.load(.acquire));
            return self.future.await(io);
        }

        /// Teardown join: blocks until the worker returns and hands back its
        /// result for the caller to dispose. `Future.cancel` is "await with
        /// a cancelation request" — never call from the render path; this is
        /// for teardown and dedicated join threads.
        pub fn cancel(self: *Self, io: std.Io) T {
            self.cancel_requested.store(true, .release);
            return self.future.cancel(io);
        }
    };
}

test "job spawns, polls, and adopts exactly once" {
    const Ctx = struct {
        gate: std.atomic.Value(bool) = .init(false),
        payload: []const u8,

        fn worker(self: *@This()) []const u8 {
            while (!self.gate.load(.acquire)) {
                std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
            }
            return self.payload;
        }
    };
    var ctx: Ctx = .{ .payload = "result bytes" };

    var job: Job([]const u8) = .{};
    defer _ = job.cancel(std.testing.io);
    try job.spawn(std.testing.io, &ctx, Ctx.worker);

    // Not done until the gate opens; the poll never blocks.
    try std.testing.expect(!job.isDone());
    ctx.gate.store(true, .release);
    var spins: u32 = 0;
    while (!job.isDone()) : (spins += 1) {
        try std.testing.expect(spins < 10_000);
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqualStrings("result bytes", job.adopt(std.testing.io));
}

test "job cancel joins a blocked worker and discards the result" {
    const Ctx = struct {
        gate: std.atomic.Value(bool) = .init(false),

        fn worker(self: *@This()) u32 {
            while (!self.gate.load(.acquire)) {
                std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
            }
            return 7;
        }
    };
    var ctx: Ctx = .{};

    var job: Job(u32) = .{};
    try job.spawn(std.testing.io, &ctx, Ctx.worker);
    try std.testing.expect(!job.isDone());

    // Cancel blocks until the worker unwinds; the result is discarded.
    ctx.gate.store(true, .release);
    const result = job.cancel(std.testing.io);
    try std.testing.expectEqual(@as(u32, 7), result);
    try std.testing.expect(job.isDone());
}

test "adopt consumes the job: a fresh slot is required for the next run" {
    const Ctx = struct {
        fn worker(_: *@This()) u32 {
            return 42;
        }
    };
    var ctx: Ctx = .{};
    var job: Job(u32) = .{};
    defer _ = job.cancel(std.testing.io);

    try job.spawn(std.testing.io, &ctx, Ctx.worker);
    var spins: u32 = 0;
    while (!job.isDone()) : (spins += 1) {
        try std.testing.expect(spins < 10_000);
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    _ = job.adopt(std.testing.io);

    // The slot is consumed -- a second spawn on it is a contract
    // violation (Debug panics). The owning state discards the slot and
    // builds a fresh one for the next run.
    try std.testing.expect(job.isDone());
}
