//! context_assembly.zig — Professional Coding Agent Context Assembly Engine
//!
//! Provides state-of-the-art context assembly for Nova Agent:
//!   1. Dynamic Environment & Repository Context Injection (CWD, OS, Git Branch/Status, Date/Time).
//!   2. Multi-convention Project Rule Ingestion (AGENTS.md, .cursorrules, CLAUDE.md, CONVENTIONS.md).
//!   3. Historical Tool Result Pruning (Context Compression for Active Turns): Keeps recent tool outputs
//!      in full, while capping/truncating ancient tool outputs in the prompt to prevent context bloat.
//!   4. Attachment Budgeting: Per-file and aggregate byte limits for @-mention file inlining.
//!   5. Context Budget Metrics: High-level usage breakdown (system, history, tool output, margin).

const std = @import("std");
const ai = @import("ai.zig");
const at_mention = @import("at_mention.zig");
const compaction = @import("compaction.zig");
const os = @import("os.zig");
const skill_mod = @import("skill.zig");
const vcs = @import("vcs.zig");

const assert = std.debug.assert;

/// Default byte limit per historical tool result when pruned.
pub const default_historical_tool_cap_bytes: u32 = 1024;
/// Number of recent tool result turns kept in full before historical pruning kicks in.
pub const default_keep_recent_tool_turns: u32 = 4;
/// Maximum bytes allowed per individual @-mention text file inlining.
pub const default_per_file_mention_max_bytes: usize = 64 * 1024;
/// Maximum total aggregate bytes allowed for all @-mention text files in a single turn.
pub const default_turn_mention_aggregate_max_bytes: usize = 256 * 1024;

/// Known project instruction files to automatically ingest if present in workspace root.
const project_rule_filenames = [_][]const u8{
    "AGENTS.md",
    ".cursorrules",
    "CLAUDE.md",
    "CONVENTIONS.md",
};

pub const ContextBudget = struct {
    system_tokens: u32,
    history_tokens: u32,
    tool_result_tokens: u32,
    total_tokens: u32,
    context_window: u32,

    pub fn usageRatio(self: ContextBudget) f32 {
        if (self.context_window == 0) return 0.0;
        return @as(f32, @floatFromInt(self.total_tokens)) / @as(f32, @floatFromInt(self.context_window));
    }

    pub fn remainingTokens(self: ContextBudget) u32 {
        if (self.total_tokens >= self.context_window) return 0;
        return self.context_window - self.total_tokens;
    }
};

/// Assembles the complete system prompt for a turn with dynamic environment,
/// git metadata, ingested project rules, and active skills.
pub fn assembleSystemPrompt(
    gpa: std.mem.Allocator,
    io: std.Io,
    base_template: []const u8,
    cwd: []const u8,
    skills: []const skill_mod.Skill,
) ![]u8 {
    assert(base_template.len > 0);
    assert(cwd.len > 0);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // 1. Substitute CWD and OS in base prompt
    const base_substituted = try substituteBaseTemplate(gpa, base_template, cwd);
    defer gpa.free(base_substituted);
    try out.writer.writeAll(base_substituted);

    // 2. Append Git environment details if in a repo
    if (vcs.isRepo(gpa, io, cwd)) {
        const maybe_branch = vcs.currentBranch(gpa, io, cwd);
        defer if (maybe_branch) |b| gpa.free(b);
        const is_dirty = vcs.workingTreeDirty(gpa, io, cwd) catch false;

        try out.writer.print("\n\n<git_environment>\n", .{});
        if (maybe_branch) |branch| {
            try out.writer.print("Branch: {s}\n", .{branch});
        } else {
            try out.writer.print("Branch: (detached HEAD)\n", .{});
        }
        try out.writer.print("Working Tree Status: {s}\n", .{if (is_dirty) "modified (dirty)" else "clean"});
        try out.writer.print("</git_environment>", .{});
    }

    // 3. Multi-convention project rule ingestion
    for (project_rule_filenames) |rule_filename| {
        if (try readProjectRuleFile(gpa, io, cwd, rule_filename)) |content| {
            defer gpa.free(content);
            try out.writer.print("\n\n<project_instructions path=\"{s}\">\n{s}\n</project_instructions>", .{ rule_filename, content });
        }
    }

    // 4. Append Skills
    const skill_prompt = try skill_mod.formatForPrompt(gpa, skills);
    defer gpa.free(skill_prompt);
    if (skill_prompt.len > 0) {
        try out.writer.writeAll("\n\n");
        try out.writer.writeAll(skill_prompt);
    }

    return out.toOwnedSlice();
}

