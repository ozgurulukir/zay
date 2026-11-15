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
const result_cache_mod = @import("tools/result_cache.zig");
const request_limiter_mod = @import("request_limiter.zig");
const lua_mod = @import("lua/root.zig");
const mcp_mod = @import("mcp/manager.zig");
const session_mod = @import("session.zig");
const skill_mod = @import("skill.zig");
const skill_context_mod = @import("context/skill_context.zig");
const skill_history = @import("context/skill_history.zig");
const tools = @import("tools.zig");

const assert = std.debug.assert;
const agent_queue = @import("agent/queue.zig");

const QueuedUserMessage = agent_queue.QueuedUserMessage;
const MessageQueue = agent_queue.MessageQueue;

const agent_workspace = @import("agent/workspace.zig");
const WorkspaceScope = agent_workspace.WorkspaceScope;
const agent_turn_budget = @import("agent/turn_budget.zig");
const TurnBudget = agent_turn_budget.TurnBudget;
const agent_stream_context = @import("agent/stream_context.zig");
const queue_ops = @import("agent/queue_ops.zig");
const skill_ops = @import("agent/skill_context_ops.zig");
const run_loop = @import("agent/run_loop.zig");
const compaction_ops = @import("agent/compaction_ops.zig");
const message_ops = @import("agent/message_ops.zig");

const agent_compactor = @import("agent/compactor.zig");
const auto_compactor_mod = @import("context/auto_compactor.zig");
const snapshotter_mod = @import("agent/snapshotter.zig");
const tool_batch = @import("agent/tool_batch.zig");
const Compactor = agent_compactor.Compactor;

