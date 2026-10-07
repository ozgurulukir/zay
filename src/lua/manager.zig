//! Plugin lifecycle manager.
//!
//! Discovers, loads, reloads, and unloads Lua plugins.
//! Plugins are discovered from two directories:
//!   - `~/.config/zay/plugins/` — global plugins
//!   - `plugins/` — project plugins (override globals with same name)
//! The former `.zay/plugins/` root remains a legacy fallback so existing
//! projects migrate without losing their installed plugins.

const std = @import("std");
const log = std.log.scoped(.lua);
const c = @import("c");
const paths = @import("../paths.zig");
const State = @import("state.zig").State;
const sandbox = @import("sandbox.zig");
const plugin_api = @import("plugin_api.zig");
const events = @import("events.zig");
const execution = @import("execution.zig");
const bridge = @import("bridge.zig");
const tool_snapshot = @import("tool_snapshot.zig");
const Manifest = @import("manifest.zig").Manifest;
const plugin_config = @import("../config/plugin.zig");

/// True when `plugin_dir` is the same as `project_dir` or a subdirectory
/// of it (separator-boundary checked — never a bare `startsWith`).
/// Treats `/` and `\` as equivalent separators for cross-platform safety.
/// Assumes `project_dir` carries no trailing separator (holds for every
/// producer: `std.fs.path.join` and `currentPathAlloc` never leave one) —
/// with a trailing separator the boundary check below would reject true
/// subdirectories.
fn pluginDirUnderProjectDir(plugin_dir: []const u8, project_dir: []const u8) bool {
    if (project_dir.len == 0) return false;
    if (plugin_dir.len < project_dir.len) return false;

    // Compare prefix, treating / and \ as equivalent separators.
    var i: usize = 0;
    while (i < project_dir.len) {
        const pc = project_dir[i];
        const dc = plugin_dir[i];
        const is_sep_p = (pc == '/' or pc == '\\');
        const is_sep_d = (dc == '/' or dc == '\\');
        if (is_sep_p and is_sep_d) {
            i += 1;
            continue;
        }
        if (pc != dc) return false;
        i += 1;
    }

    // Prefix matches. Check separator boundary or exact match.
    if (plugin_dir.len == i) return true;
    const next = plugin_dir[i];
    return next == '/' or next == '\\';
}

