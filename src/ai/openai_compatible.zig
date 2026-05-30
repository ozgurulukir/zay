const std = @import("std");
const logger = @import("logger");
const ai = @import("../ai.zig");
const model_catalog = @import("openai_compatible_models.zig");
const openai_endpoint = @import("openai_endpoint.zig");
const tools_common = @import("../tools/common.zig");

const Scanner = std.json.Scanner;

const redirect_buffer_bytes: u32 = 8192;
const transfer_buffer_bytes: u32 = 4096;
const body_buffer_bytes: u32 = 4096;
const tool_call_count_max: u32 = 16;
const stream_chunk_count_max: u32 = 100_000;
const stream_bytes_max: u32 = 8 * 1024 * 1024;

pub const ModelEntry = model_catalog.ModelEntry;
pub const listModels = model_catalog.listModels;
pub const openaiV1Root = openai_endpoint.v1Root;

/// OpenAI-compatible AI client using the Completions API.
pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: ai.Config,
    url: []u8,
    authorization: []u8,
    /// Pre-built JSON for the OpenAI `tools` request field — derived from
    /// `config.tools` (the protocol-neutral **Tool registry**) once at init.
    tools_json: []u8,
    http_client: std.http.Client,
    /// Monotonic counter for synthesised tool_call ids when the inference
    /// server omits them. OpenAI's protocol requires stable ids linking
    /// assistant tool_calls to their `tool` result messages, so we mint
    /// one here rather than letting the agent see an empty id.
    tool_call_seq: u64 = 0,

    pub fn init(
        target: *Client,
        gpa: std.mem.Allocator,
        io: std.Io,
        config: ai.Config,
    ) !void {
        std.debug.assert(config.base_url.len > 0);
        std.debug.assert(config.model.len > 0);

        const v1_root = try openaiV1Root(gpa, config.base_url);
        defer gpa.free(v1_root);
        const url = try std.fmt.allocPrint(gpa, "{s}/chat/completions", .{v1_root});
        errdefer gpa.free(url);

        const authorization = try std.fmt.allocPrint(
            gpa,
            "Bearer {s}",
            .{config.api_key},
        );
        errdefer gpa.free(authorization);

        var owned_config = config;
        owned_config.base_url = "";
        owned_config.api_key = "";
        owned_config.model = try gpa.dupe(u8, config.model);
        errdefer gpa.free(owned_config.model);

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
        self.gpa.free(self.tools_json);
        self.gpa.free(self.authorization);
        self.gpa.free(self.url);
        self.* = undefined;
    }

    pub fn prompt(
        self: *Client,
        messages: []const ai.ChatMessage,
        observer: ai.StreamObserver,
    ) !ai.Turn {
        std.debug.assert(self.url.len > 0);
        std.debug.assert(self.authorization.len > 0);

        var req = try self.http_client.request(.POST, try std.Uri.parse(self.url), .{
            .headers = .{
                .authorization = .{ .override = self.authorization },
                .content_type = .{ .override = "application/json" },
            },
        });
        defer req.deinit();

        var payload: std.Io.Writer.Allocating = .init(self.gpa);
        defer payload.deinit();
        try writeRequestPayload(
            &payload.writer,
            self.config.model,
            messages,
            self.tools_json,
            self.config.reasoning,
        );
        logger.log("openai_compatible.request POST {s} body={s}", .{ self.url, logBytes(payload.written()) });

        req.transfer_encoding = .chunked;
        var body_buffer: [body_buffer_bytes]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&body_buffer);
        try body_writer.writer.writeAll(payload.written());
        try body_writer.end();
        try req.connection.?.flush();

        var redirect_buffer: [redirect_buffer_bytes]u8 = undefined;
        var http_response = try req.receiveHead(&redirect_buffer);
        const status_code: u16 = @intFromEnum(http_response.head.status);
        logger.log("openai_compatible.response.head status={d}", .{status_code});
        if (status_code >= 400) {
            var error_buffer: [transfer_buffer_bytes]u8 = undefined;
            const error_reader = http_response.reader(&error_buffer);
            var error_body: std.Io.Writer.Allocating = .init(self.gpa);
            defer error_body.deinit();
            _ = error_reader.streamRemaining(&error_body.writer) catch 0;
            logger.log("openai_compatible.response.error status={d} body={s}", .{ status_code, logBytes(error_body.written()) });
            if (status_code >= 500) return error.HttpServerError;
            return error.HttpClientError;
        }
        if (status_code < 200 or status_code >= 300) return error.HttpUnexpectedStatus;

        var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
        const reader = http_response.reader(&transfer_buffer);
        return try readStream(self.gpa, reader, observer, &self.tool_call_seq);
    }
};

