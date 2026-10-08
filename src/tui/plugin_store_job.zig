//! TUI lifecycle for plugin-store refresh and installation jobs.
//!
//! The worker owns only copied paths and store I/O. Adoption updates a pure
//! catalog snapshot; it never calls PluginManager or mutates the live tool
//! registry. Installed plugins therefore become available at the next runtime
//! load, which preserves the Lua-state/tool-record lifetime invariant.

const std = @import("std");
const plugin_store = @import("../plugin_store.zig");
const package = @import("../plugin_package.zig");
const sandbox = @import("../lua/sandbox.zig");
const config_mod = @import("../config/config.zig");
const job_mod = @import("job.zig");
const paths = @import("../paths.zig");
const tui = @import("../tui.zig");

const App = tui.App;

pub const RefreshResult = union(enum) {
    ready: struct { catalogs: plugin_store.CatalogBundle, inventory: package.Inventory },
    failed: []u8,

    fn deinit(self: *RefreshResult, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |*snapshot| {
                snapshot.catalogs.deinit(gpa);
                snapshot.inventory.deinit(gpa);
            },
            .failed => |message| if (message.len > 0) gpa.free(message),
        }
        self.* = undefined;
    }
};

pub const InventoryResult = union(enum) {
    ready: package.Inventory,
    failed: []u8,
    fn deinit(self: *InventoryResult, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |*inventory| inventory.deinit(gpa),
            .failed => |message| if (message.len > 0) gpa.free(message),
        }
    }
};

pub const InstallResult = union(enum) {
    complete: plugin_store.InstallReport,
    failed: []u8,

    fn deinit(self: *InstallResult, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .complete => |*report| report.deinit(gpa),
            .failed => |message| if (message.len > 0) gpa.free(message),
        }
        self.* = undefined;
    }
};

pub const UninstallResult = union(enum) {
    removed: []u8,
    failed: []u8,

    fn deinit(self: *UninstallResult, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .removed, .failed => |message| if (message.len > 0) gpa.free(message),
        }
        self.* = undefined;
    }
};

pub const InstalledPlugin = struct {
    name: []const u8,
    active: bool,
    enabled: bool,
    path: []const u8 = "",
    version: []const u8 = "unknown",
    origin: []const u8 = "settings only",
    diagnostic: ?[]const u8 = null,
    managed: bool = false,
    shadowed: bool = false,
    permissions: sandbox.Permissions = .{},
};

pub const Operation = union(enum) {
    idle,
    refreshing: struct { job: job_mod.Job(RefreshResult), generation: u64 },
    scanning: struct { job: job_mod.Job(InventoryResult), generation: u64 },
    installing: struct { job: job_mod.Job(InstallResult) },
    uninstalling: struct { job: job_mod.Job(UninstallResult) },
};

pub const State = struct {
    catalogs: ?plugin_store.CatalogBundle = null,
    operation: Operation = .idle,
    notice: ?[]u8 = null,
    inventory: package.Inventory = .{},
    project_root: []u8 = &.{},
    generation: u64 = 0,

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        std.debug.assert(self.operation == .idle);
        if (self.catalogs) |*bundle| bundle.deinit(gpa);
        if (self.notice) |message| gpa.free(message);
        self.inventory.deinit(gpa);
        if (self.project_root.len > 0) gpa.free(self.project_root);
        self.* = undefined;
    }
};

