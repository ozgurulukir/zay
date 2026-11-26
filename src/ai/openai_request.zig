//! Chat-completions wire request payload serializer.
//!
//! Extracted from `openai_compatible.zig` — the chat-completions counterpart
//! of the Responses client's `responses_request.zig` (INV-RESP-1 symmetry):
//! message/content/tool-call JSON emission and dialect gating
//! (`stream_options`, `max_completion_tokens`, cache fields,
//! `enable_thinking`, the `reasoning` object) live here. HTTP transport, the
//! retry loop, and stream parsing stay in the client file;
//! `writeRequestPayload` is serialized once per cache mode and every retry
//! re-sends the same bytes.

const std = @import("std");
const log = std.log.scoped(.ai);

const ai = @import("../ai.zig");
const wire_json = @import("json.zig");
const model_compat = @import("model_compat.zig");
const tool_call_args = @import("tool_call_args.zig");

const normalizeMessagesForQwen = model_compat.normalizeMessagesForQwen;
const deinitNormalizedMessages = model_compat.deinitNormalizedMessages;

fn writeMessage(jw: *std.json.Stringify, gpa: std.mem.Allocator, message: ai.ChatMessage) !void {
    try jw.beginObject();
    try jw.objectField("role");
    const role_label: []const u8 = switch (message) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
    try jw.write(role_label);
    // Cache control is now emitted at the top level (writeRequestPayload),
    // not per-message. OpenRouter's top-level `cache_control` auto-marks the
    // last cacheable block, superseding the old system-message-only approach.
    try jw.objectField("content");
    switch (message) {
        .user => try writeUserContent(jw, gpa, message.user.content),
        inline .system, .assistant, .tool => |m| try writeTextContent(jw, gpa, m.content),
    }
    if (message == .tool) {
        try jw.objectField("tool_call_id");
        try wire_json.writeStringValue(jw, gpa, message.tool.call_id.slice());
    }
    if (message == .assistant) {
        var wrote_calls = false;
        for (message.assistant.content) |block| {
            if (block != .tool_call) continue;
            if (!wrote_calls) {
                try jw.objectField("tool_calls");
                try jw.beginArray();
                wrote_calls = true;
            }
            try writeToolCall(jw, gpa, block.tool_call);
        }
        if (wrote_calls) try jw.endArray();
    }
    try jw.endObject();
}

fn writeTextContent(jw: *std.json.Stringify, gpa: std.mem.Allocator, blocks: []const ai.ContentBlock) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    for (blocks) |block| {
        switch (block) {
            .text, .refusal => |text| try aw.writer.writeAll(text.text),
            .reasoning, .image, .tool_call => {},
        }
    }
    try wire_json.writeStringValue(jw, gpa, aw.written());
}

fn writeUserContent(jw: *std.json.Stringify, gpa: std.mem.Allocator, blocks: []const ai.ContentBlock) !void {
    try jw.beginArray();
    for (blocks) |block| {
        switch (block) {
            .text, .refusal => |text| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("text");
                try jw.objectField("text");
                try wire_json.writeStringValue(jw, gpa, text.text);
                try jw.endObject();
            },
            .image => |image| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("image_url");
                try jw.objectField("image_url");
                try jw.beginObject();
                try jw.objectField("url");
                var data_uri: std.Io.Writer.Allocating = .init(gpa);
                defer data_uri.deinit();
                try data_uri.writer.writeAll("data:");
                try data_uri.writer.writeAll(image.mime_type);
                try data_uri.writer.writeAll(";base64,");
                try data_uri.writer.writeAll(image.data_base64);
                try wire_json.writeStringValue(jw, gpa, data_uri.written());
                try jw.endObject();
                try jw.endObject();
            },
            .reasoning, .tool_call => {},
        }
    }
    try jw.endArray();
}

