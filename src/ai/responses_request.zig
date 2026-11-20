//! Wire request payload serializer for the Responses API.
//!
//! Extracted from responses_core.zig: serializes system instructions, message
//! history, tool declarations, prompt cache flags, and dialect-specific reasoning
//! configurations into JSON wire format.

const std = @import("std");

const ai = @import("../ai.zig");
const wire_json = @import("json.zig");
const model_compat = @import("model_compat.zig");
const responses_core = @import("responses_core.zig");
const tool_call_args = @import("tool_call_args.zig");
const tool_schema = @import("tool_schema.zig");
const tools_mod = @import("../tools.zig");

const log = std.log.scoped(.ai);

pub fn writeRequestPayload(
    out: *std.Io.Writer,
    gpa: std.mem.Allocator,
    config: ai.Config,
    responses_config: responses_core.ResponsesConfig,
    messages: []const ai.MessageView,
    tools_json: []const u8,
) !void {
    var jw: std.json.Stringify = .{ .writer = out, .options = .{} };
    try jw.beginObject();
    try jw.objectField("model");
    try wire_json.writeStringValue(&jw, gpa, config.model);
    try jw.objectField("input");
    try jw.beginArray();
    for (messages) |*view| {
        if (config.system_prompt.len > 0 and view.message().* == .system) continue;
        try writeInputMessage(
            &jw,
            view.message().*,
            gpa,
            responses_config.log_name,
            responses_config.scrub_encrypted_reasoning,
        );
    }
    try jw.endArray();
    try jw.objectField("stream");
    try jw.write(true);
    try jw.objectField("store");
    try jw.write(false);
    try jw.objectField("tools");
    // `tools_json` is a pre-serialized JSON array — stream it as a raw value.
    try jw.beginWriteRaw();
    try out.writeAll(tools_json);
    jw.endWriteRaw();
    // `tool_choice` accompanies a non-empty tools array, mirroring the
    // chat-completions path (openai_request.writeRequestPayload): several
    // Responses endpoints reject the pair when the array is empty.
    if (!std.mem.eql(u8, tools_json, "[]")) {
        try jw.objectField("tool_choice");
        try jw.write("auto");
    }
    if (config.system_prompt.len > 0) {
        try jw.objectField("instructions");
        try wire_json.writeStringValue(&jw, gpa, config.system_prompt);
    }
    if (config.session_id.len > 0 and !config.disable_prompt_cache) {
        try jw.objectField("prompt_cache_key");
        try wire_json.writeStringValue(&jw, gpa, config.session_id);
    }
    if (responses_config.text_verbosity) |verbosity| {
        try jw.objectField("text");
        try jw.beginObject();
        try jw.objectField("verbosity");
        try wire_json.writeStringValue(&jw, gpa, verbosity);
        try jw.endObject();
    }
    if (responses_config.parallel_tool_calls) |enabled| {
        try jw.objectField("parallel_tool_calls");
        try jw.write(enabled);
    }
    if (config.reasoning) |value| {
        try jw.objectField("reasoning");
        try jw.beginObject();
        if (value.effort) |effort| {
            // Clip Ollama-incompatible effort values for the minimal dialect,
            // mirroring the chat-completions path (model_compat.wireEffortLabel).
            // The Responses-API site is not dialect-gated for cache fields (C1/C2
            // in AGENTS.md), but effort clipping is cheap and keeps the two wire
            // clients consistent so a provider switch never changes the effort
            // semantics unexpectedly.
            const wire_label = model_compat.resolveEffortLabel(config.model, config.wire_dialect, effort);
            if (wire_label) |label| {
                try jw.objectField("effort");
                try jw.write(label);
            }
        }
        if (value.summary) |summary| {
            try jw.objectField("summary");
            try jw.write(summary.label());
        }
        try jw.endObject();
        // When effort is `.default` and summary is null, this object is empty
        // ("reasoning":{}). With include_encrypted_reasoning=false (Codex) the
        // include array is omitted — the reasoning object itself (effort and
        // summary) is still sent, only the encrypted blob is never requested.
        if (responses_config.include_encrypted_reasoning) {
            try jw.objectField("include");
            try jw.beginArray();
            try jw.write("reasoning.encrypted_content");
            try jw.endArray();
        }
    }
    try jw.endObject();
}

