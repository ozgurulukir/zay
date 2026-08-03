const std = @import("std");
const logger = @import("logger");
const ai = @import("../ai.zig");
const model_catalog = @import("openai_compatible_models.zig");
const openai_endpoint = @import("openai_endpoint.zig");
const stream_parser = @import("stream_parser.zig");
const tool_schema = @import("tool_schema.zig");
const tools_common = @import("../tools/common.zig");
const tools_mod = @import("../tools.zig");

const redirect_buffer_bytes: u32 = 8192;
const transfer_buffer_bytes: u32 = 4096;
const body_buffer_bytes: u32 = 4096;
/// Upper bound on exponential retry backoff, in milliseconds. A server-sent
/// `Retry-After` header is honored verbatim (not capped here).
const retry_max_delay_ms: u64 = 8000;

pub const ModelEntry = model_catalog.ModelEntry;
pub const listModels = model_catalog.listModels;
pub const openaiV1Root = openai_endpoint.v1Root;
pub const sanitizeToolArguments = stream_parser.sanitizeToolArguments;

/// OpenAI-compatible AI client using the Completions API.
pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: ai.Config,
    url: []u8,
    authorization: ?[]u8,
    tools_json: []u8,
    /// Whether tool definitions carry OpenAI strict structured-outputs mode.
    /// Captured at `init` so `updateMcpTools` can rebuild `tools_json`
    /// consistently without the caller re-passing it. Default `false` —
    /// strict mode is OpenAI-only and silently breaks function-calling on
    /// gateways (OpenRouter/Ollama/vLLM).
    strict: bool = false,
    http_client: std.http.Client,
    /// Monotonic counter for synthesised tool_call ids when the inference
    /// server omits them. OpenAI's protocol requires stable ids linking
    /// assistant tool_calls to their `tool` result messages, so we mint
    /// one here rather than letting the agent see an empty id.
    tool_call_seq: u64 = 0,
    last_error_detail: ?[]u8 = null,

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

        // Empty key => anonymous request. Keep `authorization` null so `prompt`
        // omits the header entirely.
        const authorization: ?[]u8 = if (config.api_key.len > 0)
            try std.fmt.allocPrint(gpa, "Bearer {s}", .{config.api_key})
        else
            null;
        errdefer if (authorization) |a| gpa.free(a);

        var owned_config = config;
        owned_config.base_url = "";
        owned_config.api_key = "";
        owned_config.model = try gpa.dupe(u8, config.model);
        errdefer gpa.free(owned_config.model);
        owned_config.session_id = try gpa.dupe(u8, config.session_id);
        errdefer gpa.free(owned_config.session_id);

        const tools_json = try tool_schema.buildAllToolsJson(gpa, config.tools, config.mcp_tools, null, config.strict, .completions);
        errdefer gpa.free(tools_json);

        target.* = .{
            .gpa = gpa,
            .io = io,
            .config = owned_config,
            .url = url,
            .authorization = authorization,
            .tools_json = tools_json,
            .strict = config.strict,
            .http_client = .{ .allocator = gpa, .io = io },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
        self.gpa.free(self.config.model);
        self.gpa.free(self.config.session_id);
        self.gpa.free(self.tools_json);
        if (self.authorization) |a| self.gpa.free(a);
        self.gpa.free(self.url);
        if (self.last_error_detail) |d| self.gpa.free(d);
        self.* = undefined;
    }

    /// Rebuild the serialized tool definitions after the MCP tool set changes.
    /// `mcp_tools` is borrowed only for the duration of the call; the result is
    /// the owned `tools_json`. Call between turns, never mid-turn.
    /// `registry`, when non-null, contributes its builtin + plugin tools so
    /// the model sees them as first-class definitions. `builtin_override`
    /// lets the caller pick what `config.tools` contributes at call time —
    /// typically `&.{}` because the registry's builtin already covers
    /// bash, and emitting both creates a duplicate name that most APIs
    /// reject outright.
    pub fn updateMcpTools(
        self: *Client,
        mcp_tools: []const ai.McpToolSchema,
        registry: ?*tools_mod.ToolRegistry,
        builtin_override: []const tools_common.Tool,
    ) !void {
        const new_json = try tool_schema.buildAllToolsJson(self.gpa, builtin_override, mcp_tools, registry, self.strict, .completions);
        self.gpa.free(self.tools_json);
        self.tools_json = new_json;
    }

    fn clearErrorDetail(self: *Client) void {
        if (self.last_error_detail) |d| self.gpa.free(d);
        self.last_error_detail = null;
    }

    /// Record `HTTP <status>: <message>` from a failed response body for the UI.
    /// Best-effort: a failure to build the string just leaves the detail unset.
    fn recordErrorDetail(self: *Client, status_code: u16, body: []const u8) void {
        const message = extractErrorMessage(self.gpa, body) catch return;
        defer self.gpa.free(message);
        // Temporary diagnostic — log every API error verbatim so we can see
        // the actual reason for "HTTP 400" (most often: schema validation
        // or duplicate tool name). The UI also shows last_error_detail;
        // this is the stderr variant.
        std.debug.print("[trace] openai_compatible.recordErrorDetail: status={d} body={s}\n", .{ status_code, message });
        const detail = std.fmt.allocPrint(self.gpa, "HTTP {d}: {s}", .{ status_code, message }) catch return;
        self.clearErrorDetail();
        self.last_error_detail = detail;
    }

    pub fn prompt(
        self: *Client,
        messages: []const ai.MessageView,
        observer: anytype,
    ) !ai.Turn {
        std.debug.assert(self.url.len > 0);
        self.clearErrorDetail();

        // The payload is serialized ONCE; every retry attempt re-sends the
        // same bytes. This is safe because retries only happen on head-phase
        // 429/5xx — the model has not produced anything and no tool has run,
        // so the request is idempotent. Stream-mid errors are never retried
        // (partial deltas may already be visible to the observer).
        var payload: std.Io.Writer.Allocating = .init(self.gpa);
        defer payload.deinit();
        try writeRequestPayload(
            self.gpa,
            &payload.writer,
            self.config.model,
            self.config.session_id,
            messages,
            self.tools_json,
            self.config.reasoning,
            self.config.max_output_tokens,
            self.config.wire_dialect,
        );
        logger.log("openai_compatible.request POST {s} body={s}", .{ self.url, logBytes(payload.written()) });

        var attempt: u32 = 0;
        while (attempt <= self.config.max_retries) : (attempt += 1) {
            var retry_after_secs: ?u64 = null;
            const turn = self.sendOnce(payload.written(), observer, &retry_after_secs) catch |err| {
                // Only head-phase transient statuses (429 + 5xx) are retried.
                // Every other 4xx is permanent — a schema/auth/model error
                // won't fix itself, and stream-mid errors never surface as
                // these codes, so they propagate immediately too.
                if (attempt >= self.config.max_retries) return err;
                switch (err) {
                    error.HttpServerError, error.HttpRateLimited => {},
                    else => return err,
                }
                const delay_ms = self.retryDelayMs(attempt, retry_after_secs);
                logger.log("openai_compatible.retry attempt={d} err={s} delay_ms={d}", .{ attempt + 1, @errorName(err), delay_ms });
                self.sleepMs(delay_ms);
                continue;
            };
            return turn;
        }
        unreachable;
    }

    /// Perform one HTTP round-trip with the already-serialized payload.
    /// Transient head-phase statuses (429, 5xx) surface as
    /// `error.HttpRateLimited` / `error.HttpServerError` so `prompt` can
    /// decide whether to retry; every other failure propagates unchanged.
    /// When a retryable status is hit, `retry_after_secs` receives the
    /// server's `Retry-After` value (integer seconds) if one was sent.
    fn sendOnce(self: *Client, payload: []const u8, observer: anytype, retry_after_secs: *?u64) !ai.Turn {
        var req = try self.http_client.request(.POST, try std.Uri.parse(self.url), .{
            .headers = .{
                .authorization = if (self.authorization) |a| .{ .override = a } else .omit,
                .content_type = .{ .override = "application/json" },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .chunked;
        var body_buffer: [body_buffer_bytes]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&body_buffer);
        try body_writer.writer.writeAll(payload);
        try body_writer.end();
        try req.connection.?.flush();

        var redirect_buffer: [redirect_buffer_bytes]u8 = undefined;
        var http_response = try req.receiveHead(&redirect_buffer);
        const status_code: u16 = @intFromEnum(http_response.head.status);
        logger.log("openai_compatible.response.head status={d}", .{status_code});
        if (status_code >= 400) {
            // Read `Retry-After` before initializing the body reader — the
            // head pointers are invalidated once the body stream starts.
            if (status_code == 429 or status_code >= 500) {
                retry_after_secs.* = parseRetryAfterSeconds(http_response.head.bytes);
            }
            var error_buffer: [transfer_buffer_bytes]u8 = undefined;
            const error_reader = http_response.reader(&error_buffer);
            var error_body: std.Io.Writer.Allocating = .init(self.gpa);
            defer error_body.deinit();
            _ = error_reader.streamRemaining(&error_body.writer) catch 0;
            logger.log("openai_compatible.response.error status={d} body={s}", .{ status_code, logBytes(error_body.written()) });
            self.recordErrorDetail(status_code, error_body.written());
            if (status_code == 429) return error.HttpRateLimited;
            if (status_code >= 500) return error.HttpServerError;
            return error.HttpClientError;
        }
        if (status_code < 200 or status_code >= 300) return error.HttpUnexpectedStatus;

        // Socket-level read timeout: prevents indefinite hangs when the
        // server stops mid-stream. Applied after the head is received so
        // the (fast) head exchange is not affected.
        if (req.connection) |conn| {
            const tv: std.posix.timeval = .{
                .sec = @intCast(self.config.request_timeout_seconds),
                .usec = 0,
            };
            std.posix.setsockopt(
                conn.stream_reader.stream.socket.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.RCVTIMEO,
                std.mem.asBytes(&tv),
            ) catch |err| {
                logger.log("openai_compatible.setsockopt.RCVTIMEO failed: {}", .{err});
            };
        }

        var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
        const reader = http_response.reader(&transfer_buffer);
        return try stream_parser.readStream(self.gpa, reader, observer, &self.tool_call_seq, self.config.max_parallel_tool_calls);
    }

    /// Delay before a retry: the server's `Retry-After` (integer seconds)
    /// when present, otherwise exponential backoff `base * 2^attempt` capped
    /// at `retry_max_delay_ms`. Pure — tested directly.
    fn retryDelayMs(self: *const Client, attempt: u32, retry_after_secs: ?u64) u64 {
        if (retry_after_secs) |secs| {
            // Saturating: an absurd header value must not wrap and stall or
            // skip the wait.
            return secs *| std.time.ms_per_s;
        }
        // Exponential backoff `base * 2^attempt`, saturating so an absurd
        // base can't wrap, then capped.
        var backoff = self.config.retry_base_delay_ms;
        var i: u32 = 0;
        while (i < attempt) : (i += 1) backoff *|= 2;
        return @min(backoff, retry_max_delay_ms);
    }

    /// Block the worker for the backoff delay. Best-effort — a cancel error
    /// just falls through (the turn is being torn down anyway).
    fn sleepMs(self: *const Client, ms: u64) void {
        if (ms == 0) return;
        const clamped: i64 = @intCast(@min(ms, std.math.maxInt(i64)));
        self.io.sleep(std.Io.Duration.fromMilliseconds(clamped), .awake) catch {};
    }
};

/// Extract an integer-seconds `Retry-After` value from a raw HTTP head.
/// HTTP-date formatted values are out of scope and yield null (gateways
/// practically send integer seconds). Pure — tested directly.
fn parseRetryAfterSeconds(head_bytes: []const u8) ?u64 {
    var it = std.mem.splitSequence(u8, head_bytes, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "retry-after")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(u64, value, 10) catch null;
    }
    return null;
}