fn writeToolCall(jw: *std.json.Stringify, gpa: std.mem.Allocator, tool_call: ai.ToolCall) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try wire_json.writeStringValue(jw, gpa, tool_call.call_id.slice());
    try jw.objectField("type");
    try jw.write("function");
    try jw.objectField("function");
    try jw.beginObject();
    try jw.objectField("name");
    try wire_json.writeStringValue(jw, gpa, tool_call.name);
    try jw.objectField("arguments");
    const args = tool_call_args.sanitizeToolArguments(tool_call.arguments);
    try wire_json.writeStringValue(jw, gpa, args);
    try jw.endObject();
    try jw.endObject();
}

/// Options for the chat-completions request body — what a caller must know
/// to serialize one. This is the client-facing interface; the wire clients
/// build one `PayloadOptions` per Client so the C2 cache downgrade is
/// "flip `.disable_prompt_cache`, re-serialize" without repeating a
/// positional argument list.
pub const PayloadOptions = struct {
    model: []const u8,
    session_id: []const u8 = "",
    reasoning: ?ai.Reasoning = null,
    max_output_tokens: ?u32 = null,
    dialect: ai.WireDialect = .minimal,
    disable_prompt_cache: bool = false,
    is_reasoning_model: bool = false,
    parallel_tool_calls: ?bool = null,
};

pub fn writeRequestPayload(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    model: []const u8,
    session_id: []const u8,
    messages: []const ai.MessageView,
    tools_json: []const u8,
    reasoning: ?ai.Reasoning,
    max_output_tokens: ?u32,
    dialect: ai.WireDialect,
    disable_prompt_cache: bool,
    is_reasoning_model: bool,
) !void {
    return writePayload(gpa, out, .{
        .model = model,
        .session_id = session_id,
        .reasoning = reasoning,
        .max_output_tokens = max_output_tokens,
        .dialect = dialect,
        .disable_prompt_cache = disable_prompt_cache,
        .is_reasoning_model = is_reasoning_model,
        .parallel_tool_calls = null,
    }, messages, tools_json);
}

