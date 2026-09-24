const std = @import("std");
const log = std.log.scoped(.agent);

const ai = @import("ai.zig");
const os = @import("os.zig");
const at_mention = @import("at_mention.zig");
const background_mod = @import("background.zig");
const compaction = @import("context/compaction.zig");
const config_mod = @import("config/config.zig");
const context_mod = @import("context/manager.zig");
const context_assembly = @import("context/assembly.zig");
const executor_mod = @import("executor.zig");
const lane_bridge = @import("tools/lane_bridge.zig");
const request_limiter_mod = @import("request_limiter.zig");
const lua_mod = @import("lua/root.zig");
const mcp_mod = @import("mcp/manager.zig");
const session_mod = @import("session.zig");
const skill_mod = @import("skill.zig");
const stream_parser = @import("ai/stream_parser.zig");
const text_tool_call = @import("ai/text_tool_call.zig");
const tools = @import("tools.zig");
const vcs = @import("vcs.zig");

const assert = std.debug.assert;
const agent_queue = @import("agent/queue.zig");

const QueuedUserMessage = agent_queue.QueuedUserMessage;
const MessageQueue = agent_queue.MessageQueue;

const agent_compactor = @import("agent/compactor.zig");
const auto_compactor_mod = @import("context/auto_compactor.zig");
const snapshotter_mod = @import("agent/snapshotter.zig");
const Compactor = agent_compactor.Compactor;

/// After this many consecutive background-compaction failures the automatic
/// path backs off (emitting one notice); the manual `/compact` command is
/// never gated (TD-6). Alias of the AutoCompactor's own limit — one SSOT.
pub const compaction_failure_limit: u32 = auto_compactor_mod.failure_limit;
/// Trailing machine-authored continuation hint left in history after a soft
/// budget stop. Role `.user` (not `.system`) because `SessionWriter.append`
/// skips system messages — `.user` survives `/resume`, branch switches, and
/// compaction reprojection, and Qwen's single-leading-system normalization
/// never touches it. Static text: the event carries the limit for the human;
/// the model does not need the number.
const tool_budget_continuation_hint =
    "[zay] This turn stopped early because the per-turn tool-call budget was reached. " ++
    "Work done so far is intact. When the user asks to continue, briefly summarize " ++
    "completed steps, then pick up exactly where the work left off.";
/// Trailing machine-authored continuation hint appended when a response was
/// severed by the provider's output token cap (`finish_reason=length`) with
/// no tool calls: the prose landed, the tool_call section did not. Same
/// `.user`-role reasoning as `tool_budget_continuation_hint` (survives
/// resume/compaction; Qwen normalization never touches it).
const length_cut_continuation_hint =
    "[zay] Your previous response was cut off by the output token limit before it finished. " ++
    "Continue from exactly where it stopped; if you were about to call a tool, emit that tool call now.";
/// Injected when the provider severed the tool_call section (name+id arrived,
/// arguments never streamed — intern-ai/internlm gateway truncation). The
/// model's request is NOT executed, so the model must re-emit the call with
/// its arguments intact. The consumer sees this as a normal user message.
const tool_call_truncation_hint =
    "[zay] Your tool call(s) arrived without their arguments — the provider " ++
    "truncated the tool_call section before the arguments payload streamed. " ++
    "The call was not executed. Re-emit the SAME tool call(s) with full arguments " ++
    "in a single request; avoid sending many parallel tool calls at once if " ++
    "truncation persists.";
/// Byte threshold at which a pending buffer flushes mid-stream. ~2s of text
/// at 100 tok/s, ~0.4s at 500 tok/s. A config knob adds surface area for
/// little gain; a comptime constant is simpler.
const coalesce_threshold_bytes: usize = 1024;
/// Defensive bound for the manual-compaction completion poll: 1000 yields
/// before giving up with `error.CompactionNotReady` (a state that never
/// resolves, e.g. a torn-down client the poll failed to clear).
const manual_compact_poll_spins_max: u32 = 1000;

