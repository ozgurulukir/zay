//! Turn lifecycle and submission logic.
//! Free functions taking `*App` — extracted from `tui.zig`.

const std = @import("std");
const tui = @import("../tui.zig");
const agent_mod = @import("../agent.zig");
const agent_worker = @import("agent_worker.zig");
const turn_cancel = @import("turn_cancel.zig");
const lanes_util = @import("lanes.zig");
const lane_recovery = @import("lanes/recovery.zig");
const queue_mod = @import("queue.zig");
const checkpoint_mod = @import("checkpoint.zig");
const runtime_mod = @import("../runtime.zig");

const App = tui.App;
const Thread = tui.Thread;

const log = std.log.scoped(.turn_lifecycle);

pub fn handleInterrupt(app: *App) !void {
    if (app.thread.turn.state != .active) return;
    if (app.thread.cancel_job != null) return; // a reap is already in flight
    app.thread.worker_context.?.requestCancel();
    try projectCancelNotice(app, app.thread);
    app.thread.turn.interrupt();
    // Tear the worker down without blocking the UI: the future moves into a
    // background cancel job (see `beginTurnCancel`) whose `Future.cancel`
    // aborts the worker's blocking read and joins it. `.interrupting` keeps
    // the tick alive, and `drainTurnCancels` converges the turn (checkpoint +
    // queued-message restart) once the job reports the worker fully unwound —
    // starting a turn here would race the still-unwinding worker on the
    // shared agent history. When nothing is in flight (or the job could not
    // spawn) converge synchronously instead; the legacy path blocks the UI
    // once but can never strand the machine in `.interrupting`.
    if (beginTurnCancel(app)) return;
    discardAbandonedTurn(app, app.thread);
    _ = try startQueuedTurn(app, app.thread);
}

/// Project the interrupt onto the lane: the cancellation notice in the
/// transcript and `turn_failed` recording it, so a spawned worker's
/// completion delivery reports it honestly ("FAILED — Interrupted.") instead
/// of "final state: done". The event's copy is freed by `event.deinit`; the
/// second dupe is owned by `turn_failed` (cleared by the next turn's
/// `resetTurnState` — correct, a new turn is running).
fn projectCancelNotice(app: *App, lane: *Thread) !void {
    const message = try app.gpa.dupe(u8, agent_worker.cancel_message);
    var event: agent_mod.Agent.Event = .{ .turn_failed = message };
    defer event.deinit(app.gpa);
    _ = try lane.turn_view.apply(app.gpa, &lane.transcript, event);
    if (lane.turn_failed) |old| app.gpa.free(old);
    lane.turn_failed = app.gpa.dupe(u8, agent_worker.cancel_message) catch null;
}

/// Move the lane's turn future into a background `TurnCancelJob` and start it.
/// Returns false when the caller must converge synchronously: nothing was in
/// flight (a turn can be `.interrupting` with no worker — the test/headless
/// path), or the job could not be created (OOM / no task slots — the future is
/// restored first). The machine is left `.interrupting` on true.
fn beginTurnCancel(app: *App) bool {
    const thread = app.thread;
    const future = thread.turn_future orelse return false;
    std.debug.assert(thread.turn.state == .interrupting);
    std.debug.assert(thread.cancel_job == null);
    thread.turn_future = null;

    const job = app.gpa.create(turn_cancel.TurnCancelJob) catch {
        thread.turn_future = future;
        // The fallback blocks the UI for the unwind — the very freeze this
        // job exists to avoid. Rare (OOM), but it must leave a trail.
        log.warn("interrupt: async cancel job unavailable (OOM); converging synchronously", .{});
        return false;
    };
    job.* = .{ .io = app.getIo(), .future = future };
    thread.cancel_job = job;
    if (app.io.concurrent(turn_cancel.TurnCancelJob.run, .{job})) |task| {
        job.task = task;
        log.info("interrupt: async cancel job started", .{});
        return true;
    } else |_| {
        thread.cancel_job = null;
        app.gpa.destroy(job);
        thread.turn_future = future;
        log.warn("interrupt: async cancel task could not spawn; converging synchronously", .{});
        return false;
    }
}

