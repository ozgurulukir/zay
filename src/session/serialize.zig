//! JSON serialization helpers for session entry payloads.
//!
//! Pure functions converting between `ai.ChatMessage` / entry metadata and
//! their JSON wire format stored in sqlite `payload_json` columns. No DB
//! access, no Session/SessionManager dependency — imported by both
//! `session.zig` (read path) and `session/writer.zig` (write path).

const std = @import("std");
const ai = @import("../ai.zig");

const session_type = @import("types.zig");
const entry_id_len = session_type.entry_id_len;
const Error = session_type.Error;

const assert = std.debug.assert;

pub fn messageToJson(gpa: std.mem.Allocator, message: ai.ChatMessage) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(message.role().label(), .{}, writer);
    if (message == .tool) {
        try writer.writeAll(",\"call_id\":");
        try std.json.Stringify.value(message.tool.call_id.slice(), .{}, writer);
        if (message.tool.display_label) |label| {
            try writer.writeAll(",\"tool_display_label\":");
            try std.json.Stringify.value(label, .{}, writer);
        }
        if (message.tool.failed) try writer.writeAll(",\"tool_failed\":true");
    }
    try writer.writeAll(",\"content\":[");
    const content: []const ai.ContentBlock = switch (message) {
        inline .system, .user, .assistant => |m| m.content,
        .tool => |t| t.content,
    };
    for (content, 0..) |block, index| {
        if (index > 0) try writer.writeByte(',');
        try block.writeJson(writer);
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

pub fn jsonToMessage(gpa: std.mem.Allocator, payload_json: []const u8) Error!ai.ChatMessage {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload_json, .{}) catch return error.CorruptPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CorruptPayload;
    const role_value = parsed.value.object.get("role") orelse return error.CorruptPayload;
    if (role_value != .string) return error.CorruptPayload;
    const role = ai.Role.fromString(role_value.string) catch return error.CorruptPayload;
    const call_id = try optionalString(gpa, parsed.value, "call_id");
    errdefer if (call_id) |id| gpa.free(id);
    const tool_display_label = try optionalString(gpa, parsed.value, "tool_display_label");
    errdefer if (tool_display_label) |label| gpa.free(label);
    const tool_failed = try optionalBool(parsed.value, "tool_failed");
    const content_value = parsed.value.object.get("content") orelse return error.CorruptPayload;
    const content = try parseContentBlocks(gpa, content_value);
    errdefer freeContentBlocks(gpa, content);
    return switch (role) {
        .system => .{ .system = .{ .content = content } },
        .user => .{ .user = .{ .content = content } },
        .assistant => .{ .assistant = .{ .content = content } },
        .tool => .{
            .tool = .{
                .content = content,
                .call_id = .{ .value = call_id orelse return error.CorruptPayload },
                .display_label = tool_display_label,
                .failed = tool_failed,
            },
        },
    };
}

pub fn branchSummaryToMessage(gpa: std.mem.Allocator, payload_json: []const u8) Error!ai.ChatMessage {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload_json, .{}) catch return error.CorruptPayload;
    defer parsed.deinit();
    const summary = parsed.value.object.get("summary") orelse return error.CorruptPayload;
    if (summary != .string) return error.CorruptPayload;
    const content = try std.fmt.allocPrint(gpa, "Branch summary: {s}", .{summary.string});
    errdefer gpa.free(content);
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = content } };
    return .{ .user = .{ .content = blocks } };
}

pub fn parseContentBlocks(gpa: std.mem.Allocator, value: std.json.Value) Error![]ai.ContentBlock {
    if (value == .string) {
        const blocks = try gpa.alloc(ai.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, value.string) } };
        return blocks;
    }
    if (value != .array) return error.CorruptPayload;
    const blocks = try gpa.alloc(ai.ContentBlock, value.array.items.len);
    var initialized: usize = 0;
    errdefer freeContentBlocks(gpa, blocks[0..initialized]);
    for (value.array.items) |item| {
        blocks[initialized] = try ai.ContentBlock.fromJson(gpa, item);
        initialized += 1;
    }
    return blocks;
}

pub fn freeContentBlocks(gpa: std.mem.Allocator, blocks: []ai.ContentBlock) void {
    for (blocks) |*block| block.deinit(gpa);
    gpa.free(blocks);
}