/// Config-struct entry point; see `PayloadOptions`.
pub fn writePayload(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    opts: PayloadOptions,
    messages: []const ai.MessageView,
    tools_json: []const u8,
) !void {
    const model = opts.model;
    const session_id = opts.session_id;
    const reasoning = opts.reasoning;
    const max_output_tokens = opts.max_output_tokens;
    const dialect = opts.dialect;
    const disable_prompt_cache = opts.disable_prompt_cache;
    const is_reasoning_model = opts.is_reasoning_model;
    // Real early returns — these MUST survive into the ReleaseFast install
    // build. `std.debug.assert` compiles to `unreachable` (UB) in ReleaseFast,
    // so it asserts nothing there (AGENTS.md §Safety). An empty model id is a
    // genuine error state — the same `error.EmptyModelId` the upstream guards
    // surface (`tui.applySelectedModel`, `runtime.applyFromConfig`) — so callers
    // already handle it.
    if (model.len == 0) return error.EmptyModelId;
    // NOTE: tools_json may legitimately be "[]" — the compaction and naming
    // clients send no tools, and a tools-less main client is a real (if broken)
    // state. The `else` branch below logs it (with model+url, see L2) rather
    // than erroring; never reintroduce an assert or an early return for the
    // empty-tools case.

    // Strict-template models (Qwen/DashScope, DeepSeek, Mistral, Gemma, Claude,
    // Gemini) require a single leading system message; merge + hoist for them
    // while leaving generic/OpenAI models untouched.
    const needs_system_normalize = model_compat.requiresSingleLeadingSystem(model, dialect);
    var normalized: std.ArrayListUnmanaged(ai.ChatMessage) = .empty;
    var wrapped: std.ArrayListUnmanaged(ai.MessageView) = .empty;
    var rebuilt = false;
    const effective_messages: []const ai.MessageView = if (needs_system_normalize) blk: {
        const res = try normalizeMessagesForQwen(gpa, messages);
        rebuilt = res.rebuilt;
        normalized = res.list;
        for (normalized.items) |*m| {
            try wrapped.append(gpa, ai.MessageView{ .borrowed = @ptrCast(@constCast(m)) });
        }
        break :blk wrapped.items;
    } else messages;
    defer if (needs_system_normalize) {
        wrapped.deinit(gpa);
        deinitNormalizedMessages(gpa, normalized, rebuilt);
    };

    var jw: std.json.Stringify = .{ .writer = out, .options = .{} };
    try jw.beginObject();
    try jw.objectField("model");
    try wire_json.writeStringValue(&jw, gpa, model);
    try jw.objectField("messages");
    try jw.beginArray();
    for (effective_messages) |*view| {
        try writeMessage(&jw, gpa, view.message().*);
    }
    try jw.endArray();
    // `stream_options.include_usage` makes the server emit a final usage-only
    // chunk (empty `choices`) before `[DONE]`. Without it, streaming responses
    // carry no token counts. Some OpenAI-compatible servers ignore it, so the
    // parser treats usage as optional. OpenRouter marks `include_usage` as
    // deprecated ("Full usage details are always included"), so it is omitted
    // for that dialect to avoid noise.
    try jw.objectField("stream");
    try jw.write(true);
    if (dialect != .openrouter) {
        try jw.objectField("stream_options");
        try jw.beginObject();
        try jw.objectField("include_usage");
        try jw.write(true);
        try jw.endObject();
    }
    // OpenAI reasoning models (o-series, gpt-5) ignore the legacy `max_tokens`
    // field; the openai-compatible provider maps it to `max_completion_tokens`
    // for them. Emit `max_completion_tokens` only for the OpenAI-native dialect
    // on a reasoning model; all other dialects keep `max_tokens`, the
    // universally-supported field.
    if (max_output_tokens) |mot| {
        if (dialect == .openai and is_reasoning_model) {
            try jw.objectField("max_completion_tokens");
        } else {
            try jw.objectField("max_tokens");
        }
        try jw.print("{d}", .{mot});
    }
    if (!std.mem.eql(u8, tools_json, "[]")) {
        try jw.objectField("tools");
        // `tools_json` is a pre-serialized JSON array — stream it as a raw value.
        try jw.beginWriteRaw();
        try out.writeAll(tools_json);
        jw.endWriteRaw();
        try jw.objectField("tool_choice");
        try jw.write("auto");
        if (opts.parallel_tool_calls) |ptc| {
            try jw.objectField("parallel_tool_calls");
            try jw.write(ptc);
        }
    } else {
        log.warn("openai_compatible: sending request with NO tools (tools_json is empty) model={s}", .{model});
    }
    // Cache + routing directives (all suppressed when `disable_prompt_cache`).
    // OpenRouter uses two dedicated top-level fields: `cache_control` (auto
    // breakpoint on the last cacheable block) and `session_id` (sticky provider
    // routing + cache grouping + observability). OpenAI-native dialects use the
    // classic `prompt_cache_key` hint. Minimal/dashscope send neither.
    if (!disable_prompt_cache) {
        if (dialect.allowsTopLevelCacheControl()) {
            try jw.objectField("cache_control");
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("ephemeral");
            try jw.endObject();
        }
        if (session_id.len > 0) {
            if (dialect.usesNativeSessionId()) {
                try jw.objectField("session_id");
                try wire_json.writeStringValue(&jw, gpa, session_id);
            } else if (dialect.allowsPromptCacheKey()) {
                try jw.objectField("prompt_cache_key");
                try wire_json.writeStringValue(&jw, gpa, session_id);
            }
        }
    }
    // Reasoning control. Effort levels: default/minimal/low/none/medium/high/
    // xhigh/max (the last two are OpenRouter extensions). Summary verbosity
    // (auto/concise/detailed) is OpenRouter-only in the chat-completions body.
    const effort = if (reasoning) |value| value.effort else null;
    const summary = if (reasoning) |value| value.summary else null;

    // DashScope controls thinking via a top-level boolean, independent of effort.
    if (dialect.usesEnableThinking()) {
        if (effort) |value| {
            try jw.objectField("enable_thinking");
            try jw.write(value != .none);
            if (value != .none and value != .default) {
                // Clip unsupported effort levels (high/max/minimal → medium/low)
                // to avoid HTTP 400 — DashScope rejects them. See wireEffortLabel.
                // `.default` means "don't override the model's own behaviour" —
                // and runinfra's DashScope-hosted Qwen rejects
                // `reasoning_effort:"default"` with HTTP 400 (upstream_error).
                // Live-verified: `enable_thinking:true` WITHOUT the effort
                // field streams thinking + the final message cleanly (200).
                // Sending the raw "default" label is invalid there, so it is
                // omitted entirely.
                try jw.objectField("reasoning_effort");
                try jw.write(model_compat.resolveEffortLabel(model, dialect, value) orelse value.label());
            }
        }
        try jw.endObject();
        return;
    }

    // OpenRouter uses the `reasoning` object with both `effort` and `summary`.
    // When neither is set (null/default effort + null/auto summary), emit
    // nothing so we don't override the model's own reasoning behaviour. `auto`
    // summary = model default, treated like `default` effort — not sent.
    if (dialect == .openrouter) {
        const resolved_effort = if (effort) |e| model_compat.resolveEffortLabel(model, dialect, e) else null;
        const has_effort = resolved_effort != null;
        const has_summary = summary != null and summary.? != .auto;
        if (has_effort or has_summary) {
            try jw.objectField("reasoning");
            try jw.beginObject();
            if (resolved_effort) |label| {
                try jw.objectField("effort");
                try jw.write(label);
            }
            if (has_summary) {
                try jw.objectField("summary");
                try jw.write(summary.?.label());
            }
            try jw.endObject();
        }
        try jw.endObject();
        return;
    }

    // OpenAI-native and minimal dialects: flat `reasoning_effort` field. The
    // `default` level means "don't override" — emit nothing. Values that the
    // target rejects are clipped by `wireEffortLabel` (see comment there).
    const wire_label = model_compat.resolveEffortLabel(model, dialect, effort orelse .default);
    if (wire_label) |label| {
        try jw.objectField("reasoning_effort");
        try jw.write(label);
    }
    try jw.endObject();
}

