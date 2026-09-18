//! In-memory scripted adapter for the `LanguageModel` seam — the second
//! adapter that makes the client seam real.
//!
//! Agent-level tests should prefer this over real sockets: it runs on every
//! platform, including Windows, where the truncation-class socket suites are
//! gated off (#32). It is deliberately NOT an SSE fixture — wire-shape and
//! truncation-encoding tests stay on the in-thread `MockScriptedServer`
//! suites; this adapter is dialect-neutral and drives the same observer a
//! real client drives.
//!
//! Ownership: steps (and their strings) are owned by the client from
//! `enqueue` until `deinit`; every returned `Turn` is freshly allocated and
//! follows the normal `Turn.deinit` / `takeAssistantMessage` contract.

const std = @import("std");
const ai = @import("../ai.zig");

/// Upper bound on scripted steps per client. Scripts are test-sized; the
/// bound keeps storage fixed and makes overflow an explicit test bug.
pub const script_capacity_max = 16;

/// Upper bound on tool calls within one scripted tool_calls step.
pub const tool_calls_step_max = 8;

/// One tool call inside a `tool_calls` step. Strings are borrowed at
/// enqueue time and duped into the client.
pub const ToolCallSpec = struct {
    name: []const u8,
    arguments: []const u8,
};

/// One scripted model response. Build with the `step` namespace and hand a
/// tuple of them to `Client.enqueue`.
pub const Step = union(enum) {
    /// Assistant text reply, streamed to the observer in two chunks.
    text: TextStep,
    /// Complete tool call(s); the observer sees one tool delta per call.
    tool_calls: ToolCallsStep,
    /// Provider-severed tool-call arguments: N dropped calls, empty
    /// assistant, nothing on the observer — the `tool_calls_truncated`
    /// signature the agent's retry-once guard consumes.
    truncated_tool_calls: u32,
    /// `prompt` returns this error and records it in `errorDetail`.
    fail: anyerror,

    pub const TextStep = struct {
        bytes: []const u8 = "",
        finish: ai.FinishReason = .stop,
    };

    pub const ToolCallsStep = struct {
        names: [tool_calls_step_max][]const u8 = undefined,
        arguments: [tool_calls_step_max][]const u8 = undefined,
        calls_len: u32 = 0,
    };
};