fn logBytes(bytes: []const u8) []const u8 {
    const limit = 12 * 1024;
    if (bytes.len <= limit) return bytes;
    return bytes[0..limit];
}

/// Build the OpenAI `tools` JSON array from the protocol-neutral
/// **Tool registry**. Each adapter owns its own translation; this is the
/// OpenAI version of "render a Tool into a tools-schema entry."
/// Substitutes `{{hsep}}` → `~` in each tool's description template.
fn buildToolsJson(gpa: std.mem.Allocator, tools: []const tools_common.Tool) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const writer = &aw.writer;
    try writer.writeByte('[');
    for (tools, 0..) |tool, i| {
        if (i > 0) try writer.writeByte(',');
        try writeToolDefinition(gpa, writer, tool);
    }
    try writer.writeByte(']');
    return aw.toOwnedSlice();
}

fn writeToolDefinition(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    tool: tools_common.Tool,
) !void {
    const description = try std.mem.replaceOwned(u8, gpa, tool.description, "{{hsep}}", "~");
    defer gpa.free(description);
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(tool.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(description, .{}, writer);
    try writer.writeAll(",\"parameters\":{\"type\":\"object\",\"properties\":{");
    for (tool.schema.properties, 0..) |prop, p| {
        if (p > 0) try writer.writeByte(',');
        try std.json.Stringify.value(prop.name, .{}, writer);
        try writer.writeAll(":{\"type\":");
        const kind_str: []const u8 = switch (prop.kind) {
            .string => "string",
            .integer => "integer",
            .object => "object",
        };
        try std.json.Stringify.value(kind_str, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(prop.description, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("},\"required\":[");
    var written_required: u32 = 0;
    for (tool.schema.properties) |prop| {
        if (!prop.required) continue;
        if (written_required > 0) try writer.writeByte(',');
        try std.json.Stringify.value(prop.name, .{}, writer);
        written_required += 1;
    }
    try writer.writeAll("]}}}");
}

fn writeMessage(out: *std.Io.Writer, message: ai.ChatMessage) !void {
    try out.writeAll("{\"role\":");
    try std.json.Stringify.value(message.role.label(), .{}, out);
    try out.writeAll(",\"content\":");
    if (message.role == .user) {
        try writeUserContent(out, message.content);
    } else {
        try writeTextContent(out, message.content);
    }
    if (message.call_id) |call_id| {
        try out.writeAll(",\"tool_call_id\":");
        try std.json.Stringify.value(call_id, .{}, out);
    }
    if (message.role == .assistant) {
        var wrote_calls = false;
        for (message.content) |block| {
            if (block != .tool_call) continue;
            if (!wrote_calls) {
                try out.writeAll(",\"tool_calls\":[");
                wrote_calls = true;
            } else {
                try out.writeByte(',');
            }
            try writeToolCall(out, block.tool_call);
        }
        if (wrote_calls) try out.writeByte(']');
    }
    try out.writeByte('}');
}

fn writeTextContent(out: *std.Io.Writer, blocks: []const ai.ContentBlock) !void {
    var aw: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer aw.deinit();
    for (blocks) |block| {
        switch (block) {
            .text => |text| try aw.writer.writeAll(text.text),
            .reasoning, .image, .tool_call => {},
        }
    }
    try std.json.Stringify.value(aw.written(), .{}, out);
}

fn writeUserContent(out: *std.Io.Writer, blocks: []const ai.ContentBlock) !void {
    try out.writeByte('[');
    var count: u32 = 0;
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                if (count > 0) try out.writeByte(',');
                try out.writeAll("{\"type\":\"text\",\"text\":");
                try std.json.Stringify.value(text.text, .{}, out);
                try out.writeByte('}');
                count += 1;
            },
            .image => |image| {
                if (count > 0) try out.writeByte(',');
                try out.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":");
                try out.writeByte('"');
                try out.writeAll("data:");
                try out.writeAll(image.mime_type);
                try out.writeAll(";base64,");
                try out.writeAll(image.data_base64);
                try out.writeByte('"');
                try out.writeAll("}}");
                count += 1;
            },
            .reasoning, .tool_call => {},
        }
    }
    try out.writeByte(']');
}

