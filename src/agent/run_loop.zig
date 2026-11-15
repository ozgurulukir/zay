//! Agent run-loop spoke, extracted from agent.zig (issue #367 slice 14).
//! Owns the turn loop: `run` (the while-hasCapacity iteration — prompt,
//! stream observation, text tool-call recovery, finalization dispatch,
//! tool-batch execution, queue steering), the pure finalization policy
//! (`TurnFinalizationOutcome` + `runTurnFinalizationOutcome`, issue #340),
//! the budget/length recovery arms (`softStopOnBudget`, `handleLengthCut`),
//! the unresolved-tool-call pairing (`reconcileUnresolvedToolCalls`, shared
//! with agent.zig's `reconcileInterruptedToolCalls`), and the wire-content
//! check + assistant-message takeover they use.
//!
//! The `Agent` TYPE and all of its state stay in agent.zig; this file
//! imports agent.zig only for the type. Spoke pattern (agent/queue_ops.zig,
//! agent/text_recovery.zig): free functions over `*Agent`; mutual import
//! terminates at the type level; agent.zig keeps an unchanged-signature
//! delegate for `run` and a `hasWireContent` re-export for its tests.
//! Log scope stays `.agent`, identical to agent.zig.

const std = @import("std");
const log = std.log.scoped(.agent);
const assert = std.debug.assert;

const agent_mod = @import("../agent.zig");
const compaction_ops = @import("compaction_ops.zig");
const ai = @import("../ai.zig");
const context_assembly = @import("../context/assembly.zig");
const stream_context_mod = @import("stream_context.zig");
const turn_budget_mod = @import("turn_budget.zig");
const queue_ops = @import("queue_ops.zig");
const skill_ops = @import("skill_context_ops.zig");
const text_recovery = @import("text_recovery.zig");
const tool_batch = @import("tool_batch.zig");
const message_ops = @import("message_ops.zig");

const Agent = agent_mod.Agent;

/// Injected when the provider severed the tool_call section (name+id arrived,
/// arguments never streamed — intern-ai/internlm gateway truncation). The
/// model's request is NOT executed, so the model must re-emit the call with
/// its arguments intact. The consumer sees this as a normal user message.
const tool_call_truncation_hint =
    "[zay] Your tool call(s) arrived without their arguments — or no tool call " ++
    "arrived at all despite your finish reason. The provider truncated the " ++
    "tool_call section before the arguments payload streamed. " ++
    "The call was not executed. Re-emit the SAME tool call(s) with full arguments " ++
    "in a single request; avoid sending many parallel tool calls at once if " ++
    "truncation persists.";
/// Result text recorded for a tool call the user interrupted before it
/// finished — surfaced to the model so it knows the call was cancelled.
pub const interrupted_tool_result = "The user interrupted the turn before this tool call completed; it produced no result.";
pub const budget_skipped_tool_result = "This tool call was not run because the per-turn tool-call budget was exhausted.";

/// Turn-finalization policy for `run` (issue #340): what a completed
/// model turn becomes. The decision order IS the recovery policy — the
/// user's queued message takes the turn before any automatic wire-shape
/// recovery (drain beats retry), then the one-shot truncation retry,
/// then the length-cut continuation. This order must never be reordered.
pub const TurnFinalizationOutcome = enum {
    /// Tool calls parsed or recovered: dispatch the batch.
    dispatch,
    /// A queued user message is waiting: drain it and continue the loop
    /// with it as the next prompt.
    continue_after_queued_drain,
    /// Provider-severed tool_call section with the one-shot retry still
    /// unspent: inject the hint and re-request.
    retry_truncation_hint,
    /// The one-shot truncation retry is already spent: end the run.
    retry_exhausted_stop,
    /// `finish_reason=length` with no tool calls: run the length-cut
    /// policy (`handleLengthCut` owns its side effects — the history
    /// write on auto-continue, the `.stopped` emit otherwise).
    length_cut_pending,
    /// Nothing left to recover from: end the turn.
    end_turn,
};

