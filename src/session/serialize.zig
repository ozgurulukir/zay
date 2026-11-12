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

test "titleFromUserMessage takes the first line and trims whitespace" {
    const gpa = std.testing.allocator;
    {
        const title = (try titleFromUserMessage(gpa, "  fix the parser bug  \n\nsecond line")).?;
        defer gpa.free(title);
        try std.testing.expectEqualStrings("fix the parser bug", title);
    }
    // Whitespace-only content has no title (the trim set includes newlines,
    // so even "\nhello" yields a title, not null).
    try std.testing.expectEqual(@as(?[]u8, null), try titleFromUserMessage(gpa, "   \r\n\t "));
    {
        const title = (try titleFromUserMessage(gpa, "\nhello")).?;
        defer gpa.free(title);
        try std.testing.expectEqualStrings("hello", title);
    }
    {
        const title = (try titleFromUserMessage(gpa, "short")).?;
        defer gpa.free(title);
        try std.testing.expectEqualStrings("short", title);
    }
}

test "titleFromUserMessage truncates long titles on a UTF-8 boundary" {
    const gpa = std.testing.allocator;
    // 81 ASCII characters: longer than the 80-char title cap.
    const long = "x" ** 81;
    const title = (try titleFromUserMessage(gpa, long)).?;
    defer gpa.free(title);
    try std.testing.expect(title.len < 84); // cut + "..."
    try std.testing.expect(std.mem.endsWith(u8, title, "..."));

    // A multi-byte sequence straddling the cut must not be split mid-codepoint.
    // With 76 ASCII bytes the byte at index 77 (the cut limit) is the middle
    // continuation byte of the first check mark, so utf8PrefixLen's backup
    // loop actually walks 77 -> 76 before landing on the lead byte.
    const straddle = "a" ** 76 ++ "\xe2\x9c\x93\xe2\x9c\x93"; // two check marks
    const cut_title = (try titleFromUserMessage(gpa, straddle)).?;
    defer gpa.free(cut_title);
    const body = cut_title[0 .. cut_title.len - 3];
    // The cut lands on the lead byte of the check mark: exactly 76 bytes.
    try std.testing.expectEqual(@as(usize, 76), body.len);
    // The prefix must end on a codepoint boundary (no stray continuation bytes).
    try std.testing.expect((body[body.len - 1] & 0xc0) != 0x80);
}

test "utf8PrefixLen never splits a multi-byte codepoint" {
    const text = "ab" ++ "\xe2\x9c\x93" ++ "cd"; // a, b, ✓(3 bytes), c, d
    // Limit inside the ✓ sequence backs up to its start (after "ab").
    try std.testing.expectEqual(@as(u32, 2), utf8PrefixLen(text, 3));
    try std.testing.expectEqual(@as(u32, 2), utf8PrefixLen(text, 4));
    // Limit after the full codepoint keeps it whole.
    try std.testing.expectEqual(@as(u32, 5), utf8PrefixLen(text, 5));
}

test "compaction payload round-trips through toJson and its parsers" {
    const gpa = std.testing.allocator;
    const first_kept = "0123abcd";
    const payload = try compactionToJson(gpa, first_kept, "kept the summary of everything before");
    defer gpa.free(payload);

    {
        const parsed_id = try compactionFirstKeptId(gpa, payload);
        try std.testing.expectEqualSlices(u8, first_kept, &parsed_id);
    }
    {
        const summary = try compactionSummaryText(gpa, payload);
        defer gpa.free(summary);
        try std.testing.expectEqualStrings("kept the summary of everything before", summary);
    }
    // Corrupt payloads are reported, not silently accepted.
    try std.testing.expectError(error.CorruptPayload, compactionFirstKeptId(gpa, "not json"));
    try std.testing.expectError(error.BadEntryId, compactionFirstKeptId(gpa, "{\"first_kept_id\":\"short\"}"));
}

test "optionalString and optionalBool distinguish absent from corrupt" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"name":"zay","flag":true,"count":3}
    , .{});
    defer parsed.deinit();
    const value = parsed.value;

    {
        const name = (try optionalString(gpa, value, "name")).?;
        defer gpa.free(name);
        try std.testing.expectEqualStrings("zay", name);
    }
    // Absent field → null; present but non-string → error.
    try std.testing.expectEqual(@as(?[]u8, null), try optionalString(gpa, value, "missing"));
    try std.testing.expectError(error.CorruptPayload, optionalString(gpa, value, "count"));

    try std.testing.expect(try optionalBool(value, "flag"));
    // Absent field defaults to false; present but non-bool → error.
    try std.testing.expect(!try optionalBool(value, "missing"));
    try std.testing.expectError(error.CorruptPayload, optionalBool(value, "name"));
}

test "titleToJson escapes quotes for embedding in stored payloads" {
    const gpa = std.testing.allocator;
    const encoded = try titleToJson(gpa, "say \"hi\" \\ back");
    defer gpa.free(encoded);
    // The escaping must produce valid JSON that parses back to the title.
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("say \"hi\" \\ back", parsed.value.object.get("title").?.string);
}