/// Build the Installed-tab rows from loaded plugins plus persisted disabled
/// entries. Disabled plugins are intentionally absent from PluginManager.
pub fn installedPlugins(gpa: std.mem.Allocator, app: *App) ![]InstalledPlugin {
    var rows: std.ArrayList(InstalledPlugin) = .empty;
    errdefer rows.deinit(gpa);

    for (app.plugin_store.inventory.packages) |*disk| {
        const name = disk.name();
        const loaded = app.plugin_manager.get(name);
        const same_copy = if (loaded) |entry| paths.pathsEqual(entry.dir_path, disk.path) else false;
        try rows.append(gpa, .{
            .name = name,
            .active = if (same_copy) loaded.?.active else false,
            .enabled = configuredEnabled(&app.cached_config, name),
            .path = disk.path,
            .version = disk.version(),
            .origin = @tagName(disk.origin),
            .diagnostic = disk.diagnostic orelse app.plugin_manager.load_failures.get(disk.path),
            .managed = disk.origin == .global and disk.receipt != null and disk.ordinary_directory,
            .shadowed = loaded != null and !same_copy,
            .permissions = if (disk.manifest) |value| value.permissions else .{},
        });
    }
    for (app.cached_config.plugins) |configured| {
        var exists = false;
        for (rows.items) |row| if (std.mem.eql(u8, row.name, configured.name)) {
            exists = true;
            break;
        };
        if (exists) continue;
        try rows.append(gpa, .{ .name = configured.name, .active = false, .enabled = configured.enabled, .diagnostic = "Package is missing; project preference retained." });
    }
    return rows.toOwnedSlice(gpa);
}

/// Invalidates only project-scoped snapshots. The armed job stays in place
/// until adoption/join; moving it would invalidate its captured done pointer.
pub fn repoint(app: *App, project_root: []const u8) !void {
    if (paths.pathsEqual(app.plugin_store.project_root, project_root)) return;
    const owned = try app.gpa.dupe(u8, project_root);
    if (app.plugin_store.project_root.len > 0) app.gpa.free(app.plugin_store.project_root);
    app.plugin_store.project_root = owned;
    app.plugin_store.generation += 1;
    if (app.plugin_store.catalogs) |*catalogs| catalogs.deinit(app.gpa);
    app.plugin_store.catalogs = null;
    app.plugin_store.inventory.deinit(app.gpa);
    app.pickers.plugins.reset();
    app.pickers.plugins.confirming_uninstall = false;
    app.pickers.plugins.adding = false;
}

pub fn configuredEnabled(config: *const config_mod.Config, name: []const u8) bool {
    for (config.plugins) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.enabled;
    }
    return true;
}

pub fn isInstalled(app: *const App, catalog: []const u8, id: []const u8) bool {
    for (app.plugin_store.inventory.packages) |disk| {
        const receipt = disk.receipt orelse continue;
        if (disk.origin == .global and std.mem.eql(u8, receipt.value.id, id) and std.mem.eql(u8, receipt.value.catalog, catalog)) return true;
    }
    return false;
}

pub fn verified(plugin: *const plugin_store.Plugin) bool {
    return switch (plugin.source) {
        .local_dir => true,
        .files => |files| blk: {
            for (files) |file| if (file.sha256 == null) break :blk false;
            break :blk true;
        },
    };
}

pub fn isProjectPlugin(app: *App, name: []const u8) bool {
    const entry = app.plugin_manager.get(name) orelse return false;
    const parent = std.fs.path.dirname(entry.dir_path) orelse return false;
    return paths.pathsEqual(parent, app.plugin_manager.project_dir) or
        paths.pathsEqual(parent, app.plugin_manager.legacy_project_dir);
}

pub fn setEnabled(app: *App, name: []const u8, enabled: bool) !void {
    const runtime = app.liveRuntime() orelse app.templateRuntime() orelse return error.NoActiveRuntime;
    if (runtime.cwd.len == 0) return error.ProjectPathUnavailable;

    const next_plugins = try clonePluginConfigsWithEnabled(app.gpa, app.cached_config.plugins, name, enabled);
    errdefer deinitPluginConfigs(app.gpa, next_plugins);
    var update_plugins = [_]config_mod.PluginConfig{.{ .name = @constCast(name), .enabled = enabled }};
    const updates: config_mod.Config = .{ .plugins = &update_plugins };
    try config_mod.mergeAndWriteProject(app.gpa, app.io, runtime.cwd, updates);

    if (app.cached_config.plugins.len > 0) deinitPluginConfigs(app.gpa, app.cached_config.plugins);
    app.cached_config.plugins = next_plugins;
}

