//! The context auto-compactor: watermark tracking, circuit breaker, manual
//! compact phases, and the summarizer-thread lifecycle, extracted from
//! Agent so the turn loop stays a sequencer.
//!
//! Division of labour:
//!   * `context/compaction.zig`  — pure policy (watermarks, budgets, prompts)
//!   * `agent/compactor.zig`     — the summarizer thread + its job/result
//!   * `context/auto_compactor.zig` (this) — the orchestration state machine
//!   * `Agent` — a sequencer: one `maybeCompact` per turn iteration, one
//!     `recordUsage` after each reply, and the narrow Env callbacks below.
//!
//! Everything environment-shaped (allocator, client, limiter, session
//! writer, window, settings, history estimators) arrives per call in
//! `Env`, built by the Agent from its live fields — so the state machine
//! holds no stale borrows and never imports the agent. The `swap` callback
//! must persist the compaction boundary BEFORE reprojecting the cache
//! (persist-before-cache: the session tree is the source of truth).

const std = @import("std");
const log = std.log.scoped(.auto_compactor);

const ai = @import("../ai.zig");
const compaction = @import("compaction.zig");
const agent_compactor = @import("../agent/compactor.zig");
const request_limiter_mod = @import("../request_limiter.zig");
const session_mod = @import("../session.zig");
const config_mod = @import("../config/config.zig");

/// Automatic compaction backs off after this many consecutive failures;
/// `/compact` stays available (TD-6).
pub const failure_limit: u32 = 3;
/// Defensive bound for `forceCompact`'s yield loop against a state that
/// never resolves.
pub const manual_poll_spins_max: u32 = 1000;

/// One-shot user-facing compaction notices. A bare enum — no allocation —
/// so the renderer owns the text and a dropped event leaks nothing.
pub const CompactionNotice = enum {
    /// Automatic compaction disabled after repeated consecutive failures.
    breaker_tripped,
    /// Past the swap watermark but nothing can be cut — the recent history
    /// already fits the retention budget.
    stuck,
    /// A synchronous overflow wait is about to join the summarizer.
    waiting,
};

/// Emitted after the agent replaces summarized history with a compaction
/// summary. Token counts are estimates for display only.
pub const HistoryCompacted = struct {
    tokens_before: u32,
    tokens_after: u32,
};

/// Per-call environment: borrowed dependencies plus the two history
/// estimators the watermark math needs. Built fresh by the Agent for every
/// call, so nothing here can go stale across a client swap or session
/// re-attach.
pub const Env = struct {
    ctx: *anyopaque,
    gpa: std.mem.Allocator,
    io: std.Io,
    client: ai.LanguageModel = .none,
    limiter: ?*request_limiter_mod.RequestLimiter = null,
    session: ?*session_mod.SessionWriter = null,
    context_window_tokens: u32 = 0,
    settings: config_mod.CompactionSettings = .{},

    /// Messages held in the live cache — the watermark anchor unit.
    historyCount: *const fn (*anyopaque) u32,
    /// Estimated tokens of everything appended after an anchor count,
    /// counting historical tool output as the pruned request would send it.
    estimateTrailing: *const fn (*anyopaque, anchor_count: u32) u32,
    /// Full footprint estimate of the whole history.
    estimateAll: *const fn (*anyopaque) u32,
    /// Persist the compaction boundary (append the summary entry) and
    /// reproject the live cache from the session tree. MUST keep the
    /// persist-first order — a failed reprojection leaves the cache
    /// intact instead of stranded (TD-5).
    swap: *const fn (*anyopaque, first_kept_id: []const u8, stored_summary: []const u8) anyerror!void,
};