/// After this many consecutive background-compaction failures the automatic
/// path backs off (emitting one notice); the manual `/compact` command is
/// never gated (TD-6). Alias of the AutoCompactor's own limit — one SSOT.
pub const compaction_failure_limit: u32 = auto_compactor_mod.failure_limit;
pub const Agent = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    /// Borrowed from the TUI worker for the duration of a turn.
    cancel_requested: ?*const std.atomic.Value(bool) = null,
    /// Workspace-mode scoping (S5): when a lane worktree path is set, tools
    /// root at it instead of `cwd`. The state (borrowed path + guarding
    /// mutex) and the worker-writes/UI-reads contract live in
    /// `agent/workspace.zig`; the accessor one-liners below are Agent's only
    /// contact with it.
    workspace_scope: WorkspaceScope = .{},
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
    /// `none` is used by review agents that receive a pinned diff as input.
    /// This is enforced at dispatch as well as by the client's tool schema.
    tool_access: enum { full, none } = .full,
    context_manager: context_mod.ContextManager,
    skills: []const skill_mod.Skill = &.{},
    skill_context: skill_context_mod.SkillContext = .{},
    skill_context_dirty: bool = false,
    /// True until the next listener event carries the complete current skill
    /// inventory. This is separate from persistence dirtiness: the writer may
    /// flush metadata before the UI has received its snapshot.
    skill_context_changed_pending: bool = false,
    /// Context window of the connected model, in tokens. Set by the runtime
    /// when a client is attached. 0 means unknown — compaction is disabled.
    context_window_tokens: u32 = 0,
    /// Dedicated client for background summarization, distinct from `client` so
    /// the two never share a connection. `.none` disables compaction.
    compaction_client: ai.LanguageModel = .none,
    /// Optional local classifier endpoint for bash approval gating.
    bash_classifier_url: ?[]const u8 = null,
    /// Session-scoped cache for identical read-only shell results (#5).
    /// Lives on the Agent (one session), not the per-batch ExecutorService,
    /// so hits span turns.
    result_cache: result_cache_mod.ResultCache,
    database_server_url: ?[]const u8 = null,
    database_auth_token: ?[]const u8 = null,
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
    /// Per-turn continuation policy (tool-call budget, soft stop on budget
    /// exhaustion, one-shot length-cut auto-continue) — state, budget math,
    /// and continuation hints live in `agent/turn_budget.zig`; the turn loop
    /// and its stop handlers below are the only consumers. Set by the
    /// runtime from `config.context`.
    turn_budget: TurnBudget = .{},
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

    /// The App-owned subsystems every live agent borrows, as ONE record
    /// assigned at ONE seam (runtime construction). `attachSharedSubsystems`
    /// is the only writer of the matching Agent fields; its `inline for` over
    /// these fields makes a missing Agent counterpart a compile error, so the
    /// wiring set cannot silently drift between runtime-creation sites (the
    /// "sending request with NO tools" incident class). Null fields keep the
    /// documented per-subsystem semantics: headless/tests run with the
    /// feature disabled (no gate, builtin-only registry, no background path).
    ///
    /// The request limiter is shared by every lane's agent (turn, naming, and
    /// compaction requests all gate on it), so the provider sees at most
    /// `maxConcurrentRequests` requests in flight across all lanes.
    pub const SharedSubsystems = struct {
        background_manager: ?*background_mod.BackgroundManager = null,
        mcp_manager: ?*mcp_mod.McpManager = null,
        tool_registry: ?*tools.ToolRegistry = null,
        plugin_manager: ?*lua_mod.PluginManager = null,
        lane_bridge: ?*lane_bridge.LaneBridge = null,
        request_limiter: ?*request_limiter_mod.RequestLimiter = null,
    };

    /// Sole writer of the shared-subsystem Agent fields. Idempotent: spawning
    /// paths may call it again after `createRuntimeImpl` (same App pointers).
    pub fn attachSharedSubsystems(self: *Agent, subsystems: SharedSubsystems) void {
        inline for (std.meta.fields(SharedSubsystems)) |field| {
            @field(self, field.name) = @field(subsystems, field.name);
        }
    }

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, client: ai.LanguageModel) Agent {
        return .{
            .gpa = gpa,
            .io = io,
            .cwd = cwd,
            .client = client,
            .context_manager = .{ .gpa = gpa },
            .result_cache = result_cache_mod.ResultCache.init(gpa),
        };
    }

    /// The directory tools run in: the workspace root when entered in a lane
    /// (S5), else the session cwd. Read per tool batch by `runToolBatch` and
    /// per `@`-mention expansion by `addUserPrompt` — both on the worker
    /// thread, but the UI thread reads the same state. One-liner over
    /// `WorkspaceScope.effectiveCwd`; the cross-thread contract lives in
    /// `agent/workspace.zig`.
    pub fn effectiveCwd(self: *Agent) []const u8 {
        return self.workspace_scope.effectiveCwd(self.io, self.cwd);
    }

    /// Set the workspace borrow (worker thread, `lane enter`/`leave`). The
    /// path is borrowed from the lane's `Thread`, never copied or freed here.
    pub fn setWorkspace(self: *Agent, path: ?[]const u8) void {
        self.workspace_scope.setWorkspace(self.io, path);
    }

    /// Read the workspace borrow (UI thread). Returns a borrowed slice; the
    /// backing path is Thread-owned and outlives the borrow.
    pub fn workspaceBorrow(self: *Agent) ?[]const u8 {
        return self.workspace_scope.workspaceBorrow(self.io);
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
        try message_ops.appendMessage(self, .system, content);
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
        self.result_cache.deinit();
        // Wait for any background summarizer before tearing down the state it
        // reads (the client), then release its result.
        compaction_ops.drainBackgroundCompaction(self);
        self.context_manager.deinit();
        self.skill_context.deinit(self.gpa);
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
        if (self.database_server_url) |url| self.gpa.free(url);
        if (self.database_auth_token) |tok| self.gpa.free(tok);
        self.* = undefined;
    }

    pub fn addUser(self: *Agent, content: []const u8) !void {
        try message_ops.appendMessage(self, .user, content);
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
        const skill_count = self.skill_context.entries.items.len;
        errdefer self.skill_context.rollbackTo(self.gpa, skill_count);
        try skill_ops.prependBlocks(self, prompt, blocks);
        try self.context_manager.appendPersisted(.{ .user = .{ .content = blocks } });
        if (self.skill_context.entries.items.len != skill_count) {
            skill_ops.noteChange(self);
        }
    }

    /// Append a synthetic, failed tool result for every `tool_call` on the active
    /// branch that has no matching result yet. Runs before a new user message so
    /// the dangling calls (from a mid-batch interrupt) don't break the next turn.
    /// A no-op when every call already has a result.
    fn reconcileInterruptedToolCalls(self: *Agent) !void {
        try run_loop.reconcileUnresolvedToolCalls(self, run_loop.interrupted_tool_result, "cancelled");
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
        /// The durable skill metadata changed on the worker and the UI should
        /// refresh its separate lane inventory projection.
        skill_inventory_changed: SkillInventory,
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

        pub const SkillInventory = struct {
            names: []u8,
        };

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
                .skill_inventory_changed => |inventory| gpa.free(inventory.names),
                .turn_started, .delta_end, .tool_batch_finished, .queued_messages_flushed, .turn_finished, .history_compacted, .compaction_notice, .tool_budget_exhausted, .length_cut => {},
            }
            self.* = undefined;
        }
    };

    /// The typed seam consumers attach to receive `Agent.Event`s. Generic
    /// over the consumer's context type — the `*Ctx` is supplied at the call
    /// site, so callbacks receive their own typed context without
    /// `@ptrCast`. The `Ctx` type is supplied by the caller.
    pub fn Listener(Ctx: type) type {
        return struct {
            ctx: *Ctx,
            on_event: *const fn (ctx: *Ctx, event: Event) anyerror!void,

            pub fn emit(self: @This(), event: Event) anyerror!void {
                return self.on_event(self.ctx, event);
            }
        };
    }

    /// Wire-stream observation (agent/stream_context.zig): the per-stream
    /// context, its coalescing buffers, and the typed observer wrappers
    /// moved there; these unchanged-signature aliases keep the in-file
    /// call sites — `run`'s construction and the stream-callback tests —
    /// reading as before.
    const StreamContext = agent_stream_context.StreamContext;
    const onContentDeltaImpl = agent_stream_context.onContentDeltaImpl;
    const onReasoningDeltaImpl = agent_stream_context.onReasoningDeltaImpl;
    const onToolDeltaImpl = agent_stream_context.onToolDeltaImpl;
    const onDeltaEndImpl = agent_stream_context.onDeltaEndImpl;

    /// Drive the turn loop to completion. Unchanged-signature delegate: the
    /// body moved to `agent/run_loop.zig` (`run`) in issue #367 slice 14.
    pub fn run(self: *Agent, listener: anytype) !void {
        return run_loop.run(self, listener);
    }

    /// Re-export: the in-file stream-callback tests read
    /// `Agent.hasWireContent`; the body moved to `agent/run_loop.zig` in
    /// issue #367 slice 14.
    pub const hasWireContent = run_loop.hasWireContent;

    /// Pub delegate: the body moved to `agent/skill_context_ops.zig`
    /// (`persist`); external callers (tui/session_switcher) keep this seam.
    pub fn persistSkillContext(self: *Agent) !void {
        return skill_ops.persist(self);
    }
};
// Issue #367 slice 15 re-exports: the bodies moved to the spokes; external
// callers keep importing this module and pass the `*Agent` explicitly.
pub const takeMessage = message_ops.takeMessage;
pub const clearNonSystemMessages = message_ops.clearNonSystemMessages;
pub const takeToolResults = message_ops.takeToolResults;
pub const maybeCompact = compaction_ops.maybeCompact;
pub const forceCompact = compaction_ops.forceCompact;
pub const requestManualCompact = compaction_ops.requestManualCompact;
pub const pollManualCompact = compaction_ops.pollManualCompact;
pub const manualCompactPending = compaction_ops.manualCompactPending;
pub const drainBackgroundCompaction = compaction_ops.drainBackgroundCompaction;
pub const currentContextTokens = compaction_ops.currentContextTokens;
pub const recordUsage = compaction_ops.recordUsage;
pub const resetContextUsage = compaction_ops.resetContextUsage;
pub const reloadFromSession = compaction_ops.reloadFromSession;
pub const replaceConversation = compaction_ops.replaceConversation;

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
        .gpa = agent.gpa,
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
        .gpa = agent.gpa,
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
        .gpa = agent.gpa,
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
        .gpa = agent.gpa,
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
        .gpa = agent.gpa,
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
    try std.testing.expectError(error.TestFailure, tool_batch.emitToolDelta(Listener, &agent, context.listener, 0, "name", "args"));
    try std.testing.expectError(error.TestFailure, tool_batch.emitToolCallFinished(Listener, &agent, context.listener, 0, "id", "name", "label", null, "body", .text, null, false));
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
    try queue_ops.enqueueUser(&agent, "queued");

    try std.testing.expectEqual(@as(u32, 1), try queue_ops.drainQueuedUserMessage(&agent, false));
    try std.testing.expectEqual(@as(usize, 2), agent.messages().len);
    try std.testing.expectEqualStrings("queued", agent.messages()[1].text());
}