/// A loaded plugin instance with its manifest and sandboxed Lua state.
pub const PluginInstance = struct {
    manifest: Manifest,
    state: State,
    execution_mutex: std.Io.Mutex = .init,
    event_subscriptions: events.Subscriptions = .init(0),
    /// Immutable owned metadata; consumers never inspect the live Lua stack.
    tool_snapshots: []tool_snapshot.ToolSnapshot,
    /// Path to the plugin directory (for reloading)
    dir_path: []const u8,
    /// Whether this plugin is active (not disabled)
    active: bool,
    /// Permissions granted to this plugin
    permissions: sandbox.Permissions,

    const Self = @This();

    /// The guard lives outside pcall, so Lua longjmp cannot skip its unlock.
    fn lockExecution(self: *Self, io: std.Io, wait_ms: u32) !void {
        const deadline = std.Io.Timestamp.now(io, .awake).nanoseconds + @as(i96, wait_ms) * std.time.ns_per_ms;
        while (true) {
            try io.checkCancel();
            if (bridge.cancel_requested_slot) |flag| if (flag.load(.acquire)) return error.Canceled;
            if (self.execution_mutex.tryLock()) {
                io.checkCancel() catch |err| {
                    self.execution_mutex.unlock(io);
                    return err;
                };
                if (bridge.cancel_requested_slot) |flag| {
                    if (flag.load(.acquire)) {
                        self.execution_mutex.unlock(io);
                        return error.Canceled;
                    }
                }
                return;
            }
            const remaining = deadline - std.Io.Timestamp.now(io, .awake).nanoseconds;
            if (remaining <= 0) return error.PluginBusy;
            try io.sleep(.fromNanoseconds(@intCast(@min(remaining, 10 * std.time.ns_per_ms))), .awake);
        }
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        tool_snapshot.deinit(allocator, self.tool_snapshots);
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
    /// Global plugin directory (~/.config/zay/plugins/)
    global_dir: []const u8,
    /// Project plugin directory (plugins/)
    project_dir: []const u8,
    /// Legacy project plugin directory (.zay/plugins/), loaded before the
    /// visible project root so the new location wins on duplicate names.
    legacy_project_dir: []const u8,
    /// Loaded plugins, indexed by name
    plugins: std.StringHashMapUnmanaged(*PluginInstance),
    /// Recoverable discovery errors keyed by physical plugin directory.
    /// Values use static error names so only map keys are owned.
    load_failures: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Whether the manager has been initialized
    initialized: bool,
    /// Cloned per-plugin config entries (enabled/settings), synced from the
    /// App config before `loadAll`. Clones, not borrows: the manager outlives
    /// mid-session `Config` swaps (a session switch frees the old config while
    /// the manager lives on), so borrowed slices would dangle.
    plugin_configs: std.ArrayListUnmanaged(plugin_config.PluginConfig) = .empty,
    /// Low bits count live turns/dispatches; high bit exclusively owns map
    /// mutation. App copies happen before workers are wired, never while used.
    lifecycle: std.atomic.Value(u32) = .init(0),
    /// Host policy, independent of Lua's per-dispatch execution budget.
    execution_policy: ExecutionPolicy = .{},

    pub const ExecutionPolicy = struct {
        tool_wait_ms: u32 = 1000,
        /// Total time for one emission, including lock waits and callbacks.
        event_budget_ms: u32 = 1000,
    };

    const mutation_bit: u32 = 1 << 31;

    /// Pin the plugin generation for a turn, dispatch, or metadata copy.
    pub fn beginUse(self: *Self) !void {
        var state = self.lifecycle.load(.acquire);
        while (true) {
            if (state & mutation_bit != 0) return error.InFlightTurn;
            if (state == mutation_bit - 1) return error.TooManyPluginUsers;
            state = self.lifecycle.cmpxchgWeak(state, state + 1, .acq_rel, .acquire) orelse return;
        }
    }

    pub fn endUse(self: *Self) void {
        const previous = self.lifecycle.fetchSub(1, .release);
        std.debug.assert(previous > 0);
        std.debug.assert(previous & mutation_bit == 0);
    }

    fn beginMutation(self: *Self) !void {
        if (self.lifecycle.cmpxchgStrong(0, mutation_bit, .acq_rel, .acquire) != null)
            return error.InFlightTurn;
    }

    fn endMutation(self: *Self) void {
        std.debug.assert(self.lifecycle.load(.monotonic) == mutation_bit);
        self.lifecycle.store(0, .release);
    }

    const Self = @This();

    /// Initialize the plugin manager.
    /// `home_dir` is the user's home directory (for `~/.config/zay/plugins/`).
    /// `cwd` is the current working directory (for `plugins/`).
    pub fn init(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, cwd: []const u8) Self {
        const global_dir: []const u8 = if (home_dir.len > 0)
            paths.globalPluginsDir(allocator, io, home_dir) catch ""
        else
            "";
        const project_dir = if (cwd.len > 0)
            std.fs.path.join(allocator, &.{ cwd, "plugins" }) catch ""
        else
            "";
        const legacy_project_dir = if (cwd.len > 0)
            std.fs.path.join(allocator, &.{ cwd, ".zay", "plugins" }) catch ""
        else
            "";
        return Self{
            .allocator = allocator,
            .io = io,
            .global_dir = global_dir,
            .project_dir = project_dir,
            .legacy_project_dir = legacy_project_dir,
            .plugins = .empty,
            .initialized = false,
        };
    }

    /// Deinitialize the manager, unloading all plugins.
    pub fn deinit(self: *Self) void {
        // The owner must cancel and join every worker before teardown.
        std.debug.assert(self.lifecycle.load(.acquire) == 0);
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            var plugin = entry.value_ptr.*;
            plugin.deinit(self.allocator);
            self.allocator.destroy(plugin);
        }
        self.plugins.deinit(self.allocator);
        var failures = self.load_failures.iterator();
        while (failures.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.load_failures.deinit(self.allocator);
        for (self.plugin_configs.items) |*pc| pc.deinit(self.allocator);
        self.plugin_configs.deinit(self.allocator);
        if (self.global_dir.len > 0) self.allocator.free(self.global_dir);
        if (self.project_dir.len > 0) self.allocator.free(self.project_dir);
        if (self.legacy_project_dir.len > 0) self.allocator.free(self.legacy_project_dir);
    }

    fn recordLoadFailure(self: *Self, path: []const u8, err: anyerror) !void {
        const reason = @errorName(err);
        if (self.load_failures.getPtr(path)) |existing| {
            existing.* = reason;
            return;
        }
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.load_failures.put(self.allocator, owned_path, reason);
    }

    fn clearLoadFailure(self: *Self, path: []const u8) void {
        if (self.load_failures.fetchRemove(path)) |removed| self.allocator.free(removed.key);
    }

    fn clearLoadFailuresUnder(self: *Self, root: []const u8) void {
        var failures = self.load_failures.iterator();
        while (failures.next()) |entry| {
            const path = entry.key_ptr.*;
            if (!pluginDirUnderProjectDir(path, root)) continue;
            // Removal does not resize the map, so iteration stays valid.
            const removed = self.load_failures.fetchRemove(path).?;
            self.allocator.free(removed.key);
        }
    }

    /// Clone the per-plugin config entries (enabled/settings) into the manager.
    /// Expected before `loadAll`; safe to call again later (replaces the
    /// previous set). Clones rather than borrows: the caller's `Config` may be
    /// freed mid-session (session switch) while the manager lives on.
    pub fn syncPluginConfig(self: *Self, plugins: []const plugin_config.PluginConfig) !void {
        try self.beginMutation();
        defer self.endMutation();
        var next: std.ArrayListUnmanaged(plugin_config.PluginConfig) = .empty;
        errdefer {
            for (next.items) |*pc| pc.deinit(self.allocator);
            next.deinit(self.allocator);
        }
        for (plugins) |pc| {
            var cloned = try pc.clone(self.allocator);
            next.append(self.allocator, cloned) catch |err| {
                cloned.deinit(self.allocator);
                return err;
            };
        }
        // Build-then-swap: an error above leaves the previous set intact.
        for (self.plugin_configs.items) |*pc| pc.deinit(self.allocator);
        self.plugin_configs.deinit(self.allocator);
        self.plugin_configs = next;
    }

    /// The config entry for `name`, or null when the plugin is unconfigured
    /// (unconfigured means default-enabled with no settings).
    fn configFor(self: *const Self, name: []const u8) ?*const plugin_config.PluginConfig {
        for (self.plugin_configs.items) |*pc| {
            if (std.mem.eql(u8, pc.name, name)) return pc;
        }
        return null;
    }

    /// Discover and load all plugins from both directories.
    /// Project plugins override global plugins with the same name.
    /// Returns the number of plugins loaded, or an error if loading fails.
    ///
    /// `syncPluginConfig` is expected to have run first: `enabled` and
    /// settings are read once at load time and are never re-evaluated on a
    /// mid-session config reload — restart the App to apply config changes.
    pub fn loadAll(self: *Self) !usize {
        try self.beginMutation();
        defer self.endMutation();
        if (self.initialized) return self.plugins.count();
        self.initialized = true;

        log.debug("plugin.loadAll.start global_dir={s} project_dir={s}", .{ self.global_dir, self.project_dir });

        // Load global plugins first
        try self.loadFromDir(self.global_dir, false);

        // Load the legacy root first so the visible project root is the
        // authoritative override during the migration window.
        try self.loadFromDir(self.legacy_project_dir, false);

        // Load project plugins (override globals and legacy project plugins)
        try self.loadFromDir(self.project_dir, false);

        const loaded = self.plugins.count();
        log.debug("plugin.loadAll.done loaded={}", .{loaded});
        return loaded;
    }

    /// Load a single plugin from a directory path.
    /// Returns the loaded plugin instance, or an error.
    pub fn loadOne(self: *Self, dir_path: []const u8, is_embedded: bool) !*PluginInstance {
        try self.beginMutation();
        defer self.endMutation();
        return self.loadOneDuringMutation(dir_path, is_embedded);
    }

    fn loadOneDuringMutation(self: *Self, dir_path: []const u8, is_embedded: bool) !*PluginInstance {
        // Read and parse the manifest
        var manifest = try self.readManifest(dir_path);
        errdefer manifest.deinit(self.allocator);

        // Disabled plugins never load. Bails BEFORE the duplicate/override
        // teardown below so a disabled project copy cannot unload the active
        // global instance. NOTE: `error.PluginDisabled` also means call-time
        // refusal on an inactive plugin (`callTool`) — same name, two
        // lifecycle stages; the errdefer above frees the manifest here.
        if (self.configFor(manifest.name)) |pc| {
            if (!pc.enabled) {
                log.info("plugin.disabled name={s} path={s}", .{ manifest.name, dir_path });
                return error.PluginDisabled;
            }
        }

        const previous = self.plugins.get(manifest.name);
        if (previous) |existing| if (existing.manifest.is_embedded) return error.CannotOverrideEmbeddedPlugin;

        // Determine permissions from manifest
        const permissions = if (is_embedded)
            sandbox.Permissions{ .full_access = true }
        else
            manifest.permissions;

        // Create the plugin instance with Io so zay.* bridge functions
        // (register_tool, read_file, etc.) are available in the sandbox.
        var L = try sandbox.createSandboxedStateWithIo(permissions, self.io);
        errdefer {
            sandbox.freeHookData(L.handle);
            L.deinit();
        }

        // Store the plugin root directory in the registry so zay.require knows its base path
        _ = c.lua_pushlstring(L.handle, dir_path.ptr, dir_path.len);
        c.lua_setfield(L.handle, c.LUA_REGISTRYINDEX, "zay_plugin_dir");

        // Store the plugin's settings JSON (if any) before init.lua runs so
        // load-time code can already call plugin.get_config(). lua_pushlstring
        // copies into the Lua GC — the manager keeps no ownership of the copy.
        if (self.configFor(manifest.name)) |pc| {
            if (pc.settings.len > 0) {
                _ = c.lua_pushlstring(L.handle, pc.settings.ptr, pc.settings.len);
                _ = c.lua_setfield(L.handle, c.LUA_REGISTRYINDEX, sandbox.settings_registry_key);
            }
        }

        // Load the plugin's init.lua
        const init_path = try std.fs.path.join(self.allocator, &.{ dir_path, "init.lua" });
        defer self.allocator.free(init_path);

        const loaded = self.loadLuaFile(&L, init_path);
        log.debug("plugin.loadOne.init path={s} loaded={}", .{ init_path, loaded });
        if (!loaded) {
            log.warn("plugin.loadOne.init_failed path={s}", .{init_path});
            return error.PluginInitFailed;
        }

        const snapshots = try tool_snapshot.capture(self.allocator, L.handle);
        errdefer tool_snapshot.deinit(self.allocator, snapshots);
        const instance = try self.allocator.create(PluginInstance);
        errdefer self.allocator.destroy(instance);
        const owned_dir = try self.allocator.dupe(u8, dir_path);
        errdefer self.allocator.free(owned_dir);
        // Reserve before replacing: failures leave the old Lua state and map
        // key intact. A map replacement must replace its borrowed key too.
        try self.plugins.ensureUnusedCapacity(self.allocator, 1);
        instance.* = .{
            .manifest = manifest,
            .state = L,
            .tool_snapshots = snapshots,
            .dir_path = owned_dir,
            .active = true,
            .permissions = permissions,
        };

        if (previous) |existing| {
            _ = self.plugins.remove(existing.manifest.name);
            existing.deinit(self.allocator);
            self.allocator.destroy(existing);
        }
        events.bindSubscriptions(instance.state.handle, &instance.event_subscriptions);
        self.plugins.putAssumeCapacity(instance.manifest.name, instance);

        return instance;
    }

    /// Reload a plugin by name. Saves state, reloads, restores state.
    pub fn reload(self: *Self, name: []const u8) !void {
        try self.beginMutation();
        defer self.endMutation();
        const entry = self.plugins.get(name) orelse return error.PluginNotFound;
        const dir_path = try self.allocator.dupe(u8, entry.dir_path);
        defer self.allocator.free(dir_path);
        const is_embedded = entry.manifest.is_embedded;
        const saved_state = self.savePluginState(entry);
        defer if (saved_state) |state| self.allocator.free(state);
        // Build-before-swap retains the previous plugin on any load failure.
        const new_instance = try self.loadOneDuringMutation(dir_path, is_embedded);
        if (saved_state) |state| self.restorePluginState(new_instance, state);
    }

    /// Unload a plugin by name.
    pub fn unload(self: *Self, name: []const u8) !void {
        try self.beginMutation();
        defer self.endMutation();
        const entry = self.plugins.get(name) orelse return;
        _ = self.plugins.remove(name);
        entry.deinit(self.allocator);
        self.allocator.destroy(entry);
    }

    /// Get a loaded plugin by name.
    pub fn get(self: *Self, name: []const u8) ?*PluginInstance {
        return self.plugins.get(name);
    }

    /// Dispatch a tool call to a loaded plugin by name.
    /// `params_json` is forwarded to the Lua handler as a JSON string.
    /// Returns the handler's owned text and status.
    pub fn callTool(
        self: *Self,
        plugin_name: []const u8,
        tool_name: []const u8,
        params_json: []const u8,
    ) !plugin_api.ToolHandlerResult {
        try self.beginUse();
        defer self.endUse();
        const plugin = self.plugins.get(plugin_name) orelse return error.PluginNotFound;
        if (!plugin.active) return error.PluginDisabled;
        try plugin.lockExecution(self.io, self.execution_policy.tool_wait_ms);
        defer plugin.execution_mutex.unlock(self.io);
        const top = c.lua_gettop(plugin.state.handle);
        defer c.lua_settop(plugin.state.handle, top);
        for (plugin.tool_snapshots) |snapshot| {
            if (std.mem.eql(u8, snapshot.name, tool_name)) {
                var result = try plugin_api.callToolHandler(plugin.state.handle, self.allocator, snapshot.index, params_json);
                if (execution.budget(plugin.state.handle)) |data| {
                    if (data.stop_reason == .canceled) {
                        result.deinit(self.allocator);
                        return error.Canceled;
                    }
                }
                if (bridge.cancel_requested_slot) |flag| {
                    if (flag.load(.acquire)) {
                        result.deinit(self.allocator);
                        return error.Canceled;
                    }
                }
                return result;
            }
        }
        return error.ToolNotFound;
    }

    /// Get the number of loaded plugins.
    pub fn count(self: *Self) usize {
        return self.plugins.count();
    }

    /// Iterate over all loaded plugins.
    pub fn iterator(self: *Self) std.StringHashMapUnmanaged(*PluginInstance).Iterator {
        return self.plugins.iterator();
    }

    /// Emit a lifecycle event to every active plugin. Each plugin's sandboxed
    /// Lua state holds a `"zay_events"` registry table (populated by
    /// `zay.on`); this drains the sub-table for `event.name()`, pcalling
    /// every stored callback ref with the event payload as a Lua table.
    ///
    /// Errors in individual callbacks are logged and do not stop delivery to
    /// other plugins. Called at tool boundaries on the emitting worker; each
    /// state is exclusively held, even when another lane is in a handler.
    pub fn emitEvent(self: *Self, event: events.Event) void {
        self.beginUse() catch return;
        defer self.endUse();
        const event_name = event.name();
        const deadline = std.Io.Timestamp.now(self.io, .awake).nanoseconds + @as(i96, self.execution_policy.event_budget_ms) * std.time.ns_per_ms;
        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            const plugin = entry.value_ptr.*;
            if (!plugin.active or !events.subscribed(&plugin.event_subscriptions, event)) continue;
            const remaining = @max(0, deadline - std.Io.Timestamp.now(self.io, .awake).nanoseconds);
            const remaining_ms: u32 = @intCast(@divFloor(remaining, std.time.ns_per_ms));
            plugin.lockExecution(self.io, remaining_ms) catch |err| {
                if (err == error.Canceled) return;
                log.warn("plugin.event.skipped plugin={s} event={s} err={s}", .{ plugin.manifest.name, event_name, @errorName(err) });
                continue;
            };
            defer plugin.execution_mutex.unlock(self.io);
            const top = c.lua_gettop(plugin.state.handle);
            defer c.lua_settop(plugin.state.handle, top);
            sandbox.resetInstructionBudget(plugin.state.handle);
            const execution_remaining = @max(0, deadline - std.Io.Timestamp.now(self.io, .awake).nanoseconds);
            execution.capDeadline(plugin.state.handle, @intCast(@divFloor(execution_remaining, std.time.ns_per_ms)));
            drainEventCallbacks(plugin.state.handle, plugin.manifest.name, event_name, event);
        }
    }

    /// Repoint project-scoped discovery from the old project to `new_cwd`:
    /// unload plugins loaded from either project root, free + replace both
    /// project paths, and load the legacy root before the visible root.
    /// Global plugins are untouched
    /// (states, event subscriptions, require caches survive). Caller owns the
    /// all-lanes-idle guarantee — unloading frees Lua states mid-dispatch
    /// would be fatal.
    pub fn repointProjectDir(self: *Self, new_cwd: []const u8) !void {
        try self.beginMutation();
        defer self.endMutation();
        // Step 1: snapshot both old roots and compute both new roots — all
        // BEFORE any mutation, so an allocation failure leaves the manager
        // intact.
        const old_project_dir = if (self.project_dir.len > 0)
            try self.allocator.dupe(u8, self.project_dir)
        else
            "";
        // Snapshot must outlive the unload pass below; freed via errdefer on
        // error and explicitly at the end of the happy path.
        errdefer if (old_project_dir.len > 0) self.allocator.free(old_project_dir);

        const old_legacy_project_dir = if (self.legacy_project_dir.len > 0)
            try self.allocator.dupe(u8, self.legacy_project_dir)
        else
            "";
        errdefer if (old_legacy_project_dir.len > 0) self.allocator.free(old_legacy_project_dir);

        // `try`, not `catch ""`: an OOM here must fail the repoint, not
        // silently empty discovery after old plugins were unloaded.
        var new_project_dir: []u8 = if (new_cwd.len > 0)
            try std.fs.path.join(self.allocator, &.{ new_cwd, "plugins" })
        else
            "";
        // Ownership transfers to self.project_dir at step 4; the assignment
        // of "" below disarms the errdefer.
        errdefer if (new_project_dir.len > 0) self.allocator.free(new_project_dir);

        var new_legacy_project_dir: []u8 = if (new_cwd.len > 0)
            try std.fs.path.join(self.allocator, &.{ new_cwd, ".zay", "plugins" })
        else
            "";
        errdefer if (new_legacy_project_dir.len > 0) self.allocator.free(new_legacy_project_dir);

        // Step 2: unload every plugin whose dir_path is under either old
        // project root. Two-pass: collect survivors and unload victims FIRST
        // (both fallible), swap the map, and only then destroy the victims.
        // Destroying during iteration would leave self.plugins referencing
        // freed instances if a later `put`/`append` failed with OOM.
        if (old_project_dir.len > 0 or old_legacy_project_dir.len > 0) {
            var surviving: std.StringHashMapUnmanaged(*PluginInstance) = .empty;
            // On error the original map still owns every instance; only the
            // scratch buckets are freed.
            errdefer surviving.deinit(self.allocator);
            var unloaded: std.ArrayList(*PluginInstance) = .empty;
            errdefer unloaded.deinit(self.allocator);

            var it = self.plugins.iterator();
            while (it.next()) |entry| {
                if (pluginDirUnderProjectDir(entry.value_ptr.*.dir_path, old_project_dir) or
                    pluginDirUnderProjectDir(entry.value_ptr.*.dir_path, old_legacy_project_dir))
                {
                    try unloaded.append(self.allocator, entry.value_ptr.*);
                } else {
                    try surviving.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
                }
            }

            // Swap first — from here on nothing fallible touches the maps,
            // so self.plugins never references a destroyed instance.
            self.plugins.deinit(self.allocator);
            self.plugins = surviving;

            for (unloaded.items) |instance| {
                instance.deinit(self.allocator);
                self.allocator.destroy(instance);
            }
            unloaded.deinit(self.allocator);
        }

        // Step 3: re-scan global_dir for globals that were shadowed by
        // the unloaded project plugins. Only load names absent from the
        // current plugin set — new-project same-name copies still win via
        // the duplicate path in step 5.
        if (self.global_dir.len > 0) {
            var dir = std.Io.Dir.openDir(.cwd(), self.io, self.global_dir, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => null,
                else => return err,
            };
            if (dir) |*d| {
                defer d.close(self.io);
                var iter = d.iterate();
                while (try iter.next(self.io)) |entry| {
                    if (entry.name.len == 0 or entry.name[0] == '.') continue;
                    if (entry.kind != .directory and entry.kind != .sym_link) continue;
                    if (self.plugins.contains(entry.name)) continue;

                    const plugin_dir = try std.fs.path.join(self.allocator, &.{ self.global_dir, entry.name });
                    defer self.allocator.free(plugin_dir);
                    self.clearLoadFailure(plugin_dir);

                    const manifest_path = try std.fs.path.join(self.allocator, &.{ plugin_dir, "plugin.lua" });
                    defer self.allocator.free(manifest_path);

                    if (!self.fileExists(manifest_path)) continue;

                    _ = self.loadOneDuringMutation(plugin_dir, false) catch |err| switch (err) {
                        error.PluginDisabled => continue,
                        else => {
                            try self.recordLoadFailure(plugin_dir, err);
                            log.warn("plugin.repoint.global_restore_failed name={s} reason={s}", .{ entry.name, @errorName(err) });
                            continue;
                        },
                    };
                }
            }
        }

        // Step 4: free old project roots, store both new roots. Transferring
        // ownership disarms the corresponding errdefers.
        self.clearLoadFailuresUnder(old_project_dir);
        self.clearLoadFailuresUnder(old_legacy_project_dir);
        if (self.project_dir.len > 0) self.allocator.free(self.project_dir);
        self.project_dir = new_project_dir;
        new_project_dir = "";
        if (self.legacy_project_dir.len > 0) self.allocator.free(self.legacy_project_dir);
        self.legacy_project_dir = new_legacy_project_dir;
        new_legacy_project_dir = "";

        // Step 5: load the legacy root, then the visible root. Missing dirs →
        // warn + no-op. Non-FileNotFound failures are soft-degraded —
        // aborting the switch would leave a half-swapped manager.
        if (self.legacy_project_dir.len > 0) {
            self.loadFromDir(self.legacy_project_dir, false) catch |err| {
                log.warn("plugin.repoint.load_legacy_dir_failed dir={s} reason={s}", .{ self.legacy_project_dir, @errorName(err) });
            };
        }

        // Load from new project dir. Missing dir → warn + no-op
        // (existing loadFromDir behavior). Non-FileNotFound failures are
        // soft-degraded — aborting the switch would leave a half-swapped
        // manager.
        if (self.project_dir.len > 0) {
            self.loadFromDir(self.project_dir, false) catch |err| {
                log.warn("plugin.repoint.load_new_dir_failed dir={s} reason={s}", .{ self.project_dir, @errorName(err) });
            };
        }

        // Free the snapshot from step 1.
        if (old_project_dir.len > 0) self.allocator.free(old_project_dir);
        if (old_legacy_project_dir.len > 0) self.allocator.free(old_legacy_project_dir);
    }

    // ── private helpers ─────────────────────────────────────────────

    /// Read the `"zay_events"` registry table on `L`, find the sub-table for
    /// `event_name`, and pcall every stored callback ref with `event`'s payload
    /// pushed as a Lua table. Each callback error is logged with `plugin_name`
    /// but does not stop the remaining callbacks. Stack-neutral.
    fn drainEventCallbacks(L: *c.lua_State, plugin_name: []const u8, event_name: []const u8, event: events.Event) void {
        _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "zay_events");
        if (c.lua_isnil(L, -1)) {
            c.lua_pop(L, 1);
            return;
        }
        defer c.lua_pop(L, 1); // pop zay_events table

        _ = c.lua_getfield(L, -1, event_name.ptr);
        if (c.lua_isnil(L, -1)) {
            c.lua_pop(L, 1);
            return;
        }
        defer c.lua_pop(L, 1); // pop event sub-table

        const subs_len = c.lua_rawlen(L, -1);
        var i: c_int = 1;
        var state = State{ .handle = L };
        while (i <= @as(c_int, @intCast(subs_len))) : (i += 1) {
            _ = c.lua_rawgeti(L, -1, i); // push callback ref (integer)
            const func_ref = state.toInteger(-1);
            state.pop(1); // pop the integer ref

            // Resolve the ref to the actual function.
            _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, @as(c_int, @intCast(func_ref)));
            if (!c.lua_isfunction(L, -1)) {
                c.lua_pop(L, 1);
                continue;
            }

            // Push the event payload as a Lua table argument.
            state.newTable();
            events.pushEventData(&state, event);

            const rc = state.pcall(1, 0);
            if (rc != c.LUA_OK) {
                const err = state.getErrorMessage();
                log.warn("plugin.event.error plugin={s} event={s} err={s}", .{
                    plugin_name, event_name, err orelse "unknown",
                });
                state.pop(1); // pop error message
                if (execution.stopped(L)) break;
            }
        }
    }

    /// Load all plugins from a directory.
    fn loadFromDir(self: *Self, dir_path: []const u8, is_embedded: bool) !void {
        log.debug("plugin.loadFromDir.start dir={s} is_embedded={}", .{ dir_path, is_embedded });
        // Each scan replaces its diagnostic snapshot, including deleted
        // packages and roots that no longer exist.
        self.clearLoadFailuresUnder(dir_path);
        var dir = std.Io.Dir.openDir(.cwd(), self.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                log.warn("plugin.loadFromDir.not_found dir={s}", .{dir_path});
                return;
            },
            error.NotDir => {
                log.warn("plugin.loadFromDir.not_dir dir={s}", .{dir_path});
                return;
            },
            else => {
                log.warn("plugin.loadFromDir.open_failed dir={s} err={s}", .{ dir_path, @errorName(err) });
                return err;
            },
        };
        defer dir.close(self.io);

        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (entry.name.len == 0) continue;
            if (entry.name[0] == '.') continue;
            if (entry.kind != .directory and entry.kind != .sym_link) continue;

            const plugin_dir = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            defer self.allocator.free(plugin_dir);
            self.clearLoadFailure(plugin_dir);

            // Check for plugin.lua manifest
            const manifest_path = try std.fs.path.join(self.allocator, &.{ plugin_dir, "plugin.lua" });
            defer self.allocator.free(manifest_path);

            if (!self.fileExists(manifest_path)) continue;

            _ = self.loadOneDuringMutation(plugin_dir, is_embedded) catch |err| {
                if (err == error.PluginDisabled) {
                    // A disabled plugin is a skip, not a load failure.
                    log.info("plugin.load.skipped_disabled path={s}", .{plugin_dir});
                    self.clearLoadFailure(plugin_dir);
                    continue;
                }
                try self.recordLoadFailure(plugin_dir, err);
                log.warn("plugin.load.failed path={s} reason={s}", .{ plugin_dir, @errorName(err) });
                continue;
            };
            self.clearLoadFailure(plugin_dir);
        }
    }

    /// Read and parse a plugin manifest from a directory.
    fn readManifest(self: *Self, dir_path: []const u8) !Manifest {
        const manifest_path = try std.fs.path.join(self.allocator, &.{ dir_path, "plugin.lua" });
        defer self.allocator.free(manifest_path);

        const bytes = try self.readFileBytes(manifest_path);
        defer self.allocator.free(bytes);
        return @import("manifest.zig").evaluate(self.allocator, bytes);
    }

    /// Load a Lua file and execute it, leaving the result on the stack.
    fn loadLuaFile(self: *Self, L: *State, path: []const u8) bool {
        const content = self.readFileBytes(path) catch |err| {
            log.warn("plugin.loadLuaFile.read_failed path={s} err={s}", .{ path, @errorName(err) });
            return false;
        };
        defer self.allocator.free(content);

        // Ensure null-terminated for Lua C API
        const null_term = self.allocator.dupeZ(u8, content) catch |err| {
            log.warn("plugin.loadLuaFile.dupZ_failed path={s} err={s}", .{ path, @errorName(err) });
            return false;
        };
        defer self.allocator.free(null_term);

        // Strip UTF-8 BOM if present
        var script_ptr = null_term.ptr;
        if (null_term.len >= 3 and std.mem.startsWith(u8, null_term, "\xEF\xBB\xBF")) {
            script_ptr = null_term[3..].ptr;
        }

        const load_rc = c.luaL_loadstring(L.handle, script_ptr);
        if (load_rc != c.LUA_OK) {
            const err_ptr = c.lua_tolstring(L.handle, -1, null);
            const msg = if (err_ptr) |p| std.mem.sliceTo(p, 0) else "unknown Lua load error";
            log.warn("plugin.loadLuaFile.lua_load_error path={s} err={s}", .{ path, msg });
            c.lua_pop(L.handle, 1);
            return false;
        }

        const pcall_rc = c.lua_pcallk(L.handle, 0, c.LUA_MULTRET, 0, 0, null);
        if (pcall_rc != c.LUA_OK) {
            const err_ptr = c.lua_tolstring(L.handle, -1, null);
            const msg = if (err_ptr) |p| std.mem.sliceTo(p, 0) else "unknown Lua runtime error";
            log.warn("plugin.loadLuaFile.lua_runtime_error path={s} err={s}", .{ path, msg });
            c.lua_pop(L.handle, 1);
            return false;
        }

        return true;
    }

    /// Read a file's contents into an owned slice.
    fn readFileBytes(self: *Self, path: []const u8) ![]u8 {
        var file = if (std.fs.path.isAbsolute(path))
            try std.Io.Dir.openFileAbsolute(self.io, path, .{})
        else
            try std.Io.Dir.openFile(.cwd(), self.io, path, .{});
        defer file.close(self.io);
        var reader = file.reader(self.io, &.{});
        return reader.interface.allocRemaining(self.allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.OutOfMemory, error.StreamTooLong => |e| return e,
        };
    }

    /// Save plugin state by calling get_state() in the plugin.
    fn savePluginState(self: *Self, plugin: *PluginInstance) ?[]u8 {
        plugin.lockExecution(self.io, self.execution_policy.tool_wait_ms) catch return null;
        defer plugin.execution_mutex.unlock(self.io);
        const top = c.lua_gettop(plugin.state.handle);
        defer c.lua_settop(plugin.state.handle, top);
        sandbox.resetInstructionBudget(plugin.state.handle);
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
        plugin.lockExecution(self.io, self.execution_policy.tool_wait_ms) catch return;
        defer plugin.execution_mutex.unlock(self.io);
        const top = c.lua_gettop(plugin.state.handle);
        defer c.lua_settop(plugin.state.handle, top);
        sandbox.resetInstructionBudget(plugin.state.handle);
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
        var file = if (std.fs.path.isAbsolute(path))
            std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return false
        else
            std.Io.Dir.openFile(.cwd(), self.io, path, .{}) catch return false;
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

test "plugin manager discovers visible project plugins root" {
    const gpa = std.testing.allocator;
    const root = "/tmp/zay_test_visible_project_plugins";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const project_plugins = try std.fs.path.join(gpa, &.{ root, "project", "plugins" });
    defer gpa.free(project_plugins);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, project_plugins);
    try writeFixturePlugin(project_plugins, "visible_plugin", "return true");

    const cwd = try std.fs.path.join(gpa, &.{ root, "project" });
    defer gpa.free(cwd);
    var manager = PluginManager.init(gpa, std.testing.io, "", cwd);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 1), try manager.loadAll());
    try std.testing.expect(manager.get("visible_plugin") != null);
    try std.testing.expectEqualStrings(project_plugins, manager.project_dir);
}

