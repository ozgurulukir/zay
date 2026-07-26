//! MCP JSON-RPC 2.0 Transport Layer.
//! Handles message framing, JSON-RPC 2.0 encoding/decoding, and stdio/SSE I/O.

const std = @import("std");

const assert = std.debug.assert;

pub const JsonRpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: i64,
    method: []const u8,
    params: ?[]const u8 = null,
};

pub const JsonRpcNotification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?[]const u8 = null,
};

pub const JsonRpcResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?i64 = null,
    result: ?std.json.Value = null,
    err: ?JsonRpcError = null,
};

pub const JsonRpcError = struct {
    code: i64,
    message: []const u8,
};

/// A server-initiated notification captured while waiting for a response.
/// Owned; the caller frees `method` (and `payload` if non-empty). Per the MCP
/// spec, a notification has a `method` and no `id` — `notifications/*` events
/// (e.g. `notifications/tools/list_changed`, `notifications/progress`) flow
/// here. We only consume `tools/list_changed` for now; others are accepted
/// and forwarded so the App can ignore them.
pub const Notification = struct {
    method: []u8,
    /// The full JSON-RPC message payload (the SSE `data:` body). Empty when
    /// the notification carries no params (the common case for list_changed).
    payload: []u8,

    pub fn deinit(self: *Notification, gpa: std.mem.Allocator) void {
        gpa.free(self.method);
        gpa.free(self.payload);
        self.* = undefined;
    }
};

/// Format a JSON-RPC 2.0 Request frame into an allocated string slice.
pub fn formatRequest(gpa: std.mem.Allocator, id: i64, method: []const u8, params_json: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id});
    try std.json.Stringify.value(method, .{}, &out.writer);
    if (params_json) |p| {
        try out.writer.writeAll(",\"params\":");
        try out.writer.writeAll(p);
    }
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

/// Format a JSON-RPC 2.0 Notification frame into an allocated string slice.
pub fn formatNotification(gpa: std.mem.Allocator, method: []const u8, params_json: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try std.json.Stringify.value(method, .{}, &out.writer);
    if (params_json) |p| {
        try out.writer.writeAll(",\"params\":");
        try out.writer.writeAll(p);
    }
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

/// Parse a JSON-RPC 2.0 message line into a parsed JSON Value tree.
pub fn parseMessage(gpa: std.mem.Allocator, line: []const u8) !std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyMessage;
    return std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{});
}

// ---------------------------------------------------------------------------
// MCP Streamable HTTP — Server-Sent Events framing
// ---------------------------------------------------------------------------
//
// A remote MCP server answers a POST either with a single `application/json`
// body or with a `text/event-stream` stream that eventually carries the
// JSON-RPC response. SSE frames a message as `event: <type>` + one or more
// `data: <payload>` lines, terminated by a blank line. Unlike the OpenAI
// completions stream there is no `[DONE]` sentinel — the stream ends when the
// connection closes.

/// Upper bounds on a single SSE response stream. Hit either and the reader
/// errors rather than letting a misbehaving server stream unbounded work.
pub const sse_event_max: u32 = 100_000;
pub const sse_data_bytes_max: u32 = 64 * 1024 * 1024;

/// The classification of one raw SSE line. Returned slices borrow the input.
pub const SseLine = union(enum) {
    /// `event: <type>` — names the following event (e.g. "message").
    event: []const u8,
    /// `data: <payload>` — a chunk of the event's JSON-RPC payload.
    data: []const u8,
    /// A blank line — marks the end of an event.
    blank,
    /// Anything else: comments (`: ...`), `id:`, `retry:`, unknown fields.
    other,
};

/// Classify one raw SSE line. No allocation; slices borrow `line`.
pub fn classifySseLine(line: []const u8) SseLine {
    const trimmed = std.mem.trim(u8, line, " \r");
    if (trimmed.len == 0) return .blank;
    if (std.mem.startsWith(u8, trimmed, "event:")) {
        return .{ .event = std.mem.trim(u8, trimmed["event:".len..], " ") };
    }
    if (std.mem.startsWith(u8, trimmed, "data:")) {
        return .{ .data = std.mem.trim(u8, trimmed["data:".len..], " ") };
    }
    return .other;
}

