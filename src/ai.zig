const std = @import("std");
const tools_common = @import("tools/common.zig");
const tools_mod = @import("tools.zig");

pub const codex_responses = @import("ai/codex_responses.zig");
pub const websocket = @import("websocket");
pub const openai_compatible = @import("ai/openai_compatible.zig");
pub const openai_responses = @import("ai/openai_responses.zig");

pub const Tool = tools_common.Tool;

/// Schema-only representation of an MCP tool, used for serialization into
/// the provider's `tools` JSON array. MCP tools lack the `run`/`display`
/// function pointers that `Tool` requires — they are dispatched through the
/// MCP transport instead.
pub const McpToolSchema = struct {
    name: []const u8,
    description: []const u8,
    schema: tools_common.Schema,
};

pub const ReasoningEffort = enum {
    /// Don't override the model's default reasoning behaviour — no
    /// `reasoning_effort` parameter is sent in the request.
    default,
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
    mcp_tools: []const McpToolSchema = &.{},
    reasoning: ?Reasoning = .{},
    /// Maximum tokens per generation turn. Sent as `max_tokens` in the
    /// request body when non-null. Sourced from per-model config
    /// (`providers.<name>.models.<id>.maxOutputTokens`) or global
    /// `context.maxOutputTokens`.
    max_output_tokens: ?u32 = null,
    /// Upper bound on parallel tool calls the stream parser will accept.
    /// Providers that exceed this get a logged error instead of silent
    /// truncation. Hard array capacity is 64; this is the runtime gate.
    max_parallel_tool_calls: u32 = 16,
    /// Socket-level read timeout in seconds for streaming responses.
    /// Prevents indefinite hangs when the server stops mid-stream.
    request_timeout_seconds: u32 = 300,
    /// Structured-outputs mode. `true` only works against the OpenAI API;
    /// gateways (OpenRouter/Ollama/vLLM/Together) reject or silently break
    /// strict schemas, which disables function-calling — the model then
    /// emits tool calls as plain text instead of `tool_calls` deltas.
    /// Default `false` keeps tool-calling working everywhere.
    strict: bool = false,
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

/// Branded wrapper for an LLM-generated tool call identifier. Carries an
/// owned `[]u8` slice. The brand prevents accidental cross-wiring with
/// other `[]u8` id fields (e.g. `model_id`, `account_id`) at call sites
/// across module boundaries. Use `.slice()` to bridge to `[]const u8`
/// parameters; use `.value` for direct `gpa.free` / `gpa.dupe`.
pub const CallId = struct {
    value: []u8,

    pub fn slice(self: *const CallId) []const u8 {
        return self.value;
    }
};

pub const ToolCall = struct {
    call_id: CallId,
    responses_item_id: ?[]u8 = null,
    name: []u8,
    arguments: []u8,

    pub fn deinit(self: *ToolCall, gpa: std.mem.Allocator) void {
        gpa.free(self.call_id.value);
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
                try std.json.Stringify.value(@as([]const u8, text.text), .{}, writer);
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
                try std.json.Stringify.value(@as([]const u8, reasoning.text), .{}, writer);
                if (reasoning.responses_item_json) |json| {
                    try writer.writeAll(",\"responses_item_json\":");
                    try std.json.Stringify.value(json, .{}, writer);
                }
                try writer.writeByte('}');
            },
            .tool_call => |call| {
                try writer.writeAll("{\"type\":\"tool_call\",\"call_id\":");
                try std.json.Stringify.value(call.call_id.slice(), .{}, writer);
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
            const text_str = if (text == .string)
                try gpa.dupe(u8, text.string)
            else if (text == .array)
                try jsonByteArrayToString(gpa, text.array.items)
            else
                return error.CorruptPayload;

            return .{ .text = .{
                .text = text_str,
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
            const text_str = if (text == .string)
                try gpa.dupe(u8, text.string)
            else if (text == .array)
                try jsonByteArrayToString(gpa, text.array.items)
            else
                return error.CorruptPayload;

            return .{ .reasoning = .{ .text = text_str, .responses_item_json = try jsonOptionalString(gpa, value, "responses_item_json") } };
        }
        if (std.mem.eql(u8, kind.string, "tool_call")) {
            const call_id = value.object.get("call_id") orelse return error.CorruptPayload;
            const name = value.object.get("name") orelse return error.CorruptPayload;
            const arguments = value.object.get("arguments") orelse return error.CorruptPayload;
            if (call_id != .string) return error.CorruptPayload;
            if (name != .string) return error.CorruptPayload;
            if (arguments != .string) return error.CorruptPayload;
            return .{ .tool_call = .{
                .call_id = .{ .value = try gpa.dupe(u8, call_id.string) },
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

fn jsonByteArrayToString(gpa: std.mem.Allocator, items: []const std.json.Value) ContentBlock.DecodeError![]u8 {
    var buf = try gpa.alloc(u8, items.len);
    errdefer gpa.free(buf);
    for (items, 0..) |item, i| {
        if (item != .integer or item.integer < 0 or item.integer > 255) return error.CorruptPayload;
        buf[i] = @intCast(item.integer);
    }
    return buf;
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
        .{ .tool_call = .{ .call_id = .{ .value = try gpa.dupe(u8, "c1") }, .name = try gpa.dupe(u8, "bash"), .arguments = try gpa.dupe(u8, "{}") } },
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

/// One entry in the conversation projection. Variants make illegal
/// combinations unrepresentable: a `.user` message cannot have a
/// `call_id`, a `.tool` message must have one. `text()` and `deinit()`
/// are the only cross-variant accessors; everything else touches a
/// specific variant via a tag switch.
pub const ChatMessage = union(enum) {
    system: struct {
        content: []ContentBlock,
    },
    user: struct {
        content: []ContentBlock,
    },
    assistant: struct {
        content: []ContentBlock,
    },
    tool: struct {
        call_id: CallId,
        content: []ContentBlock,
        display_label: ?[]u8 = null,
        failed: bool = false,
    },

    /// The first text block in the message's content. Returns "" when
    /// the message is non-text (e.g. all tool calls or images).
    pub fn text(self: ChatMessage) []const u8 {
        const content: []const ContentBlock = switch (self) {
            inline .system, .user, .assistant => |m| m.content,
            .tool => |t| t.content,
        };
        for (content) |block| {
            if (block == .text) return block.text.text;
        }
        return "";
    }

    /// The Role corresponding to this variant. Useful for serialization
    /// and for the few call sites that need to switch on role without
    /// caring about the variant payload.
    pub fn role(self: ChatMessage) Role {
        return switch (self) {
            .system => .system,
            .user => .user,
            .assistant => .assistant,
            .tool => .tool,
        };
    }

    /// Free every owned buffer. Safe to call on undefined memory
    /// after — `self.* = undefined` poisons the slot for use-after-free
    /// detection.
    pub fn deinit(self: *ChatMessage, gpa: std.mem.Allocator) void {
        switch (self.*) {
            inline .system, .user, .assistant => |*m| freeBlocks(gpa, m.content),
            .tool => |*t| {
                gpa.free(t.call_id.value);
                if (t.display_label) |label| gpa.free(label);
                freeBlocks(gpa, t.content);
            },
        }
        self.* = undefined;
    }

    fn freeBlocks(gpa: std.mem.Allocator, blocks: []ContentBlock) void {
        for (blocks) |*block| block.deinit(gpa);
        gpa.free(blocks);
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

pub const NoopCtx = struct {};

/// Typed stream observer — generic over the consumer's context type.
/// Replaces the old `*anyopaque` + `@ptrCast` vtable. Callers pass their
/// own ctx type; the callbacks receive it typed.
pub fn StreamObserver(comptime Ctx: type) type {
    return struct {
        ctx: *Ctx,
        on_content: *const fn (*Ctx, []const u8) anyerror!void,
        on_reasoning: *const fn (*Ctx, []const u8) anyerror!void,
        on_tool_delta: *const fn (*Ctx, ToolDelta) anyerror!void,
        on_delta_end: *const fn (*Ctx) anyerror!void,
    };
}

var noop_ctx: NoopCtx = .{};

/// Noop stream observer for fire-and-forget prompts. Use `streamNoop()`.
pub fn streamNoop() StreamObserver(NoopCtx) {
    return .{
        .ctx = &noop_ctx,
        .on_content = noopBytes,
        .on_reasoning = noopBytes,
        .on_tool_delta = noopToolDelta,
        .on_delta_end = noopVoid,
    };
}

fn noopBytes(_: *NoopCtx, _: []const u8) anyerror!void {}
fn noopToolDelta(_: *NoopCtx, _: ToolDelta) anyerror!void {}
fn noopVoid(_: *NoopCtx) anyerror!void {}

pub const LanguageModel = union(enum) {
    none,
    codex_responses: *codex_responses.Client,
    openai_compatible: *openai_compatible.Client,
    openai_responses: *openai_responses.Client,

    pub fn prompt(
        self: LanguageModel,
        messages: []const ChatMessage,
        observer: anytype,
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

    /// Rebuild the active client's serialized tool definitions after the MCP
    /// tool set changes. No-op when no client is connected. `mcp_tools` is
    /// borrowed only for the duration of the call. `registry`, when
    /// non-null, contributes its builtin + plugin tools so the model sees
    /// them as first-class definitions. `builtin_override` lets the caller
    /// choose what `self.config.tools` contains at call time: most callers
    /// pass `&.{}` because the registry's builtin already covers bash,
    /// and emitting both would create a duplicate name that most APIs
    /// reject (HTTP 400), dropping the entire tool list.
    pub fn updateMcpTools(
        self: LanguageModel,
        mcp_tools: []const McpToolSchema,
        registry: ?*tools_mod.ToolRegistry,
        builtin_override: []const tools_common.Tool,
    ) !void {
        switch (self) {
            .none => {},
            .codex_responses => |c| try c.updateMcpTools(mcp_tools, registry, builtin_override),
            .openai_compatible => |c| try c.updateMcpTools(mcp_tools, registry, builtin_override),
            .openai_responses => |c| try c.updateMcpTools(mcp_tools, registry, builtin_override),
        }
    }
};

test "clampTokenCount clamps negative values to zero" {
    try std.testing.expectEqual(@as(u32, 0), clampTokenCount(-1));
    try std.testing.expectEqual(@as(u32, 0), clampTokenCount(-100));
    try std.testing.expectEqual(@as(u32, 0), clampTokenCount(std.math.minInt(i64)));
}

test "clampTokenCount clamps oversized values to max_u32" {
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), clampTokenCount(std.math.maxInt(u32) + 1));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), clampTokenCount(std.math.maxInt(i64)));
}

test "clampTokenCount passes through valid values" {
    try std.testing.expectEqual(@as(u32, 0), clampTokenCount(0));
    try std.testing.expectEqual(@as(u32, 100), clampTokenCount(100));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), clampTokenCount(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u32, 1_000_000), clampTokenCount(1_000_000));
}