/// Prunes historical tool results in conversation history before sending to the model.
/// Keeps recent tool turns (`keep_recent_tool_turns`) in full, while capping older tool output text
/// at `historical_tool_cap_bytes`. Leaves tool call IDs, roles, labels, and failed flags intact.
/// Caller owns the returned slice and must free with `freePrunedMessages`.
pub fn pruneHistoricalToolResults(
    gpa: std.mem.Allocator,
    messages: []const ai.ChatMessage,
    keep_recent_tool_turns: u32,
    historical_tool_cap_bytes: u32,
) ![]ai.ChatMessage {
    var result = try gpa.alloc(ai.ChatMessage, messages.len);
    errdefer gpa.free(result);

    // Count tool result turns backwards to find cutoff
    var tool_turns_seen: u32 = 0;
    var cutoff_index: usize = messages.len;
    var i: usize = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i].role == .tool) {
            tool_turns_seen += 1;
            if (tool_turns_seen > keep_recent_tool_turns and cutoff_index == messages.len) {
                cutoff_index = i + 1; // Everything before cutoff_index is historical
            }
        }
    }

    // Copy messages; prune tool output text if before cutoff_index
    for (messages, 0..) |msg, idx| {
        if (idx < cutoff_index and msg.role == .tool) {
            result[idx] = try pruneSingleToolMessage(gpa, msg, historical_tool_cap_bytes);
        } else {
            result[idx] = try cloneChatMessage(gpa, msg);
        }
    }

    return result;
}

/// Free a message slice allocated by `pruneHistoricalToolResults`.
pub fn freePrunedMessages(gpa: std.mem.Allocator, messages: []ai.ChatMessage) void {
    for (messages) |*msg| msg.deinit(gpa);
    gpa.free(messages);
}

/// Compute context budget breakdown for a message history against a target window.
pub fn calculateBudget(messages: []const ai.ChatMessage, system_prompt: []const u8, context_window: u32) ContextBudget {
    var sys_blocks = [_]ai.ContentBlock{.{ .text = .{ .text = @constCast(system_prompt) } }};
    const system_tokens = compaction.estimateMessageTokens(.{
        .role = .system,
        .content = &sys_blocks,
    });
    var history_tokens: u32 = 0;
    var tool_result_tokens: u32 = 0;

    for (messages) |msg| {
        const est = compaction.estimateMessageTokens(msg);
        if (msg.role == .tool) {
            tool_result_tokens +|= est;
        } else {
            history_tokens +|= est;
        }
    }

    const total_tokens = system_tokens +| history_tokens +| tool_result_tokens;
    return .{
        .system_tokens = system_tokens,
        .history_tokens = history_tokens,
        .tool_result_tokens = tool_result_tokens,
        .total_tokens = total_tokens,
        .context_window = context_window,
    };
}

fn substituteBaseTemplate(gpa: std.mem.Allocator, template: []const u8, cwd: []const u8) ![]u8 {
    const cwd_resolved = try std.mem.replaceOwned(u8, gpa, template, "${CWD}", cwd);
    defer gpa.free(cwd_resolved);
    return try std.mem.replaceOwned(u8, gpa, cwd_resolved, "${OS}", os.label);
}

fn readProjectRuleFile(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, filename: []const u8) !?[]u8 {
    const path = try std.fs.path.join(gpa, &.{ cwd, filename });
    defer gpa.free(path);

    return std.Io.Dir.readFileAllocOptions(
        .cwd(),
        io,
        path,
        gpa,
        .limited(64 * 1024),
        .of(u8),
        null,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn pruneSingleToolMessage(gpa: std.mem.Allocator, msg: ai.ChatMessage, cap_bytes: u32) !ai.ChatMessage {
    assert(msg.role == .tool);
    var pruned_blocks = try gpa.alloc(ai.ContentBlock, msg.content.len);
    errdefer gpa.free(pruned_blocks);

    for (msg.content, 0..) |block, b_idx| {
        if (block == .text and block.text.text.len > cap_bytes) {
            const original_len = block.text.text.len;
            const head = block.text.text[0..cap_bytes];
            const notice = try std.fmt.allocPrint(
                gpa,
                "{s}\n\n[... historical tool output truncated ({d} bytes original) ...]",
                .{ head, original_len },
            );
            pruned_blocks[b_idx] = .{ .text = .{ .text = notice } };
        } else {
            pruned_blocks[b_idx] = try cloneContentBlock(gpa, block);
        }
    }

    return .{
        .role = .tool,
        .content = pruned_blocks,
        .call_id = if (msg.call_id) |id| try gpa.dupe(u8, id) else null,
        .tool_display_label = if (msg.tool_display_label) |l| try gpa.dupe(u8, l) else null,
        .tool_failed = msg.tool_failed,
    };
}

fn cloneChatMessage(gpa: std.mem.Allocator, msg: ai.ChatMessage) !ai.ChatMessage {
    const blocks = try gpa.alloc(ai.ContentBlock, msg.content.len);
    errdefer gpa.free(blocks);
    for (msg.content, 0..) |block, i| {
        blocks[i] = try cloneContentBlock(gpa, block);
    }
    return .{
        .role = msg.role,
        .content = blocks,
        .call_id = if (msg.call_id) |id| try gpa.dupe(u8, id) else null,
        .tool_display_label = if (msg.tool_display_label) |l| try gpa.dupe(u8, l) else null,
        .tool_failed = msg.tool_failed,
    };
}

fn cloneContentBlock(gpa: std.mem.Allocator, block: ai.ContentBlock) !ai.ContentBlock {
    return switch (block) {
        .text => |t| .{ .text = .{ .text = try gpa.dupe(u8, t.text) } },
        .reasoning => |r| .{ .reasoning = .{ .text = try gpa.dupe(u8, r.text) } },
        .image => |img| .{ .image = .{ .mime_type = try gpa.dupe(u8, img.mime_type), .data_base64 = try gpa.dupe(u8, img.data_base64) } },
        .tool_call => |call| .{ .tool_call = .{ .call_id = try gpa.dupe(u8, call.call_id), .name = try gpa.dupe(u8, call.name), .arguments = try gpa.dupe(u8, call.arguments) } },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "assembleSystemPrompt substitutes placeholders and ingests AGENTS.md" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const rel_dir = ".zig-cache/context-assembly-test";
    try std.Io.Dir.createDirPath(.cwd(), io, rel_dir);

    var file = try std.Io.Dir.createFile(.cwd(), io, rel_dir ++ "/AGENTS.md", .{ .truncate = true });
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll("Rule: Always test code.");
    try writer.interface.flush();

    const cwd = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(cwd);

    const template = "System: ${CWD} on ${OS}";
    const prompt = try assembleSystemPrompt(gpa, io, template, cwd, &.{});
    defer gpa.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, cwd) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<project_instructions path=\"AGENTS.md\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Rule: Always test code.") != null);
}