pub fn toggleEnabled(app: *App, name: []const u8) void {
    const enabled = !configuredEnabled(&app.cached_config, name);
    setEnabled(app, name, enabled) catch |err| {
        setErrorNotice(app, "Could not save plugin setting", err);
        return;
    };
    setNotice(app, if (enabled)
        "Plugin enabled for this project. Restart Zay to load it."
    else
        "Plugin disabled for this project. Restart Zay to unload it.");
}

pub fn uninstall(app: *App, name: []const u8) void {
    startUninstall(app, name) catch |err| {
        const message: []const u8 = switch (err) {
            error.ProjectPluginNotStoreManaged => "Store removal only removes global installs; project plugins are kept.",
            error.DisableAndRestartFirst, error.RestartRequired => "Disable this plugin and restart Zay before removing it.",
            error.UnmanagedInstallation => "This plugin is not Store-managed; remove it manually by its directory.",
            error.PluginNotFound => "No global Store install found; project plugins are kept by Store removal.",
            error.InvalidPluginName => "Could not remove plugin: invalid plugin name.",
            error.PluginOperationBusy => "Another plugin operation is already in progress.",
            else => "Could not start plugin removal.",
        };
        setNotice(app, message);
    };
}

/// Missing packages have no physical identity to send to the uninstaller.
/// Forget only this project's saved override; global preferences remain owned
/// by the global configuration layer.
pub fn forgetMissingPlugin(app: *App, name: []const u8) void {
    const runtime = app.liveRuntime() orelse app.templateRuntime() orelse {
        setNotice(app, "Could not remove plugin preference: no active project.");
        return;
    };
    forgetMissingPluginConfig(app.gpa, app.io, runtime.cwd, runtime.home_dir, &app.cached_config, name) catch |err| {
        if (err == error.GlobalPluginPreference) {
            setNotice(app, "Package is missing; remove its saved preference from global config.json.");
        } else {
            setErrorNotice(app, "Could not remove plugin preference", err);
        }
        return;
    };
    setNotice(app, "Removed saved plugin preference; package was already missing.");
}

fn forgetMissingPluginConfig(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, home_dir: []const u8, cached: *config_mod.Config, name: []const u8) !void {
    if (cwd.len == 0) return error.ProjectPathUnavailable;
    var global = try config_mod.readGlobal(gpa, io, home_dir);
    defer global.deinit(gpa);
    for (global.plugins) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return error.GlobalPluginPreference;
    }
    var next: std.ArrayList(config_mod.PluginConfig) = .empty;
    errdefer {
        for (next.items) |*entry| entry.deinit(gpa);
        next.deinit(gpa);
    }
    for (cached.plugins) |entry| {
        if (std.mem.eql(u8, entry.name, name)) continue;
        var copy = try entry.clone(gpa);
        errdefer copy.deinit(gpa);
        try next.append(gpa, copy);
    }
    const plugins = try next.toOwnedSlice(gpa);
    errdefer deinitPluginConfigs(gpa, plugins);
    try config_mod.removeProjectPlugin(gpa, io, cwd, name);
    deinitPluginConfigs(gpa, cached.plugins);
    cached.plugins = plugins;
}

test "missing plugin removal clears disk and cached preferences and preserves other plugins" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const project = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "project" });
    defer gpa.free(project);
    const home = try std.fs.path.join(gpa, &.{ project, "home" });
    defer gpa.free(home);
    var entries = [_]config_mod.PluginConfig{
        .{ .name = @constCast("missing"), .enabled = false },
        .{ .name = @constCast("keep"), .enabled = true },
    };
    const original: config_mod.Config = .{ .plugins = &entries };
    try config_mod.writeProject(gpa, io, project, original);
    var cached = try original.clone(gpa);
    defer cached.deinit(gpa);
    try config_mod.writeGlobal(gpa, io, home, original);
    try std.testing.expectError(error.GlobalPluginPreference, forgetMissingPluginConfig(gpa, io, project, home, &cached, "missing"));
    try std.testing.expectEqual(@as(usize, 2), cached.plugins.len);
    try config_mod.writeGlobal(gpa, io, home, .{});
    try forgetMissingPluginConfig(gpa, io, project, home, &cached, "missing");
    try std.testing.expectEqual(@as(usize, 1), cached.plugins.len);
    try std.testing.expectEqualStrings("keep", cached.plugins[0].name);
    var disk = try config_mod.readProject(gpa, io, project);
    defer disk.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), disk.plugins.len);
    try std.testing.expectEqualStrings("keep", disk.plugins[0].name);
    try forgetMissingPluginConfig(gpa, io, project, home, &cached, "missing");
    try std.testing.expectEqual(@as(usize, 1), cached.plugins.len);
}

