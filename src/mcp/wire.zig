//! McpClient's wire transports (#367 slices 6a/6b): the JSON-RPC request
//! families over stdio pipes and Streamable HTTP — `sendRequestStdio`'s
//! newline-delimited read loop (10ms-sliced poll, buffered-line drain,
//! interleaved notification routing), `sendNotificationStdio`, and the HTTP
//! POST/DELETE family with its select-raced deadline wrappers, session-id
//! plumbing, and SSE/JSON response readers.
//!
//! Ownership: the state stays on `McpClient` — `request_mutex`,
//! `transport_mutex`, `in_flight_requests`, `pending_close`,
//! `read_timeout_ms`, `next_request_id`, `session_id`, and the lifecycle
//! union reached through the capture bracket. This module is the logic, as
//! free functions over `*McpClient`; the `windows` FFI struct and the HTTP
//! select-event unions here carry no back-reference, so the mutual import
//! with client.zig terminates at the type level (client.zig imports these
//! functions; this file imports client.zig only for the `McpClient`,
//! `ServerStatus`, and test-fixture types).
//! The lock-order invariants travel with the code
//! (docs/patterns/providers-tools-and-wire-protocols.md): the pipe capture
//! bracket is taken AFTER `request_mutex`; the `in_flight_requests`
//! decrement never holds `transport_mutex` — the last exiting request
//! closes parked pipes; lock-failure paths proceed unsynchronized
//! (`catch return`), matching pre-#385 semantics; `captureSessionId` takes
//! `transport_mutex` while its caller holds `request_mutex`, and
//! `terminateHttpSessionUnbounded` is a pure DELETE on an already-detached
//! session id.

const std = @import("std");
const log = std.log.scoped(.mcp);
const config_mod = @import("../config/config.zig");
const http = @import("../http.zig");
const os = @import("../os.zig");
const transport = @import("transport.zig");
const client_mod = @import("client.zig");

const McpClient = client_mod.McpClient;
const ServerStatus = client_mod.ServerStatus;

/// Win32 surface for stdio pipe peeks. The Job-Object FFI lives in `os.zig`
/// (single declaration site, #296); the client attaches through
/// `os.createKillOnCloseJobForProcess` and keeps its own teardown policy
/// (silent-exit report before termination).
pub const windows = if (os.is_windows) struct {
    pub const DWORD = std.os.windows.DWORD;
    pub const HANDLE = std.os.windows.HANDLE;
    pub const BOOL = i32;
    pub const LPVOID = ?*anyopaque;

    pub extern "kernel32" fn PeekNamedPipe(
        hNamedPipe: HANDLE,
        lpBuffer: LPVOID,
        nBufferSize: DWORD,
        lpBytesRead: ?*DWORD,
        lpTotalBytesAvail: ?*DWORD,
        lpBytesLeftThisMessage: ?*DWORD,
    ) callconv(.winapi) BOOL;
} else struct {
    pub const HANDLE = std.os.windows.HANDLE;
    pub const DWORD = std.os.windows.DWORD;
    pub const BOOL = i32;
    pub const LPVOID = ?*anyopaque;
};

