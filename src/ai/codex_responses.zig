const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logger");
const ai = @import("../ai.zig");
const core = @import("responses_core.zig");
const websocket = @import("websocket");

const default_codex_endpoint = "https://chatgpt.com/backend-api";
const websocket_idle_timeout_seconds: u32 = 90;
const websocket_handshake_timeout_ms: u32 = 10_000;
const websocket_message_bytes_max: usize = 8 * 1024 * 1024;
const websocket_buffer_bytes: usize = 16 * 1024;
const websocket_watchdog_poll_ms: u32 = 250;

pub const Client = struct {
    core_client: core.Client,

    pub fn init(target: *Client, gpa: std.mem.Allocator, io: std.Io, config: ai.Config) !void {
        std.debug.assert(config.account_id.len > 0);
        std.debug.assert(config.session_id.len > 0);
        std.debug.assert(config.system_prompt.len > 0);
        var codex_config = config;
        codex_config.responses_mode = .codex;
        codex_config.base_url = if (config.base_url.len > 0) config.base_url else default_codex_endpoint;
        try target.core_client.init(gpa, io, codex_config);
    }

    pub fn deinit(self: *Client) void {
        self.core_client.deinit();
        self.* = undefined;
    }

    pub fn prompt(self: *Client, messages: []const ai.ChatMessage, observer: ai.StreamObserver) !ai.Turn {
        var bridge: ObserverBridge = .{ .observer = observer };
        return self.promptWebSocket(messages, bridge.streamObserver()) catch |err| {
            logger.log("codex.websocket.failure emitted={} error={s}", .{ bridge.emitted, @errorName(err) });
            if (bridge.emitted) return err;
            return self.core_client.prompt(messages, observer);
        };
    }

    fn promptWebSocket(self: *Client, messages: []const ai.ChatMessage, observer: ai.StreamObserver) !ai.Turn {
        const gpa = self.core_client.gpa;
        const endpoint = try parseWebSocketEndpoint(gpa, self.core_client.url);
        defer endpoint.deinit(gpa);

        var client = try websocket.Client.init(self.core_client.io, gpa, .{
            .host = endpoint.host,
            .port = endpoint.port,
            .tls = endpoint.tls,
            .max_size = websocket_message_bytes_max,
            .buffer_size = websocket_buffer_bytes,
        });
        defer client.deinit();
        defer client.close(.{}) catch {};

        var watchdog: WebSocketWatchdog = undefined;
        try watchdog.start(client.stream.stream.socket.handle);
        defer watchdog.stop();

        const headers = try buildHandshakeHeaders(gpa, endpoint.host_header, self.core_client.authorization, self.core_client.config);
        defer gpa.free(headers);

        logger.log("codex.websocket.request GET {s} session_id={s}", .{ self.core_client.url, self.core_client.config.session_id });
        watchdog.armMs(websocket_handshake_timeout_ms);
        client.handshake(endpoint.path, .{
            .timeout_ms = websocket_handshake_timeout_ms,
            .headers = headers,
        }) catch |err| return watchdog.timeoutError(err);
        watchdog.armSeconds(websocket_idle_timeout_seconds);
        logger.log("codex.websocket.timeout.read_idle_seconds={d}", .{websocket_idle_timeout_seconds});

        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        try body.writer.writeAll("{\"type\":\"response.create\",");
        var payload: std.Io.Writer.Allocating = .init(gpa);
        defer payload.deinit();
        try core.writeRequestPayload(&payload.writer, self.core_client.config, messages, self.core_client.tools_json);
        try body.writer.writeAll(payload.written()[1..]);
        logger.log("codex.websocket.request.body {s}", .{logBytes(body.written())});
        try client.writeText(body.written());

        var state: core.StreamState = .{};
        defer state.deinit(gpa);
        errdefer state.deinitBlocks(gpa);
        var event_count: u32 = 0;
        while (event_count < 100_000) : (event_count += 1) {
            const message = (client.read() catch |err| return watchdog.timeoutError(err)) orelse return error.WebSocketReadTimeout;
            defer client.done(message);
            watchdog.armSeconds(websocket_idle_timeout_seconds);
            switch (message.type) {
                .text => {
                    logger.log("codex.websocket.response.frame {s}", .{logBytes(message.data)});
                    try state.processJson(gpa, message.data, observer, &self.core_client.call_seq);
                },
                .binary => return error.UnsupportedWebSocketFrame,
                .close => return error.WebSocketClosed,
                .ping => try client.writePong(message.data),
                .pong => {},
            }
            if (state.completed) break;
        }
        return try state.finish(gpa, &self.core_client.call_seq);
    }
};