pub fn startUninstall(app: *App, selected_path: []const u8) !void {
    if (app.plugin_store.operation != .idle) return error.PluginOperationBusy;
    var selected: ?*const package.Package = null;
    for (app.plugin_store.inventory.packages) |*disk| if (paths.pathsEqual(disk.path, selected_path)) {
        selected = disk;
        break;
    };
    const disk = selected orelse return error.PluginNotFound;
    if (disk.origin != .global) return error.ProjectPluginNotStoreManaged;
    if (!disk.ordinary_directory or disk.receipt == null) return error.UnmanagedInstallation;
    if (configuredEnabled(&app.cached_config, disk.name())) return error.DisableAndRestartFirst;
    if (app.plugin_manager.get(disk.name()) != null) return error.RestartRequired;
    const root = std.fs.path.dirname(disk.path) orelse return error.InvalidPluginName;
    const worker = try app.gpa.create(UninstallWorker);
    errdefer app.gpa.destroy(worker);
    const root_copy = try app.gpa.dupe(u8, root);
    errdefer app.gpa.free(root_copy);
    const directory = try app.gpa.dupe(u8, disk.directory);
    errdefer app.gpa.free(directory);
    const fingerprint_copy = try app.gpa.dupe(u8, disk.receipt.?.value.fingerprint);
    errdefer app.gpa.free(fingerprint_copy);
    worker.* = .{ .gpa = app.gpa, .io = app.io, .root = root_copy, .directory = directory, .fingerprint = fingerprint_copy };
    app.plugin_store.operation = .{ .uninstalling = .{ .job = .{} } };
    app.plugin_store.operation.uninstalling.job.spawn(app.io, worker, runUninstall) catch |err| {
        app.plugin_store.operation = .idle;
        return err;
    };
}

const UninstallWorker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []u8,
    directory: []u8,
    fingerprint: []u8,

    fn deinit(self: *UninstallWorker) void {
        self.gpa.free(self.root);
        self.gpa.free(self.directory);
        self.gpa.free(self.fingerprint);
        self.gpa.destroy(self);
    }
};

fn runUninstall(worker: *UninstallWorker) UninstallResult {
    defer worker.deinit();
    // Allocate the result before deletion so OOM cannot turn a committed
    // removal into a pre-commit failure or erase the selected identity.
    const directory = worker.gpa.dupe(u8, worker.directory) catch return .{ .failed = &.{} };
    package.remove(worker.gpa, worker.io, worker.root, worker.directory, worker.fingerprint) catch |err| {
        worker.gpa.free(directory);
        return .{ .failed = failureMessage(worker.gpa, "Plugin removal failed", err) };
    };
    return .{ .removed = directory };
}

fn clonePluginConfigsWithEnabled(
    gpa: std.mem.Allocator,
    current: []const config_mod.PluginConfig,
    name: []const u8,
    enabled: bool,
) ![]config_mod.PluginConfig {
    var found = false;
    for (current) |entry| if (std.mem.eql(u8, entry.name, name)) {
        found = true;
        break;
    };
    const next = try gpa.alloc(config_mod.PluginConfig, current.len + @intFromBool(!found));
    var initialized: usize = 0;
    errdefer {
        for (next[0..initialized]) |*entry| entry.deinit(gpa);
        gpa.free(next);
    }
    for (current, 0..) |entry, index| {
        next[index] = try entry.clone(gpa);
        if (std.mem.eql(u8, entry.name, name)) next[index].enabled = enabled;
        initialized += 1;
    }
    if (!found) {
        next[initialized] = .{ .name = try gpa.dupe(u8, name), .enabled = enabled };
        initialized += 1;
    }
    return next;
}

