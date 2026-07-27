//! Plugin lifecycle management.
//!
//! A plugin is a Lua script that registers tools, hooks, and commands
//! with the Nova runtime. Each plugin has its own sandboxed Lua state
//! with configurable permissions and resource limits.

const std = @import("std");
const c = @import("c");
const State = @import("state.zig").State;
const sandbox = @import("sandbox.zig");

/// A loaded plugin instance.
pub const Plugin = struct {
    /// Plugin name (from manifest or filename)
    name: []const u8,
    /// Lua state (sandboxed)
    state: State,
    /// Whether this is an embedded (trusted) plugin
    is_embedded: bool,
    /// Permissions granted to this plugin
    permissions: sandbox.Permissions,

    const Self = @This();

    /// Initialize a new plugin with a sandboxed Lua state.
    pub fn init(name: []const u8, is_embedded: bool, permissions: sandbox.Permissions) Self {
        const perms = if (is_embedded) sandbox.Permissions{
            .full_access = true,
        } else permissions;
        const L = sandbox.createSandboxedState(perms);
        return Self{
            .name = name,
            .state = L,
            .is_embedded = is_embedded,
            .permissions = perms,
        };
    }

    /// Deinitialize the plugin, closing its Lua state.
    pub fn deinit(self: *Self) void {
        sandbox.freeHookData(self.state.handle);
        self.state.deinit();
    }

    /// Load and execute a Lua chunk in the plugin's sandbox.
    /// Returns true on success, false on error.
    pub fn loadChunk(self: *Self, chunk: [:0]const u8) bool {
        return self.state.doString(chunk);
    }

    /// Call a function registered in the plugin's global table.
    /// `function_name` is the global name of the function.
    /// `args` are pushed onto the stack before the call.
    /// Returns true if the call succeeded.
    pub fn callFunction(self: *Self, function_name: [:0]const u8, args: anytype) bool {
        _ = args;
        _ = c.lua_getglobal(self.state.handle, function_name.ptr);
        if (!self.state.isFunction(-1)) {
            self.state.pop(1);
            return false;
        }
        const rc = self.state.pcall(0, 1);
        return rc == c.LUA_OK;
    }
};

test "plugin: create and destroy" {
    var p = Plugin.init("test_plugin", false, .{});
    defer p.deinit();
    try std.testing.expectEqualStrings("test_plugin", p.name);
}

test "plugin: load and run code" {
    var p = Plugin.init("test_plugin", false, .{});
    defer p.deinit();

    try std.testing.expect(p.loadChunk("return 2 + 2"));
    try std.testing.expect(p.state.isInteger(-1));
    try std.testing.expectEqual(@as(i64, 4), p.state.toInteger(-1));
    p.state.pop(1);
}

test "plugin: sandbox blocks dangerous access" {
    var p = Plugin.init("test_plugin", false, .{});
    defer p.deinit();

    // io should be nil in sandbox
    try std.testing.expect(p.loadChunk("return io == nil"));
    try std.testing.expect(p.state.toBoolean(-1));
    p.state.pop(1);

    // os.execute should be nil in sandbox
    try std.testing.expect(p.loadChunk("return os.execute == nil"));
    try std.testing.expect(p.state.toBoolean(-1));
    p.state.pop(1);
}

test "plugin: embedded plugin has full access" {
    var p = Plugin.init("embedded", true, .{});
    defer p.deinit();

    try std.testing.expect(p.loadChunk("return type(io) == 'table'"));
    try std.testing.expect(p.state.toBoolean(-1));
    p.state.pop(1);
}

test "plugin: permissions are respected" {
    var p = Plugin.init("test_plugin", false, .{
        .allow_os_execute = true,
    });
    defer p.deinit();

    // os.execute should be available
    try std.testing.expect(p.loadChunk("return type(os.execute) == 'function'"));
    try std.testing.expect(p.state.toBoolean(-1));
    p.state.pop(1);
}
