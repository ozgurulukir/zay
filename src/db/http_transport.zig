//! Bounded HTTP transport shared by remote database adapters.
//!
//! Provider modules own URL normalization, payloads, status diagnostics, and
//! response parsing. This leaf owns the network deadline, response-body cap,
//! bearer authentication, and transport-error normalization.

const std = @import("std");
const http = @import("../http.zig");
const os = @import("../os.zig");

const assert = std.debug.assert;

pub const timeout_seconds_default: u32 = 30;
pub const response_max_bytes_default: usize = 16 * 1024 * 1024;

pub const Options = struct {
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8 = null,
    auth_token: ?[]const u8 = null,
    timeout_seconds: u32 = timeout_seconds_default,
    response_max_bytes: usize = response_max_bytes_default,
};

pub const Response = struct {
    status: u16,
    /// Owned by the caller and allocated with the allocator passed to `fetch`.
    body: []u8,
};

pub fn fetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
) !Response {
    assert(options.url.len > 0);
    assert(options.timeout_seconds > 0);
    assert(options.response_max_bytes > 0);

    // Windows AFD handles cannot use ws2_32 socket timeouts, so race the
    // complete exchange against a deadline. DB callers pass request-scoped
    // arena allocators, which also own any late task allocation discarded by
    // cancellation.
    if (os.is_windows) return fetchBounded(allocator, io, options);
    return fetchUnbounded(allocator, io, options);
}

const FetchOutcome = union(enum) {
    response: Response,
    failure: anyerror,
};

const FetchEvent = union(enum) {
    fetch: FetchOutcome,
    timeout: void,
};

fn fetchBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
) !Response {
    var events: [2]FetchEvent = undefined;
    var select = std.Io.Select(FetchEvent).init(io, &events);
    defer fetchBoundedCancel(&select, allocator);

    try select.concurrent(.fetch, fetchTask, .{ allocator, io, options });
    try select.concurrent(.timeout, deadlineTask, .{ io, options.timeout_seconds });

    const event = select.await() catch |err| return err;
    return switch (event) {
        .fetch => |outcome| switch (outcome) {
            .response => |response| response,
            .failure => |err| err,
        },
        .timeout => error.ServerTimeout,
    };
}

fn fetchBoundedCancel(
    select: *std.Io.Select(FetchEvent),
    allocator: std.mem.Allocator,
) void {
    while (select.cancel()) |event| {
        switch (event) {
            .fetch => |outcome| switch (outcome) {
                .response => |response| allocator.free(response.body),
                .failure => {},
            },
            .timeout => {},
        }
    }
}

fn fetchTask(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
) FetchOutcome {
    const response = fetchUnbounded(allocator, io, options) catch |err| {
        return .{ .failure = err };
    };
    return .{ .response = response };
}

fn deadlineTask(io: std.Io, timeout_seconds: u32) void {
    io.sleep(std.Io.Duration.fromMilliseconds(@as(i64, timeout_seconds) * 1000), .awake) catch {};
}

fn fetchUnbounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
) !Response {
    var http_client: std.http.Client = .{
        .allocator = allocator,
        .io = http.timeoutAwareIo(io),
    };
    defer http_client.deinit();

    const auth_header: ?[]u8 = if (options.auth_token) |token|
        try std.fmt.allocPrint(allocator, "Bearer {s}", .{token})
    else
        null;
    defer if (auth_header) |header| allocator.free(header);

    var request = http_client.request(
        options.method,
        std.Uri.parse(options.url) catch return error.InvalidEndpoint,
        .{
            .redirect_behavior = if (options.payload == null) @enumFromInt(3) else .unhandled,
            .headers = .{
                .content_type = if (options.payload != null) .{ .override = http.content_type_json } else .default,
                .authorization = if (auth_header) |header| .{ .override = header } else .omit,
            },
        },
    ) catch |err| return mapError(err);
    defer request.deinit();

    // Apply POSIX send/receive timeouts before the first byte is written so
    // both the response-head and response-body phases are bounded.
    if (request.connection) |connection| {
        http.setSocketTimeout(connection, options.timeout_seconds);
    }

    if (options.payload) |payload| {
        request.transfer_encoding = .{ .content_length = payload.len };
        var send_buffer: [http.body_buffer_bytes]u8 = undefined;
        var body_writer = request.sendBodyUnflushed(&send_buffer) catch |err| return mapRequestError(&request, err);
        body_writer.writer.writeAll(payload) catch |err| return mapRequestError(&request, err);
        body_writer.end() catch |err| return mapRequestError(&request, err);
        request.connection.?.flush() catch |err| return mapRequestError(&request, err);
    } else {
        request.sendBodiless() catch |err| return mapRequestError(&request, err);
    }

    var redirect_buffer: [http.redirect_buffer_bytes]u8 = undefined;
    var http_response = request.receiveHead(&redirect_buffer) catch |err| return mapRequestError(&request, err);

    var transfer_buffer: [http.transfer_buffer_bytes]u8 = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = http_response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);
    const body = reader.allocRemaining(allocator, .limited(options.response_max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.ResponseTooLarge,
        else => {
            if (err == error.ReadFailed) {
                if (request.connection) |connection| {
                    if (connection.stream_reader.err) |reason| return mapError(reason);
                }
                if (http_response.bodyErr()) |reason| return mapError(reason);
            }
            return mapError(err);
        },
    };

    return .{
        .status = @intFromEnum(http_response.head.status),
        .body = body,
    };
}

fn mapRequestError(request: *const std.http.Client.Request, err: anyerror) anyerror {
    if (err == error.ReadFailed or err == error.WriteFailed) {
        if (request.connection) |connection| {
            if (connection.stream_reader.err) |reason| return mapError(reason);
            if (connection.stream_writer.err) |reason| return mapError(reason);
        }
    }
    return mapError(err);
}

fn mapError(err: anyerror) anyerror {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.BrokenPipe,
        error.ConnectionFailed,
        => error.ConnectionRefused,
        error.Timeout => error.ServerTimeout,
        else => err,
    };
}