/// stdio transport: write the request line to the child's stdin and read
/// one newline-delimited response line from stdout. Blocks up to
/// `read_timeout_ms`. The server may push notifications (method, no id)
/// between the request and its response — those are routed to
/// `handleNotification` and the read continues until the matching
/// response (id present) arrives.
///
/// The pipe handles are captured AFTER `request_mutex` and under the
/// `transport_mutex` bracket (#385): capturing before the lock raced a
/// UI-thread `stop` closing the handles while this thread waited at the
/// mutex. `stop` never takes `request_mutex`, so it parks the pipes
/// instead of closing them under this request; the release bracket
/// performs the deferred close.
pub fn sendRequestStdio(client: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) ![]u8 {
    // Serialize requests first: stdin/stdout pipes can't handle
    // concurrent I/O.
    try client.request_mutex.lock(io);
    defer client.request_mutex.unlock(io);

    // Bracket the captured handles: `stop` parks instead of closing while
    // this is in flight, so the handles stay open until release. (Defers
    // run LIFO: the release bracket exits before the request mutex.)
    const pipes = try client.captureStdioTransport(io);
    defer client.releaseStdioTransport(io);
    const stdin_file = pipes.stdin;
    const stdout_file = pipes.stdout;

    const id = client.next_request_id;
    client.next_request_id += 1;

    const request = try transport.formatRequest(client.gpa, id, method, params_json);
    defer client.gpa.free(request);

    try stdin_file.writeStreamingAll(io, request);

    var buf: [64 * 1024]u8 = undefined;
    var reader = stdout_file.reader(io, &buf);

    // Read newline-delimited lines until the response with our `id`
    // arrives. Server-initiated notifications (method, no id) are
    // routed to handleNotification and we keep reading.
    while (true) {
        // A read can buffer both an interleaved notification and its
        // response. Drain a complete buffered line before polling the OS
        // handle, which may already have no bytes left to report.
        const has_buffered_line = std.mem.indexOfScalar(u8, reader.interface.buffered(), '\n') != null;
        if (!has_buffered_line) {
            // Wait for data on stdout with a timeout to prevent infinite
            // hangs. Poll in short slices so cancellation can be observed
            // while connecting or waiting for an MCP response. HUP alone
            // is not a crash: buffered bytes still need draining after
            // the child exits.
            const timeout_ns: i96 = @as(i96, client.read_timeout_ms) * std.time.ns_per_ms;
            const start_time = std.Io.Timestamp.now(io, .awake);
            while (true) {
                if (os.is_windows) {
                    var peek_buffer: [4 * 1024]u8 = undefined;
                    var bytes_read: windows.DWORD = 0;
                    var bytes_avail: windows.DWORD = 0;
                    if (windows.PeekNamedPipe(
                        stdout_file.handle,
                        &peek_buffer,
                        @intCast(peek_buffer.len),
                        &bytes_read,
                        &bytes_avail,
                        null,
                    ) == 0) {
                        return error.McpServerCrashed;
                    }
                    if (bytes_avail > 0 and
                        (std.mem.indexOfScalar(u8, peek_buffer[0..bytes_read], '\n') != null or
                            bytes_avail > peek_buffer.len)) break;
                } else {
                    var poll_fds: [1]std.posix.pollfd = .{
                        .{ .fd = stdout_file.handle, .events = std.posix.POLL.IN, .revents = 0 },
                    };
                    const ready = std.posix.poll(&poll_fds, 0) catch return error.ReadFailed;
                    if (ready > 0) break;
                }

                const now = std.Io.Timestamp.now(io, .awake);
                if (start_time.durationTo(now).nanoseconds >= timeout_ns) {
                    return error.Timeout;
                }
                try io.sleep(.fromMilliseconds(10), .awake);
            }
        }

        // Read one line from stdout (newline-delimited JSON-RPC).
        var line_writer: std.Io.Writer.Allocating = .init(client.gpa);
        errdefer line_writer.deinit();
        _ = reader.interface.streamDelimiterEnding(&line_writer.writer, '\n') catch |err| switch (err) {
            error.ReadFailed => return error.McpServerCrashed,
            error.WriteFailed => return error.OutOfMemory,
        };
        _ = reader.interface.take(1) catch {};
        const line = try line_writer.toOwnedSlice();
        errdefer client.gpa.free(line);

        // Classify: notification (method, no id) → handle + continue;
        // anything else → return for the caller to parse.
        const parsed = std.json.parseFromSlice(std.json.Value, client.gpa, line, .{}) catch return line;
        defer parsed.deinit();
        if (parsed.value != .object) return line;
        const obj = parsed.value.object;
        if (obj.get("method") != null and obj.get("id") == null) {
            // Server-initiated notification — route and keep reading.
            const method_str = if (obj.get("method").? == .string) obj.get("method").?.string else "";
            client.handleNotification(method_str, line);
            client.gpa.free(line);
            continue;
        }
        return line;
    }
}

/// stdio transport: write a notification line to the child's stdin. Serialized
/// via `request_mutex` like requests (#385 — previously this path captured and
/// wrote `stdin` with NO synchronization, racing both `stop`'s close and an
/// in-flight request's interleaved stdin bytes), with the same
/// `transport_mutex` capture bracket as `sendRequestStdio`.
pub fn sendNotificationStdio(client: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) !void {
    try client.request_mutex.lock(io);
    defer client.request_mutex.unlock(io);

    const pipes = try client.captureStdioTransport(io);
    defer client.releaseStdioTransport(io);

    const request = try transport.formatNotification(client.gpa, method, params_json);
    defer client.gpa.free(request);

    try pipes.stdin.writeStreamingAll(io, request);
}

// Streamable HTTP transport buffer/bound sizes.
const http_body_buffer_bytes = 8 * 1024;
const http_redirect_buffer_bytes = 16 * 1024;
const http_transfer_buffer_bytes = 64 * 1024;
const http_response_bytes_max = 64 * 1024 * 1024;

/// The Streamable HTTP `Accept` value: either a single JSON body or an SSE
/// stream (MCP spec contract).
const accept_streamable_http = http.content_type_json ++ ", " ++ http.media_type_event_stream;

const HttpRequestOutcome = union(enum) {
    response: []u8,
    failure: anyerror,
};

const HttpVoidOutcome = union(enum) {
    success,
    failure: anyerror,
};

