//! Text tool-call recovery seam, extracted from agent.zig (issue #367
//! slice 9). Recover tool calls a weak function-calling model emitted as
//! literal text inside the assistant message, and inject them back as
//! structured `.tool_call` blocks so the turn loop can execute them.
//!
//! Spoke pattern (runtime/connection.zig, mcp/wire.zig, agent/queue_ops.zig):
//! free functions over `*Agent`; all state stays on `Agent` — this file
//! imports agent.zig only for the `Agent` type (`text_tool_seq` lives there
//! and is reached through the receiver). Mutual import terminates at the
//! type level. No locks: the three functions run on the worker thread inside
//! the turn loop, between `collectToolCallsAlloc` and `takeAssistantMessage`.
//!
//! Ownership contract (load-bearing): `recoverTextToolCalls` returns
//! independently-owned strings so `injectRecoveredToolCalls` can MOVE them
//! into new `.tool_call` blocks — callers free only the recovered slice
//! shell, never its element strings, on BOTH the success and the error path:
//! when the content-block reallocation fails, `injectRecoveredToolCalls`
//! deinits the recovered calls' strings itself before returning the error
//! (#443). The turn-loop window (collect → recover → inject) and the
//! severed-tool-calls retry ordering live at the call sites in agent.zig's
//! `run` and are unchanged by this extraction.

const std = @import("std");

const agent_mod = @import("../agent.zig");
const ai = @import("../ai.zig");
const text_tool_call = @import("../ai/text_tool_call.zig");

const Agent = agent_mod.Agent;
const assert = std.debug.assert;

pub fn collectToolCallsAlloc(self: *Agent, allocator: std.mem.Allocator, assistant: ai.ChatMessage) ![]ai.ToolCall {
    _ = self;
    assert(assistant == .assistant);
    const content = assistant.assistant.content;
    var count: usize = 0;
    for (content) |block| {
        if (block == .tool_call) count += 1;
    }
    const calls = try allocator.alloc(ai.ToolCall, count);
    var index: usize = 0;
    for (content) |block| {
        if (block != .tool_call) continue;
        calls[index] = block.tool_call;
        index += 1;
    }
    return calls;
}

/// T3: scan the assistant message's text blocks for tool calls a model
/// emitted as literal text (weak function-calling models do this). Returns
/// a freshly-allocated `[]ai.ToolCall` (possibly empty) whose element
/// strings are independently owned — NOT aliased onto the message — so
/// `injectRecoveredToolCalls` can move them into new blocks cleanly.
/// Only scans `.text` blocks; reasoning blocks are ignored.
/// When calls are recovered from a text block, its `<tool_call>` envelopes
/// are excised so the message's prose does not retain duplicate/pseudo-XML
/// markers in future context windows.
pub fn recoverTextToolCalls(self: *Agent, assistant: *ai.ChatMessage) ![]ai.ToolCall {
    if (assistant.* != .assistant) return &.{};
    var all: std.ArrayList(ai.ToolCall) = .empty;
    errdefer {
        for (all.items) |*c| c.deinit(self.gpa);
        all.deinit(self.gpa);
    }
    for (assistant.assistant.content) |*block| {
        if (block.* != .text) continue;
        const found = try text_tool_call.extractFromText(self.gpa, block.text.text, &self.text_tool_seq);
        var moved = false;
        defer {
            if (!moved) {
                for (found) |*c| c.deinit(self.gpa);
            }
            self.gpa.free(found);
        }
        if (found.len > 0) {
            const stripped = try text_tool_call.stripToolCalls(self.gpa, block.text.text);
            self.gpa.free(block.text.text);
            block.text.text = stripped;
            try all.appendSlice(self.gpa, found);
            moved = true;
        }
    }
    return all.toOwnedSlice(self.gpa);
}

/// T3: append recovered tool calls as new `.tool_call` ContentBlocks into
/// the assistant message's content slice, reallocating the slice.
///
/// Ownership contract: the recovered `ToolCall`s' owned strings
/// (call_id/name/arguments) are MOVED into the new blocks — callers must
/// NOT free those strings, only the `recovered` slice shell. This mirrors
/// `collectToolCallsAlloc`'s aliasing contract (slice shell caller-freed,
/// element strings belong to the message). Existing blocks keep their
/// strings — only the slice shell is reallocated. On allocation failure the
/// move never happened, so this deinits the recovered calls' strings itself
/// and the caller still frees only the shell (#443).
pub fn injectRecoveredToolCalls(self: *Agent, assistant: *ai.ChatMessage, recovered: []ai.ToolCall) !void {
    assert(assistant.* == .assistant);
    if (recovered.len == 0) return;
    const old = assistant.assistant.content;
    const new_blocks = self.gpa.alloc(ai.ContentBlock, old.len + recovered.len) catch |err| {
        // The move never happened: the strings still belong to the `recovered`
        // elements, so free them here to keep the caller-side contract
        // unconditional — callers free only the slice shell, on the success
        // and the error path alike.
        for (recovered) |*c| c.deinit(self.gpa);
        return err;
    };
    // Shallow copy: old blocks keep their owned strings.
    @memcpy(new_blocks[0..old.len], old);
    var i: usize = old.len;
    for (recovered) |tc| {
        new_blocks[i] = .{ .tool_call = tc }; // MOVED: strings now owned by this block
        i += 1;
    }
    // Free only the old slice shell — element strings were moved into new_blocks.
    self.gpa.free(old);
    assistant.assistant.content = new_blocks;
}