/// Pure turn-finalization decision for `run`. No side effects: reads
/// only its arguments and returns the outcome; `run` performs it —
/// the warns, emits, history writes, and one-shot flag flips stay in
/// the parent.
fn runTurnFinalizationOutcome(
    finish_reason: ?ai.FinishReason,
    calls_present: bool,
    queued_message_waiting: bool,
    calls_truncated: u32,
    truncation_retried: bool,
) TurnFinalizationOutcome {
    if (calls_present) return .dispatch;
    if (queued_message_waiting) return .continue_after_queued_drain;
    // Provider-severed tool_call arguments (name+id arrived, the
    // arguments payload never streamed). The parser dropped the calls,
    // so nothing dispatched. The fully-severed shape
    // (`finish_reason=tool_calls`, zero calls parsed or recovered) sets
    // no `tool_calls_truncated` count — the parser saw nothing to drop;
    // cover it under the same one-shot retry so the warn-only path
    // doesn't strand the turn.
    if (calls_truncated > 0 or finish_reason == .tool_calls) {
        if (!truncation_retried) return .retry_truncation_hint;
        return .retry_exhausted_stop;
    }
    if (finish_reason == .length) return .length_cut_pending;
    return .end_turn;
}

pub fn run(self: *Agent, listener: anytype) !void {
    // Keep the loaded plugin generation alive through the entire turn,
    // including model waits and gaps between tool batches.
    if (self.plugin_manager) |manager| try manager.beginUse();
    defer if (self.plugin_manager) |manager| manager.endUse();
    // The listener's `ctx` field is `*Ctx`; extract `Ctx` (the pointee
    // type) so `Listener(Ctx)` matches the struct the caller built.
    const Ctx = @typeInfo(@TypeOf(listener.ctx)).pointer.child;
    const L = Agent.Listener(Ctx);
    const l: L = listener;
    try l.emit(.turn_started);
    var tool_calls_executed: u32 = 0;
    var iterations: u32 = 0;
    // One-shot guard: a single automatic length-cut continuation per run,
    // so a pathologically capping endpoint cannot loop extra billed
    // requests (the C2 `downgrade_done` idiom from the wire client).
    var length_continued = false;
    // Same one-shot for provider-severed tool-call arguments: if the
    // endpoint keeps truncating, retry exactly once then fail the turn
    // instead of billing an unbounded retry loop.
    var truncation_retried = false;
    var turn_arena = std.heap.ArenaAllocator.init(self.gpa);
    defer turn_arena.deinit();

    while (self.turn_budget.hasCapacity(iterations, tool_calls_executed)) {
        iterations += 1;
        _ = turn_arena.reset(.retain_capacity);
        const turn_allocator = turn_arena.allocator();

        try self.persistSkillContext();
        try skill_ops.emitPendingInventory(self, L, l);
        compaction_ops.maybeCompact(self, l);
        var stream_context: stream_context_mod.StreamContext(L) = .{
            .gpa = self.gpa,
            .listener = l,
        };
        defer stream_context.deinit();
        const prompt_messages = try context_assembly.pruneHistoricalToolResultsViewsWithSkills(
            self.gpa,
            &self.tool_view_cache,
            self.messages(),
            self.compaction_settings.keep_recent_tool_turns,
            self.compaction_settings.tool_output_cap_bytes,
            &self.skill_context,
        );
        defer context_assembly.freePrunedViews(self.gpa, prompt_messages);
        // #122: evict images from OLDER user messages into re-mention
        // stubs before serialization — the newest user message keeps its
        // images, the cache prefix stays stable afterwards, and the
        // `defer freePrunedViews` above releases the owned stub copies.
        if (self.compaction_settings.evict_history_images) {
            try context_assembly.evictHistoryImagesViews(self.gpa, prompt_messages);
        }

        // A permit is held only for the request itself (not across tool
        // execution), so a long bash call on one lane never head-of-line
        // blocks another lane's next request. Retries inside `prompt` hold
        // the permit too, so lanes can't retry-burst the provider together.
        const limiter = self.request_limiter;
        var turn = blk: {
            if (limiter) |lim| try lim.acquire(self.io);
            defer if (limiter) |lim| lim.release(self.io);
            break :blk try self.client.prompt(prompt_messages, stream_context.observer());
        };
        // End-of-stream flush: emit any trailing coalesced bytes as their
        // respective events BEFORE the assistant message is finalized
        // (`takeAssistantMessage` below) / the tool batch is dispatched
        // (`runToolBatch`). This must preserve wire order: a trailing
        // content delta after a tool delta would otherwise be flushed by
        // the scope-exit `stream_context.deinit()` AFTER
        // `tool_call_finished`, reordering the event queue.
        try stream_context.flushPending();
        // Hoisted before the ownership branch: `Turn.deinit` sets
        // `self.* = undefined`, and the no-wire-content branch (a
        // reasoning-only response cut before any prose) leaves the turn
        // owned — the `defer` below deinits it at scope exit — so the
        // length branch below must read the scalar, not the undefined
        // struct.
        const finish_reason = turn.finish_reason;
        const usage = turn.usage;
        // Hoisted for the same reason as the two above: the
        // no-wire-content branch deinits the turn at scope exit, and the
        // truncation guard below reads this scalar after that.
        const tool_calls_truncated = turn.tool_calls_truncated;
        var turn_owned = true;
        defer if (turn_owned) turn.deinit(self.gpa);

        const tool_calls_initial = try text_recovery.collectToolCallsAlloc(self, turn_allocator, turn.assistant);
        defer turn_allocator.free(tool_calls_initial);

        // T3: recover tool calls the model emitted as literal text (weak
        // function-calling models do this). Only when there were zero
        // structured calls, and only over the assistant's text blocks —
        // never mid-stream. Runs BEFORE takeAssistantMessage so the
        // recovered calls are persisted (turn.assistant is still live and
        // owned by the turn here). See plan §1.1, §2.2.
        var recovered: []ai.ToolCall = &.{};
        if (tool_calls_initial.len == 0) {
            recovered = try text_recovery.recoverTextToolCalls(self, &turn.assistant);
        }
        // Ownership: when recovered.len > 0 the payloads were MOVED into
        // the message's new blocks by injectRecoveredToolCalls; the
        // `recovered` slice shell itself is freed here, but NOT its
        // element strings (they were moved). When recovery didn't fire,
        // recovered is &.{} (empty literal, nothing to free).
        defer if (recovered.len > 0) self.gpa.free(recovered);
        if (recovered.len > 0) {
            try text_recovery.injectRecoveredToolCalls(self, &turn.assistant, recovered);
        }
        // The slice that drives execution. When recovery fired, execution
        // runs the recovered calls; otherwise it runs the structured ones.
        // Both `tool_calls_initial` and `recovered` are freed by their
        // defers at scope end; execution (runToolBatch) completes before
        // that, and runToolBatch copies the ToolCall values into the
        // executor before returning, so neither slice is read post-free.
        const tool_calls: []const ai.ToolCall = if (recovered.len > 0) recovered else tool_calls_initial;
        // The provider signalled "ended with tool calls" but none parsed
        // or was recovered from text — the tool_call section was severed
        // mid-flight. Without this the failure hides behind a
        // text-only assistant message (the "half-finished tool call"
        // incident signature).
        if (finish_reason == .tool_calls and tool_calls.len == 0) {
            log.warn("finish_reason=tool_calls but no tool call parsed or recovered — tool_call section likely truncated by the provider", .{});
        }

        // Ownership: a turn with wire content is MOVED into history by
        // `takeAssistantMessage`, so the turn is no longer ours to free.
        // A turn WITHOUT wire content (a reasoning-only response cut
        // before any prose) stays owned — the `defer` above frees it at
        // scope exit. Either way exactly one owner frees the message.
        if (turn.assistant == .assistant and hasWireContent(turn.assistant)) {
            try takeAssistantMessage(self, &turn.assistant);
            turn_owned = false;
        }
        // Anchor after the assistant reply is in history: `usage` accounts
        // for everything up to and including it; later appends are trailing.
        compaction_ops.recordUsage(self, usage);

        // Turn finalization (issue #340): one pure policy read decides
        // what this turn becomes; every side effect below stays in the
        // parent. The decision order — queued drain, then truncation
        // retry, then length-cut — is the recovery policy; see
        // `runTurnFinalizationOutcome`.
        var finalization = runTurnFinalizationOutcome(
            finish_reason,
            tool_calls.len > 0,
            queue_ops.hasQueuedMessages(self),
            tool_calls_truncated,
            truncation_retried,
        );
        if (finalization == .continue_after_queued_drain) {
            try skill_ops.emitPendingInventory(self, L, l);
            // Turn would otherwise go idle: drain the front queued message
            // (steer or not) and continue, so anything still waiting is
            // handled at the natural turn end. The user's queued message
            // takes precedence over the automatic continuations below.
            const drained_count = try queue_ops.drainQueuedUserMessage(self, false);
            if (drained_count > 0) {
                try l.emit(.{ .queued_messages_flushed = drained_count });
                continue;
            }
            // The queue emptied between the presence read and the drain
            // (a concurrent `clearQueue`, or a lost mutex lock): the
            // drain no longer owns the turn, so re-decide without it
            // and let the wire-shape recovery below run.
            finalization = runTurnFinalizationOutcome(finish_reason, false, false, tool_calls_truncated, truncation_retried);
        }
        if (finalization != .dispatch) {
            try skill_ops.emitPendingInventory(self, L, l);
        }
        switch (finalization) {
            .dispatch => {},
            .continue_after_queued_drain => unreachable, // re-decided above
            .retry_truncation_hint => {
                // Tell the model its arguments were truncated and retry
                // ONCE (bounded like the length-cut auto-continue) — a
                // pathological endpoint cannot bill an unbounded retry
                // loop. The two warns cover the same condition with
                // different messages; do not merge them.
                if (tool_calls_truncated > 0) {
                    log.warn("tool_call arguments truncated by provider ({d} calls dropped) — retrying once with hint", .{tool_calls_truncated});
                } else {
                    log.warn("finish_reason=tool_calls with no tool call parsed or recovered — retrying once with hint", .{});
                }
                truncation_retried = true;
                try self.addUser(tool_call_truncation_hint);
                continue;
            },
            .retry_exhausted_stop => {
                log.warn("tool_call arguments truncated by provider on retry — ending turn", .{});
                try l.emit(.{ .length_cut = .stopped });
                return;
            },
            .length_cut_pending => {
                // A provider output-token cap severed the response before the
                // tool_call section (observed: prose announcing an action,
                // then a clean close). If the partial prose is already in
                // history (`takeAssistantMessage` ran above), the wire
                // shape for the continuation stays [.., assistant, user-hint].
                // If there was no wire content (e.g. reasoning-only tokens cut
                // before prose), inject an assistant placeholder so the wire
                // shape remains valid.
                if (self.turn_budget.auto_continue_on_length_cut and !length_continued) {
                    try ensureAssistantBeforeContinuation(self, turn_owned);
                }
                if (try handleLengthCut(self, l, length_continued)) {
                    length_continued = true;
                    continue;
                }
                return;
            },
            .end_turn => return,
        }
        if (self.tool_access == .none) return error.ToolAccessDenied;
        const calls_remaining: usize = self.turn_budget.callsRemaining(tool_calls_executed);
        const calls_to_dispatch = @min(tool_calls.len, calls_remaining);
        const batch_exceeds_budget = calls_to_dispatch < tool_calls.len;
        const end_turn = try tool_batch.runToolBatch(L, self, tool_calls[0..calls_to_dispatch], &stream_context, l, turn_allocator);
        try skill_ops.emitPendingInventory(self, L, l);
        tool_calls_executed += @intCast(calls_to_dispatch);
        if (batch_exceeds_budget) {
            try reconcileUnresolvedToolCalls(self, budget_skipped_tool_result, "budget");
            if (self.turn_budget.soft_stop_on_tool_call_limit) return softStopOnBudget(self, l, tool_calls_executed, iterations);
            return error.ToolCallLimit;
        }
        if (end_turn) return;
        // Mid-turn we only inject messages explicitly marked to steer, and
        // only from the front so FIFO order holds — a default-queued
        // message ahead of a steer one keeps it waiting for turn end.
        var steered: u32 = 0;
        while ((try queue_ops.drainQueuedUserMessage(self, true)) > 0) steered += 1;
        if (steered > 0) try l.emit(.{ .queued_messages_flushed = steered });
    }
    // Budget exhausted: soft stop ends the turn gracefully (drain + hint +
    // event); hard stop keeps the historical error contract byte-for-byte.
    if (self.turn_budget.soft_stop_on_tool_call_limit) return softStopOnBudget(self, l, tool_calls_executed, iterations);
    return error.ToolCallLimit;
}