const HttpSelectEvent = union(enum) {
    request: HttpRequestOutcome,
    notification: HttpVoidOutcome,
    termination: HttpVoidOutcome,
    timeout: void,
};

/// Split a request timeout in milliseconds into the `(sec, usec)` components
/// of a POSIX `timeval` as used by `applyHttpTimeout`. Kept as a pure helper
/// so the rounding math is unit-testable cross-platform (`std.posix.timeval`
/// is not available on Windows, where the socket-timeout path is skipped).
pub fn httpTimeoutParts(read_timeout_ms: u32) struct { sec: i64, usec: i64 } {
    return .{
        .sec = @intCast(read_timeout_ms / 1000),
        .usec = @intCast((read_timeout_ms % 1000) * 1000),
    };
}

/// Apply a socket-level send/recv timeout so a server that accepts the
/// connection but then stalls — no response head, or a mid-body stop —
/// fails the handshake instead of blocking the worker forever.
///
/// `std.http.Client` exposes no connect-phase timeout in Zig 0.16, so the
/// connect itself is bounded only by kernel TCP/DNS timeouts. Connects now
/// run on a worker thread (`McpManager.launchConnect`), so a connect hang
/// can never freeze the UI; this bounds everything after connect.
pub fn applyHttpTimeout(client: *McpClient, conn: *std.http.Client.Connection) void {
    if (!os.is_windows) {
        const parts = httpTimeoutParts(client.read_timeout_ms);
        const tv: std.posix.timeval = .{
            .sec = parts.sec,
            // macOS suseconds_t is 32-bit c_int; usec is bounded to
            // [0, 999_000] by the modulo in httpTimeoutParts.
            .usec = @intCast(parts.usec),
        };
        std.posix.setsockopt(
            conn.stream_reader.stream.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&tv),
        ) catch {};
        std.posix.setsockopt(
            conn.stream_reader.stream.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            std.mem.asBytes(&tv),
        ) catch {};
    }
}

/// Windows' std.Io socket backend does not expose a socket-level timeout
/// through `std.posix`, and the HTTP client has no request deadline of its
/// own. Race the whole HTTP operation — including DNS/connect, response
/// head, and an SSE body — against a timer so cancellation covers every
/// phase of the request.
pub fn runHttpRequestWithTimeout(
    client: *McpClient,
    io: std.Io,
    method: []const u8,
    params_json: ?[]const u8,
) ![]u8 {
    var events: [2]HttpSelectEvent = undefined;
    var select = std.Io.Select(HttpSelectEvent).init(io, &events);
    defer select.cancelDiscard();

    try select.concurrent(.request, httpRequestTask, .{ client, io, method, params_json });
    try select.concurrent(.timeout, httpTimeoutTask, .{ io, client.read_timeout_ms });

    const event = select.await() catch |err| {
        cancelHttpSelect(client, &select);
        return err;
    };
    return switch (event) {
        .request => |outcome| switch (outcome) {
            .response => |response| response,
            .failure => |err| err,
        },
        .timeout => {
            cancelHttpSelect(client, &select);
            return error.Timeout;
        },
        else => unreachable,
    };
}

/// Run a void HTTP operation with the same deadline used for requests.
/// `field` is restricted by the call sites to `.notification` and
/// `.termination`; the union keeps the two operation families distinct so
/// a response allocation can never be mistaken for a void result.
pub fn runHttpVoidWithTimeout(
    client: *McpClient,
    io: std.Io,
    comptime field: std.Io.Select(HttpSelectEvent).Field,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) !void {
    var events: [2]HttpSelectEvent = undefined;
    var select = std.Io.Select(HttpSelectEvent).init(io, &events);
    defer select.cancelDiscard();

    try select.concurrent(field, function, args);
    try select.concurrent(.timeout, httpTimeoutTask, .{ io, client.read_timeout_ms });

    const event = try select.await();
    switch (event) {
        .timeout => return error.Timeout,
        .notification => |outcome| switch (outcome) {
            .success => {},
            .failure => |err| return err,
        },
        .termination => |outcome| switch (outcome) {
            .success => {},
            .failure => |err| return err,
        },
        .request => unreachable,
    }
}

pub fn cancelHttpSelect(client: *McpClient, select: *std.Io.Select(HttpSelectEvent)) void {
    while (select.cancel()) |event| {
        switch (event) {
            .request => |outcome| switch (outcome) {
                .response => |response| client.gpa.free(response),
                .failure => {},
            },
            .notification, .termination, .timeout => {},
        }
    }
}