pub fn parseToolCalls(gpa: std.mem.Allocator, value: std.json.Value) Error![]const ai.ToolCall {
    const calls_value = value.object.get("tool_calls") orelse return &.{};
    if (calls_value != .array) return error.CorruptPayload;
    const calls = try gpa.alloc(ai.ToolCall, calls_value.array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (calls[0..initialized]) |*call| call.deinit(gpa);
        gpa.free(calls);
    }
    for (calls_value.array.items) |item| {
        if (item != .object) return error.CorruptPayload;
        const id = item.object.get("id") orelse return error.CorruptPayload;
        const name = item.object.get("name") orelse return error.CorruptPayload;
        const arguments = item.object.get("arguments") orelse return error.CorruptPayload;
        if (id != .string) return error.CorruptPayload;
        if (name != .string) return error.CorruptPayload;
        if (arguments != .string) return error.CorruptPayload;
        calls[initialized] = .{
            .call_id = .{ .value = try gpa.dupe(u8, id.string) },
            .name = try gpa.dupe(u8, name.string),
            .arguments = try gpa.dupe(u8, arguments.string),
        };
        initialized += 1;
    }
    return calls;
}

pub fn optionalString(gpa: std.mem.Allocator, value: std.json.Value, name: []const u8) Error!?[]u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return error.CorruptPayload;
    return try gpa.dupe(u8, field.string);
}

pub fn optionalBool(value: std.json.Value, name: []const u8) Error!bool {
    const field = value.object.get(name) orelse return false;
    if (field != .bool) return error.CorruptPayload;
    return field.bool;
}
pub fn titleToJson(gpa: std.mem.Allocator, title: []const u8) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"title\":");
    try std.json.Stringify.value(title, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

pub fn branchSummaryToJson(gpa: std.mem.Allocator, from_id: []const u8, summary: []const u8) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"from_id\":");
    try std.json.Stringify.value(from_id, .{}, &out.writer);
    try out.writer.writeAll(",\"summary\":");
    try std.json.Stringify.value(summary, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}
pub fn compactionToJson(gpa: std.mem.Allocator, first_kept_id: []const u8, summary: []const u8) Error![]u8 {
    assert(first_kept_id.len == entry_id_len);
    assert(summary.len > 0);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"first_kept_id\":");
    try std.json.Stringify.value(first_kept_id, .{}, &out.writer);
    try out.writer.writeAll(",\"summary\":");
    try std.json.Stringify.value(summary, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

pub fn compactionFirstKeptId(gpa: std.mem.Allocator, payload_json: []const u8) Error![entry_id_len]u8 {
    assert(payload_json.len > 0);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload_json, .{}) catch return error.CorruptPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CorruptPayload;
    const field = parsed.value.object.get("first_kept_id") orelse return error.CorruptPayload;
    if (field != .string) return error.CorruptPayload;
    if (field.string.len != entry_id_len) return error.BadEntryId;
    var bytes: [entry_id_len]u8 = undefined;
    @memcpy(bytes[0..], field.string);
    return bytes;
}

pub fn compactionSummaryToMessage(gpa: std.mem.Allocator, payload_json: []const u8) Error!ai.ChatMessage {
    const summary = try compactionSummaryText(gpa, payload_json);
    errdefer gpa.free(summary);
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    errdefer gpa.free(blocks);
    blocks[0] = .{ .text = .{ .text = summary } };
    return .{ .user = .{ .content = blocks } };
}

pub fn compactionSummaryText(gpa: std.mem.Allocator, payload_json: []const u8) Error![]u8 {
    assert(payload_json.len > 0);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, payload_json, .{}) catch return error.CorruptPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CorruptPayload;
    const summary = parsed.value.object.get("summary") orelse return error.CorruptPayload;
    if (summary != .string) return error.CorruptPayload;
    return gpa.dupe(u8, summary.string);
}
pub fn titleFromUserMessage(gpa: std.mem.Allocator, content: []const u8) Error!?[]u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return null;
    const line_end = std.mem.findScalar(u8, trimmed, '\n') orelse trimmed.len;
    const line = std.mem.trim(u8, trimmed[0..line_end], " \t\r");
    if (line.len == 0) return null;
    const title_max: u32 = 80;
    if (line.len <= title_max) return try gpa.dupe(u8, line);
    const cut = utf8PrefixLen(line, title_max - 3);
    return try std.fmt.allocPrint(gpa, "{s}...", .{line[0..cut]});
}

pub fn utf8PrefixLen(text: []const u8, limit: u32) u32 {
    assert(limit < text.len);
    var end: u32 = limit;
    while (end > 0) : (end -= 1) {
        if ((text[end] & 0xc0) != 0x80) return end;
    }
    return limit;
}