/// Read one `\n`-terminated SSE line (delimiter stripped). Returns null at end
/// of stream when no trailing bytes remain.
fn readSseLine(gpa: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var line: std.Io.Writer.Allocating = .init(gpa);
    errdefer line.deinit();
    _ = reader.streamDelimiterEnding(&line.writer, '\n') catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => return error.OutOfMemory,
    };
    const delimiter = reader.take(1) catch |err| switch (err) {
        error.EndOfStream => {
            if (line.written().len == 0) return null;
            return try line.toOwnedSlice();
        },
        else => |e| return e,
    };
    std.debug.assert(delimiter.len == 1);
    std.debug.assert(delimiter[0] == '\n');
    return try line.toOwnedSlice();
}

/// True when `payload` is a JSON-RPC **response** (has an `id`, a `result` or
/// `error`, and no `method`) whose `id` equals `request_id`. Server-initiated
/// requests/notifications carry a `method` and are rejected here.
fn isResponseForId(gpa: std.mem.Allocator, payload: []const u8, request_id: i64) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const obj = parsed.value.object;
    if (obj.get("method") != null) return false;
    const id_val = obj.get("id") orelse return false;
    if (id_val != .integer) return false;
    return id_val.integer == request_id;
}

/// If `payload` is a server-initiated notification (has `method`, no `id`),
/// return an owned `Notification` with the method string and the raw payload.
/// Returns null for responses, requests with an id, or unparseable input.
/// Caller owns the result and must `deinit` it.
fn extractNotification(gpa: std.mem.Allocator, payload: []const u8) ?Notification {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    const method_val = obj.get("method") orelse return null;
    if (method_val != .string) return null;
    if (obj.get("id") != null) return null;
    const method = gpa.dupe(u8, method_val.string) catch return null;
    errdefer gpa.free(method);
    const payload_dup = gpa.dupe(u8, payload) catch return null;
    return .{ .method = method, .payload = payload_dup };
}

/// Read MCP SSE events from `reader` until a JSON-RPC response whose `id`
/// equals `request_id` arrives; return that response's raw JSON (owned, caller
/// frees). Events of type other than `message` (or the default empty type) are
/// skipped. Server-initiated notifications (method, no id) are appended to
/// `notifications` (owned, caller frees each entry) so the caller can route
/// them. Bounded by `sse_event_max` / `sse_data_bytes_max`.
pub fn readSseResponse(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    request_id: i64,
    notifications: *std.ArrayList(Notification),
) ![]u8 {
    var event_type: std.ArrayList(u8) = .empty;
    defer event_type.deinit(gpa);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    var events_seen: u32 = 0;
    while (events_seen < sse_event_max) {
        const line = (try readSseLine(gpa, reader)) orelse return error.McpStreamEndedEarly;
        defer gpa.free(line);
        switch (classifySseLine(line)) {
            .event => |e| try event_type.appendSlice(gpa, e),
            .data => |d| {
                if (data.items.len > 0) try data.append(gpa, '\n');
                try data.appendSlice(gpa, d);
                if (data.items.len > sse_data_bytes_max) return error.McpStreamTooLarge;
            },
            .other => {},
            .blank => {
                events_seen += 1;
                const is_message = event_type.items.len == 0 or
                    std.mem.eql(u8, event_type.items, "message");
                if (is_message and data.items.len > 0) {
                    if (isResponseForId(gpa, data.items, request_id)) {
                        return try gpa.dupe(u8, data.items);
                    }
                    // Not our response — record it as a notification if it
                    // has a method and no id; otherwise drop silently.
                    if (extractNotification(gpa, data.items)) |n| {
                        try notifications.append(gpa, n);
                    }
                }
                event_type.clearRetainingCapacity();
                data.clearRetainingCapacity();
            },
        }
    }
    return error.McpStreamTooManyEvents;
}

test "formatRequest formats valid JSON-RPC 2.0 request" {
    const gpa = std.testing.allocator;
    const req = try formatRequest(gpa, 1, "initialize", "{\"protocolVersion\":\"2024-11-05\"}");
    defer gpa.free(req);

    try std.testing.expect(std.mem.indexOf(u8, req, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"method\":\"initialize\"") != null);
    // Must be valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, req, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "formatRequest with null params is valid JSON" {
    const gpa = std.testing.allocator;
    const req = try formatRequest(gpa, 2, "tools/list", null);
    defer gpa.free(req);

    // Must be valid JSON — regression test for double-brace bug
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, req, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "formatNotification formats valid JSON-RPC 2.0 notification" {
    const gpa = std.testing.allocator;
    const notif = try formatNotification(gpa, "notifications/initialized", null);
    defer gpa.free(notif);

    try std.testing.expect(std.mem.indexOf(u8, notif, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, notif, "\"method\":\"notifications/initialized\"") != null);
    // Must be valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, notif, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

// ---------------------------------------------------------------------------
// parseMessage tests
// ---------------------------------------------------------------------------

test "parseMessage roundtrips formatRequest with params" {
    const gpa = std.testing.allocator;
    const req = try formatRequest(gpa, 42, "initialize",
        \\{"protocolVersion":"2024-11-05","capabilities":{}}
    );
    defer gpa.free(req);

    const parsed = try parseMessage(gpa, req);
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 42), obj.get("id").?.integer);
    try std.testing.expectEqualStrings("initialize", obj.get("method").?.string);

    const params = obj.get("params").?;
    try std.testing.expect(params == .object);
    try std.testing.expectEqualStrings("2024-11-05", params.object.get("protocolVersion").?.string);
}