fn writeToolCall(out: *std.Io.Writer, tool_call: ai.ToolCall) !void {
    try out.writeAll("{\"id\":");
    try std.json.Stringify.value(tool_call.call_id, .{}, out);
    try out.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(tool_call.name, .{}, out);
    try out.writeAll(",\"arguments\":");
    try std.json.Stringify.value(tool_call.arguments, .{}, out);
    try out.writeAll("}}");
}

fn writeRequestPayload(
    out: *std.Io.Writer,
    model: []const u8,
    messages: []const ai.ChatMessage,
    tools_json: []const u8,
    reasoning: ?ai.Reasoning,
) !void {
    std.debug.assert(model.len > 0);
    std.debug.assert(tools_json.len > 0);

    try out.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, out);
    try out.writeAll(",\"messages\":[");
    for (messages, 0..) |message, index| {
        if (index > 0) try out.writeByte(',');
        try writeMessage(out, message);
    }
    try out.writeAll("],\"stream\":true,\"tools\":");
    try out.writeAll(tools_json);
    try out.writeAll(",\"tool_choice\":\"auto\"");
    const effort = if (reasoning) |value| value.effort else null;
    const value = effort orelse {
        try out.writeByte('}');
        return;
    };

    switch (value) {
        .none => try out.writeAll(",\"enable_thinking\":false}"),
        else => {
            try out.writeAll(",\"reasoning_effort\":\"");
            try out.writeAll(value.label());
            try out.writeAll("\"}");
        },
    }
}

const ToolCallBuilder = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolCallBuilder, gpa: std.mem.Allocator) void {
        self.id.deinit(gpa);
        self.name.deinit(gpa);
        self.arguments.deinit(gpa);
        self.* = undefined;
    }

    /// Finalise the accumulated chunks into a canonical `ai.ToolCall`.
    /// When the server omitted an id, synthesise one from `tool_call_seq`
    /// — the agent never sees an empty id.
    fn toToolCall(self: *ToolCallBuilder, gpa: std.mem.Allocator, tool_call_seq: *u64) !ai.ToolCall {
        const id = if (self.id.items.len > 0)
            try self.id.toOwnedSlice(gpa)
        else id_blk: {
            const minted = try std.fmt.allocPrint(gpa, "call_{d}", .{tool_call_seq.*});
            tool_call_seq.* += 1;
            break :id_blk minted;
        };
        return .{
            .call_id = id,
            .name = try self.name.toOwnedSlice(gpa),
            .arguments = try self.arguments.toOwnedSlice(gpa),
        };
    }
};

fn readStream(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    observer: ai.StreamObserver,
    tool_call_seq: *u64,
) !ai.Turn {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var builders: std.ArrayList(ToolCallBuilder) = .empty;
    defer {
        for (builders.items) |*builder| {
            builder.deinit(gpa);
        }
        builders.deinit(gpa);
    }

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
        if (std.mem.eql(u8, data, "[DONE]")) break;
        try processStreamChunk(gpa, data, &content, &reasoning, &builders, observer);
    }

    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    errdefer {
        for (blocks.items) |*block| block.deinit(gpa);
        blocks.deinit(gpa);
    }
    if (reasoning.items.len > 0) {
        try blocks.append(gpa, .{ .reasoning = .{ .text = try reasoning.toOwnedSlice(gpa) } });
    }
    if (content.items.len > 0) {
        try blocks.append(gpa, .{ .text = .{ .text = try content.toOwnedSlice(gpa) } });
    }
    for (builders.items) |*builder| {
        if (builder.name.items.len == 0) continue;
        try blocks.append(gpa, .{ .tool_call = try builder.toToolCall(gpa, tool_call_seq) });
    }
    return .{ .assistant = .{ .role = .assistant, .content = try blocks.toOwnedSlice(gpa) } };
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
            const line = try line_writer.toOwnedSlice();
            return line;
        },
        else => |e| return e,
    };
    std.debug.assert(delimiter.len == 1);
    std.debug.assert(delimiter[0] == '\n');
    const line = try line_writer.toOwnedSlice();
    return line;
}

