//! Client implementation for the OpenAI Responses API.
//!
//! Subsystem modularization: request serialization lives in `responses_request.zig`
//! and SSE event decoding lives in `responses_events.zig`.
const os = @import("../os.zig");
const transport_mod = @import("transport.zig");

const std = @import("std");
const log = std.log.scoped(.ai);

const ai = @import("../ai.zig");
const http = @import("../http.zig");
const openai_endpoint = @import("openai_endpoint.zig");
const openai_compatible = @import("openai_compatible.zig");
const provider_headers = @import("provider_headers.zig");
const stream_part = @import("stream_part.zig");
const tool_schema = @import("tool_schema.zig");
const tools_common = @import("../tools/common.zig");
const tools_mod = @import("../tools.zig");

pub const responses_request = @import("responses_request.zig");
pub const responses_events = @import("responses_events.zig");

// Re-exports for backwards compatibility
pub const writeRequestPayload = responses_request.writeRequestPayload;
pub const StreamState = responses_events.StreamState;
pub const ToolBuilder = responses_events.ToolBuilder;
pub const processEvent = responses_events.processEvent;
pub const parseResponseUsage = responses_events.parseResponseUsage;
pub const ResponseEvent = responses_events.ResponseEvent;
pub const ResponseEventSpec = responses_events.ResponseEventSpec;
pub const response_event_specs = responses_events.response_event_specs;
pub const responseEventFromString = responses_events.responseEventFromString;

/// Upper bound on an error body we will decompress + log (matches the
/// chat-completions client's cap). Prevents a hostile/garbage body from
/// allocating unboundedly.
const response_bytes_max: u32 = 1 * 1024 * 1024;

