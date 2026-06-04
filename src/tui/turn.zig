//! Turn — the lifecycle state machine for a single agent turn.
//!
//! A turn begins when the user submits a prompt and ends when the worker
//! emits the terminal `turn_finished` event. The worker always posts that
//! event last, even on cancellation (see `agent_worker.runAgentTurn`), so it
//! is the single terminal signal the machine waits for.
//!
//! The machine is pure: it owns no thread, projection, worker, or allocator.
//! The App drives it by calling `submit`/`interrupt` and feeding every
//! `Agent.Event` through `apply`, which advances the state and returns an
//! `Outcome` describing what the App must do next. Keeping it pure makes the
//! interface the test surface — a scripted event sequence can assert the
//! whole state path with no TUI or background worker.
//!
//! The loading spinner the TUI shows while waiting for output is NOT part of
//! this machine. Whether a given chunk actually rendered (partial tool
//! arguments render nothing, for example) is known only to the thread
//! projection, which owns that finer-grained `awaiting_output` state.

const std = @import("std");

const agent_mod = @import("../agent.zig");

const assert = std.debug.assert;

const Turn = @This();

state: State = .idle,

pub const State = enum {
    /// No turn in progress.
    idle,
    /// A turn is running and the worker is streaming events.
    active,
    /// The user interrupted; the worker is still unwinding. Events are
    /// swallowed (not projected) until the terminal `turn_finished` arrives.
    interrupting,
};

/// What the App must do after `apply` handles an event. Flags rather than a
/// single enum because a terminal event is several things at once.
pub const Outcome = struct {
    /// Forward this event to the thread projection. False while interrupting:
    /// a discarded turn's output must not mutate the thread.
    project: bool = false,
    /// The turn reached its terminal event; the App should join the worker
    /// and run end-of-turn cleanup (steering flush).
    finished: bool = false,
};

pub fn isActive(self: Turn) bool {
    return self.state != .idle;
}

/// Begin a turn. Only valid from idle — the App enqueues steering messages
/// instead of submitting while a turn is already active.
pub fn submit(self: *Turn) void {
    assert(self.state == .idle);
    self.state = .active;
}

/// Mark the running turn interrupted. Events keep arriving until the worker
/// posts `turn_finished`; `apply` swallows them until then.
pub fn interrupt(self: *Turn) void {
    assert(self.state == .active);
    self.state = .interrupting;
}

/// Force the machine back to idle after the App has cancelled and drained an
/// abandoned worker out-of-band (see `App.discardAbandonedTurn`).
pub fn reset(self: *Turn) void {
    assert(self.state != .idle);
    self.state = .idle;
}

pub fn apply(self: *Turn, event: agent_mod.Agent.Event) Outcome {
    switch (self.state) {
        .idle => return .{},
        .active => {
            switch (event) {
                .turn_finished => {
                    self.state = .idle;
                    return .{ .project = true, .finished = true };
                },
                else => return .{ .project = true },
            }
        },
        .interrupting => {
            switch (event) {
                .turn_finished => {
                    self.state = .idle;
                    return .{ .finished = true };
                },
                else => return .{},
            }
        },
    }
}

test "submit then a normal turn finishes" {
    var turn: Turn = .{};
    try std.testing.expectEqual(State.idle, turn.state);
    try std.testing.expect(!turn.isActive());

    turn.submit();
    try std.testing.expectEqual(State.active, turn.state);
    try std.testing.expect(turn.isActive());

    const delta = turn.apply(.{ .response_delta = "hi" });
    try std.testing.expect(delta.project);
    try std.testing.expect(!delta.finished);
    try std.testing.expectEqual(State.active, turn.state);

    const done = turn.apply(.turn_finished);
    try std.testing.expect(done.project);
    try std.testing.expect(done.finished);
    try std.testing.expectEqual(State.idle, turn.state);
}

test "interrupt swallows output until the terminal event" {
    var turn: Turn = .{};
    turn.submit();
    turn.interrupt();
    try std.testing.expectEqual(State.interrupting, turn.state);

    // The worker keeps streaming (including its own turn_failed) — none of it
    // should reach the projection.
    const swallowed = turn.apply(.{ .response_delta = "late" });
    try std.testing.expect(!swallowed.project);
    try std.testing.expect(!swallowed.finished);
    try std.testing.expectEqual(State.interrupting, turn.state);

    const failed = turn.apply(.{ .turn_failed = "Interrupted." });
    try std.testing.expect(!failed.project);
    try std.testing.expect(!failed.finished);

    // Only turn_finished ends the interrupt window and asks the App to join.
    const done = turn.apply(.turn_finished);
    try std.testing.expect(!done.project);
    try std.testing.expect(done.finished);
    try std.testing.expectEqual(State.idle, turn.state);
}

test "events apply as no-ops while idle" {
    var turn: Turn = .{};
    const outcome = turn.apply(.{ .response_delta = "stray" });
    try std.testing.expect(!outcome.project);
    try std.testing.expect(!outcome.finished);
    try std.testing.expectEqual(State.idle, turn.state);
}
