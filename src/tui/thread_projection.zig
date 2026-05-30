const std = @import("std");

const agent_mod = @import("../agent.zig");
const ai = @import("../ai.zig");
const thread_mod = @import("../thread.zig");
const tool_policy = @import("tool_policy.zig");

const assert = std.debug.assert;

pub const loading_spinners = [4][]const u8{ "Firing Neurons", "Multiplying Matrices", "brr..brr...", "Warping" };

pub const ThreadProjection = struct {
    agent_index: ?u32 = null,
    thinking_index: ?u32 = null,
    loading_index: ?u32 = null,
    loading_word_index: u8 = 0,
    tool_seen_in_response: bool = false,
    awaiting_tool_call: bool = false,
    pending_redraw: bool = false,
    tool_indexes: std.ArrayList(?u32) = .empty,

    pub fn deinit(self: *ThreadProjection, gpa: std.mem.Allocator) void {
        self.tool_indexes.deinit(gpa);
        self.* = undefined;
    }

    pub fn resetTurn(self: *ThreadProjection, io: std.Io) void {
        self.agent_index = null;
        self.thinking_index = null;
        self.loading_index = null;
        self.loading_word_index = chooseLoadingWordIndex(io);
        self.tool_seen_in_response = false;
        self.awaiting_tool_call = true;
        self.pending_redraw = false;
        self.tool_indexes.clearRetainingCapacity();
    }

    pub fn apply(
        self: *ThreadProjection,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        event: agent_mod.Agent.Event,
    ) !bool {
        switch (event) {
            .turn_started => return false,
            .response_delta => |delta| return try self.applyResponseDelta(gpa, thread, delta),
            .thinking_delta => |delta| return try self.applyThinkingDelta(gpa, thread, delta),
            .tool_delta => |tool| return try self.applyToolDelta(gpa, thread, tool),
            .delta_end => return self.takePendingRedraw(),
            .tool_call_finished => |tool| return try self.applyToolFinished(gpa, thread, tool),
            .tool_batch_finished => return try self.applyToolBatchFinished(gpa, thread),
            .queued_messages_flushed => return false,
            .turn_failed => |message| return try self.applyTurnFailed(gpa, thread, message),
            .turn_finished => return try self.applyTurnFinished(gpa, thread),
        }
    }

    pub fn appendLoading(self: *ThreadProjection, gpa: std.mem.Allocator, thread: *thread_mod.Thread) !void {
        assert(self.loading_index == null);
        assert(self.loading_word_index < loading_spinners.len);
        self.loading_index = try thread.append(gpa, .status, loading_spinners[self.loading_word_index], "");
    }

    pub fn removeLoading(self: *ThreadProjection, gpa: std.mem.Allocator, thread: *thread_mod.Thread) void {
        const index = self.loading_index orelse return;
        self.loading_index = null;
        if (index >= thread.messages.items.len) return;
        thread.remove(gpa, index);
        self.adjustIndexesAfterRemove(index);
    }

    fn applyResponseDelta(
        self: *ThreadProjection,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        delta: []const u8,
    ) !bool {
        self.removeLoading(gpa, thread);
        if (delta.len == 0) return false;
        _ = try self.finishThinking(gpa, thread);
        try self.applyContentDelta(gpa, thread, delta);
        self.pending_redraw = true;
        return true;
    }

    fn applyThinkingDelta(
        self: *ThreadProjection,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        delta: []const u8,
    ) !bool {
        self.removeLoading(gpa, thread);
        if (try self.applyReasoningDelta(gpa, thread, delta)) self.pending_redraw = true;
        return false;
    }

    fn applyToolDelta(
        self: *ThreadProjection,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        tool: ai.ToolDelta,
    ) !bool {
        const thinking_finished = try self.finishThinking(gpa, thread);
        if (try self.applyToolPreview(gpa, thread, tool)) self.pending_redraw = true;
        if (thinking_finished) self.pending_redraw = true;
        return false;
    }

    fn applyToolFinished(
        self: *ThreadProjection,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        tool: agent_mod.Agent.Event.ToolCallFinished,
    ) !bool {
        self.removeLoading(gpa, thread);
        const thinking_finished = try self.finishThinking(gpa, thread);
        return thinking_finished or try self.finishTool(gpa, thread, tool);
    }

    fn applyToolBatchFinished(
        self: *ThreadProjection,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
    ) !bool {
        self.removeLoading(gpa, thread);
        _ = try self.finishThinking(gpa, thread);
        self.agent_index = null;
        self.thinking_index = null;
        self.tool_seen_in_response = false;
        self.awaiting_tool_call = false;
        self.tool_indexes.clearRetainingCapacity();
        try self.appendLoading(gpa, thread);
        return true;
    }

    fn applyTurnFailed(
        self: *ThreadProjection,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        message: []const u8,
    ) !bool {
        self.removeLoading(gpa, thread);
        _ = try thread.append(gpa, .notice, "notice", message);
        return true;
    }

    fn applyTurnFinished(
        self: *ThreadProjection,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
    ) !bool {
        self.removeLoading(gpa, thread);
        _ = try self.finishThinking(gpa, thread);
        return true;
    }

    fn takePendingRedraw(self: *ThreadProjection) bool {
        const redraw = self.pending_redraw;
        self.pending_redraw = false;
        return redraw;
    }

    fn applyContentDelta(
        self: *ThreadProjection,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        delta: []const u8,
    ) !void {
        assert(delta.len > 0);
        const selected = thread.selected;
        if (self.agent_index) |index| {
            try thread.appendAgentDelta(gpa, index, delta);
        } else {
            self.agent_index = try thread.append(gpa, .agent, "agent", delta);
        }
        if (self.tool_seen_in_response) {
            if (selected) |index| thread.select(index);
        } else {
            selectGeneratedMessage(thread, self.agent_index.?);
        }
    }

    fn finishThinking(self: *ThreadProjection, gpa: std.mem.Allocator, thread: *thread_mod.Thread) !bool {
        const index = self.thinking_index orelse return false;
        if (index >= thread.messages.items.len) return false;
        if (std.mem.eql(u8, thread.messages.items[index].title, "Thoughts")) return false;
        try thread.finishThinking(gpa, index);
        return true;
    }

    fn applyReasoningDelta(
        self: *ThreadProjection,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        delta: []const u8,
    ) !bool {
        if (delta.len == 0) return false;
        var visible_change = false;
        if (self.thinking_index) |index| {
            try thread.appendThinkingDelta(gpa, index, delta);
        } else if (self.agent_index) |agent_index| {
            self.thinking_index = try thread.insert(gpa, agent_index, .thinking, "Thinking...", delta);
            self.agent_index = agent_index + 1;
            thread.select(self.thinking_index.?);
            visible_change = true;
        } else {
            self.thinking_index = try thread.append(gpa, .thinking, "Thinking...", delta);
            visible_change = true;
        }
        if (self.agent_index == null and !self.tool_seen_in_response) selectGeneratedMessage(thread, self.thinking_index.?);
        return visible_change;
    }

    fn applyToolPreview(
        self: *ThreadProjection,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        tool: ai.ToolDelta,
    ) !bool {
        if (std.mem.eql(u8, tool.name, "bash")) {
            const command = agent_mod.parseCommand(gpa, tool.arguments) catch return false;
            gpa.free(command);
        }
        const title = try agent_mod.formatToolTitle(gpa, tool.name, tool.arguments);
        defer gpa.free(title);

        const loading_removed = self.loading_index != null;
        self.removeLoading(gpa, thread);

        var visible_change = false;
        if (self.toolThreadIndex(tool.index)) |index| {
            visible_change = !toolTitleMatchesCommand(thread.messages.items[index].title, title);
            try thread.updateTool(gpa, index, title);
        } else {
            const index = try thread.startTool(gpa, title);
            try self.putToolThreadIndex(gpa, tool.index, index);
            visible_change = true;
        }
        self.tool_seen_in_response = true;
        self.agent_index = null;
        return loading_removed or visible_change;
    }

    fn finishTool(
        self: *ThreadProjection,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        tool: agent_mod.Agent.Event.ToolCallFinished,
    ) !bool {
        const policy = tool_policy.forName(tool.name);
        const existing_index = self.toolThreadIndex(tool.index);
        const index = if (existing_index) |index| index else index: {
            const created = try thread.startTool(gpa, tool.display_label);
            try self.putToolThreadIndex(gpa, tool.index, created);
            break :index created;
        };

        const visible_before = toolFinishVisibleChange(thread, index, tool.display_label);
        const was_expanded = thread.messages.items[index].expanded;
        try thread.updateTool(gpa, index, tool.display_label);
        try thread.finishTool(gpa, index, tool.display_body, tool.stderr, tool.failed);
        thread.messages.items[index].expanded = policy.expand_by_default;
        thread.messages.items[index].tool_render = policy.render;
        selectGeneratedMessage(thread, index);
        self.tool_seen_in_response = true;
        self.agent_index = null;
        return existing_index == null or visible_before or policy.expand_by_default != was_expanded;
    }

    fn selectGeneratedMessage(thread: *thread_mod.Thread, index: u32) void {
        assert(index < thread.messages.items.len);
        if (thread.selected) |selected| {
            if (selected != index) return;
        }
        thread.select(index);
    }

    fn toolFinishVisibleChange(thread: *const thread_mod.Thread, index: u32, command: []const u8) bool {
        if (index >= thread.messages.items.len) return true;
        const message = thread.messages.items[index];
        if (message.kind != .tool) return true;
        if (message.expanded) return true;
        return !toolTitleMatchesCommand(message.title, command);
    }

    fn toolThreadIndex(self: *const ThreadProjection, tool_index: u32) ?u32 {
        if (tool_index >= self.tool_indexes.items.len) return null;
        return self.tool_indexes.items[tool_index];
    }

    fn putToolThreadIndex(
        self: *ThreadProjection,
        gpa: std.mem.Allocator,
        tool_index: u32,
        thread_index: u32,
    ) !void {
        while (self.tool_indexes.items.len <= tool_index) {
            try self.tool_indexes.append(gpa, null);
        }
        self.tool_indexes.items[tool_index] = thread_index;
    }

    fn adjustIndexesAfterRemove(self: *ThreadProjection, removed_index: u32) void {
        adjustOptionalIndex(&self.agent_index, removed_index);
        adjustOptionalIndex(&self.thinking_index, removed_index);
        for (self.tool_indexes.items) |*tool_index| adjustOptionalIndex(tool_index, removed_index);
    }
};

fn adjustOptionalIndex(index: *?u32, removed_index: u32) void {
    const current = index.* orelse return;
    if (current == removed_index) {
        index.* = null;
    } else if (current > removed_index) {
        index.* = current - 1;
    }
}

fn toolTitleMatchesCommand(title: []const u8, command: []const u8) bool {
    const prefix = "$ ";
    return std.mem.startsWith(u8, title, prefix) and std.mem.eql(u8, title[prefix.len..], command);
}

fn chooseLoadingWordIndex(io: std.Io) u8 {
    assert(loading_spinners.len > 0);
    const timestamp: std.Io.Timestamp = .now(io, .awake);
    const index = @mod(timestamp.nanoseconds, loading_spinners.len);
    return @intCast(index);
}

test "projection streams content into thread" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);
    var projection: ThreadProjection = .{};
    defer projection.deinit(gpa);

    try std.testing.expect(try projection.apply(gpa, &thread, .{ .response_delta = "hello" }));
    try std.testing.expectEqual(@as(usize, 1), thread.messages.items.len);
    try std.testing.expectEqualStrings("hello", thread.messages.items[0].body);
}