fn writeInputMessage(
    jw: *std.json.Stringify,
    message: ai.ChatMessage,
    gpa: std.mem.Allocator,
    log_name: []const u8,
    scrub_encrypted_reasoning: bool,
) !void {
    switch (message) {
        .assistant => return writeAssistantItems(jw, message, gpa, log_name, scrub_encrypted_reasoning),
        .tool => return writeToolOutput(jw, gpa, message),
        .system => {
            try writeRoleMessage(jw, gpa, "system", message.system.content);
        },
        .user => {
            try writeRoleMessage(jw, gpa, "user", message.user.content);
        },
    }
}

fn writeRoleMessage(jw: *std.json.Stringify, gpa: std.mem.Allocator, role: []const u8, content: []const ai.ContentBlock) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("message");
    try jw.objectField("role");
    try jw.write(role);
    try jw.objectField("content");
    try writeInputContent(jw, gpa, content);
    try jw.endObject();
}

/// Copy `json` with any top-level `"encrypted_content"` field removed.
/// Returns null when the input carries no such field (caller falls back to
/// writing the original bytes) or on any parse/serialize failure (never
/// reject replayed history over a scrub failure — upstream guidance is
/// skip-not-fail, openai/codex#25290).
fn scrubEncryptedContent(
    gpa: std.mem.Allocator,
    json: []const u8,
) ?[]u8 {
    return scrubEncryptedContentOrError(gpa, json) catch null;
}

fn scrubEncryptedContentOrError(
    gpa: std.mem.Allocator,
    json: []const u8,
) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    if (!obj.contains("encrypted_content")) return null;
    // Re-serialize by iteration instead of removing through a map copy:
    // mutating a copied ArrayHashMap corrupts state shared with the original.
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    var jw: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
    try jw.beginObject();
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "encrypted_content")) continue;
        try jw.objectField(entry.key_ptr.*);
        try jw.write(entry.value_ptr.*);
    }
    try jw.endObject();
    return try buf.toOwnedSlice();
}

fn writeAssistantItems(
    jw: *std.json.Stringify,
    message: ai.ChatMessage,
    gpa: std.mem.Allocator,
    log_name: []const u8,
    scrub_encrypted_reasoning: bool,
) !void {
    var wrote_any = false;
    const blocks = message.assistant.content;
    var index: usize = 0;
    while (index < blocks.len) {
        const block = blocks[index];
        var end = index + 1;
        if (textBlock(block)) |text| {
            if (text.responses_item_id) |id| {
                while (end < blocks.len) : (end += 1) {
                    const next = textBlock(blocks[end]) orelse break;
                    const next_id = next.responses_item_id orelse break;
                    if (!std.mem.eql(u8, id, next_id)) break;
                }
            }
        }
        wrote_any = true;
        switch (block) {
            .text, .refusal => try writeTextItem(jw, gpa, blocks[index..end]),
            .reasoning => |reasoning| {
                if (reasoning.responses_item_json) |json| {
                    if (scrub_encrypted_reasoning) {
                        if (scrubEncryptedContent(gpa, json)) |clean| {
                            defer gpa.free(clean);
                            log.info("responses.replay.scrubbed_encrypted_content client={s}", .{log_name});
                            try writeRawJson(jw, clean);
                        } else {
                            try writeRawJson(jw, json);
                        }
                    } else {
                        try writeRawJson(jw, json);
                    }
                } else {
                    try jw.beginObject();
                    try jw.objectField("type");
                    try jw.write("reasoning");
                    try jw.objectField("summary");
                    try jw.beginArray();
                    try jw.beginObject();
                    try jw.objectField("type");
                    try jw.write("summary_text");
                    try jw.objectField("text");
                    try wire_json.writeStringValue(jw, gpa, reasoning.text);
                    try jw.endObject();
                    try jw.endArray();
                    try jw.endObject();
                }
            },
            .tool_call => |call| try writeFunctionCall(jw, gpa, call),
            .image => try writeAssistantMessageWithRawContent(jw, "[]"),
        }
        index = end;
    }
    if (!wrote_any) try writeAssistantMessageWithRawContent(jw, "\"\"");
}