const ChunkChange = struct {
    content_start: ?u32 = null,
    reasoning_start: ?u32 = null,
    tool_call_indexes: [tool_call_count_max]u32 = @splat(0),
    tool_call_count: u32 = 0,

    fn empty(self: *const ChunkChange) bool {
        if (self.content_start != null) return false;
        if (self.reasoning_start != null) return false;
        if (self.tool_call_count > 0) return false;
        return true;
    }

    fn recordToolCall(self: *ChunkChange, index: u32) void {
        for (self.tool_call_indexes[0..self.tool_call_count]) |existing| {
            if (existing == index) return;
        }
        std.debug.assert(self.tool_call_count < tool_call_count_max);
        self.tool_call_indexes[self.tool_call_count] = index;
        self.tool_call_count += 1;
    }
};

fn applyChunkCallbacks(
    change: ChunkChange,
    content: []const u8,
    reasoning: []const u8,
    builders: []const ToolCallBuilder,
    observer: ai.StreamObserver,
) !void {
    if (change.content_start) |start| {
        try observer.on_content(observer.ptr, content[start..]);
    }
    if (change.reasoning_start) |start| {
        try observer.on_reasoning(observer.ptr, reasoning[start..]);
    }
    for (change.tool_call_indexes[0..change.tool_call_count]) |idx| {
        const builder = builders[idx];
        try observer.on_tool_delta(observer.ptr, .{
            .index = idx,
            .name = builder.name.items,
            .arguments = builder.arguments.items,
        });
    }
    if (change.empty()) return;
    try observer.on_delta_end(observer.ptr);
}

fn processStreamChunk(
    gpa: std.mem.Allocator,
    data: []const u8,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    builders: *std.ArrayList(ToolCallBuilder),
    observer: ai.StreamObserver,
) !void {
    const change = try parseStreamChunk(gpa, data, content, reasoning, builders);
    try applyChunkCallbacks(change, content.items, reasoning.items, builders.items, observer);
}

fn parseStreamChunk(
    gpa: std.mem.Allocator,
    data: []const u8,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    builders: *std.ArrayList(ToolCallBuilder),
) !ChunkChange {
    std.debug.assert(data.len > 0);

    var scanner = Scanner.initCompleteInput(gpa, data);
    defer scanner.deinit();

    var change: ChunkChange = .{};
    try expectObjectBegin(&scanner);
    while (try nextObjectKey(&scanner)) |key| {
        if (std.mem.eql(u8, key, "choices")) {
            try parseChoicesArray(gpa, &scanner, content, reasoning, builders, &change);
        } else {
            try scanner.skipValue();
        }
    }
    return change;
}

fn parseChoicesArray(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    builders: *std.ArrayList(ToolCallBuilder),
    change: *ChunkChange,
) !void {
    try expectArrayBegin(scanner);
    var saw_first = false;
    while (true) {
        const peeked = try scanner.peekNextTokenType();
        if (peeked == .array_end) {
            _ = try scanner.next();
            return;
        }
        if (saw_first) {
            try scanner.skipValue();
            continue;
        }
        try expectObjectBegin(scanner);
        try parseChoiceObject(gpa, scanner, content, reasoning, builders, change);
        saw_first = true;
    }
}

fn parseChoiceObject(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    builders: *std.ArrayList(ToolCallBuilder),
    change: *ChunkChange,
) !void {
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "delta")) {
            try parseDeltaObject(gpa, scanner, content, reasoning, builders, change);
        } else {
            try scanner.skipValue();
        }
    }
}

