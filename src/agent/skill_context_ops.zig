//! Skill-context ops seam, extracted from agent.zig (issue #367
//! slice 10). Owns the agent-side wiring for the session skill context:
//! prefix activation on user prompts, the dirty/pending flag lifecycle,
//! persistence to the session writer, inventory events to the listener,
//! and `skill` tool-result admission.
//!
//! The `SkillContext` TYPE lives in `src/context/skill_context.zig`
//! (with `skill_history.zig` beside it); the three relevant fields stay on
//! `Agent` (`skill_context`, `skill_context_dirty`,
//! `skill_context_changed_pending`) and are reached through the receiver.
//! Spoke pattern (agent/text_recovery.zig, agent/queue_ops.zig): free
//! functions over `*Agent`; this file imports agent.zig only for the
//! `Agent` type; mutual import terminates at the type level. No locks:
//! everything here runs on the worker thread between turn iterations.
//!
//! Flag lifecycle (load-bearing): `noteChange` collapses the duplicate
//! write shape — dirty=true + pending=true + best-effort persist (the
//! `addUserPrompt` and `takeToolResults` sites were byte-identical).
//! `noteChangeDeferred` marks only (the `takeMessage` site — `run`
//! persists on the next iteration). The `clearNonSystemMessages` reset and
//! `replaceConversation`'s count-delta re-derivation stay inline in
//! agent.zig: distinct semantics, one line each. The dirty-guard contract
//! is unchanged: `reloadFromSession` refuses while dirty
//! (`error.SkillContextNotPersisted`), and `run` calls `persist` +
//! `emitPendingInventory` before every turn iteration.

const std = @import("std");

const agent_mod = @import("../agent.zig");
const ai = @import("../ai.zig");
const executor_mod = @import("../executor.zig");
const session_mod = @import("../session.zig");
const skill_context_mod = @import("../context/skill_context.zig");
const skill_history = @import("../context/skill_history.zig");
const skill_mod = @import("../skill.zig");

const Agent = agent_mod.Agent;
const assert = std.debug.assert;

/// Same `.agent` scope as agent.zig so log output is unchanged by the move.
const log = std.log.scoped(.agent);

pub fn prependBlocks(self: *Agent, prompt: []const u8, blocks: []ai.ContentBlock) !void {
    assert(blocks.len > 0);
    assert(blocks[0] == .text);
    var loaded_names: [skill_context_mod.SkillContext.entries_max][]const u8 = undefined;
    for (self.skill_context.entries.items, 0..) |entry, index| loaded_names[index] = entry.name;
    const prefix = try skill_mod.promptPrefixWithNames(self.gpa, self.skills, prompt, loaded_names[0..self.skill_context.entries.items.len]);
    defer self.gpa.free(prefix.text);
    defer self.gpa.free(prefix.names);
    if (prefix.text.len == 0) return;

    for (prefix.names) |name| {
        const loaded = skill_mod.find(self.skills, name) orelse continue;
        _ = try self.skill_context.activate(self.gpa, loaded.name, loaded.body);
    }

    const old_text = blocks[0].text.text;
    const new_text = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ prefix.text, old_text });
    self.gpa.free(old_text);
    blocks[0].text.text = new_text;
}

fn inventorySnapshot(self: *Agent) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(self.gpa);
    for (self.skill_context.entries.items, 0..) |entry, index| {
        if (index > 0) try out.append(self.gpa, '\n');
        try out.appendSlice(self.gpa, entry.name);
    }
    return out.toOwnedSlice(self.gpa);
}

pub fn emitPendingInventory(self: *Agent, comptime L: type, listener: L) !void {
    if (!self.skill_context_changed_pending) return;
    const names = try inventorySnapshot(self);
    self.skill_context_changed_pending = false;
    listener.emit(.{ .skill_inventory_changed = .{ .names = names } }) catch |err| {
        self.skill_context_changed_pending = true;
        return err;
    };
}

/// The skill-context write happened: mark dirty + pending, then persist
/// best-effort (a failed session write is logged, never fails the caller).
pub fn noteChange(self: *Agent) void {
    noteChangeDeferred(self);
    persist(self) catch |err| log.warn("session skill context write failed: {s}", .{@errorName(err)});
}

/// Like `noteChange`, but without the immediate persist — `run` persists
/// before the next turn iteration. Used where the caller cannot surface a
/// write failure yet (`takeMessage` runs mid-appends).
pub fn noteChangeDeferred(self: *Agent) void {
    self.skill_context_dirty = true;
    self.skill_context_changed_pending = true;
}

pub fn forResult(self: *Agent, result: *const executor_mod.ToolResult) !?skill_context_mod.SkillContext.Entry {
    var index = self.messages().len;
    while (index > 0) {
        index -= 1;
        const message = self.messages()[index];
        if (message != .assistant) continue;
        for (message.assistant.content) |block| {
            if (block != .tool_call) continue;
            const call = block.tool_call;
            if (!std.mem.eql(u8, call.call_id.slice(), result.call_id.slice())) continue;
            if (!std.mem.eql(u8, call.name, "skill")) return null;
            // Skill results pair only with the immediately preceding
            // assistant batch — deeper history is never searched.
            var args = @import("../tools/skill.zig").parseArgs(self.gpa, call.arguments) catch |err| {
                if (err == error.OutOfMemory) return err;
                return null;
            };
            defer args.deinit(self.gpa);
            if (args.resource != null or args.command != null) return null;
            for (self.skill_context.entries.items) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.name, args.name)) return entry;
            }
            if (skill_mod.find(self.skills, args.name)) |source| return .{ .name = source.name, .body = source.body };
            return null;
        }
        return null;
    }
    return null;
}

pub fn persist(self: *Agent) !void {
    if (!self.skill_context_dirty) return;
    if (self.context_manager.session_writer) |writer| try writer.appendSkillContext(&self.skill_context);
    self.skill_context_dirty = false;
}

test "skill context metadata enqueue failure retains admitted activation and retries" {
    const gpa = std.testing.allocator;
    var manager = try session_mod.SessionManager.init(gpa, std.testing.io, ":memory:");
    const session = try manager.create("/tmp/zay", .{});
    var writer: session_mod.SessionWriter = undefined;
    try writer.initWithSession(gpa, std.testing.io, manager, session, 4);
    defer writer.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.attachSessionWriter(&writer);
    try agent.addUser("admitted message");
    _ = try agent.skill_context.activate(gpa, "how", "admitted instructions");
    agent.skill_context_dirty = true;
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    writer.gpa = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, persist(&agent));
    writer.gpa = gpa;
    try std.testing.expect(agent.skill_context_dirty);
    try std.testing.expectEqualStrings("admitted instructions", agent.skill_context.body("how").?);
    try std.testing.expectEqualStrings("admitted message", agent.messages()[0].text());
    try std.testing.expectError(error.SkillContextNotPersisted, agent.reloadFromSession());
    try persist(&agent);
    try std.testing.expect(!agent.skill_context_dirty);
    try agent.reloadFromSession();
    try std.testing.expectEqualStrings("admitted instructions", agent.skill_context.body("how").?);
    try std.testing.expectEqualStrings("admitted message", agent.messages()[0].text());
}