test "skill context repeated inline and model activation preserves protocol results" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const fixture: skill_mod.Skill = .{
        .name = @constCast("how"),
        .description = @constCast("Test instructions"),
        .path = @constCast("/missing/how/SKILL.md"),
        .base_dir = @constCast("/missing/how"),
        .body = @constCast("Full skill instructions."),
    };
    var client = try ai.scripted_client.Client.init(gpa, io, "skill-test");
    defer client.deinit();
    try client.enqueue(.{
        ai.scripted_client.step.toolCall("skill", "{\"name\":\"how\"}"),
        ai.scripted_client.step.toolCall("skill", "{\"name\":\"HOW\"}"),
        ai.scripted_client.step.text("done", .stop),
    });
    var agent = Agent.init(gpa, io, ".", .{ .scripted = &client });
    defer agent.deinit();
    agent.skills = &.{fixture};
    try agent.addUser("load the skill");
    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);
    try agent.run(Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent });
    try std.testing.expectEqual(@as(usize, 1), agent.skill_context.entries.items.len);
    var result_count: usize = 0;
    for (agent.messages()) |message| {
        if (message != .tool) continue;
        if (result_count == 0) {
            try std.testing.expectEqualStrings(fixture.body, message.text());
        } else {
            try std.testing.expectEqualStrings(skill_context_mod.loaded_notice, message.text());
        }
        try std.testing.expect(!message.tool.failed);
        result_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), result_count);
    var inventory_events: usize = 0;
    for (seen.events.items) |event| {
        if (event != .skill_inventory_changed) continue;
        inventory_events += 1;
        try std.testing.expectEqualStrings("how", event.skill_inventory_changed.names);
    }
    try std.testing.expectEqual(@as(usize, 1), inventory_events);
    try agent.addUserPrompt("$how $HOW");
    try std.testing.expectEqualStrings("$how $HOW", agent.messages()[agent.messages().len - 1].text());
    message_ops.clearNonSystemMessages(&agent);
    try agent.addUserPrompt("$how $HOW");
    const injected_names = try skill_mod.collectInjectedSkillNames(gpa, agent.messages()[0].text());
    defer {
        for (injected_names) |name| gpa.free(name);
        gpa.free(injected_names);
    }
    try std.testing.expectEqual(@as(usize, 1), injected_names.len);
    try agent.addUserPrompt("again $HOW");
    try std.testing.expectEqualStrings("again $HOW", agent.messages()[1].text());
    try std.testing.expectEqual(@as(usize, 1), agent.skill_context.entries.items.len);
}

test "skill context inline admission OOM never falsely activates a skill" {
    const gpa = std.testing.allocator;
    const fixture: skill_mod.Skill = .{
        .name = @constCast("how"),
        .description = @constCast("Test"),
        .path = @constCast("/missing/how/SKILL.md"),
        .base_dir = @constCast("/missing/how"),
        .body = @constCast("Instructions"),
    };
    var reached_success = false;
    for (0..64) |fail_index| {
        var agent = Agent.init(gpa, std.testing.io, ".", .none);
        defer agent.deinit();
        agent.skills = &.{fixture};
        var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        agent.gpa = failing.allocator();
        agent.context_manager.gpa = failing.allocator();
        const result = agent.addUserPrompt("$how");
        agent.gpa = gpa;
        agent.context_manager.gpa = gpa;
        if (result) |_| {
            try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
            if (agent.skill_context.contains("how")) {
                reached_success = true;
                break;
            }
            try std.testing.expect(std.mem.indexOf(u8, agent.messages()[0].text(), "could not be loaded") != null);
        } else |err| {
            // Allocating writers translate allocation failure to WriteFailed.
            try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
            try std.testing.expectEqual(@as(usize, 0), agent.messages().len);
            try std.testing.expectEqual(@as(usize, 0), agent.skill_context.entries.items.len);
        }
    }
    try std.testing.expect(reached_success);
}

