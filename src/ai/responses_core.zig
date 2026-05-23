const std = @import("std");
const logger = @import("logger");
const ai = @import("../ai.zig");
const tools_common = @import("../tools/common.zig");

const redirect_buffer_bytes: u32 = 8192;
const transfer_buffer_bytes: u32 = 4096;
const body_buffer_bytes: u32 = 4096;
const stream_chunk_count_max: u32 = 100_000;
const stream_bytes_max: u32 = 8 * 1024 * 1024;

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: ai.Config,
    url: []u8,
    authorization: []u8,
    tools_json: []u8,
    http_client: std.http.Client,
    call_seq: u64 = 0,

    pub fn init(target: *Client, gpa: std.mem.Allocator, io: std.Io, config: ai.Config) !void {
        std.debug.assert(config.base_url.len > 0);
        std.debug.assert(config.model.len > 0);
        const url = try responsesUrl(gpa, config);
        errdefer gpa.free(url);
        const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{config.api_key});
        errdefer gpa.free(authorization);
        var owned_config = config;
        owned_config.base_url = "";
        owned_config.api_key = "";
        owned_config.model = try gpa.dupe(u8, config.model);
        errdefer gpa.free(owned_config.model);
        owned_config.account_id = try gpa.dupe(u8, config.account_id);
        errdefer gpa.free(owned_config.account_id);
        owned_config.session_id = try gpa.dupe(u8, config.session_id);
        errdefer gpa.free(owned_config.session_id);
        owned_config.system_prompt = try gpa.dupe(u8, config.system_prompt);
        errdefer gpa.free(owned_config.system_prompt);
        const tools_json = try buildToolsJson(gpa, config.tools);
        errdefer gpa.free(tools_json);
        target.* = .{
            .gpa = gpa,
            .io = io,
            .config = owned_config,
            .url = url,
            .authorization = authorization,
            .tools_json = tools_json,
            .http_client = .{ .allocator = gpa, .io = io },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
        self.gpa.free(self.config.model);
        self.gpa.free(self.config.account_id);
        self.gpa.free(self.config.session_id);
        self.gpa.free(self.config.system_prompt);
        self.gpa.free(self.tools_json);
        self.gpa.free(self.authorization);
        self.gpa.free(self.url);
        self.* = undefined;
    }

    pub fn prompt(self: *Client, messages: []const ai.ChatMessage, observer: ai.StreamObserver) !ai.Turn {
        const extra_headers = [_]std.http.Header{
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "chatgpt-account-id", .value = self.config.account_id },
            .{ .name = "originator", .value = "nova" },
            .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
            .{ .name = "session_id", .value = self.config.session_id },
            .{ .name = "x-client-request-id", .value = self.config.session_id },
        };
        var req = if (self.config.responses_mode == .codex) blk: {
            break :blk try self.http_client.request(.POST, try std.Uri.parse(self.url), .{
                .headers = .{
                    .authorization = .{ .override = self.authorization },
                    .content_type = .{ .override = "application/json" },
                    .user_agent = .{ .override = "nova" },
                },
                .extra_headers = &extra_headers,
            });
        } else try self.http_client.request(.POST, try std.Uri.parse(self.url), .{ .headers = .{
            .authorization = .{ .override = self.authorization },
            .content_type = .{ .override = "application/json" },
        } });
        defer req.deinit();

        var payload: std.Io.Writer.Allocating = .init(self.gpa);
        defer payload.deinit();
        try writeRequestPayload(&payload.writer, self.config, messages, self.tools_json);
        logger.log("responses.request POST {s} responses_mode={s} body={s}", .{ self.url, @tagName(self.config.responses_mode), logBytes(payload.written()) });
        req.transfer_encoding = .chunked;
        var body_buffer: [body_buffer_bytes]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&body_buffer);
        try body_writer.writer.writeAll(payload.written());
        try body_writer.end();
        try req.connection.?.flush();

        var redirect_buffer: [redirect_buffer_bytes]u8 = undefined;
        var http_response = try req.receiveHead(&redirect_buffer);
        const status_code: u16 = @intFromEnum(http_response.head.status);
        logger.log("responses.response.head status={d} responses_mode={s}", .{ status_code, @tagName(self.config.responses_mode) });
        if (status_code >= 400) {
            var error_buffer: [transfer_buffer_bytes]u8 = undefined;
            const error_reader = http_response.reader(&error_buffer);
            var error_body: std.Io.Writer.Allocating = .init(self.gpa);
            defer error_body.deinit();
            _ = error_reader.streamRemaining(&error_body.writer) catch 0;
            logger.log("responses.response.error status={d} body={s}", .{ status_code, logBytes(error_body.written()) });
            if (status_code >= 500) return error.HttpServerError;
            return error.HttpClientError;
        }
        if (status_code < 200 or status_code >= 300) return error.HttpUnexpectedStatus;

        var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
        const reader = http_response.reader(&transfer_buffer);
        return try readStream(self.gpa, reader, observer, &self.call_seq);
    }
};

