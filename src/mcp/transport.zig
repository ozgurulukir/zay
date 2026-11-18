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

/// JSON-RPC 2.0 reserved code for "the method does not exist". Spec-mandated
/// value, used to decline server-initiated requests (#450).
pub const method_not_found_code: i64 = -32601;

/// Format a JSON-RPC 2.0 error response declining a server-initiated request
/// (#450): Zay is a client only and implements no server-requestable
/// methods, so every request the server pushes gets "method not found" —
/// otherwise a server waiting on its request can stall its write side.
pub fn formatErrorResponse(gpa: std.mem.Allocator, id: i64, method: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // The whole message is one JSON string — Stringify owns the quoting and
    // escaping (embedding a second quote layer would terminate the string
    // mid-value and invalidate the frame).
    const message = try std.fmt.allocPrint(gpa, "Method not found: {s}", .{method});
    defer gpa.free(message);
    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":", .{ id, method_not_found_code });
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeAll("}}\n");
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

/// Aggregate bounds on the server notifications accumulated while one SSE
/// response is being searched for (#450). The per-event bounds alone allowed
/// `sse_event_max` events of `sse_data_bytes_max` each — ~100 GB — to pile
/// up in memory when a server streams notifications but never the response.
/// The byte cap equals the single-event cap: total notification traffic
/// during one response read never exceeds what one event may cost.
pub const sse_notification_max: u32 = 10_000;
pub const sse_notification_bytes_max: u32 = sse_data_bytes_max;

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

const sse_event_type_max: usize = 4096;