/// Step builders — keep enqueue call sites reading like a script literal.
pub const step = struct {
    pub fn text(bytes: []const u8, finish: ai.FinishReason) Step {
        return .{ .text = .{ .bytes = bytes, .finish = finish } };
    }

    pub fn toolCalls(calls: []const ToolCallSpec) Step {
        std.debug.assert(calls.len <= tool_calls_step_max);
        var built: Step = .{ .tool_calls = .{} };
        built.tool_calls.calls_len = @intCast(calls.len);
        // Borrowed until `Client.enqueue` dupes them into owned storage.
        for (calls, 0..) |call, i| {
            built.tool_calls.names[i] = call.name;
            built.tool_calls.arguments[i] = call.arguments;
        }
        return built;
    }

    pub fn toolCall(name: []const u8, arguments: []const u8) Step {
        return toolCalls(&.{.{ .name = name, .arguments = arguments }});
    }

    pub fn truncatedToolCalls(count: u32) Step {
        return .{ .truncated_tool_calls = count };
    }

    pub fn fail(err: anyerror) Step {
        return .{ .fail = err };
    }
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    /// Unused today; kept so the constructor mirrors the wire clients'
    /// `init(gpa, io, ...)` family the seam's callers already know.
    io: std.Io,
    model_label: []u8,
    steps: [script_capacity_max]Step = undefined,
    steps_len: u32 = 0,
    step_index: u32 = 0,
    prompts_answered: u32 = 0,
    /// What the model last saw as the trailing user message — how tests
    /// assert hints and continuations actually reached the request.
    last_user_text: ?[]u8 = null,
    last_prompt_message_count: u32 = 0,
    tools_update_count: u32 = 0,
    error_detail: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, model_label: []const u8) !Client {
        return .{
            .gpa = gpa,
            .io = io,
            .model_label = try gpa.dupe(u8, model_label),
        };
    }

    pub fn deinit(self: *Client) void {
        for (self.steps[0..self.steps_len]) |script_step| self.deinitStep(script_step);
        if (self.last_user_text) |text| self.gpa.free(text);
        if (self.error_detail) |detail| self.gpa.free(detail);
        self.gpa.free(self.model_label);
        self.* = undefined;
    }

    /// Append a tuple of `Step`s to the script, duping their strings.
    /// Call sites read like a literal:
    /// `try client.enqueue(.{ step.text("partial", .length), step.text("rest", .stop) });`
    pub fn enqueue(self: *Client, steps: anytype) !void {
        const start = self.steps_len;
        errdefer self.freeStepsFrom(start);
        inline for (steps) |spec| {
            if (self.steps_len >= script_capacity_max) return error.ScriptFull;
            self.steps[self.steps_len] = try self.ownStep(spec);
            self.steps_len += 1;
        }
    }

    /// The three-method contract's entry point. Pops the next step in
    /// order, drives the observer the way a real stream would (text in two
    /// chunks; one tool delta per call), and returns a freshly owned Turn.
    pub fn prompt(self: *Client, messages: []const ai.MessageView, observer: anytype) !ai.Turn {
        self.prompts_answered += 1;
        self.captureLastUserText(messages);
        if (self.step_index >= self.steps_len) {
            self.setErrorDetail("scripted client [{s}]: script exhausted after {d} steps", .{ self.model_label, self.steps_len });
            return error.ScriptExhausted;
        }
        const script_step = self.steps[self.step_index];
        self.step_index += 1;
        switch (script_step) {
            .text => |text_step| {
                try streamText(observer, text_step.bytes);
                return try self.buildTextTurn(text_step.bytes, text_step.finish);
            },
            .tool_calls => |calls_step| {
                try streamToolDeltas(observer, calls_step);
                return try self.buildToolCallsTurn(calls_step);
            },
            .truncated_tool_calls => |count| {
                // Nothing reaches the observer: the arguments never streamed.
                const content = try self.gpa.alloc(ai.ContentBlock, 0);
                errdefer self.gpa.free(content);
                return .{
                    .assistant = .{ .assistant = .{ .content = content } },
                    .finish_reason = .tool_calls,
                    .tool_calls_truncated = count,
                };
            },
            .fail => |err| {
                self.setErrorDetail("scripted client [{s}]: step {d} failed with {s}", .{ self.model_label, self.step_index - 1, @errorName(err) });
                return err;
            },
        }
    }

    /// Contract twin of the wire clients: owned internally, freed on
    /// overwrite, returned borrowed.
    pub fn errorDetail(self: *const Client) ?[]const u8 {
        return self.error_detail;
    }

    pub fn updateTools(self: *Client, specs: []const ai.tool_schema.ToolSpec) !void {
        _ = specs;
        self.tools_update_count += 1;
    }

    fn ownStep(self: *Client, spec: Step) !Step {
        switch (spec) {
            .text => |text_step| {
                const owned = try self.gpa.dupe(u8, text_step.bytes);
                errdefer self.gpa.free(owned);
                return .{ .text = .{ .bytes = owned, .finish = text_step.finish } };
            },
            .tool_calls => |calls_step| {
                // Hand-built Steps must respect the fixed buffer; builders
                // assert earlier, this closes the boundary at the consumer.
                std.debug.assert(calls_step.calls_len <= tool_calls_step_max);
                var calls: Step.ToolCallsStep = .{};
                errdefer self.deinitStep(.{ .tool_calls = calls });
                for (0..calls_step.calls_len) |i| {
                    const name_owned = try self.gpa.dupe(u8, calls_step.names[i]);
                    errdefer self.gpa.free(name_owned);
                    const args_owned = try self.gpa.dupe(u8, calls_step.arguments[i]);
                    errdefer self.gpa.free(args_owned);
                    calls.names[i] = name_owned;
                    calls.arguments[i] = args_owned;
                    // Only after both slots are filled: the errdefer above
                    // frees exactly `calls_len` complete pairs.
                    calls.calls_len = @intCast(i + 1);
                }
                return .{ .tool_calls = calls };
            },
            .truncated_tool_calls, .fail => return spec,
        }
    }

    fn deinitStep(self: *Client, script_step: Step) void {
        switch (script_step) {
            .text => |text_step| self.gpa.free(text_step.bytes),
            .tool_calls => |calls_step| {
                for (0..calls_step.calls_len) |i| {
                    self.gpa.free(calls_step.names[i]);
                    self.gpa.free(calls_step.arguments[i]);
                }
            },
            .truncated_tool_calls, .fail => {},
        }
    }

    fn freeStepsFrom(self: *Client, start: u32) void {
        for (self.steps[start..self.steps_len]) |script_step| self.deinitStep(script_step);
        self.steps_len = start;
    }

    fn streamText(observer: anytype, bytes: []const u8) !void {
        if (bytes.len == 0) {
            try observer.on_delta_end(observer.ctx);
            return;
        }
        // Two chunks so consumers exercise coalescing; byte-midpoint split,
        // so scripted text should stay ASCII (these are test fixtures).
        const first_half = bytes.len / 2;
        try observer.on_content(observer.ctx, bytes[0..first_half]);
        try observer.on_content(observer.ctx, bytes[first_half..]);
        try observer.on_delta_end(observer.ctx);
    }

    fn streamToolDeltas(observer: anytype, calls_step: Step.ToolCallsStep) !void {
        for (0..calls_step.calls_len) |i| {
            try observer.on_tool_delta(observer.ctx, .{
                .index = @intCast(i),
                .name = calls_step.names[i],
                .arguments = calls_step.arguments[i],
            });
        }
        try observer.on_delta_end(observer.ctx);
    }

    fn buildTextTurn(self: *Client, bytes: []const u8, finish: ai.FinishReason) !ai.Turn {
        const owned = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(owned);
        const content = try self.gpa.alloc(ai.ContentBlock, 1);
        errdefer self.gpa.free(content);
        content[0] = .{ .text = .{ .text = owned } };
        return .{
            .assistant = .{ .assistant = .{ .content = content } },
            .finish_reason = finish,
        };
    }

    fn buildToolCallsTurn(self: *Client, calls_step: Step.ToolCallsStep) !ai.Turn {
        const content = try self.gpa.alloc(ai.ContentBlock, calls_step.calls_len);
        var filled: u32 = 0;
        errdefer {
            for (content[0..filled]) |*block| block.deinit(self.gpa);
            self.gpa.free(content);
        }
        for (0..calls_step.calls_len) |i| {
            const call_id = try std.fmt.allocPrint(self.gpa, "scripted-{d}-{d}", .{ self.prompts_answered, i });
            errdefer self.gpa.free(call_id);
            const name_owned = try self.gpa.dupe(u8, calls_step.names[i]);
            errdefer self.gpa.free(name_owned);
            const args_owned = try self.gpa.dupe(u8, calls_step.arguments[i]);
            errdefer self.gpa.free(args_owned);
            content[i] = .{ .tool_call = .{
                .call_id = .{ .value = call_id },
                .name = name_owned,
                .arguments = args_owned,
            } };
            filled += 1;
        }
        return .{
            .assistant = .{ .assistant = .{ .content = content } },
            .finish_reason = .tool_calls,
        };
    }

    fn captureLastUserText(self: *Client, messages: []const ai.MessageView) void {
        self.last_prompt_message_count = @intCast(messages.len);
        var found: ?[]const u8 = null;
        for (messages) |view| {
            const message = view.message();
            if (message.role() == .user) found = message.text();
        }
        if (found == null) return;
        const owned = self.gpa.dupe(u8, found.?) catch {
            // Fail to unknown, not stale: `last_prompt_message_count` has
            // already moved, so keeping the previous text would lie about
            // what this prompt saw.
            if (self.last_user_text) |old| self.gpa.free(old);
            self.last_user_text = null;
            return;
        };
        if (self.last_user_text) |old| self.gpa.free(old);
        self.last_user_text = owned;
    }

    fn setErrorDetail(self: *Client, comptime fmt: []const u8, args: anytype) void {
        // Print first: on OOM the previous good detail survives instead of
        // being destroyed alongside the failed replacement.
        const printed = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        if (self.error_detail) |old| self.gpa.free(old);
        self.error_detail = printed;
    }
};