pub const Agent = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    /// Borrowed from the TUI worker for the duration of a turn.
    cancel_requested: ?*const std.atomic.Value(bool) = null,
    /// Workspace-mode scoping (S5): when set (a borrowed lane worktree path),
    /// tools root at this path instead of `cwd`; `effectiveCwd()` is the
    /// single read. Written by the `lane` tool on this agent's worker thread
    /// (`setWorkspace`), between tool batches; reset to null by the tool
    /// (`lane leave`) or by the UI's S17 invariant while this agent's turn is
    /// idle. The path is owned by the lane's `Thread`, never freed here.
    ///
    /// Cross-thread: the worker thread writes it (`lane enter`/`leave`), the
    /// UI thread reads it (`driverWorkspace`, `clearWorkspaceBorrowForPath`).
    /// A 16-byte slice store can tear, so the field is guarded by
    /// `workspace_mutex`; `setWorkspace`/`workspaceBorrow`/`effectiveCwd` are
    /// the only accessors. The lock is never held across tool dispatch.
    workspace: ?[]const u8 = null,
    workspace_mutex: std.Io.Mutex = .init,
    /// Root-containment for lane workers: when set, the agent's bash tool
    /// refuses `cd` to a directory outside the project root (the lane
    /// worktree), so a worker can't drift into the main tree and write there.
    /// The driver/primary agents keep this false — they legitimately `cd` to
    /// lane worktrees to inspect them.
    contained: bool = false,
    /// Monotonic lane generation identity for routing background job completions
    /// safely without holding raw agent pointers.
    lane_generation: u64 = 1,
    /// The App-owned `LaneBridge` the `lane` tool posts across. Borrowed
    /// (owned by the App); null disables the lane tool (headless/tests).
    lane_bridge: ?*lane_bridge.LaneBridge = null,
    client: ai.LanguageModel,
    context_manager: context_mod.ContextManager,
    skills: []const skill_mod.Skill = &.{},
    /// Context window of the connected model, in tokens. Set by the runtime
    /// when a client is attached. 0 means unknown — compaction is disabled.
    context_window_tokens: u32 = 0,
    /// Dedicated client for background summarization, distinct from `client` so
    /// the two never share a connection. `.none` disables compaction.
    compaction_client: ai.LanguageModel = .none,
    /// Optional local classifier endpoint for bash approval gating.
    bash_classifier_url: ?[]const u8 = null,
    /// Optional synchronous approval hook used by the TUI worker.
    bash_approval: ?BashApproval = null,
    /// Optional shared manager for long-running bash commands launched with
    /// `run_in_background`. Borrowed (owned by the App); null disables the
    /// background path so such calls fall back to a normal blocking run.
    background_manager: ?*background_mod.BackgroundManager = null,
    /// Optional MCP manager for dispatching `mcp__` tool calls.
    /// Borrowed (owned by the App); null disables MCP dispatch.
    mcp_manager: ?*mcp_mod.McpManager = null,
    /// Optional tool registry (builtin + plugin). Borrowed (owned by the
    /// App); null falls back to the builtin-only registry, which is what
    /// headless tests use. The registry is read at every `runToolBatch` to
    /// route plugin calls through the shared dispatcher.
    tool_registry: ?*tools.ToolRegistry = null,
    /// Optional plugin manager (set from the App). Null falls back to
    /// `builtinRegistry()` only, which is what headless tests use. The
    /// manager is read at every `runToolBatch` to route plugin tool
    /// calls through the shared dispatcher.
    plugin_manager: ?*lua_mod.PluginManager = null,
    /// The auto-compaction state machine (watermark, breaker, manual-compact
    /// phases, summarizer thread) — see `context/auto_compactor.zig`. The
    /// Agent keeps only the sequencer calls and the narrow Env callbacks.
    compactor: auto_compactor_mod.AutoCompactor = .{},
    /// Config-driven compaction policy. Set by the runtime from
    /// `config.context.compaction`; defaults match the old hardcoded
    /// constants so agents created without a config still compact.
    compaction_settings: config_mod.CompactionSettings = .{},
    /// Per-turn bound on LLM→tool iterations (one assistant batch of tool
    /// calls = one iteration). Set by the runtime from
    /// `config.context.tool_call_limit_per_turn`; the default matches
    /// `config_mod.default_tool_call_limit_per_turn` so agents created
    /// without a config (tests) stay bounded.
    tool_call_limit_per_turn: u32 = config_mod.default_tool_call_limit_per_turn,
    /// When true, exhausting `tool_call_limit_per_turn` ends the turn
    /// gracefully (drain + hint + typed event) instead of failing with
    /// `error.ToolCallLimit`. Default true; `false` restores the historical
    /// hard-failure contract byte-for-byte.
    soft_stop_on_tool_call_limit: bool = true,
    /// When true (default), a response severed by the provider's output
    /// token cap (`finish_reason=length`, no tool calls) gets ONE automatic
    /// continuation inside the same turn: a hint is appended and the model
    /// re-requested. Guards against providers whose default completion
    /// budget cuts the tool_call section off after the prose — the turn
    /// otherwise ends as a text-only message that looks complete. Set from
    /// `config.context.auto_continue_on_length_cut`.
    auto_continue_on_length_cut: bool = true,
    /// Process-wide cap on concurrent LLM requests to the provider, shared by
    /// every lane's agent. Borrowed from the App (never freed here); null in
    /// headless/tests = no gate. Acquired around each `client.prompt` so at
    /// most `permits` requests are in flight at once (see `request_limiter.zig`).
    request_limiter: ?*request_limiter_mod.RequestLimiter = null,
    message_queue: MessageQueue = .{},
    message_queue_storage: [agent_queue.capacity]QueuedUserMessage = undefined,
    message_queue_mutex: std.Io.Mutex = .init,
    /// Cache of pruned historical tool messages across run-loop iterations (TD-13).
    /// Prevents repeated allocations and string truncation during multi-step turns.
    tool_view_cache: context_assembly.PrunedToolCache = .{},
    /// Git-shadow snapshot state (see `agent/snapshotter.zig`): index-path
    /// caching, unchanged-tree dedup, and the disable latch live in the module.
    snapshotter: ?snapshotter_mod.Snapshotter = null,
    /// Monotonic counter minting `textcall_<n>` ids for tool calls recovered
    /// from text (T3). Kept on the agent (not the stream parser) because
    /// recovery runs on the finished turn, post-stream, so the stream's own
    /// `tool_call_seq` is not in scope.
    text_tool_seq: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, client: ai.LanguageModel) Agent {
        return .{
            .gpa = gpa,
            .io = io,
            .cwd = cwd,
            .client = client,
            .context_manager = .{ .gpa = gpa },
        };
    }

    /// The directory tools run in: the workspace root when entered in a lane
    /// (S5), else the session cwd. Read per tool batch by `runToolBatch` and
    /// per `@`-mention expansion by `addUserPrompt` — both on the worker
    /// thread, but the UI thread reads the same field, so the read is guarded
    /// by `workspace_mutex`. The returned slice is borrowed (the backing path
    /// is Thread-owned and outlives the borrow).
    pub fn effectiveCwd(self: *Agent) []const u8 {
        self.workspace_mutex.lock(self.io) catch return self.cwd;
        defer self.workspace_mutex.unlock(self.io);
        return self.workspace orelse self.cwd;
    }

    /// Set the workspace borrow (worker thread, `lane enter`/`leave`). The
    /// path is borrowed from the lane's `Thread`, never copied or freed here.
    pub fn setWorkspace(self: *Agent, path: ?[]const u8) void {
        self.workspace_mutex.lock(self.io) catch return;
        defer self.workspace_mutex.unlock(self.io);
        self.workspace = path;
    }

    /// Read the workspace borrow (UI thread). Returns a borrowed slice; the
    /// backing path is Thread-owned and outlives the borrow.
    pub fn workspaceBorrow(self: *Agent) ?[]const u8 {
        self.workspace_mutex.lock(self.io) catch return null;
        defer self.workspace_mutex.unlock(self.io);
        return self.workspace;
    }

    /// The cached message projection the agent prompts with. Source of truth
    /// is the session tree; see `ContextManager`.
    pub fn messages(self: *const Agent) []ai.ChatMessage {
        return self.context_manager.items();
    }

    pub fn attachSessionWriter(self: *Agent, session_writer: *session_mod.SessionWriter) void {
        self.context_manager.attachSessionWriter(session_writer);
    }

    pub fn addSystem(self: *Agent, content: []const u8) !void {
        try self.appendMessage(.system, content);
    }

    /// Replace the one in-memory system prompt at a turn boundary. System
    /// messages are reconstructed on resume and are never persisted.
    pub fn replaceSystem(self: *Agent, content: []const u8) !void {
        const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
        errdefer self.gpa.free(blocks);
        blocks[0] = .{ .text = .{ .text = try self.gpa.dupe(u8, content) } };
        self.context_manager.replaceSystem(.{ .system = .{ .content = blocks } });
    }

    pub fn deinit(self: *Agent) void {
        self.tool_view_cache.deinit(self.gpa);
        // Wait for any background summarizer before tearing down the state it
        // reads (the client), then release its result.
        self.drainBackgroundCompaction();
        self.context_manager.deinit();
        if (self.message_queue_mutex.lock(self.io)) |_| {
            defer self.message_queue_mutex.unlock(self.io);
            while (self.message_queue.pop(&self.message_queue_storage)) |queued| {
                self.gpa.free(queued.prompt);
            }
        } else |_| {
            // Lock failed (canceled) — skip critical section, continue cleanup.
        }
        if (self.snapshotter) |*s| s.deinit();
        if (self.bash_classifier_url) |url| self.gpa.free(url);
        self.* = undefined;
    }

    pub fn addUser(self: *Agent, content: []const u8) !void {
        try self.appendMessage(.user, content);
    }

    pub fn enqueueUser(self: *Agent, content: []const u8) !void {
        assert(content.len > 0);
        const owned = try self.gpa.dupe(u8, content);
        errdefer self.gpa.free(owned);
        try self.message_queue_mutex.lock(self.io);
        defer self.message_queue_mutex.unlock(self.io);
        if (!self.message_queue.push(&self.message_queue_storage, .{ .prompt = owned })) return error.QueueFull;
    }

    /// Queue a machine-generated user message delivered verbatim (no `@`-mention
    /// expansion or skill prefixing) at the next turn boundary. Thread-safe — the
    /// `BackgroundManager` callers reach it from the UI thread while the worker
    /// may be draining the same queue. See `QueuedUserMessage.raw`.
    pub fn enqueueRaw(self: *Agent, content: []const u8) !void {
        assert(content.len > 0);
        const owned = try self.gpa.dupe(u8, content);
        errdefer self.gpa.free(owned);
        try self.message_queue_mutex.lock(self.io);
        defer self.message_queue_mutex.unlock(self.io);
        if (!self.message_queue.push(&self.message_queue_storage, .{ .prompt = owned, .raw = true })) return error.QueueFull;
    }

    /// Queue a user message marked to steer (inject after the next tool batch).
    /// Atomic push + mark under one lock, so the lane-steer path can't
    /// interleave a concurrent drain between `enqueueUser` and `setQueuedSteer`.
    pub fn enqueueSteer(self: *Agent, content: []const u8) !void {
        assert(content.len > 0);
        const owned = try self.gpa.dupe(u8, content);
        errdefer self.gpa.free(owned);
        try self.message_queue_mutex.lock(self.io);
        defer self.message_queue_mutex.unlock(self.io);
        if (!self.message_queue.push(&self.message_queue_storage, .{ .prompt = owned, .steer = true })) return error.QueueFull;
    }

    /// Whether any user message is waiting in the queue. The UI uses this to
    /// decide whether an idle lane should start a turn to deliver a background
    /// completion that was enqueued while no turn was running.
    pub fn hasQueuedMessages(self: *Agent) bool {
        self.message_queue_mutex.lock(self.io) catch return false;
        defer self.message_queue_mutex.unlock(self.io);
        return self.message_queue.len() > 0;
    }

    /// Expand `@`-mentions in `prompt` (embedding text files inline, attaching
    /// images as real content blocks) and append the result as a user message.
    /// Reads files, so this is meant to run on the agent worker thread.
    pub fn addUserPrompt(self: *Agent, prompt: []const u8) !void {
        // A turn interrupted mid-tool-batch leaves the assistant's `tool_call`s
        // with no matching tool result. Providers reject a turn whose history has
        // a tool_use without a corresponding tool_result, so fill them in before
        // this user message lands — keeping the synthetic results right after the
        // assistant call, ahead of the new user turn.
        try self.reconcileInterruptedToolCalls();

        // @-mention expansion follows the workspace (M6): in workspace mode a
        // mention of a file edited in the lane reads the lane's copy. Runs on
        // the worker thread, so `effectiveCwd` is race-free against the tool.
        const blocks = try at_mention.buildUserMessage(self.gpa, self.io, self.effectiveCwd(), prompt);
        errdefer {
            for (blocks) |*block| block.deinit(self.gpa);
            self.gpa.free(blocks);
        }
        try self.prependSkillBlocks(prompt, blocks);
        try self.context_manager.appendPersisted(.{ .user = .{ .content = blocks } });
    }

    /// Result text recorded for a tool call the user interrupted before it
    /// finished — surfaced to the model so it knows the call was cancelled.
    const interrupted_tool_result = "The user interrupted the turn before this tool call completed; it produced no result.";

    /// Append a synthetic, failed tool result for every `tool_call` on the active
    /// branch that has no matching result yet. Runs before a new user message so
    /// the dangling calls (from a mid-batch interrupt) don't break the next turn.
    /// A no-op when every call already has a result.
    fn reconcileInterruptedToolCalls(self: *Agent) !void {
        const history = self.context_manager.items();

        var resolved = std.StringHashMap(void).init(self.gpa);
        defer resolved.deinit();
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
            blocks[0] = .{ .text = .{ .text = try self.gpa.dupe(u8, interrupted_tool_result) } };
            try self.context_manager.appendPersisted(.{
                .tool = .{
                    .content = blocks,
                    .call_id = .{ .value = try self.gpa.dupe(u8, id) },
                    .display_label = try self.gpa.dupe(u8, "cancelled"),
                    .failed = true,
                },
            });
        }
    }

    fn prependSkillBlocks(self: *Agent, prompt: []const u8, blocks: []ai.ContentBlock) !void {
        assert(blocks.len > 0);
        assert(blocks[0] == .text);
        const prefix = try skill_mod.promptPrefix(self.gpa, self.skills, prompt);
        defer self.gpa.free(prefix);
        if (prefix.len == 0) return;

        const old_text = blocks[0].text.text;
        const new_text = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ prefix, old_text });
        self.gpa.free(old_text);
        blocks[0].text.text = new_text;
    }

    pub fn takeMessage(self: *Agent, message: ai.ChatMessage) !void {
        try self.context_manager.appendUnpersisted(message);
    }

    /// Drop every non-system message, freeing it. Keeps the system prompt(s) in
    /// place so the conversation can be rehydrated from a different branch (see
    /// `AgentRuntime.reloadMessages`). Only safe at a turn boundary, never while
    /// a response is streaming.
    pub fn clearNonSystemMessages(self: *Agent) void {
        self.tool_view_cache.clear(self.gpa);
        self.context_manager.clearNonSystem();
    }

    /// The tagged union the agent emits to describe what is happening.
    /// Single public seam — the TUI (and any future consumer) subscribes
    /// to this stream of events via `Agent.Listener`.
    ///
    /// Variant payloads are C-flattenable (flat fields, strings as
    /// `[]const u8`, integers, enums, single-level structs) so an FFI shim
    /// can wrap them later without redesigning the type.
    pub const Event = union(enum) {
        turn_started,
        thinking_delta: []const u8,
        response_delta: []const u8,
        tool_delta: ai.ToolDelta,
        delta_end,
        tool_call_finished: ToolCallFinished,
        tool_batch_finished,
        queued_messages_flushed: u32,
        turn_finished,
        turn_failed: []const u8,
        history_compacted: HistoryCompacted,
        /// One-shot user-facing compaction notices (breaker tripped, stuck above
        /// the swap watermark with nothing to cut, overflow wait). The variant
        /// is a bare enum so no allocation is involved — the renderer owns the
        /// message text (TD-6, TD-2 event plumbing).
        compaction_notice: CompactionNotice,
        /// The per-turn tool-call budget ran out and the turn soft-stopped.
        /// Payload is the configured limit; a bare u32 like
        /// `queued_messages_flushed` so the event is allocation-free — the
        /// renderer owns the human-facing text.
        tool_budget_exhausted: u32,
        /// The provider severed the response at the output token cap
        /// (`finish_reason=length`) with no tool calls. `.auto_continued`:
        /// a continuation hint was appended and the model re-requested
        /// (one-shot per run). `.stopped`: the turn ended cut short (knob
        /// off, or the one-shot was already used) — user action is expected.
        /// Bare enum payload: allocation-free, renderer owns the text.
        length_cut: LengthCut,

        /// The fixed notice kinds `maybeCompact` can emit while it degrades
        /// gracefully instead of looping into provider overflow errors.
        pub const CompactionNotice = auto_compactor_mod.CompactionNotice;

        /// See the `length_cut` event.
        pub const LengthCut = enum {
            auto_continued,
            stopped,
        };

        /// Emitted after the agent replaces summarized history with a compaction
        /// summary. Token counts are estimates for display only.
        pub const HistoryCompacted = auto_compactor_mod.HistoryCompacted;

        pub const ToolCallFinished = struct {
            index: u32,
            call_id: []const u8 = "",
            name: []const u8,
            display_label: []const u8,
            display_expanded_label: ?[]const u8 = null,
            display_body: []const u8,
            display_kind: tools.DisplayKind = .text,
            stderr: ?[]const u8 = null,
            failed: bool = false,
        };

        pub fn deinit(self: *Event, gpa: std.mem.Allocator) void {
            switch (self.*) {
                .thinking_delta, .response_delta, .turn_failed => |text| gpa.free(text),
                .tool_delta => |tool| {
                    gpa.free(tool.name);
                    gpa.free(tool.arguments);
                },
                .tool_call_finished => |tool| {
                    gpa.free(tool.call_id);
                    gpa.free(tool.name);
                    gpa.free(tool.display_label);
                    if (tool.display_expanded_label) |label| gpa.free(label);
                    gpa.free(tool.display_body);
                    if (tool.stderr) |stderr| gpa.free(stderr);
                },
                .turn_started, .delta_end, .tool_batch_finished, .queued_messages_flushed, .turn_finished, .history_compacted, .compaction_notice, .tool_budget_exhausted, .length_cut => {},
            }
            self.* = undefined;
        }
    };

    /// The typed seam consumers attach to receive `Agent.Event`s. Generic
    /// over the consumer's context type — the `*Ctx` is supplied at the call
    /// site, so callbacks receive their own typed context without
    /// `@ptrCast`. `nullListener(Ctx)` is the branch-free default for
    /// callers that don't subscribe; the `Ctx` type is supplied by the
    /// caller.
    pub fn Listener(Ctx: type) type {
        return struct {
            ctx: *Ctx,
            on_event: *const fn (ctx: *Ctx, event: Event) anyerror!void,

            pub fn emit(self: @This(), event: Event) anyerror!void {
                return self.on_event(self.ctx, event);
            }
        };
    }

    /// Build a no-op `Listener(Ctx)`. The ctx pointer is left undefined —
    /// the callback ignores its argument.
    pub fn nullListener(Ctx: type) Listener(Ctx) {
        return .{
            .ctx = undefined,
            .on_event = onNothingCtx,
        };
    }

    fn onNothingCtx(_: *anyopaque, _: Event) anyerror!void {}

    pub fn run(self: *Agent, listener: anytype) !void {
        // The listener's `ctx` field is `*Ctx`; extract `Ctx` (the pointee
        // type) so `Listener(Ctx)` matches the struct the caller built.
        const Ctx = @typeInfo(@TypeOf(listener.ctx)).pointer.child;
        const L = Agent.Listener(Ctx);
        const l: L = listener;
        try l.emit(.turn_started);
        var calls: u32 = 0;
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

        while (calls < self.tool_call_limit_per_turn) : (calls += 1) {
            _ = turn_arena.reset(.retain_capacity);
            const turn_allocator = turn_arena.allocator();

            self.maybeCompact(l);
            var stream_context: StreamContext(L) = .{
                .agent = self,
                .listener = l,
            };
            defer stream_context.deinit();
            const prompt_messages = try context_assembly.pruneHistoricalToolResultsViewsCached(
                self.gpa,
                &self.tool_view_cache,
                self.messages(),
                self.compaction_settings.keep_recent_tool_turns,
                self.compaction_settings.historical_tool_cap_bytes,
            );
            defer context_assembly.freePrunedViews(self.gpa, prompt_messages);

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
            // respective events BEFORE the assistant message is finalized (line
            // 543) / tool batch is dispatched (line 564). This must preserve
            // wire order: a trailing content delta after a tool delta would
            // otherwise be flushed by `deinit` (line 489) AFTER
            // `tool_call_finished`, reordering the event queue.
            try stream_context.flushPending();
            // Hoisted before the ownership branch: `Turn.deinit` sets
            // `self.* = undefined`, and the no-wire-content branch (a
            // reasoning-only response cut before any prose) deinits the turn
            // — the length branch below must read the scalar, not the
            // undefined struct.
            const finish_reason = turn.finish_reason;
            const usage = turn.usage;
            // Hoisted for the same reason as the two above: the
            // no-wire-content branch deinits the turn, and the
            // truncation guard below reads this scalar after that.
            const tool_calls_truncated = turn.tool_calls_truncated;
            var turn_owned = true;
            defer if (turn_owned) turn.deinit(self.gpa);

            const tool_calls_initial = try self.collectToolCallsAlloc(turn_allocator, turn.assistant);
            defer turn_allocator.free(tool_calls_initial);

            // T3: recover tool calls the model emitted as literal text (weak
            // function-calling models do this). Only when there were zero
            // structured calls, and only over the assistant's text blocks —
            // never mid-stream. Runs BEFORE takeAssistantMessage so the
            // recovered calls are persisted (turn.assistant is still live and
            // owned by the turn here). See plan §1.1, §2.2.
            var recovered: []ai.ToolCall = &.{};
            if (tool_calls_initial.len == 0) {
                recovered = try self.recoverTextToolCalls(turn.assistant);
            }
            // Ownership: when recovered.len > 0 the payloads were MOVED into
            // the message's new blocks by injectRecoveredToolCalls; the
            // `recovered` slice shell itself is freed here, but NOT its
            // element strings (they were moved). When recovery didn't fire,
            // recovered is &.{} (empty literal, nothing to free).
            defer if (recovered.len > 0) self.gpa.free(recovered);
            if (recovered.len > 0) {
                try self.injectRecoveredToolCalls(&turn.assistant, recovered);
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

            if (turn.assistant == .assistant and hasWireContent(turn.assistant)) {
                try self.takeAssistantMessage(&turn.assistant);
                turn_owned = false;
            } else {
                turn.deinit(self.gpa);
                turn_owned = false;
            }
            // Anchor after the assistant reply is in history: `usage` accounts
            // for everything up to and including it; later appends are trailing.
            self.recordUsage(usage);

            if (tool_calls.len == 0) {
                // Turn would otherwise go idle: drain the front queued message
                // (steer or not) and continue, so anything still waiting is
                // handled at the natural turn end. The user's queued message
                // takes precedence over the automatic continuation below.
                const drained_count = try self.drainQueuedUserMessage(false);
                if (drained_count > 0) {
                    try l.emit(.{ .queued_messages_flushed = drained_count });
                    continue;
                }
                // Provider-severed tool_call arguments (name+id arrived, the
                // arguments payload never streamed). The parser dropped the
                // calls, so nothing dispatched. Tell the model its arguments
                // were truncated and retry ONCE (bounded like the length-cut
                // auto-continue) — a pathological endpoint cannot bill an
                // unbounded retry loop.
                if (tool_calls_truncated > 0) {
                    if (!truncation_retried) {
                        log.warn("tool_call arguments truncated by provider ({d} calls dropped) — retrying once with hint", .{tool_calls_truncated});
                        truncation_retried = true;
                        try self.addUser(tool_call_truncation_hint);
                        continue;
                    }
                    log.warn("tool_call arguments truncated by provider on retry — ending turn", .{});
                    try l.emit(.{ .length_cut = .stopped });
                    return;
                }
                // A provider output-token cap severed the response before the
                // tool_call section (observed: prose announcing an action,
                // then a clean close). The partial prose is already in
                // history (`takeAssistantMessage` ran above), so the wire
                // shape for the continuation stays [.., assistant, user-hint].
                if (finish_reason == .length) {
                    if (try self.handleLengthCut(l, length_continued)) {
                        length_continued = true;
                        continue;
                    }
                }
                return;
            }
            try Agent.runToolBatch(L, self, tool_calls, &stream_context, l, turn_allocator);
            // Mid-turn we only inject messages explicitly marked to steer, and
            // only from the front so FIFO order holds — a default-queued
            // message ahead of a steer one keeps it waiting for turn end.
            var steered: u32 = 0;
            while ((try self.drainQueuedUserMessage(true)) > 0) steered += 1;
            if (steered > 0) try l.emit(.{ .queued_messages_flushed = steered });
        }
        // Budget exhausted: soft stop ends the turn gracefully (drain + hint +
        // event); hard stop keeps the historical error contract byte-for-byte.
        if (self.soft_stop_on_tool_call_limit) return self.softStopOnBudget(l, calls);
        return error.ToolCallLimit;
    }

    /// Graceful budget exhaustion: deliver everything the user queued mid-run
    /// (a queued "continue" must land in history, not be cleared at turn
    /// end), leave the continuation hint as the trailing message, and report
    /// the stop through the event stream. Always terminates the run — no
    /// auto-resume, so the budget stays a per-run bound (TD-6: continuation
    /// is the user's next submit).
    fn softStopOnBudget(self: *Agent, listener: anytype, calls: u32) !void {
        log.warn("tool-call budget exhausted after {d} iterations (limit {d}); soft-stopping turn", .{ calls, self.tool_call_limit_per_turn });
        const drained = try self.drainAllQueuedToHistory();
        if (drained > 0) try listener.emit(.{ .queued_messages_flushed = drained });
        try self.addUser(tool_budget_continuation_hint);
        try listener.emit(.{ .tool_budget_exhausted = self.tool_call_limit_per_turn });
    }

    /// React to a response severed by the provider's output token cap
    /// (`finish_reason=length`, no tool calls). Returns true when the caller
    /// must continue the run (the one-shot auto-continue fired: a hint was
    /// appended, the model gets re-requested); false when the turn should
    /// end (knob off, or the one-shot was already used this run) — the event
    /// still fires so the TUI renders a resumable notice instead of the cut
    /// passing as a complete answer.
    fn handleLengthCut(self: *Agent, listener: anytype, already_continued: bool) !bool {
        if (!self.auto_continue_on_length_cut or already_continued) {
            log.warn("turn ended on finish_reason=length with no tool calls — output token cap severed the response; not auto-continuing", .{});
            try listener.emit(.{ .length_cut = .stopped });
            return false;
        }
        log.warn("response cut by the output token cap (finish_reason=length, no tool calls) — auto-continuing once", .{});
        try listener.emit(.{ .length_cut = .auto_continued });
        try self.addUser(length_cut_continuation_hint);
        return true;
    }

    /// Hand the batch of tool_calls to the ExecutorService, bridge its
    /// ToolCallObserver callbacks into the agent's Event stream, and move
    /// the LLM-channel of each ToolResult into history.
    fn runToolBatch(
        comptime L: type,
        self: *Agent,
        tool_calls: []const ai.ToolCall,
        stream_context: *const StreamContext(L),
        listener: L,
        turn_allocator: std.mem.Allocator,
    ) !void {
        var bridge: ExecutorBridge(L) = .{
            .agent = self,
            .listener = listener,
            .stream_context = stream_context,
        };
        var executor = executor_mod.ExecutorService.init(.{
            .gpa = self.gpa,
            .scratch_allocator = turn_allocator,
            .io = self.io,
            .cwd = self.effectiveCwd(),
            .contained = self.contained,
            .bash_classifier_url = self.bash_classifier_url,
            .background = if (self.background_manager) |manager|
                .{ .manager = manager, .owner_generation = self.lane_generation }
            else
                null,
            .mcp_manager = self.mcp_manager,
            .tool_registry = self.tool_registry,
            .plugin_manager = self.plugin_manager,
            .lane_bridge = self.lane_bridge,
            .lane_requester = self,
            .skills = self.skills,
            .cancel_requested = self.cancel_requested,
        });
        const results = executor.runAll(tool_calls, bridge.observer()) catch |err| {
            if (err == error.Canceled) {
                if (self.cancel_requested) |flag| {
                    if (flag.load(.acquire)) return error.TurnCancelled;
                }
            }
            return err;
        };
        defer self.gpa.free(results);
        errdefer for (results) |*r| r.deinit(self.gpa);
        try self.takeToolResults(results);
        self.snapshotAfterBatch();
        try listener.emit(.tool_batch_finished);
    }

    /// Delegate to the extracted git-shadow snapshotter (agent/snapshotter.zig).
    fn snapshotAfterBatch(self: *Agent) void {
        if (self.snapshotter == null) self.snapshotter = .{ .gpa = self.gpa, .io = self.io };
        self.snapshotter.?.afterBatch(self.cwd, self.context_manager.session_writer);
    }

    /// Bridges ExecutorService's `ToolCallObserver` callbacks into the
    /// agent's Event stream. Tracks tool_index across the batch so the
    /// events line up with the tool_indexes the TUI saw during deltas.
    fn ExecutorBridge(comptime L: type) type {
        return struct {
            agent: *Agent,
            listener: L,
            stream_context: *const StreamContext(L),
            tool_index: u32 = 0,

            fn onStarted(ctx: *@This(), call: ai.ToolCall) anyerror!void {
                // Synthesise a tool_delta for the TUI if the LM did not stream
                // one for this tool_call (some servers emit the whole call in
                // one shot without intermediate deltas).
                if (!ctx.stream_context.toolDeltaSeen(ctx.tool_index)) {
                    try Agent.emitToolDelta(L, ctx.agent, ctx.listener, ctx.tool_index, call.name, call.arguments);
                    try ctx.listener.emit(.delta_end);
                }
                // Notify plugins at the tool-call boundary — safe because the
                // plugin's own handler has not been entered yet on this thread.
                if (ctx.agent.plugin_manager) |pm| pm.emitEvent(.{
                    .tool_call_started = .{ .name = call.name, .call_id = call.call_id.slice() },
                });
            }

            fn onFinished(ctx: *@This(), result: *const executor_mod.ToolResult) anyerror!void {
                // Notify plugins that the tool call completed.
                if (ctx.agent.plugin_manager) |pm| pm.emitEvent(.{
                    .tool_call_finished = .{
                        .name = result.name,
                        .call_id = result.call_id.slice(),
                        .success = !result.failed,
                    },
                });
                try Agent.emitToolCallFinished(
                    L,
                    ctx.agent,
                    ctx.listener,
                    ctx.tool_index,
                    result.call_id.slice(),
                    result.name,
                    result.display_label,
                    result.display_expanded_label,
                    result.display_body,
                    result.display_kind,
                    result.stderr,
                    result.failed,
                );
                ctx.tool_index += 1;
            }

            fn approveUnsafeBash(ctx: *@This(), call: ai.ToolCall, command: []const u8) anyerror!bool {
                _ = call;
                const approval = ctx.agent.bash_approval orelse return true;
                return approval.request(approval.ptr, command);
            }

            /// Build the executor's `ToolCallObserver` for this bridge. The
            /// observer's ctx is `*@This()` (the bridge itself), and the
            /// callbacks receive it typed — no `@ptrCast` at the seam.
            fn observer(self: *@This()) executor_mod.ToolCallObserver(@This()) {
                return .{
                    .ctx = self,
                    .on_started = onStarted,
                    .on_finished = onFinished,
                    .approve_unsafe_bash = approveUnsafeBash,
                };
            }
        };
    }

    /// Per-stream context shared between the agent and the ai client's
    /// stream observer callbacks. Holds the typed listener plus once-per-tool
    /// delta tracking. The `observer()` method builds a
    /// `StreamObserver(*Self)` whose callbacks are comptime-baked wrappers
    /// around this `StreamContext` and its typed listener — no
    /// `@ptrCast` at the seam.
    fn StreamContext(comptime L: type) type {
        return struct {
            agent: *Agent,
            listener: L,
            /// Fixed per-tool-slot "first delta seen" flags for the executor
            /// bridge, replacing the old grown `ArrayList(bool)` scan with an
            /// O(1) index. Sized by the SSOT `tool_call_array_cap`
            /// (stream_parser.zig), which already bounds the tool slots.
            tool_delta_seen: [stream_parser.tool_call_array_cap]bool = @splat(false),
            /// Coalesced content bytes awaiting a flush. Multiple consecutive
            /// `on_content` deltas accumulate here and are emitted as a single
            /// `response_delta`, cutting per-token allocs/locks on the dominant
            /// content path.
            pending_content: std.ArrayList(u8) = .empty,
            /// Coalesced reasoning bytes, flushed as a single `thinking_delta`.
            pending_reasoning: std.ArrayList(u8) = .empty,
            /// One-shot pre-sizing flags for the pending buffers (step #7); the
            /// ArrayList grows on first append, so these — not `capacity == 0` —
            /// are the reliable signal for the first-delta sizing hint.
            content_sized: bool = false,
            reasoning_sized: bool = false,

            const Self = @This();

            fn deinit(self: *Self) void {
                // Belt-and-suspenders flush: frees + flushes any bytes stranded
                // on an early-return/error path that skipped the explicit
                // end-of-stream flush. A no-op when that flush already cleared
                // the buffers. `deinit` returns void, so the error is swallowed;
                // the buffers are freed regardless (OOM is fatal to the turn).
                self.flushPending() catch {};
                self.pending_content.deinit(self.agent.gpa);
                self.pending_reasoning.deinit(self.agent.gpa);
            }

            fn toolDeltaSeen(self: *const Self, tool_index: u32) bool {
                if (tool_index >= self.tool_delta_seen.len) return false;
                return self.tool_delta_seen[tool_index];
            }

            fn markToolDeltaSeen(self: *Self, tool_index: u32) void {
                if (tool_index >= self.tool_delta_seen.len) return;
                self.tool_delta_seen[tool_index] = true;
            }

            /// Emit any pending content/reasoning as a single event each and
            /// reset the buffers, retaining capacity for the next batch.
            fn flushPending(self: *Self) !void {
                if (self.pending_reasoning.items.len > 0) {
                    const owned = try self.agent.gpa.dupe(u8, self.pending_reasoning.items);
                    try self.listener.emit(.{ .thinking_delta = owned });
                    self.pending_reasoning.clearRetainingCapacity();
                }
                if (self.pending_content.items.len > 0) {
                    const owned = try self.agent.gpa.dupe(u8, self.pending_content.items);
                    try self.listener.emit(.{ .response_delta = owned });
                    self.pending_content.clearRetainingCapacity();
                }
            }

            fn observer(self: *Self) ai.StreamObserver(Self) {
                return .{
                    .ctx = self,
                    .on_content = onContentDeltaImpl(L),
                    .on_reasoning = onReasoningDeltaImpl(L),
                    .on_tool_delta = onToolDeltaImpl(L),
                    .on_delta_end = onDeltaEndImpl(L),
                };
            }

            fn maybeSizeContent(self: *Self, delta: []const u8) !void {
                if (self.content_sized) return;
                try self.pending_content.ensureTotalCapacity(self.agent.gpa, delta.len * 4);
                self.content_sized = true;
            }

            fn maybeSizeReasoning(self: *Self, delta: []const u8) !void {
                if (self.reasoning_sized) return;
                try self.pending_reasoning.ensureTotalCapacity(self.agent.gpa, delta.len * 4);
                self.reasoning_sized = true;
            }
        };
    }

    fn onContentDeltaImpl(comptime L: type) *const fn (*StreamContext(L), []const u8) anyerror!void {
        const F = struct {
            fn call(ctx: *StreamContext(L), delta: []const u8) anyerror!void {
                // Preserve wire order: flush reasoning before buffering content
                // when a cross-type sequence fires reason-before-content.
                if (ctx.pending_reasoning.items.len > 0) try ctx.flushPending();
                try ctx.maybeSizeContent(delta);
                try ctx.pending_content.appendSlice(ctx.agent.gpa, delta);
                if (ctx.pending_content.items.len >= coalesce_threshold_bytes) {
                    try ctx.flushPending();
                }
            }
        };
        return &F.call;
    }

    fn onReasoningDeltaImpl(comptime L: type) *const fn (*StreamContext(L), []const u8) anyerror!void {
        const F = struct {
            fn call(ctx: *StreamContext(L), delta: []const u8) anyerror!void {
                // Preserve wire order: flush content before buffering reasoning.
                if (ctx.pending_content.items.len > 0) try ctx.flushPending();
                try ctx.maybeSizeReasoning(delta);
                try ctx.pending_reasoning.appendSlice(ctx.agent.gpa, delta);
                if (ctx.pending_reasoning.items.len >= coalesce_threshold_bytes) {
                    try ctx.flushPending();
                }
            }
        };
        return &F.call;
    }

    fn onToolDeltaImpl(comptime L: type) *const fn (*StreamContext(L), ai.ToolDelta) anyerror!void {
        const F = struct {
            fn call(ctx: *StreamContext(L), delta: ai.ToolDelta) anyerror!void {
                // Preserve wire order: flush any pending content/reasoning before
                // the tool preview so the transcript sees text first.
                try ctx.flushPending();
                ctx.markToolDeltaSeen(delta.index);
                try Agent.emitToolDelta(L, ctx.agent, ctx.listener, delta.index, delta.name, delta.arguments);
            }
        };
        return &F.call;
    }

    fn onDeltaEndImpl(comptime L: type) *const fn (*StreamContext(L)) anyerror!void {
        const F = struct {
            fn call(ctx: *StreamContext(L)) anyerror!void {
                // delta_end stays a pure no-op for coalescing: flushing here is
                // handled by the byte threshold, the cross-type flush, the tool
                // delta pre-flush, and the explicit post-prompt flush.
                try ctx.listener.emit(.delta_end);
            }
        };
        return &F.call;
    }

    fn emitToolDelta(
        comptime L: type,
        self: *Agent,
        listener: L,
        tool_index: u32,
        name: []const u8,
        arguments: []const u8,
    ) !void {
        const owned_name = try self.gpa.dupe(u8, name);
        const owned_arguments = try self.gpa.dupe(u8, arguments);
        try listener.emit(.{
            .tool_delta = .{
                .index = tool_index,
                .name = owned_name,
                .arguments = owned_arguments,
            },
        });
    }

    fn emitToolCallFinished(
        comptime L: type,
        self: *Agent,
        listener: L,
        tool_index: u32,
        call_id: []const u8,
        name: []const u8,
        display_label: []const u8,
        display_expanded_label: ?[]const u8,
        display_body: []const u8,
        display_kind: tools.DisplayKind,
        stderr: ?[]const u8,
        failed: bool,
    ) !void {
        const owned_id = try self.gpa.dupe(u8, call_id);
        const owned_name = try self.gpa.dupe(u8, name);
        const owned_label = try self.gpa.dupe(u8, display_label);
        const owned_expanded_label: ?[]u8 = if (display_expanded_label) |label|
            try self.gpa.dupe(u8, label)
        else
            null;
        const owned_body = try self.gpa.dupe(u8, display_body);
        const owned_stderr: ?[]u8 = if (stderr) |s|
            try self.gpa.dupe(u8, s)
        else
            null;
        try listener.emit(.{
            .tool_call_finished = .{
                .index = tool_index,
                .call_id = owned_id,
                .name = owned_name,
                .display_label = owned_label,
                .display_expanded_label = owned_expanded_label,
                .display_body = owned_body,
                .display_kind = display_kind,
                .stderr = owned_stderr,
                .failed = failed,
            },
        });
    }

    fn appendMessage(self: *Agent, role: ai.Role, content: []const u8) !void {
        var message = try self.makeTextMessage(role, content);
        errdefer message.deinit(self.gpa);
        try self.context_manager.appendPersisted(message);
    }

    /// True when the assistant message carries content the chat-completions wire
    /// format can represent: non-empty text or a tool call. Reasoning blocks are
    /// dropped by the serializer, so a reasoning-only message would go out as
    /// empty content with no tool_calls — rejected by strict providers.
    fn hasWireContent(message: ai.ChatMessage) bool {
        for (message.assistant.content) |block| switch (block) {
            .text => |t| if (t.text.len > 0) return true,
            .tool_call => return true,
            .reasoning, .image => {},
        };
        return false;
    }

    fn makeTextMessage(self: *Agent, role: ai.Role, content: []const u8) !ai.ChatMessage {
        assert(content.len > 0);
        const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
        errdefer self.gpa.free(blocks);
        blocks[0] = .{ .text = .{ .text = try self.gpa.dupe(u8, content) } };
        errdefer blocks[0].deinit(self.gpa);
        return switch (role) {
            .system => .{ .system = .{ .content = blocks } },
            .user => .{ .user = .{ .content = blocks } },
            .assistant => .{ .assistant = .{ .content = blocks } },
            .tool => error.InvalidToolRole,
        };
    }

    /// Build a fake tool message for tests that need a tool result without
    /// going through the executor. `call_id` defaults to "test_call".
    fn makeToolMessage(self: *Agent, content: []const u8) !ai.ChatMessage {
        assert(content.len > 0);
        const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
        errdefer self.gpa.free(blocks);
        blocks[0] = .{ .text = .{ .text = try self.gpa.dupe(u8, content) } };
        errdefer blocks[0].deinit(self.gpa);
        return .{
            .tool = .{
                .call_id = .{ .value = try self.gpa.dupe(u8, "test_call") },
                .content = blocks,
            },
        };
    }

    fn drainQueuedUserMessage(self: *Agent, steer_only: bool) !u32 {
        const queued = self.takeQueuedUserMessage(steer_only) orelse return 0;
        defer self.gpa.free(queued.prompt);
        // Raw (machine-generated) messages bypass `@`-mention expansion and skill
        // prefixing so their body is never reinterpreted; user-typed prompts go
        // through the full expansion path.
        if (queued.raw) try self.addUser(queued.prompt) else try self.addUserPrompt(queued.prompt);
        return 1;
    }

    /// Move every queued message into history in FIFO order, returning how many
    /// were drained. Used to deliver a stranded queue as a fresh turn (e.g.
    /// after a user interrupt): the leading messages become context and the
    /// last one is the latest user message the next prompt answers.
    pub fn drainAllQueuedToHistory(self: *Agent) !u32 {
        var count: u32 = 0;
        while ((try self.drainQueuedUserMessage(false)) > 0) count += 1;
        return count;
    }

    /// Drop every queued message without delivering it. Thread-safe; the worker
    /// drains under the same mutex.
    pub fn clearQueue(self: *Agent) void {
        if (self.message_queue_mutex.lock(self.io) catch null) |_| {
            defer self.message_queue_mutex.unlock(self.io);
            while (self.message_queue.pop(&self.message_queue_storage)) |queued| {
                self.gpa.free(queued.prompt);
            }
        }
    }

    /// Pop and return the front queued message. When `steer_only` is set, only
    /// pops if the front message is marked to steer (otherwise returns null,
    /// leaving the queue untouched). Caller owns `queued.prompt`.
    fn takeQueuedUserMessage(self: *Agent, steer_only: bool) ?QueuedUserMessage {
        if (self.message_queue_mutex.lock(self.io)) |_| {
            defer self.message_queue_mutex.unlock(self.io);
            if (steer_only) {
                const front = self.message_queue.peek(&self.message_queue_storage) orelse return null;
                if (!front.steer) return null;
            }
            return self.message_queue.pop(&self.message_queue_storage);
        } else |_| {
            return null;
        }
    }

    /// Mark the queued message at logical `index` to steer (inject after the
    /// next tool batch). Called from the UI thread; guarded by the queue mutex
    /// the worker also holds while draining.
    pub fn setQueuedSteer(self: *Agent, index: u32) void {
        if (self.message_queue_mutex.lock(self.io) catch null) |_| {
            defer self.message_queue_mutex.unlock(self.io);
            if (self.message_queue.at(&self.message_queue_storage, index)) |entry| entry.steer = true;
        }
    }

    fn takeAssistantMessage(self: *Agent, assistant: *ai.ChatMessage) !void {
        assert(assistant.* == .assistant);
        try self.context_manager.appendPersisted(assistant.*);
        assistant.* = undefined;
    }

    fn collectToolCallsAlloc(self: *Agent, allocator: std.mem.Allocator, assistant: ai.ChatMessage) ![]ai.ToolCall {
        _ = self;
        assert(assistant == .assistant);
        const content = assistant.assistant.content;
        var count: usize = 0;
        for (content) |block| {
            if (block == .tool_call) count += 1;
        }
        const calls = try allocator.alloc(ai.ToolCall, count);
        var index: usize = 0;
        for (content) |block| {
            if (block != .tool_call) continue;
            calls[index] = block.tool_call;
            index += 1;
        }
        return calls;
    }

    fn collectToolCalls(self: *Agent, assistant: ai.ChatMessage) ![]ai.ToolCall {
        return self.collectToolCallsAlloc(self.gpa, assistant);
    }

    /// T3: scan the assistant message's text blocks for tool calls a model
    /// emitted as literal text (weak function-calling models do this). Returns
    /// a freshly-allocated `[]ai.ToolCall` (possibly empty) whose element
    /// strings are independently owned — NOT aliased onto the message — so
    /// `injectRecoveredToolCalls` can move them into new blocks cleanly.
    /// Only scans `.text` blocks; reasoning blocks are ignored.
    fn recoverTextToolCalls(self: *Agent, assistant: ai.ChatMessage) ![]ai.ToolCall {
        if (assistant != .assistant) return &.{};
        var all: std.ArrayList(ai.ToolCall) = .empty;
        errdefer {
            for (all.items) |*c| c.deinit(self.gpa);
            all.deinit(self.gpa);
        }
        for (assistant.assistant.content) |block| {
            if (block != .text) continue;
            const found = try text_tool_call.extractFromText(self.gpa, block.text.text, &self.text_tool_seq);
            // `found`'s element strings are owned; appendSlice copies the
            // ToolCall values (shallow) into `all` — the element strings stay
            // alive because `all` now holds the only references. Free `found`'s
            // shell; the strings move with the values into `all`.
            defer self.gpa.free(found);
            try all.appendSlice(self.gpa, found);
        }
        return all.toOwnedSlice(self.gpa);
    }

    /// T3: append recovered tool calls as new `.tool_call` ContentBlocks into
    /// the assistant message's content slice, reallocating the slice.
    ///
    /// Ownership contract: the recovered `ToolCall`s' owned strings
    /// (call_id/name/arguments) are MOVED into the new blocks — callers must
    /// NOT free those strings, only the `recovered` slice shell. This mirrors
    /// `collectToolCalls`'s aliasing contract (slice shell caller-freed,
    /// element strings belong to the message). Existing blocks keep their
    /// strings — only the slice shell is reallocated.
    fn injectRecoveredToolCalls(self: *Agent, assistant: *ai.ChatMessage, recovered: []ai.ToolCall) !void {
        assert(assistant.* == .assistant);
        if (recovered.len == 0) return;
        const old = assistant.assistant.content;
        const new_blocks = try self.gpa.alloc(ai.ContentBlock, old.len + recovered.len);
        // Shallow copy: old blocks keep their owned strings.
        @memcpy(new_blocks[0..old.len], old);
        var i: usize = old.len;
        for (recovered) |tc| {
            new_blocks[i] = .{ .tool_call = tc }; // MOVED: strings now owned by this block
            i += 1;
        }
        // Free only the old slice shell — element strings were moved into new_blocks.
        self.gpa.free(old);
        assistant.assistant.content = new_blocks;
    }

    fn takeToolResults(self: *Agent, results: []executor_mod.ToolResult) !void {
        assert(results.len > 0);
        var moved: usize = 0;
        errdefer {
            for (results[moved..]) |*r| r.deinit(self.gpa);
        }
        for (results) |*r| {
            assert(r.call_id.value.len > 0);
            const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
            errdefer self.gpa.free(blocks);
            blocks[0] = .{ .text = .{ .text = r.content } };
            try self.context_manager.appendPersisted(.{
                .tool = .{
                    .content = blocks,
                    .call_id = r.call_id,
                    .display_label = r.display_label,
                    .failed = r.failed,
                },
            });
            self.gpa.free(r.name);
            if (r.display_expanded_label) |label| self.gpa.free(label);
            self.gpa.free(r.display_body);
            if (r.stderr) |s| self.gpa.free(s);
            r.* = undefined;
            moved += 1;
        }
    }

    /// Keep the prompt within the model's window using a background summarizer,
    /// so the agent never waits. Two watermarks: start the summary at the lower
    /// one (giving it time to finish), and swap it into history at the higher
    /// one (by when it is normally ready, so the swap is instant). Messages
    /// appended between the two watermarks survive the swap verbatim — the
    /// boundary references a tree entry id and the projection emits from it to
    /// the leaf. Best-effort: every failure is logged and swallowed so
    /// compaction never aborts the turn.
    /// Build the per-call environment for the auto-compactor from the live
    /// fields. Rebuilt on every call, so nothing borrows stale state across
    /// a client swap or session re-attach.
    fn compactionEnv(self: *Agent) auto_compactor_mod.Env {
        return .{
            .ctx = self,
            .gpa = self.gpa,
            .io = self.io,
            .client = self.compaction_client,
            .limiter = self.request_limiter,
            .session = self.context_manager.session_writer,
            .context_window_tokens = self.context_window_tokens,
            .settings = self.compaction_settings,
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
        return context_assembly.estimatePrunedTokensRange(
            self.context_manager.items(),
            anchor_count,
            self.compaction_settings.keep_recent_tool_turns,
            self.compaction_settings.historical_tool_cap_bytes,
        );
    }

    fn estimateAllTokensCb(ctx: *anyopaque) u32 {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        return context_assembly.estimatePrunedTokensRange(
            self.context_manager.items(),
            0,
            self.compaction_settings.keep_recent_tool_turns,
            self.compaction_settings.historical_tool_cap_bytes,
        );
    }

    /// Persist the compaction boundary, then reproject the cache — the
    /// swap. Order is the persist-before-cache invariant: the session tree
    /// is the source of truth, so a failed reprojection leaves the live
    /// cache intact instead of stranded with only the system prompt (TD-5).
    fn swapHistory(ctx: *anyopaque, first_kept_id: []const u8, stored_summary: []const u8) anyerror!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        const session_writer = self.context_manager.session_writer orelse return error.NoSessionWriter;
        try session_writer.appendCompaction(first_kept_id, stored_summary);
        try self.reloadFromSession();
    }

    /// Per-turn-iteration hook — delegates to the extracted state machine.
    pub fn maybeCompact(self: *Agent, listener: anytype) void {
        self.compactor.maybeCompact(self.compactionEnv(), listener);
    }

    /// Synchronous full compaction (headless/test path). See
    /// `AutoCompactor.forceCompact`.
    pub fn forceCompact(self: *Agent) !auto_compactor_mod.HistoryCompacted {
        return self.compactor.forceCompact(self.compactionEnv());
    }

    /// Non-blocking phase 1 of the manual `/compact`.
    pub fn requestManualCompact(self: *Agent) !void {
        return self.compactor.requestManualCompact(self.compactionEnv());
    }

    /// Non-blocking phase 2 of the manual `/compact`, polled by the TUI tick.
    pub fn pollManualCompact(self: *Agent) !?auto_compactor_mod.HistoryCompacted {
        return self.compactor.pollManualCompact(self.compactionEnv());
    }

    /// Whether a manual `/compact` is mid-flight (drives the TUI's submit
    /// gate and waiting row).
    pub fn manualCompactPending(self: *const Agent) bool {
        return self.compactor.manual_pending;
    }

    /// Wait for any in-flight background summary and discard it. Call before
    /// freeing or replacing `compaction_client` (teardown, reconnect).
    pub fn drainBackgroundCompaction(self: *Agent) void {
        self.compactor.drain(self.compactionEnv());
    }

    /// Best estimate of the footprint the *next* request will carry: the
    /// last turn's real reported usage as an anchor plus trailing estimates
    /// (see `AutoCompactor.currentContextTokens`).
    pub fn currentContextTokens(self: *Agent) u32 {
        return self.compactor.currentContextTokens(self.compactionEnv());
    }

    /// Record a completed turn's usage as the watermark anchor.
    pub fn recordUsage(self: *Agent, usage: ?ai.Usage) void {
        self.compactor.recordUsage(self.compactionEnv(), usage);
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
    fn reloadFromSession(self: *Agent) !void {
        const session_writer = self.context_manager.session_writer orelse return;
        // Project first, swap second: a failed reprojection leaves the live
        // cache intact instead of stranded with only the system prompt (TD-5).
        const projected = try session_writer.messages(self.gpa);
        errdefer self.gpa.free(projected);
        self.clearNonSystemMessages();
        for (projected) |message| try self.context_manager.appendUnpersisted(message);
        self.gpa.free(projected);
    }
};

/// Synchronous bash-approval hook. The TUI worker attaches a
/// `*Context` via the opaque `ptr`; `requestBashApproval` (in
/// `tui/agent_worker.zig`) is the bridge and is the only `@ptrCast`
/// left on this seam — making the field generic would require the
/// `Agent` struct itself to be generic, which is invasive. Kept as a
/// vtable; see type-safety-refactor.md P1-A follow-up for `BashApproval(Ctx)`.
pub const BashApproval = struct {
    ptr: *anyopaque,
    request: *const fn (*anyopaque, []const u8) anyerror!bool,
};

const tool_display = @import("tools/display.zig");
pub const parseCommand = tool_display.parseCommand;
pub const formatToolDisplay = tool_display.formatToolDisplay;

test "streaming callbacks emit owned events" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var openai_compatible_client: openai_compatible.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    const Seen = struct {
        events: std.ArrayList(Agent.Event) = .empty,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.events.items) |*event| {
                event.deinit(allocator);
            }
            self.events.deinit(allocator);
        }

        fn onEvent(ctx: *@This(), event: Agent.Event) !void {
            try ctx.events.append(std.testing.allocator, event);
        }
    };
    var seen: Seen = .{};
    defer seen.deinit(gpa);
    const Listener = Agent.Listener(Seen);
    var context: Agent.StreamContext(Listener) = .{
        .agent = &agent,
        .listener = .{ .ctx = &seen, .on_event = Seen.onEvent },
    };
    defer context.deinit();

    // Drive the wrapper functions the same way the ai stream layer would.
    try Agent.onReasoningDeltaImpl(Listener)(&context, "checking");
    try Agent.onContentDeltaImpl(Listener)(&context, "hello");
    try Agent.onToolDeltaImpl(Listener)(&context, .{
        .index = 1,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    });
    try Agent.onDeltaEndImpl(Listener)(&context);

    try std.testing.expectEqual(@as(usize, 4), seen.events.items.len);
    try std.testing.expectEqualStrings("checking", seen.events.items[0].thinking_delta);
    try std.testing.expectEqualStrings("hello", seen.events.items[1].response_delta);
    try std.testing.expectEqual(@as(u32, 1), seen.events.items[2].tool_delta.index);
    try std.testing.expectEqualStrings("bash", seen.events.items[2].tool_delta.name);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", seen.events.items[2].tool_delta.arguments);
    try std.testing.expectEqual(.delta_end, seen.events.items[3]);
    try std.testing.expect(context.toolDeltaSeen(1));
    try std.testing.expect(!context.toolDeltaSeen(0));
}