/// Write the `{"type":"message","role":"assistant","content":…}` replay
/// placeholder; `content_json` is the raw JSON value for `content` (`"\"\""`
/// for the no-items fallback, `"[]"` for a bare image block).
fn writeAssistantMessageWithRawContent(jw: *std.json.Stringify, content_json: []const u8) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("message");
    try jw.objectField("role");
    try jw.write("assistant");
    try jw.objectField("content");
    try jw.beginWriteRaw();
    try jw.writer.writeAll(content_json);
    jw.endWriteRaw();
    try jw.endObject();
}

/// Write pre-serialized JSON bytes as one complete value inside the builder's
/// current container (replayed reasoning items carry stored item JSON).
fn writeRawJson(jw: *std.json.Stringify, json: []const u8) !void {
    try jw.beginWriteRaw();
    try jw.writer.writeAll(json);
    jw.endWriteRaw();
}

fn textBlock(block: ai.ContentBlock) ?ai.TextBlock {
    return switch (block) {
        .text, .refusal => |text| text,
        else => null,
    };
}

fn writeTextItem(jw: *std.json.Stringify, gpa: std.mem.Allocator, blocks: []const ai.ContentBlock) !void {
    const text = textBlock(blocks[0]).?;
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("message");
    try jw.objectField("role");
    try jw.write("assistant");
    try jw.objectField("status");
    try jw.write("completed");
    if (text.responses_item_id) |id| {
        try jw.objectField("id");
        try wire_json.writeStringValue(jw, gpa, id);
    }
    if (text.responses_phase) |phase| {
        try jw.objectField("phase");
        try wire_json.writeStringValue(jw, gpa, phase);
    }
    try jw.objectField("content");
    try jw.beginArray();
    for (blocks) |block| {
        const part = textBlock(block).?;
        // Message-added events create a text placeholder before the part kind is known.
        if (block == .text and part.text.len == 0 and blocks.len > 1) continue;
        if (block == .refusal) {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("refusal");
            try jw.objectField("refusal");
            try wire_json.writeStringValue(jw, gpa, part.text);
            try jw.endObject();
        } else {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("output_text");
            try jw.objectField("text");
            try wire_json.writeStringValue(jw, gpa, part.text);
            try jw.objectField("annotations");
            try jw.beginArray();
            try jw.endArray();
            try jw.endObject();
        }
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeFunctionCall(jw: *std.json.Stringify, gpa: std.mem.Allocator, call: ai.ToolCall) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("function_call");
    try jw.objectField("call_id");
    try wire_json.writeStringValue(jw, gpa, call.call_id.slice());
    if (call.responses_item_id) |id| {
        try jw.objectField("id");
        try wire_json.writeStringValue(jw, gpa, id);
    }
    try jw.objectField("name");
    try wire_json.writeStringValue(jw, gpa, call.name);
    try jw.objectField("arguments");
    const args = tool_call_args.sanitizeToolArguments(call.arguments);
    try wire_json.writeStringValue(jw, gpa, args);
    try jw.endObject();
}

fn writeToolOutput(jw: *std.json.Stringify, gpa: std.mem.Allocator, message: ai.ChatMessage) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("function_call_output");
    try jw.objectField("call_id");
    try wire_json.writeStringValue(jw, gpa, message.tool.call_id.slice());
    try jw.objectField("output");
    try wire_json.writeStringValue(jw, gpa, message.text());
    try jw.endObject();
}