fn logBytes(bytes: []const u8) []const u8 {
    const limit = 12 * 1024;
    if (bytes.len <= limit) return bytes;
    return bytes[0..limit];
}

/// Pull a human-readable message out of an error response body. Handles the
/// common OpenAI-ish shapes — `{"error":{"message":...}}`, `{"error":"..."}`,
/// `{"message":...}` — and falls back to the raw body (capped) when the body
/// isn't JSON or has none of those. Returned slice is owned by `gpa`.
fn extractErrorMessage(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    const cap = 600;
    const fallback = trimmed[0..@min(trimmed.len, cap)];

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch
        return gpa.dupe(u8, if (fallback.len > 0) fallback else "(empty response body)");
    defer parsed.deinit();

    if (parsed.value == .object) {
        const obj = parsed.value.object;
        if (obj.get("error")) |err_val| switch (err_val) {
            .string => |s| return gpa.dupe(u8, s),
            .object => |eo| if (eo.get("message")) |m| {
                if (m == .string) return gpa.dupe(u8, m.string);
            },
            else => {},
        };
        if (obj.get("message")) |m| {
            if (m == .string) return gpa.dupe(u8, m.string);
        }
    }
    return gpa.dupe(u8, if (fallback.len > 0) fallback else "(empty response body)");
}