pub const AutoCompactor = struct {
    /// The summarizer thread: state, job, and result (see
    /// `agent/compactor.zig`). Kept verbatim from the Agent field.
    core: agent_compactor.Compactor = .{},

    // ── Watermark: last real usage anchor + the message count it covered. ──
    last_usage: ?ai.Usage = null,
    last_usage_anchor_count: u32 = 0,

    // ── Circuit breaker (TD-6): after `failure_limit` consecutive failures
    //    the automatic path backs off so it stops respawning a doomed
    //    summarizer every turn. One notice is emitted; `/compact` is not
    //    gated. ──
    failures: u32 = 0,
    breaker_notified: bool = false,
    stuck_notified: bool = false,

    // ── Manual compact two-phase state (TD-1). ──
    manual_pending: bool = false,
    manual_started: bool = false,

    /// Best estimate of the footprint the *next* request will carry: the
    /// last turn's real reported usage (prompt + completion) as an anchor,
    /// plus a size estimate of every message appended since — the part the
    /// provider has not accounted for yet. Falls back to a full estimate
    /// when no usage has been reported.
    pub fn currentContextTokens(self: *const AutoCompactor, env: Env) u32 {
        const usage = self.last_usage orelse return env.estimateAll(env.ctx);
        const anchored = usage.input_tokens +| usage.output_tokens;
        return anchored +| env.estimateTrailing(env.ctx, self.last_usage_anchor_count);
    }

    /// Record a completed turn's usage as the watermark anchor. The anchor is
    /// the message count *after* the assistant reply landed, so everything
    /// appended later counts as trailing tokens.
    pub fn recordUsage(self: *AutoCompactor, env: Env, usage: ?ai.Usage) void {
        self.last_usage = usage;
        self.last_usage_anchor_count = env.historyCount(env.ctx);
    }

    /// Drop the usage anchor, forcing a full re-estimate next turn. Used
    /// after the history is rebuilt (compaction, branch switch).
    pub fn resetUsage(self: *AutoCompactor) void {
        self.last_usage = null;
        self.last_usage_anchor_count = 0;
    }

    /// Whether the automatic path should back off after repeated failures.
    pub fn breakerTripped(self: *const AutoCompactor) bool {
        return self.failures >= failure_limit;
    }

    /// Emit a one-shot compaction notice through the agent's event stream
    /// (duck-typed listener; no import of the agent needed).
    fn emitNotice(listener: anytype, notice: CompactionNotice) void {
        listener.emit(.{ .compaction_notice = notice }) catch {};
    }

    /// The per-turn-iteration hook (moved verbatim from Agent.maybeCompact).
    pub fn maybeCompact(self: *AutoCompactor, env: Env, listener: anytype) void {
        if (!env.settings.auto) return;
        if (env.client == .none) return;
        if (env.context_window_tokens == 0) return;
        if (env.session == null) return;

        if (self.breakerTripped()) {
            if (!self.breaker_notified) {
                self.breaker_notified = true;
                emitNotice(listener, .breaker_tripped);
            }
            return;
        }

        const used = self.currentContextTokens(env);
        const threshold = env.settings.threshold;

        // Past the swap watermark: install the ready background summary.
        if (compaction.shouldSwap(used, env.context_window_tokens, threshold)) {
            self.applyReadyCompaction(env, listener) catch |err| log.warn("compaction apply failed: {s}", .{@errorName(err)});
        }

        // Past the start watermark: kick off the summary so it is ready by
        // the time the footprint reaches the swap watermark.
        if (compaction.shouldStartSummary(used, env.context_window_tokens, threshold) and
            self.core.stateIs(.idle))
        {
            self.startCompaction(env) catch |err| switch (err) {
                // Nothing worth cutting while already past the swap watermark:
                // emit a one-shot notice instead of looping silently into
                // provider overflow errors (TD-6).
                error.NothingToCompact => if (compaction.shouldSwap(used, env.context_window_tokens, threshold)) {
                    if (!self.stuck_notified) {
                        self.stuck_notified = true;
                        emitNotice(listener, .stuck);
                    }
                },
                else => log.warn("compaction start failed: {s}", .{@errorName(err)}),
            };
        }

        // If used tokens still exceed the swap watermark and compaction is
        // running, wait synchronously so the prompt sent to the LLM fits
        // within the window. The wait can take up to the (user-configurable)
        // request timeout, so make it visible before blocking (H2).
        if (compaction.shouldSwap(self.currentContextTokens(env), env.context_window_tokens, threshold) and
            self.core.stateIs(.running))
        {
            emitNotice(listener, .waiting);
            self.joinCompactor();
            self.applyReadyCompaction(env, listener) catch |err| log.warn("compaction apply failed: {s}", .{@errorName(err)});
        }
    }

    /// Manually trigger a full compaction cycle: snapshot, summarize, swap.
    /// Synchronous wrapper over `requestManualCompact` + `pollManualCompact`,
    /// kept for the headless/test path. The TUI does NOT use this — it drives
    /// the two phases from its tick loop so the UI never blocks on the
    /// summarizer request.
    pub fn forceCompact(self: *AutoCompactor, env: Env) !HistoryCompacted {
        try self.requestManualCompact(env);
        // A deferred start (a stale auto-run was still producing) resolves on
        // the first poll; loop until the manual run lands. The poll returns
        // non-null or an error once the state resolves, so this always
        // terminates. The yield bound is a defensive guard against a state
        // that never resolves (e.g. a torn-down client the poll failed to
        // clear).
        var spins: u32 = 0;
        while (spins < manual_poll_spins_max) : (spins += 1) {
            if (try self.pollManualCompact(env)) |info| return info;
            std.Thread.yield() catch {};
        }
        return error.CompactionNotReady;
    }

    /// Non-blocking phase 1 of the manual compact: snapshot the prefix and
    /// hand it to the summarizer thread, then return. The UI polls
    /// `pollManualCompact` to learn when the summary lands. A stale
    /// auto-compaction still in flight is not joined here — the poll discards
    /// it when it lands and starts the manual run then, so this never blocks
    /// on the summarizer's request.
    pub fn requestManualCompact(self: *AutoCompactor, env: Env) !void {
        if (env.client == .none) return error.NoCompactionClient;
        if (env.context_window_tokens == 0) return error.UnknownContextWindow;
        if (env.session == null) return error.NoSessionWriter;
        if (self.manual_pending) return error.CompactionInProgress;

        if (self.core.stateIs(.running)) {
            // A stale auto-run is still producing. Wait for it to land; the
            // poll discards it and starts the manual run (TD-1).
            self.manual_pending = true;
            self.manual_started = false;
            return;
        }

        // Instant when no thread is alive: a `.ready`/`.failed` residue is
        // drained, then the manual run starts.
        self.drain(env);
        try self.startCompaction(env);
        self.manual_pending = true;
        self.manual_started = true;
    }

    /// Non-blocking phase 2 of the manual compact: polled by the UI each tick
    /// while `manual_pending`. Returns null while the summarizer is still
    /// producing, the token-count event once the manual summary is installed,
    /// or an error describing what went wrong. Never blocks — `joinCompactor`
    /// is only reached once the thread has already finished.
    pub fn pollManualCompact(self: *AutoCompactor, env: Env) !?HistoryCompacted {
        if (!self.manual_pending) return null;

        // Client torn down mid-flight (disconnect/reconnect): the summarizer
        // was drained, so abort the manual compact rather than strand the
        // submit gate forever.
        if (env.client == .none) {
            self.manual_pending = false;
            self.manual_started = false;
            return error.CompactionFailed;
        }

        const state = self.core.state.load(.acquire);
        if (state == .running or state == .idle) return null;

        if (!self.manual_started) {
            // The run that just landed is the stale auto one — discard it,
            // then start the manual run (TD-1).
            self.joinCompactor();
            self.finishCompactor(env);
            self.startCompaction(env) catch |err| {
                self.manual_pending = false;
                self.manual_started = false;
                return err;
            };
            self.manual_started = true;
            return null;
        }

        // The manual run landed.
        self.joinCompactor();
        defer self.finishCompactor(env);
        self.manual_pending = false;
        self.manual_started = false;
        if (state == .failed) return error.CompactionFailed;

        const result = self.core.result.?;
        const tokens_before = env.estimateAll(env.ctx);
        try env.swap(env.ctx, result.first_kept_id.slice(), result.stored_summary);
        self.resetUsage();
        // A successful manual compact proves the pipeline works: reset the
        // breaker so automatic compaction resumes.
        self.failures = 0;
        self.breaker_notified = false;
        self.stuck_notified = false;
        return .{
            .tokens_before = tokens_before,
            .tokens_after = env.estimateAll(env.ctx),
        };
    }

    /// Snapshot the frozen prefix and hand it to the summarizer thread. The
    /// snapshot (rendered text + first-kept entry id) is self-contained, so
    /// the thread never touches live history.
    pub fn startCompaction(self: *AutoCompactor, env: Env) !void {
        const session_writer = env.session orelse return;
        // Scale the keep-recent budget by the ratio of the provider's real
        // token count to this estimator's, so languages where chars/4
        // undercounts (CJK ≈ 1.5 chars/token) keep fewer messages and still
        // compact below the swap watermark (TD-6). Falls back to the base
        // budget when there is no usage anchor yet.
        const base_keep = compaction.keepRecentTokens(env.context_window_tokens, env.settings.keep_recent_tokens);
        const recent_tokens = compaction.calibrateKeepBudget(base_keep, self.currentContextTokens(env), self.estimateAllTokens(env));
        const cut = (try session_writer.compactionCut(env.gpa, recent_tokens)) orelse return error.NothingToCompact;
        self.core.result = null;
        self.core.job = .{
            .gpa = env.gpa,
            .io = env.io,
            .client = env.client,
            .limiter = env.limiter,
            .first_kept_id = cut.first_kept_id,
            .prefix_text = cut.prefix_text,
        };
        self.core.state.store(.running, .release);
        self.core.thread = std.Thread.spawn(.{}, agent_compactor.Compactor.runThread, .{&self.core}) catch |err| {
            env.gpa.free(cut.prefix_text);
            self.core.job = null;
            self.core.state.store(.idle, .release);
            return err;
        };
    }

    /// Install a finished background summary: write the boundary, reproject,
    /// and emit the notice — instant, because the summary already exists. A
    /// failed run is logged and discarded. No-op while idle or still running.
    pub fn applyReadyCompaction(self: *AutoCompactor, env: Env, listener: anytype) !void {
        const state = self.core.state.load(.acquire);
        if (state == .idle or state == .running) return;
        self.joinCompactor();
        defer self.finishCompactor(env);
        if (state == .failed) {
            self.failures +|= 1;
            log.warn("background compaction failed ({d}/{d})", .{ self.failures, failure_limit });
            return;
        }
        const result = self.core.result.?;
        const tokens_before = env.estimateAll(env.ctx);
        try env.swap(env.ctx, result.first_kept_id.slice(), result.stored_summary);
        self.resetUsage();
        // A successful apply proves the pipeline works: clear the breaker and
        // re-arm the one-shot stuck notice for a future episode.
        self.failures = 0;
        self.breaker_notified = false;
        self.stuck_notified = false;
        try listener.emit(.{ .history_compacted = .{
            .tokens_before = tokens_before,
            .tokens_after = env.estimateAll(env.ctx),
        } });
    }

    /// Join the summarizer thread if one is alive. Blocks until it finishes —
    /// used both for the overflow wait and at teardown.
    pub fn joinCompactor(self: *AutoCompactor) void {
        if (self.core.thread) |thread| {
            thread.join();
            self.core.thread = null;
        }
    }

    /// Release the finished job/result and return the compactor to idle.
    fn finishCompactor(self: *AutoCompactor, env: Env) void {
        if (self.core.result) |*result| env.gpa.free(result.stored_summary);
        self.core.result = null;
        self.core.job = null;
        self.core.state.store(.idle, .release);
    }

    /// Wait for any in-flight background summary and discard it. Call before
    /// freeing or replacing `compaction_client` so the summarizer thread is
    /// never left running against a client that is about to be torn down.
    /// Also aborts any in-flight manual compact: the run (if any) is gone, so
    /// the pending flags are reset to keep the TUI's submit gate from
    /// dangling on a summary that can never land.
    pub fn drain(self: *AutoCompactor, env: Env) void {
        self.joinCompactor();
        self.finishCompactor(env);
        self.manual_pending = false;
        self.manual_started = false;
    }

    fn estimateAllTokens(self: *AutoCompactor, env: Env) u32 {
        _ = self;
        return env.estimateAll(env.ctx);
    }
};