fn deinitPluginConfigs(gpa: std.mem.Allocator, plugins: []config_mod.PluginConfig) void {
    for (plugins) |*entry| entry.deinit(gpa);
    gpa.free(plugins);
}

const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []u8,
    project_root: []u8,
    catalog_source: []u8 = &.{},
    plugin_id: []u8 = &.{},
    fingerprint: [32]u8 = @splat(0),

    fn deinit(self: *Worker) void {
        self.gpa.free(self.home_dir);
        self.gpa.free(self.project_root);
        if (self.catalog_source.len > 0) self.gpa.free(self.catalog_source);
        if (self.plugin_id.len > 0) self.gpa.free(self.plugin_id);
        self.gpa.destroy(self);
    }
};

fn runRefresh(worker: *Worker) RefreshResult {
    const gpa = worker.gpa;
    defer worker.deinit();
    var inventory = package.loadInventory(gpa, worker.io, worker.home_dir, worker.project_root) catch |err| {
        return .{ .failed = failureMessage(gpa, "Plugin inventory refresh failed", err) };
    };
    const catalogs = plugin_store.loadCatalogs(gpa, worker.io, worker.home_dir, worker.project_root) catch |err| {
        inventory.deinit(gpa);
        return .{ .failed = failureMessage(gpa, "Plugin store refresh failed", err) };
    };
    return .{ .ready = .{ .catalogs = catalogs, .inventory = inventory } };
}

fn runInventory(worker: *Worker) InventoryResult {
    defer worker.deinit();
    const inventory = package.loadInventory(worker.gpa, worker.io, worker.home_dir, worker.project_root) catch |err| {
        return .{ .failed = failureMessage(worker.gpa, "Plugin inventory refresh failed", err) };
    };
    return .{ .ready = inventory };
}

fn startInventory(app: *App) !void {
    if (app.plugin_store.operation != .idle) return;
    const runtime = app.liveRuntime() orelse app.templateRuntime() orelse return;
    try repoint(app, runtime.cwd);
    const worker = try makeWorker(app, runtime.home_dir, runtime.cwd, null);
    errdefer worker.deinit();
    app.plugin_store.operation = .{ .scanning = .{ .job = .{}, .generation = app.plugin_store.generation } };
    app.plugin_store.operation.scanning.job.spawn(app.io, worker, runInventory) catch |err| {
        app.plugin_store.operation = .idle;
        return err;
    };
}

fn runInstall(worker: *Worker) InstallResult {
    const gpa = worker.gpa;
    defer worker.deinit();
    const report = plugin_store.installSelected(
        gpa,
        worker.io,
        worker.home_dir,
        worker.project_root,
        worker.catalog_source,
        worker.plugin_id,
        worker.fingerprint,
    ) catch |err| {
        return .{ .failed = failureMessage(gpa, "Plugin installation failed", err) };
    };
    return .{ .complete = report };
}

pub fn startRefresh(app: *App) !void {
    if (app.plugin_store.operation != .idle) return;
    const runtime = app.liveRuntime() orelse app.templateRuntime() orelse {
        setNotice(app, "Could not refresh plugin store: no active runtime.");
        return;
    };
    if (runtime.home_dir.len == 0 or runtime.cwd.len == 0) {
        setNotice(app, "Could not refresh plugin store: project paths are unavailable.");
        return;
    }

    try repoint(app, runtime.cwd);
    const worker = makeWorker(app, runtime.home_dir, runtime.cwd, null) catch |err| {
        setErrorNotice(app, "Could not start plugin store refresh", err);
        return err;
    };
    errdefer worker.deinit();
    app.plugin_store.operation = .{ .refreshing = .{ .job = .{}, .generation = app.plugin_store.generation } };
    app.plugin_store.operation.refreshing.job.spawn(app.io, worker, runRefresh) catch |err| {
        app.plugin_store.operation = .idle;
        setErrorNotice(app, "Could not start plugin store refresh", err);
        return err;
    };
}