fn writeInputContent(jw: *std.json.Stringify, gpa: std.mem.Allocator, blocks: []const ai.ContentBlock) !void {
    try jw.beginArray();
    for (blocks) |block| {
        switch (block) {
            .text, .refusal => |text| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("input_text");
                try jw.objectField("text");
                try wire_json.writeStringValue(jw, gpa, text.text);
                try jw.endObject();
            },
            .image => |image| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("input_image");
                try jw.objectField("detail");
                try jw.write("auto");
                try jw.objectField("image_url");
                var data_uri: std.Io.Writer.Allocating = .init(gpa);
                defer data_uri.deinit();
                try data_uri.writer.writeAll("data:");
                try data_uri.writer.writeAll(image.mime_type);
                try data_uri.writer.writeAll(";base64,");
                try data_uri.writer.writeAll(image.data_base64);
                try wire_json.writeStringValue(jw, gpa, data_uri.written());
                try jw.endObject();
            },
            .reasoning, .tool_call => {},
        }
    }
    try jw.endArray();
}

test "assistant replay groups refusal and prose by item identity" {
    const gpa = std.testing.allocator;
    var blocks = [_]ai.ContentBlock{
        .{ .refusal = .{ .text = @constCast("Declined"), .responses_item_id = @constCast("msg_refusal"), .responses_phase = @constCast("final_answer") } },
        .{ .text = .{ .text = @constCast(""), .responses_item_id = @constCast("msg_refusal") } },
        .{ .text = .{ .text = @constCast("Separate"), .responses_item_id = @constCast("msg_other") } },
    };
    for ([_][]const u8{ "", "Alternative" }) |prose| {
        blocks[1].text.text = @constCast(prose);
        var payload: std.Io.Writer.Allocating = .init(gpa);
        defer payload.deinit();
        // `writeAssistantItems` emits one item per replay group — mirror the
        // production call site, which always runs inside the `input` array.
        var jw: std.json.Stringify = .{ .writer = &payload.writer, .options = .{} };
        try jw.beginArray();
        try writeAssistantItems(&jw, .{ .assistant = .{ .content = &blocks } }, gpa, "test", false);
        try jw.endArray();
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, payload.written(), .{});
        defer parsed.deinit();
        const items = parsed.value.array.items;
        try std.testing.expectEqual(@as(usize, 2), items.len);
        try std.testing.expectEqualStrings("msg_refusal", items[0].object.get("id").?.string);
        try std.testing.expectEqualStrings("final_answer", items[0].object.get("phase").?.string);
        const parts = items[0].object.get("content").?.array.items;
        try std.testing.expectEqual(@as(usize, if (prose.len == 0) 1 else 2), parts.len);
        try std.testing.expectEqualStrings("refusal", parts[0].object.get("type").?.string);
        try std.testing.expectEqualStrings("Declined", parts[0].object.get("refusal").?.string);
        try std.testing.expect(parts[0].object.get("annotations") == null);
        if (prose.len > 0) {
            try std.testing.expectEqualStrings("output_text", parts[1].object.get("type").?.string);
            try std.testing.expectEqualStrings(prose, parts[1].object.get("text").?.string);
        }
        try std.testing.expectEqualStrings("msg_other", items[1].object.get("id").?.string);
    }
}

test "writeRequestPayload preserves refusal content type" {
    const gpa = std.testing.allocator;
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .refusal = .{ .text = try gpa.dupe(u8, "Declined") } };
    var message = ai.ChatMessage{ .assistant = .{ .content = blocks } };
    defer message.deinit(gpa);
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{.{ .borrowed = &message }}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"refusal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"refusal\":\"Declined\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"output_text\"") == null);
}
test "writeRequestPayload puts system prompt in instructions for standard mode" {
    const gpa = std.testing.allocator;
    const empty_content = try gpa.alloc(ai.ContentBlock, 0);
    defer gpa.free(empty_content);
    const system_message: ai.ChatMessage = .{ .system = .{ .content = empty_content } };
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "session-abc",
        .system_prompt = "You are Zay.",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{.{ .borrowed = &system_message }}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"You are Zay.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt_cache_key\":\"session-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "verbosity") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "parallel_tool_calls") == null);
}

test "writeRequestPayload keeps configured verbosity hint" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-5.5",
        .session_id = "session-xyz",
        .system_prompt = "You are Zay.",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{ .text_verbosity = "low", .parallel_tool_calls = true }, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"You are Zay.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt_cache_key\":\"session-xyz\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"verbosity\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parallel_tool_calls\":true") != null);
}

