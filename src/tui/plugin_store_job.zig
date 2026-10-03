//! TUI lifecycle for plugin-store refresh and installation jobs.
//!
//! The worker owns only copied paths and store I/O. Adoption updates a pure
//! catalog snapshot; it never calls PluginManager or mutates the live tool
//! registry. Installed plugins therefore become available at the next runtime
//! load, which preserves the Lua-state/tool-record lifetime invariant.

const std = @import("std");
const plugin_store = @import("../plugin_store.zig");
const config_mod = @import("../config/config.zig");
const job_mod = @import("job.zig");
const paths = @import("../paths.zig");
const tui = @import("../tui.zig");

const App = tui.App;

pub const RefreshResult = union(enum) {
    ready: plugin_store.CatalogBundle,
    failed: []u8,

    fn deinit(self: *RefreshResult, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |*bundle| bundle.deinit(gpa),
            .failed => |message| if (message.len > 0) gpa.free(message),
        }
        self.* = undefined;
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
};

pub const Operation = union(enum) {
    idle,
    refreshing: struct { job: job_mod.Job(RefreshResult) },
    installing: struct { job: job_mod.Job(InstallResult) },
    uninstalling: struct { job: job_mod.Job(UninstallResult) },
};

pub const State = struct {
    catalogs: ?plugin_store.CatalogBundle = null,
    operation: Operation = .idle,
    notice: ?[]u8 = null,

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        std.debug.assert(self.operation == .idle);
        if (self.catalogs) |*bundle| bundle.deinit(gpa);
        if (self.notice) |message| gpa.free(message);
        self.* = undefined;
    }
};

/// Build the Installed-tab rows from loaded plugins plus persisted disabled
/// entries. Disabled plugins are intentionally absent from PluginManager.
pub fn installedPlugins(gpa: std.mem.Allocator, app: *App) ![]InstalledPlugin {
    var rows: std.ArrayList(InstalledPlugin) = .empty;
    errdefer rows.deinit(gpa);

    var iter = app.plugin_manager.iterator();
    while (iter.next()) |entry| {
        const name = entry.value_ptr.*.manifest.name;
        try rows.append(gpa, .{
            .name = name,
            .active = entry.value_ptr.*.active,
            .enabled = configuredEnabled(&app.cached_config, name),
        });
    }
    for (app.cached_config.plugins) |configured| {
        if (configured.enabled or app.plugin_manager.get(configured.name) != null) continue;
        try rows.append(gpa, .{ .name = configured.name, .active = false, .enabled = false });
    }
    return rows.toOwnedSlice(gpa);
}

pub fn configuredEnabled(config: *const config_mod.Config, name: []const u8) bool {
    for (config.plugins) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.enabled;
    }
    return true;
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
            error.PluginNotFound => "No global Store install found; project plugins are kept by Store removal.",
            error.InvalidPluginName => "Could not remove plugin: invalid plugin name.",
            error.PluginOperationBusy => "Another plugin operation is already in progress.",
            error.ProjectPathUnavailable, error.NoActiveRuntime => "Could not remove plugin: project paths are unavailable.",
            else => "Could not start plugin removal.",
        };
        setNotice(app, message);
    };
}

pub fn startUninstall(app: *App, name: []const u8) !void {
    if (app.plugin_store.operation != .idle) return error.PluginOperationBusy;
    if (isProjectPlugin(app, name)) return error.ProjectPluginNotStoreManaged;
    if (configuredEnabled(&app.cached_config, name)) return error.DisableAndRestartFirst;
    if (app.plugin_manager.get(name) != null) return error.RestartRequired;

    const runtime = app.liveRuntime() orelse app.templateRuntime() orelse return error.NoActiveRuntime;
    if (runtime.home_dir.len == 0 or runtime.cwd.len == 0) return error.ProjectPathUnavailable;
    if (!safePluginDirectoryName(name)) return error.InvalidPluginName;

    const plugin_dir = findPluginDirectory(app, runtime.home_dir, name) orelse return error.PluginNotFound;
    const worker = app.gpa.create(UninstallWorker) catch |err| {
        app.gpa.free(plugin_dir);
        return err;
    };
    const name_copy = app.gpa.dupe(u8, name) catch |err| {
        app.gpa.destroy(worker);
        app.gpa.free(plugin_dir);
        return err;
    };
    worker.* = .{ .gpa = app.gpa, .io = app.io, .name = name_copy, .plugin_dir = plugin_dir };

    app.plugin_store.operation = .{ .uninstalling = .{ .job = .{} } };
    app.plugin_store.operation.uninstalling.job.spawn(app.io, worker, runUninstall) catch |err| {
        app.plugin_store.operation = .idle;
        worker.deinit();
        return err;
    };
}

const UninstallWorker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []u8,
    plugin_dir: []u8,

    fn deinit(self: *UninstallWorker) void {
        self.gpa.free(self.name);
        self.gpa.free(self.plugin_dir);
        self.gpa.destroy(self);
    }
};

fn runUninstall(worker: *UninstallWorker) UninstallResult {
    defer worker.deinit();
    std.Io.Dir.deleteTree(.cwd(), worker.io, worker.plugin_dir) catch |err| {
        return .{ .failed = std.fmt.allocPrint(worker.gpa, "Could not remove {s}: {s}", .{ worker.name, @errorName(err) }) catch &.{} };
    };
    return .{ .removed = worker.gpa.dupe(u8, worker.name) catch &.{} };
}

