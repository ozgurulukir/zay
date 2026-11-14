//! McpClient's stdio wire transport (#367 slice 6a): the JSON-RPC request
//! family over the stdio pipes — `sendRequestStdio`'s newline-delimited
//! read loop (10ms-sliced poll, buffered-line drain, interleaved
//! notification routing) and the request-serialized `sendNotificationStdio`.
//!
//! Ownership: the state stays on `McpClient` — `request_mutex`,
//! `transport_mutex`, `in_flight_requests`, `pending_close`,
//! `read_timeout_ms`, `next_request_id`, and the lifecycle union reached
//! through the capture bracket. This module is the logic, as free functions
//! over `*McpClient`; the `windows` FFI struct here carries no
//! back-reference, so the mutual import with client.zig terminates at the
//! type level (client.zig imports these functions; this file imports
//! client.zig only for the `McpClient` type). The lock-order invariants
//! travel with the code (docs/patterns/providers-tools-and-wire-protocols.md):
//! the pipe capture bracket is taken AFTER `request_mutex`; the
//! `in_flight_requests` decrement never holds `transport_mutex` — the last
//! exiting request closes parked pipes; lock-failure paths proceed
//! unsynchronized (`catch return`), matching pre-#385 semantics.

const std = @import("std");
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
