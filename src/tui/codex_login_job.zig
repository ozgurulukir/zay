//! Background worker for the OpenAI Codex browser login.
//!
//! OAuth waits on a loopback callback and performs a token exchange. Those
//! operations are allowed to take seconds (or the full callback timeout), so
//! they must not run from the vaxis event thread. The worker owns every input
//! that crosses the thread boundary and publishes its result through a
//! release/acquire completion flag.

const std = @import("std");
const codex = @import("../auth/codex.zig");

pub const Outcome = union(enum) {
    ready: codex.Credentials,
    failed: anyerror,

    pub fn deinit(self: *Outcome, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |*credentials| credentials.deinit(gpa),
            .failed => {},
        }
        self.* = undefined;
    }
};

pub const Job = struct {
    pub const Worker = *const fn (*Job) Outcome;

    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []u8,
    /// The lane identity is checked by the UI before applying the result.
    generation: u64,
    /// Empty when the active runtime has not persisted a session yet.
    session_id: []u8 = &.{},
    cancel_requested: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    outcome: ?Outcome = null,
    thread: ?std.Thread = null,
    worker: Worker,
    /// Test-only gate; production jobs leave this null.
    test_gate: ?*std.atomic.Value(bool) = null,

    pub fn start(
        gpa: std.mem.Allocator,
        io: std.Io,
        home_dir: []const u8,
        generation: u64,
        session_id: []const u8,
    ) !*Job {
        return startWithWorker(gpa, io, home_dir, generation, session_id, runLogin, null);
    }

    fn startWithWorker(
        gpa: std.mem.Allocator,
        io: std.Io,
        home_dir: []const u8,
        generation: u64,
        session_id: []const u8,
        worker: Worker,
        test_gate: ?*std.atomic.Value(bool),
    ) !*Job {
        std.debug.assert(home_dir.len > 0);

        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        const owned_home_dir = try gpa.dupe(u8, home_dir);
        errdefer gpa.free(owned_home_dir);
        const owned_session_id: []u8 = if (session_id.len == 0) &.{} else try gpa.dupe(u8, session_id);
        errdefer if (owned_session_id.len > 0) gpa.free(owned_session_id);

        job.* = .{
            .gpa = gpa,
            .io = io,
            .home_dir = owned_home_dir,
            .generation = generation,
            .session_id = owned_session_id,
            .worker = worker,
            .test_gate = test_gate,
        };
        job.thread = try std.Thread.spawn(.{}, runWorker, .{job});
        return job;
    }

    fn runWorker(job: *Job) void {
        job.outcome = job.worker(job);
        job.done.store(true, .release);
    }

    fn runLogin(job: *Job) Outcome {
        const credentials = codex.loginCancellable(
            job.gpa,
            job.io,
            job.home_dir,
            &job.cancel_requested,
        ) catch |err| return .{ .failed = err };
        return .{ .ready = credentials };
    }

    pub fn isDone(self: *const Job) bool {
        return self.done.load(.acquire);
    }

    pub fn takeOutcome(self: *Job) Outcome {
        std.debug.assert(self.done.load(.acquire));
        const outcome = self.outcome orelse unreachable;
        self.outcome = null;
        return outcome;
    }

    pub fn deinit(self: *Job) void {
        self.cancel_requested.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.outcome) |*outcome| outcome.deinit(self.gpa);
        if (self.session_id.len > 0) self.gpa.free(self.session_id);
        self.gpa.free(self.home_dir);
        self.gpa.destroy(self);
    }
};

fn blockedTestWorker(job: *Job) Outcome {
    const gate = job.test_gate orelse unreachable;
    while (!gate.load(.acquire)) {
        job.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return .{ .failed = error.TestExpectedEqual };
}

test "codex login job leaves the caller responsive while OAuth waits" {
    const gpa = std.testing.allocator;
    var gate = std.atomic.Value(bool).init(false);
    var job = try Job.startWithWorker(gpa, std.testing.io, ".", 1, "", blockedTestWorker, &gate);
    defer job.deinit();

    try std.testing.expect(!job.isDone());
    gate.store(true, .release);

    var spins: u32 = 0;
    while (!job.isDone() and spins < 1_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(job.isDone());
    var outcome = job.takeOutcome();
    outcome.deinit(gpa);
}
