//! Thread — a lane: one unit of parallel work the developer can branch, run an
//! agent in, and merge back. It bundles the always-present UI projection
//! (transcript + turn state) with an `engine` that is attached lazily.
//!
//! The engine is a sum type so the expensive parts — an `AgentRuntime` owns a
//! client connection, a session writer, and a worker thread — exist only when a
//! lane is actually being run:
//!   - `idle`     a parked lane: its jj workspace identity, but no runtime
//!                attached. Cheap. Smartlog entries, headless rendering, and
//!                tests live here. Wake it to attach a runtime.
//!   - `live`     workspace + an owned `AgentRuntime` (tools rooted at the
//!                workspace path). The lane is in use.
//!   - `archived` squashed into a target and popped: only the merge record
//!                remains, so there is no workspace path to dangle and no
//!                runtime to accidentally drive.
//!
//! The transcript/turn UI lives outside the union because it's needed in every
//! state (you still render a parked or archived lane's history), and a turn is
//! cheap value state. `id` is optional: bound once the lane has a persisted
//! session; null for a fresh or headless UI.
//!
//! Scaffolding for now — the `App` still owns the single primary lane as inline
//! fields; a later stage moves those into one of these.

const std = @import("std");
const vaxis = @import("vaxis");

const agent_mod = @import("../agent.zig");
const vcs = @import("../vcs.zig");
const runtime = @import("../runtime.zig");
const session = @import("../session.zig");
const transcript_mod = @import("../transcript.zig");
const Turn = @import("turn.zig");
const turn_view_mod = @import("turn_view.zig");
const agent_worker = @import("agent_worker.zig");

const Thread = @This();

/// Identity: the conversation tree this lane talks to. Null until the lane has a
/// persisted session (fresh startup before the first turn, or a headless/test
/// UI). Branching the timeline forks a new session (a new `Thread`).
id: ?session.SessionId = null,
/// One-line label, lazily derived from the first user message. Owned.
title: ?[]u8 = null,
/// Rendered history — present in every engine state, even archived.
transcript: transcript_mod.Transcript = .{},
/// Lifecycle of the in-progress turn (idle / active / interrupting).
turn: Turn = .{},
/// Streaming positions + synthetic UI state for the current turn.
turn_view: turn_view_mod.TurnView = .{},
/// Messages the user queued behind a running turn on this lane. Owned text.
queued: std.ArrayList(QueuedMessage) = .empty,
/// Per-lane viewport state that outlives any single turn.
auto_scroll: bool = true,
/// Per-lane scroll/viewport state for rendering this lane's transcript in its
/// own pane, so split columns scroll independently.
transcript_list: vaxis.vxfw.ListView = .{ .children = .{ .slice = &.{} }, .draw_cursor = false, .wheel_scroll = 4 },
transcript_view_width: u16 = 80,
transcript_view_height: u16 = 1,
/// Per-lane turn execution: the worker's event queue + cancel flags (null until
/// the lane runs turns), the in-flight turn's future, and the raw prompt
/// awaiting handoff to the worker. Each lane runs its turn independently of the
/// others.
worker_context: ?agent_worker.Context = null,
turn_future: ?std.Io.Future(void) = null,
pending_prompt: ?[]u8 = null,
permission_selection: agent_worker.ApprovalDecision = .approve,
permission_scroll: u32 = 0,
/// The turn-driving handle: enqueue user input, start turns, read messages.
/// Orthogonal to `engine` — in production it points into the live runtime's
/// agent, but it's a borrowed handle (never freed here), and it can be present
/// without a runtime (the test/headless path drives a free-standing agent).
/// Null until an agent is attached.
agent: ?*agent_mod.Agent = null,
engine: Engine = .{ .idle = .primary },

/// A user message queued behind a running turn. `steer` injects it after the
/// next tool batch instead of waiting for the turn to go idle. Text is owned.
pub const QueuedMessage = struct {
    text: []const u8,
    steer: bool = false,
};

/// A live lane: its git worktree identity plus the owned runtime driving it.
pub const Live = struct {
    lane: vcs.Lane,
    runtime: *runtime.AgentRuntime,
    /// Whether this lane owns `runtime` and frees it on deinit. False for a
    /// borrowed runtime — e.g. a test that attaches a stack-allocated stub it
    /// frees itself.
    owns: bool = true,
};

/// Whether — and how — this lane is attached to an execution engine. A lane is
/// either parked (`idle`, no runtime) or running (`live`). Closing a lane tears
/// it down and removes it from the list — there is no archived state (lanes
/// don't merge; they land on `main` via a PR).
pub const Engine = union(enum) {
    idle: vcs.Lane,
    live: Live,
};

/// Free everything this thread owns. For `.live`, that includes tearing down and
/// destroying the owned `AgentRuntime` — the lane is the runtime's owner.
pub fn deinit(self: *Thread, gpa: std.mem.Allocator) void {
    if (self.title) |title| gpa.free(title);
    self.transcript.deinit(gpa);
    self.turn_view.deinit(gpa);
    for (self.queued.items) |*message| gpa.free(message.text);
    self.queued.deinit(gpa);
    if (self.pending_prompt) |prompt| gpa.free(prompt);
    if (self.worker_context) |*worker| {
        worker.approval.deinit(worker.io, gpa);
        worker.queue.deinit(worker.io, gpa);
    }
    switch (self.engine) {
        .idle => |*lane| lane.deinit(gpa),
        .live => |*live| {
            // Free the runtime before the lane: a workspace runtime borrows the
            // lane's `path` as its `cwd`, so the owner must outlive the borrower.
            if (live.owns) {
                live.runtime.deinit();
                gpa.destroy(live.runtime);
            }
            live.lane.deinit(gpa);
        },
    }
    self.* = undefined;
}

test "idle thread frees its owned title, transcript, and queue" {
    const gpa = std.testing.allocator;
    var thread: Thread = .{ .title = try gpa.dupe(u8, "feature x") };
    try thread.queued.append(gpa, .{ .text = try gpa.dupe(u8, "queued prompt") });
    thread.deinit(gpa);
}

test "idle working lane frees its worktree branch and path" {
    const gpa = std.testing.allocator;
    var thread: Thread = .{ .engine = .{ .idle = .{ .working = .{
        .branch = try gpa.dupe(u8, "nova/x"),
        .path = try gpa.dupe(u8, "/repo/.nova/worktrees/x"),
    } } } };
    thread.deinit(gpa);
}