test "writeRequestPayload disables thinking for reasoning effort none" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    // DashScope dialect uses enable_thinking:false
    try writeRequestPayload(gpa, &payload.writer, "qwen-test", "", &.{}, "[]", .{ .effort = .none }, null, .dashscope, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "writeRequestPayload dashscope default effort omits reasoning_effort but keeps thinking" {
    // runinfra DashScope-hosted Qwen rejects `reasoning_effort:"default"`
    // with HTTP 400 (upstream_error). `.default` means "don't override the
    // model's own behaviour" — it must NOT serialize the raw "default" label.
    // Live-verified that `enable_thinking:true` alone (no effort field)
    // streams thinking + the final message cleanly. Regression for the
    // user's `"reasoningEffort":"default"` config on `qwen3-8-27b`.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "qwen3-8-27b", "", &.{}, "[]", .{ .effort = .default }, null, .dashscope, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "default") == null);
}

test "writeRequestPayload dashscope medium effort keeps enable_thinking plus effort" {
    // Sanity: an explicit valid DashScope effort level still serializes both
    // `enable_thinking:true` and `reasoning_effort`. Only `.default` and
    // `.none` special-case the boolean.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "qwen3-8-27b", "", &.{}, "[]", .{ .effort = .medium }, null, .dashscope, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"medium\"") != null);
}

test "writeRequestPayload uses reasoning_effort none for minimal dialect" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "ollama-model", "", &.{}, "[]", .{ .effort = .none }, null, .minimal, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "enable_thinking") == null);
}

test "minimal dialect clips xhigh reasoning_effort to max" {
    // Ollama's /v1/chat/completions validates reasoning_effort strictly:
    // only high/medium/low/max/none are accepted. The minimal dialect
    // (Ollama Cloud, Groq, vLLM) must clip xhigh → max to avoid HTTP 400.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "ollama-model", "", &.{}, "[]", .{ .effort = .xhigh }, null, .minimal, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"max\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "xhigh") == null);
}

