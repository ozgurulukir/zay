const std = @import("std");

const ai = @import("ai.zig");
const at_mention = @import("at_mention.zig");
const bounded_queue = @import("bounded_queue");
const compaction = @import("compaction.zig");
const context_mod = @import("context.zig");
const executor_mod = @import("executor.zig");
const session_mod = @import("session.zig");
const skill_mod = @import("skill.zig");
const tools = @import("tools.zig");

const assert = std.debug.assert;
const message_queue_capacity: u32 = 64;

const QueuedUserMessage = struct {
    /// Raw prompt text as typed. `@`-mentions are expanded (files embedded,
    /// images attached) lazily at drain time so the file I/O lands on the
    /// agent worker thread rather than the UI thread.
    prompt: []u8,
    /// When set, this message is injected after the next tool batch ("steer")
    /// rather than waiting for the turn to go idle. The UI flips it via
    /// `setQueuedSteer` when the user steers a queued message.
    steer: bool = false,
};

const MessageQueue = bounded_queue.BoundedQueue(QueuedUserMessage);

const ToolBatch = struct {
    calls: []const ai.ToolCall,

    fn init(calls: []const ai.ToolCall) ToolBatch {
        assert(calls.len > 0);
        return .{ .calls = calls };
    }
};

/// Background summarizer state. At most one summary is ever in flight, so a
/// single result slot plus an atomic state is all the synchronization needed
/// between the worker thread (start/apply) and the summarizer thread (produce).
/// The summarizer never touches live history or the session — only the
/// dedicated client and its own allocations — so the boundary is clean.
const Compactor = struct {
    state: std.atomic.Value(State) = .init(.idle),
    thread: ?std.Thread = null,
    job: ?Job = null,
    result: ?Result = null,

    const State = enum(u8) { idle, running, ready, failed };

    /// Self-contained input handed to the summarizer thread: the rendered
    /// prefix to summarize and the entry the kept history resumes from.
    const Job = struct {
        gpa: std.mem.Allocator,
        client: ai.LanguageModel,
        first_kept_id: [session_mod.entry_id_len]u8,
        prefix_text: []u8,
    };

    const Result = struct {
        first_kept_id: [session_mod.entry_id_len]u8,
        stored_summary: []u8,
    };

    fn stateIs(self: *const Compactor, expected: State) bool {
        return self.state.load(.acquire) == expected;
    }
};

/// Body of the summarizer thread: produce the stored summary from the job's
/// frozen prefix, publish it, and flip the state. Acquire/release on `state`
/// makes the result visible to the worker once it observes `.ready`.
fn runCompactionThread(compactor: *Compactor) void {
    const job = compactor.job.?;
    defer job.gpa.free(job.prefix_text);
    const stored = produceStoredSummary(job) catch {
        compactor.state.store(.failed, .release);
        return;
    };
    compactor.result = .{ .first_kept_id = job.first_kept_id, .stored_summary = stored };
    compactor.state.store(.ready, .release);
}

fn produceStoredSummary(job: Compactor.Job) ![]u8 {
    const summary = try compaction.summarize(job.gpa, job.client, job.prefix_text);
    defer job.gpa.free(summary);
    if (summary.len == 0) return error.EmptySummary;
    return compaction.buildStoredSummary(job.gpa, summary);
}

