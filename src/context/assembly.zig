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
const ai = @import("../ai.zig");
const at_mention = @import("../at_mention.zig");
const compaction = @import("compaction.zig");
const os = @import("../os.zig");
const plugin_prompt = @import("../plugin_prompt.zig");
const skill_mod = @import("../skill.zig");
const vcs = @import("../vcs.zig");

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

/// Maximum bytes of a single project rule file ingested into the prompt. A file
/// larger than this is truncated to the head with a visible notice rather than
/// rejected, so an oversized AGENTS.md can never brick startup.
pub const max_project_rule_file_bytes: usize = 64 * 1024;

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
/// git metadata, ingested project rules, active skills, and plugin prompts.
pub fn assembleSystemPrompt(
    gpa: std.mem.Allocator,
    io: std.Io,
    base_template: []const u8,
    cwd: []const u8,
    skills: []const skill_mod.Skill,
    plugin_prompts: []const plugin_prompt.PluginPrompt,
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

    // 5. Append Plugin prompts (optional per-plugin prompt.md bodies)
    const plugin_prompt_text = try plugin_prompt.formatForPrompt(gpa, plugin_prompts);
    defer gpa.free(plugin_prompt_text);
    if (plugin_prompt_text.len > 0) {
        try out.writer.writeAll("\n\n");
        try out.writer.writeAll(plugin_prompt_text);
    }

    return out.toOwnedSlice();
}

/// Count tool result turns backwards from the end of `messages` and return the
/// index at which historical pruning begins: everything at `idx < cutoff` is a
/// tool turn older than the `keep_recent_tool_turns` most recent ones.
/// Messages at `>= cutoff` are kept in full.
fn computeCutoff(messages: []const ai.ChatMessage, keep_recent_tool_turns: u32) usize {
    var tool_turns_seen: u32 = 0;
    var cutoff_index: usize = messages.len;
    var i: usize = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i] == .tool) {
            tool_turns_seen += 1;
            if (tool_turns_seen > keep_recent_tool_turns and cutoff_index == messages.len) {
                cutoff_index = i + 1; // Everything before cutoff_index is historical
            }
        }
    }
    return cutoff_index;
}

/// Borrow-based view of the pruned history. Unchanged messages BORROW from
/// `messages` — no byte copy, so base64 images are never duplicated per turn —
/// and only historical tool messages older than the cutoff become owned pruned
/// copies. Caller owns the returned slice and must free with `freePrunedViews`.
///
/// Safe while `messages` is stable: the caller (`Agent.run`) holds the
/// ContextManager list and does not append between building the views and the
/// synchronous `client.prompt` returning.
pub fn pruneHistoricalToolResultsViews(
    gpa: std.mem.Allocator,
    messages: []const ai.ChatMessage,
    keep_recent_tool_turns: u32,
    historical_tool_cap_bytes: u32,
) ![]ai.MessageView {
    const views = try gpa.alloc(ai.MessageView, messages.len);
    errdefer gpa.free(views);
    const cutoff_index = computeCutoff(messages, keep_recent_tool_turns);
    for (messages, 0..) |*msg, idx| {
        if (idx < cutoff_index and msg.* == .tool) {
            views[idx] = .{ .owned = try pruneSingleToolMessage(gpa, msg.*, historical_tool_cap_bytes) };
        } else {
            views[idx] = .{ .borrowed = msg };
        }
    }
    return views;
}

/// Free a view slice produced by `pruneHistoricalToolResultsViews`. Only the
/// `.owned` pruned copies are released; borrowed views point into the
/// ContextManager and are left untouched.
pub fn freePrunedViews(gpa: std.mem.Allocator, views: []ai.MessageView) void {
    for (views) |*view| switch (view.*) {
        .owned => |*m| m.deinit(gpa),
        .borrowed => {},
    };
    gpa.free(views);
}