/// Read one `\n`-terminated SSE line (delimiter stripped), bounded by `max_bytes`.
/// Returns null at end of stream when no trailing bytes remain.
fn readSseLine(gpa: std.mem.Allocator, reader: *std.Io.Reader, max_bytes: usize) !?[]u8 {
    var line: std.Io.Writer.Allocating = .init(gpa);
    errdefer line.deinit();
    _ = reader.streamDelimiterLimit(&line.writer, '\n', .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.McpStreamTooLarge,
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

/// Extract the JSON-RPC response `id` from a payload, or null when the
/// payload is not a response with an integer `id` (notifications and
/// server-initiated requests carry a `method`; malformed input parses to
/// nothing). Shared by the SSE matcher and the HTTP JSON-body id check
/// (#450): both must answer "does this message belong to request N".
pub fn responseId(gpa: std.mem.Allocator, payload: []const u8) ?i64 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    if (obj.get("method") != null) return null;
    const id_val = obj.get("id") orelse return null;
    if (id_val != .integer) return null;
    return id_val.integer;
}

/// True when `payload` is a JSON-RPC **response** (has an `id`, a `result` or
/// `error`, and no `method`) whose `id` equals `request_id`. Server-initiated
/// requests/notifications carry a `method` and are rejected here.
fn isResponseForId(gpa: std.mem.Allocator, payload: []const u8, request_id: i64) bool {
    const id = responseId(gpa, payload) orelse return false;
    return id == request_id;
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
/// them. Bounded by `sse_event_max` / `sse_data_bytes_max` per event and by
/// the aggregate notification caps (#450): a server that streams
/// notifications but never the response errors out instead of piling up
/// unbounded memory.
pub fn readSseResponse(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    request_id: i64,
    notifications: *std.ArrayList(Notification),
) ![]u8 {
    return readSseResponseBounded(
        gpa,
        reader,
        request_id,
        notifications,
        sse_notification_max,
        sse_notification_bytes_max,
    );
}

/// Core of `readSseResponse` with explicit aggregate notification caps —
/// the public wrapper freezes the call sites; tests exercise the caps with
/// small values so the flood path stays cheap to run.
fn readSseResponseBounded(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    request_id: i64,
    notifications: *std.ArrayList(Notification),
    notification_count_max: u32,
    notification_bytes_max: usize,
) ![]u8 {
    var event_type: std.ArrayList(u8) = .empty;
    defer event_type.deinit(gpa);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    var events_seen: u32 = 0;
    var notifications_seen: u32 = 0;
    var notification_bytes_total: usize = 0;
    while (events_seen < sse_event_max) {
        const line = (try readSseLine(gpa, reader, sse_data_bytes_max)) orelse return error.McpStreamEndedEarly;
        defer gpa.free(line);
        switch (classifySseLine(line)) {
            .event => |e| {
                if (event_type.items.len + e.len > sse_event_type_max) return error.McpStreamTooLarge;
                try event_type.appendSlice(gpa, e);
            },
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
                    // has a method and no id; otherwise drop silently. The
                    // aggregate caps bound what a notification-flooding
                    // server can make us hold (#450).
                    if (extractNotification(gpa, data.items)) |extracted| {
                        var n = extracted;
                        const next_count = notifications_seen + 1;
                        const next_bytes = notification_bytes_total + n.payload.len + n.method.len;
                        if (next_count > notification_count_max or next_bytes > notification_bytes_max) {
                            n.deinit(gpa);
                            return error.McpStreamTooLarge;
                        }
                        notifications.append(gpa, n) catch {
                            n.deinit(gpa);
                            return error.OutOfMemory;
                        };
                        notifications_seen = next_count;
                        notification_bytes_total = next_bytes;
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

test "readSseLine aborts with McpStreamTooLarge on oversized line (#412)" {
    const gpa = std.testing.allocator;
    const payload = "data: " ++ ("x" ** 64);
    var reader: std.Io.Reader = .fixed(payload);
    try std.testing.expectError(error.McpStreamTooLarge, readSseLine(gpa, &reader, 32));
}

test "readSseResponse aborts with McpStreamTooLarge on oversized event type (#412)" {
    const gpa = std.testing.allocator;
    const huge_event = "event: " ++ ("a" ** (sse_event_type_max + 1)) ++ "\n\n";
    var reader: std.Io.Reader = .fixed(huge_event);
    var notifications: std.ArrayList(Notification) = .empty;
    defer {
        for (notifications.items) |*n| n.deinit(gpa);
        notifications.deinit(gpa);
    }
    try std.testing.expectError(error.McpStreamTooLarge, readSseResponse(gpa, &reader, 1, &notifications));
}

// ---------------------------------------------------------------------------
// Response-id matching and server-request decline (#450)
// ---------------------------------------------------------------------------

test "responseId extracts the id from responses and rejects everything else" {
    const gpa = std.testing.allocator;

    // A response (result or error, no method) carries its id.
    try std.testing.expectEqual(@as(?i64, 7), responseId(gpa, "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}"));
    try std.testing.expectEqual(@as(?i64, 7), responseId(gpa, "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":1,\"message\":\"x\"}}"));

    // Notifications and server-initiated requests carry a method — never ours.
    try std.testing.expectEqual(@as(?i64, null), responseId(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}"));
    try std.testing.expectEqual(@as(?i64, null), responseId(gpa, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"sampling/createMessage\"}"));

    // Malformed or non-integer ids cannot be matched.
    try std.testing.expectEqual(@as(?i64, null), responseId(gpa, "this is not json"));
    try std.testing.expectEqual(@as(?i64, null), responseId(gpa, "{\"jsonrpc\":\"2.0\",\"id\":\"7\",\"result\":{}}"));
    try std.testing.expectEqual(@as(?i64, null), responseId(gpa, "{\"jsonrpc\":\"2.0\",\"result\":{}}"));
}

test "formatErrorResponse declines a server request with the spec method-not-found code" {
    const gpa = std.testing.allocator;
    const reply = try formatErrorResponse(gpa, 900, "sampling/createMessage");
    defer gpa.free(reply);

    try std.testing.expect(std.mem.indexOf(u8, reply, "\"id\":900") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"code\":-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Method not found") != null);
    // The method name is JSON-escaped and the frame is newline-terminated.
    try std.testing.expect(std.mem.indexOf(u8, reply, "sampling/createMessage") != null);
    try std.testing.expect(std.mem.endsWith(u8, reply, "\"}}\n"));
}

// ---------------------------------------------------------------------------
// Aggregate notification flood caps (#450)
// ---------------------------------------------------------------------------

test "readSseResponse aborts when notifications flood past the aggregate count cap (#450)" {
    const gpa = std.testing.allocator;
    // Each notification is tiny — the per-event bounds never fire; the
    // aggregate COUNT cap does. Building the stream past the cap proves the
    // reader errors instead of accumulating unbounded work.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    const notification = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n";
    const count_max = sse_notification_max + 1;
    try stream.ensureTotalCapacity(gpa, notification.len * count_max);
    var i: u32 = 0;
    while (i < count_max) : (i += 1) try stream.appendSlice(gpa, notification);

    var reader: std.Io.Reader = .fixed(stream.items);
    var notifications: std.ArrayList(Notification) = .empty;
    defer {
        for (notifications.items) |*n| n.deinit(gpa);
        notifications.deinit(gpa);
    }
    try std.testing.expectError(error.McpStreamTooLarge, readSseResponse(gpa, &reader, 1, &notifications));
}

test "readSseResponse aborts when notification bytes flood past the aggregate byte cap (#450)" {
    const gpa = std.testing.allocator;
    // Two fat notifications against a small test bound on the core reader:
    // the accumulated BYTES exceed the cap long before the count does.
    const bytes_max: usize = 64 * 1024;
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    const event = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"blob\":\"" ++ ("x" ** (48 * 1024)) ++ "\"}}\n\n";
    try stream.appendSlice(gpa, event);
    try stream.appendSlice(gpa, event);
    try stream.appendSlice(gpa, event);

    var reader: std.Io.Reader = .fixed(stream.items);
    var notifications: std.ArrayList(Notification) = .empty;
    defer {
        for (notifications.items) |*n| n.deinit(gpa);
        notifications.deinit(gpa);
    }
    try std.testing.expectError(error.McpStreamTooLarge, readSseResponseBounded(gpa, &reader, 1, &notifications, sse_notification_max, bytes_max));
}
