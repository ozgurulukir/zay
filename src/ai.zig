const std = @import("std");
const tools_common = @import("tools/common.zig");

pub const openai = @import("ai/openai.zig");

pub const Tool = tools_common.Tool;

pub const ReasoningEffort = enum {
    low,
    medium,
    high,
    xhigh,

    pub fn label(self: ReasoningEffort) []const u8 {
        return @tagName(self);
    }
};

pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    /// Tools the model can call. Each adapter consumes this to build its
    /// provider-specific tool schema JSON. Protocol-neutral.
    tools: []const Tool = &.{},
    reasoning_effort: ?ReasoningEffort = .medium,
};

/// The canonical, finalised record of one tool call — `{ id, name, arguments }`.
/// Lives on assistant `ChatMessage`s in history and in `Response.tool_calls`.
/// Ids are guaranteed non-empty; the LanguageModel adapter mints fallbacks
/// when the protocol omits them. Distinct from `ToolDelta` (the streaming
/// chunk shape, carried inside `StreamObserver.on_tool_delta`).
pub const ToolCall = struct {
    id: []u8,
    name: []u8,
    arguments: []u8,

    pub fn deinit(self: *ToolCall, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.arguments);
        self.* = undefined;
    }
};

/// A streaming chunk of one in-progress tool call, delivered to
/// `StreamObserver.on_tool_delta`. `name` and `arguments` are *chunks*, not
/// complete values; the adapter accumulates them internally and assembles
/// the finalised `ToolCall` for the returned `Response`. Borrowed for the
/// duration of the callback.
pub const ToolDelta = struct {
    index: u32,
    name: []const u8,
    arguments: []const u8,
};

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
    /// Present only for messages with role="tool". Holds the id of the
    /// assistant tool_call this result is responding to.
    tool_call_id: ?[]const u8 = null,
    /// Present only for messages with role="assistant" that emitted at least
    /// one tool call. The order matches the response's tool_calls order.
    tool_calls: []const ToolCall = &.{},
};

pub const Response = struct {
    content: []u8,
    reasoning: []u8,
    tool_calls: std.ArrayList(ToolCall) = .empty,

    pub fn deinit(self: *Response, gpa: std.mem.Allocator) void {
        gpa.free(self.content);
        gpa.free(self.reasoning);
        for (self.tool_calls.items) |*tool_call| {
            tool_call.deinit(gpa);
        }
        self.tool_calls.deinit(gpa);
        self.* = undefined;
    }
};

/// The narrow private callback interface a `LanguageModel` adapter uses to
/// report inference progress back to its caller (the agent). Typed
/// callbacks — no optional fn pointers; consumers that don't want a given
/// callback supply the matching `StreamObserver.noop_*` fn.
pub const StreamObserver = struct {
    ptr: *anyopaque,
    on_content: *const fn (*anyopaque, []const u8) anyerror!void,
    on_reasoning: *const fn (*anyopaque, []const u8) anyerror!void,
    on_tool_delta: *const fn (*anyopaque, ToolDelta) anyerror!void,
    on_delta_end: *const fn (*anyopaque) anyerror!void,

    /// A no-op observer for callers that don't care about streaming
    /// callbacks (most tests). Branch-free at the call site.
    pub const noop: StreamObserver = .{
        .ptr = undefined,
        .on_content = noopBytes,
        .on_reasoning = noopBytes,
        .on_tool_delta = noopToolDelta,
        .on_delta_end = noopVoid,
    };

    pub fn noopBytes(_: *anyopaque, _: []const u8) anyerror!void {}
    pub fn noopToolDelta(_: *anyopaque, _: ToolDelta) anyerror!void {}
    pub fn noopVoid(_: *anyopaque) anyerror!void {}
};

/// The agent's seam to LLM inference. A tagged union over LM adapters —
/// `openai` today; more planned. Exposes `prompt(messages, observer)` which
/// dispatches to the active adapter. The agent never sees protocol vocabulary.
pub const LanguageModel = union(enum) {
    openai: *openai.Client,

    pub fn prompt(
        self: LanguageModel,
        messages: []const ChatMessage,
        observer: StreamObserver,
    ) !Response {
        return switch (self) {
            .openai => |c| c.prompt(messages, observer),
        };
    }
};