pub fn startInstall(app: *App) !void {
    if (app.plugin_store.operation != .idle) return;
    if (app.pickers.plugins.view != .store) return;
    if (app.plugin_store.catalogs == null) {
        setNotice(app, "Plugin catalog is not ready yet. Press r to refresh.");
        return;
    }
    const runtime = app.liveRuntime() orelse app.templateRuntime() orelse {
        setNotice(app, "Could not install plugin: no active runtime.");
        return;
    };
    if (runtime.home_dir.len == 0 or runtime.cwd.len == 0) {
        setNotice(app, "Could not install plugin: project paths are unavailable.");
        return;
    }

    const selection = app.pickers.plugins.selection;
    const count = app.plugin_store.catalogs.?.entryCount();
    if (selection >= count) {
        setNotice(app, "Could not install plugin: no plugin is selected.");
        return;
    }

    const entry = app.plugin_store.catalogs.?.entryAt(selection) orelse {
        setNotice(app, "Could not install plugin: selection is no longer available.");
        return;
    };
    const worker = makeWorker(app, runtime.home_dir, runtime.cwd, entry) catch |err| {
        setErrorNotice(app, "Could not start plugin installation", err);
        return err;
    };
    errdefer worker.deinit();
    app.plugin_store.operation = .{ .installing = .{ .job = .{} } };
    app.plugin_store.operation.installing.job.spawn(app.io, worker, runInstall) catch |err| {
        app.plugin_store.operation = .idle;
        setErrorNotice(app, "Could not start plugin installation", err);
        return err;
    };
}

pub fn addStore(app: *App, raw_url: []const u8) !void {
    const url = std.mem.trim(u8, raw_url, " \t\r\n");
    if (url.len == 0) {
        setNotice(app, "Store URL cannot be empty.");
        return;
    }
    const runtime = app.liveRuntime() orelse app.templateRuntime() orelse {
        setNotice(app, "Could not add store: no active runtime.");
        return;
    };

    plugin_store.addStoreUrl(app.gpa, app.io, runtime.home_dir, url) catch |err| {
        const message = std.fmt.allocPrint(app.gpa, "Could not add store: {s}", .{@errorName(err)}) catch null;
        if (message) |owned| takeNotice(app, owned) else setNotice(app, "Could not add store.");
        return err;
    };
    setNotice(app, "Store added; refreshing catalog...");
    try startRefresh(app);
}