/// Graceful budget exhaustion: deliver everything the user queued mid-run
/// (a queued "continue" must land in history, not be cleared at turn
/// end), leave the continuation hint as the trailing message, and report
/// the stop through the event stream. Always terminates the run — no
/// auto-resume, so the budget stays a per-run bound (TD-6: continuation
/// is the user's next submit).
pub fn softStopOnBudget(self: *Agent, listener: anytype, tool_calls_executed: u32, iterations: u32) !void {
    log.warn("turn budget reached after {d} tool calls in {d} model iterations (limit {d}); soft-stopping", .{ tool_calls_executed, iterations, self.turn_budget.tool_call_limit_per_turn });
    const drained = try queue_ops.drainAllQueuedToHistory(self);
    if (drained > 0) try listener.emit(.{ .queued_messages_flushed = drained });
    try self.addUser(turn_budget_mod.tool_budget_continuation_hint);
    try listener.emit(.{ .tool_budget_exhausted = self.turn_budget.tool_call_limit_per_turn });
}

/// React to a response severed by the provider's output token cap
/// (`finish_reason=length`, no tool calls). Returns true when the caller
/// must continue the run (the one-shot auto-continue fired: a hint was
/// appended, the model gets re-requested); false when the turn should
/// end (knob off, or the one-shot was already used this run) — the event
/// still fires so the TUI renders a resumable notice instead of the cut
/// passing as a complete answer.
pub fn handleLengthCut(self: *Agent, listener: anytype, already_continued: bool) !bool {
    if (!self.turn_budget.auto_continue_on_length_cut or already_continued) {
        log.warn("turn ended on finish_reason=length with no tool calls — output token cap severed the response; not auto-continuing", .{});
        try listener.emit(.{ .length_cut = .stopped });
        return false;
    }
    log.warn("response cut by the output token cap (finish_reason=length, no tool calls) — auto-continuing once", .{});
    try listener.emit(.{ .length_cut = .auto_continued });
    try self.addUser(turn_budget_mod.length_cut_continuation_hint);
    return true;
}