fn responsesUrl(gpa: std.mem.Allocator, config: ai.Config) ![]u8 {
    const base = std.mem.trimEnd(u8, config.base_url, "/");
    if (config.responses_mode == .codex) {
        if (std.mem.endsWith(u8, base, "/codex/responses")) return try gpa.dupe(u8, base);
        if (std.mem.endsWith(u8, base, "/codex")) return try std.fmt.allocPrint(gpa, "{s}/responses", .{base});
        return try std.fmt.allocPrint(gpa, "{s}/codex/responses", .{base});
    }
    return try std.fmt.allocPrint(gpa, "{s}/v1/responses", .{base});
}

fn buildToolsJson(gpa: std.mem.Allocator, tools: []const tools_common.Tool) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeByte('[');
    for (tools, 0..) |tool, index| {
        if (index > 0) try aw.writer.writeByte(',');
        try writeToolDefinition(gpa, &aw.writer, tool);
    }
    try aw.writer.writeByte(']');
    return aw.toOwnedSlice();
}

fn writeToolDefinition(gpa: std.mem.Allocator, writer: *std.Io.Writer, tool: tools_common.Tool) !void {
    const description = try std.mem.replaceOwned(u8, gpa, tool.description, "{{hsep}}", "~");
    defer gpa.free(description);
    try writer.writeAll("{\"type\":\"function\",\"name\":");
    try std.json.Stringify.value(tool.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(description, .{}, writer);
    try writer.writeAll(",\"parameters\":");
    try writeParameters(writer, tool);
    try writer.writeAll(",\"strict\":false}");
}

fn writeParameters(writer: *std.Io.Writer, tool: tools_common.Tool) !void {
    try writer.writeAll("{\"type\":\"object\",\"properties\":{");
    for (tool.schema.properties, 0..) |prop, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(prop.name, .{}, writer);
        try writer.writeAll(":{\"type\":");
        const kind: []const u8 = switch (prop.kind) {
            .string => "string",
            .integer => "integer",
            .object => "object",
        };
        try std.json.Stringify.value(kind, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(prop.description, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("},\"required\":[");
    var required_count: u32 = 0;
    for (tool.schema.properties) |prop| {
        if (!prop.required) continue;
        if (required_count > 0) try writer.writeByte(',');
        try std.json.Stringify.value(prop.name, .{}, writer);
        required_count += 1;
    }
    try writer.writeAll("]}");
}

pub fn writeRequestPayload(out: *std.Io.Writer, config: ai.Config, messages: []const ai.ChatMessage, tools_json: []const u8) !void {
    try out.writeAll("{\"model\":");
    try std.json.Stringify.value(config.model, .{}, out);
    try out.writeAll(",\"input\":[");
    var written: u32 = 0;
    for (messages) |message| {
        if (config.responses_mode == .codex and message.role == .system) continue;
        if (written > 0) try out.writeByte(',');
        try writeInputMessage(out, message);
        written += 1;
    }
    try out.writeAll("],\"stream\":true,\"store\":false,\"tools\":");
    try out.writeAll(tools_json);
    try out.writeAll(",\"tool_choice\":\"auto\"");
    if (config.responses_mode == .codex) {
        try out.writeAll(",\"instructions\":");
        try std.json.Stringify.value(config.system_prompt, .{}, out);
        try out.writeAll(",\"text\":{\"verbosity\":\"low\"},\"parallel_tool_calls\":true");
        if (config.session_id.len > 0) {
            try out.writeAll(",\"prompt_cache_key\":");
            try std.json.Stringify.value(config.session_id, .{}, out);
        }
    }
    if (config.reasoning) |value| {
        try out.writeAll(",\"reasoning\":{");
        var wrote = false;
        if (value.effort) |effort| {
            try out.writeAll("\"effort\":");
            try std.json.Stringify.value(effort.label(), .{}, out);
            wrote = true;
        }
        if (value.summary) |summary| {
            if (wrote) try out.writeByte(',');
            try out.writeAll("\"summary\":");
            try std.json.Stringify.value(summary.label(), .{}, out);
        }
        try out.writeAll("},\"include\":[\"reasoning.encrypted_content\"]");
    }
    try out.writeByte('}');
}

fn writeInputMessage(out: *std.Io.Writer, message: ai.ChatMessage) !void {
    if (message.role == .assistant) return writeAssistantItems(out, message);
    if (message.role == .tool) return writeToolOutput(out, message);
    try out.writeAll("{\"type\":\"message\",\"role\":");
    try std.json.Stringify.value(message.role.label(), .{}, out);
    try out.writeAll(",\"content\":");
    try writeInputContent(out, message.content);
    try out.writeByte('}');
}

fn writeAssistantItems(out: *std.Io.Writer, message: ai.ChatMessage) !void {
    var first = true;
    for (message.content) |block| {
        if (!first) try out.writeByte(',');
        first = false;
        switch (block) {
            .text => |text| {
                try out.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\"");
                if (text.responses_item_id) |id| {
                    try out.writeAll(",\"id\":");
                    try std.json.Stringify.value(id, .{}, out);
                }
                try out.writeAll(",\"content\":[{\"type\":\"output_text\",\"text\":");
                try std.json.Stringify.value(text.text, .{}, out);
                try out.writeAll(",\"annotations\":[]}]}");
            },
            .reasoning => |reasoning| {
                if (reasoning.responses_item_json) |json| {
                    try out.writeAll(json);
                } else {
                    try out.writeAll("{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":");
                    try std.json.Stringify.value(reasoning.text, .{}, out);
                    try out.writeAll("}]}");
                }
            },
            .tool_call => |call| try writeFunctionCall(out, call),
            .image => try out.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}"),
        }
    }
    if (first) try out.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":\"\"}");
}

fn writeFunctionCall(out: *std.Io.Writer, call: ai.ToolCall) !void {
    try out.writeAll("{\"type\":\"function_call\",\"call_id\":");
    try std.json.Stringify.value(call.call_id, .{}, out);
    if (call.responses_item_id) |id| {
        try out.writeAll(",\"id\":");
        try std.json.Stringify.value(id, .{}, out);
    }
    try out.writeAll(",\"name\":");
    try std.json.Stringify.value(call.name, .{}, out);
    try out.writeAll(",\"arguments\":");
    try std.json.Stringify.value(call.arguments, .{}, out);
    try out.writeByte('}');
}

fn writeToolOutput(out: *std.Io.Writer, message: ai.ChatMessage) !void {
    try out.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
    try std.json.Stringify.value(message.call_id orelse "", .{}, out);
    try out.writeAll(",\"output\":");
    try std.json.Stringify.value(message.text(), .{}, out);
    try out.writeByte('}');
}

fn writeInputContent(out: *std.Io.Writer, blocks: []const ai.ContentBlock) !void {
    try out.writeByte('[');
    var count: u32 = 0;
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                if (count > 0) try out.writeByte(',');
                try out.writeAll("{\"type\":\"input_text\",\"text\":");
                try std.json.Stringify.value(text.text, .{}, out);
                try out.writeByte('}');
                count += 1;
            },
            .image => |image| {
                if (count > 0) try out.writeByte(',');
                try out.writeAll("{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":");
                try out.writeByte('"');
                try out.writeAll("data:");
                try out.writeAll(image.mime_type);
                try out.writeAll(";base64,");
                try out.writeAll(image.data_base64);
                try out.writeByte('"');
                try out.writeByte('}');
                count += 1;
            },
            .reasoning, .tool_call => {},
        }
    }
    try out.writeByte(']');
}