test "extractErrorMessage pulls the nested message, plain error, or raw fallback" {
    const gpa = std.testing.allocator;

    // OpenCode Zen's shape: {"type":"error","error":{"type":...,"message":...}}
    const zen = try extractErrorMessage(gpa,
        \\{"type":"error","error":{"type":"ModelError","message":"Free promotion has ended."}}
    );
    defer gpa.free(zen);
    try std.testing.expectEqualStrings("Free promotion has ended.", zen);

    // `error` as a bare string.
    const plain = try extractErrorMessage(gpa,
        \\{"error":"invalid api key"}
    );
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("invalid api key", plain);

    // Non-JSON body falls back to the raw text.
    const raw = try extractErrorMessage(gpa, "  upstream timeout  ");
    defer gpa.free(raw);
    try std.testing.expectEqualStrings("upstream timeout", raw);
}

fn writeMessage(out: *std.Io.Writer, gpa: std.mem.Allocator, message: ai.ChatMessage, dialect: ai.WireDialect) !void {
    try out.writeAll("{\"role\":");
    const role_label: []const u8 = switch (message) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
    try std.json.Stringify.value(role_label, .{}, out);
    if (dialect.allowsCacheControl()) {
        switch (message) {
            .system => try out.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}"),
            else => {},
        }
    }
    try out.writeAll(",\"content\":");
    switch (message) {
        .user => try writeUserContent(out, message.user.content),
        inline .system, .assistant, .tool => |m| try writeTextContent(out, gpa, m.content),
    }
    if (message == .tool) {
        try out.writeAll(",\"tool_call_id\":");
        try std.json.Stringify.value(message.tool.call_id.slice(), .{}, out);
    }
    if (message == .assistant) {
        var wrote_calls = false;
        for (message.assistant.content) |block| {
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

fn writeTextContent(out: *std.Io.Writer, gpa: std.mem.Allocator, blocks: []const ai.ContentBlock) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    for (blocks) |block| {
        switch (block) {
            .text => |text| try aw.writer.writeAll(text.text),
            .reasoning, .image, .tool_call => {},
        }
    }
    const text = aw.written();
    // Ensure the tool/history text we send is valid UTF-8. Some MCP/tool
    // results can contain stray bytes; replace invalid sequences rather
    // than sending a malformed JSON string that providers reject.
    if (!std.unicode.utf8ValidateSlice(text)) {
        const repaired = try gpa.alloc(u8, text.len * 4);
        errdefer gpa.free(repaired);
        var i: usize = 0;
        var j: usize = 0;
        while (i < text.len) {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + len <= text.len and std.unicode.utf8ValidateSlice(text[i..][0..len])) {
                @memcpy(repaired[j..][0..len], text[i..][0..len]);
                j += len;
            } else {
                // replacement character for invalid sequence
                repaired[j] = 0xef;
                repaired[j + 1] = 0xbf;
                repaired[j + 2] = 0xbd;
                j += 3;
            }
            i += len;
        }
        try std.json.Stringify.value(repaired[0..j], .{}, out);
    } else {
        try std.json.Stringify.value(text, .{}, out);
    }
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
    try std.json.Stringify.value(tool_call.call_id.slice(), .{}, out);
    try out.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(tool_call.name, .{}, out);
    try out.writeAll(",\"arguments\":");
    const args = stream_parser.sanitizeToolArguments(tool_call.arguments);
    try std.json.Stringify.value(args, .{}, out);
    try out.writeAll("}}");
}

fn writeRequestPayload(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    model: []const u8,
    session_id: []const u8,
    messages: []const ai.MessageView,
    tools_json: []const u8,
    reasoning: ?ai.Reasoning,
    max_output_tokens: ?u32,
    dialect: ai.WireDialect,
) !void {
    std.debug.assert(model.len > 0);
    std.debug.assert(tools_json.len > 0);

    try out.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, out);
    try out.writeAll(",\"messages\":[");
    for (messages, 0..) |*view, index| {
        if (index > 0) try out.writeByte(',');
        try writeMessage(out, gpa, view.message().*, dialect);
    }
    // `stream_options.include_usage` makes the server emit a final usage-only
    // chunk (empty `choices`) before `[DONE]`. Without it, streaming responses
    // carry no token counts. Some OpenAI-compatible servers ignore it, so the
    // parser treats usage as optional.
    try out.writeAll("],\"stream\":true,\"stream_options\":{\"include_usage\":true}");
    if (max_output_tokens) |mot| {
        try out.writeAll(",\"max_tokens\":");
        try out.print("{d}", .{mot});
    }
    if (!std.mem.eql(u8, tools_json, "[]")) {
        try out.writeAll(",\"tools\":");
        try out.writeAll(tools_json);
        try out.writeAll(",\"tool_choice\":\"auto\"");
    } else {
        logger.log("openai_compatible: sending request with NO tools (tools_json is empty)", .{});
    }
    // Standard OpenAI cache-routing hint: steers requests sharing this session's
    // prefix to the same backend, raising prefix-cache hit rates (used by
    // gateways like OpenCode Zen; servers that don't support it, e.g. Ollama,
    // reject the unknown field with 400).
    if (session_id.len > 0 and dialect.allowsPromptCacheKey()) {
        try out.writeAll(",\"prompt_cache_key\":");
        try std.json.Stringify.value(session_id, .{}, out);
    }
    const effort = if (reasoning) |value| value.effort else null;
    const value = effort orelse {
        try out.writeByte('}');
        return;
    };

    switch (value) {
        .default => {
            // Model's own default — don't send any reasoning parameter.
            try out.writeByte('}');
            return;
        },
        .none => {
            if (dialect.usesEnableThinking()) {
                try out.writeAll(",\"enable_thinking\":false}");
            } else {
                try out.writeAll(",\"reasoning_effort\":\"none\"}");
            }
        },
        else => {
            try out.writeAll(",\"reasoning_effort\":\"");
            try out.writeAll(value.label());
            try out.writeAll("\"}");
        },
    }
}