test "writeRequestPayload emits reasoning effort none" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "",
        .reasoning = .{ .effort = .none, .summary = null },
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"none\"}") != null);
}

test "writeRequestPayload omits reasoning effort when set to default" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "",
        .reasoning = .{ .effort = .default, .summary = null },
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\"") == null);
}

test "writeRequestPayload emits reasoning summary even with default effort (Responses API)" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "",
        .reasoning = .{ .effort = .default, .summary = .detailed },
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"summary\":\"detailed\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "effort") == null);
}

test "writeRequestPayload omits prompt_cache_key when no session id is set" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "You are Zay.",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"You are Zay.\"") != null);
}

test "writeRequestPayload omits prompt_cache_key when disable_prompt_cache is true" {
    // C1: this site is NOT dialect-gated (it emits whenever session_id is
    // non-empty), so the flag is the sole gate. When set, prompt_cache_key
    // must be suppressed even with a non-empty session id.
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "session-abc",
        .system_prompt = "You are Zay.",
        .reasoning = null,
        .disable_prompt_cache = true,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_key") == null);
}

test "writeRequestPayload serializes tool call ids as strings, not objects" {
    const gpa = std.testing.allocator;

    const assistant_blocks = try gpa.alloc(ai.ContentBlock, 1);
    assistant_blocks[0] = .{ .tool_call = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_xyz789") },
        .name = try gpa.dupe(u8, "read"),
        .arguments = try gpa.dupe(u8, "{\"path\":\"main.zig\"}"),
    } };
    const assistant_msg: ai.ChatMessage = .{ .assistant = .{ .content = assistant_blocks } };

    const tool_blocks = try gpa.alloc(ai.ContentBlock, 1);
    tool_blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "content") } };
    const tool_msg: ai.ChatMessage = .{ .tool = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_xyz789") },
        .content = tool_blocks,
    } };

    var messages = [_]ai.ChatMessage{ assistant_msg, tool_msg };
    defer for (&messages) |*m| m.deinit(gpa);
    const views = [_]ai.MessageView{
        .{ .borrowed = &messages[0] },
        .{ .borrowed = &messages[1] },
    };

    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &views, "[{\"type\":\"function\"}]");
    const body = payload.written();

    // function_call call_id must be a string
    try std.testing.expect(std.mem.indexOf(u8, body, "\"call_id\":\"call_xyz789\"") != null);
    // function_call_output call_id must be a string
    try std.testing.expect(std.mem.indexOf(u8, body, "\"call_id\":\"call_xyz789\"") != null);
    // Negative: must NOT serialize CallId as an object
    try std.testing.expect(std.mem.indexOf(u8, body, "\"call_id\":{\"value\":") == null);
}

test "writeRequestPayload keeps invalid tool output as a JSON string" {
    const gpa = std.testing.allocator;
    const tool_blocks = try gpa.alloc(ai.ContentBlock, 1);
    tool_blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "ok\xff") } };
    var tool_message: ai.ChatMessage = .{ .tool = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_invalid_utf8") },
        .content = tool_blocks,
    } };
    defer tool_message.deinit(gpa);

    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .reasoning = null,
    };
    const views = [_]ai.MessageView{.{ .borrowed = &tool_message }};
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &views, "[]");

    try std.testing.expect(std.mem.indexOf(u8, payload.written(), "\"output\":[") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload.written(), "\"output\":\"ok\xef\xbf\xbd\"") != null);
}

test "writeRequestPayload clips xhigh reasoning effort for minimal dialect (Responses API)" {
    // Mirrors the chat-completions clipping: Ollama's /v1/chat/completions
    // rejects xhigh/minimal with HTTP 400. The /v1/responses endpoint
    // silently ignores unknown reasoning fields (Go decoder), but clipping
    // keeps the two wire clients consistent and is forward-safe if Ollama
    // adds validation later.
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "ollama-model",
        .reasoning = .{ .effort = .xhigh },
        .wire_dialect = .minimal,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\":\"max\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "xhigh") == null);
}