const ToolBuilder = struct {
    call_id: std.ArrayList(u8) = .empty,
    item_id: std.ArrayList(u8) = .empty,
    output_index: ?u32 = null,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolBuilder, gpa: std.mem.Allocator) void {
        self.call_id.deinit(gpa);
        self.item_id.deinit(gpa);
        self.name.deinit(gpa);
        self.arguments.deinit(gpa);
        self.* = undefined;
    }
};

fn readStream(gpa: std.mem.Allocator, reader: *std.Io.Reader, observer: ai.StreamObserver, call_seq: *u64) !ai.Turn {
    var state: StreamState = .{};
    defer state.deinit(gpa);
    errdefer state.deinitBlocks(gpa);
    var chunk_count: u32 = 0;
    var bytes_read: usize = 0;
    while (try readStreamLine(gpa, reader)) |line| {
        defer gpa.free(line);
        chunk_count += 1;
        bytes_read += line.len;
        if (chunk_count > stream_chunk_count_max) return error.StreamTooManyChunks;
        if (bytes_read > stream_bytes_max) return error.StreamTooLarge;
        const trimmed = std.mem.trim(u8, line, " \r");
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const data = std.mem.trim(u8, trimmed["data:".len..], " ");
        logger.log("responses.response.sse data={s}", .{logBytes(data)});
        if (std.mem.eql(u8, data, "[DONE]")) break;
        try state.processJson(gpa, data, observer, call_seq);
    }
    return try state.finish(gpa, call_seq);
}