pub const ResponsesConfig = struct {
    // Transport-protocol header specs, unified with the provider-header
    // vocabulary in `provider_headers.zig` (INV-RESP-1 sibling leaf).
    pub const HeaderValue = provider_headers.HeaderValue;
    pub const Header = provider_headers.Header;

    pub const BaseUrlMode = enum { openai_v1, raw };

    base_url_mode: BaseUrlMode = .openai_v1,
    endpoint_path: []const u8 = "/responses",
    /// Static profile table (codex handshake set); borrowed for the
    /// client's lifetime, so it must reference permanent storage — the
    /// owned, dynamic channel is `Client.provider_headers_owned`.
    headers: []const Header = &.{},
    user_agent: ?[]const u8 = null,
    text_verbosity: ?[]const u8 = null,
    parallel_tool_calls: ?bool = null,
    /// Request `reasoning.encrypted_content` in the include array. Keep true
    /// for the plain Responses API (stateless replay needs the blob). The
    /// ChatGPT Codex backend rejects replayed encrypted reasoning items with
    /// a confusing 400 ("expected an object, but got an integer"), and
    /// upstream clients never re-send them (openai/codex#25290, pi#6023) —
    /// so this transport opts out and relies on summaries only.
    include_encrypted_reasoning: bool = true,
    /// Remove encrypted reasoning from replayed history before serialization.
    /// This is transport-specific and therefore independent of whether the
    /// current request asks the server to include encrypted reasoning.
    scrub_encrypted_reasoning: bool = false,
    log_name: []const u8 = "standard",
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: ai.Config,
    url: []u8,
    authorization: []u8,
    tools_json: []u8,
    /// Whether tool definitions carry OpenAI strict structured-outputs mode.
    /// Captured at `init` so `updateMcpTools` can rebuild `tools_json`
    /// consistently. Default `false` — strict mode is OpenAI-only and breaks
    /// function-calling on gateways (OpenRouter/Ollama/vLLM).
    strict: bool = false,
    responses_config: ResponsesConfig,
    /// Owned copy of `ai.Config.headers` (auto provider headers merged with
    /// the user's, precedence already resolved at attach time). Materialized
    /// per request by the transport alongside the static profile table.
    provider_headers_owned: []provider_headers.Header = &.{},
    call_seq: u64 = 0,
    /// The shared send pipeline: request construction, retry budget, C2
    /// downgrade, head/error classification, error-detail recording.
    transport: transport_mod.Transport = undefined,

    pub fn init(target: *Client, gpa: std.mem.Allocator, io: std.Io, config: ai.Config, responses_config: ResponsesConfig) !void {
        if (config.base_url.len == 0) return error.EmptyBaseUrl;
        if (config.model.len == 0) return error.EmptyModelId;
        const url = try responsesUrl(gpa, config.base_url, responses_config);
        errdefer gpa.free(url);
        const authorization = try std.fmt.allocPrint(gpa, "{s}{s}", .{ http.bearer_prefix, config.api_key });
        errdefer gpa.free(authorization);
        var owned_config = config;
        owned_config.base_url = "";
        owned_config.api_key = "";
        // Borrowed at init; the deep copy lives in provider_headers_owned.
        // Blank it like base_url/api_key so no future read dangles after the
        // attach frame (which owns the specs) returns.
        owned_config.headers = &.{};
        owned_config.model = try gpa.dupe(u8, config.model);
        errdefer gpa.free(owned_config.model);
        owned_config.account_id = try gpa.dupe(u8, config.account_id);
        errdefer gpa.free(owned_config.account_id);
        owned_config.session_id = try gpa.dupe(u8, config.session_id);
        errdefer gpa.free(owned_config.session_id);
        owned_config.system_prompt = try gpa.dupe(u8, config.system_prompt);
        errdefer gpa.free(owned_config.system_prompt);
        const tools_json = try tool_schema.buildAllToolsJson(gpa, config.tools, config.mcp_tools, null, config.strict, .responses);
        errdefer gpa.free(tools_json);
        const provider_headers_owned = try provider_headers.cloneHeaders(gpa, config.headers);
        errdefer provider_headers.freeHeaders(gpa, provider_headers_owned);
        target.* = .{
            .gpa = gpa,
            .io = io,
            .config = owned_config,
            .url = url,
            .authorization = authorization,
            .tools_json = tools_json,
            .strict = config.strict,
            .responses_config = responses_config,
            .provider_headers_owned = provider_headers_owned,
        };
        target.transport = undefined;
        target.transport.init(gpa, io);
        // Borrowed identity: every slice here is owned by this Client, so it
        // outlives the transport and every request it sends.
        target.transport.url = target.url;
        target.transport.authorization = target.authorization;
        target.transport.profile_headers = responses_config.headers;
        target.transport.provider_headers = target.provider_headers_owned;
        // Borrowed like the profile table: ResponsesConfig.user_agent must
        // reference permanent storage, and the codex profile's "zay" identity
        // is load-bearing (chatgpt.com backend 403s unknown clients).
        target.transport.user_agent = responses_config.user_agent;
        target.transport.header_context = .{
            .session_id = target.config.session_id,
            .account_id = target.config.account_id,
        };
        target.transport.log_tag = "responses";
        target.transport.log_context = responses_config.log_name;
        target.transport.request_timeout_seconds = config.request_timeout_seconds;
        target.transport.retry_base_delay_ms = config.retry_base_delay_ms;
        target.transport.max_retries = config.max_retries;
        target.transport.disable_cache_seed = config.disable_prompt_cache;
    }

    pub fn deinit(self: *Client) void {
        self.transport.deinit();
        self.gpa.free(self.config.model);
        self.gpa.free(self.config.account_id);
        self.gpa.free(self.config.session_id);
        self.gpa.free(self.config.system_prompt);
        self.gpa.free(self.tools_json);
        self.gpa.free(self.authorization);
        self.gpa.free(self.url);
        provider_headers.freeHeaders(self.gpa, self.provider_headers_owned);
        self.* = undefined;
    }

    /// Rebuild the serialized tool definitions after the MCP tool set changes.
    /// `mcp_tools` is borrowed only for the duration of the call; the result is
    /// the owned `tools_json`. Call between turns, never mid-turn.
    /// `registry`, when non-null, contributes its builtin + plugin tools so
    /// the model sees them as first-class definitions. When null, only the
    /// builtin slice (`config.tools`) is used — the legacy path used by
    /// tests that don't construct a full registry.
    ///
    /// The caller is responsible for choosing what `self.config.tools`
    /// contains at call time. `attachXxxClient` initializes it with
    /// `builtinRegistry()` so bash is present; the tick-driven
    /// `injectAllTools` path passes an empty slice because the registry's
    /// `builtin` already covers the same tool — passing both would emit
    /// duplicate definitions and most OpenAI-compatible APIs reject
    /// duplicate tool names outright (HTTP 400), dropping the entire
    /// tool list including the plugin tools the caller wants exposed.
    // Rebuild the serialized tool definitions from the final, already-deduped
    // spec list assembled by the runtime layer. Call between turns.
    pub fn updateTools(self: *Client, specs: []const tool_schema.ToolSpec) !void {
        const new_json = try tool_schema.buildToolsJson(self.gpa, specs, self.strict, .responses);
        self.gpa.free(self.tools_json);
        self.tools_json = new_json;
    }

    pub fn errorDetail(self: *const Client) ?[]const u8 {
        return self.transport.errorDetail();
    }

    /// Run one prompt through the shared transport. The payload writer is a
    /// stack struct holding a mutable config copy so the C2 downgrade is
    /// "flip one field, re-serialize"; the stream adapter is `responses_events`.
    pub fn prompt(self: *Client, messages: []const ai.MessageView, observer: anytype) !ai.Turn {
        var payload = ResponsesPayload{
            .gpa = self.gpa,
            .config = self.config,
            .responses_config = self.responses_config,
            .messages = messages,
            .tools_json = self.tools_json,
        };
        const env: stream_part.StreamEnv = .{
            .limits = .{ .max_parallel_calls = self.config.max_parallel_tool_calls, .model_label = self.config.model },
            .id_seq = &self.call_seq,
        };
        return self.transport.prompt(transport_mod.payloadSource(ResponsesPayload, &payload), observer, responses_events, env);
    }

    const ResponsesPayload = struct {
        gpa: std.mem.Allocator,
        config: ai.Config,
        responses_config: ResponsesConfig,
        messages: []const ai.MessageView,
        tools_json: []const u8,

        pub fn writePayload(self: *ResponsesPayload, out: *std.Io.Writer, disable_prompt_cache: bool) !void {
            self.config.disable_prompt_cache = disable_prompt_cache;
            return responses_request.writeRequestPayload(out, self.gpa, self.config, self.responses_config, self.messages, self.tools_json);
        }

        pub fn isToolLess(self: *ResponsesPayload) bool {
            return std.mem.eql(u8, self.tools_json, "[]");
        }
    };
};