test "minimal dialect clips minimal reasoning_effort to low" {
    // `minimal` is not in Ollama's accepted set; clip to the nearest valid
    // level (low) for the minimal dialect.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "ollama-model", "", &.{}, "[]", .{ .effort = .minimal }, null, .minimal, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "minimal") == null);
}

test "dashscope dialect clips high/max reasoning_effort to medium" {
    // Qwen / DashScope rejects `high` and `max` (HTTP 400), keeping only
    // low/medium/none/xhigh. Clip high-tier levels to medium. Regression:
    // `high` returned HTTP 400 and the stream parser threw UnexpectedToken.
    const gpa = std.testing.allocator;
    var p_high: std.Io.Writer.Allocating = .init(gpa);
    defer p_high.deinit();
    try writeRequestPayload(gpa, &p_high.writer, "qwen3-8-27b", "", &.{}, "[]", ai.Reasoning{ .effort = .high }, null, .dashscope, false, false);
    const body_high = p_high.written();
    try std.testing.expect(std.mem.indexOf(u8, body_high, "\"reasoning_effort\":\"medium\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_high, "high") == null);

    var p_max: std.Io.Writer.Allocating = .init(gpa);
    defer p_max.deinit();
    try writeRequestPayload(gpa, &p_max.writer, "qwen3-8-27b", "", &.{}, "[]", ai.Reasoning{ .effort = .max }, null, .dashscope, false, false);
    const body_max = p_max.written();
    try std.testing.expect(std.mem.indexOf(u8, body_max, "\"reasoning_effort\":\"medium\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_max, "max") == null);
}

test "dashscope dialect clips minimal reasoning_effort to low" {
    // `minimal` is rejected by DashScope too; clip to low.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "qwen3-8-27b", "", &.{}, "[]", ai.Reasoning{ .effort = .minimal }, null, .dashscope, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "minimal") == null);
}

test "dashscope dialect preserves xhigh and low/medium reasoning_effort" {
    // DashScope accepts xhigh/low/medium/none verbatim — only high/max/minimal
    // are clipped.
    const gpa = std.testing.allocator;
    var p_xhigh: std.Io.Writer.Allocating = .init(gpa);
    defer p_xhigh.deinit();
    try writeRequestPayload(gpa, &p_xhigh.writer, "qwen3-8-27b", "", &.{}, "[]", ai.Reasoning{ .effort = .xhigh }, null, .dashscope, false, false);
    try std.testing.expect(std.mem.indexOf(u8, p_xhigh.written(), "\"reasoning_effort\":\"xhigh\"") != null);

    var p_low: std.Io.Writer.Allocating = .init(gpa);
    defer p_low.deinit();
    try writeRequestPayload(gpa, &p_low.writer, "qwen3-8-27b", "", &.{}, "[]", ai.Reasoning{ .effort = .low }, null, .dashscope, false, false);
    try std.testing.expect(std.mem.indexOf(u8, p_low.written(), "\"reasoning_effort\":\"low\"") != null);
}

test "openai dialect preserves xhigh and minimal reasoning_effort" {
    // The OpenAI-native dialect must NOT clip — gpt-5 honours xhigh/max and
    // minimal is a valid level there. Only the minimal dialect clips.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "gpt-5", "", &.{}, "[]", .{ .effort = .xhigh }, null, .openai, false, true);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"xhigh\"") != null);

    var payload2: std.Io.Writer.Allocating = .init(gpa);
    defer payload2.deinit();
    try writeRequestPayload(gpa, &payload2.writer, "gpt-5", "", &.{}, "[]", .{ .effort = .minimal }, null, .openai, false, true);
    try std.testing.expect(std.mem.indexOf(u8, payload2.written(), "\"reasoning_effort\":\"minimal\"") != null);
}

test "minimal dialect omits reasoning_effort for default effort" {
    // `default` means "don't override" — the parameter must be absent.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "ollama-model", "", &.{}, "[]", .{ .effort = .default }, null, .minimal, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "writeRequestPayload uses reasoning object for openrouter dialect" {
    // OpenRouter controls reasoning via the `reasoning` object, not the
    // OpenAI-native `reasoning_effort` field. See
    // openrouter.ai/docs/guides/best-practices/reasoning-tokens.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "anthropic/claude-opus-5", "", &.{}, "[]", .{ .effort = .high }, null, .openrouter, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"high\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "writeRequestPayload uses reasoning object with none for openrouter dialect" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "anthropic/claude-opus-5", "", &.{}, "[]", .{ .effort = .none }, null, .openrouter, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"none\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "writeRequestPayload omits reasoning object for openrouter default effort" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "anthropic/claude-opus-5", "", &.{}, "[]", .{ .effort = .default }, null, .openrouter, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning") == null);
}

test "writeRequestPayload emits reasoning summary for openrouter dialect" {
    // OpenRouter's `reasoning` object accepts both `effort` and `summary`.
    // The chat-completions client must serialize `summary` alongside `effort`.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "anthropic/claude-opus-5", "", &.{}, "[]", .{ .effort = .high, .summary = .concise }, null, .openrouter, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"high\",\"summary\":\"concise\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "writeRequestPayload emits reasoning summary even with default effort" {
    // `default` effort = model's own behaviour, but a non-null summary still
    // produces a reasoning object with just the summary field.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "anthropic/claude-opus-5", "", &.{}, "[]", .{ .effort = .default, .summary = .detailed }, null, .openrouter, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"summary\":\"detailed\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "effort") == null);
}

test "writeRequestPayload emits max effort for openrouter dialect" {
    // `max` is the highest reasoning level (OpenRouter extension, above xhigh).
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "anthropic/claude-opus-5", "", &.{}, "[]", .{ .effort = .max }, null, .openrouter, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"max\"}") != null);
}

test "writeRequestPayload omits stream_options for openrouter dialect" {
    // OpenRouter marks `stream_options.include_usage` as deprecated — omit it.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "anthropic/claude-opus-5", "", &.{}, "[]", null, null, .openrouter, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "stream_options") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

test "writeRequestPayload keeps stream_options for non-openrouter dialects" {
    // Other dialects still need `stream_options.include_usage`.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "gpt-4o", "", &.{}, "[]", null, null, .openai, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
}

test "writeRequestPayload emits max_completion_tokens for openai reasoning models" {
    // OpenAI reasoning models (o-series, gpt-5) ignore the legacy `max_tokens`
    // field; the openai-compatible provider maps it to `max_completion_tokens`.
    // The OpenAI-native dialect on a reasoning model must emit the latter.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "gpt-5", "", &.{}, "[]", .{ .effort = .high }, 4096, .openai, false, true);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_completion_tokens\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\"") == null);
}

test "writeRequestPayload keeps max_tokens for openai non-reasoning models" {
    // A non-reasoning OpenAI model (gpt-4o) keeps the legacy `max_tokens`.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "gpt-4o", "", &.{}, "[]", .{ .effort = .high }, 4096, .openai, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_completion_tokens\"") == null);
}

test "writeRequestPayload keeps max_tokens for non-openai reasoning models" {
    // The max_completion_tokens mapping is OpenAI-native only; other dialects
    // (minimal, openrouter) keep the universally-supported `max_tokens` even
    // for reasoning models.
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "deepseek-reasoner", "", &.{}, "[]", .{ .effort = .high }, 4096, .minimal, false, true);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_completion_tokens\"") == null);
}