pub fn discardAbandonedTurn(app: *App, lane: *Thread) void {
    if (lane.cancel_job != null) return; // the job owns the future
    if (lane.turn.state != .interrupting and lane.turn_future == null) return;
    if (lane.turn_future) |*future| {
        // `cancel` blocks until the task hits its next cancellation point
        // (typically the network read) and unwinds. On a healthy stream
        // this is near-instant; on a hung connection it forces the OS
        // read to abort. Only reached from synchronous callers (spawn
        // fallback, `lane cancel`, model switch) — ESC uses the async job.
        _ = future.cancel(app.getIo());
        lane.turn_future = null;
    }
    discardStrandedEvents(lane);
    if (lane.turn.state == .interrupting) lane.turn.reset();
}

/// Free everything still sitting in a joined worker's event queue. The worker
/// keeps pushing until the cancel lands, so this must only run after the
/// worker is joined (cancel job done, or a synchronous `future.cancel`).
fn discardStrandedEvents(lane: *Thread) void {
    if (lane.worker_context) |*worker| worker.queue.discardAll(worker.io, worker.gpa);
}

/// Tick drain: converge every lane whose async interrupt teardown finished.
/// Returns true when visible state changed. Safe against both convergence
/// orderings — the worker's terminal `turn_finished` may land through
/// `applyAgentEvent` while the job is still unwinding (machine goes idle and
/// `reset` here is skipped), or be dropped by the cancel gate (machine stays
/// `.interrupting` and `reset` closes the window).
pub fn drainTurnCancels(app: *App) !bool {
    var changed = false;
    for (app.threads.slice()) |lane| {
        const job = lane.cancel_job orelse continue;
        if (!job.done.load(.acquire)) continue;
        lane.cancel_job = null;
        std.debug.assert(lane.turn_future == null); // the job owns the moved future
        // `done` is stored last, so the task is finished here and the await
        // only releases its frame.
        job.task.await(app.io);
        app.gpa.destroy(job);
        changed = true;

        discardStrandedEvents(lane);
        if (lane.turn.state == .interrupting) {
            // The cancel gate dropped the worker's terminal event (the
            // machine never saw `turn_finished`) — close the window here.
            log.info("interrupt: cancel gate dropped the terminal event; resetting machine", .{});
            lane.turn.reset();
        }
        if (try convergeFinishedTurn(app, lane)) changed = true;
    }
    return changed;
}

/// Whether any lane has an interrupt teardown still in flight — a tick reason,
/// so the loop survives the window where the machine already went idle (the
/// worker's terminal event drained) but the job has not been joined yet.
pub fn turnCancelActive(app: *App) bool {
    for (app.threads.slice()) |lane| {
        if (lane.cancel_job != null) return true;
    }
    return false;
}

/// Start a turn from the current input — the full submit+spawn front door.
/// Returns true when a worker was spawned (the caller should keep the tick
/// alive); false when the prompt was empty, had no provider, was refused
/// (manual compact / idle lane), or was queued behind a running turn.
pub fn beginSubmit(app: *App) !bool {
    app.closeAtSearch();
    app.clearBlockNav();
    // An in-flight turn — including `.interrupting` and the post-idle window
    // where the async teardown is still unwinding the worker — refuses a new
    // worker: two concurrent workers would race the shared agent message
    // history. Queue behind it; `drainTurnCancels` restarts the turn with
    // the queue once the worker is joined.
    if (app.thread.turn.isActive() or app.thread.cancel_job != null) return try app.enqueueSubmit();
    // A manual `/compact` is mid-flight on this lane: the summarizer will swap
    // the context on the UI thread, so starting a turn now would race that
    // reload. Keep the input — the user can submit once the notice lands.
    if (app.thread.agent) |agent| {
        if (agent.manualCompactPending()) {
            _ = try app.thread.transcript.append(app.gpa, .notice, "compaction", "Compaction in progress — wait for the summary before submitting.");
            return false;
        }
    }
    // C1: an idle lane (from `lane create` or a rested worker) has no
    // worker_context — submitting here would deref null at the
    // `resetCancel`/`dupe` sites below. Refuse through the shared gate with
    // a guiding notice instead of crashing. The guard is before
    // `toOwnedSlice` so the user's typed input is preserved (TD-2).
    if (app.thread.worker_context == null) {
        lanes_util.appendIdleLaneNotice(app);
        return false;
    }
    const prompt = try app.inputs.input.toOwnedSlice();
    defer app.gpa.free(prompt);
    if (prompt.len == 0) return false;
    try app.thread.pushPromptHistory(app.gpa, prompt);
    if (app.liveRuntime()) |rt| rt.session_writer.savePromptHistory(prompt) catch {};

    if (app.liveRuntime() != null and app.liveRuntime().?.client == .none) {
        app.thread.transcript.dropIntroLogo(app.gpa);
        _ = try app.thread.transcript.append(app.gpa, .user, "you", prompt);
        const message = try formatNoProviderMessage(app);
        defer app.gpa.free(message);
        _ = try app.thread.transcript.append(app.gpa, .agent, "agent", message);
        return false;
    }

    // THE one worker-allocator copy: every projection below borrows it, and
    // it is handed to the spine (the caller frees it if the spawn fails).
    const worker_prompt = try app.thread.worker_context.?.gpa.dupe(u8, prompt);
    errdefer app.thread.worker_context.?.gpa.free(worker_prompt);
    app.thread.transcript.dropIntroLogo(app.gpa);
    _ = try app.thread.transcript.append(app.gpa, .user, "you", worker_prompt);
    // A worktree lane's first prompt also names its branch: ask the model
    // in parallel, and rename the hex branch when the answer lands.
    if (app.thread.title == null and lanes_util.workingLaneOf(app.thread) != null) {
        app.scheduleLaneNaming(app.thread, worker_prompt) catch {};
    }
    try setLaneTitleIfUnset(app, app.thread, worker_prompt);
    try queue_mod.appendSkillInvocationsToTranscript(app, app.thread, worker_prompt);
    try spawnTurn(app, app.thread, .{ .prompt = worker_prompt });
    return true;
}