fn responsesUrl(gpa: std.mem.Allocator, base_url: []const u8, responses_config: ResponsesConfig) ![]u8 {
    const base = std.mem.trimEnd(u8, base_url, "/");
    const root = switch (responses_config.base_url_mode) {
        .raw => try gpa.dupe(u8, base),
        .openai_v1 => try openai_endpoint.v1Root(gpa, base),
    };
    defer gpa.free(root);
    return try std.fmt.allocPrint(gpa, "{s}{s}", .{ root, responses_config.endpoint_path });
}

/// Drain a full chunked HTTP request (headers + body through the terminal
/// `0\r\n\r\n`) from a mock connection without ever blocking past it: the
/// client sends nothing after the terminator — it blocks reading the
/// response — so a blind extra read would hang the server thread and, with
/// it, the whole test. A complete drain also proves the client finished
/// sending before the mock aborts the connection.
fn drainChunkedRequest(reader: *std.Io.Reader) void {
    var req_buf: [4096]u8 = undefined;
    var req_len: usize = 0;
    while (req_len < req_buf.len) {
        // `readSliceShort` blocks until its destination is FULL — and this
        // request is smaller than any fixed buffer we could pick — so it
        // must never be handed a larger destination here. `fillMore`
        // performs exactly one blocking read, then an exactly-sized
        // `readSliceShort` copies the buffered bytes out without waiting
        // for more.
        reader.fillMore() catch break;
        const take = @min(reader.bufferedLen(), req_buf.len - req_len);
        req_len += reader.readSliceShort(req_buf[req_len..][0..take]) catch break;
        if (std.mem.indexOf(u8, req_buf[0..req_len], "\r\n\r\n") != null and
            std.mem.endsWith(u8, req_buf[0..req_len], "0\r\n\r\n")) break;
    }
}

