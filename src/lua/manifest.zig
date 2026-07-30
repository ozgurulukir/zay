//! Plugin manifest parsing and validation.
//!
//! A plugin manifest is a `plugin.lua` file at the root of a plugin directory.
//! It returns a Lua table with metadata about the plugin, including
//! permissions and resource limits.

const std = @import("std");
const c = @import("c");
const State = @import("state.zig").State;
const bridge = @import("bridge.zig");
const sandbox = @import("sandbox.zig");

/// Parsed plugin manifest.
pub const Manifest = struct {
    /// Plugin name (unique identifier, e.g. "syntax_highlighter")
    name: []const u8,
    /// Semantic version string (e.g. "1.2.0")
    version: []const u8,
    /// Author name or handle
    author: []const u8 = "",
    /// License identifier (e.g. "MIT", "Apache-2.0")
    license: []const u8 = "",
    /// Human-readable description
    description: []const u8 = "",
    /// Plugin dependencies (e.g. "lpeg >= 1.0")
    dependencies: []const []const u8 = &.{},
    /// Whether this is an embedded plugin (shipped with Nova)
    is_embedded: bool = false,
    /// Permissions requested by the plugin
    permissions: sandbox.Permissions = .{},

    const Self = @This();

    /// Parse a manifest from a Lua file loaded in the given state.
    /// The manifest table must be on top of the stack.
    /// Caller owns the returned strings (allocated with `allocator`).
    pub fn parse(allocator: std.mem.Allocator, L: *State) !Manifest {
        if (!L.isTable(-1)) return error.InvalidManifest;

        const name = bridge.getTableString(L, -1, "name") orelse return error.MissingPluginName;
        const version = bridge.getTableString(L, -1, "version") orelse return error.MissingPluginVersion;

        // Parse permissions sub-table
        const permissions = parsePermissions(L) catch sandbox.Permissions{};

        return Manifest{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, version),
            .author = if (bridge.getTableString(L, -1, "author")) |s| try allocator.dupe(u8, s) else "",
            .license = if (bridge.getTableString(L, -1, "license")) |s| try allocator.dupe(u8, s) else "",
            .description = if (bridge.getTableString(L, -1, "description")) |s| try allocator.dupe(u8, s) else "",
            .dependencies = &.{},
            .is_embedded = false,
            .permissions = permissions,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        if (self.author.len > 0) allocator.free(self.author);
        if (self.license.len > 0) allocator.free(self.license);
        if (self.description.len > 0) allocator.free(self.description);
    }
};

/// Parse the permissions sub-table from the manifest table on the stack.
/// The manifest table must be at the top of the stack.
fn parsePermissions(L: *State) !sandbox.Permissions {
    const t = c.lua_getfield(L.handle, -1, "permissions");
    defer L.pop(1);

    if (t != c.LUA_TTABLE) return sandbox.Permissions{};

    var perms = sandbox.Permissions{};

    if (bridge.getTableBoolean(L, -1, "file_access")) |v| perms.file_access = v;
    if (bridge.getTableBoolean(L, -1, "network_access")) |v| perms.network_access = v;
    if (bridge.getTableBoolean(L, -1, "require_others")) |v| perms.require_others = v;
    if (bridge.getTableBoolean(L, -1, "allow_rawget_rawset")) |v| perms.allow_rawget_rawset = v;
    if (bridge.getTableBoolean(L, -1, "allow_os_execute")) |v| perms.allow_os_execute = v;
    if (bridge.getTableBoolean(L, -1, "allow_os_exit")) |v| perms.allow_os_exit = v;
    if (bridge.getTableBoolean(L, -1, "allow_os_remove")) |v| perms.allow_os_remove = v;

    if (bridge.getTableInteger(L, -1, "instruction_limit")) |v| perms.instruction_limit = @intCast(v);
    if (bridge.getTableInteger(L, -1, "memory_limit_mb")) |v| perms.memory_limit_mb = @intCast(v);
    if (bridge.getTableInteger(L, -1, "timeout_ms")) |v| perms.timeout_ms = @intCast(v);

    return perms;
}

test "manifest: parse valid table" {
    const testing = std.testing;
    var L = try State.init();
    defer L.deinit();

    try testing.expect(L.doString(
        \\return { name = "test_plugin", version = "1.0.0", author = "dev" }
    ));

    var manifest = try Manifest.parse(testing.allocator, &L);
    defer manifest.deinit(testing.allocator);

    try testing.expectEqualStrings("test_plugin", manifest.name);
    try testing.expectEqualStrings("1.0.0", manifest.version);
    try testing.expectEqualStrings("dev", manifest.author);
}

test "manifest: missing name returns error" {
    var L = try State.init();
    defer L.deinit();

    try std.testing.expect(L.doString("return { version = '1.0.0' }"));
    try std.testing.expectError(error.MissingPluginName, Manifest.parse(std.testing.allocator, &L));
}

test "manifest: missing version returns error" {
    var L = try State.init();
    defer L.deinit();

    try std.testing.expect(L.doString("return { name = 'test' }"));
    try std.testing.expectError(error.MissingPluginVersion, Manifest.parse(std.testing.allocator, &L));
}

test "manifest: parse permissions" {
    const testing = std.testing;
    var L = try State.init();
    defer L.deinit();

    try testing.expect(L.doString(
        \\return {
        \\  name = "test_plugin",
        \\  version = "1.0.0",
        \\  permissions = {
        \\    file_access = true,
        \\    network_access = true,
        \\    allow_os_execute = true,
        \\    instruction_limit = 50000,
        \\    memory_limit_mb = 32,
        \\  }
        \\}
    ));

    var manifest = try Manifest.parse(testing.allocator, &L);
    defer manifest.deinit(testing.allocator);

    try testing.expect(manifest.permissions.file_access);
    try testing.expect(manifest.permissions.network_access);
    try testing.expect(manifest.permissions.allow_os_execute);
    try testing.expectEqual(@as(u32, 50000), manifest.permissions.instruction_limit);
    try testing.expectEqual(@as(u32, 32), manifest.permissions.memory_limit_mb);
    try testing.expect(!manifest.permissions.allow_rawget_rawset);
}

test "manifest: default permissions when not specified" {
    const testing = std.testing;
    var L = try State.init();
    defer L.deinit();

    try testing.expect(L.doString(
        \\return { name = "test", version = "1.0.0" }
    ));

    var manifest = try Manifest.parse(testing.allocator, &L);
    defer manifest.deinit(testing.allocator);

    try testing.expect(!manifest.permissions.file_access);
    try testing.expect(!manifest.permissions.network_access);
    try testing.expect(manifest.permissions.require_others);
}