/// POST a JSON-RPC request to the remote endpoint and return the matching
/// JSON-RPC response (owned). The response is either a single
/// `application/json` body or a `text/event-stream` searched for the
/// request `id`. Captures the server-assigned `Mcp-Session-Id`.
pub fn sendRequestHttp(client: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) ![]u8 {
    if (os.is_windows) {
        return runHttpRequestWithTimeout(client, io, method, params_json);
    }
    return sendRequestHttpUnbounded(client, io, method, params_json);
}

fn sendRequestHttpUnbounded(client: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) ![]u8 {
    const url = switch (client.transport) {
        .sse => |t| t.url,
        .stdio => return error.NoHttpTransport,
    };

    try client.request_mutex.lock(io);
    defer client.request_mutex.unlock(io);

    const id = client.next_request_id;
    client.next_request_id += 1;

    const body = try transport.formatRequest(client.gpa, id, method, params_json);
    defer client.gpa.free(body);

    var http_client: std.http.Client = .{ .allocator = client.gpa, .io = io };
    defer http_client.deinit();

    // Owned session-id snapshot (#385): immune to a concurrent
    // stop→terminateHttpSession freeing the stored id while this request's
    // header bytes still borrow it.
    const session_snapshot = snapshotSessionId(client, io, client.gpa);
    defer if (session_snapshot) |sid| client.gpa.free(sid);
    const extra_headers = try buildExtraHeadersWith(client.gpa, customHttpHeaders(client), session_snapshot);
    defer client.gpa.free(extra_headers);
    var req = try http_client.request(.POST, try std.Uri.parse(url), .{
        .headers = .{ .content_type = .{ .override = http.content_type_json } },
        .extra_headers = extra_headers,
    });
    defer req.deinit();
    // Bound send + head + body reads so a stalled server fails fast.
    if (req.connection) |conn| applyHttpTimeout(client, conn);
    try writeBody(&req, body);

    var redirect_buffer: [http_redirect_buffer_bytes]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    const status_code: u16 = @intFromEnum(response.head.status);
    if (status_code == 404) return error.McpSessionExpired;
    if (status_code == 401 or status_code == 403) return error.McpUnauthorized;
    if (!http.isSuccess(status_code)) return error.McpHttpRequestFailed;

    // Capture session id + content type BEFORE the body reader invalidates
    // the head's borrowed pointers.
    try captureSessionId(client, io, response.head);
    const is_sse = isEventStream(response.head);

    if (is_sse) {
        var transfer_buffer: [http_transfer_buffer_bytes]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var notifications: std.ArrayList(transport.Notification) = .empty;
        defer {
            for (notifications.items) |*n| n.deinit(client.gpa);
            notifications.deinit(client.gpa);
        }
        const response_body = try transport.readSseResponse(client.gpa, reader, id, &notifications);
        // Route accumulated server notifications — they may mark the
        // discovery cache stale, which the App polls on the next tick.
        for (notifications.items) |n| client.handleNotification(n.method, n.payload);
        return response_body;
    }
    return try readJsonBody(client.gpa, &response);
}

/// POST a JSON-RPC notification to the remote endpoint. Expects
/// 202 Accepted (or 200); the response body is not consumed.
pub fn sendNotificationHttp(client: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) !void {
    if (os.is_windows) {
        return runHttpVoidWithTimeout(client, io, .notification, httpNotificationTask, .{ client, io, method, params_json });
    }
    return sendNotificationHttpUnbounded(client, io, method, params_json);
}

fn sendNotificationHttpUnbounded(client: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) !void {
    const url = switch (client.transport) {
        .sse => |t| t.url,
        .stdio => return error.NoHttpTransport,
    };

    try client.request_mutex.lock(io);
    defer client.request_mutex.unlock(io);

    const body = try transport.formatNotification(client.gpa, method, params_json);
    defer client.gpa.free(body);

    var http_client: std.http.Client = .{ .allocator = client.gpa, .io = io };
    defer http_client.deinit();

    // Owned session-id snapshot (#385) — same rationale as
    // sendRequestHttpUnbounded.
    const session_snapshot = snapshotSessionId(client, io, client.gpa);
    defer if (session_snapshot) |sid| client.gpa.free(sid);
    const extra_headers = try buildExtraHeadersWith(client.gpa, customHttpHeaders(client), session_snapshot);
    defer client.gpa.free(extra_headers);
    var req = try http_client.request(.POST, try std.Uri.parse(url), .{
        .headers = .{ .content_type = .{ .override = http.content_type_json } },
        .extra_headers = extra_headers,
    });
    defer req.deinit();
    // Bound send + head reads so a stalled server fails fast.
    if (req.connection) |conn| applyHttpTimeout(client, conn);
    try writeBody(&req, body);

    var redirect_buffer: [http_redirect_buffer_bytes]u8 = undefined;
    const response = try req.receiveHead(&redirect_buffer);
    try captureSessionId(client, io, response.head);
    const status_code: u16 = @intFromEnum(response.head.status);
    if (status_code == 404) return error.McpSessionExpired;
    if (status_code >= 400) return error.McpHttpRequestFailed;
}