const WebSocketWatchdog = struct {
    fd: std.posix.socket_t,
    deadline_ns: std.atomic.Value(i64),
    stopped: std.atomic.Value(bool),
    timed_out: std.atomic.Value(bool),
    thread: std.Thread,

    fn start(self: *WebSocketWatchdog, fd: std.posix.socket_t) !void {
        self.* = .{
            .fd = fd,
            .deadline_ns = .init(0),
            .stopped = .init(false),
            .timed_out = .init(false),
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn stop(self: *WebSocketWatchdog) void {
        self.stopped.store(true, .release);
        self.thread.join();
    }

    fn armMs(self: *WebSocketWatchdog, timeout_ms: u32) void {
        std.debug.assert(timeout_ms > 0);
        const timeout_ns: i64 = @as(i64, timeout_ms) * std.time.ns_per_ms;
        self.deadline_ns.store(monotonicNowNs() + timeout_ns, .release);
        self.timed_out.store(false, .release);
    }

    fn armSeconds(self: *WebSocketWatchdog, timeout_seconds: u32) void {
        std.debug.assert(timeout_seconds > 0);
        const timeout_ns: i64 = @as(i64, timeout_seconds) * std.time.ns_per_s;
        self.deadline_ns.store(monotonicNowNs() + timeout_ns, .release);
        self.timed_out.store(false, .release);
    }

    fn timeoutError(self: *WebSocketWatchdog, err: anyerror) anyerror {
        if (self.timed_out.load(.acquire)) return error.WebSocketReadTimeout;
        return err;
    }

    fn run(self: *WebSocketWatchdog) void {
        while (!self.stopped.load(.acquire)) {
            const deadline_ns = self.deadline_ns.load(.acquire);
            if (deadline_ns > 0) {
                if (monotonicNowNs() >= deadline_ns) {
                    self.timed_out.store(true, .release);
                    self.shutdown();
                    return;
                }
            }
            sleepMs(websocket_watchdog_poll_ms);
        }
    }

    fn shutdown(self: *WebSocketWatchdog) void {
        const rc = std.c.shutdown(self.fd, std.c.SHUT.RDWR);
        _ = rc;
    }
};

const WebSocketEndpoint = struct {
    host: []u8,
    host_header: []u8,
    path: []u8,
    port: u16,
    tls: bool,

    fn deinit(self: *const WebSocketEndpoint, gpa: std.mem.Allocator) void {
        gpa.free(self.host);
        gpa.free(self.host_header);
        gpa.free(self.path);
    }
};

const ObserverBridge = struct {
    observer: ai.StreamObserver,
    emitted: bool = false,

    fn streamObserver(self: *ObserverBridge) ai.StreamObserver {
        return .{
            .ptr = self,
            .on_content = onContent,
            .on_reasoning = onReasoning,
            .on_tool_delta = onToolDelta,
            .on_delta_end = onDeltaEnd,
        };
    }

    fn onContent(ptr: *anyopaque, delta: []const u8) anyerror!void {
        const self: *ObserverBridge = @ptrCast(@alignCast(ptr));
        self.emitted = true;
        try self.observer.on_content(self.observer.ptr, delta);
    }

    fn onReasoning(ptr: *anyopaque, delta: []const u8) anyerror!void {
        const self: *ObserverBridge = @ptrCast(@alignCast(ptr));
        self.emitted = true;
        try self.observer.on_reasoning(self.observer.ptr, delta);
    }

    fn onToolDelta(ptr: *anyopaque, delta: ai.ToolDelta) anyerror!void {
        const self: *ObserverBridge = @ptrCast(@alignCast(ptr));
        self.emitted = true;
        try self.observer.on_tool_delta(self.observer.ptr, delta);
    }

    fn onDeltaEnd(ptr: *anyopaque) anyerror!void {
        const self: *ObserverBridge = @ptrCast(@alignCast(ptr));
        try self.observer.on_delta_end(self.observer.ptr);
    }
};

fn parseWebSocketEndpoint(gpa: std.mem.Allocator, url: []const u8) !WebSocketEndpoint {
    const uri = try std.Uri.parse(url);
    const tls = if (std.mem.eql(u8, uri.scheme, "https") or std.mem.eql(u8, uri.scheme, "wss"))
        true
    else if (std.mem.eql(u8, uri.scheme, "http") or std.mem.eql(u8, uri.scheme, "ws"))
        false
    else
        return error.UnsupportedWebSocketScheme;
    const port = uri.port orelse if (tls) @as(u16, 443) else @as(u16, 80);
    const host = try uriHost(gpa, uri);
    errdefer gpa.free(host);
    const host_header = try hostHeader(gpa, host, port, tls);
    errdefer gpa.free(host_header);
    const path = try uriPathAndQuery(gpa, uri);
    errdefer gpa.free(path);
    return .{
        .host = host,
        .host_header = host_header,
        .path = path,
        .port = port,
        .tls = tls,
    };
}

fn uriHost(gpa: std.mem.Allocator, uri: std.Uri) ![]u8 {
    const host_component = uri.host orelse return error.UriMissingHost;
    return try componentAlloc(gpa, host_component);
}

fn uriPathAndQuery(gpa: std.mem.Allocator, uri: std.Uri) ![]u8 {
    const path = try componentAlloc(gpa, uri.path);
    defer gpa.free(path);
    const query_component = uri.query orelse return try gpa.dupe(u8, path);
    const query = try componentAlloc(gpa, query_component);
    defer gpa.free(query);
    return try std.fmt.allocPrint(gpa, "{s}?{s}", .{ path, query });
}

fn componentAlloc(gpa: std.mem.Allocator, component: std.Uri.Component) ![]u8 {
    return switch (component) {
        .raw => |raw| try gpa.dupe(u8, raw),
        .percent_encoded => |encoded| try gpa.dupe(u8, encoded),
    };
}

fn hostHeader(gpa: std.mem.Allocator, host: []const u8, port: u16, tls: bool) ![]u8 {
    const default_port: u16 = if (tls) 443 else 80;
    if (port == default_port) return try gpa.dupe(u8, host);
    return try std.fmt.allocPrint(gpa, "{s}:{d}", .{ host, port });
}

fn buildHandshakeHeaders(
    gpa: std.mem.Allocator,
    host_header: []const u8,
    authorization: []const u8,
    config: ai.Config,
) ![]u8 {
    return try std.fmt.allocPrint(
        gpa,
        "Host: {s}\r\nAuthorization: {s}\r\nUser-Agent: nova\r\nchatgpt-account-id: {s}\r\noriginator: nova\r\nOpenAI-Beta: responses_websockets=2026-02-06\r\nsession_id: {s}\r\nx-client-request-id: {s}\r\n",
        .{
            host_header,
            authorization,
            config.account_id,
            config.session_id,
            config.session_id,
        },
    );
}

fn logBytes(bytes: []const u8) []const u8 {
    const limit = 12 * 1024;
    if (bytes.len <= limit) return bytes;
    return bytes[0..limit];
}

fn monotonicNowNs() i64 {
    if (builtin.os.tag == .windows) {
        var freq: std.os.windows.LARGE_INTEGER = undefined;
        _ = std.os.windows.ntdll.RtlQueryPerformanceFrequency(&freq);
        var counter: std.os.windows.LARGE_INTEGER = undefined;
        _ = std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter);
        const ns: i128 = @divFloor(@as(i128, counter) * std.time.ns_per_s, @as(i128, freq));
        return @intCast(ns);
    }
    var now: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &now);
    std.debug.assert(rc == 0);
    return @as(i64, @intCast(now.sec)) * std.time.ns_per_s + now.nsec;
}