test "writeRequestPayload preserves xhigh reasoning effort for openai dialect (Responses API)" {
    // The openai dialect must NOT clip — gpt-5 honours xhigh/max.
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-5",
        .reasoning = .{ .effort = .xhigh },
        .wire_dialect = .openai,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\":\"xhigh\"") != null);
}

test "openresponses tools json is an array" {
    const tools = @import("../tools.zig");
    const gpa = std.testing.allocator;
    const json = try tool_schema.buildAllToolsJson(gpa, tools.builtinRegistry(), &.{}, null, true, .responses);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\":true") != null);
}

test "openresponses strict schema includes nullable union types and top-level additionalProperties:false" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_mod.Tool{
        .{
            .name = "demo",
            .description = "Demo tool",
            .schema = .{
                .properties = &.{
                    .{ .name = "id", .kind = .string, .description = "ID", .required = true, .nullable = false },
                    .{ .name = "tag", .kind = .string, .description = "Tag", .required = false, .nullable = true },
                },
            },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, true, .responses);
    defer gpa.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tag\":{\"type\":[\"string\",\"null\"]") != null);
    // Required array includes ALL properties for strict mode compliance.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"id\",\"tag\"]") != null);
}

test "openresponses omits strict mode and filters required when strict is false (gateway compatibility)" {
    // Regression for function-calling breaking on gateways: strict
    // structured-outputs is OpenAI-only, so it must be omitted when the
    // client is built with strict=false. `required` then lists only the
    // genuinely-required properties.
    const gpa = std.testing.allocator;
    const tools = [_]tools_mod.Tool{
        .{
            .name = "demo",
            .description = "Demo tool",
            .schema = .{
                .properties = &.{
                    .{ .name = "id", .kind = .string, .description = "ID", .required = true, .nullable = false },
                    .{ .name = "tag", .kind = .string, .description = "Tag", .required = false, .nullable = true },
                },
            },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, false, .responses);
    defer gpa.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"id\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tag\":{\"type\":[\"string\",\"null\"]") != null);
}

test "writeRequestPayload handles empty messages and empty tools array" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "test-model",
        .session_id = "",
        .system_prompt = "",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[]") != null);
    // tool_choice accompanies a non-empty tools array only — several
    // Responses endpoints reject the pair when the array is empty (#441).
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\"") == null);
}

test "writeRequestPayload emits tool_choice auto alongside a non-empty tools array" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "test-model",
        .session_id = "",
        .system_prompt = "",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    const tools_json = "[{\"type\":\"function\",\"name\":\"bash\"}]";
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, tools_json);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\"") != null);
}

test "writeRequestPayload skips system messages in history when config system_prompt is set" {
    const gpa = std.testing.allocator;
    const sys_blocks = try gpa.alloc(ai.ContentBlock, 0);
    defer gpa.free(sys_blocks);
    const sys_msg: ai.ChatMessage = .{ .system = .{ .content = sys_blocks } };

    const views = [_]ai.MessageView{
        .{ .borrowed = &sys_msg },
    };
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "Global system instruction",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writeRequestPayload(&payload.writer, gpa, config, .{}, &views, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"Global system instruction\"") != null);
    // History system message is skipped from input array
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":[]") != null);
}

test "writeRequestPayload sanitizes empty tool call arguments to empty object" {
    const gpa = std.testing.allocator;
    const assistant_blocks = try gpa.alloc(ai.ContentBlock, 1);
    assistant_blocks[0] = .{ .tool_call = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_empty_args") },
        .name = try gpa.dupe(u8, "test_tool"),
        .arguments = try gpa.dupe(u8, ""),
    } };
    const assistant_msg: ai.ChatMessage = .{ .assistant = .{ .content = assistant_blocks } };
    var messages = [_]ai.ChatMessage{assistant_msg};
    defer for (&messages) |*m| m.deinit(gpa);

    const views = [_]ai.MessageView{
        .{ .borrowed = &messages[0] },
    };
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writeRequestPayload(&payload.writer, gpa, config, .{}, &views, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"arguments\":\"{}\"") != null);
}

