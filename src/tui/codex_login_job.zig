//! Worker for the OpenAI Codex browser login.
//!
//! OAuth waits on a loopback callback and performs a token exchange. Those
//! operations are allowed to take seconds (or the full callback timeout), so
//! they must not run from the vaxis event thread. The worker context is the
//! armed arm itself — `Job(Outcome).spawn` captures its address, so the App
//! field may not be reassigned until the job is adopted or cancelled.

const std = @import("std");
const job_mod = @import("job.zig");
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

/// The armed login job as an App field. `generation`/`session_id` let the UI
/// discard a result whose lane or session was switched while the browser was
/// open; `cancel_requested` is polled by the OAuth worker so teardown can
/// unwind it.
pub const CodexLoginJob = struct {
    job: job_mod.Job(Outcome),
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []u8,
    generation: u64,
    /// Empty when the active runtime has not persisted a session yet.
    session_id: []u8 = &.{},
    cancel_requested: std.atomic.Value(bool) = .init(false),
};

/// Free the arm's allocations (the Job itself is disarmed by then).
pub fn deinitArm(arm: *CodexLoginJob) void {
    arm.gpa.free(arm.home_dir);
    if (arm.session_id.len > 0) arm.gpa.free(arm.session_id);
    arm.* = undefined;
}

/// Worker entry point for `Job(Outcome).spawn`. The cooperative cancel flag
/// is polled inside `loginCancellable`'s callback wait.
pub fn runLogin(arm: *CodexLoginJob) Outcome {
    const credentials = codex.loginCancellable(
        arm.gpa,
        arm.io,
        arm.home_dir,
        &arm.cancel_requested,
    ) catch |err| return .{ .failed = err };
    return .{ .ready = credentials };
}