test "skill context conversation swap is atomic on OOM and restores persisted bodies" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    try agent.addSystem("system");
    try agent.addUser("original message");
    _ = try agent.skill_context.activate(gpa, "original", "original instructions");
    const projected_messages = try gpa.alloc(ai.ChatMessage, 32);
    for (projected_messages) |*message| message.* = .{ .user = .{ .content = &.{} } };
    var projected: session_mod.SessionWriter.Conversation = .{ .messages = projected_messages, .skill_context = .{} };
    defer projected.deinit(gpa);
    _ = try projected.skill_context.activate(gpa, "missing-source", "persisted instructions");
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    agent.context_manager.gpa = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, compaction_ops.replaceConversation(&agent, &projected));
    agent.context_manager.gpa = gpa;
    try std.testing.expectEqual(@as(usize, 2), agent.messages().len);
    try std.testing.expectEqualStrings("original message", agent.messages()[1].text());
    try std.testing.expectEqualStrings("original instructions", agent.skill_context.body("original").?);
    try std.testing.expectEqual(@as(usize, 32), projected.messages.len);
    try compaction_ops.replaceConversation(&agent, &projected);
    try std.testing.expectEqual(@as(usize, 33), agent.messages().len);
    try std.testing.expectEqualStrings("system", agent.messages()[0].text());
    try std.testing.expect(!agent.skill_context.contains("original"));
    try std.testing.expectEqualStrings("persisted instructions", agent.skill_context.body("missing-source").?);
    try std.testing.expectEqual(@as(usize, 0), projected.messages.len);
    message_ops.clearNonSystemMessages(&agent);
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expectEqual(@as(usize, 0), agent.skill_context.entries.items.len);
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

test "addUser auto-reconciles dangling assistant tool calls before appending" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    const calls = try gpa.alloc(ai.ContentBlock, 1);
    calls[0] = .{ .tool_call = .{ .call_id = .{ .value = try gpa.dupe(u8, "call_x") }, .name = try gpa.dupe(u8, "bash"), .arguments = try gpa.dupe(u8, "{}") } };
    try agent.context_manager.appendUnpersisted(.{ .assistant = .{ .content = calls } });

    // Calling addUser (used by raw messages and continuation hints) must reconcile call_x
    // before the user message lands, maintaining alternating assistant->tool->user order.
    try agent.addUser("user continuation");

    const items = agent.messages();
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expect(items[0] == .assistant);
    try std.testing.expect(items[1] == .tool);
    try std.testing.expectEqualStrings("call_x", items[1].tool.call_id.slice());
    try std.testing.expect(items[2] == .user);
    try std.testing.expectEqualStrings("user continuation", items[2].text());
}

test "context token estimate anchors on usage plus trailing messages" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // Anchor on a reported usage just after an assistant reply (1 message).
    try agent.context_manager.appendUnpersisted(try message_ops.makeTextMessage(&agent, .assistant, "a" ** 40));
    compaction_ops.recordUsage(&agent, .{ .input_tokens = 1000, .output_tokens = 200, .total_tokens = 1200 });
    // A tool result appended afterwards (~40 bytes -> 10 estimated tokens).
    try agent.context_manager.appendUnpersisted(try message_ops.makeToolMessage(&agent, "b" ** 40));

    // anchor total (1000 + 200) + trailing estimate (10) = 1210
    try std.testing.expectEqual(@as(u32, 1210), compaction_ops.currentContextTokens(&agent));
}

test "context footprint includes wire tools before usage without counting them twice" {
    const gpa = std.testing.allocator;
    var client: ai.openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .api_key = "test",
        .model = "test",
        .base_url = "http://localhost:1",
        .system_prompt = "",
        .tools = tools.builtinRegistry(),
    });
    defer client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &client });
    defer agent.deinit();
    try agent.context_manager.appendUnpersisted(try message_ops.makeTextMessage(&agent, .user, "hi"));
    const tool_tokens = client.tools_json.len / 4 + @intFromBool(client.tools_json.len % 4 != 0);
    try std.testing.expectEqual(@as(u32, @intCast(tool_tokens + 1)), compaction_ops.currentContextTokens(&agent));
    compaction_ops.recordUsage(&agent, .{ .input_tokens = 68000, .output_tokens = 40, .total_tokens = 68040 });
    try std.testing.expectEqual(@as(u32, 68040), compaction_ops.currentContextTokens(&agent));
    try client.updateTools(&.{});
    try std.testing.expectEqual(@as(u32, @intCast(68040 - tool_tokens)), compaction_ops.currentContextTokens(&agent));
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
    agent.turn_budget.tool_call_limit_per_turn = 7;

    try queue_ops.enqueueUser(&agent, "first");
    try queue_ops.enqueueUser(&agent, "second");

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);
    const listener = Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent };

    try run_loop.softStopOnBudget(&agent, listener, 7, 7);

    // Everything queued landed in history in FIFO order, and the trailing
    // continuation hint is the last message — a `.user` machine message so
    // it persists (`SessionWriter.append` skips `.system`).
    try std.testing.expectEqual(@as(usize, 3), agent.messages().len);
    try std.testing.expectEqualStrings("first", agent.messages()[0].text());
    try std.testing.expectEqualStrings("second", agent.messages()[1].text());
    try std.testing.expect(std.mem.startsWith(u8, agent.messages()[2].text(), "[zay] This turn stopped"));
    try std.testing.expect(agent.messages()[2].role() == .user);
    try std.testing.expect(!queue_ops.hasQueuedMessages(&agent));

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

    try run_loop.softStopOnBudget(&agent, listener, 0, agent.turn_budget.tool_call_limit_per_turn);

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
    try std.testing.expect(try run_loop.handleLengthCut(&agent, listener, false));
    try std.testing.expectEqual(@as(usize, 1), seen.events.items.len);
    try std.testing.expectEqual(Agent.Event.LengthCut.auto_continued, seen.events.items[0].length_cut);
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expect(agent.messages()[0].role() == .user);
    try std.testing.expect(std.mem.startsWith(u8, agent.messages()[0].text(), "[zay] Your previous response was cut off"));

    // Second cut in the same run: the one-shot is exhausted — the turn ends
    // with the stopped event and no extra hint message.
    try std.testing.expect(!try run_loop.handleLengthCut(&agent, listener, true));
    try std.testing.expectEqual(@as(usize, 2), seen.events.items.len);
    try std.testing.expectEqual(Agent.Event.LengthCut.stopped, seen.events.items[1].length_cut);
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
}