// ── tests ────────────────────────────────────────────────────────────────

const Seen = struct {
    content: std.ArrayList(u8) = .empty,
    tool_delta_count: u32 = 0,
    /// Borrows step-owned memory — read before `turn.deinit`.
    last_tool_name: []const u8 = "",
    delta_end_count: u32 = 0,

    fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.content.deinit(gpa);
    }

    fn onContent(ctx: *@This(), bytes: []const u8) anyerror!void {
        try ctx.content.appendSlice(std.testing.allocator, bytes);
    }

    fn onReasoning(ctx: *@This(), bytes: []const u8) anyerror!void {
        _ = ctx;
        _ = bytes;
    }

    fn onToolDelta(ctx: *@This(), delta: ai.ToolDelta) anyerror!void {
        ctx.tool_delta_count += 1;
        ctx.last_tool_name = delta.name;
    }

    fn onDeltaEnd(ctx: *@This()) anyerror!void {
        ctx.delta_end_count += 1;
    }
};

fn seenObserver(seen: *Seen) ai.StreamObserver(Seen) {
    return .{
        .ctx = seen,
        .on_content = Seen.onContent,
        .on_reasoning = Seen.onReasoning,
        .on_tool_delta = Seen.onToolDelta,
        .on_delta_end = Seen.onDeltaEnd,
    };
}

