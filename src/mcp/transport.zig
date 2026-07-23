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
    try out.writer.writeAll("}}\n");
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
    try out.writer.writeAll("}}\n");
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
}

test "formatNotification formats valid JSON-RPC 2.0 notification" {
    const gpa = std.testing.allocator;
    const notif = try formatNotification(gpa, "notifications/initialized", null);
    defer gpa.free(notif);

    try std.testing.expect(std.mem.indexOf(u8, notif, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, notif, "\"method\":\"notifications/initialized\"") != null);
}