/// Build the extra request headers: the Streamable HTTP `Accept` header,
/// `Mcp-Session-Id` once a session is established, and any custom headers
/// configured for the server (e.g. API keys). Returned slice is owned; free
/// with `gpa.free`.
///
/// Reads `session_id`, so callers must hold `transport_mutex` — or use the
/// `snapshotSessionId` + `buildExtraHeadersWith` pair (#385), which hands
/// the request an owned dupe immune to a concurrent `terminateHttpSession`
/// freeing the stored id.
pub fn customHttpHeaders(client: *const McpClient) []const config_mod.McpHeader {
    return switch (client.transport) {
        .sse => |t| t.headers,
        .stdio => &.{},
    };
}

pub fn buildExtraHeaders(client: *const McpClient, gpa: std.mem.Allocator) ![]std.http.Header {
    return buildExtraHeadersWith(gpa, customHttpHeaders(client), client.session_id);
}

/// Pure header builder behind `buildExtraHeaders`; `session_id` is passed
/// in so a request can build headers from an owned snapshot instead of
/// borrowing the live field (#385).
pub fn buildExtraHeadersWith(gpa: std.mem.Allocator, custom: []const config_mod.McpHeader, session_id: ?[]const u8) ![]std.http.Header {
    const count = 1 + custom.len + (if (session_id != null) @as(usize, 1) else 0);
    const headers = try gpa.alloc(std.http.Header, count);
    var i: usize = 0;
    headers[i] = .{ .name = "Accept", .value = accept_streamable_http };
    i += 1;
    if (session_id) |sid| {
        headers[i] = .{ .name = "Mcp-Session-Id", .value = sid };
        i += 1;
    }
    for (custom) |h| {
        headers[i] = .{ .name = h.name, .value = h.value };
        i += 1;
    }
    return headers;
}

/// Owned copy of the live `session_id` under `transport_mutex` (#385), for
/// request paths that hold `request_mutex` and must not borrow the field a
/// concurrent `stop`→`terminateHttpSession` may free. null when there is
/// no session or the lock is canceled (the request then fails loudly
/// server-side rather than racing the free). Caller frees the result.
pub fn snapshotSessionId(client: *McpClient, io: std.Io, gpa: std.mem.Allocator) ?[]u8 {
    client.transport_mutex.lock(io) catch return null;
    defer client.transport_mutex.unlock(io);
    const sid = client.session_id orelse return null;
    return gpa.dupe(u8, sid) catch {
        log.warn("MCP '{s}': OOM snapshotting session id; request goes out session-less", .{client.name});
        return null;
    };
}

/// Update `session_id` from the response's `Mcp-Session-Id` header (if
/// present). Header values borrow the response head, so the value is duped.
/// The free/dupe swap is guarded by `transport_mutex` (#385) — callers hold
/// `request_mutex`, so the lock order stays `request_mutex →
/// transport_mutex`.
pub fn captureSessionId(client: *McpClient, io: std.Io, head: std.http.Client.Response.Head) !void {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) continue;
        try client.transport_mutex.lock(io);
        defer client.transport_mutex.unlock(io);
        // Dupe BEFORE freeing the old value: on OOM the field keeps the
        // coherent old id instead of dangling at freed memory.
        const fresh = try client.gpa.dupe(u8, header.value);
        if (client.session_id) |old| client.gpa.free(old);
        client.session_id = fresh;
        return;
    }
}

/// Pure HTTP DELETE on an already-detached session id (best-effort): the
/// caller (`terminateHttpSession`'s short `transport_mutex` section) owns
/// the detach and the free; this function takes no locks (#385).
pub fn terminateHttpSessionUnbounded(client: *McpClient, io: std.Io, session_id: []const u8) void {
    const url = switch (client.transport) {
        .sse => |t| t.url,
        .stdio => return,
    };
    var http_client: std.http.Client = .{ .allocator = client.gpa, .io = io };
    defer http_client.deinit();
    const extra_headers = buildExtraHeadersWith(client.gpa, customHttpHeaders(client), session_id) catch return;
    defer client.gpa.free(extra_headers);
    var req = http_client.request(.DELETE, std.Uri.parse(url) catch return, .{
        .extra_headers = extra_headers,
    }) catch return;
    defer req.deinit();
    // Best-effort: bound the send so teardown can't hang on a dead server,
    // then send the termination without waiting for the response.
    if (req.connection) |conn| applyHttpTimeout(client, conn);
    req.sendBodiless() catch return;
}

pub fn httpTimeoutTask(io: std.Io, timeout_ms: u32) void {
    io.sleep(std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)), .awake) catch {};
}