test "scripted client replays text through LanguageModel.prompt with streamed chunks" {
    // The union dispatch is the seam test: a `.scripted` tag satisfies the
    // same three-method contract the wire clients do, at compile time.
    const gpa = std.testing.allocator;
    var client = try Client.init(gpa, std.testing.io, "scripted-model");
    defer client.deinit();
    try client.enqueue(.{step.text("hello world", .stop)});

    const model = ai.LanguageModel{ .scripted = &client };
    var seen: Seen = .{};
    defer seen.deinit(gpa);

    var turn = try model.prompt(&.{}, seenObserver(&seen));
    defer turn.deinit(gpa);

    try std.testing.expectEqual(ai.FinishReason.stop, turn.finish_reason);
    try std.testing.expectEqualStrings("hello world", turn.assistant.text());
    try std.testing.expectEqual(@as(u32, 0), turn.tool_calls_truncated);
    // The text reached the observer in chunks that join to the whole.
    try std.testing.expectEqualStrings("hello world", seen.content.items);
    try std.testing.expectEqual(@as(u32, 1), seen.delta_end_count);
    try std.testing.expectEqual(@as(u32, 1), client.prompts_answered);
    try std.testing.expectEqual(@as(u32, 0), client.last_prompt_message_count);
    try std.testing.expect(client.last_user_text == null);
    try std.testing.expect(model.lastErrorDetail() == null);
}

