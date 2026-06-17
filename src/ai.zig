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

    /// Error set for decoding a block from Nova's persistence JSON.
    pub const DecodeError = error{CorruptPayload} || std.mem.Allocator.Error;

    /// Encode and decode for Nova's canonical *persistence* JSON — the form the
    /// session store keeps on disk. This is NOT a provider's wire format;
    /// adapters in `ai/` own those. The two directions live together so a new
    /// variant cannot be added to one without the other (a round-trip test in
    /// session.zig guards the symmetry). If versioned/migrated payloads ever
    /// arrive, introduce a codec module that wraps these rather than spreading
    /// the version envelope across both halves.
    pub fn writeJson(self: ContentBlock, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .text => |text| {
                try writer.writeAll("{\"type\":\"text\",\"text\":");
                try std.json.Stringify.value(text.text, .{}, writer);
                if (text.responses_item_id) |id| {
                    try writer.writeAll(",\"responses_item_id\":");
                    try std.json.Stringify.value(id, .{}, writer);
                }
                if (text.responses_phase) |phase| {
                    try writer.writeAll(",\"responses_phase\":");
                    try std.json.Stringify.value(phase, .{}, writer);
                }
                try writer.writeByte('}');
            },
            .image => |image| {
                try writer.writeAll("{\"type\":\"image\",\"mime_type\":");
                try std.json.Stringify.value(image.mime_type, .{}, writer);
                try writer.writeAll(",\"data_base64\":");
                try std.json.Stringify.value(image.data_base64, .{}, writer);
                try writer.writeByte('}');
            },
            .reasoning => |reasoning| {
                try writer.writeAll("{\"type\":\"reasoning\",\"text\":");
                try std.json.Stringify.value(reasoning.text, .{}, writer);
                if (reasoning.responses_item_json) |json| {
                    try writer.writeAll(",\"responses_item_json\":");
                    try std.json.Stringify.value(json, .{}, writer);
                }
                try writer.writeByte('}');
            },
            .tool_call => |call| {
                try writer.writeAll("{\"type\":\"tool_call\",\"call_id\":");
                try std.json.Stringify.value(call.call_id, .{}, writer);
                if (call.responses_item_id) |id| {
                    try writer.writeAll(",\"responses_item_id\":");
                    try std.json.Stringify.value(id, .{}, writer);
                }
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(call.name, .{}, writer);
                try writer.writeAll(",\"arguments\":");
                try std.json.Stringify.value(call.arguments, .{}, writer);
                try writer.writeByte('}');
            },
        }
    }

    pub fn fromJson(gpa: std.mem.Allocator, value: std.json.Value) DecodeError!ContentBlock {
        if (value != .object) return error.CorruptPayload;
        const kind = value.object.get("type") orelse return error.CorruptPayload;
        if (kind != .string) return error.CorruptPayload;
        if (std.mem.eql(u8, kind.string, "text")) {
            const text = value.object.get("text") orelse return error.CorruptPayload;
            if (text != .string) return error.CorruptPayload;
            return .{ .text = .{
                .text = try gpa.dupe(u8, text.string),
                .responses_item_id = try jsonOptionalString(gpa, value, "responses_item_id"),
                .responses_phase = try jsonOptionalString(gpa, value, "responses_phase"),
            } };
        }
        if (std.mem.eql(u8, kind.string, "image")) {
            const mime = value.object.get("mime_type") orelse return error.CorruptPayload;
            const data = value.object.get("data_base64") orelse return error.CorruptPayload;
            if (mime != .string) return error.CorruptPayload;
            if (data != .string) return error.CorruptPayload;
            return .{ .image = .{ .mime_type = try gpa.dupe(u8, mime.string), .data_base64 = try gpa.dupe(u8, data.string) } };
        }
        if (std.mem.eql(u8, kind.string, "reasoning")) {
            const text = value.object.get("text") orelse return error.CorruptPayload;
            if (text != .string) return error.CorruptPayload;
            return .{ .reasoning = .{ .text = try gpa.dupe(u8, text.string), .responses_item_json = try jsonOptionalString(gpa, value, "responses_item_json") } };
        }
        if (std.mem.eql(u8, kind.string, "tool_call")) {
            const call_id = value.object.get("call_id") orelse return error.CorruptPayload;
            const name = value.object.get("name") orelse return error.CorruptPayload;
            const arguments = value.object.get("arguments") orelse return error.CorruptPayload;
            if (call_id != .string) return error.CorruptPayload;
            if (name != .string) return error.CorruptPayload;
            if (arguments != .string) return error.CorruptPayload;
            return .{ .tool_call = .{
                .call_id = try gpa.dupe(u8, call_id.string),
                .responses_item_id = try jsonOptionalString(gpa, value, "responses_item_id"),
                .name = try gpa.dupe(u8, name.string),
                .arguments = try gpa.dupe(u8, arguments.string),
            } };
        }
        return error.CorruptPayload;
    }
};

