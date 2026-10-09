//! Recognition of admitted skill instructions, shared by rehydration and requests.
const std = @import("std");
const ai = @import("../ai.zig");
const skill = @import("../skill.zig");
const skill_tool = @import("../tools/skill.zig");
const SkillContext = @import("skill_context.zig").SkillContext;

const Inline = struct { name: []const u8, body: []const u8, end: usize };

/// Only complete blocks at the beginning of a user message are legacy evidence.
/// The location and reference preamble distinguish generated blocks from mentions.
fn inlineBlock(text: []const u8, offset: usize) ?Inline {
    const marker = "<skill name=\"";
    if (!std.mem.startsWith(u8, text[offset..], marker)) return null;
    const name_start = offset + marker.len;
    const name_end = std.mem.indexOfScalarPos(u8, text, name_start, '"') orelse return null;
    const location = "\" location=\"";
    if (!std.mem.startsWith(u8, text[name_end..], location)) return null;
    const header_end = std.mem.indexOfPos(u8, text, name_end + location.len, "\">\nReferences are relative to ") orelse return null;
    const preamble_end = std.mem.indexOfPos(u8, text, header_end, ".\n\n") orelse return null;
    const body_start = preamble_end + 3;
    const body_end = std.mem.indexOfPos(u8, text, body_start, "\n</skill>") orelse return null;
    return .{ .name = text[name_start..name_end], .body = text[body_start..body_end], .end = body_end + "\n</skill>".len };
}

pub fn toolCall(messages: []const ai.ChatMessage, index: usize) ?ai.ToolCall {
    if (messages[index] != .tool) return null;
    const result_id = messages[index].tool.call_id.slice();
    var previous = index;
    while (previous > 0) {
        previous -= 1;
        const message = messages[previous];
        if (message != .assistant) continue;
        for (message.assistant.content) |block| {
            if (block == .tool_call and std.mem.eql(u8, block.tool_call.call_id.slice(), result_id)) return block.tool_call;
        }
        return null;
    }
    return null;
}

fn admit(context: *SkillContext, gpa: std.mem.Allocator, name: []const u8, body: []const u8) !void {
    _ = context.activate(gpa, name, body) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.log.scoped(.skill_context).warn("legacy skill skipped: {s}", .{@errorName(err)});
        return;
    };
}

/// Enrich a temporary projection before its live swap. Never infer names from
/// arbitrary tool text: require an explicit skill call and a successful result.
pub fn rebuild(context: *SkillContext, gpa: std.mem.Allocator, messages: []const ai.ChatMessage, skills: []const skill.Skill) !void {
    for (messages, 0..) |message, index| {
        if (message == .user) {
            const text = message.text();
            var offset: usize = 0;
            while (inlineBlock(text, offset)) |block| {
                const name = if (skill.find(skills, block.name)) |source| source.name else block.name;
                try admit(context, gpa, name, block.body);
                offset = block.end;
                while (offset < text.len and text[offset] == '\n') offset += 1;
            }
        } else if (message == .tool and !message.tool.failed) {
            const call = toolCall(messages, index) orelse continue;
            if (!std.mem.eql(u8, call.name, "skill")) continue;
            var args = skill_tool.parseArgs(gpa, call.arguments) catch |err| {
                if (err == error.OutOfMemory) return err;
                continue;
            };
            defer args.deinit(gpa);
            if (args.resource != null or args.command != null) continue;
            if (context.contains(args.name)) continue;
            if (message.tool.content.len != 1 or message.tool.content[0] != .text) continue;
            const instructions = message.text();
            if (std.mem.eql(u8, instructions, @import("skill_context.zig").loaded_notice)) continue;
            // Persisted successful results are authoritative even if discovery
            // now returns a changed body. Request pruning never edits history.
            try admit(context, gpa, args.name, instructions);
        }
    }
}

pub fn retainedTool(context: *const SkillContext, messages: []const ai.ChatMessage, index: usize) bool {
    const message = messages[index];
    if (message != .tool or message.tool.failed) return false;
    const call = toolCall(messages, index) orelse return false;
    if (!std.mem.eql(u8, call.name, "skill")) return false;
    for (context.entries.items) |entry| {
        if (std.mem.eql(u8, entry.body, message.text())) return true;
    }
    return false;
}

fn represented(entry: SkillContext.Entry, messages: []const ai.ChatMessage) bool {
    for (messages, 0..) |message, index| {
        if (message == .user) {
            const text = message.text();
            var offset: usize = 0;
            while (inlineBlock(text, offset)) |block| {
                if (std.ascii.eqlIgnoreCase(entry.name, block.name) and std.mem.eql(u8, entry.body, block.body)) return true;
                offset = block.end;
                while (offset < text.len and text[offset] == '\n') offset += 1;
            }
        } else if (message == .tool and !message.tool.failed and std.mem.eql(u8, entry.body, message.text())) {
            const call = toolCall(messages, index) orelse continue;
            if (std.mem.eql(u8, call.name, "skill")) return true;
        }
    }
    return false;
}

