//! Message/conversation mutations for `Agent` (issue #367 slice 15).
//!
//! Free functions over `*Agent`: history appends, system-message surgery,
//! provider result ingestion and the conversation reset path. State stays on
//! the owner struct; this file owns no state of its own.

const std = @import("std");
const assert = std.debug.assert;

const agent_mod = @import("../agent.zig");
const ai = @import("../ai.zig");
const executor_mod = @import("../executor.zig");
const skill_context_mod = @import("../context/skill_context.zig");
const skill_history = @import("../context/skill_history.zig");
const run_loop = @import("run_loop.zig");
const skill_ops = @import("skill_context_ops.zig");

const Agent = agent_mod.Agent;

pub fn takeMessage(self: *Agent, message: ai.ChatMessage) !void {
    const mark = self.skill_context.entries.items.len;
    errdefer self.skill_context.rollbackTo(self.gpa, mark);
    const history = try self.gpa.alloc(ai.ChatMessage, self.messages().len + 1);
    defer self.gpa.free(history);
    @memcpy(history[0..self.messages().len], self.messages());
    history[history.len - 1] = message;
    try skill_history.rebuild(&self.skill_context, self.gpa, history, self.skills);
    try self.context_manager.appendUnpersisted(message);
    if (self.skill_context.entries.items.len != mark) {
        skill_ops.noteChangeDeferred(self);
    }
}

/// Drop every non-system message, freeing it. Keeps the system prompt(s) in
/// place so the conversation can be rehydrated from a different branch (see
/// `AgentRuntime.reloadMessages`). Only safe at a turn boundary, never while
/// a response is streaming.
pub fn clearNonSystemMessages(self: *Agent) void {
    self.tool_view_cache.clear(self.gpa);
    self.context_manager.clearNonSystem();
    self.skill_context.clear(self.gpa);
    self.skill_context_dirty = false;
    self.skill_context_changed_pending = true;
}

pub fn appendMessage(self: *Agent, role: ai.Role, content: []const u8) !void {
    if (role == .user) {
        try run_loop.reconcileUnresolvedToolCalls(self, run_loop.interrupted_tool_result, "cancelled");
    }
    var message = try makeTextMessage(self, role, content);
    errdefer message.deinit(self.gpa);
    try self.context_manager.appendPersisted(message);
}

pub fn makeTextMessage(self: *Agent, role: ai.Role, content: []const u8) !ai.ChatMessage {
    assert(content.len > 0);
    const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
    errdefer self.gpa.free(blocks);
    blocks[0] = .{ .text = .{ .text = try self.gpa.dupe(u8, content) } };
    errdefer blocks[0].deinit(self.gpa);
    return switch (role) {
        .system => .{ .system = .{ .content = blocks } },
        .user => .{ .user = .{ .content = blocks } },
        .assistant => .{ .assistant = .{ .content = blocks } },
        .tool => error.InvalidToolRole,
    };
}

/// Build a fake tool message for tests that need a tool result without
/// going through the executor. `call_id` defaults to "test_call".
pub fn makeToolMessage(self: *Agent, content: []const u8) !ai.ChatMessage {
    assert(content.len > 0);
    const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
    errdefer self.gpa.free(blocks);
    blocks[0] = .{ .text = .{ .text = try self.gpa.dupe(u8, content) } };
    errdefer blocks[0].deinit(self.gpa);
    return .{
        .tool = .{
            .call_id = .{ .value = try self.gpa.dupe(u8, "test_call") },
            .content = blocks,
        },
    };
}

pub fn takeToolResults(self: *Agent, results: []executor_mod.ToolResult) !void {
    assert(results.len > 0);
    var moved: usize = 0;
    errdefer {
        for (results[moved..]) |*r| r.deinit(self.gpa);
    }
    for (results) |*r| {
        assert(r.call_id.value.len > 0);
        const skill_count = self.skill_context.entries.items.len;
        errdefer self.skill_context.rollbackTo(self.gpa, skill_count);
        if (std.mem.eql(u8, r.name, "skill")) {
            if (try skill_ops.forResult(self, r)) |loaded| {
                const already_loaded = self.skill_context.contains(loaded.name);
                if (!r.failed or already_loaded) {
                    const activation = try self.skill_context.activate(self.gpa, loaded.name, loaded.body);
                    if (activation == .already_loaded) {
                        const notice = try self.gpa.dupe(u8, skill_context_mod.loaded_notice);
                        self.gpa.free(r.content);
                        r.content = notice;
                        r.failed = false;
                    }
                }
            }
        }
        const failed = r.failed;
        // Drops name / expanded label / body / stderr and hands us the
        // history trio; the result becomes a deinit-safe shell, so the
        // errdefer loop above would free nothing twice if persistence
        // fails after this point.
        const channels = r.takeHistoryChannels(self.gpa);
        errdefer {
            // The moved channels are ours until persistence succeeds
            // (appendPersisted failure leaves ownership with the caller).
            self.gpa.free(channels.call_id.value);
            self.gpa.free(channels.content);
            self.gpa.free(channels.display_label);
        }
        const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
        errdefer self.gpa.free(blocks);
        blocks[0] = .{ .text = .{ .text = channels.content } };
        try self.context_manager.appendPersisted(.{
            .tool = .{
                .content = blocks,
                .call_id = channels.call_id,
                .display_label = channels.display_label,
                .failed = failed,
            },
        });
        r.* = undefined;
        moved += 1;
        if (self.skill_context.entries.items.len != skill_count) {
            skill_ops.noteChange(self);
        }
    }
}