test "recoverTextToolCalls recovers from a text block when there are zero structured calls" {
    // T3 unit test: the recovery helper, exercised on a realistic assistant
    // message — a single text block containing the DB-observed XML shape.
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "<tool_call>bash<arg_key=\"command\">echo recovered</arg_key></tool_call>") } };
    var assistant: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer assistant.deinit(gpa);

    const recovered = try recoverTextToolCalls(&agent, &assistant);
    defer {
        for (recovered) |*c| c.deinit(gpa);
        gpa.free(recovered);
    }
    try std.testing.expectEqual(@as(usize, 1), recovered.len);
    try std.testing.expectEqualStrings("bash", recovered[0].name);
    // The arg_key="command" pair is captured (the value sits on the opening tag).
    try std.testing.expectEqualStrings("{\"arg_key\":\"command\"}", recovered[0].arguments);
    try std.testing.expect(std.mem.startsWith(u8, recovered[0].call_id.slice(), "textcall_"));
    // The text block has had the envelope excised
    try std.testing.expectEqualStrings("", assistant.assistant.content[0].text.text);
}

test "injectRecoveredToolCalls appends without dropping existing blocks" {
    // T3 ownership test — the highest-risk failure mode. Build an assistant
    // with a text block, recover one call, inject it, and assert the message
    // now has 2 blocks (text + tool_call) with the original text excised of
    // tool_call envelopes. Run under std.testing.allocator to catch any leak/double-free
    // (the recovered strings are MOVED into the new block, so the slice shell is freed but
    // NOT the element strings).
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "prefix <tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"x\"}}</tool_call> suffix") } };
    var assistant: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer assistant.deinit(gpa);

    const recovered = try recoverTextToolCalls(&agent, &assistant);
    // After inject, the element strings belong to the message — free only the shell.
    defer gpa.free(recovered);
    try std.testing.expectEqual(@as(usize, 1), recovered.len);

    try injectRecoveredToolCalls(&agent, &assistant, recovered);
    // 2 blocks now: the excised text + the injected tool_call.
    try std.testing.expectEqual(@as(usize, 2), assistant.assistant.content.len);
    try std.testing.expect(assistant.assistant.content[0] == .text);
    try std.testing.expectEqualStrings("prefix  suffix", assistant.assistant.content[0].text.text);
    try std.testing.expect(assistant.assistant.content[1] == .tool_call);
    try std.testing.expectEqualStrings("bash", assistant.assistant.content[1].tool_call.name);

    // collectToolCallsAlloc now sees the recovered call (the turn-loop window).
    const recollected = try collectToolCallsAlloc(&agent, gpa, assistant);
    defer gpa.free(recollected);
    try std.testing.expectEqual(@as(usize, 1), recollected.len);
    try std.testing.expectEqualStrings("bash", recollected[0].name);
}

test "T3 turn-loop window: zero structured calls + text recovery yields executable tool_calls" {
    // Integration of the exact turn-loop window (collect → recover → inject)
    // without firing a full HTTP turn. Mirrors the ordering fact in plan §1.1:
    // recovery must run BEFORE takeAssistantMessage, and the recovered slice
    // drives execution via re-collection. No use-after-free because the
    // message is live throughout the window.
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // Simulate a turn whose assistant emitted a tool call as TEXT (zero
    // structured .tool_call blocks).
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "Sure! <tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"echo done\"}}</tool_call>") } };
    var assistant: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer assistant.deinit(gpa);

    // Step 1: collect — zero structured calls.
    const initial = try collectToolCallsAlloc(&agent, gpa, assistant);
    defer gpa.free(initial);
    try std.testing.expectEqual(@as(usize, 0), initial.len);

    // Step 2: recover — fire because initial is empty.
    const recovered = try recoverTextToolCalls(&agent, &assistant);
    defer gpa.free(recovered);
    try std.testing.expectEqual(@as(usize, 1), recovered.len);

    // Step 3: inject so takeAssistantMessage persists the recovered call.
    try injectRecoveredToolCalls(&agent, &assistant, recovered);

    // Step 4: the slice that would drive execution (recovered, per plan §2.2)
    // has length > 0 → runToolBatch would fire, not the idle-drain branch.
    const tool_calls: []const ai.ToolCall = recovered;
    try std.testing.expect(tool_calls.len > 0);
    try std.testing.expectEqualStrings("bash", tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"echo done\"}", tool_calls[0].arguments);
}

test "injectRecoveredToolCalls frees the recovered strings when the block realloc fails" {
    // #443: the content-block allocation can fail before any string moves;
    // inject must deinit the recovered calls itself so the caller-side
    // contract ("free only the slice shell") holds on the error path too.
    // std.testing.allocator's leak check is the proof.
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "<tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"x\"}}</tool_call>") } };
    var assistant: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer assistant.deinit(gpa);

    const recovered = try recoverTextToolCalls(&agent, &assistant);
    try std.testing.expectEqual(@as(usize, 1), recovered.len);

    // Fail the first allocation inside injectRecoveredToolCalls — the content
    // block realloc — with nothing moved yet, so the strings still belong to
    // the recovered elements.
    const real_gpa = agent.gpa;
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    agent.gpa = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, injectRecoveredToolCalls(&agent, &assistant, recovered));
    agent.gpa = real_gpa;

    // The caller frees only the shell (the documented contract): the leak
    // check proves inject freed the recovered strings on the error path.
    gpa.free(recovered);
}