pub const StreamState = struct {
    blocks: std.ArrayList(ai.ContentBlock) = .empty,
    tools: std.ArrayList(ToolBuilder) = .empty,
    completed: bool = false,

    pub fn deinit(self: *StreamState, gpa: std.mem.Allocator) void {
        for (self.tools.items) |*tool| tool.deinit(gpa);
        self.tools.deinit(gpa);
    }

    pub fn deinitBlocks(self: *StreamState, gpa: std.mem.Allocator) void {
        for (self.blocks.items) |*block| block.deinit(gpa);
        self.blocks.deinit(gpa);
    }

    pub fn processJson(self: *StreamState, gpa: std.mem.Allocator, data: []const u8, observer: ai.StreamObserver, call_seq: *u64) !void {
        try processEvent(gpa, data, &self.blocks, &self.tools, observer, call_seq, &self.completed);
    }

    pub fn finish(self: *StreamState, gpa: std.mem.Allocator, call_seq: *u64) !ai.Turn {
        for (self.tools.items) |*tool| {
            if (tool.name.items.len == 0) continue;
            const call_id = if (tool.call_id.items.len > 0) try tool.call_id.toOwnedSlice(gpa) else try std.fmt.allocPrint(gpa, "call_{d}", .{call_seq.*});
            if (tool.call_id.items.len == 0) call_seq.* += 1;
            errdefer gpa.free(call_id);
            const item_id = if (tool.item_id.items.len > 0) try tool.item_id.toOwnedSlice(gpa) else null;
            errdefer if (item_id) |id| gpa.free(id);
            try self.blocks.append(gpa, .{ .tool_call = .{
                .call_id = call_id,
                .responses_item_id = item_id,
                .name = try tool.name.toOwnedSlice(gpa),
                .arguments = try tool.arguments.toOwnedSlice(gpa),
            } });
        }
        const content = try self.blocks.toOwnedSlice(gpa);
        self.blocks = .empty;
        return .{ .assistant = .{ .role = .assistant, .content = content } };
    }
};

