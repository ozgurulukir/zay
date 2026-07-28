//! Lua plugin SDK module root.
//!
//! Re-exports all public types and functions for the Lua plugin system.

const std = @import("std");

pub const State = @import("state.zig").State;
pub const bridge = @import("bridge.zig");
pub const sandbox = @import("sandbox.zig");
pub const plugin = @import("plugin.zig");
pub const Manifest = @import("manifest.zig").Manifest;
pub const PluginManager = @import("manager.zig").PluginManager;
pub const PluginInstance = @import("manager.zig").PluginInstance;
pub const Event = @import("events.zig").Event;
pub const plugin_api = @import("plugin_api.zig");
pub const registry_bridge = @import("registry_bridge.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(State);
    std.testing.refAllDecls(bridge);
    std.testing.refAllDecls(sandbox);
    std.testing.refAllDecls(plugin);
    std.testing.refAllDecls(Manifest);
    std.testing.refAllDecls(PluginManager);
    std.testing.refAllDecls(PluginInstance);
    std.testing.refAllDecls(Event);
}