fn sleepMs(milliseconds: u32) void {
    std.debug.assert(milliseconds > 0);
    if (builtin.os.tag == .windows) {
        // NtDelayExecution interval is in 100ns units; negative = relative.
        const interval: std.os.windows.LARGE_INTEGER = -@as(std.os.windows.LARGE_INTEGER, milliseconds) * 10_000;
        _ = std.os.windows.ntdll.NtDelayExecution(.FALSE, &interval);
        return;
    }
    var remaining: std.c.timespec = .{
        .sec = milliseconds / std.time.ms_per_s,
        .nsec = @as(c_long, @intCast(milliseconds % std.time.ms_per_s)) * std.time.ns_per_ms,
    };
    while (std.c.nanosleep(&remaining, &remaining) != 0) {}
}

test "codex websocket endpoint parses https url" {
    const gpa = std.testing.allocator;
    const endpoint = try parseWebSocketEndpoint(gpa, "https://chatgpt.com/backend-api/codex/responses?x=1");
    defer endpoint.deinit(gpa);
    try std.testing.expectEqualStrings("chatgpt.com", endpoint.host);
    try std.testing.expectEqualStrings("chatgpt.com", endpoint.host_header);
    try std.testing.expectEqualStrings("/backend-api/codex/responses?x=1", endpoint.path);
    try std.testing.expectEqual(@as(u16, 443), endpoint.port);
    try std.testing.expect(endpoint.tls);
}

test "codex websocket endpoint includes non-default port in host header" {
    const gpa = std.testing.allocator;
    const endpoint = try parseWebSocketEndpoint(gpa, "ws://localhost:9224/ws");
    defer endpoint.deinit(gpa);
    try std.testing.expectEqualStrings("localhost:9224", endpoint.host_header);
    try std.testing.expectEqual(@as(u16, 9224), endpoint.port);
    try std.testing.expect(!endpoint.tls);
}

test {
    std.testing.refAllDecls(@This());
}
