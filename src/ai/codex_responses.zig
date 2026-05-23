const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logger");
const ai = @import("../ai.zig");
const core = @import("responses_core.zig");
const websocket = @import("websocket");

const default_codex_endpoint = "https://chatgpt.com/backend-api";
const websocket_idle_timeout_seconds: u32 = 90;

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
        const key = websocket.makeKey(self.core_client.io);
        var accept_expected: [28]u8 = undefined;
        websocket.acceptValue(&accept_expected, &key);
        const extra_headers = [_]std.http.Header{
            .{ .name = "upgrade", .value = "websocket" },
            .{ .name = "sec-websocket-version", .value = "13" },
            .{ .name = "sec-websocket-key", .value = &key },
            .{ .name = "chatgpt-account-id", .value = self.core_client.config.account_id },
            .{ .name = "originator", .value = "nova" },
            .{ .name = "OpenAI-Beta", .value = "responses_websockets=2026-02-06" },
            .{ .name = "session_id", .value = self.core_client.config.session_id },
            .{ .name = "x-client-request-id", .value = self.core_client.config.session_id },
        };
        logger.log("codex.websocket.request GET {s} session_id={s}", .{ self.core_client.url, self.core_client.config.session_id });
        var req = try self.core_client.http_client.request(.GET, try std.Uri.parse(self.core_client.url), .{
            .headers = .{
                .authorization = .{ .override = self.core_client.authorization },
                .connection = .{ .override = "Upgrade" },
                .user_agent = .{ .override = "nova" },
            },
            .extra_headers = &extra_headers,
        });
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buffer: [8192]u8 = undefined;
        const response = try req.receiveHead(&redirect_buffer);
        logger.log("codex.websocket.response.head status={d}", .{@intFromEnum(response.head.status)});
        if (response.head.status != .switching_protocols) return error.WebSocketUpgradeFailed;
        if (!acceptMatches(response.head.bytes, &accept_expected)) return error.WebSocketUpgradeFailed;
        setWebSocketReadTimeout(req.connection.?);
        defer finishUpgradedRequest(&req, self.core_client.io);

        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        try body.writer.writeAll("{\"type\":\"response.create\",");
        var payload: std.Io.Writer.Allocating = .init(gpa);
        defer payload.deinit();
        try core.writeRequestPayload(&payload.writer, self.core_client.config, messages, self.core_client.tools_json);
        try body.writer.writeAll(payload.written()[1..]);
        logger.log("codex.websocket.request.body {s}", .{logBytes(body.written())});
        const frame = try websocket.encodeClientTextFrame(gpa, self.core_client.io, body.written());
        defer gpa.free(frame);
        try req.connection.?.writer().writeAll(frame);
        try req.connection.?.flush();

        var state: core.StreamState = .{};
        defer state.deinit(gpa);
        errdefer state.deinitBlocks(gpa);
        var event_count: u32 = 0;
        while (event_count < 100_000) : (event_count += 1) {
            const text = readTextFrame(gpa, req.connection.?.reader()) catch |err| {
                logWebSocketReadFailure(req.connection.?, err);
                return err;
            };
            defer gpa.free(text);
            logger.log("codex.websocket.response.frame {s}", .{logBytes(text)});
            try state.processJson(gpa, text, observer, &self.core_client.call_seq);
            if (state.completed) break;
        }
        return try state.finish(gpa, &self.core_client.call_seq);
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

fn finishUpgradedRequest(request: *std.http.Client.Request, io: std.Io) void {
    const connection = request.connection orelse return;
    var close_frame: [websocket.client_close_frame_bytes]u8 = undefined;
    websocket.encodeClientCloseFrame(&close_frame, io);
    connection.writer().writeAll(&close_frame) catch {};
    connection.flush() catch {};
    connection.closing = true;
    request.reader.state = .ready;
}

fn setWebSocketReadTimeout(connection: *std.http.Client.Connection) void {
    if (comptime builtin.os.tag == .windows) return;
    if (comptime builtin.os.tag == .wasi) return;
    if (comptime builtin.os.tag == .emscripten) return;

    const timeout: std.posix.timeval = .{
        .sec = websocket_idle_timeout_seconds,
        .usec = 0,
    };
    std.posix.setsockopt(
        connection.stream_reader.stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    ) catch |err| {
        logger.log("codex.websocket.timeout.setup_failed seconds={d} error={s}", .{
            websocket_idle_timeout_seconds,
            @errorName(err),
        });
        return;
    };
    logger.log("codex.websocket.timeout.read_idle_seconds={d}", .{websocket_idle_timeout_seconds});
}

fn logWebSocketReadFailure(connection: *std.http.Client.Connection, err: anyerror) void {
    if (connection.getReadError()) |read_error| {
        logger.log("codex.websocket.read.failure error={s} transport_error={s}", .{
            @errorName(err),
            @errorName(read_error),
        });
        return;
    }
    logger.log("codex.websocket.read.failure error={s}", .{@errorName(err)});
}

fn acceptMatches(head: []const u8, expected: []const u8) bool {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " ");
        if (!std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        return std.mem.eql(u8, value, expected);
    }
    return false;
}

fn readTextFrame(gpa: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var header_bytes: [14]u8 = undefined;
    header_bytes[0] = try reader.takeByte();
    header_bytes[1] = try reader.takeByte();
    const len_code = header_bytes[1] & 0x7f;
    var header_len: usize = 2;
    if (len_code == 126) {
        @memcpy(header_bytes[2..4], try reader.take(2));
        header_len = 4;
    } else if (len_code == 127) {
        @memcpy(header_bytes[2..10], try reader.take(8));
        header_len = 10;
    }
    const masked = (header_bytes[1] & 0x80) != 0;
    if (masked) {
        @memcpy(header_bytes[header_len .. header_len + 4], try reader.take(4));
        header_len += 4;
    }
    const header = try websocket.parseFrameHeader(header_bytes[0..header_len]);
    if (header.opcode == .close) return error.WebSocketClosed;
    if (header.opcode != .text) return error.UnsupportedWebSocketFrame;
    if (header.payload_len > 8 * 1024 * 1024) return error.WebSocketFrameTooLarge;
    const payload = try gpa.alloc(u8, @intCast(header.payload_len));
    errdefer gpa.free(payload);
    @memcpy(payload, try reader.take(payload.len));
    if (header.masked) websocket.unmask(payload, header.mask);
    return payload;
}

fn logBytes(bytes: []const u8) []const u8 {
    const limit = 12 * 1024;
    if (bytes.len <= limit) return bytes;
    return bytes[0..limit];
}

test "websocket accept header is matched case-insensitively" {
    try std.testing.expect(acceptMatches("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: abc\r\n\r\n", "abc"));
    try std.testing.expect(!acceptMatches("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: abc\r\n\r\n", "def"));
}

test {
    std.testing.refAllDecls(@This());
}