test "writeRequestPayload emits prompt_cache_key from the session id" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "gpt-test", "session-abc", &.{}, "[]", null, null, .openai, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt_cache_key\":\"session-abc\"") != null);
}

test "writeRequestPayload omits prompt_cache_key for minimal dialect" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "ollama-model", "session-abc", &.{}, "[]", null, null, .minimal, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_key") == null);
}

test "writeRequestPayload omits prompt_cache_key when no session id is set" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "qwen-test", "", &.{}, "[]", null, null, .openai, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_key") == null);
}

test "writeRequestPayload suppresses cache_control when disable_prompt_cache is true" {
    // C1: an OpenRouter model that rejects cache_control must have BOTH the
    // top-level cache_control AND the native session_id suppressed.
    const gpa = std.testing.allocator;
    const system_blocks = try gpa.alloc(ai.ContentBlock, 1);
    system_blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "You are a helpful agent.") } };
    var system_msg: ai.ChatMessage = .{ .system = .{ .content = system_blocks } };
    defer system_msg.deinit(gpa);
    const views = [_]ai.MessageView{.{ .borrowed = &system_msg }};

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "inclusionai/ling-3.0-flash:free", "sess-abc", &views, "[]", null, null, .openrouter, true, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "cache_control") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "session_id") == null);
}