test "scripted tool_calls step builds a complete turn and drives tool deltas" {
    const gpa = std.testing.allocator;
    var client = try Client.init(gpa, std.testing.io, "scripted-model");
    defer client.deinit();
    try client.enqueue(.{step.toolCall("pwsh", "{\"command\":\"echo hi\"}")});

    const model = ai.LanguageModel{ .scripted = &client };
    var seen: Seen = .{};
    defer seen.deinit(gpa);

    var turn = try model.prompt(&.{}, seenObserver(&seen));
    defer turn.deinit(gpa);

    try std.testing.expectEqual(ai.FinishReason.tool_calls, turn.finish_reason);
    try std.testing.expectEqual(@as(u32, 0), turn.tool_calls_truncated);
    var tool_calls: usize = 0;
    for (turn.assistant.assistant.content) |block| {
        if (block == .tool_call) {
            tool_calls += 1;
            try std.testing.expect(block.tool_call.call_id.slice().len > 0);
            try std.testing.expectEqualStrings("pwsh", block.tool_call.name);
            try std.testing.expectEqualStrings("{\"command\":\"echo hi\"}", block.tool_call.arguments);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), tool_calls);
    try std.testing.expectEqual(@as(u32, 1), seen.tool_delta_count);
    try std.testing.expectEqualStrings("pwsh", seen.last_tool_name);
}

test "scripted fail step returns the error and records error detail" {
    const gpa = std.testing.allocator;
    var client = try Client.init(gpa, std.testing.io, "scripted-model");
    defer client.deinit();
    try client.enqueue(.{step.fail(error.ScriptedProviderDown)});

    const model = ai.LanguageModel{ .scripted = &client };
    var seen: Seen = .{};
    defer seen.deinit(gpa);

    try std.testing.expectError(error.ScriptedProviderDown, model.prompt(&.{}, seenObserver(&seen)));
    const detail = model.lastErrorDetail() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, detail, "ScriptedProviderDown") != null);
}

test "script exhaustion errors instead of replaying a wrong turn" {
    const gpa = std.testing.allocator;
    var client = try Client.init(gpa, std.testing.io, "scripted-model");
    defer client.deinit();

    const model = ai.LanguageModel{ .scripted = &client };
    var seen: Seen = .{};
    defer seen.deinit(gpa);

    try std.testing.expectError(error.ScriptExhausted, model.prompt(&.{}, seenObserver(&seen)));
    try std.testing.expectError(error.ScriptExhausted, model.prompt(&.{}, seenObserver(&seen)));
    const detail = model.lastErrorDetail() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, detail, "exhausted") != null);
    try std.testing.expectEqual(@as(u32, 2), client.prompts_answered);
}

test "scripted client records the trailing user text and updateTools pushes" {
    const gpa = std.testing.allocator;
    var client = try Client.init(gpa, std.testing.io, "scripted-model");
    defer client.deinit();
    try client.enqueue(.{ step.text("ok", .stop), step.text("again", .stop) });

    var user_message = ai.ChatMessage{ .user = .{ .content = try blockWithText(gpa, "the actual prompt") } };
    defer user_message.deinit(gpa);
    const views = [_]ai.MessageView{.{ .owned = user_message }};

    const model = ai.LanguageModel{ .scripted = &client };
    var seen: Seen = .{};
    defer seen.deinit(gpa);

    var first = try model.prompt(&views, seenObserver(&seen));
    defer first.deinit(gpa);
    try std.testing.expectEqualStrings("the actual prompt", client.last_user_text.?);
    try std.testing.expectEqual(@as(u32, 1), client.last_prompt_message_count);

    var second = try model.prompt(&.{}, seenObserver(&seen));
    defer second.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), client.prompts_answered);

    try model.updateTools(&.{});
    try model.updateTools(&.{});
    try std.testing.expectEqual(@as(u32, 2), client.tools_update_count);
}

fn blockWithText(gpa: std.mem.Allocator, text_bytes: []const u8) ![]ai.ContentBlock {
    const content = try gpa.alloc(ai.ContentBlock, 1);
    errdefer gpa.free(content);
    const owned = try gpa.dupe(u8, text_bytes);
    errdefer gpa.free(owned);
    content[0] = .{ .text = .{ .text = owned } };
    return content;
}