test "handleLengthCut with the knob off only emits the stopped event" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.turn_budget.auto_continue_on_length_cut = false;

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);
    const listener = Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent };

    try std.testing.expect(!try run_loop.handleLengthCut(&agent, listener, false));
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
        .{ .status = .ok, .body = "data: {\"choices\":[{\"delta\":{\"content\":\"Done\"},\"finish_reason\":\"stop\"}]}\n" ++
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

    // One truncation retry, followed by the normal post-tool answer request.
    // Omitting the final response leaves the client waiting on an exhausted
    // server script, rather than testing the truncation retry bound.
    try std.testing.expectEqual(@as(u32, 3), server.connection_count.load(.monotonic));
    try std.testing.expectEqualStrings("Done", agent.messages()[agent.messages().len - 1].text());

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

test "background launch ends the model turn until completion is delivered" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try ai.scripted_client.Client.init(gpa, io, "scripted-model");
    defer client.deinit();
    try client.enqueue(.{ai.scripted_client.step.toolCall(
        tools.shell_tool.name,
        "{\"command\":\"echo bg\",\"description\":\"start background test\",\"run_in_background\":true}",
    )});

    var manager = background_mod.BackgroundManager.init(io, gpa);
    defer manager.shutdownAll();

    var agent = Agent.init(gpa, io, ".", .{ .scripted = &client });
    defer agent.deinit();
    agent.background_manager = &manager;
    try agent.addUser("start the background command");

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);
    try agent.run(Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent });

    // The launch result is persisted, but it must not trigger a second model
    // request that can poll `background.status` before completion delivery.
    try std.testing.expectEqual(@as(u32, 1), client.prompts_answered);
    const messages = agent.messages();
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expect(std.mem.indexOf(u8, messages[2].text(), "Started in the background") != null);
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
        try client.addTool("search", "Search the index", .{ .properties = props }, null);
        try manager.addClient(client);
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

test "tool-call budget caps parallel batches by individual calls" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try ai.scripted_client.Client.init(gpa, io, "scripted-model");
    defer client.deinit();
    try client.enqueue(.{
        ai.scripted_client.step.toolCalls(&.{
            .{ .name = "missing_first", .arguments = "{}" },
            .{ .name = "missing_second", .arguments = "{}" },
        }),
    });

    var agent = Agent.init(gpa, io, ".", .{ .scripted = &client });
    defer agent.deinit();
    agent.turn_budget.tool_call_limit_per_turn = 1;
    try agent.addUser("run exactly one tool call");

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);
    try agent.run(Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent });

    try std.testing.expectEqual(@as(u32, 1), client.prompts_answered);
    var tool_results: usize = 0;
    var first_call_was_dispatched = false;
    var second_call_was_rejected = false;
    for (agent.messages()) |message| {
        if (message != .tool) continue;
        tool_results += 1;
        const body = message.text();
        if (std.mem.indexOf(u8, body, "unknown tool") != null) first_call_was_dispatched = true;
        if (std.mem.indexOf(u8, body, "tool-call budget") != null) second_call_was_rejected = true;
    }
    try std.testing.expectEqual(@as(usize, 2), tool_results);
    try std.testing.expect(first_call_was_dispatched);
    try std.testing.expect(second_call_was_rejected);

    var exhausted_events: usize = 0;
    for (seen.events.items) |event| switch (event) {
        .tool_budget_exhausted => |limit| {
            try std.testing.expectEqual(@as(u32, 1), limit);
            exhausted_events += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), exhausted_events);
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

test "run retries once when finish_reason=tool_calls arrives with no tool call" {
    // Fully-severed twin of the truncation guard: the provider ends the
    // response with finish_reason=tool_calls but streamed NO call at all —
    // nothing to count as `tool_calls_truncated`, so the original guard
    // (`truncated > 0`) never fired and the turn died silently behind the
    // warn-only log. The same one-shot hint retry must cover this shape.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try ai.scripted_client.Client.init(gpa, io, "scripted-model");
    defer client.deinit();
    try client.enqueue(.{
        ai.scripted_client.step.text("", .tool_calls),
        ai.scripted_client.step.toolCall("pwsh", "{\"command\":\"echo hi\"}"),
        ai.scripted_client.step.text("Done", .stop),
    });

    var agent = Agent.init(gpa, io, ".", .{ .scripted = &client });
    defer agent.deinit();
    try agent.addUser("list the directory");

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);

    try agent.run(Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent });

    // Three prompts: severed response, hint retry executing the call the
    // second response emits, final post-tool answer.
    try std.testing.expectEqual(@as(u32, 3), client.prompts_answered);
    try std.testing.expectEqualStrings("Done", agent.messages()[agent.messages().len - 1].text());
    var hint_found = false;
    for (agent.messages()) |m| {
        if (m.role() == .user and std.mem.startsWith(u8, m.text(), "[zay] Your tool call(s) arrived without their arguments")) {
            hint_found = true;
        }
    }
    try std.testing.expect(hint_found);
}