test "StreamContext coalesces small content deltas into one response_delta" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var openai_compatible_client: openai_compatible.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    const Seen = struct {
        events: std.ArrayList(Agent.Event) = .empty,
        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.events.items) |*event| event.deinit(allocator);
            self.events.deinit(allocator);
        }
        fn onEvent(ctx: *@This(), event: Agent.Event) !void {
            try ctx.events.append(std.testing.allocator, event);
        }
    };
    var seen: Seen = .{};
    defer seen.deinit(gpa);
    const Listener = Agent.Listener(Seen);
    var context: Agent.StreamContext(Listener) = .{
        .agent = &agent,
        .listener = .{ .ctx = &seen, .on_event = Seen.onEvent },
    };
    defer context.deinit();

    // Several small content deltas followed by a delta_end. None individually
    // reach the 1024-byte threshold, and onDeltaEnd does NOT flush — so only
    // the final explicit flush emits a single concatenated response_delta.
    const deltas = [_][]const u8{ "Hello ", "world ", "from ", "the ", "stream." };
    for (deltas) |d| try Agent.onContentDeltaImpl(Listener)(&context, d);
    try Agent.onDeltaEndImpl(Listener)(&context);
    try std.testing.expectEqual(@as(usize, 1), seen.events.items.len);
    try std.testing.expectEqual(.delta_end, seen.events.items[0]);

    try context.flushPending();
    try std.testing.expectEqual(@as(usize, 2), seen.events.items.len);
    try std.testing.expectEqualStrings("Hello world from the stream.", seen.events.items[1].response_delta);
}