test "parseMessage roundtrips formatRequest with null params" {
    const gpa = std.testing.allocator;
    const req = try formatRequest(gpa, 1, "tools/list", null);
    defer gpa.free(req);

    const parsed = try parseMessage(gpa, req);
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expect(obj.get("params") == null);
    try std.testing.expectEqual(@as(i64, 1), obj.get("id").?.integer);
}

test "parseMessage roundtrips formatNotification without params" {
    const gpa = std.testing.allocator;
    const notif = try formatNotification(gpa, "notifications/initialized", null);
    defer gpa.free(notif);

    const parsed = try parseMessage(gpa, notif);
    defer parsed.deinit();

    const obj = parsed.value.object;
    // Notifications have no id
    try std.testing.expect(obj.get("id") == null);
    try std.testing.expectEqualStrings("notifications/initialized", obj.get("method").?.string);
}

test "parseMessage roundtrips formatNotification with params" {
    const gpa = std.testing.allocator;
    const notif = try formatNotification(gpa, "notifications/initialized",
        \\{"protocolVersion":"2024-11-05"}
    );
    defer gpa.free(notif);

    const parsed = try parseMessage(gpa, notif);
    defer parsed.deinit();

    const params = parsed.value.object.get("params").?;
    try std.testing.expectEqualStrings("2024-11-05", params.object.get("protocolVersion").?.string);
}

test "parseMessage roundtrips nested JSON params" {
    const gpa = std.testing.allocator;
    const req = try formatRequest(gpa, 3, "tools/call",
        \\{"name":"search","arguments":{"query":"test","limit":10}}
    );
    defer gpa.free(req);

    const parsed = try parseMessage(gpa, req);
    defer parsed.deinit();

    const args = parsed.value.object.get("params").?.object
        .get("arguments").?;
    try std.testing.expect(args == .object);
    try std.testing.expectEqual(@as(i64, 10), args.object.get("limit").?.integer);
    try std.testing.expectEqualStrings("test", args.object.get("query").?.string);
}

test "parseMessage rejects empty and whitespace-only input" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.EmptyMessage, parseMessage(gpa, ""));
    try std.testing.expectError(error.EmptyMessage, parseMessage(gpa, "   "));
    try std.testing.expectError(error.EmptyMessage, parseMessage(gpa, "\n\r\t"));
}

test "parseMessage rejects malformed JSON" {
    const gpa = std.testing.allocator;
    const malformed = [_][]const u8{
        "{broken",
        "{{{",
        "{\"jsonrpc\":\"2.0\"", // missing closing brace
        "]}",
        "{:}",
    };
    for (malformed) |input| {
        // Any error is acceptable — we just need it to fail, not crash.
        if (parseMessage(gpa, input)) |_| {
            try std.testing.expect(false); // should have failed
        } else |_| {
            // expected
        }
    }
}

test "parseMessage trims trailing newline from formatRequest output" {
    const gpa = std.testing.allocator;
    // formatRequest appends \n — parseMessage should trim it
    const req = try formatRequest(gpa, 1, "ping", null);
    defer gpa.free(req);

    const parsed = try parseMessage(gpa, req);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ping", parsed.value.object.get("method").?.string);
}

test "parseMessage handles large params without truncation" {
    const gpa = std.testing.allocator;
    // Build a params object with >2KB of data
    var params: std.ArrayList(u8) = .empty;
    defer params.deinit(gpa);
    try params.appendSlice(gpa, "{\"data\":\"");
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        try params.append(gpa, 'x');
    }
    try params.appendSlice(gpa, "\"}");

    const req = try formatRequest(gpa, 1, "bulk", params.items);
    defer gpa.free(req);

    const parsed = try parseMessage(gpa, req);
    defer parsed.deinit();

    const data = parsed.value.object.get("params").?.object
        .get("data").?.string;
    try std.testing.expectEqual(@as(usize, 2000), data.len);
}

