const std = @import("std");
const tools_common = @import("tools/common.zig");

pub const codex_responses = @import("ai/codex_responses.zig");
pub const websocket = @import("websocket");
pub const openai_compatible = @import("ai/openai_compatible.zig");
pub const openai_responses = @import("ai/openai_responses.zig");

pub const Tool = tools_common.Tool;

pub const ReasoningEffort = enum {
    minimal,
    low,
    none,
    medium,
    high,
    xhigh,

    pub fn label(self: ReasoningEffort) []const u8 {
        return @tagName(self);
    }
};

pub const ReasoningSummary = enum {
    auto,
    concise,
    detailed,

    pub fn label(self: ReasoningSummary) []const u8 {
        return @tagName(self);
    }
};

pub const Reasoning = struct {
    effort: ?ReasoningEffort = .medium,
    summary: ?ReasoningSummary = .auto,
};

pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    tools: []const Tool = &.{},
    reasoning: ?Reasoning = .{},
    account_id: []const u8 = "",
    session_id: []const u8 = "",
    system_prompt: []const u8 = "You are a helpful assistant.",
};

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn label(self: Role) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(role: []const u8) !Role {
        if (std.mem.eql(u8, role, "system")) return .system;
        if (std.mem.eql(u8, role, "user")) return .user;
        if (std.mem.eql(u8, role, "assistant")) return .assistant;
        if (std.mem.eql(u8, role, "tool")) return .tool;
        return error.InvalidRole;
    }
};

pub const TextBlock = struct {
    text: []u8,
    responses_item_id: ?[]u8 = null,
    responses_phase: ?[]u8 = null,

    pub fn deinit(self: *TextBlock, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        if (self.responses_item_id) |id| gpa.free(id);
        if (self.responses_phase) |phase| gpa.free(phase);
        self.* = undefined;
    }
};

pub const ImageBlock = struct {
    mime_type: []u8,
    data_base64: []u8,

    pub fn deinit(self: *ImageBlock, gpa: std.mem.Allocator) void {
        gpa.free(self.mime_type);
        gpa.free(self.data_base64);
        self.* = undefined;
    }
};

pub const ReasoningBlock = struct {
    text: []u8,
    responses_item_json: ?[]u8 = null,

    pub fn deinit(self: *ReasoningBlock, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        if (self.responses_item_json) |json| gpa.free(json);
        self.* = undefined;
    }
};

pub const ToolCall = struct {
    call_id: []u8,
    responses_item_id: ?[]u8 = null,
    name: []u8,
    arguments: []u8,

    pub fn deinit(self: *ToolCall, gpa: std.mem.Allocator) void {
        gpa.free(self.call_id);
        if (self.responses_item_id) |id| gpa.free(id);
        gpa.free(self.name);
        gpa.free(self.arguments);
        self.* = undefined;
    }
};

pub const ContentBlock = union(enum) {
    text: TextBlock,
    image: ImageBlock,
    reasoning: ReasoningBlock,
    tool_call: ToolCall,

    pub fn deinit(self: *ContentBlock, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .text => |*block| block.deinit(gpa),
            .image => |*block| block.deinit(gpa),
            .reasoning => |*block| block.deinit(gpa),
            .tool_call => |*block| block.deinit(gpa),
        }
        self.* = undefined;
    }
};

pub const ChatMessage = struct {
    role: Role,
    content: []ContentBlock,
    call_id: ?[]u8 = null,
    tool_display_label: ?[]u8 = null,

    pub fn text(self: ChatMessage) []const u8 {
        for (self.content) |block| {
            if (block == .text) return block.text.text;
        }
        return "";
    }

    pub fn deinit(self: *ChatMessage, gpa: std.mem.Allocator) void {
        for (self.content) |*block| block.deinit(gpa);
        gpa.free(self.content);
        if (self.call_id) |id| gpa.free(id);
        if (self.tool_display_label) |label| gpa.free(label);
        self.* = undefined;
    }
};

pub const Turn = struct {
    assistant: ChatMessage,

    pub fn deinit(self: *Turn, gpa: std.mem.Allocator) void {
        self.assistant.deinit(gpa);
        self.* = undefined;
    }
};

pub const ToolDelta = struct {
    index: u32,
    name: []const u8,
    arguments: []const u8,
};

pub const StreamObserver = struct {
    ptr: *anyopaque,
    on_content: *const fn (*anyopaque, []const u8) anyerror!void,
    on_reasoning: *const fn (*anyopaque, []const u8) anyerror!void,
    on_tool_delta: *const fn (*anyopaque, ToolDelta) anyerror!void,
    on_delta_end: *const fn (*anyopaque) anyerror!void,

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

pub const LanguageModel = union(enum) {
    none,
    codex_responses: *codex_responses.Client,
    openai_compatible: *openai_compatible.Client,
    openai_responses: *openai_responses.Client,

    pub fn prompt(
        self: LanguageModel,
        messages: []const ChatMessage,
        observer: StreamObserver,
    ) !Turn {
        return switch (self) {
            .none => error.NoProviderConnected,
            .codex_responses => |c| c.prompt(messages, observer),
            .openai_compatible => |c| c.prompt(messages, observer),
            .openai_responses => |c| c.prompt(messages, observer),
        };
    }
};