/// Label the lane by its first user prompt (one line, truncated) so split
/// tiles read as the session, not a generic "lane". Owned; freed in deinit.
pub fn setLaneTitleIfUnset(app: *App, lane: *Thread, prompt: []const u8) !void {
    if (lane.title != null) return;
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0) return;
    const line_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    const line = std.mem.trim(u8, trimmed[0..line_end], " \t\r");
    if (line.len == 0) return;
    const max: usize = 40;
    if (line.len <= max) {
        lane.title = try app.gpa.dupe(u8, line);
    } else {
        var cut: usize = max;
        while (cut > 0 and (line[cut] & 0xC0) == 0x80) cut -= 1;
        lane.title = try std.fmt.allocPrint(app.gpa, "{s}…", .{line[0..cut]});
    }
    // Keep the manifest title in step (best-effort): a crash-restored lane
    // shows this label until branch naming lands. No-op for the primary.
    lane_recovery.syncLaneUpdated(app, lane);
}

pub fn formatNoProviderMessage(app: *App) ![]u8 {
    if (app.liveRuntime()) |rt| {
        for (rt.diagnostics) |d| {
            switch (d) {
                .config_parse_error => |e| return std.fmt.allocPrint(
                    app.gpa,
                    "Failed to load {s}: {s}",
                    .{ e.path, e.reason },
                ),
                .bad_env_model => |raw| return std.fmt.allocPrint(
                    app.gpa,
                    "Invalid OPENAI_MODEL: expected <provider>/<model>, got '{s}'",
                    .{raw},
                ),
            }
        }
    }
    if (app.cached_config.model_selection) |ms| {
        const p = ms.provider();
        if (p.adapter() == null) {
            return std.fmt.allocPrint(
                app.gpa,
                "Provider '{s}' is not yet supported in Zay.",
                .{p.label()},
            );
        }
        if (p == .openai) {
            if (app.liveRuntime()) |rt| {
                if (rt.codex_connection_expired) return app.gpa.dupe(u8, runtime_mod.codex_connection_expired_message);
            }
            return app.gpa.dupe(u8, "No OpenAI Codex session — type /connect to sign in.");
        }
    }
    return app.gpa.dupe(
        u8,
        "No provider connected. Type /connect to pick one, or set OPENAI_MODEL=<provider>/<model>.",
    );
}

pub fn resetTurnState(app: *App, lane: *Thread) void {
    lane.turn_view.reset(app.getIo());
    app.metrics.loading_frame = 0;
    // A fresh turn invalidates the previous turn's failure record.
    if (lane.turn_failed) |old| {
        app.gpa.free(old);
        lane.turn_failed = null;
    }
    // Turn-start bookkeeping for the model-driven `lane` ops: a fresh turn
    // has made no progress yet, so anchor the activity clock now (a worker
    // is legitimately silent while its first model request is in flight)
    // and reset the tool-call tally + stall-warning latch.
    lane.last_activity_ms = std.Io.Clock.now(.awake, app.getIo()).toMilliseconds();
    lane.turn_tool_calls = 0;
    lane.stall_warned = false;
}