pub const Agent = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    client: ai.LanguageModel,
    context_manager: context_mod.ContextManager,
    skills: []const skill_mod.Skill = &.{},
    /// Context window of the connected model, in tokens. Set by the runtime
    /// when a client is attached. 0 means unknown — compaction is disabled.
    context_window_tokens: u32 = 0,
    /// Token usage reported by the most recent turn, the anchor for the
    /// compaction watermark estimate. Null until the first turn completes or
    /// after a compaction / branch switch (forcing a full re-estimate).
    last_usage: ?ai.Usage = null,
    /// Message count when `last_usage` was captured (just after the assistant
    /// reply landed). Messages beyond this index are estimated and added to
    /// `last_usage`, so tool results not yet reflected in provider usage still
    /// count toward the watermark.
    last_usage_anchor_count: u32 = 0,
    /// Dedicated client for background summarization, distinct from `client` so
    /// the two never share a connection. `.none` disables compaction.
    compaction_client: ai.LanguageModel = .none,
    /// Background summarizer state machine.
    compactor: Compactor = .{},
    message_queue: MessageQueue = .{},
    message_queue_storage: [message_queue_capacity]QueuedUserMessage = undefined,
    message_queue_mutex: std.atomic.Mutex = .unlocked,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, client: ai.LanguageModel) Agent {
        return .{
            .gpa = gpa,
            .io = io,
            .cwd = cwd,
            .client = client,
            .context_manager = .{ .gpa = gpa },
        };
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

    pub fn deinit(self: *Agent) void {
        // Wait for any background summarizer before tearing down the state it
        // reads, then release its result.
        self.drainBackgroundCompaction();
        self.context_manager.deinit();
        self.lockMessageQueue();
        while (self.message_queue.pop(&self.message_queue_storage)) |queued| {
            self.gpa.free(queued.prompt);
        }
        self.message_queue_mutex.unlock();
        self.* = undefined;
    }

    pub fn addUser(self: *Agent, content: []const u8) !void {
        try self.appendMessage(.user, content);
    }

    pub fn enqueueUser(self: *Agent, content: []const u8) !void {
        assert(content.len > 0);
        const owned = try self.gpa.dupe(u8, content);
        errdefer self.gpa.free(owned);
        self.lockMessageQueue();
        defer self.message_queue_mutex.unlock();
        if (!self.message_queue.push(&self.message_queue_storage, .{ .prompt = owned })) return error.QueueFull;
    }

    /// Expand `@`-mentions in `prompt` (embedding text files inline, attaching
    /// images as real content blocks) and append the result as a user message.
    /// Reads files, so this is meant to run on the agent worker thread.
    pub fn addUserPrompt(self: *Agent, prompt: []const u8) !void {
        const blocks = try at_mention.buildUserMessage(self.gpa, self.io, self.cwd, prompt);
        errdefer {
            for (blocks) |*block| block.deinit(self.gpa);
            self.gpa.free(blocks);
        }
        try self.prependSkillBlocks(prompt, blocks);
        try self.context_manager.appendPersisted(.{ .role = .user, .content = blocks });
    }

    fn prependSkillBlocks(self: *Agent, prompt: []const u8, blocks: []ai.ContentBlock) !void {
        assert(blocks.len > 0);
        assert(blocks[0] == .text);
        const prefix = try skill_mod.promptPrefix(self.gpa, self.io, self.skills, prompt);
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

        /// Emitted after the agent replaces summarized history with a compaction
        /// summary. Token counts are estimates for display only.
        pub const HistoryCompacted = struct {
            tokens_before: u32,
            tokens_after: u32,
        };

        pub const ToolCallFinished = struct {
            index: u32,
            call_id: []const u8 = "",
            name: []const u8,
            display_label: []const u8,
            display_expanded_label: ?[]const u8 = null,
            display_body: []const u8,
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
                .turn_started, .delta_end, .tool_batch_finished, .queued_messages_flushed, .turn_finished, .history_compacted => {},
            }
            self.* = undefined;
        }
    };

    /// The typed seam consumers attach to receive `Agent.Event`s. Vtable-
    /// style — `*anyopaque` is hidden behind `emit(event)` so callers see
    /// only the typed method. `null_listener` is the branch-free default
    /// for callers that don't subscribe.
    pub const Listener = struct {
        ptr: *anyopaque,
        on_event: *const fn (*anyopaque, Event) anyerror!void,

        pub fn emit(self: Listener, event: Event) anyerror!void {
            return self.on_event(self.ptr, event);
        }

        pub const null_listener: Listener = .{
            .ptr = undefined,
            .on_event = onNothing,
        };

        fn onNothing(_: *anyopaque, _: Event) anyerror!void {}
    };

    pub fn run(self: *Agent, listener: Listener) !void {
        try listener.emit(.turn_started);
        const tool_call_limit = 100;
        var calls: u32 = 0;
        while (calls < tool_call_limit) : (calls += 1) {
            self.maybeCompact(listener);
            var stream_context: StreamContext = .{
                .agent = self,
                .listener = listener,
            };
            defer stream_context.deinit();
            var turn = try self.client.prompt(self.messages(), .{
                .ptr = &stream_context,
                .on_content = onContentDelta,
                .on_reasoning = onReasoningDelta,
                .on_tool_delta = onToolDelta,
                .on_delta_end = onDeltaEnd,
            });
            const usage = turn.usage;
            var turn_owned = true;
            defer if (turn_owned) turn.deinit(self.gpa);

            const tool_calls = try self.collectToolCalls(turn.assistant);
            defer self.gpa.free(tool_calls);
            if (turn.assistant.content.len > 0) {
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
                // handled at the natural turn end.
                const drained_count = try self.drainQueuedUserMessage(false);
                if (drained_count > 0) {
                    try listener.emit(.{ .queued_messages_flushed = drained_count });
                    continue;
                }
                return;
            }
            try self.runToolBatch(ToolBatch.init(tool_calls), &stream_context, listener);
            // Mid-turn we only inject messages explicitly marked to steer, and
            // only from the front so FIFO order holds — a default-queued
            // message ahead of a steer one keeps it waiting for turn end.
            var steered: u32 = 0;
            while ((try self.drainQueuedUserMessage(true)) > 0) steered += 1;
            if (steered > 0) try listener.emit(.{ .queued_messages_flushed = steered });
        }
        return error.ToolCallLimit;
    }

    /// Hand the batch of tool_calls to the ExecutorService, bridge its
    /// ToolCallObserver callbacks into the agent's Event stream, and move
    /// the LLM-channel of each ToolResult into history.
    fn runToolBatch(
        self: *Agent,
        tool_batch: ToolBatch,
        stream_context: *const StreamContext,
        listener: Listener,
    ) !void {
        var bridge: ExecutorBridge = .{
            .agent = self,
            .listener = listener,
            .stream_context = stream_context,
        };
        var executor = executor_mod.ExecutorService.init(self.gpa, self.io, self.cwd);
        const results = try executor.runAll(tool_batch.calls, .{
            .ptr = &bridge,
            .on_started = ExecutorBridge.onStarted,
            .on_finished = ExecutorBridge.onFinished,
        });
        defer self.gpa.free(results);
        errdefer for (results) |*r| r.deinit(self.gpa);
        try self.takeToolResults(results);
        try listener.emit(.tool_batch_finished);
    }

    /// Bridges ExecutorService's `ToolCallObserver` callbacks into the
    /// agent's Event stream. Tracks tool_index across the batch so the
    /// events line up with the tool_indexes the TUI saw during deltas.
    const ExecutorBridge = struct {
        agent: *Agent,
        listener: Listener,
        stream_context: *const StreamContext,
        tool_index: u32 = 0,

        fn onStarted(ptr: *anyopaque, call: ai.ToolCall) anyerror!void {
            const self: *ExecutorBridge = @ptrCast(@alignCast(ptr));
            // Synthesise a tool_delta for the TUI if the LM did not stream
            // one for this tool_call (some servers emit the whole call in
            // one shot without intermediate deltas).
            if (!self.stream_context.toolDeltaSeen(self.tool_index)) {
                try self.agent.emitToolDelta(self.listener, self.tool_index, call.name, call.arguments);
                try self.listener.emit(.delta_end);
            }
        }

        fn onFinished(ptr: *anyopaque, result: *const executor_mod.ToolResult) anyerror!void {
            const self: *ExecutorBridge = @ptrCast(@alignCast(ptr));
            try self.agent.emitToolCallFinished(
                self.listener,
                self.tool_index,
                result.call_id,
                result.name,
                result.display_label,
                result.display_expanded_label,
                result.display_body,
                result.stderr,
                result.failed,
            );
            self.tool_index += 1;
        }
    };

    const StreamContext = struct {
        agent: *Agent,
        listener: Listener,
        tool_delta_seen: std.ArrayList(bool) = .empty,

        fn deinit(self: *StreamContext) void {
            self.tool_delta_seen.deinit(self.agent.gpa);
        }

        fn toolDeltaSeen(self: *const StreamContext, tool_index: u32) bool {
            if (tool_index >= self.tool_delta_seen.items.len) return false;
            return self.tool_delta_seen.items[tool_index];
        }

        fn markToolDeltaSeen(self: *StreamContext, tool_index: u32) !void {
            while (self.tool_delta_seen.items.len <= tool_index) {
                try self.tool_delta_seen.append(self.agent.gpa, false);
            }
            self.tool_delta_seen.items[tool_index] = true;
        }
    };

    fn onContentDelta(context: *anyopaque, delta: []const u8) anyerror!void {
        const concrete: *StreamContext = @ptrCast(@alignCast(context));
        const owned = try concrete.agent.gpa.dupe(u8, delta);
        errdefer concrete.agent.gpa.free(owned);
        try concrete.listener.emit(.{ .response_delta = owned });
    }

    fn onReasoningDelta(context: *anyopaque, delta: []const u8) anyerror!void {
        const concrete: *StreamContext = @ptrCast(@alignCast(context));
        const owned = try concrete.agent.gpa.dupe(u8, delta);
        errdefer concrete.agent.gpa.free(owned);
        try concrete.listener.emit(.{ .thinking_delta = owned });
    }

    fn onToolDelta(context: *anyopaque, delta: ai.ToolDelta) anyerror!void {
        const concrete: *StreamContext = @ptrCast(@alignCast(context));
        try concrete.markToolDeltaSeen(delta.index);
        try concrete.agent.emitToolDelta(concrete.listener, delta.index, delta.name, delta.arguments);
    }

    fn onDeltaEnd(context: *anyopaque) anyerror!void {
        const concrete: *StreamContext = @ptrCast(@alignCast(context));
        try concrete.listener.emit(.delta_end);
    }

    fn emitToolDelta(
        self: *Agent,
        listener: Listener,
        tool_index: u32,
        name: []const u8,
        arguments: []const u8,
    ) !void {
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        const owned_arguments = try self.gpa.dupe(u8, arguments);
        errdefer self.gpa.free(owned_arguments);
        try listener.emit(.{
            .tool_delta = .{
                .index = tool_index,
                .name = owned_name,
                .arguments = owned_arguments,
            },
        });
    }

    fn emitToolCallFinished(
        self: *Agent,
        listener: Listener,
        tool_index: u32,
        call_id: []const u8,
        name: []const u8,
        display_label: []const u8,
        display_expanded_label: ?[]const u8,
        display_body: []const u8,
        stderr: ?[]const u8,
        failed: bool,
    ) !void {
        const owned_id = try self.gpa.dupe(u8, call_id);
        errdefer self.gpa.free(owned_id);
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        const owned_label = try self.gpa.dupe(u8, display_label);
        errdefer self.gpa.free(owned_label);
        const owned_expanded_label: ?[]u8 = if (display_expanded_label) |label|
            try self.gpa.dupe(u8, label)
        else
            null;
        errdefer if (owned_expanded_label) |label| self.gpa.free(label);
        const owned_body = try self.gpa.dupe(u8, display_body);
        errdefer self.gpa.free(owned_body);
        const owned_stderr: ?[]u8 = if (stderr) |s|
            try self.gpa.dupe(u8, s)
        else
            null;
        errdefer if (owned_stderr) |s| self.gpa.free(s);
        try listener.emit(.{
            .tool_call_finished = .{
                .index = tool_index,
                .call_id = owned_id,
                .name = owned_name,
                .display_label = owned_label,
                .display_expanded_label = owned_expanded_label,
                .display_body = owned_body,
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

    fn makeTextMessage(self: *Agent, role: ai.Role, content: []const u8) !ai.ChatMessage {
        assert(content.len > 0);
        const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
        errdefer self.gpa.free(blocks);
        blocks[0] = .{ .text = .{ .text = try self.gpa.dupe(u8, content) } };
        errdefer blocks[0].deinit(self.gpa);
        return .{ .role = role, .content = blocks };
    }

    fn drainQueuedUserMessage(self: *Agent, steer_only: bool) !u32 {
        const prompt = self.takeQueuedUserPrompt(steer_only) orelse return 0;
        defer self.gpa.free(prompt);
        try self.addUserPrompt(prompt);
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
        self.lockMessageQueue();
        defer self.message_queue_mutex.unlock();
        while (self.message_queue.pop(&self.message_queue_storage)) |queued| {
            self.gpa.free(queued.prompt);
        }
    }

    /// Pop and return the front queued prompt. When `steer_only` is set, only
    /// pops if the front message is marked to steer (otherwise returns null,
    /// leaving the queue untouched).
    fn takeQueuedUserPrompt(self: *Agent, steer_only: bool) ?[]u8 {
        self.lockMessageQueue();
        defer self.message_queue_mutex.unlock();
        if (steer_only) {
            const front = self.message_queue.peek(&self.message_queue_storage) orelse return null;
            if (!front.steer) return null;
        }
        const queued = self.message_queue.pop(&self.message_queue_storage) orelse return null;
        return queued.prompt;
    }

    /// Mark the queued message at logical `index` to steer (inject after the
    /// next tool batch). Called from the UI thread; guarded by the queue mutex
    /// the worker also holds while draining.
    pub fn setQueuedSteer(self: *Agent, index: u32) void {
        self.lockMessageQueue();
        defer self.message_queue_mutex.unlock();
        if (self.message_queue.at(&self.message_queue_storage, index)) |entry| entry.steer = true;
    }

    fn lockMessageQueue(self: *Agent) void {
        while (!self.message_queue_mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    fn takeAssistantMessage(self: *Agent, assistant: *ai.ChatMessage) !void {
        assert(assistant.role == .assistant);
        try self.context_manager.appendPersisted(assistant.*);
        assistant.* = undefined;
    }

    fn collectToolCalls(self: *Agent, assistant: ai.ChatMessage) ![]ai.ToolCall {
        assert(assistant.role == .assistant);
        var count: usize = 0;
        for (assistant.content) |block| {
            if (block == .tool_call) count += 1;
        }
        const calls = try self.gpa.alloc(ai.ToolCall, count);
        var index: usize = 0;
        for (assistant.content) |block| {
            if (block != .tool_call) continue;
            calls[index] = block.tool_call;
            index += 1;
        }
        return calls;
    }

    fn takeToolResults(self: *Agent, results: []executor_mod.ToolResult) !void {
        assert(results.len > 0);
        var moved: usize = 0;
        errdefer {
            for (results[moved..]) |*r| r.deinit(self.gpa);
        }
        for (results) |*r| {
            assert(r.call_id.len > 0);
            const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
            errdefer self.gpa.free(blocks);
            blocks[0] = .{ .text = .{ .text = r.content } };
            try self.context_manager.appendPersisted(.{
                .role = .tool,
                .content = blocks,
                .call_id = r.call_id,
                .tool_display_label = r.display_label,
                .tool_failed = r.failed,
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
    fn maybeCompact(self: *Agent, listener: Listener) void {
        if (self.compaction_client == .none) return;
        if (self.context_window_tokens == 0) return;
        if (self.context_manager.session_writer == null) return;

        const used = self.currentContextTokens();

        // Past the swap watermark: install the ready background summary.
        if (compaction.shouldSwap(used, self.context_window_tokens)) {
            self.applyReadyCompaction(listener) catch |err| std.log.warn("compaction apply failed: {s}", .{@errorName(err)});
        }

        // Past the start watermark: kick off the summary so it is ready by the
        // time the footprint reaches the swap watermark.
        if (compaction.shouldStartSummary(used, self.context_window_tokens) and self.compactor.stateIs(.idle)) {
            self.startCompaction() catch |err| std.log.warn("compaction start failed: {s}", .{@errorName(err)});
        }
    }

    /// Snapshot the frozen prefix and hand it to the summarizer thread. The
    /// snapshot (rendered text + first-kept entry id) is self-contained, so the
    /// thread never touches live history.
    fn startCompaction(self: *Agent) !void {
        const session_writer = self.context_manager.session_writer orelse return;
        const cut = (try session_writer.compactionCut(self.gpa, compaction.keep_recent_tokens_default)) orelse return;
        self.compactor.result = null;
        self.compactor.job = .{
            .gpa = self.gpa,
            .client = self.compaction_client,
            .first_kept_id = cut.first_kept_id,
            .prefix_text = cut.prefix_text,
        };
        self.compactor.state.store(.running, .release);
        self.compactor.thread = std.Thread.spawn(.{}, runCompactionThread, .{&self.compactor}) catch |err| {
            self.gpa.free(cut.prefix_text);
            self.compactor.job = null;
            self.compactor.state.store(.idle, .release);
            return err;
        };
    }

    /// Install a finished background summary: write the boundary, reproject, and
    /// emit the notice — instant, because the summary already exists. A failed
    /// run is logged and discarded. No-op while idle or still running.
    fn applyReadyCompaction(self: *Agent, listener: Listener) !void {
        const state = self.compactor.state.load(.acquire);
        if (state == .idle or state == .running) return;
        self.joinCompactor();
        defer self.finishCompactor();
        if (state == .failed) {
            std.log.warn("background compaction failed", .{});
            return;
        }
        const result = self.compactor.result.?;
        const session_writer = self.context_manager.session_writer orelse return;
        const tokens_before = self.currentContextTokens();
        try session_writer.appendCompaction(result.first_kept_id[0..], result.stored_summary);
        try self.reloadFromSession();
        self.resetContextUsage();
        try listener.emit(.{ .history_compacted = .{
            .tokens_before = tokens_before,
            .tokens_after = self.estimateContextTokens(),
        } });
    }

    /// Join the summarizer thread if one is alive. Blocks until it finishes —
    /// used both for the overflow wait and at teardown.
    fn joinCompactor(self: *Agent) void {
        if (self.compactor.thread) |thread| {
            thread.join();
            self.compactor.thread = null;
        }
    }

    /// Release the finished job/result and return the compactor to idle.
    fn finishCompactor(self: *Agent) void {
        if (self.compactor.result) |*result| self.gpa.free(result.stored_summary);
        self.compactor.result = null;
        self.compactor.job = null;
        self.compactor.state.store(.idle, .release);
    }

    /// Wait for any in-flight background summary and discard it. Call before
    /// freeing or replacing `compaction_client` so the summarizer thread is
    /// never left running against a client that is about to be torn down.
    pub fn drainBackgroundCompaction(self: *Agent) void {
        self.joinCompactor();
        self.finishCompactor();
    }

    /// Rehydrate the cached message list from the session projection after a
    /// compaction boundary was written — the swap. Keeps the system prompt.
    /// Called between turn iterations, where every message is already persisted
    /// and no stream is active; never mid-stream.
    fn reloadFromSession(self: *Agent) !void {
        const session_writer = self.context_manager.session_writer orelse return;
        self.context_manager.clearNonSystem();
        const projected = try session_writer.messages(self.gpa);
        defer self.gpa.free(projected);
        for (projected) |message| try self.context_manager.appendUnpersisted(message);
    }

    /// Best estimate of the footprint the *next* request will carry: the last
    /// turn's real reported usage (prompt + completion) as an anchor, plus a
    /// size estimate of every message appended since (tool results, queued user
    /// turns) — the part the provider has not accounted for yet. Falls back to
    /// a full estimate when no usage has been reported.
    fn currentContextTokens(self: *Agent) u32 {
        const usage = self.last_usage orelse return self.estimateContextTokens();
        const anchored = usage.input_tokens +| usage.output_tokens;
        return anchored +| self.estimateTrailingTokens(self.last_usage_anchor_count);
    }

    /// Sum the estimated tokens of cached messages from `anchor_count` onward —
    /// the messages appended after `last_usage` was captured.
    fn estimateTrailingTokens(self: *Agent, anchor_count: u32) u32 {
        const items = self.context_manager.items();
        var total: u32 = 0;
        var index: usize = anchor_count;
        while (index < items.len) : (index += 1) {
            total +|= compaction.estimateMessageTokens(items[index]);
        }
        return total;
    }

    /// Record a completed turn's usage as the watermark anchor. The anchor is
    /// the message count *after* the assistant reply landed, so everything
    /// appended later counts as trailing tokens.
    fn recordUsage(self: *Agent, usage: ?ai.Usage) void {
        self.last_usage = usage;
        self.last_usage_anchor_count = self.context_manager.count();
    }

    /// Drop the usage anchor, forcing a full re-estimate next turn. Used after
    /// the history is rebuilt (compaction, branch switch).
    pub fn resetContextUsage(self: *Agent) void {
        self.last_usage = null;
        self.last_usage_anchor_count = 0;
    }

    fn estimateContextTokens(self: *Agent) u32 {
        var total: u32 = 0;
        for (self.context_manager.items()) |message| {
            total +|= compaction.estimateMessageTokens(message);
        }
        return total;
    }
};

/// Parse just the `command` field of bash's argument JSON. The TUI uses
/// this to detect whether the streaming bash JSON is complete enough to
/// surface a meaningful title — for partial JSON we hold the title back.
pub fn parseCommand(gpa: std.mem.Allocator, arguments: []const u8) ![]u8 {
    const JsonArgs = struct {
        command: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch return error.InvalidToolArguments;
    defer parsed.deinit();

    const command = parsed.value.command orelse return error.InvalidToolArguments;
    return try gpa.dupe(u8, command);
}

/// Render friendly display metadata for a tool call by delegating to the
/// registered tool. Falls back to `<name> <arguments>` for tools that aren't
/// in the registry (shouldn't happen outside test paths).
pub fn formatToolDisplay(gpa: std.mem.Allocator, name: []const u8, arguments: []const u8) !tools.ToolDisplay {
    const tool = tools.lookup(name) orelse
        return .{ .label = try std.fmt.allocPrint(gpa, "{s} {s}", .{ name, arguments }) };
    return tool.display(gpa, arguments);
}

test "parse bash command arguments" {
    const gpa = std.testing.allocator;
    const command = try parseCommand(gpa, "{\"command\":\"zig build test\"}");
    defer gpa.free(command);
    try std.testing.expectEqualStrings("zig build test", command);
}

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

        fn onEvent(context: *anyopaque, event: Agent.Event) !void {
            const seen: *@This() = @ptrCast(@alignCast(context));
            try seen.events.append(std.testing.allocator, event);
        }
    };
    var seen: Seen = .{};
    defer seen.deinit(gpa);
    var context: Agent.StreamContext = .{
        .agent = &agent,
        .listener = .{
            .ptr = &seen,
            .on_event = Seen.onEvent,
        },
    };
    defer context.deinit();

    try Agent.onReasoningDelta(&context, "checking");
    try Agent.onContentDelta(&context, "hello");
    try Agent.onToolDelta(&context, .{
        .index = 1,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    });
    try Agent.onDeltaEnd(&context);

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

test "context token estimate anchors on usage plus trailing messages" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // Anchor on a reported usage just after an assistant reply (1 message).
    try agent.context_manager.appendUnpersisted(try agent.makeTextMessage(.assistant, "a" ** 40));
    agent.recordUsage(.{ .input_tokens = 1000, .output_tokens = 200, .total_tokens = 1200 });
    // A tool result appended afterwards (~40 bytes -> 10 estimated tokens).
    try agent.context_manager.appendUnpersisted(try agent.makeTextMessage(.tool, "b" ** 40));

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