fn processEvent(gpa: std.mem.Allocator, data: []const u8, blocks: *std.ArrayList(ai.ContentBlock), tools: *std.ArrayList(ToolBuilder), observer: ai.StreamObserver, call_seq: *u64, completed: *bool) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const type_value = parsed.value.object.get("type") orelse return;
    if (type_value != .string) return;
    const event_type = type_value.string;
    if (std.mem.eql(u8, event_type, "error")) return error.ProviderError;
    if (std.mem.eql(u8, event_type, "response.failed")) return error.ProviderError;
    if (std.mem.eql(u8, event_type, "response.completed")) {
        completed.* = true;
        return;
    }
    if (std.mem.eql(u8, event_type, "response.output_item.added")) try onItemAdded(gpa, parsed.value, blocks, tools, call_seq);
    if (std.mem.eql(u8, event_type, "response.output_text.delta")) try onTextDelta(gpa, parsed.value, blocks, observer);
    if (std.mem.eql(u8, event_type, "response.reasoning_text.delta")) try onReasoningDelta(gpa, parsed.value, blocks, observer);
    if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) try onArgumentsDelta(gpa, parsed.value, tools, observer);
    if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) try onArgumentsDone(gpa, parsed.value, tools, observer);
    if (std.mem.eql(u8, event_type, "response.output_item.done")) try onItemDone(gpa, parsed.value, blocks, tools);
}

fn onItemAdded(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), tools: *std.ArrayList(ToolBuilder), call_seq: *u64) !void {
    const item = value.object.get("item") orelse return;
    if (item != .object) return;
    const kind = item.object.get("type") orelse return;
    if (kind != .string) return;
    if (std.mem.eql(u8, kind.string, "message")) {
        try blocks.append(gpa, .{ .text = .{ .text = try gpa.alloc(u8, 0), .responses_item_id = try optionalString(gpa, item, "id") } });
    } else if (std.mem.eql(u8, kind.string, "reasoning")) {
        const raw = try std.json.Stringify.valueAlloc(gpa, item, .{});
        try blocks.append(gpa, .{ .reasoning = .{ .text = try gpa.alloc(u8, 0), .responses_item_json = raw } });
    } else if (std.mem.eql(u8, kind.string, "function_call")) {
        var builder: ToolBuilder = .{};
        errdefer builder.deinit(gpa);
        builder.output_index = optionalU32(value, "output_index");
        if (try optionalString(gpa, item, "call_id")) |id| {
            defer gpa.free(id);
            try builder.call_id.appendSlice(gpa, id);
        }
        if (try optionalString(gpa, item, "id")) |id| {
            defer gpa.free(id);
            try builder.item_id.appendSlice(gpa, id);
        }
        if (try optionalString(gpa, item, "name")) |name| {
            defer gpa.free(name);
            try builder.name.appendSlice(gpa, name);
        }
        if (try optionalString(gpa, item, "arguments")) |args| {
            defer gpa.free(args);
            try builder.arguments.appendSlice(gpa, args);
        }
        if (builder.call_id.items.len == 0) {
            const minted = try std.fmt.allocPrint(gpa, "call_{d}", .{call_seq.*});
            defer gpa.free(minted);
            try builder.call_id.appendSlice(gpa, minted);
            call_seq.* += 1;
        }
        try tools.append(gpa, builder);
    }
}