pub fn drain(app: *App) !bool {
    switch (app.plugin_store.operation) {
        .idle => return false,
        .refreshing => |*refresh| {
            if (!refresh.job.isDone()) return false;
            const generation = refresh.generation;
            var result = refresh.job.adopt(app.io);
            app.plugin_store.operation = .idle;
            if (generation != app.plugin_store.generation) {
                result.deinit(app.gpa);
                try startRefresh(app);
                return true;
            }
            switch (result) {
                .ready => |snapshot| {
                    const selection = refreshedSelection(app, &snapshot.inventory, &snapshot.catalogs);
                    if (app.plugin_store.catalogs) |*old| old.deinit(app.gpa);
                    app.plugin_store.catalogs = snapshot.catalogs;
                    app.plugin_store.inventory.deinit(app.gpa);
                    app.plugin_store.inventory = snapshot.inventory;
                    app.pickers.plugins.reset();
                    app.pickers.plugins.selection = selection;
                    app.pickers.plugins.confirming_uninstall = false;
                    if (snapshot.catalogs.failures.len == 0) {
                        setNotice(app, "Catalog refreshed.");
                    } else {
                        const failure = snapshot.catalogs.failures[0];
                        const message = std.fmt.allocPrint(app.gpa, "Store failed ({s}): {s}. Cached entries are stale; press r to retry.", .{ failure.message, failure.source }) catch null;
                        if (message) |owned| takeNotice(app, owned) else setNotice(app, "Some stores failed; press r to retry.");
                    }
                },
                .failed => |message| takeNotice(app, message),
            }
            return true;
        },
        .scanning => |*scan| {
            if (!scan.job.isDone()) return false;
            const generation = scan.generation;
            var result = scan.job.adopt(app.io);
            app.plugin_store.operation = .idle;
            if (generation != app.plugin_store.generation) {
                result.deinit(app.gpa);
                try startInventory(app);
                return true;
            }
            switch (result) {
                .ready => |inventory| {
                    const selection = refreshedSelection(app, &inventory, if (app.plugin_store.catalogs) |*catalogs| catalogs else null);
                    app.plugin_store.inventory.deinit(app.gpa);
                    app.plugin_store.inventory = inventory;
                    app.pickers.plugins.reset();
                    app.pickers.plugins.selection = selection;
                    app.pickers.plugins.confirming_uninstall = false;
                },
                .failed => |message| takeNotice(app, message),
            }
            return true;
        },
        .installing => |*install| {
            if (!install.job.isDone()) return false;
            var result = install.job.adopt(app.io);
            app.plugin_store.operation = .idle;
            switch (result) {
                .complete => |*report| {
                    const message = switch (report.status) {
                        .installed => std.fmt.allocPrint(app.gpa, "Installed {s} {s}; restart Zay to load it.", .{ report.name, report.version }) catch null,
                        .already_installed => std.fmt.allocPrint(app.gpa, "{s} {s} is already installed.", .{ report.name, report.version }) catch null,
                    };
                    if (message) |owned| takeNotice(app, owned) else setNotice(app, "Plugin installation completed.");
                    report.deinit(app.gpa);
                },
                .failed => |message| takeNotice(app, message),
            }
            try startInventory(app);
            return true;
        },
        .uninstalling => |*removal| {
            if (!removal.job.isDone()) return false;
            var result = removal.job.adopt(app.io);
            app.plugin_store.operation = .idle;
            switch (result) {
                .removed => |name| {
                    // Global removal leaves every project's preferences intact.
                    const message = std.fmt.allocPrint(app.gpa, "Removed {s}; project preferences retained.", .{name}) catch null;
                    if (message) |owned| takeNotice(app, owned) else setNotice(app, "Plugin removed; project preferences retained.");
                    if (name.len > 0) app.gpa.free(name);
                    result.removed = &.{};
                },
                .failed => |message| {
                    takeNotice(app, message);
                    result.failed = &.{};
                },
            }
            result.deinit(app.gpa);
            try startInventory(app);
            return true;
        },
    }
}

/// Resolve selection against the new snapshot while the old identities are
/// still alive. Confirmation always resets even when the row survives.
fn refreshedSelection(app: *const App, inventory: *const package.Inventory, catalogs: ?*const plugin_store.CatalogBundle) usize {
    const selection = app.pickers.plugins.selection;
    switch (app.pickers.plugins.view) {
        .installed => {
            if (selection >= app.plugin_store.inventory.packages.len) return 0;
            const path = app.plugin_store.inventory.packages[selection].path;
            for (inventory.packages, 0..) |disk, index| {
                if (paths.pathsEqual(path, disk.path)) return index;
            }
        },
        .store => {
            const old = if (app.plugin_store.catalogs) |*bundle| bundle.entryAt(selection) orelse return 0 else return 0;
            const next = catalogs orelse return 0;
            for (0..next.entryCount()) |index| {
                const entry = next.entryAt(index).?;
                if (std.mem.eql(u8, old.catalog_source, entry.catalog_source) and std.mem.eql(u8, old.plugin.id, entry.plugin.id)) return index;
            }
        },
        .sources => {
            const old = if (app.plugin_store.catalogs) |*bundle| bundle else return 0;
            if (selection >= old.stores.len) return 0;
            const next = catalogs orelse return 0;
            for (next.stores, 0..) |source, index| {
                if (std.mem.eql(u8, old.stores[selection].url, source.url)) return index;
            }
        },
    }
    return 0;
}