test "prompt records last_error_detail on head-phase ReadFailed" {
    if (os.is_windows) {
        // Windows loopback close semantics: close-without-response does not
        // surface as a client read error here, so the client blocks. See
        // openai_compatible.zig's stream-phase gate note (#32).
        return error.SkipZigTest;
    }
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A mock server that accepts a connection but closes immediately
    // without sending any HTTP response. receiveHead will see ReadFailed.
    const MockCloseServer = struct {
        srv_io: std.Io,
        server: std.Io.net.Server,

        fn init(srv_io: std.Io) !@This() {
            const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
            const srv = try addr.listen(srv_io, .{ .reuse_address = true });
            return .{ .srv_io = srv_io, .server = srv };
        }

        fn deinit(self: *@This()) void {
            self.server.deinit(self.srv_io);
        }

        fn port(self: *const @This()) u16 {
            return self.server.socket.address.ip4.port;
        }

        fn serve(self: *@This()) void {
            var read_buf: [4096]u8 = undefined;
            var write_buf: [8192]u8 = undefined;
            var stream = self.server.accept(self.srv_io) catch return;
            var reader = stream.reader(self.srv_io, &read_buf);
            // Drain the request so the client can finish sending before the
            // connection closes. This makes the failure occur in
            // `receiveHead`, rather than nondeterministically during upload.
            drainChunkedRequest(&reader.interface);
            // Send an incomplete status line after the upload. This makes the
            // client fail while receiving the response head, rather than
            // racing the request upload against a closed socket.
            var writer = stream.writer(self.srv_io, &write_buf);
            writer.interface.writeAll("HTTP/1.1 200") catch return;
            writer.interface.flush() catch return;
            stream.close(self.srv_io);
        }
    };

    var server = try MockCloseServer.init(io);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockCloseServer.serve, .{&server});
    defer thread.join();

    // `Client.init` copies what it keeps and clears `base_url` in its owned
    // config — the temporary string stays ours to free.
    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(base_url);
    var client: Client = undefined;
    // `max_retries = 0`: this test verifies error-detail recording on a head
    // phase drop, not the retry loop. The mock accepts a single connection, so
    // leaving the default budget (2) would make attempt 2 block on a connection
    // the server never accepts.
    try Client.init(&client, gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
        .max_retries = 0,
    }, .{});
    defer client.deinit();

    try std.testing.expectError(error.ConnectionFailed, client.prompt(&.{}, ai.streamNoop()));
    const detail = client.errorDetail() orelse @panic("expected a recorded error detail on head-phase ReadFailed");
    try std.testing.expect(std.mem.startsWith(u8, detail, "Connection to the model provider was lost:"));
}

test "prompt records last_error_detail on stream-phase ReadFailed" {
    if (os.is_windows) {
        // Truncation-class gate — see openai_compatible.zig (#32).
        return error.SkipZigTest;
    }
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A mock server that sends a valid HTTP 200 head with SSE content-type,
    // sends partial SSE data, then closes abruptly.
    const MockAbortServer = struct {
        srv_io: std.Io,
        server: std.Io.net.Server,

        fn init(srv_io: std.Io) !@This() {
            const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
            const srv = try addr.listen(srv_io, .{ .reuse_address = true });
            return .{ .srv_io = srv_io, .server = srv };
        }

        fn deinit(self: *@This()) void {
            self.server.deinit(self.srv_io);
        }

        fn port(self: *const @This()) u16 {
            return self.server.socket.address.ip4.port;
        }

        fn serve(self: *@This()) void {
            var read_buf: [4096]u8 = undefined;
            var write_buf: [8192]u8 = undefined;
            var stream = self.server.accept(self.srv_io) catch return;
            defer stream.close(self.srv_io);
            var reader = stream.reader(self.srv_io, &read_buf);
            var writer = stream.writer(self.srv_io, &write_buf);
            // Drain the FULL request (headers + chunked body through the
            // terminal `0\r\n\r\n`); see drainChunkedRequest for why a blind
            // extra read past it would hang the test.
            drainChunkedRequest(&reader.interface);
            // Send a 200 OK response with SSE content-type.
            writer.interface.writeAll("HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/event-stream\r\n" ++
                "Transfer-Encoding: chunked\r\n" ++
                "\r\n") catch return;
            // Send one chunk of SSE data (Responses API format).
            const chunk = "event: response.output_text.delta\ndata: {\"delta\":\"hi\"}\n\n";
            var hex_buf: [16]u8 = undefined;
            const hex = std.fmt.bufPrint(&hex_buf, "{x}\r\n", .{chunk.len}) catch return;
            writer.interface.writeAll(hex) catch return;
            writer.interface.writeAll(chunk) catch return;
            writer.interface.writeAll("\r\n") catch return;
            // A malformed chunk header breaks the client's chunked decoder
            // mid-body — std maps that to a stream-phase `error.ReadFailed`
            // with `body_err` set. An abortive RST would mimic a real-world
            // drop more closely, but `Io.Threaded` hands out AFD handles on
            // Windows, which `setsockopt`(SO_LINGER) rejects — a
            // protocol-level abort is the portable way to exercise the same
            // client capture path.
            writer.interface.writeAll("ZZ\r\n") catch return;
            writer.interface.flush() catch return;
        }
    };

    var server = try MockAbortServer.init(io);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockAbortServer.serve, .{&server});
    defer thread.join();

    // `Client.init` copies what it keeps and clears `base_url` in its owned
    // config — the temporary string stays ours to free.
    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(base_url);
    var client: Client = undefined;
    try Client.init(&client, gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
    }, .{});
    defer client.deinit();

    try std.testing.expectError(error.ReadFailed, client.prompt(&.{}, ai.streamNoop()));
    const detail = client.errorDetail() orelse @panic("expected a recorded error detail on stream-phase ReadFailed");
    try std.testing.expect(std.mem.startsWith(u8, detail, "Connection to the model provider was lost:"));
}