test "StreamContext coalescing preserves wire order across types" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var openai_compatible_client: openai_compatible.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    const Seen = struct {
        events: std.ArrayList(Agent.Event) = .empty,
        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.events.items) |*event| event.deinit(allocator);
            self.events.deinit(allocator);
        }
        fn onEvent(ctx: *@This(), event: Agent.Event) !void {
            try ctx.events.append(std.testing.allocator, event);
        }
    };
    var seen: Seen = .{};
    defer seen.deinit(gpa);
    const Listener = Agent.Listener(Seen);
    var context: Agent.StreamContext(Listener) = .{
        .agent = &agent,
        .listener = .{ .ctx = &seen, .on_event = Seen.onEvent },
    };
    defer context.deinit();

    // A reasoning chunk followed by a content chunk. The cross-type flush must
    // emit the reasoning thinking_delta first, then the content response_delta.
    try Agent.onReasoningDeltaImpl(Listener)(&context, "thinking hard");
    try Agent.onContentDeltaImpl(Listener)(&context, "and answering");
    // Tool deltas flush any pending content first, then emit the tool delta.
    try Agent.onToolDeltaImpl(Listener)(&context, .{
        .index = 0,
        .name = "bash",
        .arguments = "{}",
    });

    try std.testing.expectEqual(@as(usize, 3), seen.events.items.len);
    try std.testing.expectEqualStrings("thinking hard", seen.events.items[0].thinking_delta);
    try std.testing.expectEqualStrings("and answering", seen.events.items[1].response_delta);
    try std.testing.expectEqual(@as(u32, 0), seen.events.items[2].tool_delta.index);
}