/// Pair unresolved assistant tool calls with an explicit result when work
/// was not dispatched, keeping the provider conversation protocol valid.
pub fn reconcileUnresolvedToolCalls(self: *Agent, result_text: []const u8, display_label: []const u8) !void {
    const history = self.context_manager.items();

    var resolved = std.StringHashMap(void).init(self.gpa);
    defer resolved.deinit();
    try resolved.ensureTotalCapacity(@intCast(history.len));
    for (history) |message| {
        switch (message) {
            .tool => |t| try resolved.put(t.call_id.slice(), {}),
            else => {},
        }
    }

    // Copy the unmatched ids out before appending — `appendPersisted` may
    // realloc the message array, invalidating slices into it.
    var missing: std.ArrayList([]u8) = .empty;
    defer {
        for (missing.items) |id| self.gpa.free(id);
        missing.deinit(self.gpa);
    }
    for (history) |message| {
        switch (message) {
            .assistant => |a| {
                for (a.content) |block| {
                    if (block != .tool_call) continue;
                    if (resolved.contains(block.tool_call.call_id.slice())) continue;
                    try missing.append(self.gpa, try self.gpa.dupe(u8, block.tool_call.call_id.slice()));
                }
            },
            else => continue,
        }
    }

    for (missing.items) |id| {
        const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
        errdefer self.gpa.free(blocks);
        blocks[0] = .{ .text = .{ .text = try self.gpa.dupe(u8, result_text) } };
        try self.context_manager.appendPersisted(.{
            .tool = .{
                .content = blocks,
                .call_id = .{ .value = try self.gpa.dupe(u8, id) },
                .display_label = try self.gpa.dupe(u8, display_label),
                .failed = true,
            },
        });
    }
}

/// True when the assistant message carries content the chat-completions wire
/// format can represent: non-empty text or a tool call. Reasoning blocks are
/// dropped by the serializer, so a reasoning-only message would go out as
/// empty content with no tool_calls — rejected by strict providers.
pub fn hasWireContent(message: ai.ChatMessage) bool {
    for (message.assistant.content) |block| switch (block) {
        .text, .refusal => |t| if (t.text.len > 0) return true,
        .tool_call => return true,
        .reasoning, .image => {},
    };
    return false;
}
fn takeAssistantMessage(self: *Agent, assistant: *ai.ChatMessage) !void {
    assert(assistant.* == .assistant);
    try self.context_manager.appendPersisted(assistant.*);
    assistant.* = undefined;
}

pub fn ensureAssistantBeforeContinuation(self: *Agent, turn_owned: bool) !void {
    if (turn_owned) {
        try message_ops.appendMessage(self, .assistant, "[Response truncated before text was emitted]");
    }
}