pub fn httpRequestTask(
    client: *McpClient,
    io: std.Io,
    method: []const u8,
    params_json: ?[]const u8,
) HttpRequestOutcome {
    const response = sendRequestHttpUnbounded(client, io, method, params_json) catch |err| {
        return .{ .failure = err };
    };
    return .{ .response = response };
}

pub fn httpNotificationTask(
    client: *McpClient,
    io: std.Io,
    method: []const u8,
    params_json: ?[]const u8,
) HttpVoidOutcome {
    sendNotificationHttpUnbounded(client, io, method, params_json) catch |err| {
        return .{ .failure = err };
    };
    return .success;
}

pub fn httpTerminationTask(client: *McpClient, io: std.Io, session_id: []const u8) HttpVoidOutcome {
    terminateHttpSessionUnbounded(client, io, session_id);
    return .success;
}

pub fn stalledHttpOperation(io: std.Io) HttpVoidOutcome {
    io.sleep(std.Io.Duration.fromSeconds(30), .awake) catch |err| {
        return .{ .failure = err };
    };
    return .success;
}

/// Write the request `body` with an explicit content-length and flush it, so
/// the server receives a complete request before we read the response head.
fn writeBody(req: *std.http.Client.Request, body: []const u8) !void {
    req.transfer_encoding = .{ .content_length = body.len };
    var body_buffer: [http_body_buffer_bytes]u8 = undefined;
    var body_writer = try req.sendBodyUnflushed(&body_buffer);
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();
}

/// True when the response `Content-Type` is `text/event-stream` (an SSE
/// stream) rather than a single `application/json` body.
fn isEventStream(head: std.http.Client.Response.Head) bool {
    const content_type = head.content_type orelse return false;
    return std.mem.indexOf(u8, content_type, http.media_type_event_stream) != null;
}

/// Read a single `application/json` response body, honouring content-encoding
/// (mirrors `modelsdev.fetchApiJson`: Cloudflare-style hosts may gzip it).
/// Returns the owned body; caller frees.
fn readJsonBody(gpa: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
    var empty_decompress_buffer: [0]u8 = .{};
    var decompress_buffer: []u8 = &empty_decompress_buffer;
    var decompress_buffer_owned = false;
    switch (response.head.content_encoding) {
        .identity => {},
        .zstd => {
            decompress_buffer = try gpa.alloc(u8, std.compress.zstd.default_window_len);
            decompress_buffer_owned = true;
        },
        .deflate, .gzip => {
            decompress_buffer = try gpa.alloc(u8, std.compress.flate.max_window_len);
            decompress_buffer_owned = true;
        },
        .compress => return error.UnsupportedCompressionMethod,
    }
    defer if (decompress_buffer_owned) gpa.free(decompress_buffer);

    var transfer_buffer: [http_transfer_buffer_bytes]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    return reader.allocRemaining(gpa, .limited(http_response_bytes_max)) catch |err| switch (err) {
        error.StreamTooLong => error.McpResponseTooLarge,
        else => |e| e,
    };
}

// ---------------------------------------------------------------------------
// Notification handling tests
// ---------------------------------------------------------------------------

test "sendRequestStdio routes interleaved notifications to handleNotification" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try client_mod.initMockClient(gpa, "notif-server", "interleaved");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    // Handshake records the listChanged capability.
    try client.initialize(io);
    try std.testing.expect(client.discovery.server_supports_tools_list_changed);

    // tools/list arrives after a notification — the loop routes the
    // notification and keeps reading until the response.
    try client.listTools(io);
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    try std.testing.expectEqualStrings("mcp__notif-server__greet", client.discovery.tools.items[0].full_name);

    // The interleaved notification was buffered — poll drains it.
    try std.testing.expect(client.pollToolsRefresh());
    try std.testing.expectEqual(false, client.pollToolsRefresh());
}

test "McpClient sendRequest timeout produces error.Timeout" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try client_mod.initMockClient(gpa, "slow-server", "slow");
    defer client.deinit(io);
    client.read_timeout_ms = 50;

    try client.startStdio(io);
    defer client.stop(io);

    const result = client.sendRequest(io, "initialize", null);
    try std.testing.expectError(error.Timeout, result);
}

// ---------------------------------------------------------------------------
// Transport-lifetime races (#385) — stdio wire suite
// ---------------------------------------------------------------------------