test "StreamContext coalesces the real per-chunk cadence" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var openai_compatible_client: openai_compatible.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    const Seen = struct {
        events: std.ArrayList(Agent.Event) = .empty,
        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.events.items) |*event| event.deinit(allocator);
            self.events.deinit(allocator);
        }
        fn onEvent(ctx: *@This(), event: Agent.Event) !void {
            try ctx.events.append(std.testing.allocator, event);
        }
    };
    var seen: Seen = .{};
    defer seen.deinit(gpa);
    const Listener = Agent.Listener(Seen);
    var context: Agent.StreamContext(Listener) = .{
        .agent = &agent,
        .listener = .{ .ctx = &seen, .on_event = Seen.onEvent },
    };
    defer context.deinit();

    // Mimic the real cadence: every small content chunk is followed by
    // delta_end. Coalescing must yield FEWER response_delta events than chunks,
    // flushing only at the threshold or at the explicit flush/deinit.
    const chunks = 40;
    for (0..chunks) |_| {
        try Agent.onContentDeltaImpl(Listener)(&context, "word ");
        try Agent.onDeltaEndImpl(Listener)(&context);
    }
    // No threshold crossed (5 bytes × 40 = 200 < 1024), so no response_delta yet.
    const before_flush = seen.events.items.len;
    for (seen.events.items[0..before_flush]) |ev| {
        if (std.mem.eql(u8, @tagName(ev), "response_delta")) return error.TestFailed;
    }

    try context.flushPending();
    const response_delta_count = blk: {
        var count: usize = 0;
        for (seen.events.items[before_flush..]) |ev| {
            switch (ev) {
                .response_delta => count += 1,
                else => {},
            }
        }
        break :blk count;
    };
    // Exactly one response_delta for the whole run — fewer than the 40 chunks.
    try std.testing.expectEqual(@as(usize, 1), response_delta_count);
    try std.testing.expectEqualStrings("word " ** chunks, seen.events.items[seen.events.items.len - 1].response_delta);
}

test "stream callbacks do not double-free when the listener returns an error" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var openai_compatible_client: openai_compatible.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    const FailingListener = struct {
        gpa: std.mem.Allocator,
        fn onEvent(self: *@This(), event: Agent.Event) anyerror!void {
            // Mirror `postAgentEvent`'s error path: it frees the event's owned
            // data before propagating the failure. The callbacks under test
            // must NOT free it again (that was the double-free bug).
            var ev = event;
            ev.deinit(self.gpa);
            return error.TestFailure;
        }
    };
    var failing: FailingListener = .{ .gpa = gpa };
    const Listener = Agent.Listener(FailingListener);
    var context: Agent.StreamContext(Listener) = .{
        .agent = &agent,
        .listener = .{ .ctx = &failing, .on_event = FailingListener.onEvent },
    };
    defer context.deinit();

    // Content deltas are coalesced — they don't emit until flushed. Build up
    // some pending content, then trigger a cross-type flush via reasoning
    // delta, which must propagate the listener's error without double-freeing.
    try Agent.onContentDeltaImpl(Listener)(&context, "delta");
    // The cross-type flush (pending_content -> response_delta) hits the
    // failing listener, which frees the owned slice and returns an error.
    // The callback must propagate the error without a double-free. The
    // buffer is left intact (flushPending clears only on success), so a
    // subsequent flush also fails — which is correct: the caller should
    // either handle the error or abort the stream.
    try std.testing.expectError(error.TestFailure, Agent.onReasoningDeltaImpl(Listener)(&context, "reasoning"));
    try std.testing.expectError(error.TestFailure, context.flushPending());

    // emitToolDelta emits directly (no coalescing), so it propagates the
    // listener's error without double-freeing the owned name/arguments.
    try std.testing.expectError(error.TestFailure, Agent.emitToolDelta(Listener, &agent, context.listener, 0, "name", "args"));
    try std.testing.expectError(error.TestFailure, Agent.emitToolCallFinished(Listener, &agent, context.listener, 0, "id", "name", "label", null, "body", .text, null, false));
}

test "run gates the request on the limiter and releases on the error path" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &client });
    defer agent.deinit();

    var limiter: request_limiter_mod.RequestLimiter = .{ .permits = 1 };
    agent.request_limiter = &limiter;

    var noop: NoopListener = .{};
    const listener: Agent.Listener(NoopListener) = .{
        .ctx = &noop,
        .on_event = NoopListener.onEvent,
    };
    // Dead server → the request fails after its retries; the labeled-block
    // `defer` must have released the permit, so none leaks on the error path.
    try std.testing.expectError(error.ConnectionFailed, agent.run(listener));
    try std.testing.expectEqual(@as(u32, 0), limiter.in_flight);
}

test "queued user messages wait for completed assistant turn" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try agent.addUser("first");
    try agent.enqueueUser("queued");

    try std.testing.expectEqual(@as(u32, 1), try agent.drainQueuedUserMessage(false));
    try std.testing.expectEqual(@as(usize, 2), agent.messages().len);
    try std.testing.expectEqualStrings("queued", agent.messages()[1].text());
}

test "interrupted tool calls get synthetic cancelled results" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // Assistant issues two tool calls; only the first got a result before the
    // user interrupted — leaving call_b dangling.
    const calls = try gpa.alloc(ai.ContentBlock, 2);
    calls[0] = .{ .tool_call = .{ .call_id = .{ .value = try gpa.dupe(u8, "call_a") }, .name = try gpa.dupe(u8, "read"), .arguments = try gpa.dupe(u8, "{}") } };
    calls[1] = .{ .tool_call = .{ .call_id = .{ .value = try gpa.dupe(u8, "call_b") }, .name = try gpa.dupe(u8, "bash"), .arguments = try gpa.dupe(u8, "{}") } };
    try agent.context_manager.appendUnpersisted(.{ .assistant = .{ .content = calls } });

    const result = try gpa.alloc(ai.ContentBlock, 1);
    result[0] = .{ .text = .{ .text = try gpa.dupe(u8, "ok") } };
    try agent.context_manager.appendUnpersisted(.{ .tool = .{ .call_id = .{ .value = try gpa.dupe(u8, "call_a") }, .content = result } });

    try agent.reconcileInterruptedToolCalls();

    // A synthetic failed result for call_b is appended right after; call_a is left
    // alone.
    const items = agent.messages();
    try std.testing.expectEqual(@as(usize, 3), items.len);
    const synthetic = items[2];
    try std.testing.expect(synthetic == .tool);
    try std.testing.expectEqualStrings("call_b", synthetic.tool.call_id.slice());
    try std.testing.expect(synthetic.tool.failed);

    // Idempotent: every call now has a result, so a second pass adds nothing.
    try agent.reconcileInterruptedToolCalls();
    try std.testing.expectEqual(@as(usize, 3), agent.messages().len);
}

test "recoverTextToolCalls recovers from a text block when there are zero structured calls" {
    // T3 unit test: the recovery helper, exercised on a realistic assistant
    // message — a single text block containing the DB-observed XML shape.
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "<tool_call>bash<arg_key=\"command\">echo recovered</arg_key></tool_call>") } };
    var assistant: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer assistant.deinit(gpa);

    const recovered = try agent.recoverTextToolCalls(assistant);
    defer {
        for (recovered) |*c| c.deinit(gpa);
        gpa.free(recovered);
    }
    try std.testing.expectEqual(@as(usize, 1), recovered.len);
    try std.testing.expectEqualStrings("bash", recovered[0].name);
    // The arg_key="command" pair is captured (the value sits on the opening tag).
    try std.testing.expectEqualStrings("{\"arg_key\":\"command\"}", recovered[0].arguments);
    try std.testing.expect(std.mem.startsWith(u8, recovered[0].call_id.slice(), "textcall_"));
}

test "injectRecoveredToolCalls appends without dropping existing blocks" {
    // T3 ownership test — the highest-risk failure mode. Build an assistant
    // with a text block, recover one call, inject it, and assert the message
    // now has 2 blocks (text + tool_call) with the original text intact. Run
    // under std.testing.allocator to catch any leak/double-free (the recovered
    // strings are MOVED into the new block, so the slice shell is freed but
    // NOT the element strings).
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "prefix <tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"x\"}}</tool_call> suffix") } };
    var assistant: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer assistant.deinit(gpa);

    const recovered = try agent.recoverTextToolCalls(assistant);
    // After inject, the element strings belong to the message — free only the shell.
    defer gpa.free(recovered);
    try std.testing.expectEqual(@as(usize, 1), recovered.len);

    try agent.injectRecoveredToolCalls(&assistant, recovered);
    // 2 blocks now: the original text + the injected tool_call.
    try std.testing.expectEqual(@as(usize, 2), assistant.assistant.content.len);
    try std.testing.expect(assistant.assistant.content[0] == .text);
    try std.testing.expectEqualStrings("prefix <tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"x\"}}</tool_call> suffix", assistant.assistant.content[0].text.text);
    try std.testing.expect(assistant.assistant.content[1] == .tool_call);
    try std.testing.expectEqualStrings("bash", assistant.assistant.content[1].tool_call.name);

    // collectToolCalls now sees the recovered call (the turn-loop window).
    const recollected = try agent.collectToolCalls(assistant);
    defer gpa.free(recollected);
    try std.testing.expectEqual(@as(usize, 1), recollected.len);
    try std.testing.expectEqualStrings("bash", recollected[0].name);
}

test "T3 turn-loop window: zero structured calls + text recovery yields executable tool_calls" {
    // Integration of the exact turn-loop window (collect → recover → inject)
    // without firing a full HTTP turn. Mirrors the ordering fact in plan §1.1:
    // recovery must run BEFORE takeAssistantMessage, and the recovered slice
    // drives execution via re-collection. No use-after-free because the
    // message is live throughout the window.
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // Simulate a turn whose assistant emitted a tool call as TEXT (zero
    // structured .tool_call blocks).
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "Sure! <tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"echo done\"}}</tool_call>") } };
    var assistant: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer assistant.deinit(gpa);

    // Step 1: collect — zero structured calls.
    const initial = try agent.collectToolCalls(assistant);
    defer gpa.free(initial);
    try std.testing.expectEqual(@as(usize, 0), initial.len);

    // Step 2: recover — fire because initial is empty.
    const recovered = try agent.recoverTextToolCalls(assistant);
    defer gpa.free(recovered);
    try std.testing.expectEqual(@as(usize, 1), recovered.len);

    // Step 3: inject so takeAssistantMessage persists the recovered call.
    try agent.injectRecoveredToolCalls(&assistant, recovered);

    // Step 4: the slice that would drive execution (recovered, per plan §2.2)
    // has length > 0 → runToolBatch would fire, not the idle-drain branch.
    const tool_calls: []const ai.ToolCall = recovered;
    try std.testing.expect(tool_calls.len > 0);
    try std.testing.expectEqualStrings("bash", tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"echo done\"}", tool_calls[0].arguments);
}

