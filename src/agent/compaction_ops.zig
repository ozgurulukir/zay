//! Compaction and context-usage plumbing for `Agent` (issue #367 slice 15).
//!
//! Free functions over `*Agent`: the `AutoCompactor.Env` vtable callbacks,
//! watermark/background compaction entry points, the manual two-phase
//! compact protocol and usage/context accounting. State stays on the owner
//! struct; `Env` is rebuilt per call so nothing borrows stale state.

const std = @import("std");
const log = std.log.scoped(.agent);

const agent_mod = @import("../agent.zig");
const ai = @import("../ai.zig");
const auto_compactor_mod = @import("../context/auto_compactor.zig");
const context_assembly = @import("../context/assembly.zig");
const session_mod = @import("../session.zig");
const skill_history = @import("../context/skill_history.zig");

const Agent = agent_mod.Agent;

/// Build the per-call environment for the auto-compactor from the live
/// fields. Rebuilt on every call, so nothing borrows stale state across
/// a client swap or session re-attach.
pub fn compactionEnv(self: *Agent) auto_compactor_mod.Env {
    return .{
        .ctx = self,
        .gpa = self.gpa,
        .io = self.io,
        .client = self.compaction_client,
        .limiter = self.request_limiter,
        .session = self.context_manager.session_writer,
        .context_window_tokens = self.context_window_tokens,
        .settings = self.compaction_settings,
        .tool_tokens = self.client.estimateToolTokens(),
        .historyCount = historyCount,
        .estimateTrailing = estimateTrailingTokensCb,
        .estimateAll = estimateAllTokensCb,
        .swap = swapHistory,
    };
}

fn historyCount(ctx: *anyopaque) u32 {
    const self: *Agent = @ptrCast(@alignCast(ctx));
    return self.context_manager.count();
}

fn estimateTrailingTokensCb(ctx: *anyopaque, anchor_count: u32) u32 {
    const self: *Agent = @ptrCast(@alignCast(ctx));
    return context_assembly.estimatePrunedTokensRangeWithSkills(
        self.context_manager.items(),
        anchor_count,
        self.compaction_settings.keep_recent_tool_turns,
        self.compaction_settings.tool_output_cap_bytes,
        self.compaction_settings.evict_history_images,
        &self.skill_context,
    );
}

fn estimateAllTokensCb(ctx: *anyopaque) u32 {
    const self: *Agent = @ptrCast(@alignCast(ctx));
    return context_assembly.estimatePrunedTokensRangeWithSkills(
        self.context_manager.items(),
        0,
        self.compaction_settings.keep_recent_tool_turns,
        self.compaction_settings.tool_output_cap_bytes,
        self.compaction_settings.evict_history_images,
        &self.skill_context,
    );
}

/// Persist the compaction boundary, then reproject the cache — the
/// swap. Order is the persist-before-cache invariant: the session tree
/// is the source of truth, so a failed reprojection leaves the live
/// cache intact instead of stranded with only the system prompt (TD-5).
fn swapHistory(ctx: *anyopaque, first_kept_id: []const u8, stored_summary: []const u8) anyerror!void {
    const self: *Agent = @ptrCast(@alignCast(ctx));
    const session_writer = self.context_manager.session_writer orelse return error.NoSessionWriter;
    try self.persistSkillContext();
    try session_writer.appendCompaction(first_kept_id, stored_summary);
    try reloadFromSession(self);
}

/// Keep the prompt within the model's window using a background summarizer,
/// so the agent never waits. Two watermarks: start the summary at the lower
/// one (giving it time to finish), and swap it into history at the higher
/// one (by when it is normally ready, so the swap is instant). Messages
/// appended between the two watermarks survive the swap verbatim — the
/// boundary references a tree entry id and the projection emits from it to
/// the leaf. Best-effort: every failure is logged and swallowed so
/// compaction never aborts the turn.
pub fn maybeCompact(self: *Agent, listener: anytype) void {
    self.compactor.maybeCompact(compactionEnv(self), listener);
}

/// Synchronous full compaction (headless/test path). See
/// `AutoCompactor.forceCompact`.
pub fn forceCompact(self: *Agent) !auto_compactor_mod.HistoryCompacted {
    return self.compactor.forceCompact(compactionEnv(self));
}

/// Non-blocking phase 1 of the manual `/compact`.
pub fn requestManualCompact(self: *Agent) !void {
    return self.compactor.requestManualCompact(compactionEnv(self));
}

/// Non-blocking phase 2 of the manual `/compact`, polled by the TUI tick.
pub fn pollManualCompact(self: *Agent) !?auto_compactor_mod.HistoryCompacted {
    return self.compactor.pollManualCompact(compactionEnv(self));
}

/// Whether a manual `/compact` is mid-flight (drives the TUI's submit
/// gate and waiting row).
pub fn manualCompactPending(self: *const Agent) bool {
    return self.compactor.manual_pending;
}

/// Wait for any in-flight background summary and discard it. Call before
/// freeing or replacing `compaction_client` (teardown, reconnect).
pub fn drainBackgroundCompaction(self: *Agent) void {
    self.compactor.drain(compactionEnv(self));
}

/// Best estimate of the footprint the *next* request will carry: the
/// last turn's real reported usage as an anchor plus trailing estimates
/// (see `AutoCompactor.currentContextTokens`).
pub fn currentContextTokens(self: *Agent) u32 {
    return self.compactor.currentContextTokens(compactionEnv(self));
}

/// Record a completed turn's usage as the watermark anchor.
pub fn recordUsage(self: *Agent, usage: ?ai.Usage) void {
    self.compactor.recordUsage(compactionEnv(self), usage);
    if (usage) |measured| {
        if (self.context_manager.session_writer) |writer| {
            writer.recordUsage(measured) catch |err| log.warn("session usage write failed: {s}", .{@errorName(err)});
        }
    }
}

/// Drop the usage anchor, forcing a full re-estimate next turn. Used
/// after the history is rebuilt (compaction, branch switch).
pub fn resetContextUsage(self: *Agent) void {
    self.compactor.resetUsage();
}

/// Rehydrate the cached message list from the session projection after a
/// compaction boundary was written — the swap. Keeps the system prompt.
/// Called between turn iterations, where every message is already
/// persisted and no stream is active; never mid-stream.
pub fn reloadFromSession(self: *Agent) !void {
    const session_writer = self.context_manager.session_writer orelse return;
    if (self.skill_context_dirty) return error.SkillContextNotPersisted;
    // Project first, swap second: a failed reprojection leaves the live
    // cache intact instead of stranded with only the system prompt (TD-5).
    var projected = try session_writer.conversation(self.gpa);
    defer projected.deinit(self.gpa);
    try replaceConversation(self, &projected);
}

/// Consume both projections on success. Reservation happens before either
/// live owner is discarded, so an allocation failure preserves both.
pub fn replaceConversation(self: *Agent, projected: *session_mod.SessionWriter.Conversation) !void {
    const prior_count = projected.skill_context.entries.items.len;
    try skill_history.rebuild(&projected.skill_context, self.gpa, projected.messages, self.skills);
    try self.context_manager.replaceConversation(projected.messages);
    self.gpa.free(projected.messages);
    projected.messages = &.{};
    self.skill_context.deinit(self.gpa);
    self.skill_context = projected.skill_context;
    projected.skill_context = .{};
    self.skill_context_dirty = self.skill_context.entries.items.len != prior_count;
    self.skill_context_changed_pending = true;
    self.tool_view_cache.clear(self.gpa);
}