/// The one turn-spawn sequence every starter shares: reset the turn
/// bookkeeping (spinner word, `turn_failed`, activity clock, tool tally),
/// clear any stale worker cancel flag, free a stranded prompt, flip the view
/// to awaiting-model, submit the machine, and start the worker future.
/// `opts.prompt` must be allocated on the lane worker's allocator; the CALLER
/// owns it until the spawn succeeds — on failure the spine only clears the
/// slot claim, and the caller's errdefer frees. After a successful spawn the
/// worker consumes and frees it.
const SpawnOpts = struct {
    /// Allocated on the lane worker's allocator. Caller-owned until the
    /// spawn succeeds; the spine never frees it.
    prompt: ?[]u8 = null,
    /// Deliver the agent's queued messages as context + the latest user turn
    /// instead of a fresh prompt.
    drain_queue_first: bool = false,
};

fn spawnTurn(app: *App, lane: *Thread, opts: SpawnOpts) !void {
    resetTurnState(app, lane);
    lane.worker_context.?.resetCancel();
    // Free any prompt left over from a failed spawn (the window is
    // theoretical — the spawn is the last step — but the cleanup costs
    // nothing).
    lane.worker_context.?.pending_prompt.freeStale(lane.worker_context.?.gpa);
    lane.turn_view.awaitModel();
    lane.turn.submit();
    if (opts.prompt) |prompt| lane.worker_context.?.pending_prompt.set(prompt);
    // Drop the slot's claim WITHOUT freeing on spawn failure: the bytes are
    // still the caller's, and its errdefer frees them exactly once.
    errdefer lane.worker_context.?.pending_prompt.slot = null;
    lane.turn_future = try app.getIo().concurrent(agent_worker.runAgentTurn, .{
        lane.agent.?,
        lane.liveRuntime(),
        &lane.worker_context.?,
        opts.drain_queue_first,
    });
}

/// Drain a lane's queued messages as a fresh turn — the shared contract of
/// the ESC restart and the background completion delivery: the worker drains
/// the whole queue into history (leading messages as context, the last as
/// the latest user message the model answers), so no prompt is handed over.
/// Gated on the AGENT queue, not the UI mirror: the mirror can legitimately
/// be empty while the agent queue is full (a QueueFull drop), and the
/// no-provider cleanup below must still run to clear it. Returns false when
/// nothing is queued. Without a connected provider the queue is surfaced in
/// the transcript and dropped rather than spinning up a doomed worker.
pub fn startQueuedTurn(app: *App, lane: *Thread) !bool {
    // A parked lane (agent nulled by the park) has nothing to drain — the
    // background-delivery path can reach here after `parkFinishedWorker`.
    const agent = lane.agent orelse return false;
    if (agent.message_queue.len() == 0) return false;
    if (lane.liveRuntime() != null and lane.liveRuntime().?.client == .none) {
        // Flush the mirror first so it stays 1:1 with the cleared agent
        // queue (raw entries are dropped unrendered; a stray mirror entry
        // would shift every `steerSelectedQueued` index).
        try queue_mod.flushQueuedUserMessagesToTranscript(app, lane, @intCast(lane.queued.items.len));
        agent.clearQueue();
        return true;
    }
    try spawnTurn(app, lane, .{ .drain_queue_first = true });
    return true;
}

/// Close out a finished turn: snapshot the lane's working tree and deliver
/// anything queued behind it as a fresh turn. Shared by the worker-event
/// path and the async-cancel drain so the two convergence orderings cannot
/// drift.
pub fn convergeFinishedTurn(app: *App, lane: *Thread) !bool {
    checkpoint_mod.checkpointFinishedTurn(app, lane);
    return startQueuedTurn(app, lane);
}