// A valid, completed Responses-API stream (empty output) the mock serves on
// the final attempt. `response.completed` flips the completed flag so `finish`
// succeeds; no output items are needed for a valid Turn.
const ok_responses_sse_body =
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\"}\n\n";

/// Mock that serves one canned response per accepted connection (like the
/// chat-completions client's retry tests). Each connection is `close`d after
/// the response so the client reconnects for the next attempt. Captures each
/// connection's request body so tests can assert on the re-serialized payload
/// (the C2 cache downgrade re-sends a stripped body).
const MockResponsesRetryServer = struct {
    const Response = struct {
        status: std.http.Status,
        retry_after: ?[]const u8 = null,
        body: []const u8 = "",
    };

    gpa: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    responses: []const Response,
    connection_count: std.atomic.Value(u32) = .init(0),
    /// Request body per captured connection (index = connection number).
    captured: [8]?[]u8 = .{null} ** 8,

    fn init(gpa: std.mem.Allocator, io: std.Io, responses: []const Response) !@This() {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = try addr.listen(io, .{ .reuse_address = true });
        return .{ .gpa = gpa, .io = io, .server = server, .responses = responses };
    }

    fn deinit(self: *@This()) void {
        for (self.captured) |maybe_body| {
            if (maybe_body) |body| self.gpa.free(body);
        }
        self.server.deinit(self.io);
    }

    fn port(self: *const @This()) u16 {
        return self.server.socket.address.ip4.port;
    }

    fn serve(self: *@This()) void {
        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        for (self.responses) |resp| {
            var stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            const conn_index = self.connection_count.fetchAdd(1, .monotonic);
            var reader = stream.reader(self.io, &read_buf);
            var writer = stream.writer(self.io, &write_buf);
            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            // `request.respond` drains the (chunked) request body internally —
            // the client blocks reading the response after sending, so nothing
            // follows the terminal `0\r\n\r\n`.
            var request = http_server.receiveHead() catch return;
            // Capture the body BEFORE responding (respond drains what's left).
            if (conn_index < self.captured.len) {
                var body_buf: [16384]u8 = undefined;
                var body_reader = request.readerExpectNone(&body_buf);
                if (body_reader.allocRemaining(self.gpa, .limited(1024 * 1024))) |body| {
                    self.captured[conn_index] = body;
                } else |_| {}
            }
            var extra: [2]std.http.Header = undefined;
            var extra_count: usize = 0;
            if (resp.retry_after) |ra| {
                extra[extra_count] = .{ .name = "Retry-After", .value = ra };
                extra_count += 1;
            }
            request.respond(resp.body, .{
                .status = resp.status,
                .keep_alive = false,
                .extra_headers = extra[0..extra_count],
            }) catch return;
        }
    }
};

test "prompt retries a transient 503 and succeeds (Responses API)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockResponsesRetryServer.init(gpa, io, &.{
        .{ .status = .service_unavailable },
        .{ .status = .ok, .body = ok_responses_sse_body },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockResponsesRetryServer.serve, .{&server});
    defer thread.join();

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(base_url);
    var client: Client = undefined;
    try Client.init(&client, gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
        // No sleeping between retries in tests.
        .retry_base_delay_ms = 0,
    }, .{});
    defer client.deinit();

    var turn = try client.prompt(&.{}, ai.streamNoop());
    defer turn.deinit(gpa);
    // Two connections: the failed 503 attempt plus the successful retry.
    try std.testing.expectEqual(@as(u32, 2), server.connection_count.load(.monotonic));
}

test "prompt does not retry a permanent 4xx (Responses API)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockResponsesRetryServer.init(gpa, io, &.{
        .{ .status = .bad_request },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockResponsesRetryServer.serve, .{&server});
    defer thread.join();

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(base_url);
    var client: Client = undefined;
    try Client.init(&client, gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
        .retry_base_delay_ms = 0,
    }, .{});
    defer client.deinit();

    try std.testing.expectError(error.HttpClientError, client.prompt(&.{}, ai.streamNoop()));
    // Exactly one attempt — 4xx is permanent.
    try std.testing.expectEqual(@as(u32, 1), server.connection_count.load(.monotonic));
}