test "buildToolsJson produces a valid JSON array for the registry" {
    const tools = @import("../tools.zig");
    const gpa = std.testing.allocator;
    const json = try tool_schema.buildAllToolsJson(gpa, tools.builtinRegistry(), &.{}, null, true, .completions);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Shell command to run.") != null);
}

test "buildToolsJson substitutes {{hsep}} placeholders with ~" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "demo",
            .description = "uses {{hsep}} marker",
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, false, .completions);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "uses ~ marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "{{hsep}}") == null);
}

test "buildAllToolsJson includes MCP tools alongside builtin tools" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "bash",
            .description = "Run shell commands",
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        },
    };
    const mcp_tools = [_]ai.McpToolSchema{
        .{
            .name = "mcp__server__greet",
            .description = "Say hello",
            .schema = .{ .properties = &.{} },
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &mcp_tools, null, false, .completions);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"mcp__server__greet\"") != null);
}

test "buildAllToolsJson via updateMcpTools: registry builtin suppresses duplicate bash" {
    // Regression: the tick-driven `injectAllTools` path used to call
    // `updateMcpTools(mcp_tools, registry)` without an override, so
    // `buildAllToolsJson` would emit bash twice — once from
    // `self.config.tools` and again from `r.all.builtin`. Most
    // OpenAI-compatible APIs reject duplicate tool names with HTTP 400,
    // dropping the entire tool list including the plugin tools.
    const gpa = std.testing.allocator;

    // Build a minimal Client with just a bash builtin in `config.tools`.
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "https://example.invalid",
        .api_key = "test-key",
        .model = "test-model",
        .tools = tools_mod.builtinRegistry(),
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
    });
    defer client.deinit();

    // Build a registry with a plugin tool; its builtin is bash too.
    const reg = try gpa.create(tools_mod.ToolRegistry);
    defer {
        reg.deinit(gpa);
        gpa.destroy(reg);
    }
    reg.* = tools_mod.ToolRegistry.init(tools_mod.builtinRegistry());
    // Ownership of `plugin_name` and `plugin_desc` transfers to the
    // registry via addPluginTool; registry.deinit frees them.
    const plugin_name = try gpa.dupe(u8, "lua__p__t");
    const plugin_desc = try gpa.dupe(u8, "plugin tool");
    try reg.addPluginTool(gpa, .{
        .name = plugin_name,
        .description = plugin_desc,
        .schema = .{ .properties = &.{} },
        .run = undefined,
        .display = undefined,
    });

    // The fix: pass &.{} as builtin_override so config.tools isn't
    // emitted alongside the registry's builtin (which already has it).
    try client.updateMcpTools(&.{}, reg, &.{});

    const json = client.tools_json;
    var first: ?usize = null;
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, json, idx, "\"name\":\"bash\"")) |pos| {
        if (first == null) first = pos;
        count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"lua__p__t\"") != null);
}

test "updateMcpTools propagates plugin tools into tools_json end-to-end" {
    // End-to-end regression for the user-reported "plugin tools not
    // visible to AI" bug. We simulate the exact call site:
    //   attachOpenAiCompatibleClient → injectPluginTools → injectAllTools →
    //   runtime.client.updateMcpTools(mcp_schemas, registry, &.{}).
    // After the call, `client.tools_json` must contain every plugin
    // tool's name so the next prompt includes them.
    const gpa = std.testing.allocator;

    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "https://example.invalid",
        .api_key = "test-key",
        .model = "test-model",
        .tools = tools_mod.builtinRegistry(),
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
    });
    defer client.deinit();

    // Build a registry carrying two plugin tools, exactly the way
    // registerPluginTools would after initRuntime runs.
    const reg = try gpa.create(tools_mod.ToolRegistry);
    defer {
        reg.deinit(gpa);
        gpa.destroy(reg);
    }
    reg.* = tools_mod.ToolRegistry.init(tools_mod.builtinRegistry());

    for ([_][]const u8{ "lua__hello-world__greet", "lua__hello-world__current_time" }) |tool_name| {
        const owned_name = try gpa.dupe(u8, tool_name);
        const owned_desc = try gpa.dupe(u8, "test");
        try reg.addPluginTool(gpa, .{
            .name = owned_name,
            .description = owned_desc,
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        });
    }

    // The exact call shape from injectAllTools.
    try client.updateMcpTools(&.{}, reg, &.{});

    const json = client.tools_json;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"lane\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"lua__hello-world__greet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"lua__hello-world__current_time\"") != null);

    // And the count of name occurrences must be exactly 4 (no duplicate
    // bash/lane, no dropped plugin tools).
    var name_count: usize = 0;
    var scan_idx: usize = 0;
    while (std.mem.indexOfPos(u8, json, scan_idx, "\"name\":\"")) |pos| {
        name_count += 1;
        scan_idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 4), name_count);
}