test "plugin manager: end-to-end loadOne with register_tool" {
    const testing = std.testing;

    const dir_path = try std.fs.path.join(testing.allocator, &.{ "/tmp", "zay_test_plugin_disk" });
    defer testing.allocator.free(dir_path);

    var io_dir = try std.Io.Dir.openDir(.cwd(), testing.io, "/tmp", .{});
    defer io_dir.close(testing.io);

    std.Io.Dir.cwd().createDirPath(testing.io, "/tmp/zay_test_plugin_disk") catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, "/tmp/zay_test_plugin_disk") catch {};

    var plugin_dir = try std.Io.Dir.openDir(.cwd(), testing.io, dir_path, .{});
    defer plugin_dir.close(testing.io);

    // Create plugin.lua
    try plugin_dir.writeFile(testing.io, .{
        .sub_path = "plugin.lua",
        .data =
        \\return {
        \\  name = "disk_plugin",
        \\  version = "1.0.0",
        \\  description = "Disk test plugin"
        \\}
        ,
    });

    // Create init.lua
    try plugin_dir.writeFile(testing.io, .{
        .sub_path = "init.lua",
        .data =
        \\zay.register_tool({
        \\  name = "disk_tool",
        \\  description = "Tool from disk plugin",
        \\  parameters = {},
        \\  handler = function() return "disk ok" end,
        \\})
        ,
    });

    var manager = PluginManager.init(testing.allocator, testing.io, "", "");
    defer manager.deinit();

    const instance = try manager.loadOne(dir_path, false);
    try testing.expectEqualStrings("disk_plugin", instance.manifest.name);
    try testing.expect(instance.active);

    const tool_count = plugin_api.countTools(instance.state.handle);
    try testing.expectEqual(@as(u32, 1), tool_count);
}

