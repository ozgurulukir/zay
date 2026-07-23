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