fn parseDeltaObject(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    builders: *std.ArrayList(ToolCallBuilder),
    change: *ChunkChange,
) !void {
    try expectObjectBegin(scanner);
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "content")) {
            const before: u32 = @intCast(content.items.len);
            const appended = try appendStringValueOrNull(scanner, gpa, content);
            if (appended) {
                if (content.items.len > before) change.content_start = before;
            }
        } else if (std.mem.eql(u8, key, "reasoning") or std.mem.eql(u8, key, "reasoning_content")) {
            const before: u32 = @intCast(reasoning.items.len);
            const appended = try appendStringValueOrNull(scanner, gpa, reasoning);
            if (appended) {
                if (reasoning.items.len > before) change.reasoning_start = before;
            }
        } else if (std.mem.eql(u8, key, "tool_calls")) {
            try parseToolCallsArray(gpa, scanner, builders, change);
        } else {
            try scanner.skipValue();
        }
    }
}

fn parseToolCallsArray(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    builders: *std.ArrayList(ToolCallBuilder),
    change: *ChunkChange,
) !void {
    try expectArrayBegin(scanner);
    while (true) {
        const peeked = try scanner.peekNextTokenType();
        if (peeked == .array_end) {
            _ = try scanner.next();
            return;
        }
        try expectObjectBegin(scanner);
        try parseToolCallObject(gpa, scanner, builders, change);
    }
}

fn parseToolCallObject(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    builders: *std.ArrayList(ToolCallBuilder),
    change: *ChunkChange,
) !void {
    var pending: ToolCallBuilder = .{};
    defer pending.deinit(gpa);
    var has_pending_id = false;
    var has_pending_name = false;
    var has_pending_arguments = false;
    var resolved_index: ?u32 = null;

    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "index")) {
            const index = try nextInteger(scanner);
            if (index < 0) return error.InvalidToolCallIndex;
            if (index >= tool_call_count_max) return error.TooManyToolCalls;
            resolved_index = @intCast(index);
        } else if (std.mem.eql(u8, key, "id")) {
            try appendStringValue(scanner, gpa, &pending.id);
            has_pending_id = true;
        } else if (std.mem.eql(u8, key, "function")) {
            try parseToolCallFunction(gpa, scanner, &pending, &has_pending_name, &has_pending_arguments);
        } else {
            try scanner.skipValue();
        }
    }

    const idx = resolved_index orelse return;
    while (builders.items.len <= idx) try builders.append(gpa, .{});
    const target = &builders.items[@as(usize, idx)];

    if (has_pending_id) try target.id.appendSlice(gpa, pending.id.items);
    if (has_pending_name) try target.name.appendSlice(gpa, pending.name.items);
    if (has_pending_arguments) try target.arguments.appendSlice(gpa, pending.arguments.items);
    change.recordToolCall(idx);
}

fn parseToolCallFunction(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    pending: *ToolCallBuilder,
    has_pending_name: *bool,
    has_pending_arguments: *bool,
) !void {
    try expectObjectBegin(scanner);
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "name")) {
            try appendStringValue(scanner, gpa, &pending.name);
            has_pending_name.* = true;
        } else if (std.mem.eql(u8, key, "arguments")) {
            try appendStringValue(scanner, gpa, &pending.arguments);
            has_pending_arguments.* = true;
        } else {
            try scanner.skipValue();
        }
    }
}

fn expectObjectBegin(scanner: *Scanner) !void {
    const token = try scanner.next();
    if (token != .object_begin) return error.UnexpectedToken;
}

fn expectArrayBegin(scanner: *Scanner) !void {
    const token = try scanner.next();
    if (token != .array_begin) return error.UnexpectedToken;
}

fn nextObjectKey(scanner: *Scanner) !?[]const u8 {
    const token = try scanner.next();
    return switch (token) {
        .object_end => null,
        .string => |s| s,
        else => error.UnexpectedToken,
    };
}

fn nextInteger(scanner: *Scanner) !i64 {
    const token = try scanner.next();
    const text = switch (token) {
        .number => |s| s,
        else => return error.UnexpectedToken,
    };
    return try std.fmt.parseInt(i64, text, 10);
}

fn appendStringValue(scanner: *Scanner, gpa: std.mem.Allocator, list: *std.ArrayList(u8)) !void {
    const appended = try appendStringValueOrNull(scanner, gpa, list);
    if (!appended) return error.UnexpectedToken;
}

