//! Event types and event bus for the plugin system.
//!
//! The EventBus dispatches lifecycle events to subscribed Lua callbacks.
//! Events are emitted by the agent loop and executor at key points.

const std = @import("std");
const c = @import("c");
const State = @import("state.zig").State;

// ── Event type ─────────────────────────────────────────────────────

/// All event types that can be emitted on the plugin event bus.
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

// ── Event Bus ──────────────────────────────────────────────────────

/// A subscription: a Lua function reference stored as a registry reference.
const Subscription = struct {
    /// Lua registry reference (LUA_NOREF = no reference)
    func_ref: c_int,
    /// Plugin name (for error reporting)
    plugin_name: []const u8,
};

/// The event bus dispatches events to subscribed Lua callbacks.
/// Each plugin registers callbacks via `nova.on(event_name, callback)`.
pub const EventBus = struct {
    allocator: std.mem.Allocator,
    /// Per-event subscriptions: event_name -> list of subscriptions
    subscriptions: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Subscription)),
    /// Lua state where callbacks are registered (the main plugin state)
    L: ?*State,

    const Self = @This();

    /// Initialize the event bus.
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .subscriptions = .empty,
            .L = null,
        };
    }

    /// Deinitialize the event bus, freeing all subscriptions.
    pub fn deinit(self: *Self) void {
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |sub| {
                if (self.L) |L| {
                    c.luaL_unref(L.handle, c.LUA_REGISTRYINDEX, sub.func_ref);
                }
                self.allocator.free(sub.plugin_name);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.subscriptions.deinit(self.allocator);
    }

    /// Set the Lua state used for callback dispatch.
    pub fn setState(self: *Self, L: *State) void {
        self.L = L;
    }

    /// Subscribe a Lua function to an event.
    /// `func_ref` is a Lua registry reference to the callback function.
    /// `plugin_name` is used for error reporting.
    pub fn subscribe(self: *Self, event_name: []const u8, func_ref: c_int, plugin_name: []const u8) !void {
        var subs = self.subscriptions.getOrPut(self.allocator, event_name) catch return error.OutOfMemory;
        if (!subs.found_existing) {
            subs.value_ptr.* = .empty;
        }
        try subs.value_ptr.append(self.allocator, .{
            .func_ref = func_ref,
            .plugin_name = try self.allocator.dupe(u8, plugin_name),
        });
    }

    /// Unsubscribe all callbacks for a plugin.
    pub fn unsubscribePlugin(self: *Self, plugin_name: []const u8) void {
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            var subs = entry.value_ptr;
            var i: usize = 0;
            while (i < subs.items.len) {
                if (std.mem.eql(u8, subs.items[i].plugin_name, plugin_name)) {
                    if (self.L) |L| {
                        c.luaL_unref(L.handle, c.LUA_REGISTRYINDEX, subs.items[i].func_ref);
                    }
                    self.allocator.free(subs.items[i].plugin_name);
                    _ = subs.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Emit an event to all subscribed callbacks.
    /// Errors in individual callbacks are caught and logged — other callbacks
    /// still run. Returns the number of callbacks that were invoked.
    pub fn emit(self: *Self, event: Event) usize {
        const L = self.L orelse return 0;
        const event_name = event.name();
        const subs = self.subscriptions.get(event_name) orelse return 0;

        var count: usize = 0;
        for (subs.items) |sub| {
            // Push the callback function from the registry
            _ = c.lua_rawgeti(L.handle, c.LUA_REGISTRYINDEX, sub.func_ref);
            if (!L.isFunction(-1)) {
                L.pop(1);
                continue;
            }

            // Push event data as a Lua table
            L.newTable();
            pushEventData(L, event);

            // Call the callback
            const rc = L.pcall(1, 0);
            if (rc != c.LUA_OK) {
                const err = L.getErrorMessage();
                std.log.warn("plugin.event.error plugin={s} event={s} err={s}", .{
                    sub.plugin_name,
                    event_name,
                    err orelse "unknown",
                });
                L.pop(1); // pop error message
            }
            count += 1;
        }
        return count;
    }
};

/// Push event data as a Lua table on top of the stack.
fn pushEventData(L: *State, event: Event) void {
    switch (event) {
        .turn_started, .turn_ended, .response_received => {
            // No payload for these events
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

test "event bus: init and deinit" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    try std.testing.expect(bus.L == null);
}

test "event bus: emit with no subscribers does nothing" {
    var L = State.init();
    defer L.deinit();

    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    bus.setState(&L);

    const count = bus.emit(.{ .turn_started = {} });
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "event bus: subscribe and emit" {
    var L = State.init();
    defer L.deinit();

    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    bus.setState(&L);
    bus.setState(&L);

    // Register a Lua callback that sets a global flag
    try std.testing.expect(L.doString(
        \\function on_turn_started(data)
        \\  _G.event_fired = true
        \\end
    ));

    // Get a registry reference to the function
    _ = c.lua_getglobal(L.handle, "on_turn_started");
    try std.testing.expect(L.isFunction(-1));
    const func_ref = c.luaL_ref(L.handle, c.LUA_REGISTRYINDEX);

    try bus.subscribe("turn_started", func_ref, "test_plugin");

    const count = bus.emit(.{ .turn_started = {} });
    try std.testing.expectEqual(@as(usize, 1), count);

    // Check the global flag was set
    _ = c.lua_getglobal(L.handle, "event_fired");
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "event bus: error in one callback doesn't affect others" {
    var L = State.init();
    defer L.deinit();

    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    bus.setState(&L);

    // First callback errors
    try std.testing.expect(L.doString(
        \\function on_turn_error(data)
        \\  error("this callback failed")
        \\end
    ));
    _ = c.lua_getglobal(L.handle, "on_turn_error");
    const ref1 = c.luaL_ref(L.handle, c.LUA_REGISTRYINDEX);
    try bus.subscribe("turn_started", ref1, "faulty_plugin");

    // Second callback succeeds
    try std.testing.expect(L.doString(
        \\function on_turn_ok(data)
        \\  _G.ok_fired = true
        \\end
    ));
    _ = c.lua_getglobal(L.handle, "on_turn_ok");
    const ref2 = c.luaL_ref(L.handle, c.LUA_REGISTRYINDEX);
    try bus.subscribe("turn_started", ref2, "good_plugin");

    const count = bus.emit(.{ .turn_started = {} });
    try std.testing.expectEqual(@as(usize, 2), count);

    // The good callback should have run
    _ = c.lua_getglobal(L.handle, "ok_fired");
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "event bus: unsubscribe plugin" {
    var L = State.init();
    defer L.deinit();

    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    bus.setState(&L);

    try std.testing.expect(L.doString(
        \\function on_event(data)
        \\  _G.fired = true
        \\end
    ));
    _ = c.lua_getglobal(L.handle, "on_event");
    const ref = c.luaL_ref(L.handle, c.LUA_REGISTRYINDEX);
    try bus.subscribe("turn_started", ref, "test_plugin");

    try std.testing.expectEqual(@as(usize, 1), bus.emit(.{ .turn_started = {} }));

    bus.unsubscribePlugin("test_plugin");
    try std.testing.expectEqual(@as(usize, 0), bus.emit(.{ .turn_started = {} }));
}