test "writeRequestPayload emits cache_control when disable_prompt_cache is false" {
    // Regression guard: the flag defaults off, so the existing OpenRouter
    // cache behaviour is preserved. Top-level cache_control (auto breakpoint)
    // + native session_id (sticky routing).
    const gpa = std.testing.allocator;
    const system_blocks = try gpa.alloc(ai.ContentBlock, 1);
    system_blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "You are a helpful agent.") } };
    var system_msg: ai.ChatMessage = .{ .system = .{ .content = system_blocks } };
    defer system_msg.deinit(gpa);
    const views = [_]ai.MessageView{.{ .borrowed = &system_msg }};

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "inclusionai/ling-3.0-flash:free", "sess-abc", &views, "[]", null, null, .openrouter, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"session_id\":\"sess-abc\"") != null);
}

test "writeRequestPayload omits tools and tool_choice when there are none" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    // The background summarizer sends no tools ("[]"); the request must not carry
    // a `tool_choice` (rejected by strict providers) or invite a tool-call reply.
    try writeRequestPayload(gpa, &payload.writer, "summarizer", "", &.{}, "[]", null, null, .minimal, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_choice") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
}

test "writeRequestPayload repairs invalid UTF-8 in a user message text block" {
    // Regression: the compaction request is a single *user* message, so it
    // serializes through writeUserContent. A tool result with stray bytes in
    // the prefix made Stringify.value fall back to an array of integers
    // (`"text":[89,111,...]`), which providers reject with `400 invalid
    // message format`. The text must be emitted as a JSON string with the
    // invalid bytes replaced by U+FFFD.
    const gpa = std.testing.allocator;
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    // "ok" followed by an invalid UTF-8 byte 0xFF.
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "ok\xff") } };
    var user_msg: ai.ChatMessage = .{ .user = .{ .content = blocks } };
    defer user_msg.deinit(gpa);
    const views = [_]ai.MessageView{.{ .borrowed = &user_msg }};

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "summarizer", "", &views, "[]", null, null, .minimal, false, false);
    const body = payload.written();
    // The text must be a JSON string, not an array of integers.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":[") == null);
    // "ok" + U+FFFD (EF BF BD) as a JSON string.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"ok\xef\xbf\xbd\"") != null);
}

test "writeRequestPayload rejects an empty model id with EmptyModelId" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    // Empty tools ("[]") is legal; empty model is not. The guard must be a real
    // early return that fires in ReleaseFast, not a stripped `unreachable`.
    try std.testing.expectError(error.EmptyModelId, writeRequestPayload(gpa, &payload.writer, "", "", &.{}, "[]", null, null, .minimal, false, false));
}

test "writeRequestPayload keeps tools and tool_choice when tools are present" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "agent", "", &.{}, "[{\"type\":\"function\"}]", null, null, .minimal, false, false);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"type\":\"function\"}]") != null);
}