test "run drains a queued user message before spending the truncation retry" {
    // Precedence pin for the turn-finalization decision table: a queued user
    // message and a severed tool_call section arriving in the same turn must
    // hand the turn to the DRAIN, not to the hint retry. The one-shot stays
    // unspent, so the NEXT severed response still gets its retry.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try ai.scripted_client.Client.init(gpa, io, "scripted-model");
    defer client.deinit();
    try client.enqueue(.{
        ai.scripted_client.step.truncatedToolCalls(1),
        ai.scripted_client.step.truncatedToolCalls(1),
        ai.scripted_client.step.text("done after retry", .stop),
    });

    var agent = Agent.init(gpa, io, ".", .{ .scripted = &client });
    defer agent.deinit();
    try agent.addUser("list the directory");
    try queue_ops.enqueueUser(&agent, "queued while busy");

    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);

    try agent.run(Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent });

    // Three prompts: the drained turn, the hint retry, the closing text. A
    // retry-first ordering would spend the one-shot on turn 1, push the
    // queued delivery to turn 3, and exhaust the script before the closing
    // text.
    try std.testing.expectEqual(@as(u32, 3), client.prompts_answered);

    // Exactly one flush of the queued message, and the queue ends empty.
    var flushed: usize = 0;
    for (seen.events.items) |event| switch (event) {
        .queued_messages_flushed => |count| {
            try std.testing.expectEqual(@as(u32, 1), count);
            flushed += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), flushed);
    try std.testing.expect(!queue_ops.hasQueuedMessages(&agent));

    // History pins the ordering: the drained message landed BEFORE the hint
    // (a retry-wins turn would put the hint first). The empty severed
    // assistants store nothing, so the shape is exactly four messages.
    const messages = agent.messages();
    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqualStrings("list the directory", messages[0].text());
    try std.testing.expectEqualStrings("queued while busy", messages[1].text());
    try std.testing.expect(std.mem.startsWith(u8, messages[2].text(), "[zay] Your tool call(s) arrived without their arguments"));
    try std.testing.expectEqualStrings("done after retry", messages[3].text());
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
    compaction_ops.maybeCompact(&agent, listener);

    // Compactor never left idle, no event emitted (noop listener would error
    // otherwise — there is nothing to assert beyond not panicking).
    try std.testing.expect(agent.compactor.core.stateIs(.idle));
}

test "forceCompact: no compaction client returns NoCompactionClient without swapping" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // The very first guard: compaction_client == .none.
    try std.testing.expectError(error.NoCompactionClient, compaction_ops.forceCompact(&agent));
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
    try std.testing.expectError(error.NoCompactionClient, compaction_ops.forceCompact(&agent));
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
    try std.testing.expectError(error.NoCompactionClient, compaction_ops.requestManualCompact(&agent));
    try std.testing.expect(!agent.compactor.manual_pending);
    try std.testing.expect(agent.compactor.core.stateIs(.idle));

    // Window guard fires before the writer guard (same order as forceCompact).
    agent.context_window_tokens = 4096;
    try std.testing.expectError(error.NoCompactionClient, compaction_ops.requestManualCompact(&agent));
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
    try compaction_ops.requestManualCompact(&agent);
    try std.testing.expect(agent.compactor.manual_pending);
    try std.testing.expect(!agent.compactor.manual_started);
    try std.testing.expect(agent.compactor.core.stateIs(.running));

    // A second request while pending is refused.
    try std.testing.expectError(error.CompactionInProgress, compaction_ops.requestManualCompact(&agent));
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

    try compaction_ops.requestManualCompact(&agent);
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
    try std.testing.expectError(error.CompactionFailed, compaction_ops.pollManualCompact(&agent));
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

    try std.testing.expect((try compaction_ops.pollManualCompact(&agent)) == null);
    try std.testing.expect(agent.compactor.manual_pending);
}