test "context token estimate anchors on usage plus trailing messages" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // Anchor on a reported usage just after an assistant reply (1 message).
    try agent.context_manager.appendUnpersisted(try agent.makeTextMessage(.assistant, "a" ** 40));
    agent.recordUsage(.{ .input_tokens = 1000, .output_tokens = 200, .total_tokens = 1200 });
    // A tool result appended afterwards (~40 bytes -> 10 estimated tokens).
    try agent.context_manager.appendUnpersisted(try agent.makeToolMessage("b" ** 40));

    // anchor total (1000 + 200) + trailing estimate (10) = 1210
    try std.testing.expectEqual(@as(u32, 1210), agent.currentContextTokens());
}

test "queued user messages drain one at a time" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try agent.enqueueUser("first");
    try agent.enqueueUser("second");

    try std.testing.expectEqual(@as(u32, 1), try agent.drainQueuedUserMessage(false));
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expectEqual(@as(u32, 1), agent.message_queue.len());
    try std.testing.expectEqualStrings("first", agent.messages()[0].text());
}

test "steer-only drain pops a steered front but leaves default-queued messages" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try agent.enqueueUser("steer me");
    try agent.enqueueUser("later");
    agent.setQueuedSteer(0);

    // The steered front injects mid-turn...
    try std.testing.expectEqual(@as(u32, 1), try agent.drainQueuedUserMessage(true));
    try std.testing.expectEqualStrings("steer me", agent.messages()[0].text());
    // ...but the default-queued one behind it waits for turn end.
    try std.testing.expectEqual(@as(u32, 0), try agent.drainQueuedUserMessage(true));
    try std.testing.expectEqual(@as(u32, 1), agent.message_queue.len());
    // The turn-end drain (steer_only = false) takes it.
    try std.testing.expectEqual(@as(u32, 1), try agent.drainQueuedUserMessage(false));
    try std.testing.expectEqualStrings("later", agent.messages()[1].text());
}

test "drain all queued moves the whole queue to history in FIFO order" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try agent.enqueueUser("a");
    try agent.enqueueUser("b");
    try agent.enqueueUser("c");

    try std.testing.expectEqual(@as(u32, 3), try agent.drainAllQueuedToHistory());
    try std.testing.expectEqual(@as(usize, 3), agent.messages().len);
    try std.testing.expectEqualStrings("a", agent.messages()[0].text());
    try std.testing.expectEqualStrings("c", agent.messages()[2].text());
    try std.testing.expectEqual(@as(u32, 0), agent.message_queue.len());
}

/// Mutex-wrapped allocator facade for the concurrency test below: the raw
/// testing allocator is not thread-safe, and both the enqueuer and the
/// drainer allocate through `agent.gpa`. (Same shape as tui/test_helpers'
/// `LockedAllocator`, re-declared here so agent tests don't import the TUI.)
const TestLockedAllocator = struct {
    child: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub fn allocator(self: *TestLockedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TestLockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TestLockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TestLockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TestLockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "concurrent enqueue and drain never deadlock or lose messages" {
    // Test-gap closure (PRIORITY_ACTIONS): the UI thread enqueues while a
    // worker-shaped task drains — the queue mutex guards only push/pop, and
    // the lock-failure-tolerant paths (`clearQueue`/`setQueuedSteer` treat
    // lock failure as a no-op) must not drop or corrupt entries under
    // contention. FIFO order and the exact count are the assertion; a
    // deadlock surfaces as the test runner's timeout.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var safe_gpa = TestLockedAllocator{ .child = gpa, .io = io };
    const alg = safe_gpa.allocator();

    var agent = Agent.init(alg, io, ".", .none);
    defer agent.deinit();

    const Drainer = struct {
        fn run(a: *Agent, done: *std.atomic.Value(bool)) void {
            var spins: u32 = 0;
            while (!done.load(.acquire)) : (spins += 1) {
                if (spins > 100_000) return; // bounded: never spin forever
                _ = a.drainAllQueuedToHistory() catch return;
                std.testing.io.sleep(.fromMilliseconds(1), .awake) catch return;
            }
        }
    };
    var done = std.atomic.Value(bool).init(false);
    var task = try io.concurrent(Drainer.run, .{ &agent, &done });

    const total: usize = 200;
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    // Block-scoped errdefer: an enqueue-section failure still stops and joins
    // the drainer before `agent.deinit` (the block exit guarantees it can
    // never double-await the post-join section).
    {
        errdefer {
            done.store(true, .release);
            task.await(io);
        }
        while (i < total) : (i += 1) {
            const text = try std.fmt.bufPrint(&buf, "m{d}", .{i});
            // Retry on QueueFull: the drainer is consuming concurrently, so
            // the 64-slot queue drains — the loop terminates.
            var spins: u32 = 0;
            while (true) : (spins += 1) {
                try std.testing.expect(spins < 100_000);
                agent.enqueueUser(text) catch |err| switch (err) {
                    error.QueueFull => {
                        io.sleep(.fromMilliseconds(1), .awake) catch {};
                        continue;
                    },
                    else => return err,
                };
                break;
            }
            // Exercise the steer-marking path under contention too (mark the
            // front entry; `drainAllQueuedToHistory` drains it regardless).
            if (i % 50 == 0) agent.setQueuedSteer(0);
        }
    }
    done.store(true, .release);
    // Single await: the drainer exits within one 1 ms sleep of the flag.
    task.await(io);
    // Drain whatever the drainer hadn't reached when the flag flipped.
    while (agent.message_queue.len() > 0) {
        try std.testing.expect(try agent.drainAllQueuedToHistory() > 0);
    }

    // No loss, FIFO preserved, nothing left behind.
    const messages = agent.messages();
    try std.testing.expectEqual(total, messages.len);
    try std.testing.expectEqualStrings("m0", messages[0].text());
    try std.testing.expectEqualStrings("m199", messages[total - 1].text());
    try std.testing.expectEqual(@as(u32, 0), agent.message_queue.len());
}

const BudgetSeen = struct {
    events: std.ArrayList(Agent.Event) = .empty,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.events.items) |*event| event.deinit(allocator);
        self.events.deinit(allocator);
    }

    fn onEvent(ctx: *@This(), event: Agent.Event) !void {
        try ctx.events.append(std.testing.allocator, event);
    }
};

test "softStopOnBudget drains queue, appends hint, emits events" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.tool_call_limit_per_turn = 7;

    try agent.enqueueUser("first");
    try agent.enqueueUser("second");

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);
    const listener = Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent };

    try agent.softStopOnBudget(listener, 7);

    // Everything queued landed in history in FIFO order, and the trailing
    // continuation hint is the last message — a `.user` machine message so
    // it persists (`SessionWriter.append` skips `.system`).
    try std.testing.expectEqual(@as(usize, 3), agent.messages().len);
    try std.testing.expectEqualStrings("first", agent.messages()[0].text());
    try std.testing.expectEqualStrings("second", agent.messages()[1].text());
    try std.testing.expect(std.mem.startsWith(u8, agent.messages()[2].text(), "[zay] This turn stopped"));
    try std.testing.expect(agent.messages()[2].role() == .user);
    try std.testing.expect(!agent.hasQueuedMessages());

    // Flush first (so the transcript shows the delivered user rows), then the
    // terminal budget event carrying the configured limit.
    try std.testing.expectEqual(@as(usize, 2), seen.events.items.len);
    try std.testing.expectEqual(@as(u32, 2), seen.events.items[0].queued_messages_flushed);
    try std.testing.expectEqual(@as(u32, 7), seen.events.items[1].tool_budget_exhausted);
}

test "softStopOnBudget with empty queue emits only the budget event" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);
    const listener = Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent };

    try agent.softStopOnBudget(listener, agent.tool_call_limit_per_turn);

    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expect(std.mem.startsWith(u8, agent.messages()[0].text(), "[zay] This turn stopped"));
    try std.testing.expectEqual(@as(usize, 1), seen.events.items.len);
    try std.testing.expectEqual(@as(u32, 100), seen.events.items[0].tool_budget_exhausted);
}

test "handleLengthCut auto-continues once then stops" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);
    const listener = Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent };

    // First cut: the one-shot auto-continue fires — a `.user` continuation
    // hint (persistable, like the budget hint) lands in history and the
    // continuing event is emitted so the TUI keeps the turn open.
    try std.testing.expect(try agent.handleLengthCut(listener, false));
    try std.testing.expectEqual(@as(usize, 1), seen.events.items.len);
    try std.testing.expectEqual(Agent.Event.LengthCut.auto_continued, seen.events.items[0].length_cut);
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expect(agent.messages()[0].role() == .user);
    try std.testing.expect(std.mem.startsWith(u8, agent.messages()[0].text(), "[zay] Your previous response was cut off"));

    // Second cut in the same run: the one-shot is exhausted — the turn ends
    // with the stopped event and no extra hint message.
    try std.testing.expect(!try agent.handleLengthCut(listener, true));
    try std.testing.expectEqual(@as(usize, 2), seen.events.items.len);
    try std.testing.expectEqual(Agent.Event.LengthCut.stopped, seen.events.items[1].length_cut);
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
}

test "handleLengthCut with the knob off only emits the stopped event" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.auto_continue_on_length_cut = false;

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);
    const listener = Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent };

    try std.testing.expect(!try agent.handleLengthCut(listener, false));
    try std.testing.expectEqual(@as(usize, 1), seen.events.items.len);
    try std.testing.expectEqual(Agent.Event.LengthCut.stopped, seen.events.items[0].length_cut);
    try std.testing.expectEqual(@as(usize, 0), agent.messages().len);
}

const mock_http_server = @import("ai/mock_http_server.zig");
const MockHttpServer = mock_http_server.MockHttpServer;

test "run auto-continues once after a length-cut stream" {
    if (os.is_windows) {
        // Truncation-class socket gate — see openai_compatible.zig (#32).
        return error.SkipZigTest;
    }
    // Integration test over a real socket: the first response is a
    // chat-completions stream severed at the output token cap (text-only,
    // finish_reason=length); the second is a normal stop. `Agent.run` must
    // emit the continuing notice, append the hint, re-request exactly once,
    // and end with both assistant messages in history.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockHttpServer.init(io, &.{
        .{ .status = .ok, .body = "data: {\"choices\":[{\"finish_reason\":null,\"delta\":{\"role\":\"assistant\",\"content\":\"partial plan\"}}]}\n" ++
            "data: {\"choices\":[{\"finish_reason\":\"length\",\"delta\":{}}]}\n" ++
            "data: [DONE]\n" },
        .{ .status = .ok, .body = "data: {\"choices\":[{\"finish_reason\":null,\"delta\":{\"content\":\"continued\"}}]}\n" ++
            "data: {\"choices\":[{\"finish_reason\":\"stop\",\"delta\":{}}]}\n" ++
            "data: [DONE]\n" },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockHttpServer.serve, .{&server});
    defer thread.join();

    const openai_compatible = @import("ai/openai_compatible.zig");
    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1", .{server.port()});
    var client: openai_compatible.Client = undefined;
    try client.init(gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        // No sleeping between retries in tests.
        .retry_base_delay_ms = 0,
    });
    // `init` deep-copies the config (including the request URL) — the
    // temporary base_url is not retained, so free it.
    gpa.free(base_url);
    defer client.deinit();

    var agent = Agent.init(gpa, io, ".", .{ .openai_compatible = &client });
    defer agent.deinit();
    try agent.addUser("write a long plan");

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);

    try agent.run(Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent });

    // Exactly two requests hit the scripted server (the cut + the
    // continuation); a third would hang on script exhaustion, so this
    // assertion is the loop-guard's observable.
    try std.testing.expectEqual(@as(u32, 2), server.connection_count.load(.monotonic));

    // One continuing notice, never a stopped one (the one-shot fired).
    var length_cut_events: usize = 0;
    for (seen.events.items) |event| {
        if (event == .length_cut) {
            length_cut_events += 1;
            try std.testing.expectEqual(Agent.Event.LengthCut.auto_continued, event.length_cut);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), length_cut_events);

    // History: user, assistant("partial plan"), user continuation hint,
    // assistant("continued") — the hint lands AFTER the persisted partial
    // prose so the wire shape stays [.., assistant, user-hint].
    const messages = agent.messages();
    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqualStrings("write a long plan", messages[0].text());
    try std.testing.expect(messages[1].role() == .assistant);
    try std.testing.expectEqualStrings("partial plan", messages[1].text());
    try std.testing.expect(messages[2].role() == .user);
    try std.testing.expect(std.mem.startsWith(u8, messages[2].text(), "[zay] Your previous response was cut off"));
    try std.testing.expect(messages[3].role() == .assistant);
    try std.testing.expectEqualStrings("continued", messages[3].text());
}

test "run retries once when the provider truncates tool-call arguments" {
    if (os.is_windows) {
        // Truncation-class socket gate — see openai_compatible.zig (#32).
        return error.SkipZigTest;
    }
    // Integration test over a real socket mirroring the intern-ai/internlm
    // gateway signature: the first response ends with finish_reason=tool_calls
    // but the arguments payload never streamed (the parser drops the call and
    // surfaces `tool_calls_truncated`=1). Agent.run must NOT dispatch a bare
    // {} call; it injects the truncation hint and re-requests exactly once.
    // The second response carries a complete tool call which then executes.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockHttpServer.init(io, &.{
        .{ .status = .ok, .body = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"chatcmpl-tool-abc\",\"function\":{\"name\":\"pwsh\"}}]}}]}\n" ++
            "data: {\"choices\":[{\"finish_reason\":\"tool_calls\",\"delta\":{}}]}\n" ++
            "data: [DONE]\n" },
        .{ .status = .ok, .body = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"chatcmpl-tool-def\",\"function\":{\"name\":\"pwsh\",\"arguments\":\"{\\\"command\\\":\\\"echo hi\\\"}\"}}]}}]}\n" ++
            "data: {\"choices\":[{\"finish_reason\":\"tool_calls\",\"delta\":{}}]}\n" ++
            "data: [DONE]\n" },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockHttpServer.serve, .{&server});
    defer thread.join();

    const openai_compatible = @import("ai/openai_compatible.zig");
    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1", .{server.port()});
    var client: openai_compatible.Client = undefined;
    try client.init(gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .retry_base_delay_ms = 0,
    });
    gpa.free(base_url);
    defer client.deinit();

    var agent = Agent.init(gpa, io, ".", .{ .openai_compatible = &client });
    defer agent.deinit();
    try agent.addUser("list the directory");

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);

    try agent.run(Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent });

    // Exactly two requests hit the scripted server (the truncated call + the
    // retry with the hint). A third would hang on script exhaustion, so this
    // assertion is the loop-guard's observable: the truncation hint is
    // injected, the model retries once and succeeds — the run does NOT loop.
    try std.testing.expectEqual(@as(u32, 2), server.connection_count.load(.monotonic));

    // History: user, assistant (empty — the truncated call produced no
    // content blocks, so takeAssistantMessage stored nothing), user hint,
    // assistant + tool_call, tool result.
    const messages = agent.messages();
    try std.testing.expect(messages.len >= 3);
    // The hint must be present, telling the model its arguments were severed.
    var hint_found = false;
    for (messages) |m| {
        if (m.role() == .user and std.mem.startsWith(u8, m.text(), "[zay] Your tool call(s) arrived without their arguments")) {
            hint_found = true;
        }
    }
    try std.testing.expect(hint_found);
}