test "stop during an in-flight request defers the pipe close and fails the request loudly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // slow mode: the response takes 500ms, so the request is genuinely
    // in flight when stop lands on the main thread.
    var client = try client_mod.initMockClient(gpa, "mid-stop", "slow");
    defer client.deinit(io);
    client.read_timeout_ms = 60_000;

    try client.startStdio(io);
    defer client.stop(io);
    try client.initialize(io);

    var worker = try io.concurrent(McpClient.sendRequest, .{ &client, io, "tools/list", @as(?[]const u8, null) });
    // Land stop while the worker sits in its read.
    try io.sleep(.fromMilliseconds(50), .awake);
    const stop_started = std.Io.Timestamp.now(io, .awake);
    client.stop(io);
    const stop_elapsed = stop_started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;

    // stop must stay bounded — the pipe close was deferred to the release
    // bracket, and the process kill path was already bounded.
    try std.testing.expect(stop_elapsed < 5 * std.time.ns_per_s);
    // The lifecycle flips synchronously, not at the deferred close.
    try std.testing.expectEqual(ServerStatus.disabled, client.status());

    // The in-flight request fails loudly — any error beats I/O on closed
    // handles — and the release bracket consumed the parked pipes.
    if (worker.await(io)) |r| gpa.free(r) else |err| {
        try std.testing.expect(err == error.McpServerCrashed or
            err == error.ReadFailed or
            err == error.NotConnected);
    }
    try std.testing.expect(client.pending_close == null);
}

test "a request queued behind another request fails loudly after stop" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try client_mod.initMockClient(gpa, "queued-stop", "slow");
    defer client.deinit(io);
    client.read_timeout_ms = 60_000;

    try client.startStdio(io);
    defer client.stop(io);
    try client.initialize(io);

    // Two concurrent requests: the second queues on request_mutex behind
    // the first; stop lands while both are pending (one inside the read,
    // one at the lock — the exact capture-before-lock window from #385).
    var first = try io.concurrent(McpClient.sendRequest, .{ &client, io, "tools/list", @as(?[]const u8, null) });
    try io.sleep(.fromMilliseconds(50), .awake);
    var second = try io.concurrent(McpClient.sendRequest, .{ &client, io, "ping", @as(?[]const u8, null) });
    try io.sleep(.fromMilliseconds(50), .awake);
    client.stop(io);

    // No use-after-free, no crash: each future resolves (error or value).
    if (first.await(io)) |r| gpa.free(r) else |_| {}
    if (second.await(io)) |r| gpa.free(r) else |_| {}
    try std.testing.expectEqual(ServerStatus.disabled, client.status());
    try std.testing.expect(client.pending_close == null);
}

test "sendNotificationStdio during stop is safe and serialized" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try client_mod.initMockClient(gpa, "notify-stop", "slow");
    defer client.deinit(io);
    client.read_timeout_ms = 60_000;

    try client.startStdio(io);
    defer client.stop(io);
    try client.initialize(io);

    // A notification concurrent with stop must not write through a handle
    // stop is closing (pre-#385 this path had NO synchronization at all).
    var notify = try io.concurrent(McpClient.sendNotification, .{ &client, io, "notifications/initialized", @as(?[]const u8, null) });
    try io.sleep(.fromMilliseconds(50), .awake);
    client.stop(io);
    if (notify.await(io)) |_| {} else |err| {
        try std.testing.expectEqual(error.NotConnected, err);
    }
    try std.testing.expectEqual(ServerStatus.disabled, client.status());
}

test "a notification concurrent with an in-flight request does not corrupt stdin" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try client_mod.initMockClient(gpa, "interleave", "default");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);
    try client.initialize(io);

    // Both paths serialize on request_mutex: the mock must still answer
    // the request correctly, not a spliced notification/request line.
    var request = try io.concurrent(McpClient.callTool, .{ &client, io, "greet", "{\"name\":\"World\"}" });
    client.sendNotification(io, "notifications/initialized", null) catch {};
    const result = try request.await(io);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("Hello, World!", result);
}

test "stop parks the pipes while a capture bracket is open and the bracket's release closes them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try client_mod.initMockClient(gpa, "bracket-park", "default");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);
    try client.initialize(io);

    // Hold a capture bracket across stop — deterministic stand-in for a
    // lane worker mid-request (the concurrent variant of this test covers
    // the real thread; this pins the mechanism without a race window).
    _ = try client.captureStdioTransport(io);
    client.stop(io);

    // The transport went down synchronously, but the pipes the bracket
    // holds are PARKED, not closed — closing them here would be the #385
    // HANDLE/fd-reuse crossfire.
    try std.testing.expectEqual(ServerStatus.disabled, client.status());
    try std.testing.expect(client.pending_close != null);

    // The bracket's exit owns the deferred close.
    client.releaseStdioTransport(io);
    try std.testing.expect(client.pending_close == null);
}

// ---------------------------------------------------------------------------
// Streamable HTTP transport tests
// ---------------------------------------------------------------------------