/// Compute context budget breakdown for a message history against a target window.
pub fn calculateBudget(messages: []const ai.ChatMessage, system_prompt: []const u8, context_window: u32) ContextBudget {
    var sys_blocks = [_]ai.ContentBlock{.{ .text = .{ .text = @constCast(system_prompt) } }};
    const system_tokens = compaction.estimateMessageTokens(.{
        .system = .{ .content = &sys_blocks },
    });
    var history_tokens: u32 = 0;
    var tool_result_tokens: u32 = 0;

    for (messages) |msg| {
        const est = compaction.estimateMessageTokens(msg);
        if (msg == .tool) {
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

pub fn substituteBaseTemplate(gpa: std.mem.Allocator, template: []const u8, cwd: []const u8) ![]u8 {
    const cwd_resolved = try std.mem.replaceOwned(u8, gpa, template, "${CWD}", cwd);
    defer gpa.free(cwd_resolved);
    return try std.mem.replaceOwned(u8, gpa, cwd_resolved, "${OS}", os.label);
}

pub fn readProjectRuleFile(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, filename: []const u8) !?[]u8 {
    const path = try std.fs.path.join(gpa, &.{ cwd, filename });
    defer gpa.free(path);

    const file = std.Io.Dir.openFile(.cwd(), io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    const head_len: usize = @intCast(@min(stat.size, max_project_rule_file_bytes));
    const bytes = try gpa.alloc(u8, head_len);
    errdefer gpa.free(bytes);
    var reader = file.reader(io, &.{});
    try reader.interface.readSliceAll(bytes);
    if (stat.size > max_project_rule_file_bytes) {
        const notice = try std.fmt.allocPrint(
            gpa,
            "\n\n[project rule file truncated: {s} is {d} bytes, only the first {d} ingested]",
            .{ filename, stat.size, max_project_rule_file_bytes },
        );
        defer gpa.free(notice);
        const joined = try gpa.alloc(u8, head_len + notice.len);
        @memcpy(joined[0..head_len], bytes);
        @memcpy(joined[head_len..], notice);
        gpa.free(bytes);
        return joined;
    }
    return bytes;
}

fn pruneSingleToolMessage(gpa: std.mem.Allocator, msg: ai.ChatMessage, cap_bytes: u32) !ai.ChatMessage {
    assert(msg == .tool);
    const content = msg.tool.content;
    var pruned_blocks = try gpa.alloc(ai.ContentBlock, content.len);
    errdefer gpa.free(pruned_blocks);

    for (content, 0..) |block, b_idx| {
        if (block == .text and block.text.text.len > cap_bytes) {
            const original_len = block.text.text.len;
            const head = block.text.text[0..cap_bytes];
            const notice = try std.fmt.allocPrint(
                gpa,
                "{s}\n\n[... earlier tool result compacted to save context (was {d} bytes) ...]",
                .{ head, original_len },
            );
            pruned_blocks[b_idx] = .{ .text = .{ .text = notice } };
        } else {
            pruned_blocks[b_idx] = try cloneContentBlock(gpa, block);
        }
    }

    return .{
        .tool = .{
            .content = pruned_blocks,
            .call_id = .{ .value = try gpa.dupe(u8, msg.tool.call_id.slice()) },
            .display_label = if (msg.tool.display_label) |l| try gpa.dupe(u8, l) else null,
            .failed = msg.tool.failed,
        },
    };
}

fn cloneContentBlock(gpa: std.mem.Allocator, block: ai.ContentBlock) !ai.ContentBlock {
    return switch (block) {
        .text => |t| .{ .text = .{ .text = try gpa.dupe(u8, t.text) } },
        .reasoning => |r| .{ .reasoning = .{ .text = try gpa.dupe(u8, r.text) } },
        .image => |img| .{ .image = .{ .mime_type = try gpa.dupe(u8, img.mime_type), .data_base64 = try gpa.dupe(u8, img.data_base64) } },
        .tool_call => |call| .{ .tool_call = .{ .call_id = .{ .value = try gpa.dupe(u8, call.call_id.slice()) }, .name = try gpa.dupe(u8, call.name), .arguments = try gpa.dupe(u8, call.arguments) } },
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
    const prompt = try assembleSystemPrompt(gpa, io, template, cwd, &.{}, &.{});
    defer gpa.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, cwd) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<project_instructions path=\"AGENTS.md\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Rule: Always test code.") != null);
}

test "assembleSystemPrompt appends plugin prompts block" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const rel_dir = ".zig-cache/context-assembly-plugin-test";
    try std.Io.Dir.createDirPath(.cwd(), io, rel_dir);
    const cwd = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(cwd);

    var prompts = try gpa.alloc(plugin_prompt.PluginPrompt, 1);
    prompts[0] = .{
        .name = try gpa.dupe(u8, "write-tool"),
        .body = try gpa.dupe(u8, "Always confirm before overwrite."),
        .path = try gpa.dupe(u8, "/tmp/prompt.md"),
    };
    defer plugin_prompt.deinitAll(gpa, prompts);

    const template = "System: ${CWD} on ${OS}";
    const prompt = try assembleSystemPrompt(gpa, io, template, cwd, &.{}, prompts);
    defer gpa.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "<plugin_prompts>") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<plugin name=\"write-tool\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Always confirm before overwrite.") != null);
}