test "pruneHistoricalToolResults caps old tool outputs while preserving recent ones" {
    const gpa = std.testing.allocator;

    var messages: [6]ai.ChatMessage = undefined;
    messages[0] = try makeTextMessage(gpa, .user, "hello");
    messages[1] = try makeToolMessage(gpa, "c1", "a" ** 2000); // Historical tool 1 (turn 1)
    messages[2] = try makeToolMessage(gpa, "c2", "b" ** 2000); // Historical tool 2 (turn 2)
    messages[3] = try makeToolMessage(gpa, "c3", "c" ** 2000); // Recent tool 1 (turn 3)
    messages[4] = try makeToolMessage(gpa, "c4", "d" ** 2000); // Recent tool 2 (turn 4)
    messages[5] = try makeTextMessage(gpa, .user, "next user ask");
    defer for (&messages) |*m| m.deinit(gpa);

    // Keep recent 2 tool turns intact, prune older tools at 100 bytes
    const pruned = try pruneHistoricalToolResults(gpa, &messages, 2, 100);
    defer freePrunedMessages(gpa, pruned);

    try std.testing.expectEqual(@as(usize, 6), pruned.len);
    // Historical tool 1 (index 1) should be truncated
    const t1_text = pruned[1].content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, t1_text, "historical tool output truncated") != null);
    try std.testing.expect(t1_text.len < 300);

    // Recent tool 1 (index 3) should be full length
    const t3_text = pruned[3].content[0].text.text;
    try std.testing.expectEqual(@as(usize, 2000), t3_text.len);
}

test "calculateBudget returns accurate token breakdown" {
    const gpa = std.testing.allocator;

    var msgs: [2]ai.ChatMessage = undefined;
    msgs[0] = try makeTextMessage(gpa, .user, "12345678"); // 8 bytes = 2 tokens
    msgs[1] = try makeToolMessage(gpa, "c1", "1234123412341234"); // 16 bytes = 4 tokens
    defer for (&msgs) |*m| m.deinit(gpa);

    const budget = calculateBudget(&msgs, "system prompt", 100_000);
    try std.testing.expect(budget.system_tokens > 0);
    try std.testing.expectEqual(@as(u32, 2), budget.history_tokens);
    try std.testing.expectEqual(@as(u32, 4), budget.tool_result_tokens);
    try std.testing.expect(budget.remainingTokens() < 100_000);
}

fn makeTextMessage(gpa: std.mem.Allocator, role: ai.Role, text: []const u8) !ai.ChatMessage {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    errdefer gpa.free(blocks);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, text) } };
    return .{ .role = role, .content = blocks };
}

fn makeToolMessage(gpa: std.mem.Allocator, call_id: []const u8, text: []const u8) !ai.ChatMessage {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    errdefer gpa.free(blocks);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, text) } };
    return .{
        .role = .tool,
        .content = blocks,
        .call_id = try gpa.dupe(u8, call_id),
        .tool_display_label = try gpa.dupe(u8, "bash"),
    };
}
