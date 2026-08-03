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
const naming = @import("naming.zig");

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
/// Prompt history submitted on this lane for Up/Down navigation.
prompt_history: std.ArrayList([]u8) = .empty,
prompt_history_index: ?usize = null,
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
/// Recent parent-lane messages captured when this lane was forked with
/// `/parallel` (oldest first) — context for the branch-naming request fired
/// on the lane's first submit. Owned; consumed by the naming job.
parent_context: [][]u8 = &.{},
/// The async branch-naming request (the lane starts on a `nova/<hex>` branch
/// and is renamed in place when the model's name lands). The future needs
/// `io` to cancel, so the App (not `deinit` here) is responsible for it.
naming_future: ?std.Io.Future(naming.BranchOutcome) = null,
naming_done: std.atomic.Value(bool) = .init(false),
/// Set on a lane spawned by the model via `lane spawn`: the `*Agent` that
/// spawned it (as `?*agent_mod.Agent`). Completion delivery routes to that
/// agent's lane; a spawner that is closed/abandoned first makes
/// `laneForAgent` return null and the delivery is dropped (M7). Never
/// dereferenced — only compared against live `lane.agent` pointers.
spawned_by_agent: ?*agent_mod.Agent = null,
/// Set by `lane read`/`await`/successful `merge` (M2): the orchestrator has
/// consumed the worker's result, so completion delivery appends only a terse
/// notice — no raw enqueue, no answer turn.
acknowledged: bool = false,
/// Set once a finished worker's completion has been delivered (or dropped).
/// Guards the park+deliver pass so it runs exactly once per worker.
completion_delivered: bool = false,

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
/// it down and removes it from the list. A live lane can be *rested* (S11): a
/// finished worker's runtime is freed and the engine downgraded to `.idle` —
/// the lane stays in the grid, its transcript intact, so `read`/`await`/`merge`
/// keep working on it.
pub const Engine = union(enum) {
    idle: vcs.Lane,
    live: Live,
};

/// Free everything this thread owns. For `.live`, that includes tearing down and
/// destroying the owned `AgentRuntime` — the lane is the runtime's owner.
pub fn deinit(self: *Thread, gpa: std.mem.Allocator) void {
    if (self.title) |title| gpa.free(title);
    for (self.parent_context) |message| gpa.free(message);
    if (self.parent_context.len > 0) gpa.free(self.parent_context);
    self.transcript.deinit(gpa);
    self.turn_view.deinit(gpa);
    for (self.queued.items) |*message| gpa.free(message.text);
    self.queued.deinit(gpa);
    for (self.prompt_history.items) |p| gpa.free(p);
    self.prompt_history.deinit(gpa);
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

/// Build a live lane `Thread` for `createParallelLane`: a worktree identity
/// (`branch`/`path`) plus the owned runtime driving it, carrying the
/// fork-time parent context. The moved fields (`branch`, `path`, `context`,
/// `runtime`) are adopted by the returned thread, so the caller keeps the
/// `errdefer`s that free/destroy them until this returns. Centralizes the
/// nested `.engine.live` literal so the lane-creation call site reads as
/// intent, not boilerplate.
pub fn initLive(
    id: session.SessionId,
    agent: *agent_mod.Agent,
    io: std.Io,
    runtime_gpa: std.mem.Allocator,
    context: [][]u8,
    branch: []u8,
    path: []u8,
    live_runtime: *runtime.AgentRuntime,
) Thread {
    return .{
        .id = id,
        .agent = agent,
        .worker_context = .{ .io = io, .gpa = runtime_gpa },
        .parent_context = context,
        .engine = .{ .live = .{
            .lane = .{ .working = .{ .branch = branch, .path = path } },
            .runtime = live_runtime,
            .owns = true,
        } },
    };
}

pub fn pushPromptHistory(self: *Thread, gpa: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return;
    if (self.prompt_history.items.len > 0) {
        const last = self.prompt_history.items[self.prompt_history.items.len - 1];
        if (std.mem.eql(u8, last, text)) {
            self.prompt_history_index = null;
            return;
        }
    }
    const dup = try gpa.dupe(u8, text);
    try self.prompt_history.append(gpa, dup);
    self.prompt_history_index = null;
}

pub const HistoryDirection = enum { up, down };

pub fn navigatePromptHistory(self: *Thread, direction: HistoryDirection) ?[]const u8 {
    if (self.prompt_history.items.len == 0) return null;
    const len = self.prompt_history.items.len;
    switch (direction) {
        .up => {
            if (self.prompt_history_index) |idx| {
                if (idx > 0) self.prompt_history_index = idx - 1;
            } else {
                self.prompt_history_index = len - 1;
            }
        },
        .down => {
            if (self.prompt_history_index) |idx| {
                if (idx + 1 < len) {
                    self.prompt_history_index = idx + 1;
                } else {
                    self.prompt_history_index = null;
                    return "";
                }
            } else {
                return null;
            }
        },
    }
    if (self.prompt_history_index) |idx| {
        return self.prompt_history.items[idx];
    }
    return null;
}

test "idle thread frees its owned title, transcript, and queue" {
    const gpa = std.testing.allocator;
    var thread: Thread = .{ .title = try gpa.dupe(u8, "feature x") };
    try thread.queued.append(gpa, .{ .text = try gpa.dupe(u8, "queued prompt") });

    try std.testing.expectEqualStrings("feature x", thread.title.?);
    try std.testing.expectEqual(@as(usize, 1), thread.queued.items.len);

    thread.deinit(gpa);
}

test "lane frees its captured parent context" {
    const gpa = std.testing.allocator;
    const context = try gpa.alloc([]u8, 2);
    context[0] = try gpa.dupe(u8, "fix the login race");
    context[1] = try gpa.dupe(u8, "I found the mutex issue");
    var thread: Thread = .{ .parent_context = context };

    try std.testing.expectEqual(@as(usize, 2), thread.parent_context.len);
    try std.testing.expectEqualStrings("fix the login race", thread.parent_context[0]);

    thread.deinit(gpa);
}

test "idle working lane frees its worktree branch and path" {
    const gpa = std.testing.allocator;
    var thread: Thread = .{ .engine = .{ .idle = .{ .working = .{
        .branch = try gpa.dupe(u8, "nova/x"),
        .path = try gpa.dupe(u8, "/home/user/.config/nova/worktrees/x"),
    } } } };

    try std.testing.expectEqualStrings("nova/x", thread.engine.idle.working.branch);
    try std.testing.expectEqualStrings("/home/user/.config/nova/worktrees/x", thread.engine.idle.working.path);

    thread.deinit(gpa);
}

test "prompt history navigation cycles through saved prompts" {
    const gpa = std.testing.allocator;
    var thread: Thread = .{};
    defer thread.deinit(gpa);

    try thread.pushPromptHistory(gpa, "first prompt");
    try thread.pushPromptHistory(gpa, "second prompt");

    try std.testing.expectEqualStrings("second prompt", thread.navigatePromptHistory(.up).?);
    try std.testing.expectEqualStrings("first prompt", thread.navigatePromptHistory(.up).?);
    try std.testing.expectEqualStrings("second prompt", thread.navigatePromptHistory(.down).?);
    try std.testing.expectEqualStrings("", thread.navigatePromptHistory(.down).?);
}