const opening = "[Activated skill instructions retained from this conversation]\n";
const block_open = "<skill name=\"";
const block_middle = "\">\n";
const block_close = "\n</skill>\n";

pub fn missingBytes(context: *const SkillContext, messages: []const ai.ChatMessage) usize {
    var bytes: usize = 0;
    for (context.entries.items) |entry| {
        if (represented(entry, messages)) continue;
        bytes += block_open.len + entry.name.len + block_middle.len + entry.body.len + block_close.len;
    }
    return if (bytes == 0) 0 else opening.len + bytes;
}

pub fn formatMissing(context: *const SkillContext, gpa: std.mem.Allocator, messages: []const ai.ChatMessage) !?[]u8 {
    if (missingBytes(context, messages) == 0) return null;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll(opening);
    for (context.entries.items) |entry| {
        if (represented(entry, messages)) continue;
        try out.writer.print("{s}{s}{s}{s}{s}", .{ block_open, entry.name, block_middle, entry.body, block_close });
    }
    return try out.toOwnedSlice();
}

test "skill context legacy inline reconstructs missing source and ignores incomplete markers" {
    const gpa = std.testing.allocator;
    var ledger: SkillContext = .{};
    defer ledger.deinit(gpa);
    var blocks = [_]ai.ContentBlock{.{ .text = .{ .text = @constCast("<skill name=\"how\" location=\"/deleted/SKILL.md\">\nReferences are relative to /deleted.\n\nSaved instructions\n</skill>\n\n$how") } }};
    const messages = [_]ai.ChatMessage{.{ .user = .{ .content = &blocks } }};
    try rebuild(&ledger, gpa, &messages, &.{});
    try std.testing.expectEqualStrings("Saved instructions", ledger.body("how").?);
    try std.testing.expectEqual(@as(usize, 0), missingBytes(&ledger, &messages));
    try rebuild(&ledger, gpa, &messages, &.{});
    try std.testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
    blocks[0].text.text = @constCast("<skill name=\"why\" location=\"/missing\">\nReferences are relative to /missing.\n\nIncomplete");
    try rebuild(&ledger, gpa, &messages, &.{});
    try std.testing.expect(!ledger.contains("why"));
    const missing = (try formatMissing(&ledger, gpa, &messages)).?;
    defer gpa.free(missing);
    try std.testing.expectEqual(missing.len, missingBytes(&ledger, &messages));
}

test "skill context legacy tool reconstruction requires a successful correlated call" {
    const gpa = std.testing.allocator;
    var ledger: SkillContext = .{};
    defer ledger.deinit(gpa);
    var calls = [_]ai.ContentBlock{.{ .tool_call = .{
        .call_id = .{ .value = @constCast("call") },
        .name = @constCast("skill"),
        .arguments = @constCast("{\"name\":\"how\"}"),
    } }};
    var result = [_]ai.ContentBlock{.{ .text = .{ .text = @constCast("Saved model-loaded instructions") } }};
    var messages = [_]ai.ChatMessage{
        .{ .assistant = .{ .content = &calls } },
        .{ .tool = .{ .call_id = .{ .value = @constCast("wrong-id") }, .content = &result } },
    };
    try rebuild(&ledger, gpa, &messages, &.{});
    try std.testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
    messages[1].tool.call_id.value = @constCast("call");
    messages[1].tool.failed = true;
    try rebuild(&ledger, gpa, &messages, &.{});
    try std.testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
    messages[1].tool.failed = false;
    calls[0].tool_call.arguments = @constCast("{\"name\":\"how\",\"resource\":\"references/rubric.md\"}");
    try rebuild(&ledger, gpa, &messages, &.{});
    try std.testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
    calls[0].tool_call.arguments = @constCast("{\"name\":\"how\",\"command\":\"python3 scripts/check.py\"}");
    try rebuild(&ledger, gpa, &messages, &.{});
    try std.testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
    calls[0].tool_call.arguments = @constCast("{\"name\":\"how\"}");
    const changed_source = [_]skill.Skill{.{
        .name = @constCast("how"),
        .description = @constCast(""),
        .path = @constCast("/skills/how/SKILL.md"),
        .base_dir = @constCast("/skills/how"),
        .body = @constCast("New instructions from the edited file"),
    }};
    try rebuild(&ledger, gpa, &messages, &changed_source);
    try std.testing.expectEqualStrings("Saved model-loaded instructions", ledger.body("how").?);
    try std.testing.expect(retainedTool(&ledger, &messages, 1));
    try rebuild(&ledger, gpa, &messages, &.{});
    try std.testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
}

/// Replace generated inline bodies only in the summarizer projection.
pub fn writeInlineNotices(out: *std.Io.Writer, text: []const u8, context: *const SkillContext) ![]const u8 {
    var offset: usize = 0;
    while (inlineBlock(text, offset)) |block| {
        const retained = context.body(block.name) orelse break;
        if (!std.mem.eql(u8, retained, block.body)) break;
        try out.print("[skill activated]: {s} (full instructions retained in session skill_context metadata)\n", .{block.name});
        offset = block.end;
        while (offset < text.len and text[offset] == '\n') offset += 1;
    }
    return text[offset..];
}