// ── plugin config: enabled + settings (P1/P2) ───────────────────────

/// Write a minimal plugin fixture (plugin.lua + init.lua) under `abs_root/name`.
fn writeFixturePlugin(abs_root: []const u8, name: []const u8, init_lua: []const u8) !void {
    const path = try std.fs.path.join(std.testing.allocator, &.{ abs_root, name });
    defer std.testing.allocator.free(path);
    std.Io.Dir.cwd().createDirPath(std.testing.io, path) catch {};

    var d = try std.Io.Dir.openDir(.cwd(), std.testing.io, path, .{});
    defer d.close(std.testing.io);

    const manifest = try std.fmt.allocPrint(
        std.testing.allocator,
        "return {{ name = \"{s}\", version = \"1.0.0\", description = \"{s}\" }}",
        .{ name, name },
    );
    defer std.testing.allocator.free(manifest);
    try d.writeFile(std.testing.io, .{ .sub_path = "plugin.lua", .data = manifest });
    try d.writeFile(std.testing.io, .{ .sub_path = "init.lua", .data = init_lua });
}

test "disabled hostile manifests cannot access the host or evade budgets" {
    const testing = std.testing;
    const root = "/tmp/zay_test_disabled_hostile_manifest";
    const plugins_root = root ++ "/plugins";
    const marker = root ++ "/marker";
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try writeFixturePlugin(plugins_root, "hostile", "return {}");
    try writeFixturePlugin(plugins_root, "looping", "return {}");
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = plugins_root ++ "/hostile/plugin.lua",
        .data = "os.execute('touch " ++ marker ++ "'); return {name='hostile',version='1'}",
    });
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = plugins_root ++ "/looping/plugin.lua",
        .data = "while true do end; return {name='looping',version='1'}",
    });
    var manager = PluginManager.init(testing.allocator, testing.io, "", root);
    defer manager.deinit();
    var hostile: plugin_config.PluginConfig = .{ .name = try testing.allocator.dupe(u8, "hostile"), .enabled = false };
    defer hostile.deinit(testing.allocator);
    var looping: plugin_config.PluginConfig = .{ .name = try testing.allocator.dupe(u8, "looping"), .enabled = false };
    defer looping.deinit(testing.allocator);
    try manager.syncPluginConfig(&.{ hostile, looping });
    try testing.expectEqual(@as(usize, 0), try manager.loadAll());
    try testing.expectEqualStrings("InvalidManifest", manager.load_failures.get(plugins_root ++ "/hostile").?);
    try testing.expectEqualStrings("ManifestInstructionLimit", manager.load_failures.get(plugins_root ++ "/looping").?);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, marker, .{}));
}

