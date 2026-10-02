//! TUI lifecycle for plugin-store refresh and installation jobs.
//!
//! The worker owns only copied paths and store I/O. Adoption updates a pure
//! catalog snapshot; it never calls PluginManager or mutates the live tool
//! registry. Installed plugins therefore become available at the next runtime
//! load, which preserves the Lua-state/tool-record lifetime invariant.

const std = @import("std");
const plugin_store = @import("../plugin_store.zig");
const job_mod = @import("job.zig");
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

pub const Operation = union(enum) {
    idle,
    refreshing: struct { job: job_mod.Job(RefreshResult) },
    installing: struct { job: job_mod.Job(InstallResult) },
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
    const runtime = app.liveRuntime() orelse app.templateRuntime() orelse return;
    if (runtime.home_dir.len == 0 or runtime.cwd.len == 0) return;

    const worker = try makeWorker(app, runtime.home_dir, runtime.cwd, null);
    errdefer worker.deinit();
    app.plugin_store.operation = .{ .refreshing = .{ .job = .{} } };
    app.plugin_store.operation.refreshing.job.spawn(app.io, worker, runRefresh) catch |err| {
        app.plugin_store.operation = .idle;
        return err;
    };
}

pub fn startInstall(app: *App) !void {
    if (app.plugin_store.operation != .idle) return;
    if (app.pickers.plugins.view != .store) return;
    if (app.plugin_store.catalogs == null) return;
    const runtime = app.liveRuntime() orelse app.templateRuntime() orelse return;
    if (runtime.home_dir.len == 0 or runtime.cwd.len == 0) return;

    const selection = app.pickers.plugins.selection;
    const count = app.plugin_store.catalogs.?.entryCount();
    if (selection >= count) return;

    const entry = app.plugin_store.catalogs.?.entryAt(selection) orelse return;
    const worker = try makeWorker(app, runtime.home_dir, runtime.cwd, entry);
    errdefer worker.deinit();
    app.plugin_store.operation = .{ .installing = .{ .job = .{} } };
    app.plugin_store.operation.installing.job.spawn(app.io, worker, runInstall) catch |err| {
        app.plugin_store.operation = .idle;
        return err;
    };
}

pub fn addStore(app: *App, raw_url: []const u8) !void {
    const runtime = app.liveRuntime() orelse app.templateRuntime() orelse return;
    const url = std.mem.trim(u8, raw_url, " \t\r\n");
    if (url.len == 0) return;

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
                        .installed => std.fmt.allocPrint(app.gpa, "Installed {s} {s}; restart or start a new session to load it.", .{ report.name, report.version }) catch null,
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

fn takeNotice(app: *App, message: []u8) void {
    if (app.plugin_store.notice) |old| app.gpa.free(old);
    app.plugin_store.notice = if (message.len > 0) message else null;
}