test "buildToolsJson emits strict schema with nullable union types for optional fields" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "demo",
            .description = "Demo tool with mixed required/optional fields",
            .schema = .{
                .properties = &.{
                    .{ .name = "required_str", .kind = .string, .description = "Required string", .required = true, .nullable = false },
                    .{ .name = "optional_str", .kind = .string, .description = "Optional string", .required = false, .nullable = true },
                    .{ .name = "optional_int", .kind = .integer, .description = "Optional int", .required = false, .nullable = true },
                    .{ .name = "optional_bool", .kind = .boolean, .description = "Optional bool", .required = false, .nullable = true },
                    .{ .name = "optional_obj", .kind = .object, .description = "Optional object", .required = false, .nullable = true },
                    .{ .name = "optional_arr", .kind = .array, .description = "Optional array", .required = false, .nullable = true },
                    .{ .name = "non_nullable_str", .kind = .string, .description = "Non-nullable string", .required = true, .nullable = false },
                },
            },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, true, .completions);
    defer gpa.free(json);

    // Top-level strict marker and top-level additionalProperties:false
    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"additionalProperties\":false") != null);

    // Non-nullable required field stays as a single type string
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required_str\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"non_nullable_str\":{\"type\":\"string\"") != null);

    // Nullable optional fields become union type arrays
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_str\":{\"type\":[\"string\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_int\":{\"type\":[\"integer\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_bool\":{\"type\":[\"boolean\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_obj\":{\"type\":[\"object\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_arr\":{\"type\":[\"array\",\"null\"]") != null);

    // Nested object keeps additionalProperties:true for free-form keys
    try std.testing.expect(std.mem.indexOf(u8, json, "\"additionalProperties\":true") != null);

    // Required array includes ALL properties for strict mode compliance.
    // Optional fields are marked nullable so the model knows they can be absent.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"required_str\",\"optional_str\",\"optional_int\",\"optional_bool\",\"optional_obj\",\"optional_arr\",\"non_nullable_str\"]") != null);
    // Optional fields appear in properties.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_str\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_int\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_bool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_obj\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_arr\"") != null);
}

test "buildToolsJson omits strict mode and filters required when strict is false (gateway compatibility)" {
    // Regression for the "model emits tool calls as plain text" bug:
    // gateways (OpenRouter/Ollama/vLLM) reject or silently break OpenAI
    // strict structured-outputs mode, which disables function-calling.
    // With strict=false the schema must (a) NOT carry "strict":true and
    // (b) list only genuinely-required properties in `required`.
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "demo",
            .description = "Demo",
            .schema = .{
                .properties = &.{
                    .{ .name = "required_str", .kind = .string, .description = "Required", .required = true, .nullable = false },
                    .{ .name = "optional_str", .kind = .string, .description = "Optional", .required = false, .nullable = true },
                    .{ .name = "optional_int", .kind = .integer, .description = "Optional", .required = false, .nullable = true },
                },
            },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, false, .completions);
    defer gpa.free(json);

    // No strict marker.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\"") == null);
    // Only the required property is required — optionals stay optional.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"required_str\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "optional_str") != null);
    // Optionals still listed in properties (nullable unions preserved).
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_str\":{\"type\":[\"string\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_int\":{\"type\":[\"integer\",\"null\"]") != null);
    // Empty `required` (no required props) is still valid JSON.
    const no_required_tools = [_]tools_common.Tool{
        .{
            .name = "noargs",
            .description = "No args",
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        },
    };
    const json2 = try tool_schema.buildAllToolsJson(gpa, &no_required_tools, &.{}, null, false, .completions);
    defer gpa.free(json2);
    try std.testing.expect(std.mem.indexOf(u8, json2, "\"required\":[]") != null);
}

test "buildToolsJson preserves nested object additionalProperties for free-form env" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "bash",
            .description = "Run shell commands",
            .schema = .{
                .properties = &.{
                    .{ .name = "command", .kind = .string, .description = "Shell command", .required = true, .nullable = false },
                    .{ .name = "env", .kind = .object, .description = "Env vars", .required = false, .nullable = true },
                },
            },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, true, .completions);
    defer gpa.free(json);

    // Top-level parameters object is strict
    try std.testing.expect(std.mem.indexOf(u8, json, "\"parameters\":{\"type\":\"object\",\"additionalProperties\":false") != null);
    // Nested env object remains free-form
    try std.testing.expect(std.mem.indexOf(u8, json, "\"env\":{\"type\":[\"object\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"additionalProperties\":true") != null);
}

test "updateMcpTools rebuilds the serialized tool list in place" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "bash",
            .description = "Run shell commands",
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        },
    };
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "http://localhost:8080/v1",
        .api_key = "test-key",
        .model = "test-model",
        .tools = &tools,
        .mcp_tools = &.{},
    });
    defer client.deinit();

    // No MCP tools yet — only the builtin "bash" is serialized.
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "mcp__tavily__search") == null);

    // Injecting an MCP tool set must add it alongside the builtin tool.
    const mcp_tools = [_]ai.McpToolSchema{
        .{ .name = "mcp__tavily__search", .description = "Search the web", .schema = .{ .properties = &.{} } },
    };
    try client.updateMcpTools(&mcp_tools, null, tools_mod.builtinRegistry());
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "\"name\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "\"name\":\"mcp__tavily__search\"") != null);

    // Replacing with an empty set removes the MCP tool but keeps the builtin.
    try client.updateMcpTools(&.{}, null, tools_mod.builtinRegistry());
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "mcp__tavily__search") == null);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "\"name\":\"bash\"") != null);
}

test "writeRequestPayload disables thinking for reasoning effort none" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    // DashScope dialect uses enable_thinking:false
    try writeRequestPayload(gpa, &payload.writer, "qwen-test", "", &.{}, "[]", .{ .effort = .none }, null, .dashscope);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "writeRequestPayload uses reasoning_effort none for minimal dialect" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "ollama-model", "", &.{}, "[]", .{ .effort = .none }, null, .minimal);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "enable_thinking") == null);
}

test "writeRequestPayload emits prompt_cache_key from the session id" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "gpt-test", "session-abc", &.{}, "[]", null, null, .openai);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt_cache_key\":\"session-abc\"") != null);
}