test "assistant classification replays commentary and final answer phases as message text" {
    const gpa = std.testing.allocator;
    var blocks = [_]ai.ContentBlock{
        .{ .text = .{ .text = @constCast("Working"), .responses_phase = @constCast("commentary") } },
        .{ .text = .{ .text = @constCast("Done"), .responses_phase = @constCast("final_answer") } },
    };
    const message: ai.ChatMessage = .{ .assistant = .{ .content = &blocks } };
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    var jw: std.json.Stringify = .{ .writer = &buffer.writer, .options = .{} };
    try jw.beginArray();
    try writeAssistantItems(&jw, message, gpa, "test", false);
    try jw.endArray();
    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "\"phase\":\"commentary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "\"phase\":\"final_answer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.written(), "\"type\":\"reasoning\"") == null);
}

test "writeRequestPayload clips minimal reasoning effort for minimal dialect" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "ollama-model",
        .reasoning = .{ .effort = .minimal },
        .wire_dialect = .minimal,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\":\"low\"") != null);
}

test "writeRequestPayload omits encrypted reasoning include when disabled" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-5.6-sol",
        .reasoning = .{ .effort = .medium },
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writeRequestPayload(&payload.writer, gpa, config, .{ .include_encrypted_reasoning = false }, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "encrypted_content") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"include\"") == null);
    // The reasoning object itself must still be emitted for effort.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{") != null);
}

test "writeRequestPayload scrubs encrypted_content from replayed reasoning items" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-5.6-sol",
        .reasoning = null,
    };

    const reasoning_blocks = try gpa.alloc(ai.ContentBlock, 1);
    reasoning_blocks[0] = .{ .reasoning = .{
        .text = try gpa.dupe(u8, "**Planning**"),
        .responses_item_json = try gpa.dupe(u8, "{\"id\":\"rs_x\",\"type\":\"reasoning\",\"content\":[],\"encrypted_content\":\"gAAAAABsecret\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"**Planning**\"}]}"),
    } };

    var message = ai.ChatMessage{ .assistant = .{ .content = reasoning_blocks } };
    // Owns the blocks array and every duped field — single teardown path.
    defer message.deinit(gpa);
    const views = [_]ai.MessageView{.{ .borrowed = &message }};

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writeRequestPayload(&payload.writer, gpa, config, .{
        .include_encrypted_reasoning = false,
        .scrub_encrypted_reasoning = true,
    }, &views, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "gAAAAABsecret") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"rs_x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "**Planning**") != null);

    payload.clearRetainingCapacity();
    try writeRequestPayload(&payload.writer, gpa, config, .{ .include_encrypted_reasoning = true }, &views, "[]");
    try std.testing.expect(std.mem.indexOf(u8, payload.written(), "gAAAAABsecret") != null);
}

test "scrubEncryptedContent passes through malformed json as null" {
    const gpa = std.testing.allocator;
    const clean = scrubEncryptedContent(gpa, "{not json at all");
    try std.testing.expect(clean == null);
}

test "writeRequestPayload escapes an input image data URI with special characters (Responses API)" {
    // Regression (Responses parity): image.mime_type / image.data_base64 used to
    // be written verbatim into a JSON string. A value containing a quote (or
    // backslash / control char) would terminate the string early and produce
    // invalid JSON. The data URI is now built in a buffer and emitted through
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

    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &views, "[]");
    const body = payload.written();

    // The data URI prefix is present and well-formed.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"image_url\":\"data:image/") != null);
    // A raw (unescaped) quote right after image/ must be gone.
    try std.testing.expect(std.mem.indexOf(u8, body, "image/\"") == null);
    // The JSON-escaped quote (backslash-quote) must be present instead.
    try std.testing.expect(std.mem.indexOf(u8, body, "image/\\\"") != null);
}

test "writeRequestPayload repairs invalid UTF-8 in text verbosity" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writeRequestPayload(
        &payload.writer,
        gpa,
        config,
        .{ .text_verbosity = "low\xff" },
        &.{},
        "[]",
    );

    try std.testing.expect(std.mem.indexOf(u8, payload.written(), "\"verbosity\":\"low\xef\xbf\xbd\"") != null);
}