test "inventory refresh preserves selected physical copy across row changes" {
    const first: package.Package = .{ .directory = @constCast("first"), .path = @constCast("/plugins/first"), .origin = .global };
    const selected: package.Package = .{ .directory = @constCast("selected"), .path = @constCast("/plugins/selected"), .origin = .global };
    var old_packages = [_]package.Package{ first, selected };
    var next_packages = [_]package.Package{ selected, first };
    var app: App = undefined;
    app.plugin_store = .{ .inventory = .{ .packages = &old_packages } };
    app.pickers.plugins = .{ .view = .installed, .selection = 1 };
    const inventory: package.Inventory = .{ .packages = &next_packages };
    try std.testing.expectEqual(@as(usize, 0), refreshedSelection(&app, &inventory, null));
    app.pickers.plugins.selection = 0;
    try std.testing.expectEqual(@as(usize, 1), refreshedSelection(&app, &inventory, null));
    const empty: package.Inventory = .{};
    try std.testing.expectEqual(@as(usize, 0), refreshedSelection(&app, &empty, null));
}

pub fn cancel(app: *App) void {
    switch (app.plugin_store.operation) {
        .idle => {},
        .scanning => |*scan| {
            var result = scan.job.cancel(app.io);
            result.deinit(app.gpa);
            app.plugin_store.operation = .idle;
        },
        .refreshing => |*refresh| {
            var result = refresh.job.cancel(app.io);
            result.deinit(app.gpa);
            app.plugin_store.operation = .idle;
        },
        .installing => |*install| {
            var result = install.job.cancel(app.io);
            result.deinit(app.gpa);
            app.plugin_store.operation = .idle;
        },
        .uninstalling => |*removal| {
            var result = removal.job.cancel(app.io);
            result.deinit(app.gpa);
            app.plugin_store.operation = .idle;
        },
    }
}

pub fn active(app: *const App) bool {
    return app.plugin_store.operation != .idle;
}

fn makeWorker(app: *App, home_dir: []const u8, project_root: []const u8, entry: ?plugin_store.Entry) !*Worker {
    const worker = try app.gpa.create(Worker);
    errdefer app.gpa.destroy(worker);
    const home_copy = try app.gpa.dupe(u8, home_dir);
    errdefer app.gpa.free(home_copy);
    const project_copy = try app.gpa.dupe(u8, project_root);
    errdefer app.gpa.free(project_copy);
    const catalog_source: []u8 = if (entry) |selected| try app.gpa.dupe(u8, selected.catalog_source) else &.{};
    errdefer if (catalog_source.len > 0) app.gpa.free(catalog_source);
    const plugin_id: []u8 = if (entry) |selected| try app.gpa.dupe(u8, selected.plugin.id) else &.{};
    errdefer if (plugin_id.len > 0) app.gpa.free(plugin_id);
    worker.* = .{
        .gpa = app.gpa,
        .io = app.io,
        .home_dir = home_copy,
        .project_root = project_copy,
        .catalog_source = catalog_source,
        .plugin_id = plugin_id,
        .fingerprint = if (entry) |selected| plugin_store.fingerprint(selected.plugin) else @splat(0),
    };
    return worker;
}

fn failureMessage(gpa: std.mem.Allocator, prefix: []const u8, err: anyerror) []u8 {
    return std.fmt.allocPrint(gpa, "{s}: {s}", .{ prefix, @errorName(err) }) catch
        gpa.dupe(u8, prefix) catch &.{};
}

fn setNotice(app: *App, message: []const u8) void {
    const copy = app.gpa.dupe(u8, message) catch return;
    takeNotice(app, copy);
}

fn setErrorNotice(app: *App, prefix: []const u8, err: anyerror) void {
    const message = std.fmt.allocPrint(app.gpa, "{s}: {s}", .{ prefix, @errorName(err) }) catch null;
    if (message) |owned| takeNotice(app, owned) else setNotice(app, prefix);
}

fn takeNotice(app: *App, message: []u8) void {
    if (app.plugin_store.notice) |old| app.gpa.free(old);
    app.plugin_store.notice = if (message.len > 0) message else null;
}