// ── Scripted-adapter twins ───────────────────────────────────────────────
//
// The tests below drive `Agent.run` through `ai.scripted_client` — the
// in-memory second adapter on the LanguageModel seam — so they run on every
// platform, including Windows where the truncation-class socket suites above
// are gated (#32). Wire-shape coverage stays with the socket suites; these
// pin the run-loop behaviour itself.

test "run completes a scripted text turn and streams deltas through the observer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try ai.scripted_client.Client.init(gpa, io, "scripted-model");
    defer client.deinit();
    try client.enqueue(.{ai.scripted_client.step.text("hello from the script", .stop)});

    var agent = Agent.init(gpa, io, ".", .{ .scripted = &client });
    defer agent.deinit();
    try agent.addUser("say hi");

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);

    try agent.run(Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent });

    try std.testing.expectEqual(@as(u32, 1), client.prompts_answered);

    // The scripted chunks stream through the same observer a real client
    // drives; the response_delta bytes must join to the scripted text.
    var delta_text: std.ArrayList(u8) = .empty;
    defer delta_text.deinit(gpa);
    for (seen.events.items) |event| {
        if (event == .response_delta) try delta_text.appendSlice(gpa, event.response_delta);
    }
    try std.testing.expectEqualStrings("hello from the script", delta_text.items);

    // History: user prompt, assistant reply.
    const messages = agent.messages();
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("say hi", messages[0].text());
    try std.testing.expectEqualStrings("hello from the script", messages[1].text());
}

test "run retries once when the provider truncates tool-call arguments (scripted, socket-free)" {
    // Windows-runnable twin of the socket suite above: the scripted adapter
    // produces the `tool_calls_truncated` signature directly, so the run
    // loop's severed-arguments guard (inject hint, re-request exactly once)
    // is testable without a network stack.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try ai.scripted_client.Client.init(gpa, io, "scripted-model");
    defer client.deinit();
    try client.enqueue(.{
        ai.scripted_client.step.truncatedToolCalls(1),
        ai.scripted_client.step.text("done after retry", .stop),
    });

    var agent = Agent.init(gpa, io, ".", .{ .scripted = &client });
    defer agent.deinit();
    try agent.addUser("list the directory");

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);

    try agent.run(Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent });

    // Exactly two prompts: the truncated turn, then the hint retry. A third
    // would exhaust the script.
    try std.testing.expectEqual(@as(u32, 2), client.prompts_answered);
    // The retry actually carried the hint to the model.
    try std.testing.expect(client.last_user_text != null);
    try std.testing.expect(std.mem.startsWith(u8, client.last_user_text.?, "[zay] Your tool call(s) arrived without their arguments"));

    // The truncated turn's empty assistant stored nothing; the hint and the
    // retried reply close out history.
    const messages = agent.messages();
    try std.testing.expect(messages.len >= 3);
    var hint_found = false;
    for (messages) |m| {
        if (m.role() == .user and std.mem.startsWith(u8, m.text(), "[zay] Your tool call(s) arrived without their arguments")) {
            hint_found = true;
        }
    }
    try std.testing.expect(hint_found);
    try std.testing.expectEqualStrings("done after retry", messages[messages.len - 1].text());
}

test "run executes a synced MCP tool through the registry (scripted, socket-free)" {
    // Worker-MCP regression (PRIORITY_ACTIONS HIGH #2): a contained agent —
    // the lane-worker shape — dispatches an MCP tool end-to-end through the
    // shared registry. The fake client's zeroed child makes the transport
    // fail, so the history tool result must be the MCP bridge's failure
    // ("MCP tool 'search' failed") and NEVER "unknown tool" (the registry
    // lookup miss this test guards against).
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const mcp_client_mod = @import("mcp/client.zig");

    var manager = mcp_mod.McpManager.init(gpa);
    defer manager.deinit(io);
    {
        // Heap-allocated (not &.{}): McpTool.deinit frees the property strings
        // and reads the array when the manager is torn down.
        const props = try gpa.alloc(tools.Schema.Property, 1);
        props[0] = .{
            .name = try gpa.dupe(u8, "query"),
            .kind = .string,
            .description = try gpa.dupe(u8, "Query text"),
            .required = true,
        };
        var client = try mcp_client_mod.McpClient.init(gpa, "test", "echo", &.{}, null);
        client.lifecycle = .{ .stdio = .{ .process = mcp_client_mod.zeroedChild(), .status = .ready } };
        try client.addTool("search", "Search the index", .{ .properties = props });
        try manager.clients.append(gpa, client);
    }
    var reg = try tools.ToolRegistry.init(gpa, tools.builtinRegistry());
    defer reg.deinit(gpa);
    try reg.syncMcpTools(gpa, &manager);

    var client = try ai.scripted_client.Client.init(gpa, io, "scripted-model");
    defer client.deinit();
    try client.enqueue(.{
        ai.scripted_client.step.toolCall("mcp__test__search", "{\"query\":\"x\"}"),
        ai.scripted_client.step.text("done", .stop),
    });

    var agent = Agent.init(gpa, io, ".", .{ .scripted = &client });
    defer agent.deinit();
    agent.tool_registry = &reg;
    agent.mcp_manager = &manager;
    agent.contained = true;
    try agent.addUser("search for x");

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);
    try agent.run(Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent });

    // Two prompts: the tool-call turn and the closing text turn. A third
    // would exhaust the script.
    try std.testing.expectEqual(@as(u32, 2), client.prompts_answered);
    var tool_result: ?[]const u8 = null;
    for (agent.messages()) |m| {
        if (m.role() == .tool) tool_result = m.text();
    }
    try std.testing.expect(tool_result != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_result.?, "unknown tool") == null);
    try std.testing.expect(std.mem.indexOf(u8, tool_result.?, "MCP tool 'search' failed") != null);
}

test "run ends the turn when tool-call arguments truncate on the retry too" {
    // The stop arm of the truncation guard: the one-shot is spent, so a
    // second severed response must END the turn (`.length_cut = .stopped`)
    // instead of billing an unbounded retry loop. Socket-free via the
    // scripted adapter.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try ai.scripted_client.Client.init(gpa, io, "scripted-model");
    defer client.deinit();
    try client.enqueue(.{
        ai.scripted_client.step.truncatedToolCalls(1),
        ai.scripted_client.step.truncatedToolCalls(1),
    });

    var agent = Agent.init(gpa, io, ".", .{ .scripted = &client });
    defer agent.deinit();
    try agent.addUser("list the directory");

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);

    try agent.run(Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent });

    // Two prompts exactly: the guard retried once, then stopped the turn.
    try std.testing.expectEqual(@as(u32, 2), client.prompts_answered);
    var stopped: usize = 0;
    for (seen.events.items) |event| {
        if (event == .length_cut and event.length_cut == .stopped) stopped += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), stopped);
}

test "run auto-continues once after a scripted length-cut (socket-free)" {
    // Windows-runnable twin of the length-cut socket suite: the scripted
    // adapter returns finish_reason=.length directly, pinning the one-shot
    // auto-continue and the wire shape of the continuation without a socket.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try ai.scripted_client.Client.init(gpa, io, "scripted-model");
    defer client.deinit();
    try client.enqueue(.{
        ai.scripted_client.step.text("partial plan", .length),
        ai.scripted_client.step.text("continued", .stop),
    });

    var agent = Agent.init(gpa, io, ".", .{ .scripted = &client });
    defer agent.deinit();
    try agent.addUser("write a long plan");

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);

    try agent.run(Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent });

    try std.testing.expectEqual(@as(u32, 2), client.prompts_answered);

    // One auto-continue, never a stopped notice — the one-shot fired.
    var auto_continued: usize = 0;
    var stopped: usize = 0;
    for (seen.events.items) |event| {
        if (event == .length_cut) {
            if (event.length_cut == .auto_continued) {
                auto_continued += 1;
            } else {
                stopped += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), auto_continued);
    try std.testing.expectEqual(@as(usize, 0), stopped);

    // History: user, assistant("partial plan"), continuation hint,
    // assistant("continued") — the hint lands AFTER the persisted partial
    // prose.
    const messages = agent.messages();
    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqualStrings("write a long plan", messages[0].text());
    try std.testing.expectEqualStrings("partial plan", messages[1].text());
    try std.testing.expect(std.mem.startsWith(u8, messages[2].text(), "[zay] Your previous response was cut off"));
    try std.testing.expectEqualStrings("continued", messages[3].text());
}

test "raw enqueued messages are delivered verbatim without @-mention expansion" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try std.testing.expect(!agent.hasQueuedMessages());
    // A background completion notice may contain an `@` that must not be treated
    // as a file mention.
    try agent.enqueueRaw("Background command bg_1 (`echo @no/such/file`) finished — exit 0");
    try std.testing.expect(agent.hasQueuedMessages());

    try std.testing.expectEqual(@as(u32, 1), try agent.drainQueuedUserMessage(false));
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expectEqualStrings(
        "Background command bg_1 (`echo @no/such/file`) finished — exit 0",
        agent.messages()[0].text(),
    );
    try std.testing.expect(!agent.hasQueuedMessages());
}

test "clear queue drops messages without delivering them" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try agent.enqueueUser("x");
    try agent.enqueueUser("y");
    agent.clearQueue();

    try std.testing.expectEqual(@as(u32, 0), agent.message_queue.len());
    try std.testing.expectEqual(@as(usize, 0), agent.messages().len);
}

// ── P1: compaction / checkpoint core regression tests ──────────────────
//
// The highest-edge-density cluster (snapshotAfterBatch, runToolBatch,
// maybeCompact, forceCompact, applyReadyCompaction) was entirely test-free,
// the same path the da7c761 resume-segfault class of regressions comes from.
// These cover the no-op / early-return contracts documented in the pseudocode:
// disabled compaction, sub-watermark, the failed-compactor discard, and the
// snapshot short-circuits that latch `snapshots_disabled` off silently.

/// No-op listener for `maybeCompact`: compaction events are discarded. The
/// agent owns nothing from it, so there is no per-test cleanup.
const NoopListener = struct {
    fn onEvent(_: *@This(), _: Agent.Event) !void {}
};

test "snapshotAfterBatch: disabled snapshots return without touching git" {
    // The `disabled` latch is the early return before any vcs call, so this
    // exercises the no-git-available branch without needing a repo.
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    agent.snapshotter = .{ .gpa = gpa, .io = std.testing.io, .disabled = true };
    agent.snapshotAfterBatch(); // must not error or allocate

    try std.testing.expect(agent.snapshotter.?.disabled);
    try std.testing.expect(agent.snapshotter.?.index_path == null);
    try std.testing.expect(agent.snapshotter.?.last_tree == null);
}

test "snapshotAfterBatch: no session writer short-circuits silently" {
    // Without a session_writer the function returns at the second guard, also
    // never touching git — confirming the best-effort contract holds even when
    // git IS available but no session is attached.
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // The latch stays false, but no session_writer is attached.
    agent.snapshotAfterBatch();

    // No panic, no error; the latch was untouched because the short-circuit
    // never reached the git-availability probe.
    try std.testing.expect(!agent.snapshotter.?.disabled);
}

test "maybeCompact: disabled auto stays a no-op below the watermark" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // No compaction_client and no context window: every guard short-circuits.
    // Setting auto=false first makes the intent explicit even though the other
    // guards would also bail.
    agent.compaction_settings.auto = false;
    var noop: NoopListener = .{};
    const listener: Agent.Listener(NoopListener) = .{
        .ctx = &noop,
        .on_event = NoopListener.onEvent,
    };
    agent.maybeCompact(listener);

    // Compactor never left idle, no event emitted (noop listener would error
    // otherwise — there is nothing to assert beyond not panicking).
    try std.testing.expect(agent.compactor.core.stateIs(.idle));
}

test "forceCompact: no compaction client returns NoCompactionClient without swapping" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // The very first guard: compaction_client == .none.
    try std.testing.expectError(error.NoCompactionClient, agent.forceCompact());
    try std.testing.expect(agent.compactor.core.stateIs(.idle));
}

test "forceCompact: window guard fires before the writer guard" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // The guard order is NoCompactionClient → UnknownContextWindow →
    // NoSessionWriter (see forceCompact body). With a `.none` client the first
    // guard wins regardless of the other fields, so the function never reaches
    // the writer check — confirming the order matches the source.
    agent.context_window_tokens = 4096; // would pass the window guard
    try std.testing.expectError(error.NoCompactionClient, agent.forceCompact());
    try std.testing.expect(agent.compactor.core.stateIs(.idle));
}

/// Add `count` long persisted user messages so a compaction cut exists under
/// the default keep budget. Each message is ~370 tokens; `cutByTokenBudget`
/// only cuts once the newest (len-1) messages already exceed the budget, so
/// `count` must be comfortably past the 1433-token budget for a 4096 window.
/// 10 × 370 = 3700 total, newest 9 = 3330 > budget — a cut past the first
/// message. Pub so the TUI tests can reuse the same session shape.
pub fn fillSessionForCompaction(agent: *Agent, count: usize) !void {
    const filler =
        "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur excepteur sint occaecat cupidatat non proident sunt in culpa qui officia deserunt mollit anim id est laborum " ++
        "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur excepteur sint occaecat cupidatat non proident sunt in culpa qui officia deserunt mollit anim id est laborum " ++
        "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur excepteur sint occaecat cupidatat non proident sunt in culpa qui officia deserunt mollit anim id est laborum " ++
        "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua";
    var i: usize = 0;
    while (i < count) : (i += 1) try agent.addUser(filler);
}