fn appendStringValueOrNull(scanner: *Scanner, gpa: std.mem.Allocator, list: *std.ArrayList(u8)) !bool {
    while (true) {
        const token = try scanner.next();
        switch (token) {
            .null => return false,
            .string => |s| {
                try list.appendSlice(gpa, s);
                return true;
            },
            .partial_string => |s| try list.appendSlice(gpa, s),
            .partial_string_escaped_1 => |bytes| try list.appendSlice(gpa, &bytes),
            .partial_string_escaped_2 => |bytes| try list.appendSlice(gpa, &bytes),
            .partial_string_escaped_3 => |bytes| try list.appendSlice(gpa, &bytes),
            .partial_string_escaped_4 => |bytes| try list.appendSlice(gpa, &bytes),
            else => return error.UnexpectedToken,
        }
    }
}

test "buildToolsJson produces a valid JSON array for the registry" {
    const tools = @import("../tools.zig");
    const gpa = std.testing.allocator;
    const json = try buildToolsJson(gpa, tools.registry);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"read_file\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"write_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"path\",\"content\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "`content` is the entire file body") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, ":50-200") != null);
}

test "buildToolsJson substitutes {{hsep}} placeholders with ~" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "demo",
            .description = "uses {{hsep}} marker",
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .displayLabel = undefined,
        },
    };
    const json = try buildToolsJson(gpa, &tools);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "uses ~ marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "{{hsep}}") == null);
}

test "writeRequestPayload disables thinking for reasoning effort none" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, "qwen-test", &.{}, "[]", .{ .effort = .none });
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "readStream accepts an SSE line larger than the transfer buffer" {
    const gpa = std.testing.allocator;
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);

    try stream.appendSlice(gpa, "data: {\"choices\":[{\"delta\":{\"content\":\"");
    var index: u32 = 0;
    while (index < transfer_buffer_bytes + 512) : (index += 1) try stream.append(gpa, 'a');
    try stream.appendSlice(gpa, "\"}}]}\n");
    try stream.appendSlice(gpa, "data: [DONE]\n");

    var reader: std.Io.Reader = .fixed(stream.items);
    var tool_call_seq: u64 = 0;
    var response = try readStream(gpa, &reader, ai.StreamObserver.noop, &tool_call_seq);
    defer response.deinit(gpa);
    try std.testing.expectEqual(@as(usize, transfer_buffer_bytes + 512), response.assistant.content[0].text.text.len);
}

test "parse streaming content tolerates null prelude" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var builders: std.ArrayList(ToolCallBuilder) = .empty;
    defer {
        for (builders.items) |*builder| {
            builder.deinit(gpa);
        }
        builders.deinit(gpa);
    }

    const change = try parseStreamChunk(gpa,
        \\{"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}]}
    , &content, &reasoning, &builders);

    try std.testing.expect(change.empty());
    try std.testing.expectEqual(@as(usize, 0), content.items.len);
    try std.testing.expectEqual(@as(usize, 0), reasoning.items.len);
}

test "parse streaming tool deltas as they arrive" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var builders: std.ArrayList(ToolCallBuilder) = .empty;
    defer {
        for (builders.items) |*builder| {
            builder.deinit(gpa);
        }
        builders.deinit(gpa);
    }

    const Seen = struct {
        name: []const u8 = "",
        arguments: []const u8 = "",
        index: u32 = 0,

        fn onToolDelta(context: *anyopaque, delta: ai.ToolDelta) anyerror!void {
            const seen: *@This() = @ptrCast(@alignCast(context));
            seen.index = delta.index;
            seen.name = delta.name;
            seen.arguments = delta.arguments;
        }
    };
    var seen: Seen = .{};
    var observer = ai.StreamObserver.noop;
    observer.ptr = &seen;
    observer.on_tool_delta = Seen.onToolDelta;

    try processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":\"zig"}}]}}]}
    , &content, &reasoning, &builders, observer);
    try processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":" build\"}"}}]}}]}
    , &content, &reasoning, &builders, observer);

    try std.testing.expectEqualStrings("bash", seen.name);
    try std.testing.expectEqualStrings("{\"command\":\"zig build\"}", seen.arguments);
    try std.testing.expectEqual(@as(u32, 0), seen.index);
}