test "writeRequestPayload omits prompt_cache_key for minimal dialect" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "ollama-model", "session-abc", &.{}, "[]", null, null, .minimal);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_key") == null);
}

test "writeRequestPayload omits prompt_cache_key when no session id is set" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "qwen-test", "", &.{}, "[]", null, null, .openai);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_key") == null);
}

test "writeRequestPayload omits tools and tool_choice when there are none" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    // The background summarizer sends no tools ("[]"); the request must not carry
    // a `tool_choice` (rejected by strict providers) or invite a tool-call reply.
    try writeRequestPayload(gpa, &payload.writer, "summarizer", "", &.{}, "[]", null, null, .minimal);
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_choice") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
}

test "writeRequestPayload keeps tools and tool_choice when tools are present" {
    const gpa = std.testing.allocator;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "agent", "", &.{}, "[{\"type\":\"function\"}]", null, null, .minimal);
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
    try writeRequestPayload(gpa, &payload.writer, "test-model", "", &views, "[{\"type\":\"function\"}]", null, null, .minimal);
    const body = payload.written();

    // The tool_call id must be a JSON string, not an object
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"call_abc123\"") != null);
    // The tool_call_id in the tool message must be a string
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"call_abc123\"") != null);
    // Negative: must NOT serialize CallId as an object
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":{\"value\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":{\"value\":") == null);
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
    var response = try stream_parser.readStream(gpa, &reader, ai.streamNoop(), &tool_call_seq, 16);
    defer response.deinit(gpa);
    try std.testing.expectEqual(@as(usize, transfer_buffer_bytes + 512), response.assistant.assistant.content[0].text.text.len);
}

test "readStream skips empty data lines without crashing" {
    const gpa = std.testing.allocator;
    // An empty `data:` keep-alive used to hit `parseStreamChunk`'s non-empty
    // assertion and panic the TUI mid-turn.
    const stream =
        "data:\n" ++
        "data: \n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n" ++
        "data: [DONE]\n";
    var reader: std.Io.Reader = .fixed(stream);
    var tool_call_seq: u64 = 0;
    var response = try stream_parser.readStream(gpa, &reader, ai.streamNoop(), &tool_call_seq, 16);
    defer response.deinit(gpa);
    try std.testing.expectEqualStrings("hi", response.assistant.assistant.content[0].text.text);
}

test "parse streaming content tolerates null prelude" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}]}
    , &content, &reasoning, &stream);

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
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const Seen = struct {
        name: []const u8 = "",
        arguments: []const u8 = "",
        index: u32 = 0,

        fn onToolDelta(ctx: *@This(), delta: ai.ToolDelta) anyerror!void {
            ctx.index = delta.index;
            ctx.name = delta.name;
            ctx.arguments = delta.arguments;
        }
        fn noopBytes(_: *@This(), _: []const u8) anyerror!void {}
        fn noopVoid(_: *@This()) anyerror!void {}
    };
    var seen: Seen = .{};
    const observer: ai.StreamObserver(Seen) = .{
        .ctx = &seen,
        .on_content = Seen.noopBytes,
        .on_reasoning = Seen.noopBytes,
        .on_tool_delta = Seen.onToolDelta,
        .on_delta_end = Seen.noopVoid,
    };

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":\"zig"}}]}}]}
    , &content, &reasoning, &stream, observer);
    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":" build\"}"}}]}}]}
    , &content, &reasoning, &stream, observer);

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
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"function":{"name":"bash","arguments":"{}"},"id":"call_1","index":0}]}}]}
    , &content, &reasoning, &stream, ai.streamNoop());

    try std.testing.expectEqual(@as(usize, 1), stream.builders.items.len);
    try std.testing.expectEqualStrings("call_1", stream.builders.items[0].id.items);
    try std.testing.expectEqualStrings("bash", stream.builders.items[0].name.items);
    try std.testing.expectEqualStrings("{}", stream.builders.items[0].arguments.items);
}

test "parse streaming tool deltas batches render notification per event" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const Seen = struct {
        tool_delta_count: u32 = 0,
        render_count: u32 = 0,

        fn onToolDelta(ctx: *@This(), _: ai.ToolDelta) anyerror!void {
            ctx.tool_delta_count += 1;
        }

        fn onDeltaEnd(ctx: *@This()) anyerror!void {
            ctx.render_count += 1;
        }
        fn noopBytes(_: *@This(), _: []const u8) anyerror!void {}
    };
    var seen: Seen = .{};
    const observer: ai.StreamObserver(Seen) = .{
        .ctx = &seen,
        .on_content = Seen.noopBytes,
        .on_reasoning = Seen.noopBytes,
        .on_tool_delta = Seen.onToolDelta,
        .on_delta_end = Seen.onDeltaEnd,
    };

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":\"pwd\"}"}},{"index":1,"id":"call_2","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]}}]}
    , &content, &reasoning, &stream, observer);

    try std.testing.expectEqual(@as(u32, 2), seen.tool_delta_count);
    try std.testing.expectEqual(@as(u32, 1), seen.render_count);
}

test "parse streaming reasoning deltas as they arrive" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const Seen = struct {
        gpa: std.mem.Allocator,
        reasoning: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.reasoning.deinit(self.gpa);
        }

        fn onReasoning(ctx: *@This(), delta: []const u8) anyerror!void {
            try ctx.reasoning.appendSlice(ctx.gpa, delta);
        }
        fn noopBytes(_: *@This(), _: []const u8) anyerror!void {}
        fn noopToolDelta(_: *@This(), _: ai.ToolDelta) anyerror!void {}
        fn noopVoid(_: *@This()) anyerror!void {}
    };
    var seen: Seen = .{ .gpa = gpa };
    defer seen.deinit();
    const observer: ai.StreamObserver(Seen) = .{
        .ctx = &seen,
        .on_content = Seen.noopBytes,
        .on_reasoning = Seen.onReasoning,
        .on_tool_delta = Seen.noopToolDelta,
        .on_delta_end = Seen.noopVoid,
    };

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"reasoning_content":"checking output"}}]}
    , &content, &reasoning, &stream, observer);

    try std.testing.expectEqualStrings("checking output", seen.reasoning.items);
    try std.testing.expectEqualStrings("checking output", reasoning.items);
}