test "plugin manager: syncPluginConfig skips disabled plugins (P2)" {
    const testing = std.testing;
    const gpa = testing.allocator;

    // The fixture mirrors the production layout: <home>/.config/zay/plugins,
    // because PluginManager.init derives global_dir from home_dir.
    const root = "/tmp/zay_test_plugin_cfg/.config/zay/plugins";
    std.Io.Dir.cwd().createDirPath(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, "/tmp/zay_test_plugin_cfg") catch {};

    try writeFixturePlugin(root, "on_plugin",
        \\unconfigured = (plugin.get_config() == nil)
        \\zay.register_tool({
        \\  name = "t",
        \\  description = "t",
        \\  parameters = {},
        \\  handler = function() return "on" end,
        \\})
    );
    try writeFixturePlugin(root, "off_plugin",
        \\zay.register_tool({
        \\  name = "t",
        \\  description = "t",
        \\  parameters = {},
        \\  handler = function() return "off" end,
        \\})
    );

    var manager = PluginManager.init(gpa, testing.io, "/tmp/zay_test_plugin_cfg", "");
    defer manager.deinit();

    // Owned input entry, freed right after sync to prove the manager holds
    // clones (borrowed slices would double-free under the test allocator).
    var entry: plugin_config.PluginConfig = .{
        .name = try gpa.dupe(u8, "off_plugin"),
        .enabled = false,
    };
    try manager.syncPluginConfig(&.{entry});
    entry.deinit(gpa);

    // loadOne refuses the disabled plugin before any teardown/registration.
    const off_dir = try std.fs.path.join(gpa, &.{ root, "off_plugin" });
    defer gpa.free(off_dir);
    try testing.expectError(error.PluginDisabled, manager.loadOne(off_dir, false));

    // The directory walk skips it at info level and loads only on_plugin,
    // which is unconfigured (no config entry → default enabled, nil config).
    try testing.expectEqual(@as(usize, 1), try manager.loadAll());
    try testing.expect(manager.get("on_plugin") != null);
    try testing.expect(manager.get("off_plugin") == null);

    const on = manager.get("on_plugin").?;
    _ = c.lua_getglobal(on.state.handle, "unconfigured");
    try testing.expect(c.lua_toboolean(on.state.handle, -1) != 0);
    c.lua_pop(on.state.handle, 1);
}

