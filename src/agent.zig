const std = @import("std");

const ai = @import("ai.zig");
const executor_mod = @import("executor.zig");
const session_mod = @import("session.zig");
const tools = @import("tools.zig");

const assert = std.debug.assert;

pub const Agent = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    client: ai.LanguageModel,
    session_writer: ?*session_mod.SessionWriter = null,
    messages: std.ArrayList(ai.ChatMessage) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, client: ai.LanguageModel) Agent {
        return .{
            .gpa = gpa,
            .io = io,
            .cwd = cwd,
            .client = client,
        };
    }

    pub fn attachSessionWriter(self: *Agent, session_writer: *session_mod.SessionWriter) void {
        self.session_writer = session_writer;
    }

    pub fn addSystem(self: *Agent, content: []const u8) !void {
        try self.appendMessage("system", content);
    }

    pub fn deinit(self: *Agent) void {
        for (self.messages.items) |*message| {
            message.deinit(self.gpa);
        }
        self.messages.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn addUser(self: *Agent, content: []const u8) !void {
        try self.appendMessage("user", content);
    }

    pub fn addUserBlocks(self: *Agent, blocks: []const ai.ContentBlock) !void {
        const owned = try self.cloneBlocks(blocks);
        errdefer {
            for (owned) |*block| block.deinit(self.gpa);
            self.gpa.free(owned);
        }
        try self.messages.append(self.gpa, .{ .role = .user, .content = owned });
        try self.persistLastMessage();
    }

    pub fn takeMessage(self: *Agent, message: ai.ChatMessage) !void {
        try self.messages.append(self.gpa, message);
    }

    /// The tagged union the agent emits to describe what is happening.
    /// Single public seam — the TUI (and any future consumer) subscribes
    /// to this stream of events via `Agent.Listener`.
    ///
    /// Variant payloads are C-flattenable (flat fields, strings as
    /// `[]const u8`, integers, enums, single-level structs) so an FFI shim
    /// can wrap them later without redesigning the type. See CONTEXT.md's
    /// **Agent.Event** and the **C-flattenable Agent.Event payloads**
    /// convention.
    pub const Event = union(enum) {
        turn_started,
        thinking_delta: []const u8,
        response_delta: []const u8,
        tool_delta: ai.ToolDelta,
        delta_end,
        tool_call_finished: ToolCallFinished,
        tool_batch_finished,
        turn_finished,
        turn_failed: []const u8,

        pub const ToolCallFinished = struct {
            index: u32,
            call_id: []const u8 = "",
            name: []const u8,
            display_label: []const u8,
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
                    gpa.free(tool.display_body);
                    if (tool.stderr) |stderr| gpa.free(stderr);
                },
                .turn_started, .delta_end, .tool_batch_finished, .turn_finished => {},
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
        const tool_call_limit = 8;
        var calls: u32 = 0;
        while (calls < tool_call_limit) : (calls += 1) {
            var stream_context: StreamContext = .{
                .agent = self,
                .listener = listener,
            };
            defer stream_context.deinit();
            var turn = try self.client.prompt(self.messages.items, .{
                .ptr = &stream_context,
                .on_content = onContentDelta,
                .on_reasoning = onReasoningDelta,
                .on_tool_delta = onToolDelta,
                .on_delta_end = onDeltaEnd,
            });
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

            if (tool_calls.len == 0) return;
            try self.runToolBatch(tool_calls, &stream_context, listener);
        }
        return error.ToolCallLimit;
    }

    /// Hand the batch of tool_calls to the ExecutorService, bridge its
    /// ToolCallObserver callbacks into the agent's Event stream, and move
    /// the LLM-channel of each ToolResult into history.
    fn runToolBatch(
        self: *Agent,
        tool_calls: []const ai.ToolCall,
        stream_context: *const StreamContext,
        listener: Listener,
    ) !void {
        var bridge: ExecutorBridge = .{
            .agent = self,
            .listener = listener,
            .stream_context = stream_context,
        };
        var executor = executor_mod.ExecutorService.init(self.gpa, self.io, self.cwd);
        const results = try executor.runAll(tool_calls, .{
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
                .display_body = owned_body,
                .stderr = owned_stderr,
                .failed = failed,
            },
        });
    }

    fn cloneBlocks(self: *Agent, blocks: []const ai.ContentBlock) ![]ai.ContentBlock {
        const owned = try self.gpa.alloc(ai.ContentBlock, blocks.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |*block| block.deinit(self.gpa);
            self.gpa.free(owned);
        }
        for (blocks) |block| {
            owned[initialized] = try self.cloneBlock(block);
            initialized += 1;
        }
        return owned;
    }

    fn cloneBlock(self: *Agent, block: ai.ContentBlock) !ai.ContentBlock {
        return switch (block) {
            .text => |text| .{ .text = .{
                .text = try self.gpa.dupe(u8, text.text),
                .responses_item_id = if (text.responses_item_id) |id| try self.gpa.dupe(u8, id) else null,
                .responses_phase = if (text.responses_phase) |phase| try self.gpa.dupe(u8, phase) else null,
            } },
            .image => |image| .{ .image = .{
                .mime_type = try self.gpa.dupe(u8, image.mime_type),
                .data_base64 = try self.gpa.dupe(u8, image.data_base64),
            } },
            .reasoning => |reasoning| .{ .reasoning = .{
                .text = try self.gpa.dupe(u8, reasoning.text),
                .responses_item_json = if (reasoning.responses_item_json) |json| try self.gpa.dupe(u8, json) else null,
            } },
            .tool_call => |call| .{ .tool_call = .{
                .call_id = try self.gpa.dupe(u8, call.call_id),
                .responses_item_id = if (call.responses_item_id) |id| try self.gpa.dupe(u8, id) else null,
                .name = try self.gpa.dupe(u8, call.name),
                .arguments = try self.gpa.dupe(u8, call.arguments),
            } },
        };
    }

    fn appendMessage(self: *Agent, role: []const u8, content: []const u8) !void {
        const parsed_role = try ai.Role.fromString(role);
        const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
        errdefer self.gpa.free(blocks);
        blocks[0] = .{ .text = .{ .text = try self.gpa.dupe(u8, content) } };
        errdefer blocks[0].deinit(self.gpa);
        try self.messages.append(self.gpa, .{ .role = parsed_role, .content = blocks });
        try self.persistLastMessage();
    }

    fn takeAssistantMessage(self: *Agent, assistant: *ai.ChatMessage) !void {
        assert(assistant.role == .assistant);
        try self.messages.append(self.gpa, assistant.*);
        assistant.* = undefined;
        try self.persistLastMessage();
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
            try self.messages.append(self.gpa, .{
                .role = .tool,
                .content = blocks,
                .call_id = r.call_id,
            });
            try self.persistLastMessage();
            self.gpa.free(r.name);
            self.gpa.free(r.display_label);
            self.gpa.free(r.display_body);
            if (r.stderr) |s| self.gpa.free(s);
            r.* = undefined;
            moved += 1;
        }
    }

    fn persistLastMessage(self: *Agent) !void {
        const session_writer = self.session_writer orelse return;
        assert(self.messages.items.len > 0);
        const message = self.messages.items[self.messages.items.len - 1];
        try session_writer.append(message);
    }
};

/// Parse just the `command` field of bash's argument JSON. The TUI uses
/// this to detect whether the streaming bash JSON is complete enough to
/// surface a meaningful title — for partial JSON we hold the title back.
pub fn parseCommand(gpa: std.mem.Allocator, arguments: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, arguments, .{});
    defer parsed.deinit();

    const command = parsed.value.object.get("command") orelse return error.InvalidToolArguments;
    if (command != .string) return error.InvalidToolArguments;
    return try gpa.dupe(u8, command.string);
}

/// Render a friendly title for a tool call by delegating to the registered
/// tool's `displayLabel`. Falls back to `<name> <arguments>` for tools that
/// aren't in the registry (shouldn't happen outside test paths).
pub fn formatToolTitle(gpa: std.mem.Allocator, name: []const u8, arguments: []const u8) ![]u8 {
    const tool = tools.lookup(name) orelse
        return std.fmt.allocPrint(gpa, "{s} {s}", .{ name, arguments });
    return tool.displayLabel(gpa, arguments);
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