test "parse streaming content deltas as they arrive" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const Seen = struct {
        gpa: std.mem.Allocator,
        content: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.content.deinit(self.gpa);
        }

        fn onContent(ctx: *@This(), delta: []const u8) anyerror!void {
            try ctx.content.appendSlice(ctx.gpa, delta);
        }
        fn noopBytes(_: *@This(), _: []const u8) anyerror!void {}
        fn noopToolDelta(_: *@This(), _: ai.ToolDelta) anyerror!void {}
        fn noopVoid(_: *@This()) anyerror!void {}
    };
    var seen: Seen = .{ .gpa = gpa };
    defer seen.deinit();
    const observer: ai.StreamObserver(Seen) = .{
        .ctx = &seen,
        .on_content = Seen.onContent,
        .on_reasoning = Seen.noopBytes,
        .on_tool_delta = Seen.noopToolDelta,
        .on_delta_end = Seen.noopVoid,
    };

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"content":"hel"}}]}
    , &content, &reasoning, &stream, observer);
    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"content":"lo"}}]}
    , &content, &reasoning, &stream, observer);

    try std.testing.expectEqualStrings("hello", seen.content.items);
    try std.testing.expectEqualStrings("hello", content.items);
}

test "parse streaming usage chunk" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":340,"total_tokens":1540}}
    , &content, &reasoning, &stream);

    try std.testing.expect(change.usage != null);
    try std.testing.expectEqual(@as(u32, 1200), change.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u32, 340), change.usage.?.output_tokens);
    try std.testing.expectEqual(@as(u32, 1540), change.usage.?.total_tokens);
}

test "content chunk carries null usage" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"content":"hi"}}],"usage":null}
    , &content, &reasoning, &stream);

    try std.testing.expect(change.usage == null);
}

test "parse streaming tool calls deduplicates repeated tool names (bashbash fix)" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]}}]}
    , &content, &reasoning, &stream);

    // Second chunk repeats function.name: "bash" while sending argument continuation
    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"\"}"}}]}}]}
    , &content, &reasoning, &stream);

    try std.testing.expectEqual(@as(usize, 1), stream.builders.items.len);
    try std.testing.expectEqualStrings("bash", stream.builders.items[0].name.items);
    try std.testing.expectEqualStrings("call_1", stream.builders.items[0].id.items);
}

test "sanitizeToolArguments strips markdown backticks and falls back to empty object" {
    try std.testing.expectEqualStrings("{}", stream_parser.sanitizeToolArguments(""));
    try std.testing.expectEqualStrings("{}", stream_parser.sanitizeToolArguments("   "));
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", stream_parser.sanitizeToolArguments("{\"command\":\"ls\"}"));
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", stream_parser.sanitizeToolArguments("```json\n{\"command\":\"ls\"}\n```"));
    try std.testing.expectEqualStrings("{}", stream_parser.sanitizeToolArguments("not a json string"));
}

test "parse streaming parallel tool calls with reused index does not concatenate names" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    // Provider emits two parallel tool calls in separate SSE events, both
    // with index 0 (a known misbehaviour from some OpenAI-compatible providers).
    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"mcp__server__get_architecture","arguments":"{}"}}]}}]}
    , &content, &reasoning, &stream);

    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_2","function":{"name":"mcp__server__search_graph","arguments":"{}"}}]}}]}
    , &content, &reasoning, &stream);

    // Queue mechanism forks the second tool call into a new physical slot.
    // Both tool calls are preserved — names must NOT be concatenated.
    try std.testing.expectEqual(@as(usize, 2), stream.builders.items.len);
    try std.testing.expectEqualStrings("mcp__server__get_architecture", stream.builders.items[0].name.items);
    try std.testing.expectEqualStrings("call_1", stream.builders.items[0].id.items);
    try std.testing.expectEqualStrings("mcp__server__search_graph", stream.builders.items[1].name.items);
    try std.testing.expectEqualStrings("call_2", stream.builders.items[1].id.items);
}

test "parse streaming duplicate ID across indices merges into one builder" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    // Qwen/DashScope echoes the same tool-call ID across multiple indices.
    // The first chunk carries the name at index 0; a duplicate arrives at
    // index 1 with the same ID. Arguments follow on index 0.
    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":""}}]}}]}
    , &content, &reasoning, &stream);

    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_1","function":{"name":"bash","arguments":""}}]}}]}
    , &content, &reasoning, &stream);

    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":\"ls\"}"}}]}}]}
    , &content, &reasoning, &stream);

    // Index 1 is remapped to the same physical slot as index 0.
    // Only one builder should carry the name + arguments.
    var with_args: usize = 0;
    for (stream.builders.items) |b| {
        if (b.name.items.len > 0 and b.arguments.items.len > 0) with_args += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), with_args);
    try std.testing.expectEqualStrings("bash", stream.builders.items[0].name.items);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", stream.builders.items[0].arguments.items);
}

// ── Retry / backoff ───────────────────────────────────────────────────────

test "parseRetryAfterSeconds extracts integer seconds from a head" {
    try std.testing.expectEqual(@as(?u64, 5), parseRetryAfterSeconds("HTTP/1.1 429 Too Many Requests\r\nRetry-After: 5\r\nContent-Length: 0\r\n\r\n"));
    // Header name is case-insensitive.
    try std.testing.expectEqual(@as(?u64, 2), parseRetryAfterSeconds("HTTP/1.1 503 Service Unavailable\r\nretry-after: 2\r\n\r\n"));
    // Missing header → null.
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds("HTTP/1.1 200 OK\r\n\r\n"));
    // HTTP-date value → null (integer seconds only, per scope).
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds("HTTP/1.1 429 Too Many Requests\r\nRetry-After: Wed, 21 Oct 2026 07:28:00 GMT\r\n\r\n"));
}

