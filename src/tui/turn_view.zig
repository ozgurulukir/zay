//! TurnView owns the visible state of the current agent turn.
//!
//! The durable transcript lives in `thread.zig`. This type only remembers the
//! streaming positions needed to turn `Agent.Event`s into transcript mutations
//! and synthetic UI state such as the loading spinner.

const std = @import("std");

const agent_mod = @import("../agent.zig");
const ai = @import("../ai.zig");
const thread_mod = @import("../thread.zig");
const tools_mod = @import("../tools.zig");
const tool_policy = @import("tool_policy.zig");

const assert = std.debug.assert;

pub const loading_spinners = [12][]const u8{ "Firing Neurons", "Multiplying Matrices", "brr..brr...", "Warping", "Hailing the machine god", "Tokenmaxxing", "Uploading consciousness", "Brain dancing", "Resisting psychosis", "Wait a minute...", "beep... boop...", "Uhhh" };

pub const TurnView = struct {
    agent_index: ?u32 = null,
    thinking_index: ?u32 = null,
    /// Chosen when the turn starts. The spinner itself is synthetic and is
    /// drawn outside the transcript while `activity == .awaiting_model`.
    loading_word_index: u8 = 0,
    activity: Activity = .idle,
    tool_seen_in_response: bool = false,
    pending_redraw: bool = false,
    tool_indexes: std.ArrayList(?u32) = .empty,

    pub const Activity = union(enum) {
        idle,
        awaiting_model,
        thinking: u32,
        writing_response: u32,
        calling_tools,
    };

    pub fn deinit(self: *TurnView, gpa: std.mem.Allocator) void {
        self.tool_indexes.deinit(gpa);
        self.* = undefined;
    }

    pub fn reset(self: *TurnView, io: std.Io) void {
        self.agent_index = null;
        self.thinking_index = null;
        self.loading_word_index = chooseLoadingWordIndex(io);
        self.activity = .idle;
        self.tool_seen_in_response = false;
        self.pending_redraw = false;
        self.tool_indexes.clearRetainingCapacity();
    }

    pub fn apply(
        self: *TurnView,
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

    pub fn awaitingOutput(self: *const TurnView) bool {
        return self.activity == .awaiting_model;
    }

    /// Begin waiting for the next chunk of model output. The spinner is drawn
    /// outside the transcript; no thread mutation.
    pub fn awaitModel(self: *TurnView) void {
        assert(self.loading_word_index < loading_spinners.len);
        self.activity = .awaiting_model;
    }

    fn applyResponseDelta(
        self: *TurnView,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        delta: []const u8,
    ) !bool {
        if (delta.len == 0) return false;
        _ = try self.finishThinking(gpa, thread);
        try self.applyContentDelta(gpa, thread, delta);
        self.activity = .{ .writing_response = self.agent_index.? };
        self.pending_redraw = true;
        return true;
    }

    fn applyThinkingDelta(
        self: *TurnView,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        delta: []const u8,
    ) !bool {
        if (try self.applyReasoningDelta(gpa, thread, delta)) self.pending_redraw = true;
        if (self.thinking_index) |index| self.activity = .{ .thinking = index };
        return false;
    }

    fn applyToolDelta(
        self: *TurnView,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        tool: ai.ToolDelta,
    ) !bool {
        const thinking_finished = try self.finishThinking(gpa, thread);
        if (try self.applyToolPreview(gpa, thread, tool)) {
            self.activity = .calling_tools;
            self.pending_redraw = true;
        }
        if (thinking_finished) self.pending_redraw = true;
        return false;
    }

    fn applyToolFinished(
        self: *TurnView,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        tool: agent_mod.Agent.Event.ToolCallFinished,
    ) !bool {
        const thinking_finished = try self.finishThinking(gpa, thread);
        self.activity = .calling_tools;
        return thinking_finished or try self.finishTool(gpa, thread, tool);
    }

    fn applyToolBatchFinished(
        self: *TurnView,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
    ) !bool {
        _ = try self.finishThinking(gpa, thread);
        self.agent_index = null;
        self.thinking_index = null;
        self.tool_seen_in_response = false;
        self.tool_indexes.clearRetainingCapacity();
        // The batch is done; wait for the next response segment.
        self.activity = .awaiting_model;
        return true;
    }

    fn applyTurnFailed(
        self: *TurnView,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        message: []const u8,
    ) !bool {
        self.activity = .idle;
        _ = thread.stopRunningTools();
        _ = try thread.append(gpa, .notice, "notice", message);
        return true;
    }

    fn applyTurnFinished(
        self: *TurnView,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
    ) !bool {
        self.activity = .idle;
        _ = try self.finishThinking(gpa, thread);
        _ = thread.stopRunningTools();
        return true;
    }

    fn takePendingRedraw(self: *TurnView) bool {
        const redraw = self.pending_redraw;
        self.pending_redraw = false;
        return redraw;
    }

    fn applyContentDelta(
        self: *TurnView,
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

    fn finishThinking(self: *TurnView, gpa: std.mem.Allocator, thread: *thread_mod.Thread) !bool {
        const index = self.thinking_index orelse return false;
        if (index >= thread.messages.items.len) return false;
        if (std.mem.eql(u8, thread.messages.items[index].title, "Thoughts")) return false;
        try thread.finishThinking(gpa, index);
        return true;
    }

    fn applyReasoningDelta(
        self: *TurnView,
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
        self: *TurnView,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        tool: ai.ToolDelta,
    ) !bool {
        if (std.mem.eql(u8, tool.name, "bash")) {
            const command = agent_mod.parseCommand(gpa, tool.arguments) catch return false;
            gpa.free(command);
            if (try skillNameFromBashRead(gpa, tool.arguments)) |skill_name| {
                defer gpa.free(skill_name);
                return try self.applySkillPreview(gpa, thread, tool.index, skill_name);
            }
        }
        var display = try agent_mod.formatToolDisplay(gpa, tool.name, tool.arguments);
        defer display.deinit(gpa);
        if (std.mem.eql(u8, tool.name, "bash") and display.expanded_label == null) return false;

        // Reached only once arguments parse — partial tool args return above,
        // keeping the spinner up. Clearing it here counts as a visible change.
        const was_awaiting = self.awaitingOutput();

        var visible_change = false;
        if (self.toolThreadIndex(tool.index)) |index| {
            visible_change = !toolDisplayMatches(thread.messages.items[index], display);
            try thread.updateToolExpanded(gpa, index, display.label, display.expanded_label);
        } else {
            const index = try thread.startTool(gpa, display.label);
            try thread.updateToolExpanded(gpa, index, display.label, display.expanded_label);
            try self.putToolThreadIndex(gpa, tool.index, index);
            visible_change = true;
        }
        self.tool_seen_in_response = true;
        self.agent_index = null;
        return was_awaiting or visible_change;
    }

    fn setSkillMessage(gpa: std.mem.Allocator, thread: *thread_mod.Thread, index: u32, title: []const u8) !void {
        assert(index < thread.messages.items.len);
        const message = &thread.messages.items[index];
        const owned_title = try gpa.dupe(u8, title);
        errdefer gpa.free(owned_title);
        const owned_body = try gpa.dupe(u8, "");
        errdefer gpa.free(owned_body);
        gpa.free(message.title);
        gpa.free(message.body);
        if (message.stderr_body) |stderr| gpa.free(stderr);
        if (message.tool_expanded_title) |expanded_title| gpa.free(expanded_title);
        message.* = .{
            .kind = .skill,
            .title = owned_title,
            .body = owned_body,
            .expanded = false,
        };
    }

    fn applySkillPreview(
        self: *TurnView,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        tool_index: u32,
        skill_name: []const u8,
    ) !bool {
        const title = try std.fmt.allocPrint(gpa, "[SKILL] {s}", .{skill_name});
        defer gpa.free(title);

        const was_awaiting = self.awaitingOutput();
        var visible_change = false;
        if (self.toolThreadIndex(tool_index)) |index| {
            visible_change = thread.messages.items[index].kind != .skill or !std.mem.eql(u8, thread.messages.items[index].title, title);
            if (visible_change) try setSkillMessage(gpa, thread, index, title);
        } else {
            const index = try thread.append(gpa, .skill, title, "");
            try self.putToolThreadIndex(gpa, tool_index, index);
            visible_change = true;
        }
        self.tool_seen_in_response = true;
        self.agent_index = null;
        return was_awaiting or visible_change;
    }

    fn finishTool(
        self: *TurnView,
        gpa: std.mem.Allocator,
        thread: *thread_mod.Thread,
        tool: agent_mod.Agent.Event.ToolCallFinished,
    ) !bool {
        const policy = tool_policy.forName(tool.name);
        const existing_index = self.toolThreadIndex(tool.index);
        if (existing_index) |index| {
            if (index < thread.messages.items.len and thread.messages.items[index].kind == .skill) {
                try thread.finishSkill(gpa, index, tool.display_body, tool.failed);
                self.tool_seen_in_response = true;
                self.agent_index = null;
                return true;
            }
        }
        const index = if (existing_index) |index| index else index: {
            const created = try thread.startTool(gpa, tool.display_label);
            try thread.updateToolExpanded(gpa, created, tool.display_label, tool.display_expanded_label);
            try self.putToolThreadIndex(gpa, tool.index, created);
            break :index created;
        };

        const visible_before = toolFinishVisibleChange(thread, index, tool.display_label);
        const was_expanded = thread.messages.items[index].expanded;
        const was_running = thread.messages.items[index].tool_running;
        try thread.updateToolExpanded(gpa, index, tool.display_label, tool.display_expanded_label);
        try thread.finishTool(gpa, index, tool.display_body, tool.stderr, tool.failed);
        thread.setExpanded(index, policy.expand_by_default);
        thread.messages.items[index].tool_render = policy.render;
        selectGeneratedMessage(thread, index);
        self.tool_seen_in_response = true;
        self.agent_index = null;
        return existing_index == null or was_running or visible_before or policy.expand_by_default != was_expanded;
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

    fn toolThreadIndex(self: *const TurnView, tool_index: u32) ?u32 {
        if (tool_index >= self.tool_indexes.items.len) return null;
        return self.tool_indexes.items[tool_index];
    }

    fn skillNameFromBashRead(gpa: std.mem.Allocator, arguments: []const u8) !?[]u8 {
        const JsonArgs = struct {
            command: ?[]const u8 = null,
        };
        const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch return null;
        defer parsed.deinit();
        const command = parsed.value.command orelse return null;
        if (!commandReadsSkill(command)) return null;
        const name = skillNameFromCommand(command) orelse return null;
        return try gpa.dupe(u8, name);
    }

    fn commandReadsSkill(command: []const u8) bool {
        if (std.mem.indexOf(u8, command, "cat") == null) return false;
        if (std.mem.indexOf(u8, command, ".agents/") == null) return false;
        return std.mem.indexOf(u8, command, "/SKILL.md") != null;
    }

    fn skillNameFromCommand(command: []const u8) ?[]const u8 {
        const skill_suffix = "/SKILL.md";
        const suffix_start = std.mem.indexOf(u8, command, skill_suffix) orelse return null;
        var name_start = suffix_start;
        while (name_start > 0) {
            const byte = command[name_start - 1];
            if (byte == '/' or byte == '\'' or byte == '"' or std.ascii.isWhitespace(byte)) break;
            name_start -= 1;
        }
        const name = command[name_start..suffix_start];
        if (name.len == 0) return null;
        if (std.mem.indexOfScalar(u8, name, '/') != null) return null;
        return name;
    }

    fn putToolThreadIndex(
        self: *TurnView,
        gpa: std.mem.Allocator,
        tool_index: u32,
        thread_index: u32,
    ) !void {
        while (self.tool_indexes.items.len <= tool_index) {
            try self.tool_indexes.append(gpa, null);
        }
        self.tool_indexes.items[tool_index] = thread_index;
    }
};

fn toolDisplayMatches(message: thread_mod.Message, display: tools_mod.ToolDisplay) bool {
    if (!toolTitleMatchesText(message.title, display.label)) return false;
    if (display.expanded_label) |label| {
        const title = message.tool_expanded_title orelse return false;
        return toolTitleMatchesText(title, label);
    }
    return message.tool_expanded_title == null;
}

fn toolTitleMatchesCommand(title: []const u8, command: []const u8) bool {
    return toolTitleMatchesText(title, command);
}

fn toolTitleMatchesText(title: []const u8, text: []const u8) bool {
    const prefix = "🛠  ";
    return std.mem.startsWith(u8, title, prefix) and std.mem.eql(u8, title[prefix.len..], text);
}

fn chooseLoadingWordIndex(io: std.Io) u8 {
    assert(loading_spinners.len > 0);
    const timestamp: std.Io.Timestamp = .now(io, .awake);
    const index = @mod(timestamp.nanoseconds, loading_spinners.len);
    return @intCast(index);
}

test "bash read of skill renders skill row" {
    const gpa = std.testing.allocator;
    var view: TurnView = .{};
    defer view.deinit(gpa);
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    const changed = try view.applyToolPreview(gpa, &thread, .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"cat .agents/skills/tigerstyle/SKILL.md\",\"reason\":\"Read the tigerstyle skill instructions\"}",
    });

    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 1), thread.messages.items.len);
    try std.testing.expectEqual(thread_mod.MessageKind.skill, thread.messages.items[0].kind);
    try std.testing.expectEqualStrings("[SKILL] tigerstyle", thread.messages.items[0].title);

    const finished = try view.applyToolFinished(gpa, &thread, .{
        .index = 0,
        .name = "bash",
        .display_label = "Read the tigerstyle skill instructions",
        .display_expanded_label = "cat .agents/skills/tigerstyle/SKILL.md",
        .display_body = "skill file contents",
    });
    try std.testing.expect(finished);
    try std.testing.expectEqualStrings("skill file contents", thread.messages.items[0].body);
    try std.testing.expect(!thread.messages.items[0].expanded);
    thread.toggleSelected();
    try std.testing.expect(thread.messages.items[0].expanded);
}

test "bash skill detection uses command, not reason" {
    const gpa = std.testing.allocator;
    const skill_name = try TurnView.skillNameFromBashRead(gpa, "{\"command\":\"cat .agents/skills/tigerstyle/SKILL.md\",\"reason\":\"Read the skill file\"}");
    defer if (skill_name) |name| gpa.free(name);
    try std.testing.expectEqualStrings("tigerstyle", skill_name.?);
}

test "turn view streams content into thread" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);
    var turn_view: TurnView = .{};
    defer turn_view.deinit(gpa);

    turn_view.awaitModel();
    try std.testing.expect(turn_view.activity == .awaiting_model);

    try std.testing.expect(try turn_view.apply(gpa, &thread, .{ .response_delta = "hello" }));
    try std.testing.expectEqual(@as(usize, 1), thread.messages.items.len);
    try std.testing.expectEqualStrings("hello", thread.messages.items[0].body);
    try std.testing.expect(turn_view.activity == .writing_response);
    try std.testing.expectEqual(@as(u32, 0), turn_view.activity.writing_response);
}