test "pollManualCompact: torn-down client aborts and clears the pending flags" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.compactor.manual_pending = true;
    agent.compactor.manual_started = true;

    // compaction_client stays .none — simulates a disconnect mid-compact.
    try std.testing.expectError(error.CompactionFailed, compaction_ops.pollManualCompact(&agent));
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
    agent.compactor.core.task = try std.testing.io.concurrent(agent_compactor.Compactor.runThread, .{&agent.compactor.core});
    agent.compactor.manual_pending = true;
    agent.compactor.manual_started = true;

    var spins: u32 = 0;
    while (!agent.compactor.core.stateIs(.failed) and spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(agent.compactor.core.stateIs(.failed));

    try std.testing.expectError(error.CompactionFailed, compaction_ops.pollManualCompact(&agent));
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
    try std.testing.expect((try compaction_ops.pollManualCompact(&agent)) == null);
    try std.testing.expect(agent.compactor.manual_started);

    // The manual run fails against the dead server; the poll surfaces it.
    var spins: u32 = 0;
    while (!agent.compactor.core.stateIs(.failed) and spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(agent.compactor.core.stateIs(.failed));
    try std.testing.expectError(error.CompactionFailed, compaction_ops.pollManualCompact(&agent));
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

    compaction_ops.drainBackgroundCompaction(&agent);

    try std.testing.expect(agent.compactor.core.stateIs(.idle));
    try std.testing.expect(agent.compactor.core.result == null);
    try std.testing.expect(agent.compactor.core.task == null);
}

test "drain and failed compaction preserve live and persisted context" {
    if (@import("os.zig").is_windows) return error.SkipZigTest;
    const io = std.testing.io;
    var allocator: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer std.testing.expect(allocator.deinit() == .ok) catch @panic("compaction test leaked");
    const gpa = allocator.allocator();
    const mock = @import("ai/mock_http_server.zig");
    const openai = @import("ai/openai_compatible.zig");

    const Scenario = enum { stalled_head, stalled_body, stalled_error_body, retry_backoff, rejected, empty_summary, whitespace, truncated, filtered, success };
    for (std.enums.values(Scenario)) |scenario| {
        const stalled = scenario == .stalled_head or scenario == .stalled_body or scenario == .stalled_error_body or scenario == .retry_backoff;
        const responses = [_]mock.Response{.{
            .status = if (scenario == .rejected) .bad_request else if (scenario == .retry_backoff or scenario == .stalled_error_body) .too_many_requests else .ok,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
            .body = switch (scenario) {
                .whitespace => "data: {\"choices\":[{\"delta\":{\"content\":\"  \\n\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n",
                .truncated => "data: {\"choices\":[{\"delta\":{\"content\":\"partial summary\"},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n",
                .filtered => "data: {\"choices\":[{\"delta\":{\"content\":\"partial summary\"},\"finish_reason\":\"content_filter\"}]}\n\ndata: [DONE]\n\n",
                .success => "data: {\"choices\":[{\"delta\":{\"content\":\"complete summary\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n",
                else => "data: [DONE]\n\n",
            },
            .head_delay_ms = if (scenario == .stalled_head) 1500 else 0,
            .body_delay_ms = if (scenario == .stalled_body or scenario == .stalled_error_body) 1500 else 0,
        }};
        var server = try mock.MockHttpServer.init(io, &responses);
        defer server.deinit();
        var serving = try io.concurrent(mock.MockHttpServer.serve, .{&server});
        defer serving.cancel(io);
        const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
        defer gpa.free(base_url);
        var client: openai.Client = undefined;
        try client.init(gpa, io, .{ .base_url = base_url, .api_key = "test", .model = "test", .request_timeout_seconds = 30 });
        defer client.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
        defer gpa.free(home_dir);
        var writer: session_mod.SessionWriter = undefined;
        try session_mod.SessionWriter.initDefault(&writer, gpa, io, home_dir, "/tmp");
        defer writer.deinit();
        var agent = Agent.init(gpa, io, ".", .none);
        defer agent.deinit();
        agent.attachSessionWriter(&writer);
        agent.compaction_client = .{ .openai_compatible = &client };
        agent.context_window_tokens = 4096;
        try fillSessionForCompaction(&agent, 10);
        _ = try writer.lastUserEntry();
        const leaf_before = try gpa.dupe(u8, writer.session.leaf().?);
        defer gpa.free(leaf_before);
        const history_before = agent.messages().len;
        const text_before = try gpa.dupe(u8, agent.messages()[0].text());
        defer gpa.free(text_before);
        try compaction_ops.requestManualCompact(&agent);
        var spins: u32 = 0;
        while (server.connection_count.load(.acquire) == 0 and spins < 500) : (spins += 1) try io.sleep(.fromMilliseconds(2), .awake);
        try std.testing.expect(server.connection_count.load(.acquire) == 1);
        if (stalled) {
            try io.sleep(.fromMilliseconds(100), .awake);
            try std.testing.expect(agent.compactor.core.stateIs(.running));
            const started = std.Io.Timestamp.now(io, .awake);
            if (scenario == .stalled_error_body)
                try std.testing.expectError(error.Canceled, agent.compactor.core.task.?.cancel(io));
            compaction_ops.drainBackgroundCompaction(&agent);
            const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));
            try std.testing.expect(elapsed.nanoseconds < 600 * std.time.ns_per_ms);
        } else {
            spins = 0;
            while (agent.compactor.core.stateIs(.running) and spins < 500) : (spins += 1) try io.sleep(.fromMilliseconds(2), .awake);
            if (scenario == .success) {
                try std.testing.expect((try compaction_ops.pollManualCompact(&agent)) != null);
            } else {
                try std.testing.expectError(error.CompactionFailed, compaction_ops.pollManualCompact(&agent));
            }
        }
        // Repeated teardown is harmless, including manual-submit flags.
        compaction_ops.drainBackgroundCompaction(&agent);
        try std.testing.expect(agent.compactor.core.stateIs(.idle));
        try std.testing.expect(agent.compactor.core.task == null);
        try std.testing.expect(agent.compactor.core.result == null);
        try std.testing.expect(!agent.compactor.manual_pending);
        try std.testing.expect(!agent.compactor.manual_started);
        _ = try writer.lastUserEntry();
        if (scenario == .success) {
            try std.testing.expect(agent.messages().len < history_before);
            try std.testing.expect(!std.mem.eql(u8, leaf_before, writer.session.leaf().?));
        } else {
            try std.testing.expectEqual(history_before, agent.messages().len);
            try std.testing.expectEqualStrings(text_before, agent.messages()[0].text());
            try std.testing.expectEqualStrings(leaf_before, writer.session.leaf().?);
        }
        try std.testing.expectEqual(@as(u32, 1), server.connection_count.load(.acquire));
    }
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
    agent.compactor.core.task = try std.testing.io.concurrent(agent_compactor.Compactor.runThread, .{&agent.compactor.core});

    // Wait for the summarizer to fail (connection refused, so this is fast).
    var spins: u32 = 0;
    while (!agent.compactor.core.stateIs(.failed) and spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(agent.compactor.core.stateIs(.failed));

    compaction_ops.drainBackgroundCompaction(&agent);
    try std.testing.expect(agent.compactor.core.stateIs(.idle));
    try std.testing.expect(agent.compactor.core.task == null);
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
    compaction_ops.maybeCompact(&agent, listener);
    try std.testing.expectEqual(@as(usize, 1), seen.notices.items.len);
    try std.testing.expectEqual(Agent.Event.CompactionNotice.breaker_tripped, seen.notices.items[0]);
    try std.testing.expect(agent.compactor.core.stateIs(.idle));

    // The notice is one-shot: a second call emits nothing new.
    compaction_ops.maybeCompact(&agent, listener);
    try std.testing.expectEqual(@as(usize, 1), seen.notices.items.len);

    // Failure bookkeeping: each failed apply increments toward the limit.
    agent.compactor.failures = compaction_failure_limit - 1;
    agent.compactor.core.state.store(.failed, .release);
    try agent.compactor.applyReadyCompaction(compaction_ops.compactionEnv(&agent), listener);
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

    try agent.compactor.applyReadyCompaction(compaction_ops.compactionEnv(&agent), listener);

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

test "skill context missing source repeat returns one successful protocol result" {
    const gpa = std.testing.allocator;
    var client = try ai.scripted_client.Client.init(gpa, std.testing.io, "skill-test");
    defer client.deinit();
    try client.enqueue(.{
        ai.scripted_client.step.toolCall("skill", "{\"name\":\"HOW\"}"),
        ai.scripted_client.step.text("done", .stop),
    });
    var agent = Agent.init(gpa, std.testing.io, ".", .{ .scripted = &client });
    defer agent.deinit();
    _ = try agent.skill_context.activate(gpa, "how", "Saved instructions");
    try agent.addUser("Use the saved skill");
    var seen: BudgetSeen = .{};
    defer seen.deinit(gpa);
    try agent.run(Agent.Listener(BudgetSeen){ .ctx = &seen, .on_event = BudgetSeen.onEvent });
    var count: usize = 0;
    for (agent.messages()) |message| {
        if (message != .tool) continue;
        count += 1;
        try std.testing.expect(!message.tool.failed);
        try std.testing.expectEqualStrings(skill_context_mod.loaded_notice, message.text());
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("Saved instructions", agent.skill_context.body("how").?);
}

test "skill context canceled result preserves call pairing without activating" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    const fixture: skill_mod.Skill = .{
        .name = @constCast("how"),
        .description = @constCast("Test"),
        .path = @constCast("/missing/SKILL.md"),
        .base_dir = @constCast("/missing"),
        .body = @constCast("Instructions"),
    };
    agent.skills = &.{fixture};
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .tool_call = .{
        .call_id = .{ .value = try gpa.dupe(u8, "canceled-call") },
        .name = try gpa.dupe(u8, "skill"),
        .arguments = try gpa.dupe(u8, "{\"name\":\"how\"}"),
    } };
    try message_ops.takeMessage(&agent, .{ .assistant = .{ .content = blocks } });
    var results = [_]executor_mod.ToolResult{try executor_mod.ToolResult.init(gpa, .{
        .call_id = "canceled-call",
        .name = "skill",
        .failed = true,
        .content = try gpa.dupe(u8, "Tool canceled"),
        .display = .{ .label = try gpa.dupe(u8, "skill how") },
        .display_body = try gpa.dupe(u8, "Tool canceled"),
    })};
    try message_ops.takeToolResults(&agent, &results);
    try std.testing.expectEqual(@as(usize, 2), agent.messages().len);
    try std.testing.expect(agent.messages()[1].tool.failed);
    try std.testing.expectEqualStrings("canceled-call", agent.messages()[1].tool.call_id.slice());
    try std.testing.expect(!agent.skill_context.contains("how"));
}