test "plugin manager: settings reach init.lua and tool handlers via get_config (P1+P2)" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const root = "/tmp/zay_test_plugin_settings";
    std.Io.Dir.cwd().createDirPath(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};

    try writeFixturePlugin(root, "cfg_plugin",
        \\local cfg = plugin.get_config()
        \\load_time_theme = cfg and cfg.theme or "unset"
        \\zay.register_tool({
        \\  name = "theme_tool",
        \\  description = "returns configured theme",
        \\  parameters = {},
        \\  handler = function()
        \\    local c = plugin.get_config()
        \\    return (c and c.theme) or "unset"
        \\  end,
        \\})
    );

    var manager = PluginManager.init(gpa, testing.io, "", "");
    defer manager.deinit();

    var entry: plugin_config.PluginConfig = .{
        .name = try gpa.dupe(u8, "cfg_plugin"),
        .settings = try gpa.dupe(u8, "{\"theme\":\"dark\"}"),
    };
    try manager.syncPluginConfig(&.{entry});
    entry.deinit(gpa);

    const plugin_dir = try std.fs.path.join(gpa, &.{ root, "cfg_plugin" });
    defer gpa.free(plugin_dir);
    const instance = try manager.loadOne(plugin_dir, false);
    try testing.expectEqualStrings("cfg_plugin", instance.manifest.name);

    // The registry slot is set before init.lua runs — the load-time read saw it.
    _ = c.lua_getglobal(instance.state.handle, "load_time_theme");
    var len: usize = 0;
    const p = c.lua_tolstring(instance.state.handle, -1, &len);
    const got = if (p) |q| q[0..len] else "";
    try testing.expectEqualStrings("dark", got);
    c.lua_pop(instance.state.handle, 1);

    // And the per-call read inside a tool handler returns the same value.
    var out = try manager.callTool("cfg_plugin", "theme_tool", "{}");
    defer out.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expectEqualStrings("dark", out.text);
}

test "plugin manager: handler result contract preserves status and stack balance" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(testing.io, gpa);
    defer gpa.free(cwd);
    const root = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "plugin-result-contract",
    });
    defer gpa.free(root);
    std.Io.Dir.cwd().createDirPath(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};

    try writeFixturePlugin(root, "result_plugin",
        \\local function register(name, handler)
        \\  zay.register_tool({ name = name, description = name, parameters = {}, handler = handler })
        \\end
        \\register("success", function() return "Error: this is valid output text" end)
        \\register("failure", function() return nil, "diagnostic from handler" end)
        \\register("exception", function() error("boom") end)
        \\register("malformed", function() return {} end)
    );

    var manager = PluginManager.init(gpa, testing.io, "", "");
    defer manager.deinit();
    const plugin_dir = try std.fs.path.join(gpa, &.{ root, "result_plugin" });
    defer gpa.free(plugin_dir);
    const instance = try manager.loadOne(plugin_dir, false);
    const stack_depth = c.lua_gettop(instance.state.handle);

    var success = try manager.callTool("result_plugin", "success", "{}");
    defer success.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), success.code);
    try testing.expectEqualStrings("Error: this is valid output text", success.text);
    try testing.expectEqual(stack_depth, c.lua_gettop(instance.state.handle));

    var failure = try manager.callTool("result_plugin", "failure", "{}");
    defer failure.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), failure.code);
    try testing.expectEqualStrings("diagnostic from handler", failure.text);
    try testing.expectEqual(stack_depth, c.lua_gettop(instance.state.handle));

    var exception = try manager.callTool("result_plugin", "exception", "{}");
    defer exception.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), exception.code);
    try testing.expect(std.mem.startsWith(u8, exception.text, "Lua tool error:"));
    try testing.expect(std.mem.indexOf(u8, exception.text, "boom") != null);
    try testing.expectEqual(stack_depth, c.lua_gettop(instance.state.handle));

    var malformed = try manager.callTool("result_plugin", "malformed", "{}");
    defer malformed.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), malformed.code);
    try testing.expectEqualStrings(
        "Lua tool handler must return a string, or nil and an error message",
        malformed.text,
    );
    try testing.expectEqual(stack_depth, c.lua_gettop(instance.state.handle));
}

// Load every shipped plugin and confirm each registered at least one
// tool. This catches syntax errors, missing bridge functions, and registration
// regressions across the whole plugin set in one test.
test "plugin manager: loads all shipped example plugins" {
    const testing = std.testing;

    // plugins is resolved from cwd. The test binary runs with cwd
    // set to the repo root (same convention as the other plugin tests), so a
    // relative "plugins" works without needing @src().
    const plugins_dir = try std.fs.path.join(testing.allocator, &.{ "plugins", "packages" });
    defer testing.allocator.free(plugins_dir);

    // Each entry: directory name and the minimum number of tools expected.
    const expectations = [_]struct { dir: []const u8, min_tools: u32 }{
        .{ .dir = "file-tools", .min_tools = 4 }, // read, write, edit, list_directory
        .{ .dir = "search-tools", .min_tools = 2 }, // grep, glob
        .{ .dir = "path-tools", .min_tools = 4 }, // create_directory, copy_path, move_path, delete_path
        .{ .dir = "git-tools", .min_tools = 5 }, // git_status, git_diff, git_log, git_branch, git_commit
        .{ .dir = "hello-world", .min_tools = 1 }, // greet (demo, at least one)
        .{ .dir = "file-watcher", .min_tools = 1 }, // track_file_op / file_stats
        .{ .dir = "todo", .min_tools = 9 }, // todo_list, todo_add, todo_done, todo_delete, todo_prioritize, todo_write, todo_get_plan, todo_set_plan, todo_check_step
        // Zero I/O at load (bootstrap happens lazily inside tool handlers),
        // so this load test needs no duckdb binary present.
        .{ .dir = "sitting-duck", .min_tools = 4 }, // ast_outline, ast_find_pattern, ast_get_source, ast_query
    };

    var manager = PluginManager.init(testing.allocator, testing.io, "", "");
    defer manager.deinit();

    for (expectations) |exp| {
        const plugin_dir = try std.fs.path.join(testing.allocator, &.{ plugins_dir, exp.dir });
        defer testing.allocator.free(plugin_dir);

        const instance = manager.loadOne(plugin_dir, false) catch |err| {
            std.debug.print("\nFAIL load plugin {s}: {s}\n", .{ exp.dir, @errorName(err) });
            return err;
        };
        const tool_count = plugin_api.countTools(instance.state.handle);
        if (tool_count < exp.min_tools) {
            std.debug.print("\nFAIL plugin {s}: expected >={d} tools, got {d}\n", .{ exp.dir, exp.min_tools, tool_count });
        }
        try testing.expect(tool_count >= exp.min_tools);
    }
}

