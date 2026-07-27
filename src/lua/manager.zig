//! Plugin lifecycle manager.
//!
//! Discovers, loads, reloads, and unloads Lua plugins.
//! Plugins are discovered from two directories:
//!   - `~/.config/nova/plugins/` — global plugins
//!   - `.nova/plugins/` — project plugins (override globals with same name)

const std = @import("std");
const c = @import("c");
const State = @import("state.zig").State;
const sandbox = @import("sandbox.zig");
const Manifest = @import("manifest.zig").Manifest;

/// A loaded plugin instance with its manifest and sandboxed Lua state.
pub const PluginInstance = struct {
    manifest: Manifest,
    state: State,
    /// Path to the plugin directory (for reloading)
    dir_path: []const u8,
    /// Whether this plugin is active (not disabled)
    active: bool,
    /// Permissions granted to this plugin
    permissions: sandbox.Permissions,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.manifest.deinit(allocator);
        sandbox.freeHookData(self.state.handle);
        self.state.deinit();
        allocator.free(self.dir_path);
    }
};

/// Manages all loaded plugins: discovery, loading, reloading, state persistence.
pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Global plugin directory (~/.config/nova/plugins/)
    global_dir: []const u8,
    /// Project plugin directory (.nova/plugins/)
    project_dir: []const u8,
    /// Loaded plugins, indexed by name
    plugins: std.StringHashMapUnmanaged(*PluginInstance),
    /// Whether the manager has been initialized
    initialized: bool,

    const Self = @This();

    /// Initialize the plugin manager.
    /// `home_dir` is the user's home directory (for `~/.config/nova/plugins/`).
    /// `cwd` is the current working directory (for `.nova/plugins/`).
    pub fn init(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, cwd: []const u8) Self {
        const global_dir = if (home_dir.len > 0)
            std.fs.path.join(allocator, &.{ home_dir, ".config", "nova", "plugins" }) catch ""
        else
            "";
        const project_dir = if (cwd.len > 0)
            std.fs.path.join(allocator, &.{ cwd, ".nova", "plugins" }) catch ""
        else
            "";
        return Self{
            .allocator = allocator,
            .io = io,
            .global_dir = global_dir,
            .project_dir = project_dir,
            .plugins = .empty,
            .initialized = false,
        };
    }

    /// Deinitialize the manager, unloading all plugins.
    pub fn deinit(self: *Self) void {
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            var plugin = entry.value_ptr.*;
            plugin.deinit(self.allocator);
            self.allocator.destroy(plugin);
        }
        self.plugins.deinit(self.allocator);
        if (self.global_dir.len > 0) self.allocator.free(self.global_dir);
        if (self.project_dir.len > 0) self.allocator.free(self.project_dir);
    }

    /// Discover and load all plugins from both directories.
    /// Project plugins override global plugins with the same name.
    /// Returns the number of plugins loaded, or an error if loading fails.
    pub fn loadAll(self: *Self) !usize {
        if (self.initialized) return self.plugins.count();
        self.initialized = true;

        // Load global plugins first
        try self.loadFromDir(self.global_dir, false);

        // Load project plugins (override globals)
        try self.loadFromDir(self.project_dir, false);

        return self.plugins.count();
    }

    /// Load a single plugin from a directory path.
    /// Returns the loaded plugin instance, or an error.
    pub fn loadOne(self: *Self, dir_path: []const u8, is_embedded: bool) !*PluginInstance {
        // Read and parse the manifest
        var manifest = try self.readManifest(dir_path);
        errdefer manifest.deinit(self.allocator);

        // Check for duplicate
        if (self.plugins.get(manifest.name)) |existing| {
            // Project overrides global — unload the existing one
            if (!existing.manifest.is_embedded) {
                _ = self.plugins.remove(manifest.name);
                existing.deinit(self.allocator);
                self.allocator.destroy(existing);
            } else {
                return error.CannotOverrideEmbeddedPlugin;
            }
        }

        // Determine permissions from manifest
        const permissions = if (is_embedded)
            sandbox.Permissions{ .full_access = true }
        else
            manifest.permissions;

        // Create the plugin instance
        var L = sandbox.createSandboxedState(permissions);

        // Load the plugin's init.lua
        const init_path = try std.fs.path.join(self.allocator, &.{ dir_path, "init.lua" });
        defer self.allocator.free(init_path);

        _ = self.loadLuaFile(&L, init_path);

        const instance = try self.allocator.create(PluginInstance);
        instance.* = .{
            .manifest = manifest,
            .state = L,
            .dir_path = try self.allocator.dupe(u8, dir_path),
            .active = true,
            .permissions = permissions,
        };

        try self.plugins.put(self.allocator, instance.manifest.name, instance);

        return instance;
    }

    /// Reload a plugin by name. Saves state, reloads, restores state.
    pub fn reload(self: *Self, name: []const u8) !void {
        const entry = self.plugins.get(name) orelse return error.PluginNotFound;
        const dir_path = entry.dir_path;
        const is_embedded = entry.manifest.is_embedded;

        // Save state
        var saved_state: ?[]u8 = null;
        if (self.savePluginState(entry)) |state| {
            saved_state = state;
        }

        // Unload
        entry.deinit(self.allocator);
        self.allocator.destroy(entry);
        _ = self.plugins.remove(name);

        // Reload
        const new_instance = try self.loadOne(dir_path, is_embedded);

        // Restore state
        if (saved_state) |state| {
            self.restorePluginState(new_instance, state);
            self.allocator.free(state);
        }
    }

    /// Unload a plugin by name.
    pub fn unload(self: *Self, name: []const u8) void {
        const entry = self.plugins.get(name) orelse return;
        entry.deinit(self.allocator);
        self.allocator.destroy(entry);
        _ = self.plugins.remove(name);
    }

    /// Get a loaded plugin by name.
    pub fn get(self: *Self, name: []const u8) ?*PluginInstance {
        return self.plugins.get(name);
    }

    /// Get the number of loaded plugins.
    pub fn count(self: *Self) usize {
        return self.plugins.count();
    }

    /// Iterate over all loaded plugins.
    pub fn iterator(self: *Self) std.StringHashMapUnmanaged(*PluginInstance).Iterator {
        return self.plugins.iterator();
    }

    // ── private helpers ─────────────────────────────────────────────

    /// Load all plugins from a directory.
    fn loadFromDir(self: *Self, dir_path: []const u8, is_embedded: bool) !void {
        var dir = std.Io.Dir.openDir(.cwd(), self.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            error.NotDir => return,
            else => return err,
        };
        defer dir.close(self.io);

        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (entry.name.len == 0) continue;
            if (entry.name[0] == '.') continue;
            if (entry.kind != .directory) continue;

            const plugin_dir = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            defer self.allocator.free(plugin_dir);

            // Check for plugin.lua manifest
            const manifest_path = try std.fs.path.join(self.allocator, &.{ plugin_dir, "plugin.lua" });
            defer self.allocator.free(manifest_path);

            if (!self.fileExists(manifest_path)) continue;

            _ = self.loadOne(plugin_dir, is_embedded) catch |err| {
                std.log.warn("plugin.load.failed path={s} reason={s}", .{ plugin_dir, @errorName(err) });
                continue;
            };
        }
    }

    /// Read and parse a plugin manifest from a directory.
    fn readManifest(self: *Self, dir_path: []const u8) !Manifest {
        const manifest_path = try std.fs.path.join(self.allocator, &.{ dir_path, "plugin.lua" });
        defer self.allocator.free(manifest_path);

        var L = State.init();
        defer L.deinit();

        if (!self.loadLuaFile(&L, manifest_path)) {
            return error.InvalidManifest;
        }

        return try Manifest.parse(self.allocator, &L);
    }

    /// Load a Lua file and execute it, leaving the result on the stack.
    fn loadLuaFile(self: *Self, L: *State, path: []const u8) bool {
        const content = self.readFileBytes(path) catch return false;
        defer self.allocator.free(content);

        // Ensure null-terminated for Lua C API
        const null_term = self.allocator.alloc(u8, content.len + 1) catch return false;
        defer self.allocator.free(null_term);
        @memcpy(null_term[0..content.len], content);
        null_term[content.len] = 0;

        return L.doString(null_term[0 .. content.len + 1 :0]);
    }

    /// Read a file's contents into an owned slice.
    fn readFileBytes(self: *Self, path: []const u8) ![]u8 {
        var file = try std.Io.Dir.openFileAbsolute(self.io, path, .{});
        defer file.close(self.io);
        var reader = file.reader(self.io, &.{});
        return reader.interface.allocRemaining(self.allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.OutOfMemory, error.StreamTooLong => |e| return e,
        };
    }

    /// Save plugin state by calling get_state() in the plugin.
    fn savePluginState(self: *Self, plugin: *PluginInstance) ?[]u8 {
        _ = c.lua_getglobal(plugin.state.handle, "get_state");
        if (!plugin.state.isFunction(-1)) {
            plugin.state.pop(1);
            return null;
        }
        const rc = plugin.state.pcall(0, 1);
        if (rc != c.LUA_OK) {
            plugin.state.pop(1);
            return null;
        }
        const state_str = plugin.state.toString(-1);
        const result = if (state_str) |s| self.allocator.dupe(u8, s) catch null else null;
        plugin.state.pop(1);
        return result;
    }

    /// Restore plugin state by calling set_state(state) in the plugin.
    fn restorePluginState(self: *Self, plugin: *PluginInstance, state: []const u8) void {
        _ = self;
        _ = c.lua_getglobal(plugin.state.handle, "set_state");
        if (!plugin.state.isFunction(-1)) {
            plugin.state.pop(1);
            return;
        }
        plugin.state.pushString(state);
        _ = plugin.state.pcall(1, 0);
    }

    /// Check if a file exists.
    fn fileExists(self: *PluginManager, path: []const u8) bool {
        var file = std.Io.Dir.openFile(.cwd(), self.io, path, .{}) catch return false;
        file.close(self.io);
        return true;
    }
};

test "plugin manager: init and deinit" {
    var manager = PluginManager.init(std.testing.allocator, std.testing.io, "/tmp", "/tmp");
    defer manager.deinit();
    try std.testing.expect(!manager.initialized);
}

test "plugin manager: loadAll with no plugins" {
    var manager = PluginManager.init(std.testing.allocator, std.testing.io, "/nonexistent", "/nonexistent");
    defer manager.deinit();
    const count = try manager.loadAll();
    try std.testing.expectEqual(@as(usize, 0), count);
}