test "writeRequestPayload serializes tool call ids as strings, not objects" {
    const gpa = std.testing.allocator;

    // Build an assistant message with a tool_call block
    const assistant_blocks = try gpa.alloc(ai.ContentBlock, 1);
    assistant_blocks[0] = .{ .tool_call = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_abc123") },
        .name = try gpa.dupe(u8, "bash"),
        .arguments = try gpa.dupe(u8, "{\"command\":\"pwd\"}"),
    } };
    const assistant_msg: ai.ChatMessage = .{ .assistant = .{ .content = assistant_blocks } };

    // Build a tool result message
    const tool_blocks = try gpa.alloc(ai.ContentBlock, 1);
    tool_blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "/home/user") } };
    const tool_msg: ai.ChatMessage = .{ .tool = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_abc123") },
        .content = tool_blocks,
    } };

    var messages = [_]ai.ChatMessage{ assistant_msg, tool_msg };
    defer for (&messages) |*m| m.deinit(gpa);
    const views = [_]ai.MessageView{
        .{ .borrowed = &messages[0] },
        .{ .borrowed = &messages[1] },
    };

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "test-model", "", &views, "[{\"type\":\"function\"}]", null, null, .minimal, false, false);
    const body = payload.written();

    // The tool_call id must be a JSON string, not an object
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"call_abc123\"") != null);
    // The tool_call_id in the tool message must be a string
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"call_abc123\"") != null);
    // Negative: must NOT serialize CallId as an object
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":{\"value\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":{\"value\":") == null);
}

test "writeRequestPayload escapes a user image data URI with special characters" {
    // Regression: image.mime_type / image.data_base64 used to be written
    // verbatim into a JSON string. A value containing a quote (or backslash,
    // or control char) would terminate the string early and produce invalid
    // JSON. The data URI is now built in a buffer and emitted through
    // std.json.Stringify, so special characters are escaped.
    const gpa = std.testing.allocator;
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .image = .{
        .mime_type = try gpa.dupe(u8, "image/\"png"),
        .data_base64 = try gpa.dupe(u8, "YWJj"),
    } };
    var user_msg: ai.ChatMessage = .{ .user = .{ .content = blocks } };
    defer user_msg.deinit(gpa);
    const views = [_]ai.MessageView{.{ .borrowed = &user_msg }};

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "vision-model", "", &views, "[]", null, null, .minimal, false, false);
    const body = payload.written();

    // The data URI prefix is present and well-formed.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"url\":\"data:image/") != null);
    // A raw (unescaped) quote right after image/ must be gone.
    try std.testing.expect(std.mem.indexOf(u8, body, "image/\"") == null);
    // The JSON-escaped quote (backslash-quote) must be present instead.
    try std.testing.expect(std.mem.indexOf(u8, body, "image/\\\"") != null);
}

test "writePayload emits parallel_tool_calls when configured" {
    const gpa = std.testing.allocator;

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writePayload(gpa, &payload.writer, .{
        .model = "gpt-4o",
        .parallel_tool_calls = false,
    }, &.{}, "[{\"type\":\"function\"}]");

    try std.testing.expect(std.mem.indexOf(u8, payload.written(), ",\"parallel_tool_calls\":false") != null);

    var payload_true: std.Io.Writer.Allocating = .init(gpa);
    defer payload_true.deinit();

    try writePayload(gpa, &payload_true.writer, .{
        .model = "gpt-4o",
        .parallel_tool_calls = true,
    }, &.{}, "[{\"type\":\"function\"}]");

    try std.testing.expect(std.mem.indexOf(u8, payload_true.written(), ",\"parallel_tool_calls\":true") != null);
}

test "writePayload clips Qwen reasoning effort on OpenRouter dialect (#423)" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writePayload(gpa, &payload.writer, .{
        .model = "qwen/qwen3-32b",
        .dialect = .openrouter,
        .reasoning = .{ .effort = .high, .summary = .auto },
    }, &.{}, "[]");

    try std.testing.expect(std.mem.indexOf(u8, payload.written(), "\"effort\":\"medium\"") != null);
}