test "requestManualCompact: guard order matches forceCompact" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // The very first guard: compaction_client == .none.
    try std.testing.expectError(error.NoCompactionClient, agent.requestManualCompact());
    try std.testing.expect(!agent.compactor.manual_pending);
    try std.testing.expect(agent.compactor.core.stateIs(.idle));

    // Window guard fires before the writer guard (same order as forceCompact).
    agent.context_window_tokens = 4096;
    try std.testing.expectError(error.NoCompactionClient, agent.requestManualCompact());
    try std.testing.expect(!agent.compactor.manual_pending);
}

test "requestManualCompact: defers to a stale run instead of starting a second" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".config/zay");
    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var writer: session_mod.SessionWriter = undefined;
    try session_mod.SessionWriter.initDefault(&writer, gpa, std.testing.io, home_dir, "/tmp");
    defer writer.deinit();

    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.attachSessionWriter(&writer);
    agent.compaction_client = .{ .openai_compatible = &client };
    agent.context_window_tokens = 4096;

    // A stale auto-run is in flight: request must defer, not spawn a second
    // thread or disturb the running state.
    agent.compactor.core.state.store(.running, .release);
    try agent.requestManualCompact();
    try std.testing.expect(agent.compactor.manual_pending);
    try std.testing.expect(!agent.compactor.manual_started);
    try std.testing.expect(agent.compactor.core.stateIs(.running));

    // A second request while pending is refused.
    try std.testing.expectError(error.CompactionInProgress, agent.requestManualCompact());
}

test "requestManualCompact starts a run; poll fails it against a dead server" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".config/zay");
    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var writer: session_mod.SessionWriter = undefined;
    try session_mod.SessionWriter.initDefault(&writer, gpa, std.testing.io, home_dir, "/tmp");
    defer writer.deinit();

    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.attachSessionWriter(&writer);
    agent.compaction_client = .{ .openai_compatible = &client };
    agent.context_window_tokens = 4096;
    try fillSessionForCompaction(&agent, 10);

    try agent.requestManualCompact();
    try std.testing.expect(agent.compactor.manual_pending);
    try std.testing.expect(agent.compactor.manual_started);
    try std.testing.expect(agent.compactor.core.stateIs(.running));

    // The summarizer fails against the dead server; the poll surfaces it and
    // clears the pending flags.
    var spins: u32 = 0;
    while (!agent.compactor.core.stateIs(.failed) and spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(agent.compactor.core.stateIs(.failed));
    try std.testing.expectError(error.CompactionFailed, agent.pollManualCompact());
    try std.testing.expect(!agent.compactor.manual_pending);
    try std.testing.expect(!agent.compactor.manual_started);
    try std.testing.expect(agent.compactor.core.stateIs(.idle));
}

test "pollManualCompact: returns null while the summarizer is running" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.compaction_client = .{ .openai_compatible = &client };
    agent.compactor.manual_pending = true;
    agent.compactor.manual_started = true;
    agent.compactor.core.state.store(.running, .release);

    try std.testing.expect((try agent.pollManualCompact()) == null);
    try std.testing.expect(agent.compactor.manual_pending);
}

test "pollManualCompact: torn-down client aborts and clears the pending flags" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.compactor.manual_pending = true;
    agent.compactor.manual_started = true;

    // compaction_client stays .none — simulates a disconnect mid-compact.
    try std.testing.expectError(error.CompactionFailed, agent.pollManualCompact());
    try std.testing.expect(!agent.compactor.manual_pending);
    try std.testing.expect(!agent.compactor.manual_started);
}

test "pollManualCompact: a failed summarizer surfaces CompactionFailed and clears the flags" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.compaction_client = .{ .openai_compatible = &client };

    // Fake an in-flight manual run: the summarizer thread fails (dead server →
    // connection refused) and flips to `.failed`; poll must surface it and
    // return the compactor to idle without leaking the result slot.
    agent.compactor.core.job = .{
        .gpa = gpa,
        .io = std.testing.io,
        .client = .{ .openai_compatible = &client },
        .limiter = null,
        .first_kept_id = undefined, // never read on the failure path
        .prefix_text = try gpa.dupe(u8, "some prefix"),
    };
    agent.compactor.core.state.store(.running, .release);
    agent.compactor.core.thread = try std.Thread.spawn(.{}, agent_compactor.Compactor.runThread, .{&agent.compactor.core});
    agent.compactor.manual_pending = true;
    agent.compactor.manual_started = true;

    var spins: u32 = 0;
    while (!agent.compactor.core.stateIs(.failed) and spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(agent.compactor.core.stateIs(.failed));

    try std.testing.expectError(error.CompactionFailed, agent.pollManualCompact());
    try std.testing.expect(!agent.compactor.manual_pending);
    try std.testing.expect(!agent.compactor.manual_started);
    try std.testing.expect(agent.compactor.core.stateIs(.idle));
}

test "pollManualCompact: discards a stale background result before the manual run" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".config/zay");
    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var writer: session_mod.SessionWriter = undefined;
    try session_mod.SessionWriter.initDefault(&writer, gpa, std.testing.io, home_dir, "/tmp");
    defer writer.deinit();

    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.attachSessionWriter(&writer);
    agent.compaction_client = .{ .openai_compatible = &client };
    agent.context_window_tokens = 4096;
    try fillSessionForCompaction(&agent, 10);

    // A stale auto summary is ready (no thread) and the manual run has not
    // started yet: the request deferred on an in-flight auto-run.
    agent.compactor.manual_pending = true;
    agent.compactor.manual_started = false;
    agent.compactor.core.result = .{
        .first_kept_id = undefined,
        .stored_summary = try gpa.dupe(u8, "stale summary"),
    };
    agent.compactor.core.state.store(.ready, .release);

    // First poll: the stale result is discarded (TD-1) and the manual run
    // starts. Returns null — the manual run is now in flight.
    try std.testing.expect((try agent.pollManualCompact()) == null);
    try std.testing.expect(agent.compactor.manual_started);

    // The manual run fails against the dead server; the poll surfaces it.
    var spins: u32 = 0;
    while (!agent.compactor.core.stateIs(.failed) and spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(agent.compactor.core.stateIs(.failed));
    try std.testing.expectError(error.CompactionFailed, agent.pollManualCompact());
    try std.testing.expect(!agent.compactor.manual_pending);
    try std.testing.expect(!agent.compactor.manual_started);
    try std.testing.expect(agent.compactor.core.stateIs(.idle));
}

test "compaction watermarks: shouldStartSummary fires before shouldSwap" {
    // Pure checks of the watermark contracts the maybeCompact/forceCompact
    // logic depends on. A 10 000-token window, default threshold 0.75:
    // start = round(10000 * 0.75) = 7500, swap = round(10000 * 0.95) = 9500.
    const context_window: u32 = 10_000;
    const threshold: f64 = 0.75;

    try std.testing.expect(!compaction.shouldStartSummary(7_000, context_window, threshold));
    try std.testing.expect(compaction.shouldStartSummary(8_000, context_window, threshold));
    try std.testing.expect(!compaction.shouldSwap(8_000, context_window, threshold));
    try std.testing.expect(compaction.shouldSwap(9_600, context_window, threshold));

    // keepRecentTokens scales with the window: 35% capped at the config keep.
    try std.testing.expectEqual(@as(u32, 3_500), compaction.keepRecentTokens(context_window, 8_000));
    // Small-context model: the %35 of 8000 is 2800, under the 8k cap, but the
    // 1000 floor applies only when the window is tiny.
    try std.testing.expectEqual(@as(u32, 1_000), compaction.keepRecentTokens(1_000, 8_000));
}

test "drain discards a ready summary and returns the compactor to idle" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // A finished background summary sitting in `.ready` — no thread. Drain
    // must free the stored summary (leak-checked) and return to idle (TD-1).
    agent.compactor.core.result = .{
        .first_kept_id = undefined,
        .stored_summary = try gpa.dupe(u8, "stale summary"),
    };
    agent.compactor.core.state.store(.ready, .release);

    agent.drainBackgroundCompaction();

    try std.testing.expect(agent.compactor.core.stateIs(.idle));
    try std.testing.expect(agent.compactor.core.result == null);
    try std.testing.expect(agent.compactor.core.thread == null);
}

test "drain joins a running summarizer that fails against a dead server" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // Fake an in-flight job: the summarizer thread will fail (dead server →
    // connection refused) and flip to `.failed`; drain must join it and return
    // the compactor to idle without leaking the result slot (TD-1).
    agent.compactor.core.job = .{
        .gpa = gpa,
        .io = std.testing.io,
        .client = .{ .openai_compatible = &client },
        .limiter = null,
        .first_kept_id = undefined, // never read on the failure path
        .prefix_text = try gpa.dupe(u8, "some prefix"),
    };
    agent.compactor.core.state.store(.running, .release);
    agent.compactor.core.thread = try std.Thread.spawn(.{}, agent_compactor.Compactor.runThread, .{&agent.compactor.core});

    // Wait for the summarizer to fail (connection refused, so this is fast).
    var spins: u32 = 0;
    while (!agent.compactor.core.stateIs(.failed) and spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(agent.compactor.core.stateIs(.failed));

    agent.drainBackgroundCompaction();
    try std.testing.expect(agent.compactor.core.stateIs(.idle));
    try std.testing.expect(agent.compactor.core.thread == null);
}

test "compaction breaker trips after repeated failures and backs off automatically" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".config/zay");
    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var writer: session_mod.SessionWriter = undefined;
    try session_mod.SessionWriter.initDefault(&writer, gpa, std.testing.io, home_dir, "/tmp");
    defer writer.deinit();

    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.attachSessionWriter(&writer);
    agent.compaction_client = .{ .openai_compatible = &client };
    agent.context_window_tokens = 4096;
    agent.compactor.failures = compaction_failure_limit;
    agent.compactor.breaker_notified = false;

    const Seen = struct {
        notices: std.ArrayList(Agent.Event.CompactionNotice) = .empty,

        fn onEvent(ctx: *@This(), event: Agent.Event) !void {
            switch (event) {
                .compaction_notice => |notice| try ctx.notices.append(std.testing.allocator, notice),
                else => {},
            }
        }
    };
    var seen: Seen = .{};
    defer seen.notices.deinit(gpa);
    const Listener = Agent.Listener(Seen);
    const listener: Listener = .{ .ctx = &seen, .on_event = Seen.onEvent };

    // Tripped: maybeCompact emits the one-shot breaker notice and backs off.
    agent.maybeCompact(listener);
    try std.testing.expectEqual(@as(usize, 1), seen.notices.items.len);
    try std.testing.expectEqual(Agent.Event.CompactionNotice.breaker_tripped, seen.notices.items[0]);
    try std.testing.expect(agent.compactor.core.stateIs(.idle));

    // The notice is one-shot: a second call emits nothing new.
    agent.maybeCompact(listener);
    try std.testing.expectEqual(@as(usize, 1), seen.notices.items.len);

    // Failure bookkeeping: each failed apply increments toward the limit.
    agent.compactor.failures = compaction_failure_limit - 1;
    agent.compactor.core.state.store(.failed, .release);
    try agent.compactor.applyReadyCompaction(agent.compactionEnv(), listener);
    try std.testing.expectEqual(compaction_failure_limit, agent.compactor.failures);
}

test "applyReadyCompaction resets the breaker on a successful swap" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".config/zay");
    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var writer: session_mod.SessionWriter = undefined;
    try session_mod.SessionWriter.initDefault(&writer, gpa, std.testing.io, home_dir, "/tmp");
    defer writer.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.attachSessionWriter(&writer);

    // Two persisted user messages so a 1-token keep budget cuts after the first.
    try agent.addUser("hello");
    try agent.addUser("world");
    const cut = (try writer.compactionCut(gpa, 1)) orelse return error.TestFailed;
    defer gpa.free(cut.prefix_text);

    // Simulate a ready background summary while the breaker was tripped.
    agent.compactor.core.result = .{
        .first_kept_id = cut.first_kept_id,
        .stored_summary = try gpa.dupe(u8, "SUMMARY"),
    };
    agent.compactor.core.state.store(.ready, .release);
    agent.compactor.failures = compaction_failure_limit;
    agent.compactor.breaker_notified = true;
    agent.compactor.stuck_notified = true;

    const Seen = struct {
        fn onEvent(_: *@This(), _: Agent.Event) !void {}
    };
    var seen: Seen = .{};
    const Listener = Agent.Listener(Seen);
    const listener: Listener = .{ .ctx = &seen, .on_event = Seen.onEvent };

    try agent.compactor.applyReadyCompaction(agent.compactionEnv(), listener);

    // A successful swap proves the pipeline works: breaker cleared, notices
    // re-armed for a future episode.
    try std.testing.expectEqual(@as(u32, 0), agent.compactor.failures);
    try std.testing.expect(!agent.compactor.breaker_notified);
    try std.testing.expect(!agent.compactor.stuck_notified);
}

test "assistant message with only reasoning is dropped from history" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var openai_compatible_client: openai_compatible.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    // A reasoning-only assistant message has no wire content.
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .reasoning = .{ .text = try gpa.dupe(u8, "thinking") } };
    var message: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer message.deinit(gpa);
    try std.testing.expect(!Agent.hasWireContent(message));
}

test "assistant message with text or tool calls is kept" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var openai_compatible_client: openai_compatible.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "answer") } };
    var text_message: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer text_message.deinit(gpa);
    try std.testing.expect(Agent.hasWireContent(text_message));

    const call_blocks = try gpa.alloc(ai.ContentBlock, 1);
    call_blocks[0] = .{ .tool_call = .{
        .call_id = .{ .value = try gpa.dupe(u8, "c1") },
        .name = try gpa.dupe(u8, "bash"),
        .arguments = try gpa.dupe(u8, "{}"),
    } };
    var call_message: ai.ChatMessage = .{ .assistant = .{ .content = call_blocks } };
    defer call_message.deinit(gpa);
    try std.testing.expect(Agent.hasWireContent(call_message));
}

test "I3: setWorkspace/effectiveCwd round-trip under the test allocator" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // No borrow: effectiveCwd falls back to the session cwd.
    try std.testing.expectEqualStrings(".", agent.effectiveCwd());
    try std.testing.expect(agent.workspaceBorrow() == null);

    // Set a borrow (a lane worktree path, borrowed — never freed here).
    agent.setWorkspace("/tmp/zay-lanes/abc123");
    try std.testing.expectEqualStrings("/tmp/zay-lanes/abc123", agent.effectiveCwd());
    try std.testing.expectEqualStrings("/tmp/zay-lanes/abc123", agent.workspaceBorrow().?);

    // Clear it back.
    agent.setWorkspace(null);
    try std.testing.expectEqualStrings(".", agent.effectiveCwd());
    try std.testing.expect(agent.workspaceBorrow() == null);
}