test "prompt downgrades to a cache-stripped payload on a cache-mentioning 400 (C2)" {
    // Regression: the C2 branch used to sit behind the retry-budget gate, but
    // `HttpClientError` is not retryable — a 400 on the FIRST attempt returned
    // immediately and the stripped re-send never happened.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockResponsesRetryServer.init(gpa, io, &.{
        .{ .status = .bad_request, .body = "{\"error\":{\"message\":\"prompt_cache_key is not accepted\"}}" },
        .{ .status = .ok, .body = ok_responses_sse_body },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockResponsesRetryServer.serve, .{&server});
    defer thread.join();

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(base_url);
    var client: Client = undefined;
    try Client.init(&client, gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
        .retry_base_delay_ms = 0,
    }, .{});
    defer client.deinit();

    // The downgrade is invisible to the caller: the 400 becomes a turn.
    var turn = try client.prompt(&.{}, ai.streamNoop());
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), server.connection_count.load(.monotonic));
    // The re-serialized payload dropped the cache field the server rejected.
    const first = server.captured[0].?;
    const second = server.captured[1].?;
    try std.testing.expect(std.mem.indexOf(u8, first, "\"prompt_cache_key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"prompt_cache_key\"") == null);
}

test "prompt records last_error_detail on an HTTP error (Responses API)" {
    // Regression: the Responses client previously dropped the error body and
    // never populated `last_error_detail`, so the UI saw no provider message.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockResponsesRetryServer.init(gpa, io, &.{
        .{ .status = .forbidden, .body = "{\"error\":{\"message\":\"invalid api key\"}}" },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockResponsesRetryServer.serve, .{&server});
    defer thread.join();

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(base_url);
    var client: Client = undefined;
    try Client.init(&client, gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
        .retry_base_delay_ms = 0,
    }, .{});
    defer client.deinit();

    try std.testing.expectError(error.HttpClientError, client.prompt(&.{}, ai.streamNoop()));
    const detail = client.errorDetail() orelse @panic("expected a recorded error detail");
    try std.testing.expectEqualStrings("HTTP 403: invalid api key", detail);
}

test "extraHeaders materializes provider headers with zen routing and user precedence" {
    const gpa = std.testing.allocator;
    // The merged spec list the runtime would hand the client: zen auto
    // headers with the user's client-attribution override applied.
    const specs = try provider_headers.build(gpa, "https://opencode.ai/zen/v1", .minimal, &.{
        .{ .name = "x-opencode-client", .value = .{ .literal = "custom-client" } },
    });
    defer provider_headers.freeHeaders(gpa, specs);
    try std.testing.expectEqual(@as(usize, 2), specs.len);

    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "https://opencode.ai/zen/v1",
        .api_key = "test-key",
        .model = "test-model",
        .session_id = "sess-32",
        .headers = specs,
        .system_prompt = "",
    }, .{ .log_name = "test" });
    defer client.deinit();

    var buffer: [provider_headers.max_outbound_headers]std.http.Header = undefined;
    var set = provider_headers.HeaderSet.init(&buffer);
    const context = provider_headers.ValueContext{
        .session_id = client.config.session_id,
        .account_id = client.config.account_id,
    };
    set.append(client.responses_config.headers, context);
    set.append(client.provider_headers_owned, context);
    const headers = set.slice();

    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings(provider_headers.zen_session_header, headers[0].name);
    try std.testing.expectEqualStrings("sess-32", headers[0].value);
    try std.testing.expectEqualStrings(provider_headers.zen_client_header, headers[1].name);
    try std.testing.expectEqualStrings("custom-client", headers[1].value);
}

test "init wires the profile User-Agent into the shared transport" {
    const gpa = std.testing.allocator;
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "http://127.0.0.1:1",
        .api_key = "test-key",
        .model = "test-model",
        .system_prompt = "",
    }, .{ .log_name = "test", .user_agent = "test-agent" });
    defer client.deinit();

    // A null here silently downgrades every Responses request (including the
    // codex path, whose chatgpt.com backend checks client identity) to the
    // stdlib default User-Agent.
    try std.testing.expect(client.transport.user_agent != null);
    try std.testing.expectEqualStrings("test-agent", client.transport.user_agent.?);
}