// End-to-end exercise of the todo plugin's plan round-trip via the json bridges
// is intentionally NOT a unit test here: the plugin reads ".zay/todos.txt" and
// ".zay/todos/plans.json" as paths relative to cwd, and Zig 0.16 has no
// process.chdir API to isolate the test's file ops from the repo's real .zay/.
// Coverage instead comes from two layers:
//   1. The 9 json_decode/json_encode unit tests in plugin_api.zig prove each
//      bridge works (decode of objects/arrays/primitives, encode with array-vs-
//      object inference, pretty indentation, string escaping, nested round-trip).
//   2. "plugin manager: loads all shipped example plugins" below proves the
//      todo plugin's init.lua is syntactically valid, the bridges it calls
//      (json_encode in save_plans, json_decode in load_plans) resolve at load,
//      and all 9 tools register. Handler bodies are pure Lua, so once the
//      bridges and registration are proven, the set_plan/get_plan/check_step
//      loop follows. Verify the live flow by running the plugin in Zay.

// Verify that a plugin's registered event callback fires when emitEvent is
// called. This is the integration test for the event wiring (agent.zig emits
// -> PluginManager.emitEvent -> drains zay_events -> pcalls callback).
test "plugin manager: emitEvent delivers to plugin callbacks" {
    const testing = std.testing;

    const dir_path = try std.fs.path.join(testing.allocator, &.{ "/tmp", "zay_test_plugin_events" });
    defer testing.allocator.free(dir_path);

    std.Io.Dir.cwd().createDirPath(testing.io, "/tmp/zay_test_plugin_events") catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, "/tmp/zay_test_plugin_events") catch {};

    var plugin_dir = try std.Io.Dir.openDir(.cwd(), testing.io, dir_path, .{});
    defer plugin_dir.close(testing.io);

    try plugin_dir.writeFile(testing.io, .{
        .sub_path = "plugin.lua",
        .data =
        \\return {
        \\  name = "event_plugin",
        \\  version = "1.0.0",
        \\  description = "Event test plugin"
        \\}
        ,
    });
    try plugin_dir.writeFile(testing.io, .{
        .sub_path = "init.lua",
        .data =
        \\-- Register a callback that records the tool name in a global.
        \\zay.on("tool_call_started", function(data)
        \\  _G.received_tool = data.name
        \\end)
        \\zay.register_tool({
        \\  name = "noop",
        \\  description = "noop",
        \\  parameters = {},
        \\  handler = function() return "ok" end,
        \\})
        ,
    });

    var manager = PluginManager.init(testing.allocator, testing.io, "", "");
    defer manager.deinit();

    const instance = try manager.loadOne(dir_path, false);
    try testing.expect(instance.active);

    // Emit a tool_call_started event; the callback should record the name.
    manager.emitEvent(.{
        .tool_call_started = .{ .name = "bash", .call_id = "call-1" },
    });

    // Read back the global the callback set.
    _ = c.lua_getglobal(instance.state.handle, "received_tool");
    const got = c.lua_tolstring(instance.state.handle, -1, null);
    c.lua_pop(instance.state.handle, 1);
    if (got) |ptr| {
        try testing.expectEqualStrings("bash", std.mem.span(ptr));
    } else {
        return error.CallbackDidNotFire;
    }
}

test "plugin manager: file-watcher counts a real failed/successful completion event" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var manager = PluginManager.init(gpa, testing.io, "", "");
    defer manager.deinit();

    const instance = try manager.loadOne("plugins/packages/file-watcher", false);
    try testing.expect(instance.active);
    manager.emitEvent(.{
        .tool_call_finished = .{ .name = "lua__file-tools__write", .call_id = "call-ok", .success = true },
    });
    manager.emitEvent(.{
        .tool_call_finished = .{ .name = "lua__file-tools__write", .call_id = "call-failed", .success = false },
    });

    var result = try manager.callTool("file-watcher", "file_stats", "{}");
    defer result.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.text, "write=1") != null);
}

// ── repointProjectDir tests ──────────────────────────────────────

test "plugin load diagnostics prune departed projects and removed packages" {
    const testing = std.testing;
    const root = "/tmp/zay_test_load_failure_pruning";
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    const old_root = root ++ "/old/plugins";
    const legacy_root = root ++ "/old/.zay/plugins";
    const global_root = root ++ "/home/.config/zay/plugins";
    try writeFixturePlugin(old_root, "old_bad", "error('broken')");
    try writeFixturePlugin(legacy_root, "legacy_bad", "error('broken')");
    try writeFixturePlugin(global_root, "global_bad", "error('broken')");
    var manager = PluginManager.init(testing.allocator, testing.io, root ++ "/home", root ++ "/old");
    defer manager.deinit();
    _ = try manager.loadAll();
    try testing.expectEqual(@as(u32, 3), manager.load_failures.count());
    // A sibling with a shared path prefix must not be pruned.
    try manager.recordLoadFailure(old_root ++ "-other/keep", error.PluginInitFailed);
    try manager.repointProjectDir(root ++ "/new");
    try testing.expectEqual(@as(u32, 2), manager.load_failures.count());
    try testing.expect(manager.load_failures.contains(global_root ++ "/global_bad"));
    try testing.expect(manager.load_failures.contains(old_root ++ "-other/keep"));

    try std.Io.Dir.cwd().deleteTree(testing.io, global_root ++ "/global_bad");
    try manager.loadFromDir(global_root, false);
    try testing.expect(!manager.load_failures.contains(global_root ++ "/global_bad"));
    try manager.recordLoadFailure(global_root ++ "/missing", error.PluginInitFailed);
    try std.Io.Dir.cwd().deleteTree(testing.io, global_root);
    try manager.loadFromDir(global_root, false);
    try testing.expect(!manager.load_failures.contains(global_root ++ "/missing"));
    try testing.expectEqual(@as(u32, 1), manager.load_failures.count());
}

test "repointProjectDir swaps project plugins, keeps globals" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const root_tmp = "/tmp/zay_test_repoint_swap";
    defer std.Io.Dir.cwd().deleteTree(testing.io, root_tmp) catch {};

    // Create: <home>/.config/zay/plugins/
    const home_plugins = try std.fs.path.join(gpa, &.{ root_tmp, "home", ".config", "zay", "plugins" });
    defer gpa.free(home_plugins);
    std.Io.Dir.cwd().createDirPath(testing.io, home_plugins) catch {};

    // Create: <old_project>/.zay/plugins/
    const old_proj_plugins = try std.fs.path.join(gpa, &.{ root_tmp, "old_project", ".zay", "plugins" });
    defer gpa.free(old_proj_plugins);
    std.Io.Dir.cwd().createDirPath(testing.io, old_proj_plugins) catch {};

    // Create: <new_project>/.zay/plugins/
    const new_proj_plugins = try std.fs.path.join(gpa, &.{ root_tmp, "new_project", ".zay", "plugins" });
    defer gpa.free(new_proj_plugins);
    std.Io.Dir.cwd().createDirPath(testing.io, new_proj_plugins) catch {};

    try writeFixturePlugin(home_plugins, "global_plugin", "zay.register_tool({name='t',description='t',parameters={},handler=function() return 'global' end})");
    try writeFixturePlugin(old_proj_plugins, "old_proj_plugin", "zay.register_tool({name='t',description='t',parameters={},handler=function() return 'old' end})");
    try writeFixturePlugin(new_proj_plugins, "new_proj_plugin", "zay.register_tool({name='t',description='t',parameters={},handler=function() return 'new' end})");

    const home_dir = try std.fs.path.join(gpa, &.{ root_tmp, "home" });
    defer gpa.free(home_dir);
    const old_cwd = try std.fs.path.join(gpa, &.{ root_tmp, "old_project" });
    defer gpa.free(old_cwd);

    var manager = PluginManager.init(gpa, testing.io, home_dir, old_cwd);
    defer manager.deinit();

    try manager.syncPluginConfig(&.{});
    _ = try manager.loadAll();

    // Verify initial state: all three loaded
    try testing.expect(manager.get("global_plugin") != null);
    try testing.expect(manager.get("old_proj_plugin") != null);
    try testing.expect(manager.get("new_proj_plugin") == null);

    // Repoint to new_project
    const new_cwd = try std.fs.path.join(gpa, &.{ root_tmp, "new_project" });
    defer gpa.free(new_cwd);
    try manager.repointProjectDir(new_cwd);

    // Verify: old project plugin gone, new one loaded, global stays
    try testing.expect(manager.get("global_plugin") != null);
    try testing.expect(manager.get("old_proj_plugin") == null);
    try testing.expect(manager.get("new_proj_plugin") != null);

    // Verify project_dir updated to new_project's visible plugins root.
    const expected_new_dir = try std.fs.path.join(gpa, &.{ new_cwd, "plugins" });
    defer gpa.free(expected_new_dir);
    try testing.expectEqualStrings(expected_new_dir, manager.project_dir);
}