test "skill command results neither activate instructions nor become loaded notices" {
    const gpa = std.testing.allocator;
    for ([_]bool{ false, true }) |already_active| {
        var agent = Agent.init(gpa, std.testing.io, ".", .none);
        defer agent.deinit();
        const fixture: skill_mod.Skill = .{
            .name = @constCast("how"),
            .description = @constCast("Test"),
            .path = @constCast("/missing/SKILL.md"),
            .base_dir = @constCast("/missing"),
            .body = @constCast("Retained instructions"),
        };
        agent.skills = &.{fixture};
        if (already_active) _ = try agent.skill_context.activate(gpa, fixture.name, fixture.body);
        const blocks = try gpa.alloc(ai.ContentBlock, 1);
        blocks[0] = .{ .tool_call = .{
            .call_id = .{ .value = try gpa.dupe(u8, "script-call") },
            .name = try gpa.dupe(u8, "skill"),
            .arguments = try gpa.dupe(u8, "{\"name\":\"how\",\"command\":\"python3 scripts/check.py\"}"),
        } };
        try message_ops.takeMessage(&agent, .{ .assistant = .{ .content = blocks } });
        var results = [_]executor_mod.ToolResult{try executor_mod.ToolResult.init(gpa, .{
            .call_id = "script-call",
            .name = "skill",
            .failed = false,
            .content = try gpa.dupe(u8, "Script result"),
            .display = .{ .label = try gpa.dupe(u8, "Run how skill") },
            .display_body = try gpa.dupe(u8, "Script result"),
        })};
        try message_ops.takeToolResults(&agent, &results);
        try std.testing.expectEqualStrings("Script result", agent.messages()[1].text());
        try std.testing.expectEqual(already_active, agent.skill_context.contains("how"));
        if (already_active) try std.testing.expectEqualStrings(fixture.body, agent.skill_context.body("how").?);
    }
}

test "shared subsystems record mirrors the Agent fields it wires" {
    // Compile-time parity: every SharedSubsystems field must have a
    // same-named, same-typed Agent field, so the record and the fields it
    // writes cannot drift apart. No runtime assertions — compiling IS the
    // assertion.
    inline for (std.meta.fields(Agent.SharedSubsystems)) |record_field| {
        const matched = comptime blk: {
            for (std.meta.fields(Agent)) |agent_field| {
                if (std.mem.eql(u8, agent_field.name, record_field.name)) {
                    if (agent_field.type != record_field.type) {
                        @compileError("Agent." ++ record_field.name ++
                            " type diverged from SharedSubsystems." ++ record_field.name);
                    }
                    break :blk true;
                }
            }
            break :blk false;
        };
        if (!matched) {
            @compileError("SharedSubsystems." ++ record_field.name ++
                " has no same-named Agent field");
        }
    }
}