/// Start a turn on `lane` with `prompt` (duped into the lane worker's
/// allocator). The model-driven spawn path: the task is appended to the
/// lane's transcript, the lane gets a title + branch naming, and the worker
/// starts on its own thread. Title and naming derive from `title_source`
/// (the raw task), not the framed prompt — the role framing would otherwise
/// become the lane's visible label.
pub fn startTurnForLane(app: *App, lane: *Thread, prompt: []const u8, title_source: []const u8) !void {
    const owned = try lane.worker_context.?.gpa.dupe(u8, prompt);
    // The caller frees `owned` if `spawnTurn` fails; the worker consumes it
    // on success.
    errdefer lane.worker_context.?.gpa.free(owned);
    lane.transcript.dropIntroLogo(app.gpa);
    _ = try lane.transcript.append(app.gpa, .user, "you", prompt);
    // Title + naming helpers take the lane explicitly — no scope-swap.
    setLaneTitleIfUnset(app, lane, title_source) catch {};
    if (lanes_util.workingLaneOf(lane) != null) {
        app.scheduleLaneNaming(lane, title_source) catch {};
    }
    // The spine's `resetCancel` is a no-op on a fresh worker context and its
    // stale-prompt free is a no-op on a fresh lane; `spawnTurn` submits and
    // starts the worker.
    try spawnTurn(app, lane, .{ .prompt = owned });
}

/// `lane cancel {lane}`: two-phase interrupt of a target lane's turn (S10),
/// the synchronous twin of `handleInterrupt`. `requestCancel` alone only
/// takes effect at the worker's next `emit`; between stream chunks (and for
/// the whole duration of a running tool) the worker is blocked in a read and
/// emits nothing — so the future is force-cancelled and the turn reset
/// UI-side. Synchronous because the bridge handler acknowledges the cancel
/// to the orchestrator only after the turn is torn down.
pub fn cancelLaneTurn(app: *App, lane: *Thread) void {
    // An ESC interrupt's async teardown is already unwinding this worker;
    // its `drainTurnCancels` convergence covers everything below.
    if (lane.cancel_job != null) return;
    if (lane.turn.state != .active and lane.turn.state != .interrupting) return;
    if (lane.worker_context) |*worker| worker.requestCancel();
    // An OOM while projecting aborts before the discard: the worker keeps
    // running with `requestCancel` set, so a retry (ESC / `lane cancel`)
    // converges instead of leaving the lane stuck.
    projectCancelNotice(app, lane) catch return;
    if (lane.turn.state == .active) lane.turn.interrupt();
    discardAbandonedTurn(app, lane);
}

pub fn applyAgentEvent(app: *App, lane: *Thread, event: agent_mod.Agent.Event) !bool {
    const outcome = lane.turn.apply(event);
    // Any event the worker emitted means it is alive — stamp the activity
    // clock `lane read`/`await`/`list` use to detect a stalled worker (one
    // blocked in a hung read emits nothing), clear the stall-warning latch
    // (progress resumed), and tally tool calls.
    lane.last_activity_ms = std.Io.Clock.now(.awake, app.getIo()).toMilliseconds();
    lane.stall_warned = false;
    switch (event) {
        .tool_call_finished => lane.turn_tool_calls += 1,
        .turn_started => lane.turn_tool_calls = 0,
        .turn_failed => |message| {
            // Record why the turn failed (the same text lands in the
            // transcript as a notice). Spawned-worker completion delivery
            // reads this so a failed worker isn't reported as "done"; a new
            // turn on the lane resets it.
            if (lane.turn_failed) |old| app.gpa.free(old);
            lane.turn_failed = try app.gpa.dupe(u8, message);
        },
        else => {},
    }
    if (!outcome.project) {
        // Interrupting: a discarded turn's output must not mutate the
        // transcript. The terminal event moved the machine to idle; the join,
        // checkpoint, and queued-message restart happen in `drainTurnCancels`
        // once the async cancel job reports the worker fully unwound — the
        // future is owned by the job, so the UI thread must not await it here.
        // The fallback (no job) is a synchronously-interrupted lane: converge
        // immediately, as `handleInterrupt`'s legacy path does.
        if (outcome.finished) {
            if (lane.cancel_job != null) return false;
            app.awaitTurnFor(lane);
            return try convergeFinishedTurn(app, lane);
        }
        return false;
    }
    var visible_change = try lane.turn_view.apply(app.gpa, &lane.transcript, event);
    switch (event) {
        .queued_messages_flushed => |count| {
            if (count > 0 and lane.queued.items.len > 0) {
                try queue_mod.flushQueuedUserMessagesToTranscript(app, lane, count);
                visible_change = true;
            }
        },
        else => {},
    }
    if (outcome.finished) {
        app.awaitTurnFor(lane);
        checkpoint_mod.checkpointFinishedTurn(app, lane);
        if (lane.queued.items.len > 0) {
            queue_mod.clearQueuedUserMessages(app, lane);
            visible_change = true;
        }
    }
    return visible_change;
}
