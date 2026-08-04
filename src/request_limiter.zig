//! RequestLimiter — a process-wide cap on concurrent LLM requests to the
//! provider, shared by every lane's agent.
//!
//! Nova runs each lane on its own worker thread with its own HTTP client, so
//! without a limiter N active lanes fire N independent requests at the
//! provider at once. Providers (notably cloud flash models) degrade or
//! rate-limit that burst and every lane slows down together. The limiter lets
//! at most `permits` requests be in flight at a time, so lanes briefly queue
//! instead of saturating the provider — bounded and fair, with no head-of-line
//! blocking (a permit is held only for the duration of a single
//! `client.prompt`, never across tool execution).
//!
//! Mirrors the `LaneBridge`/`ApprovalGate` pattern: `std.Io.Mutex` +
//! `std.Io.Condition`. The wait is an I/O wait on the shared `std.Io`, so a
//! worker blocked here is a normal cancellation point — `future.cancel`
//! (turn interrupt / app teardown) aborts it and `acquire` reports
//! `error.TurnCancelled`, which the worker's existing "Interrupted." path
//! handles.

const std = @import("std");

/// Default maximum concurrent requests when the config knob is unset. Single
/// lane (1 request at a time) is unaffected; 2 lets driver + one lane stream
/// while bounding the burst that saturates the provider.
pub const default_permits: u32 = 2;

pub const RequestLimiter = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    /// Maximum concurrent requests allowed through. Read/written under
    /// `mutex`; `setPermits` clamps to >= 1.
    permits: u32 = default_permits,
    /// Requests currently between `acquire` and `release`.
    in_flight: u32 = 0,

    /// Block until fewer than `permits` requests are in flight, then count
    /// this one. Returns `error.TurnCancelled` when the owning future is
    /// cancelled (turn interrupt / teardown) — the condition wait is an I/O
    /// wait, so the cancel aborts it.
    pub fn acquire(self: *RequestLimiter, io: std.Io) !void {
        self.mutex.lock(io) catch return error.TurnCancelled;
        defer self.mutex.unlock(io);
        while (self.in_flight >= self.permits) {
            self.condition.wait(io, &self.mutex) catch return error.TurnCancelled;
        }
        self.in_flight += 1;
    }

    /// Free this request's slot and wake one waiter (if any).
    pub fn release(self: *RequestLimiter, io: std.Io) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        self.in_flight -= 1;
        self.condition.signal(io);
    }

    /// Live config update. Safe to call on a limiter with waiters: the permit
    /// count is read under the mutex, and raising it lets a waiting request
    /// through on its next wake.
    pub fn setPermits(self: *RequestLimiter, io: std.Io, n: u32) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        self.permits = @max(1, n);
        self.condition.signal(io);
    }
};

/// Test helper: current in-flight count, read under the mutex so a concurrent
/// worker's acquire/release is seen atomically.
fn inFlightCount(limiter: *RequestLimiter) u32 {
    limiter.mutex.lock(std.testing.io) catch return 0;
    defer limiter.mutex.unlock(std.testing.io);
    return limiter.in_flight;
}

test "acquire/release bookkeeping passes through under the cap" {
    var limiter: RequestLimiter = .{ .permits = 2 };
    try limiter.acquire(std.testing.io);
    try limiter.acquire(std.testing.io);
    try std.testing.expectEqual(@as(u32, 2), limiter.in_flight);
    limiter.release(std.testing.io);
    limiter.release(std.testing.io);
    try std.testing.expectEqual(@as(u32, 0), limiter.in_flight);
}

test "a third acquire blocks until a release frees a slot" {
    var limiter: RequestLimiter = .{ .permits = 1 };
    try limiter.acquire(std.testing.io); // main holds the only slot

    var started: std.atomic.Value(bool) = .init(false);
    var acquired: std.atomic.Value(bool) = .init(false);
    const Worker = struct {
        fn run(l: *RequestLimiter, started_flag: *std.atomic.Value(bool), acquired_flag: *std.atomic.Value(bool)) void {
            started_flag.store(true, .release);
            l.acquire(std.testing.io) catch unreachable;
            acquired_flag.store(true, .release);
            l.release(std.testing.io);
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &limiter, &started, &acquired });

    // The worker is blocked on the cap: started but not yet acquired.
    var spins: u32 = 0;
    while (spins < 10_000 and !started.load(.acquire)) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(started.load(.acquire));
    std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    try std.testing.expectEqual(@as(u32, 1), inFlightCount(&limiter));
    try std.testing.expect(!acquired.load(.acquire));

    // Releasing wakes it; the worker acquires (2 in flight), then releases.
    limiter.release(std.testing.io);
    thread.join();
    try std.testing.expect(acquired.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), inFlightCount(&limiter));
}

test "raising permits lets a blocked waiter through" {
    var limiter: RequestLimiter = .{ .permits = 1 };
    try limiter.acquire(std.testing.io); // main holds the only slot

    var started: std.atomic.Value(bool) = .init(false);
    var acquired: std.atomic.Value(bool) = .init(false);
    const Worker = struct {
        fn run(l: *RequestLimiter, started_flag: *std.atomic.Value(bool), acquired_flag: *std.atomic.Value(bool)) void {
            started_flag.store(true, .release);
            l.acquire(std.testing.io) catch unreachable;
            acquired_flag.store(true, .release);
            l.release(std.testing.io);
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &limiter, &started, &acquired });

    var spins: u32 = 0;
    while (spins < 10_000 and !started.load(.acquire)) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(!acquired.load(.acquire));

    // permits 1 -> 2: the worker no longer needs a release to get through.
    limiter.setPermits(std.testing.io, 2);
    thread.join();
    try std.testing.expect(acquired.load(.acquire));
}

test "a cancelled acquire reports TurnCancelled (interrupt/teardown path)" {
    var limiter: RequestLimiter = .{ .permits = 1 };
    try limiter.acquire(std.testing.io); // main holds the only slot

    var started: std.atomic.Value(bool) = .init(false);
    var got_cancel: std.atomic.Value(bool) = .init(false);
    const Worker = struct {
        fn run(l: *RequestLimiter, started_flag: *std.atomic.Value(bool), cancel_flag: *std.atomic.Value(bool)) void {
            started_flag.store(true, .release);
            l.acquire(std.testing.io) catch |err| {
                if (err == error.TurnCancelled) cancel_flag.store(true, .release);
                return;
            };
            // A pass-through here means the cancel did not reach the wait.
            std.debug.panic("acquire resolved instead of cancelling", .{});
        }
    };
    var future = try std.testing.io.concurrent(Worker.run, .{ &limiter, &started, &got_cancel });

    var spins: u32 = 0;
    while (spins < 10_000 and !started.load(.acquire)) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    // Give the worker a moment to actually enter the condition wait.
    std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};

    _ = future.cancel(std.testing.io);
    try std.testing.expect(got_cancel.load(.acquire));
    // The main slot is still held — only the cancelled waiter was unwound.
    try std.testing.expectEqual(@as(u32, 1), inFlightCount(&limiter));
    limiter.release(std.testing.io);
}