test "repointProjectDir to a project without plugins is a no-op" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const root_tmp = "/tmp/zay_test_repoint_noop";
    defer std.Io.Dir.cwd().deleteTree(testing.io, root_tmp) catch {};

    const home_plugins = try std.fs.path.join(gpa, &.{ root_tmp, "home", ".config", "zay", "plugins" });
    defer gpa.free(home_plugins);
    std.Io.Dir.cwd().createDirPath(testing.io, home_plugins) catch {};

    const old_proj_plugins = try std.fs.path.join(gpa, &.{ root_tmp, "old_project", ".zay", "plugins" });
    defer gpa.free(old_proj_plugins);
    std.Io.Dir.cwd().createDirPath(testing.io, old_proj_plugins) catch {};

    try writeFixturePlugin(home_plugins, "global_plugin", "zay.register_tool({name='t',description='t',parameters={},handler=function() return 'global' end})");
    try writeFixturePlugin(old_proj_plugins, "old_proj_plugin", "zay.register_tool({name='t',description='t',parameters={},handler=function() return 'old' end})");

    const home_dir = try std.fs.path.join(gpa, &.{ root_tmp, "home" });
    defer gpa.free(home_dir);
    const old_cwd = try std.fs.path.join(gpa, &.{ root_tmp, "old_project" });
    defer gpa.free(old_cwd);

    var manager = PluginManager.init(gpa, testing.io, home_dir, old_cwd);
    defer manager.deinit();

    try manager.syncPluginConfig(&.{});
    _ = try manager.loadAll();

    try testing.expect(manager.get("global_plugin") != null);
    try testing.expect(manager.get("old_proj_plugin") != null);

    // Repoint to a directory with no project plugins root.
    const no_project_cwd = try std.fs.path.join(gpa, &.{ root_tmp, "no_project" });
    defer gpa.free(no_project_cwd);
    // Ensure the target directory exists (but no plugins subdir)
    std.Io.Dir.cwd().createDirPath(testing.io, no_project_cwd) catch {};
    try manager.repointProjectDir(no_project_cwd);

    // Verify: old project plugin gone, global stays, no new plugins loaded
    try testing.expect(manager.get("global_plugin") != null);
    try testing.expect(manager.get("old_proj_plugin") == null);
    try testing.expectEqual(@as(usize, 1), manager.count());

    // Verify project_dir updated
    const expected_new_dir = try std.fs.path.join(gpa, &.{ no_project_cwd, "plugins" });
    defer gpa.free(expected_new_dir);
    try testing.expectEqualStrings(expected_new_dir, manager.project_dir);
}

test "repointProjectDir unloads by dir, not by name" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const root_tmp = "/tmp/zay_test_repoint_samename";
    defer std.Io.Dir.cwd().deleteTree(testing.io, root_tmp) catch {};

    const home_plugins = try std.fs.path.join(gpa, &.{ root_tmp, "home", ".config", "zay", "plugins" });
    defer gpa.free(home_plugins);
    std.Io.Dir.cwd().createDirPath(testing.io, home_plugins) catch {};

    const old_proj_plugins = try std.fs.path.join(gpa, &.{ root_tmp, "old_project", ".zay", "plugins" });
    defer gpa.free(old_proj_plugins);
    std.Io.Dir.cwd().createDirPath(testing.io, old_proj_plugins) catch {};

    const new_proj_plugins = try std.fs.path.join(gpa, &.{ root_tmp, "new_project", ".zay", "plugins" });
    defer gpa.free(new_proj_plugins);
    std.Io.Dir.cwd().createDirPath(testing.io, new_proj_plugins) catch {};

    // Same plugin name in both old and new project dirs
    try writeFixturePlugin(old_proj_plugins, "foo", "zay.register_tool({name='t',description='t',parameters={},handler=function() return 'old_foo' end})");
    try writeFixturePlugin(new_proj_plugins, "foo", "zay.register_tool({name='t',description='t',parameters={},handler=function() return 'new_foo' end})");

    const home_dir = try std.fs.path.join(gpa, &.{ root_tmp, "home" });
    defer gpa.free(home_dir);
    const old_cwd = try std.fs.path.join(gpa, &.{ root_tmp, "old_project" });
    defer gpa.free(old_cwd);

    var manager = PluginManager.init(gpa, testing.io, home_dir, old_cwd);
    defer manager.deinit();

    try manager.syncPluginConfig(&.{});
    _ = try manager.loadAll();

    // Verify "foo" loaded from old project dir
    const foo_before = manager.get("foo") orelse return error.PluginNotFound;
    const old_foo_dir = try std.fs.path.join(gpa, &.{ old_proj_plugins, "foo" });
    defer gpa.free(old_foo_dir);
    try testing.expectEqualStrings(old_foo_dir, foo_before.dir_path);

    // Repoint to new_project
    const new_cwd = try std.fs.path.join(gpa, &.{ root_tmp, "new_project" });
    defer gpa.free(new_cwd);
    try manager.repointProjectDir(new_cwd);

    // Verify "foo" still present, now loaded from new project dir
    const foo_after = manager.get("foo") orelse return error.PluginNotFound;

    const new_foo_dir = try std.fs.path.join(gpa, &.{ new_proj_plugins, "foo" });
    defer gpa.free(new_foo_dir);
    try testing.expectEqualStrings(new_foo_dir, foo_after.dir_path);
}

test "repointProjectDir restores globals shadowed by old project plugins" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const root_tmp = "/tmp/zay_test_repoint_shadow";
    defer std.Io.Dir.cwd().deleteTree(testing.io, root_tmp) catch {};

    const home_plugins = try std.fs.path.join(gpa, &.{ root_tmp, "home", ".config", "zay", "plugins" });
    defer gpa.free(home_plugins);
    std.Io.Dir.cwd().createDirPath(testing.io, home_plugins) catch {};

    const old_proj_plugins = try std.fs.path.join(gpa, &.{ root_tmp, "old_project", ".zay", "plugins" });
    defer gpa.free(old_proj_plugins);
    std.Io.Dir.cwd().createDirPath(testing.io, old_proj_plugins) catch {};

    const new_proj_plugins = try std.fs.path.join(gpa, &.{ root_tmp, "new_project", ".zay", "plugins" });
    defer gpa.free(new_proj_plugins);
    std.Io.Dir.cwd().createDirPath(testing.io, new_proj_plugins) catch {};

    // Global dir has "foo", old project dir also has "foo" (shadows global),
    // new project dir has no "foo".
    try writeFixturePlugin(home_plugins, "foo", "zay.register_tool({name='t',description='t',parameters={},handler=function() return 'global_foo' end})");
    try writeFixturePlugin(old_proj_plugins, "foo", "zay.register_tool({name='t',description='t',parameters={},handler=function() return 'old_foo' end})");

    const home_dir = try std.fs.path.join(gpa, &.{ root_tmp, "home" });
    defer gpa.free(home_dir);
    const old_cwd = try std.fs.path.join(gpa, &.{ root_tmp, "old_project" });
    defer gpa.free(old_cwd);

    var manager = PluginManager.init(gpa, testing.io, home_dir, old_cwd);
    defer manager.deinit();

    try manager.syncPluginConfig(&.{});
    _ = try manager.loadAll();

    // At this point "foo" is loaded from the old project dir (shadows global)
    const foo_before = manager.get("foo") orelse return error.PluginNotFound;
    const old_foo_dir = try std.fs.path.join(gpa, &.{ old_proj_plugins, "foo" });
    defer gpa.free(old_foo_dir);
    try testing.expectEqualStrings(old_foo_dir, foo_before.dir_path);

    // Repoint to new_project (no "foo" in its plugins)
    const new_cwd = try std.fs.path.join(gpa, &.{ root_tmp, "new_project" });
    defer gpa.free(new_cwd);
    try manager.repointProjectDir(new_cwd);

    // "foo" should be reloaded from the global dir — the shadowed global is restored
    const foo_after = manager.get("foo") orelse return error.PluginNotFound;
    const global_foo_dir = try std.fs.path.join(gpa, &.{ home_plugins, "foo" });
    defer gpa.free(global_foo_dir);
    try testing.expectEqualStrings(global_foo_dir, foo_after.dir_path);
}