test "retryDelayMs honors Retry-After over backoff and caps exponential growth" {
    const gpa = std.testing.allocator;
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "http://127.0.0.1:1/v1",
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
    });
    defer client.deinit();

    // Retry-After wins regardless of the attempt count.
    try std.testing.expectEqual(@as(u64, 3000), client.retryDelayMs(0, 3));
    try std.testing.expectEqual(@as(u64, 3000), client.retryDelayMs(5, 3));
    // Without the header: base * 2^attempt, capped at 8000ms.
    try std.testing.expectEqual(@as(u64, 500), client.retryDelayMs(0, null));
    try std.testing.expectEqual(@as(u64, 1000), client.retryDelayMs(1, null));
    try std.testing.expectEqual(@as(u64, 2000), client.retryDelayMs(2, null));
    try std.testing.expectEqual(@as(u64, 4000), client.retryDelayMs(3, null));
    try std.testing.expectEqual(@as(u64, 8000), client.retryDelayMs(4, null)); // capped
    try std.testing.expectEqual(@as(u64, 8000), client.retryDelayMs(10, null)); // stays capped
}

/// Minimal blocking HTTP server for retry tests. Serves exactly one canned
/// response per accepted connection (each `Connection: close`), on a
/// dedicated thread. The ephemeral port comes from `server.socket.address`.
const MockRetryServer = struct {
    const Response = struct {
        status: std.http.Status,
        retry_after: ?[]const u8 = null,
        body: []const u8 = "",
    };

    io: std.Io,
    server: std.Io.net.Server,
    responses: []const Response,
    connection_count: std.atomic.Value(u32) = .init(0),

    fn init(io: std.Io, responses: []const Response) !MockRetryServer {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = try addr.listen(io, .{ .reuse_address = true });
        return .{ .io = io, .server = server, .responses = responses };
    }

    fn deinit(self: *MockRetryServer) void {
        self.server.deinit(self.io);
    }

    fn port(self: *const MockRetryServer) u16 {
        return self.server.socket.address.ip4.port;
    }

    fn serve(self: *MockRetryServer) void {
        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        for (self.responses) |resp| {
            var stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            _ = self.connection_count.fetchAdd(1, .monotonic);
            var reader = stream.reader(self.io, &read_buf);
            var writer = stream.writer(self.io, &write_buf);
            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = http_server.receiveHead() catch return;
            var extra: [1]std.http.Header = undefined;
            const headers: []const std.http.Header = if (resp.retry_after) |ra| blk: {
                extra[0] = .{ .name = "Retry-After", .value = ra };
                break :blk &extra;
            } else &.{};
            request.respond(resp.body, .{
                .status = resp.status,
                .keep_alive = false,
                .extra_headers = headers,
            }) catch return;
        }
    }
};

const ok_sse_body =
    "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n" ++
    "data: [DONE]\n";

fn retryTestClient(gpa: std.mem.Allocator, io: std.Io, port: u16) !Client {
    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1", .{port});
    errdefer gpa.free(base_url);
    var client: Client = undefined;
    try client.init(gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        // No sleeping between retries in tests.
        .retry_base_delay_ms = 0,
    });
    // `init` deep-copies the config (including the request URL) — the
    // temporary base_url is not retained, so free it.
    gpa.free(base_url);
    return client;
}

test "prompt retries a transient 503 and succeeds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockRetryServer.init(io, &.{
        .{ .status = .service_unavailable },
        .{ .status = .ok, .body = ok_sse_body },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    var client = try retryTestClient(gpa, io, server.port());
    defer client.deinit();

    var turn = try client.prompt(&.{}, ai.streamNoop());
    defer turn.deinit(gpa);
    // Two connections: the failed 503 attempt plus the successful retry.
    try std.testing.expectEqual(@as(u32, 2), server.connection_count.load(.monotonic));
    try std.testing.expectEqualStrings("hi", turn.assistant.assistant.content[0].text.text);
}

test "prompt retries a 429 and honors Retry-After" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockRetryServer.init(io, &.{
        .{ .status = .too_many_requests, .retry_after = "0" },
        .{ .status = .ok, .body = ok_sse_body },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    var client = try retryTestClient(gpa, io, server.port());
    defer client.deinit();

    var turn = try client.prompt(&.{}, ai.streamNoop());
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), server.connection_count.load(.monotonic));
    try std.testing.expectEqualStrings("hi", turn.assistant.assistant.content[0].text.text);
}

test "prompt does not retry a permanent 4xx" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockRetryServer.init(io, &.{
        .{ .status = .bad_request },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    var client = try retryTestClient(gpa, io, server.port());
    defer client.deinit();

    try std.testing.expectError(error.HttpClientError, client.prompt(&.{}, ai.streamNoop()));
    // Exactly one attempt — 4xx is permanent.
    try std.testing.expectEqual(@as(u32, 1), server.connection_count.load(.monotonic));
}

test "prompt with max_retries 0 makes a single attempt on a transient 5xx" {
    // Kill-switch regression: max_retries = 0 must reproduce the legacy
    // single-attempt behavior even for otherwise-retryable 5xx errors.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockRetryServer.init(io, &.{
        .{ .status = .internal_server_error },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1", .{server.port()});
    defer gpa.free(base_url);
    var client: Client = undefined;
    try client.init(gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .max_retries = 0,
    });
    defer client.deinit();

    try std.testing.expectError(error.HttpServerError, client.prompt(&.{}, ai.streamNoop()));
    try std.testing.expectEqual(@as(u32, 1), server.connection_count.load(.monotonic));
}

test "prompt exhausts retries on a persistent 5xx" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Default max_retries = 2 → three attempts total.
    var server = try MockRetryServer.init(io, &.{
        .{ .status = .internal_server_error },
        .{ .status = .internal_server_error },
        .{ .status = .internal_server_error },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    var client = try retryTestClient(gpa, io, server.port());
    defer client.deinit();

    try std.testing.expectError(error.HttpServerError, client.prompt(&.{}, ai.streamNoop()));
    try std.testing.expectEqual(@as(u32, 3), server.connection_count.load(.monotonic));
}