/// Dupe an optional string field from a JSON object. Returns null when absent,
/// `error.CorruptPayload` when present but not a string.
fn jsonOptionalString(gpa: std.mem.Allocator, value: std.json.Value, name: []const u8) ContentBlock.DecodeError!?[]u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return error.CorruptPayload;
    return try gpa.dupe(u8, field.string);
}

fn reencode(gpa: std.mem.Allocator, block: ContentBlock) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try block.writeJson(&out.writer);
    return out.toOwnedSlice();
}

test "ContentBlock JSON round-trips every variant" {
    const gpa = std.testing.allocator;
    var blocks = [_]ContentBlock{
        .{ .text = .{ .text = try gpa.dupe(u8, "hello"), .responses_item_id = try gpa.dupe(u8, "id1"), .responses_phase = try gpa.dupe(u8, "final") } },
        .{ .image = .{ .mime_type = try gpa.dupe(u8, "image/png"), .data_base64 = try gpa.dupe(u8, "AAAA") } },
        .{ .reasoning = .{ .text = try gpa.dupe(u8, "thinking"), .responses_item_json = try gpa.dupe(u8, "{}") } },
        .{ .tool_call = .{ .call_id = try gpa.dupe(u8, "c1"), .name = try gpa.dupe(u8, "bash"), .arguments = try gpa.dupe(u8, "{}") } },
    };
    defer for (&blocks) |*block| block.deinit(gpa);

    for (blocks) |block| {
        const json = try reencode(gpa, block);
        defer gpa.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
        defer parsed.deinit();
        var decoded = try ContentBlock.fromJson(gpa, parsed.value);
        defer decoded.deinit(gpa);
        // Decoding then re-encoding must reproduce the bytes exactly — proving
        // the two halves stay symmetric.
        const round_tripped = try reencode(gpa, decoded);
        defer gpa.free(round_tripped);
        try std.testing.expectEqualStrings(json, round_tripped);
    }
}

test "ContentBlock.fromJson rejects malformed payloads" {
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        "\"not an object\"",
        "{}",
        "{\"type\":\"text\"}",
        "{\"type\":\"bogus\"}",
        "{\"type\":\"text\",\"text\":5}",
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, case, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.CorruptPayload, ContentBlock.fromJson(gpa, parsed.value));
    }
}

pub const ChatMessage = struct {
    role: Role,
    content: []ContentBlock,
    call_id: ?[]u8 = null,
    tool_display_label: ?[]u8 = null,
    tool_failed: bool = false,

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

/// Token accounting for one model response, normalized across provider
/// dialects. Chat Completions reports `prompt_tokens`/`completion_tokens`;
/// the Responses API reports `input_tokens`/`output_tokens`. We store the
/// neutral `input`/`output` naming and parse each dialect at its adapter
/// boundary (see `boundary-discipline`).
///
/// `cached_input_tokens` is a *subset* of `input_tokens` (already counted in
/// it) and is informational only: a cached prompt is still re-sent in full,
/// so it never reduces the size used for context-overflow math.
pub const Usage = struct {
    input_tokens: u32,
    output_tokens: u32,
    total_tokens: u32,
    cached_input_tokens: u32 = 0,
    reasoning_tokens: u32 = 0,
};

/// Clamp a provider-reported token count (an arbitrary JSON integer parsed at
/// an adapter boundary) into the `u32` domain `Usage` uses. Negative or absurd
/// values collapse to the nearest representable bound rather than wrapping.
pub fn clampTokenCount(value: i64) u32 {
    if (value < 0) return 0;
    if (value > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(value);
}

pub const Turn = struct {
    assistant: ChatMessage,
    /// Token usage for this turn, when the provider reported it. `null` means
    /// the provider omitted usage (e.g. a streaming OpenAI-compatible endpoint
    /// without `stream_options.include_usage`); the budget falls back to a
    /// size estimate in that case.
    usage: ?Usage = null,

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

    pub fn lastErrorDetail(self: LanguageModel) ?[]const u8 {
        return switch (self) {
            .openai_compatible => |c| c.last_error_detail,
            else => null,
        };
    }
};
