//! Event types for the plugin system.
//!
//! Events are emitted by the agent loop (`Agent.ExecutorBridge`) at tool-call
//! boundaries and dispatched to every plugin by `PluginManager.emitEvent`,
//! which drains each plugin's `"nova_events"` Lua registry table.

const std = @import("std");
const c = @import("c");
const State = @import("state.zig").State;

// ── Event type ─────────────────────────────────────────────────────

/// All event types that can be emitted to plugin callbacks.
pub const Event = union(enum) {
    /// A new agent turn has started.
    turn_started: void,
    /// An agent turn has ended.
    turn_ended: void,
    /// A tool call has started.
    tool_call_started: ToolCallPayload,
    /// A tool call has finished.
    tool_call_finished: ToolCallFinishedPayload,
    /// A response was received from the LLM.
    response_received: void,
    /// A plugin was loaded.
    plugin_loaded: PluginPayload,
    /// A plugin was unloaded.
    plugin_unloaded: PluginPayload,

    pub const ToolCallPayload = struct {
        name: []const u8,
        call_id: []const u8,
    };

    pub const ToolCallFinishedPayload = struct {
        name: []const u8,
        call_id: []const u8,
        success: bool,
    };

    pub const PluginPayload = struct {
        name: []const u8,
    };

    /// Return the event name as a string (for Lua callback lookup).
    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .turn_started => "turn_started",
            .turn_ended => "turn_ended",
            .tool_call_started => "tool_call_started",
            .tool_call_finished => "tool_call_finished",
            .response_received => "response_received",
            .plugin_loaded => "plugin_loaded",
            .plugin_unloaded => "plugin_unloaded",
        };
    }
};

// ── Payload marshalling ─────────────────────────────────────────────

/// Push event data as a Lua table on top of the stack. Public so
/// `PluginManager.emitEvent` (manager.zig) can build the callback argument.
pub fn pushEventData(L: *State, event: Event) void {
    switch (event) {
        .turn_started, .turn_ended, .response_received => {
            // No payload for these events.
        },
        .tool_call_started => |payload| {
            L.pushString(payload.name);
            _ = c.lua_setfield(L.handle, -2, "name");
            L.pushString(payload.call_id);
            _ = c.lua_setfield(L.handle, -2, "call_id");
        },
        .tool_call_finished => |payload| {
            L.pushString(payload.name);
            _ = c.lua_setfield(L.handle, -2, "name");
            L.pushString(payload.call_id);
            _ = c.lua_setfield(L.handle, -2, "call_id");
            L.pushBoolean(payload.success);
            _ = c.lua_setfield(L.handle, -2, "success");
        },
        .plugin_loaded => |payload| {
            L.pushString(payload.name);
            _ = c.lua_setfield(L.handle, -2, "name");
        },
        .plugin_unloaded => |payload| {
            L.pushString(payload.name);
            _ = c.lua_setfield(L.handle, -2, "name");
        },
    }
}

// ── Tests ──────────────────────────────────────────────────────────

test "event: name returns correct string" {
    const e1 = Event{ .turn_started = {} };
    try std.testing.expectEqualStrings("turn_started", e1.name());
    const e2 = Event{ .turn_ended = {} };
    try std.testing.expectEqualStrings("turn_ended", e2.name());
    const e3 = Event{ .tool_call_started = .{ .name = @as([]const u8, "bash"), .call_id = @as([]const u8, "1") } };
    try std.testing.expectEqualStrings("tool_call_started", e3.name());
    const e4 = Event{ .tool_call_finished = .{ .name = @as([]const u8, "bash"), .call_id = @as([]const u8, "1"), .success = true } };
    try std.testing.expectEqualStrings("tool_call_finished", e4.name());
    const e5 = Event{ .response_received = {} };
    try std.testing.expectEqualStrings("response_received", e5.name());
    const e6 = Event{ .plugin_loaded = .{ .name = @as([]const u8, "test") } };
    try std.testing.expectEqualStrings("plugin_loaded", e6.name());
    const e7 = Event{ .plugin_unloaded = .{ .name = @as([]const u8, "test") } };
    try std.testing.expectEqualStrings("plugin_unloaded", e7.name());
}