test "parse streaming tool deltas tolerate key reorder" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var builders: std.ArrayList(ToolCallBuilder) = .empty;
    defer {
        for (builders.items) |*builder| {
            builder.deinit(gpa);
        }
        builders.deinit(gpa);
    }

    try processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"function":{"name":"bash","arguments":"{}"},"id":"call_1","index":0}]}}]}
    , &content, &reasoning, &builders, ai.StreamObserver.noop);

    try std.testing.expectEqual(@as(usize, 1), builders.items.len);
    try std.testing.expectEqualStrings("call_1", builders.items[0].id.items);
    try std.testing.expectEqualStrings("bash", builders.items[0].name.items);
    try std.testing.expectEqualStrings("{}", builders.items[0].arguments.items);
}

test "parse streaming tool deltas batches render notification per event" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var builders: std.ArrayList(ToolCallBuilder) = .empty;
    defer {
        for (builders.items) |*builder| {
            builder.deinit(gpa);
        }
        builders.deinit(gpa);
    }

    const Seen = struct {
        tool_delta_count: u32 = 0,
        render_count: u32 = 0,

        fn onToolDelta(context: *anyopaque, _: ai.ToolDelta) anyerror!void {
            const seen: *@This() = @ptrCast(@alignCast(context));
            seen.tool_delta_count += 1;
        }

        fn onDeltaEnd(context: *anyopaque) anyerror!void {
            const seen: *@This() = @ptrCast(@alignCast(context));
            seen.render_count += 1;
        }
    };
    var seen: Seen = .{};
    var observer = ai.StreamObserver.noop;
    observer.ptr = &seen;
    observer.on_tool_delta = Seen.onToolDelta;
    observer.on_delta_end = Seen.onDeltaEnd;

    try processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":\"pwd\"}"}},{"index":1,"id":"call_2","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]}}]}
    , &content, &reasoning, &builders, observer);

    try std.testing.expectEqual(@as(u32, 2), seen.tool_delta_count);
    try std.testing.expectEqual(@as(u32, 1), seen.render_count);
}

test "parse streaming reasoning deltas as they arrive" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var builders: std.ArrayList(ToolCallBuilder) = .empty;
    defer {
        for (builders.items) |*builder| {
            builder.deinit(gpa);
        }
        builders.deinit(gpa);
    }

    const Seen = struct {
        gpa: std.mem.Allocator,
        reasoning: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.reasoning.deinit(self.gpa);
        }

        fn onReasoning(context: *anyopaque, delta: []const u8) anyerror!void {
            const seen: *@This() = @ptrCast(@alignCast(context));
            try seen.reasoning.appendSlice(seen.gpa, delta);
        }
    };
    var seen: Seen = .{ .gpa = gpa };
    defer seen.deinit();
    var observer = ai.StreamObserver.noop;
    observer.ptr = &seen;
    observer.on_reasoning = Seen.onReasoning;

    try processStreamChunk(gpa,
        \\{"choices":[{"delta":{"reasoning_content":"checking output"}}]}
    , &content, &reasoning, &builders, observer);

    try std.testing.expectEqualStrings("checking output", seen.reasoning.items);
    try std.testing.expectEqualStrings("checking output", reasoning.items);
}

test "parse streaming content deltas as they arrive" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var builders: std.ArrayList(ToolCallBuilder) = .empty;
    defer {
        for (builders.items) |*builder| {
            builder.deinit(gpa);
        }
        builders.deinit(gpa);
    }

    const Seen = struct {
        gpa: std.mem.Allocator,
        content: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.content.deinit(self.gpa);
        }

        fn onContent(context: *anyopaque, delta: []const u8) anyerror!void {
            const seen: *@This() = @ptrCast(@alignCast(context));
            try seen.content.appendSlice(seen.gpa, delta);
        }
    };
    var seen: Seen = .{ .gpa = gpa };
    defer seen.deinit();
    var observer = ai.StreamObserver.noop;
    observer.ptr = &seen;
    observer.on_content = Seen.onContent;

    try processStreamChunk(gpa,
        \\{"choices":[{"delta":{"content":"hel"}}]}
    , &content, &reasoning, &builders, observer);
    try processStreamChunk(gpa,
        \\{"choices":[{"delta":{"content":"lo"}}]}
    , &content, &reasoning, &builders, observer);

    try std.testing.expectEqualStrings("hello", seen.content.items);
    try std.testing.expectEqualStrings("hello", content.items);
}
