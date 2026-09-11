//! Async teardown of an interrupted turn's worker: a heap job that owns the
//! turn future while the (possibly long) `Future.cancel` join runs on a
//! background task, so the UI thread never blocks on an interrupt.
//!
//! Deliberately dumb plumbing — no App, no Thread, no turn machine. The
//! spawn/drain/converge logic lives in `turn_lifecycle.zig`; this module
//! imports only std so `Thread` can hold the pointer type without a cycle.

const std = @import("std");

pub const TurnCancelJob = struct {
    io: std.Io,
    /// The interrupted turn's future, MOVED out of `Thread.turn_future`:
    /// `Future.cancel`/`await` are not threadsafe and the slot may be reused
    /// by a fresh turn, so this job is its exclusive owner until the worker
    /// has fully unwound. The UI thread never touches it again.
    future: std.Io.Future(void),
    /// This job's own task frame. `concurrent` may start running the task
    /// before it returns, but the task never reads this field — only
    /// `drainTurnCancels` does, after `done` (which the task stores last).
    task: std.Io.Future(void) = undefined,
    /// Set after the join completed; the release/acquire pair is the handoff
    /// that makes every other field safe to read from the UI thread.
    done: std.atomic.Value(bool) = .init(false),

    /// Blocks until the worker task fully returns: `Future.cancel` places the
    /// cancel request and then awaits. Bounded in practice by the abortable
    /// network read upstream and, in the tool unwind, the capture teardown's
    /// SIGKILL escalation (`os.terminateChildBounded`).
    pub fn run(job: *TurnCancelJob) void {
        job.future.cancel(job.io);
        job.done.store(true, .release);
    }
};