fn findPluginDirectory(app: *App, home_dir: []const u8, name: []const u8) ?[]u8 {
    const global_root = paths.globalPluginsDir(app.gpa, app.io, home_dir) catch return null;
    defer app.gpa.free(global_root);
    if (!isOrdinaryPluginDirectory(app.io, global_root, name)) return null;
    const global = std.fs.path.join(app.gpa, &.{ global_root, name }) catch return null;
    if (hasPluginManifest(app.gpa, app.io, global)) return global;
    app.gpa.free(global);
    return null;
}

fn isOrdinaryPluginDirectory(io: std.Io, root_path: []const u8, name: []const u8) bool {
    var root = std.Io.Dir.openDir(.cwd(), io, root_path, .{ .iterate = true }) catch return false;
    defer root.close(io);
    var iter = root.iterate();
    while (iter.next(io) catch return false) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.kind == .directory;
    }
    return false;
}

fn hasPluginManifest(gpa: std.mem.Allocator, io: std.Io, plugin_dir: []const u8) bool {
    const manifest_path = std.fs.path.join(gpa, &.{ plugin_dir, "plugin.lua" }) catch return false;
    defer gpa.free(manifest_path);
    std.Io.Dir.access(.cwd(), io, manifest_path, .{}) catch return false;
    return true;
}

fn safePluginDirectoryName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    }
    return true;
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

fn clonePluginConfigsWithout(
    gpa: std.mem.Allocator,
    current: []const config_mod.PluginConfig,
    name: []const u8,
) ![]config_mod.PluginConfig {
    var found = false;
    for (current) |plugin| if (std.mem.eql(u8, plugin.name, name)) {
        found = true;
        break;
    };
    const next = try gpa.alloc(config_mod.PluginConfig, current.len - @intFromBool(found));
    var initialized: usize = 0;
    errdefer {
        for (next[0..initialized]) |*plugin| plugin.deinit(gpa);
        if (next.len > 0) gpa.free(next);
    }
    for (current) |plugin| {
        if (std.mem.eql(u8, plugin.name, name)) continue;
        next[initialized] = try plugin.clone(gpa);
        initialized += 1;
    }
    return next;
}

const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []u8,
    project_root: []u8,
    catalog_source: []u8 = &.{},
    plugin_id: []u8 = &.{},

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
    const catalogs = plugin_store.loadCatalogs(gpa, worker.io, worker.home_dir, worker.project_root) catch |err| {
        return .{ .failed = failureMessage(gpa, "Plugin store refresh failed", err) };
    };
    return .{ .ready = catalogs };
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

    const worker = makeWorker(app, runtime.home_dir, runtime.cwd, null) catch |err| {
        setErrorNotice(app, "Could not start plugin store refresh", err);
        return err;
    };
    errdefer worker.deinit();
    app.plugin_store.operation = .{ .refreshing = .{ .job = .{} } };
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
            var result = refresh.job.adopt(app.io);
            app.plugin_store.operation = .idle;
            switch (result) {
                .ready => |bundle| {
                    if (app.plugin_store.catalogs) |*old| old.deinit(app.gpa);
                    app.plugin_store.catalogs = bundle;
                    if (app.pickers.plugins.view == .store) app.pickers.plugins.reset();
                    setNotice(app, "Catalog refreshed.");
                },
                .failed => |message| {
                    takeNotice(app, message);
                    result.failed = &.{};
                },
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
                .failed => |message| {
                    takeNotice(app, message);
                    result.failed = &.{};
                },
            }
            return true;
        },
        .uninstalling => |*removal| {
            if (!removal.job.isDone()) return false;
            var result = removal.job.adopt(app.io);
            app.plugin_store.operation = .idle;
            switch (result) {
                .removed => |name| {
                    const runtime = app.liveRuntime() orelse app.templateRuntime();
                    const next_plugins = clonePluginConfigsWithout(app.gpa, app.cached_config.plugins, name) catch null;
                    if (runtime == null or next_plugins == null) {
                        if (next_plugins) |plugins| deinitPluginConfigs(app.gpa, plugins);
                        setNotice(app, "Removed plugin, but could not update its project settings. Restart Zay to reload settings.");
                    } else {
                        config_mod.removeProjectPlugin(app.gpa, app.io, runtime.?.cwd, name) catch |err| {
                            deinitPluginConfigs(app.gpa, next_plugins.?);
                            setErrorNotice(app, "Removed plugin, but could not clear its project setting", err);
                            app.gpa.free(name);
                            result.removed = &.{};
                            result.deinit(app.gpa);
                            return true;
                        };
                        if (app.cached_config.plugins.len > 0) deinitPluginConfigs(app.gpa, app.cached_config.plugins);
                        app.cached_config.plugins = next_plugins.?;
                        const message = std.fmt.allocPrint(app.gpa, "Removed {s}. Restart Zay to finish unloading it.", .{name}) catch null;
                        if (message) |owned| takeNotice(app, owned) else setNotice(app, "Plugin removed. Restart Zay to finish unloading it.");
                    }
                    app.gpa.free(name);
                    result.removed = &.{};
                },
                .failed => |message| {
                    takeNotice(app, message);
                    result.failed = &.{};
                },
            }
            result.deinit(app.gpa);
            return true;
        },
    }
}

pub fn cancel(app: *App) void {
    switch (app.plugin_store.operation) {
        .idle => {},
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