// ---------------------------------------------------------------------------
// SSE framing tests
// ---------------------------------------------------------------------------

test "classifySseLine distinguishes event, data, blank, and other lines" {
    switch (classifySseLine("event: message")) {
        .event => |e| try std.testing.expectEqualStrings("message", e),
        else => return error.Unexpected,
    }
    switch (classifySseLine("data: {\"id\":1}")) {
        .data => |d| try std.testing.expectEqualStrings("{\"id\":1}", d),
        else => return error.Unexpected,
    }
    try std.testing.expectEqual(SseLine.blank, classifySseLine(""));
    try std.testing.expectEqual(SseLine.blank, classifySseLine("\r"));
    try std.testing.expectEqual(SseLine.other, classifySseLine(": keep-alive comment"));
    try std.testing.expectEqual(SseLine.other, classifySseLine("id: 42"));
    try std.testing.expectEqual(SseLine.other, classifySseLine("retry: 3000"));
}

test "readSseResponse returns the matching response from a single message event" {
    const gpa = std.testing.allocator;
    const stream =
        "event: message\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}\n" ++
        "\n";
    var reader: std.Io.Reader = .fixed(stream);
    var notifications: std.ArrayList(Notification) = .empty;
    defer {
        for (notifications.items) |*n| n.deinit(gpa);
        notifications.deinit(gpa);
    }
    const response = try readSseResponse(gpa, &reader, 7, &notifications);
    defer gpa.free(response);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}", response);
    try std.testing.expectEqual(@as(usize, 0), notifications.items.len);
}

test "readSseResponse accumulates notifications while searching for the response" {
    const gpa = std.testing.allocator;
    const stream =
        "event: message\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n" ++
        "\n" ++
        "event: message\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n" ++
        "\n" ++
        "event: ping\n" ++
        "data: {}\n" ++
        "\n" ++
        "event: message\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"tools\":[]}}\n" ++
        "\n";
    var reader: std.Io.Reader = .fixed(stream);
    var notifications: std.ArrayList(Notification) = .empty;
    defer {
        for (notifications.items) |*n| n.deinit(gpa);
        notifications.deinit(gpa);
    }
    const response = try readSseResponse(gpa, &reader, 3, &notifications);
    defer gpa.free(response);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"tools\":[]}}", response);
    // progress + tools/list_changed captured; the `ping` event is dropped.
    try std.testing.expectEqual(@as(usize, 2), notifications.items.len);
    try std.testing.expectEqualStrings("notifications/progress", notifications.items[0].method);
    try std.testing.expectEqualStrings("notifications/tools/list_changed", notifications.items[1].method);
}

test "readSseResponse joins multi-line data fields" {
    const gpa = std.testing.allocator;
    // Two data: lines in one event are joined with a newline before parsing.
    const stream =
        "data: {\"jsonrpc\":\"2.0\",\"id\":1,\n" ++
        "data: \"result\":{}}\n" ++
        "\n";
    var reader: std.Io.Reader = .fixed(stream);
    var notifications: std.ArrayList(Notification) = .empty;
    defer {
        for (notifications.items) |*n| n.deinit(gpa);
        notifications.deinit(gpa);
    }
    const response = try readSseResponse(gpa, &reader, 1, &notifications);
    defer gpa.free(response);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\n\"result\":{}}", response);
}

test "readSseResponse errors when the stream ends before the response" {
    const gpa = std.testing.allocator;
    const stream =
        "event: message\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}\n" ++
        "\n";
    var reader: std.Io.Reader = .fixed(stream);
    var notifications: std.ArrayList(Notification) = .empty;
    defer {
        for (notifications.items) |*n| n.deinit(gpa);
        notifications.deinit(gpa);
    }
    try std.testing.expectError(error.McpStreamEndedEarly, readSseResponse(gpa, &reader, 1, &notifications));
}

test "readSseResponse treats a default (no event:) event as a message" {
    const gpa = std.testing.allocator;
    const stream = "data: {\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{}}\n\n";
    var reader: std.Io.Reader = .fixed(stream);
    var notifications: std.ArrayList(Notification) = .empty;
    defer {
        for (notifications.items) |*n| n.deinit(gpa);
        notifications.deinit(gpa);
    }
    const response = try readSseResponse(gpa, &reader, 5, &notifications);
    defer gpa.free(response);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{}}", response);
}