test "buildExtraHeaders sends Accept, session id, and custom headers" {
    const gpa = std.testing.allocator;
    var client = try McpClient.initSse(gpa, "x", "http://x/mcp");
    defer client.deinit(std.testing.io);

    // No session, no custom headers → only Accept.
    {
        const headers = try buildExtraHeaders(&client, gpa);
        defer gpa.free(headers);
        try std.testing.expectEqual(@as(usize, 1), headers.len);
        try std.testing.expectEqualStrings("Accept", headers[0].name);
        try std.testing.expectEqualStrings("application/json, text/event-stream", headers[0].value);
    }

    // With a session → Accept + Mcp-Session-Id.
    client.session_id = try gpa.dupe(u8, "sess-1");
    {
        const headers = try buildExtraHeaders(&client, gpa);
        defer gpa.free(headers);
        try std.testing.expectEqual(@as(usize, 2), headers.len);
        try std.testing.expectEqualStrings("Mcp-Session-Id", headers[1].name);
        try std.testing.expectEqualStrings("sess-1", headers[1].value);
    }

    // With a custom header → Accept + Mcp-Session-Id + custom (e.g. an API key).
    client.transport.sse.headers = try config_mod.cloneHeaders(gpa, &[_]config_mod.McpHeader{
        .{ .name = @constCast("CONTEXT7_API_KEY"), .value = @constCast("secret") },
    });
    {
        const headers = try buildExtraHeaders(&client, gpa);
        defer gpa.free(headers);
        try std.testing.expectEqual(@as(usize, 3), headers.len);
        try std.testing.expectEqualStrings("CONTEXT7_API_KEY", headers[2].name);
        try std.testing.expectEqualStrings("secret", headers[2].value);
    }
}

test "captureSessionId + isEventStream read the response head" {
    const gpa = std.testing.allocator;
    var client = try McpClient.initSse(gpa, "x", "http://x/mcp");
    defer client.deinit(std.testing.io);

    const json_head = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nMcp-Session-Id: sess-42\r\n\r\n",
    );
    try captureSessionId(&client, std.testing.io, json_head);
    try std.testing.expectEqualStrings("sess-42", client.session_id.?);
    try std.testing.expect(!isEventStream(json_head));

    const sse_head = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n",
    );
    try std.testing.expect(isEventStream(sse_head));
}

test "httpTimeoutParts derives timeval sec/usec from read_timeout_ms" {
    // The per-server `requestTimeoutMs` knob flows into `read_timeout_ms` and
    // feeds `applyHttpTimeout`'s socket timeval. Exact multiples land on zero
    // usec; non-multiples carry the sub-second remainder.
    const whole = httpTimeoutParts(5000);
    try std.testing.expectEqual(@as(i64, 5), whole.sec);
    try std.testing.expectEqual(@as(i64, 0), whole.usec);

    const partial = httpTimeoutParts(1500);
    try std.testing.expectEqual(@as(i64, 1), partial.sec);
    try std.testing.expectEqual(@as(i64, 500_000), partial.usec);

    // Sub-second values produce zero sec and the sub-second remainder in usec.
    const sub_second = httpTimeoutParts(250);
    try std.testing.expectEqual(@as(i64, 0), sub_second.sec);
    try std.testing.expectEqual(@as(i64, 250_000), sub_second.usec);
}

test "Windows HTTP timeout cancels a stalled operation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try McpClient.initSse(gpa, "timeout-test", "http://127.0.0.1/mcp");
    defer client.deinit(io);
    client.read_timeout_ms = 10;

    try std.testing.expectError(
        error.Timeout,
        runHttpVoidWithTimeout(&client, io, .notification, stalledHttpOperation, .{io}),
    );
}

test "snapshotSessionId dupes under transport_mutex and buildExtraHeadersWith keeps the header set" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var client = try McpClient.initSse(gpa, "x", "http://x/mcp");
    defer client.deinit(io);

    // No session yet.
    try std.testing.expect(snapshotSessionId(&client, io, gpa) == null);

    client.session_id = try gpa.dupe(u8, "sess-42");
    const snapshot = snapshotSessionId(&client, io, gpa) orelse return error.SnapshotFailed;
    defer gpa.free(snapshot);
    try std.testing.expectEqualStrings("sess-42", snapshot);
    // The snapshot is owned — freeing the original leaves it readable.
    gpa.free(client.session_id.?);
    client.session_id = null;
    try std.testing.expectEqualStrings("sess-42", snapshot);

    // The pure builder produces the identical header set for the same input.
    const headers = try buildExtraHeadersWith(gpa, &.{}, snapshot);
    defer gpa.free(headers);
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("Accept", headers[0].name);
    try std.testing.expectEqualStrings("Mcp-Session-Id", headers[1].name);
    try std.testing.expectEqualStrings("sess-42", headers[1].value);
}