fn onItemDone(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), tools: *std.ArrayList(ToolBuilder)) !void {
    const item = value.object.get("item") orelse return;
    if (item != .object) return;
    const kind = item.object.get("type") orelse return;
    if (kind != .string) return;
    if (std.mem.eql(u8, kind.string, "message")) {
        const text = outputTextFromItem(item) orelse return;
        var index = blocks.items.len;
        while (index > 0) {
            index -= 1;
            if (blocks.items[index] != .text) continue;
            gpa.free(blocks.items[index].text.text);
            blocks.items[index].text.text = try gpa.dupe(u8, text);
            return;
        }
    }
    if (std.mem.eql(u8, kind.string, "reasoning")) {
        const raw = try std.json.Stringify.valueAlloc(gpa, item, .{});
        var index = blocks.items.len;
        while (index > 0) {
            index -= 1;
            if (blocks.items[index] != .reasoning) continue;
            if (blocks.items[index].reasoning.responses_item_json) |old| gpa.free(old);
            blocks.items[index].reasoning.responses_item_json = raw;
            return;
        }
        gpa.free(raw);
    }
    if (std.mem.eql(u8, kind.string, "function_call")) {
        const call_id = stringField(item, "call_id") orelse return;
        for (tools.items) |*tool| {
            if (!std.mem.eql(u8, tool.call_id.items, call_id)) continue;
            if (stringField(item, "name")) |name| {
                tool.name.clearRetainingCapacity();
                try tool.name.appendSlice(gpa, name);
            }
            if (stringField(item, "arguments")) |arguments| {
                tool.arguments.clearRetainingCapacity();
                try tool.arguments.appendSlice(gpa, arguments);
            }
            return;
        }
    }
}

fn outputTextFromItem(item: std.json.Value) ?[]const u8 {
    const content = item.object.get("content") orelse return null;
    if (content != .array) return null;
    for (content.array.items) |part| {
        if (part != .object) continue;
        const kind = part.object.get("type") orelse continue;
        if (kind != .string) continue;
        if (!std.mem.eql(u8, kind.string, "output_text")) continue;
        const text = part.object.get("text") orelse return null;
        if (text != .string) return null;
        return text.string;
    }
    return null;
}

fn onTextDelta(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), observer: ai.StreamObserver) !void {
    const delta = stringField(value, "delta") orelse return;
    var index = blocks.items.len;
    while (index > 0) {
        index -= 1;
        if (blocks.items[index] != .text) continue;
        const old = blocks.items[index].text.text;
        blocks.items[index].text.text = try appendOwned(gpa, old, delta);
        try observer.on_content(observer.ptr, delta);
        try observer.on_delta_end(observer.ptr);
        return;
    }
}

fn onReasoningDelta(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), observer: ai.StreamObserver) !void {
    const delta = stringField(value, "delta") orelse return;
    var index = blocks.items.len;
    while (index > 0) {
        index -= 1;
        if (blocks.items[index] != .reasoning) continue;
        const old = blocks.items[index].reasoning.text;
        blocks.items[index].reasoning.text = try appendOwned(gpa, old, delta);
        try observer.on_reasoning(observer.ptr, delta);
        try observer.on_delta_end(observer.ptr);
        return;
    }
}

fn onArgumentsDelta(gpa: std.mem.Allocator, value: std.json.Value, tools: *std.ArrayList(ToolBuilder), observer: ai.StreamObserver) !void {
    const delta = stringField(value, "delta") orelse return;
    const index = toolIndexForEvent(value, tools.items) orelse return;
    try tools.items[index].arguments.appendSlice(gpa, delta);
    try observer.on_tool_delta(observer.ptr, .{ .index = index, .name = tools.items[index].name.items, .arguments = tools.items[index].arguments.items });
    try observer.on_delta_end(observer.ptr);
}