test "readProjectRuleFile truncates an oversized rule file with a notice instead of failing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const rel_dir = ".zig-cache/context-rule-truncate-test";
    try std.Io.Dir.createDirPath(.cwd(), io, rel_dir);
    const cwd = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(cwd);

    const filename = "BIG.md";
    const path = try std.fs.path.join(gpa, &.{ cwd, filename });
    defer gpa.free(path);
    var file = try std.Io.Dir.createFile(.cwd(), io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    const filler = "x" ** 100; // 100-byte chunk
    var written: usize = 0;
    while (written < max_project_rule_file_bytes + 100) {
        try writer.interface.writeAll(filler);
        written += filler.len;
    }
    try writer.interface.flush();

    const content = (try readProjectRuleFile(gpa, io, cwd, filename)).?;
    defer gpa.free(content);
    try std.testing.expect(content.len > max_project_rule_file_bytes); // head + notice
    try std.testing.expect(std.mem.indexOf(u8, content, "truncated") != null);
    // Head bytes are preserved verbatim.
    try std.testing.expect(std.mem.startsWith(u8, content, "xxxxxxxxxx"));
}

test "pruneHistoricalToolResultsViews caps old tool outputs while preserving recent ones" {
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
    const pruned = try pruneHistoricalToolResultsViews(gpa, &messages, 2, 100);
    defer freePrunedViews(gpa, pruned);

    try std.testing.expectEqual(@as(usize, 6), pruned.len);
    // Historical tool 1 (index 1) should be owned and truncated
    try std.testing.expect(pruned[1] == .owned);
    const t1_text = pruned[1].owned.tool.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, t1_text, "compacted to save context") != null);
    try std.testing.expect(t1_text.len < 300);

    // Recent tool 1 (index 3) should be borrowed and kept in full
    try std.testing.expect(pruned[3] == .borrowed);
    const t3_text = pruned[3].borrowed.tool.content[0].text.text;
    try std.testing.expectEqual(@as(usize, 2000), t3_text.len);
}

test "pruneHistoricalToolResultsViews borrows unchanged messages without copying" {
    // The zero-copy contract: an image user message must be BORROWED with
    // pointer identity (its base64 bytes are never re-duped), while a
    // historical tool message older than the cutoff becomes an owned pruned
    // copy. Recent tool messages are borrowed in full.
    const gpa = std.testing.allocator;

    var messages: [3]ai.ChatMessage = undefined;
    messages[0] = try makeToolMessage(gpa, "c_old", "a" ** 2000); // historical (over cap)
    messages[1] = try makeImageUserMessage(gpa); // image user message
    messages[2] = try makeToolMessage(gpa, "c_new", "b" ** 2000); // recent tool
    defer for (&messages) |*m| m.deinit(gpa);

    const views = try pruneHistoricalToolResultsViews(gpa, &messages, 1, 100);
    defer freePrunedViews(gpa, views);

    try std.testing.expectEqual(@as(usize, 3), views.len);

    // Historical tool message → owned, pruned.
    try std.testing.expect(views[0] == .owned);
    const pruned_text = views[0].owned.tool.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, pruned_text, "compacted to save context") != null);

    // Image user message → borrowed with pointer identity: no copy was made.
    try std.testing.expect(views[1] == .borrowed);
    try std.testing.expect(views[1].borrowed == &messages[1]);
    const image = views[1].borrowed.user.content[0].image;
    try std.testing.expect(image.data_base64.ptr == messages[1].user.content[0].image.data_base64.ptr);

    // Recent tool message → borrowed, kept in full.
    try std.testing.expect(views[2] == .borrowed);
    try std.testing.expectEqual(@as(usize, 2000), views[2].borrowed.tool.content[0].text.text.len);
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
    return switch (role) {
        .system => .{ .system = .{ .content = blocks } },
        .user => .{ .user = .{ .content = blocks } },
        .assistant => .{ .assistant = .{ .content = blocks } },
        .tool => error.InvalidToolRole,
    };
}

fn makeImageUserMessage(gpa: std.mem.Allocator) !ai.ChatMessage {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    errdefer gpa.free(blocks);
    blocks[0] = .{ .image = .{
        .mime_type = try gpa.dupe(u8, "image/png"),
        .data_base64 = try gpa.dupe(u8, "QUJD"),
    } };
    return .{ .user = .{ .content = blocks } };
}

fn makeToolMessage(gpa: std.mem.Allocator, call_id: []const u8, text: []const u8) !ai.ChatMessage {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    errdefer gpa.free(blocks);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, text) } };
    return .{
        .tool = .{
            .content = blocks,
            .call_id = .{ .value = try gpa.dupe(u8, call_id) },
            .display_label = try gpa.dupe(u8, "bash"),
        },
    };
}

test "assembleSystemPrompt includes the unconditional <lanes> block from system.md" {
    // The `lane` tool is a builtin, so its <lanes> guidance is always in the
    // assembled prompt (unlike the conditional lua/mcp blocks).
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const template = @embedFile("../prompts/system.md");
    const prompt = try assembleSystemPrompt(gpa, io, template, root, &.{}, &.{});
    defer gpa.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "<lanes>") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Workspace mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Fan out when the work decomposes") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Sequence what depends") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Discipline (hard)") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Dispatch, don't block") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "lane spawn") != null);
}