fn onArgumentsDone(gpa: std.mem.Allocator, value: std.json.Value, tools: *std.ArrayList(ToolBuilder), observer: ai.StreamObserver) !void {
    const arguments = stringField(value, "arguments") orelse return;
    const index = toolIndexForEvent(value, tools.items) orelse return;
    tools.items[index].arguments.clearRetainingCapacity();
    try tools.items[index].arguments.appendSlice(gpa, arguments);
    try observer.on_tool_delta(observer.ptr, .{ .index = index, .name = tools.items[index].name.items, .arguments = tools.items[index].arguments.items });
    try observer.on_delta_end(observer.ptr);
}

fn toolIndexForEvent(value: std.json.Value, tools: []const ToolBuilder) ?u32 {
    if (tools.len == 0) return null;
    if (stringField(value, "item_id")) |item_id| {
        for (tools, 0..) |tool, index| {
            if (std.mem.eql(u8, tool.item_id.items, item_id)) return @intCast(index);
        }
    }
    if (stringField(value, "call_id")) |call_id| {
        for (tools, 0..) |tool, index| {
            if (std.mem.eql(u8, tool.call_id.items, call_id)) return @intCast(index);
        }
    }
    if (optionalU32(value, "output_index")) |output_index| {
        for (tools, 0..) |tool, index| {
            if (tool.output_index) |tool_output_index| {
                if (tool_output_index == output_index) return @intCast(index);
            }
        }
    }
    if (tools.len == 1) return 0;
    return null;
}

fn appendOwned(gpa: std.mem.Allocator, old: []u8, suffix: []const u8) ![]u8 {
    const next = try gpa.alloc(u8, old.len + suffix.len);
    @memcpy(next[0..old.len], old);
    @memcpy(next[old.len..], suffix);
    gpa.free(old);
    return next;
}

fn optionalString(gpa: std.mem.Allocator, value: std.json.Value, name: []const u8) !?[]u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return null;
    return try gpa.dupe(u8, field.string);
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn optionalU32(value: std.json.Value, name: []const u8) ?u32 {
    const field = value.object.get(name) orelse return null;
    if (field != .integer) return null;
    if (field.integer < 0) return null;
    if (field.integer > std.math.maxInt(u32)) return null;
    return @intCast(field.integer);
}

fn readStreamLine(gpa: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var line_writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer line_writer.deinit();
    _ = reader.streamDelimiterEnding(&line_writer.writer, '\n') catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => return error.OutOfMemory,
    };
    const delimiter = reader.take(1) catch |err| switch (err) {
        error.EndOfStream => {
            if (line_writer.written().len == 0) return null;
            return try line_writer.toOwnedSlice();
        },
        else => |e| return e,
    };
    std.debug.assert(delimiter.len == 1);
    std.debug.assert(delimiter[0] == '\n');
    return try line_writer.toOwnedSlice();
}

fn logBytes(bytes: []const u8) []const u8 {
    const limit = 12 * 1024;
    if (bytes.len <= limit) return bytes;
    return bytes[0..limit];
}

test "openresponses tools json is an array" {
    const tools = @import("../tools.zig");
    const gpa = std.testing.allocator;
    const json = try buildToolsJson(gpa, tools.registry);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\":false") != null);
}

test "openresponses routes parallel argument deltas by output index" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_a\",\"id\":\"item_a\",\"name\":\"bash\"}}", ai.StreamObserver.noop, &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_b\",\"id\":\"item_b\",\"name\":\"read\"}}", ai.StreamObserver.noop, &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\\\"command\\\":\"}", ai.StreamObserver.noop, &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{\\\"path\\\":\"}", ai.StreamObserver.noop, &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"\\\"pwd\\\"}\"}", ai.StreamObserver.noop, &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"\\\"src/main.zig\\\"}\"}", ai.StreamObserver.noop, &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), turn.assistant.content.len);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", turn.assistant.content[0].tool_call.arguments);
    try std.testing.expectEqualStrings("{\"path\":\"src/main.zig\"}", turn.assistant.content[1].tool_call.arguments);
}
