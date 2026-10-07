//! Plugin-store catalogs and installation.
//!
//! Store files are deliberately small, explicit JSON documents. A catalog may
//! point at a local project-relative demo directory, or describe every remote
//! file by URL. There is no archive extraction or shell command in this path:
//! the boundary validates names, paths, URLs, counts, and byte budgets before
//! anything is staged into the user's global plugin directory.

const std = @import("std");
const http = @import("http.zig");
const paths = @import("paths.zig");
const package = @import("plugin_package.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const log = std.log.scoped(.plugin_store);

pub const default_store_url: []const u8 = "https://raw.githubusercontent.com/ozgurulukir/zay/main/plugins/store.json";

pub const catalog_max_bytes: usize = 2 * 1024 * 1024;
pub const plugin_file_max_bytes: usize = 4 * 1024 * 1024;
pub const plugin_total_max_bytes: usize = 16 * 1024 * 1024;
pub const max_catalog_plugins: usize = 256;
pub const max_plugin_files: usize = 64;
pub const max_store_urls: usize = 32;

pub const Catalog = struct {
    source: []u8,
    name: []u8,
    plugins: []Plugin,
    stale: bool = false,

    pub fn deinit(self: *Catalog, gpa: std.mem.Allocator) void {
        gpa.free(self.source);
        gpa.free(self.name);
        for (self.plugins) |*plugin| plugin.deinit(gpa);
        gpa.free(self.plugins);
        self.* = undefined;
    }
};

pub const CatalogBundle = struct {
    catalogs: []Catalog,
    failures: []StoreFailure = &.{},
    stores: []StoreSource = &.{},

    pub fn deinit(self: *CatalogBundle, gpa: std.mem.Allocator) void {
        for (self.catalogs) |*catalog| catalog.deinit(gpa);
        gpa.free(self.catalogs);
        for (self.failures) |failure| {
            gpa.free(failure.source);
            gpa.free(failure.message);
        }
        if (self.failures.len > 0) gpa.free(self.failures);
        for (self.stores) |*store| store.deinit(gpa);
        if (self.stores.len > 0) gpa.free(self.stores);
        self.* = undefined;
    }

    pub fn entryCount(self: *const CatalogBundle) usize {
        var count: usize = 0;
        for (self.catalogs) |catalog| count += catalog.plugins.len;
        return count;
    }

    pub fn entryAt(self: *const CatalogBundle, index: usize) ?Entry {
        var offset: usize = 0;
        for (self.catalogs, 0..) |catalog, catalog_index| {
            if (index < offset + catalog.plugins.len) {
                const plugin_index = index - offset;
                const plugin = &catalog.plugins[plugin_index];
                return .{
                    .catalog_index = catalog_index,
                    .plugin_index = plugin_index,
                    .catalog_source = catalog.source,
                    .store_name = catalog.name,
                    .plugin = plugin,
                };
            }
            offset += catalog.plugins.len;
        }
        return null;
    }
};

pub const StoreFailure = struct { source: []u8, message: []u8 };

pub const StoreSource = struct {
    url: []u8,
    enabled: bool = true,
    catalog_name: ?[]u8 = null,
    stale: bool = false,
    failure: ?[]u8 = null,

    pub fn deinit(self: *StoreSource, gpa: std.mem.Allocator) void {
        gpa.free(self.url);
        if (self.catalog_name) |name| gpa.free(name);
        if (self.failure) |message| gpa.free(message);
        self.* = undefined;
    }
};

const StoreRegistration = struct { url: []u8, enabled: bool = true };

pub const Entry = struct {
    catalog_index: usize,
    plugin_index: usize,
    catalog_source: []const u8,
    store_name: []const u8,
    plugin: *const Plugin,
};

pub const Plugin = struct {
    id: []u8,
    name: []u8,
    version: []u8,
    description: []u8,
    source: Source,

    pub fn deinit(self: *Plugin, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.version);
        gpa.free(self.description);
        self.source.deinit(gpa);
        self.* = undefined;
    }
};

pub const Source = union(enum) {
    local_dir: []u8,
    files: []File,

    pub fn deinit(self: *Source, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .local_dir => |dir| gpa.free(dir),
            .files => |files| {
                for (files) |*file| file.deinit(gpa);
                gpa.free(files);
            },
        }
        self.* = undefined;
    }
};

pub const File = struct {
    path: []u8,
    url: []u8,
    sha256: ?[32]u8 = null,
    size: ?usize = null,

    fn deinit(self: *File, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.url);
        self.* = undefined;
    }
};

pub const InstallStatus = enum { installed, already_installed };

pub const InstallReport = struct {
    status: InstallStatus,
    name: []u8,
    version: []u8,

    pub fn deinit(self: *InstallReport, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.version);
        self.* = undefined;
    }
};

/// Load the checked-in catalog when running from a Zay checkout, otherwise
/// fetch the same catalog from GitHub, then load every user-configured remote
/// catalog. A missing default catalog is best-effort so users can still add a
/// store while offline; malformed configured catalogs remain visible errors.
pub fn loadCatalogs(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    project_root: []const u8,
) !CatalogBundle {
    var catalogs: std.ArrayList(Catalog) = .empty;
    errdefer deinitCatalogs(gpa, &catalogs);
    var failures: std.ArrayList(StoreFailure) = .empty;
    errdefer {
        for (failures.items) |failure| {
            gpa.free(failure.source);
            gpa.free(failure.message);
        }
        failures.deinit(gpa);
    }
    const local_path = try std.fs.path.join(gpa, &.{ project_root, "plugins", "store.json" });
    defer gpa.free(local_path);
    const primary = if (pathExists(io, local_path)) local_path else default_store_url;
    try appendSource(gpa, io, home_dir, project_root, primary, &catalogs, &failures);
    var registrations = loadStoreRegistrations(gpa, io, home_dir) catch |err| blk: {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        try appendFailure(gpa, &failures, "plugin-stores.json", err);
        break :blk std.ArrayList(StoreRegistration).empty;
    };
    defer deinitStoreRegistrations(gpa, &registrations);
    for (registrations.items) |registration| {
        if (registration.enabled) try appendSource(gpa, io, home_dir, project_root, registration.url, &catalogs, &failures);
    }
    var stores: std.ArrayList(StoreSource) = .empty;
    errdefer {
        for (stores.items) |*store| store.deinit(gpa);
        stores.deinit(gpa);
    }
    for (registrations.items) |registration| {
        var store: StoreSource = .{ .url = try gpa.dupe(u8, registration.url), .enabled = registration.enabled };
        var store_transferred = false;
        errdefer if (!store_transferred) store.deinit(gpa);
        if (!registration.enabled) {
            try stores.append(gpa, store);
            store_transferred = true;
            continue;
        }
        for (catalogs.items) |catalog| {
            if (!std.mem.eql(u8, catalog.source, registration.url)) continue;
            store.catalog_name = try gpa.dupe(u8, catalog.name);
            store.stale = catalog.stale;
            break;
        }
        for (failures.items) |failure| {
            if (!std.mem.eql(u8, failure.source, registration.url)) continue;
            store.failure = try gpa.dupe(u8, failure.message);
            break;
        }
        try stores.append(gpa, store);
        store_transferred = true;
    }
    const owned_catalogs = try catalogs.toOwnedSlice(gpa);
    errdefer {
        for (owned_catalogs) |*catalog| catalog.deinit(gpa);
        gpa.free(owned_catalogs);
    }
    const owned_failures = try failures.toOwnedSlice(gpa);
    errdefer {
        for (owned_failures) |failure| {
            gpa.free(failure.source);
            gpa.free(failure.message);
        }
        gpa.free(owned_failures);
    }
    const owned_stores = try stores.toOwnedSlice(gpa);
    return .{ .catalogs = owned_catalogs, .failures = owned_failures, .stores = owned_stores };
}

fn appendFailure(gpa: std.mem.Allocator, failures: *std.ArrayList(StoreFailure), source: []const u8, err: anyerror) !void {
    const source_copy = try gpa.dupe(u8, source);
    errdefer gpa.free(source_copy);
    const message = try gpa.dupe(u8, @errorName(err));
    errdefer gpa.free(message);
    try failures.append(gpa, .{ .source = source_copy, .message = message });
}

fn cachePath(gpa: std.mem.Allocator, home: []const u8, source: []const u8) ![]u8 {
    const base = try paths.platformConfigDir(gpa, home);
    defer gpa.free(base);
    var digest: [32]u8 = undefined;
    Sha256.hash(source, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(gpa, "{s}/plugin-store-cache/{s}.json", .{ base, hex });
}

fn loadSource(gpa: std.mem.Allocator, io: std.Io, home: ?[]const u8, project: []const u8, source: []const u8) !Catalog {
    const local = try std.fs.path.join(gpa, &.{ project, "plugins", "store.json" });
    defer gpa.free(local);
    const is_local = paths.pathsEqual(source, local);
    const bytes = if (is_local) try readFile(gpa, io, source, catalog_max_bytes) else try fetchHttp(gpa, io, source, catalog_max_bytes);
    defer gpa.free(bytes);
    var catalog = try parseCatalog(gpa, source, bytes, project, is_local);
    errdefer catalog.deinit(gpa);
    if (!is_local) if (home) |home_dir| {
        const cache = try cachePath(gpa, home_dir, source);
        defer gpa.free(cache);
        package.atomicWrite(io, cache, bytes) catch |err| {
            if (err == error.Canceled) return err;
            log.warn("catalog_cache_write_failed reason={s}", .{@errorName(err)});
        };
    };
    return catalog;
}

fn appendSource(gpa: std.mem.Allocator, io: std.Io, home: []const u8, project: []const u8, source: []const u8, catalogs: *std.ArrayList(Catalog), failures: *std.ArrayList(StoreFailure)) !void {
    var catalog = loadSource(gpa, io, home, project, source) catch |err| blk: {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        try appendFailure(gpa, failures, source, err);
        if (!std.mem.startsWith(u8, source, "https://") and !std.mem.startsWith(u8, source, "http://")) return;
        const cached = try cachePath(gpa, home, source);
        defer gpa.free(cached);
        const bytes = readFile(gpa, io, cached, catalog_max_bytes) catch |cache_err| {
            if (cache_err == error.OutOfMemory or cache_err == error.Canceled) return cache_err;
            return;
        };
        defer gpa.free(bytes);
        var value = parseCatalog(gpa, source, bytes, project, false) catch |cache_err| {
            if (cache_err == error.OutOfMemory or cache_err == error.Canceled) return cache_err;
            return;
        };
        value.stale = true;
        break :blk value;
    };
    errdefer catalog.deinit(gpa);
    try catalogs.append(gpa, catalog);
}

/// Add a remote store URL to the global store list. Re-adding the same URL is
/// intentionally a no-op, so key repeats and startup migrations converge.
pub fn addStoreUrl(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    raw_url: []const u8,
) !void {
    const url = std.mem.trim(u8, raw_url, " \t\r\n");
    try validateHttpUrl(url);
    if (std.mem.eql(u8, url, default_store_url)) return;

    const base = try paths.platformConfigDir(gpa, home_dir);
    defer gpa.free(base);
    const guard = try package.lock(gpa, io, base, "plugin-stores");
    defer guard.close(io);

    var registrations = try loadStoreRegistrations(gpa, io, home_dir);
    defer deinitStoreRegistrations(gpa, &registrations);
    for (registrations.items) |*existing| {
        if (std.mem.eql(u8, existing.url, url)) {
            existing.enabled = true;
            try writeStoreRegistrations(gpa, io, home_dir, registrations.items);
            return;
        }
    }
    if (registrations.items.len >= max_store_urls) return error.TooManyStores;
    const url_copy = try gpa.dupe(u8, url);
    var appended = false;
    errdefer if (!appended) gpa.free(url_copy);
    try registrations.append(gpa, .{ .url = url_copy });
    appended = true;
    try writeStoreRegistrations(gpa, io, home_dir, registrations.items);
}

pub fn removeStoreUrl(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, url: []const u8) !void {
    const base = try paths.platformConfigDir(gpa, home_dir);
    defer gpa.free(base);
    const guard = try package.lock(gpa, io, base, "plugin-stores");
    defer guard.close(io);
    var registrations = try loadStoreRegistrations(gpa, io, home_dir);
    defer deinitStoreRegistrations(gpa, &registrations);
    for (registrations.items, 0..) |existing, index| {
        if (!std.mem.eql(u8, existing.url, url)) continue;
        gpa.free(registrations.orderedRemove(index).url);
        try writeStoreRegistrations(gpa, io, home_dir, registrations.items);
        const cached = try cachePath(gpa, home_dir, url);
        defer gpa.free(cached);
        std.Io.Dir.deleteFile(.cwd(), io, cached) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {},
            else => log.warn("plugin_store.cache.remove_failed source={s} err={s}", .{ url, @errorName(err) }),
        };
        return;
    }
    return error.StoreNotFound;
}

pub fn setStoreUrlEnabled(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, url: []const u8, enabled: bool) !void {
    const base = try paths.platformConfigDir(gpa, home_dir);
    defer gpa.free(base);
    const guard = try package.lock(gpa, io, base, "plugin-stores");
    defer guard.close(io);
    var registrations = try loadStoreRegistrations(gpa, io, home_dir);
    defer deinitStoreRegistrations(gpa, &registrations);
    for (registrations.items) |*registration| {
        if (!std.mem.eql(u8, registration.url, url)) continue;
        if (registration.enabled == enabled) return;
        registration.enabled = enabled;
        try writeStoreRegistrations(gpa, io, home_dir, registrations.items);
        return;
    }
    return error.StoreNotFound;
}

/// Install the catalog entry at `selection` into the user's global plugin
/// directory. The project root is only used to resolve the checked-in local
/// catalog and its demo source directories.
/// The catalog is reloaded in the worker immediately before installation so a
/// stale UI selection cannot install a different URL after a store changes.
pub fn installSelected(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    project_root: []const u8,
    catalog_source: []const u8,
    plugin_id: []const u8,
    expected_fingerprint: [32]u8,
) !InstallReport {
    var catalog = try loadSource(gpa, io, null, project_root, catalog_source);
    defer catalog.deinit(gpa);
    var selected: ?*const Plugin = null;
    for (catalog.plugins) |*candidate| if (std.mem.eql(u8, candidate.id, plugin_id)) {
        selected = candidate;
        break;
    };
    const plugin = selected orelse return error.PluginNotFound;
    if (!std.mem.eql(u8, &fingerprint(plugin), &expected_fingerprint)) return error.CatalogSelectionChanged;
    const install_dir = try paths.globalPluginsDir(gpa, io, home_dir);
    defer gpa.free(install_dir);
    return installPlugin(gpa, io, install_dir, plugin, catalog_source, project_root);
}

/// Length-delimited descriptor hash binds display/selection to exact source,
/// version and file metadata. File bytes are verified separately on download.
pub fn fingerprint(plugin: *const Plugin) [32]u8 {
    var hash = Sha256.init(.{});
    hashField(&hash, plugin.id);
    hashField(&hash, plugin.name);
    hashField(&hash, plugin.version);
    hashField(&hash, plugin.description);
    switch (plugin.source) {
        .local_dir => |root| hashField(&hash, root),
        .files => |files| for (files) |file| {
            hashField(&hash, file.path);
            hashField(&hash, file.url);
            if (file.sha256) |digest| hashField(&hash, &digest) else hashField(&hash, "unverified");
            if (file.size) |size| {
                var encoded: [8]u8 = undefined;
                std.mem.writeInt(u64, &encoded, @intCast(size), .little);
                hashField(&hash, &encoded);
            } else hashField(&hash, "unknown-size");
        },
    }
    return hash.finalResult();
}

fn hashField(hash: *Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(value.len), .little);
    hash.update(&length);
    hash.update(value);
}

fn findEntry(bundle: *const CatalogBundle, catalog_source: []const u8, plugin_id: []const u8) ?Entry {
    for (bundle.catalogs, 0..) |catalog, catalog_index| {
        if (!std.mem.eql(u8, catalog.source, catalog_source)) continue;
        for (catalog.plugins, 0..) |*plugin, plugin_index| {
            if (std.mem.eql(u8, plugin.id, plugin_id)) {
                return .{
                    .catalog_index = catalog_index,
                    .plugin_index = plugin_index,
                    .catalog_source = catalog.source,
                    .store_name = catalog.name,
                    .plugin = plugin,
                };
            }
        }
    }
    return null;
}

fn installPlugin(
    gpa: std.mem.Allocator,
    io: std.Io,
    plugins_dir: []const u8,
    plugin: *const Plugin,
    catalog_source: []const u8,
    project_root: []const u8,
) !InstallReport {
    try std.Io.Dir.createDirPath(.cwd(), io, plugins_dir);

    const final_dir = try std.fs.path.join(gpa, &.{ plugins_dir, plugin.id });
    defer gpa.free(final_dir);
    const guard = try package.lock(gpa, io, plugins_dir, plugin.id);
    defer guard.close(io);
    const descriptor = fingerprint(plugin);
    const descriptor_hex = std.fmt.bytesToHex(descriptor, .lower);
    if (std.Io.Dir.access(.cwd(), io, final_dir, .{})) |_| {
        var existing = std.Io.Dir.openDir(.cwd(), io, final_dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.Canceled => return err,
            else => return error.InvalidPluginPackage,
        };
        defer existing.close(io);
        const entrypoint = existing.openFile(io, "init.lua", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.Canceled => return err,
            else => return error.InvalidPluginPackage,
        };
        defer entrypoint.close(io);
        if ((try entrypoint.stat(io)).kind != .file) return error.InvalidPluginPackage;
        var receipt = package.readReceipt(gpa, io, final_dir) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            return error.UnmanagedOrInvalidInstallation;
        };
        defer receipt.deinit();
        if (!std.mem.eql(u8, receipt.value.id, plugin.id) or !std.mem.eql(u8, receipt.value.catalog, catalog_source) or
            !std.mem.eql(u8, receipt.value.fingerprint, &descriptor_hex)) return error.InstallationConflict;
        if (!std.mem.eql(u8, receipt.value.name, plugin.id) or
            !std.mem.eql(u8, receipt.value.version, plugin.version)) return error.InstallationConflict;
        var manifest = try package.readManifest(gpa, io, final_dir);
        defer manifest.deinit(gpa);
        if (!std.mem.eql(u8, manifest.name, plugin.id) or !std.mem.eql(u8, manifest.version, receipt.value.version)) return error.InvalidPluginPackage;
        return makeInstallReport(gpa, .already_installed, plugin);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    const staging_dir = try std.fmt.allocPrint(gpa, "{s}/.staging-{s}-{s}", .{ plugins_dir, plugin.id, std.fmt.bytesToHex(nonce, .lower) });
    defer gpa.free(staging_dir);
    try std.Io.Dir.createDir(.cwd(), io, staging_dir, .default_dir);
    errdefer std.Io.Dir.deleteTree(.cwd(), io, staging_dir) catch {};

    var total_bytes: usize = 0;
    var file_count: usize = 0;
    var directory_count: usize = 0;
    switch (plugin.source) {
        .local_dir => |source_dir| {
            const physical_source = try std.Io.Dir.realPathFileAlloc(.cwd(), io, source_dir, gpa);
            defer gpa.free(physical_source);
            const physical_project = try std.Io.Dir.realPathFileAlloc(.cwd(), io, project_root, gpa);
            defer gpa.free(physical_project);
            if (!pathWithin(physical_source, physical_project)) return error.LocalSourceEscapesProject;
            const source_relative = try relativeSourcePath(source_dir, project_root);
            var project = try std.Io.Dir.openDir(.cwd(), io, physical_project, .{ .iterate = true, .follow_symlinks = false });
            defer project.close(io);
            var source = try openRelativeDirectory(io, &project, source_relative);
            defer source.close(io);
            try copyTree(gpa, io, &source, staging_dir, &total_bytes, &file_count, &directory_count, 0);
        },
        .files => |files| {
            if (files.len > max_plugin_files) return error.TooManyFiles;
            for (files) |file| {
                const bytes = try fetchHttp(gpa, io, file.url, plugin_file_max_bytes);
                defer gpa.free(bytes);
                try verifyFile(&file, bytes);
                total_bytes = std.math.add(usize, total_bytes, bytes.len) catch return error.PluginTooLarge;
                if (total_bytes > plugin_total_max_bytes) return error.PluginTooLarge;
                const output = try std.fs.path.join(gpa, &.{ staging_dir, file.path });
                defer gpa.free(output);
                if (std.fs.path.dirname(output)) |parent| try std.Io.Dir.createDirPath(.cwd(), io, parent);
                try writeFile(io, output, bytes);
            }
        },
    }

    const manifest_path = try std.fs.path.join(gpa, &.{ staging_dir, "plugin.lua" });
    defer gpa.free(manifest_path);
    const init_path = try std.fs.path.join(gpa, &.{ staging_dir, "init.lua" });
    defer gpa.free(init_path);
    if (!pathExists(io, manifest_path) or !pathExists(io, init_path)) return error.InvalidPluginPackage;
    var manifest = try package.readManifest(gpa, io, staging_dir);
    defer manifest.deinit(gpa);
    if (!std.mem.eql(u8, manifest.name, plugin.id)) return error.PluginIdentityMismatch;
    if (!std.mem.eql(u8, manifest.version, plugin.version)) return error.PluginVersionMismatch;
    const receipt_path = try std.fs.path.join(gpa, &.{ staging_dir, package.receipt_name });
    defer gpa.free(receipt_path);
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try std.json.Stringify.value(package.Receipt{ .id = plugin.id, .name = manifest.name, .version = manifest.version, .catalog = catalog_source, .fingerprint = &descriptor_hex }, .{}, &payload.writer);
    try writeFile(io, receipt_path, payload.written());
    var report = try makeInstallReport(gpa, .installed, plugin);
    errdefer report.deinit(gpa);
    try std.Io.Dir.renamePreserve(.cwd(), staging_dir, .cwd(), final_dir, io);
    return report;
}

fn verifyFile(file: *const File, bytes: []const u8) !void {
    if (file.size) |size| if (size != bytes.len) return error.FileSizeMismatch;
    if (file.sha256) |expected| {
        var actual: [32]u8 = undefined;
        Sha256.hash(bytes, &actual, .{});
        if (!std.mem.eql(u8, &actual, &expected)) return error.FileDigestMismatch;
    }
}

fn makeInstallReport(gpa: std.mem.Allocator, status: InstallStatus, plugin: *const Plugin) !InstallReport {
    const name = try gpa.dupe(u8, plugin.name);
    errdefer gpa.free(name);
    const version = try gpa.dupe(u8, plugin.version);
    return .{ .status = status, .name = name, .version = version };
}

fn copyTree(
    gpa: std.mem.Allocator,
    io: std.Io,
    source: *std.Io.Dir,
    target_dir: []const u8,
    total_bytes: *usize,
    file_count: *usize,
    directory_count: *usize,
    depth: usize,
) !void {
    if (depth > 16) return error.PluginDirectoryDepthExceeded;
    directory_count.* += 1;
    if (directory_count.* > 128) return error.TooManyDirectories;
    try std.Io.Dir.createDirPath(.cwd(), io, target_dir);

    var iter = source.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const target_path = try std.fs.path.join(gpa, &.{ target_dir, entry.name });
        defer gpa.free(target_path);

        switch (entry.kind) {
            .directory => {
                var child = try source.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer child.close(io);
                try copyTree(gpa, io, &child, target_path, total_bytes, file_count, directory_count, depth + 1);
            },
            .file => {
                file_count.* += 1;
                if (file_count.* > max_plugin_files) return error.TooManyFiles;
                const file = try source.openFile(io, entry.name, .{ .follow_symlinks = false });
                defer file.close(io);
                var reader = file.reader(io, &.{});
                const bytes = try reader.interface.allocRemaining(gpa, .limited(plugin_file_max_bytes));
                defer gpa.free(bytes);
                total_bytes.* = std.math.add(usize, total_bytes.*, bytes.len) catch return error.PluginTooLarge;
                if (total_bytes.* > plugin_total_max_bytes) return error.PluginTooLarge;
                try writeFile(io, target_path, bytes);
            },
            .sym_link => return error.PluginSymlinkUnsupported,
            else => return error.InvalidPluginPackage,
        }
    }
}

fn pathWithin(child: []const u8, parent: []const u8) bool {
    if (paths.pathsEqual(child, parent)) return true;
    return child.len > parent.len and paths.pathsEqual(child[0..parent.len], parent) and
        (child[parent.len] == '/' or child[parent.len] == '\\');
}

fn relativeSourcePath(source_dir: []const u8, project_root: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, source_dir, project_root) or source_dir.len <= project_root.len) return error.InvalidSourceDir;
    const separator = source_dir[project_root.len];
    if (separator != '/' and separator != '\\') return error.InvalidSourceDir;
    const relative = source_dir[project_root.len + 1 ..];
    if (relative.len == 0) return error.InvalidSourceDir;
    return relative;
}

fn openRelativeDirectory(io: std.Io, root: *std.Io.Dir, relative: []const u8) !std.Io.Dir {
    var current = root.*;
    var current_owned = false;
    errdefer if (current_owned) current.close(io);
    var segments = std.mem.splitScalar(u8, relative, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidSourceDir;
        const child = try current.openDir(io, segment, .{ .iterate = true, .follow_symlinks = false });
        if (current_owned) current.close(io);
        current = child;
        current_owned = true;
    }
    if (!current_owned) return error.InvalidSourceDir;
    const result = current;
    current_owned = false;
    return result;
}

fn parseCatalog(
    gpa: std.mem.Allocator,
    source: []const u8,
    bytes: []const u8,
    project_root: []const u8,
    local_source: bool,
) !Catalog {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidCatalog,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCatalog;

    const name = try duplicateRequiredString(gpa, parsed.value.object, "name", 128);
    errdefer gpa.free(name);
    const plugins_value = parsed.value.object.get("plugins") orelse return error.MissingPlugins;
    if (plugins_value != .array or plugins_value.array.items.len > max_catalog_plugins) return error.InvalidCatalog;

    var plugins: std.ArrayList(Plugin) = .empty;
    errdefer deinitPluginList(gpa, &plugins);
    for (plugins_value.array.items) |value| {
        if (value != .object) return error.InvalidCatalog;
        var plugin = try parsePlugin(gpa, value.object, project_root, local_source);
        var appended = false;
        errdefer if (!appended) plugin.deinit(gpa);
        for (plugins.items) |existing| {
            if (std.mem.eql(u8, existing.id, plugin.id)) return error.DuplicatePlugin;
        }
        try plugins.append(gpa, plugin);
        appended = true;
    }

    const source_copy = try gpa.dupe(u8, source);
    errdefer gpa.free(source_copy);
    return .{
        .source = source_copy,
        .name = name,
        .plugins = try plugins.toOwnedSlice(gpa),
    };
}

fn parsePlugin(
    gpa: std.mem.Allocator,
    object: std.json.ObjectMap,
    project_root: []const u8,
    local_source: bool,
) !Plugin {
    const id = try duplicateRequiredString(gpa, object, "id", 64);
    errdefer gpa.free(id);
    if (!validPluginId(id)) return error.InvalidPluginId;
    const name = try duplicateRequiredString(gpa, object, "name", 128);
    errdefer gpa.free(name);
    const version = try duplicateRequiredString(gpa, object, "version", 64);
    errdefer gpa.free(version);
    const description = try duplicateOptionalString(gpa, object, "description", 1024);
    errdefer gpa.free(description);

    if (object.get("sourceDir") orelse object.get("source_dir")) |source_value| {
        if (local_source) {
            if (source_value != .string or !validRelativePath(source_value.string)) return error.InvalidSourceDir;
            const source_dir = try std.fs.path.join(gpa, &.{ project_root, source_value.string });
            return .{
                .id = id,
                .name = name,
                .version = version,
                .description = description,
                .source = .{ .local_dir = source_dir },
            };
        }
    }

    const files_value = object.get("files") orelse return error.MissingFiles;
    if (files_value != .array or files_value.array.items.len == 0 or files_value.array.items.len > max_plugin_files) return error.InvalidFiles;
    var files: std.ArrayList(File) = .empty;
    errdefer deinitFileList(gpa, &files);
    for (files_value.array.items) |value| {
        if (value != .object) return error.InvalidFiles;
        const path = try duplicateRequiredString(gpa, value.object, "path", 256);
        errdefer gpa.free(path);
        if (!validRelativePath(path)) return error.InvalidFilePath;
        const url = try duplicateRequiredString(gpa, value.object, "url", 2048);
        errdefer gpa.free(url);
        validateHttpUrl(url) catch return error.InvalidFileUrl;
        var digest: ?[32]u8 = null;
        var size: ?usize = null;
        if (value.object.get("sha256")) |hash_value| {
            if (hash_value != .string or hash_value.string.len != 64) return error.InvalidFileDigest;
            var decoded: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&decoded, hash_value.string) catch return error.InvalidFileDigest;
            digest = decoded;
        }
        if (value.object.get("size")) |size_value| {
            if (size_value != .integer or size_value.integer < 0 or size_value.integer > plugin_file_max_bytes) return error.InvalidFileSize;
            size = @intCast(size_value.integer);
        }
        if ((digest == null) != (size == null)) return error.IncompleteFileVerification;
        for (files.items) |existing| {
            if (pathsConflict(existing.path, path)) return error.DuplicateFile;
        }
        try files.append(gpa, .{ .path = path, .url = url, .sha256 = digest, .size = size });
    }
    if (!containsFile(files.items, "plugin.lua") or !containsFile(files.items, "init.lua")) return error.InvalidPluginPackage;

    return .{
        .id = id,
        .name = name,
        .version = version,
        .description = description,
        .source = .{ .files = try files.toOwnedSlice(gpa) },
    };
}

fn duplicateRequiredString(gpa: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, max_len: usize) ![]u8 {
    const value = object.get(key) orelse return error.MissingField;
    if (value != .string or value.string.len == 0 or value.string.len > max_len) return error.InvalidField;
    return gpa.dupe(u8, value.string);
}

fn duplicateOptionalString(gpa: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, max_len: usize) ![]u8 {
    const value = object.get(key) orelse return gpa.alloc(u8, 0);
    if (value != .string or value.string.len > max_len) return error.InvalidField;
    return gpa.dupe(u8, value.string);
}

fn validPluginId(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    var previous_hyphen = false;
    for (value) |byte| {
        if (byte == '-') {
            if (previous_hyphen) return false;
            previous_hyphen = true;
        } else if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9'))) {
            return false;
        } else {
            previous_hyphen = false;
        }
    }
    return !previous_hyphen;
}

fn validRelativePath(value: []const u8) bool {
    if (value.len == 0 or value.len > 256) return false;
    if (value[0] == '/' or std.mem.indexOfAny(u8, value, "\\:<>\"|?*") != null) return false;
    var segments = std.mem.splitScalar(u8, value, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        if (segment[segment.len - 1] == '.' or segment[segment.len - 1] == ' ') return false;
        const stem_end = std.mem.indexOfScalar(u8, segment, '.') orelse segment.len;
        const stem = segment[0..stem_end];
        for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }) |reserved| {
            if (std.ascii.eqlIgnoreCase(stem, reserved)) return false;
        }
        for (segment) |byte| if (byte < 0x20) return false;
    }
    return true;
}

fn pathsConflict(left: []const u8, right: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(left, right)) return true;
    const short = if (left.len < right.len) left else right;
    const long = if (left.len < right.len) right else left;
    return long.len > short.len and std.ascii.eqlIgnoreCase(short, long[0..short.len]) and long[short.len] == '/';
}

fn containsFile(files: []const File, path: []const u8) bool {
    for (files) |file| if (std.mem.eql(u8, file.path, path)) return true;
    return false;
}

fn validateHttpUrl(url: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidStoreUrl;
    if (!(std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https"))) return error.InvalidStoreUrl;
    if (uri.host == null) return error.InvalidStoreUrl;
}

fn loadStoreRegistrations(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !std.ArrayList(StoreRegistration) {
    var registrations: std.ArrayList(StoreRegistration) = .empty;
    errdefer deinitStoreRegistrations(gpa, &registrations);
    if (home_dir.len == 0) return registrations;
    const path = try storeUrlsPath(gpa, home_dir);
    defer gpa.free(path);
    const bytes = readFile(gpa, io, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return registrations,
        else => return err,
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidStoreList,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidStoreList;
    const value = parsed.value.object.get("stores") orelse return registrations;
    if (value != .array or value.array.items.len > max_store_urls) return error.InvalidStoreList;
    for (value.array.items) |item| {
        const url: []const u8 = switch (item) {
            .string => item.string,
            .object => if (item.object.get("url")) |url_value|
                if (url_value == .string) url_value.string else return error.InvalidStoreList
            else
                return error.InvalidStoreList,
            else => return error.InvalidStoreList,
        };
        const enabled = if (item == .string)
            true
        else if (item.object.get("enabled")) |enabled_value|
            if (enabled_value == .bool) enabled_value.bool else return error.InvalidStoreList
        else
            true;
        validateHttpUrl(url) catch return error.InvalidStoreList;
        const copy = try gpa.dupe(u8, url);
        var appended = false;
        errdefer if (!appended) gpa.free(copy);
        try registrations.append(gpa, .{ .url = copy, .enabled = enabled });
        appended = true;
    }
    return registrations;
}

fn writeStoreRegistrations(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, registrations: []const StoreRegistration) !void {
    const path = try storeUrlsPath(gpa, home_dir);
    defer gpa.free(path);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.createDirPath(.cwd(), io, parent);
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try payload.writer.writeAll("{\"stores\":[");
    for (registrations, 0..) |registration, i| {
        if (i > 0) try payload.writer.writeByte(',');
        try std.json.Stringify.value(registration, .{}, &payload.writer);
    }
    try payload.writer.writeAll("]}");

    try package.atomicWrite(io, path, payload.written());
}

fn deinitStoreRegistrations(gpa: std.mem.Allocator, registrations: *std.ArrayList(StoreRegistration)) void {
    for (registrations.items) |registration| gpa.free(registration.url);
    registrations.deinit(gpa);
}

fn storeUrlsPath(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    const base = try paths.platformConfigDir(gpa, home_dir);
    defer gpa.free(base);
    return std.fs.path.join(gpa, &.{ base, "plugin-stores.json" });
}

fn fetchHttp(gpa: std.mem.Allocator, io: std.Io, url: []const u8, max_bytes: usize) ![]u8 {
    try validateHttpUrl(url);
    var client: std.http.Client = .{ .allocator = gpa, .io = http.timeoutAwareIo(io) };
    defer client.deinit();
    var request = try client.request(.GET, try std.Uri.parse(url), .{
        .headers = .{ .user_agent = .{ .override = "zay-plugin-store" } },
    });
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [http.redirect_buffer_bytes]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (!http.isSuccess(@intFromEnum(response.head.status))) return error.HttpError;

    var empty_decompress_buffer: [0]u8 = .{};
    var decompress_buffer: []u8 = &empty_decompress_buffer;
    var decompress_owned = false;
    switch (response.head.content_encoding) {
        .identity => {},
        .zstd => {
            decompress_buffer = try gpa.alloc(u8, std.compress.zstd.default_window_len);
            decompress_owned = true;
        },
        .deflate, .gzip => {
            decompress_buffer = try gpa.alloc(u8, std.compress.flate.max_window_len);
            decompress_owned = true;
        },
        .compress => return error.UnsupportedCompressionMethod,
    }
    defer if (decompress_owned) gpa.free(decompress_buffer);
    var transfer_buffer: [http.transfer_buffer_bytes]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    return reader.allocRemaining(gpa, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.ResponseTooLarge,
        else => |e| e,
    };
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.ResponseTooLarge,
        else => |e| e,
    };
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.createFile(.cwd(), io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try file.sync(io);
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.access(.cwd(), io, path, .{}) catch return false;
    return true;
}

fn deinitCatalogs(gpa: std.mem.Allocator, catalogs: *std.ArrayList(Catalog)) void {
    for (catalogs.items) |*catalog| catalog.deinit(gpa);
    catalogs.deinit(gpa);
}

fn deinitPluginList(gpa: std.mem.Allocator, plugins: *std.ArrayList(Plugin)) void {
    for (plugins.items) |*plugin| plugin.deinit(gpa);
    plugins.deinit(gpa);
}

fn deinitFileList(gpa: std.mem.Allocator, files: *std.ArrayList(File)) void {
    for (files.items) |*file| file.deinit(gpa);
    files.deinit(gpa);
}

fn deinitStringList(gpa: std.mem.Allocator, values: *std.ArrayList([]u8)) void {
    for (values.items) |value| gpa.free(value);
    values.deinit(gpa);
}

test "parseCatalog validates explicit remote files" {
    const json =
        "{\"name\":\"Test Store\",\"plugins\":[{" ++
        "\"id\":\"hello-world\",\"name\":\"Hello\",\"version\":\"1.0.0\",\"files\":[" ++
        "{\"path\":\"plugin.lua\",\"url\":\"https://example.com/plugin.lua\"}," ++
        "{\"path\":\"init.lua\",\"url\":\"https://example.com/init.lua\"}]}]}";
    var catalog = try parseCatalog(std.testing.allocator, "https://example.com/store.json", json, ".", false);
    defer catalog.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Test Store", catalog.name);
    try std.testing.expectEqual(@as(usize, 1), catalog.plugins.len);
    try std.testing.expect(catalog.plugins[0].source == .files);
}

test "findEntry selects by catalog source and plugin id" {
    const gpa = std.testing.allocator;
    const json =
        "{\"name\":\"Test Store\",\"plugins\":[{" ++
        "\"id\":\"hello-world\",\"name\":\"Hello\",\"version\":\"1\",\"files\":[" ++
        "{\"path\":\"plugin.lua\",\"url\":\"https://example.com/plugin.lua\"}," ++
        "{\"path\":\"init.lua\",\"url\":\"https://example.com/init.lua\"}]}]}";
    var catalog = try parseCatalog(gpa, "https://example.com/store.json", json, ".", false);
    var catalog_owned = true;
    defer if (catalog_owned) catalog.deinit(gpa);
    var catalogs = try gpa.alloc(Catalog, 1);
    var catalogs_owned = true;
    defer if (catalogs_owned) gpa.free(catalogs);
    catalogs[0] = catalog;
    catalog_owned = false;
    var bundle: CatalogBundle = .{ .catalogs = catalogs };
    catalogs_owned = false;
    defer bundle.deinit(gpa);

    const entry = findEntry(&bundle, "https://example.com/store.json", "hello-world") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello-world", entry.plugin.id);
    try std.testing.expectEqualStrings("https://example.com/store.json", entry.catalog_source);
}

test "parseCatalog rejects traversal and invalid plugin ids" {
    const traversal =
        "{\"name\":\"Test\",\"plugins\":[{" ++
        "\"id\":\"hello-world\",\"name\":\"Hello\",\"version\":\"1\",\"files\":[" ++
        "{\"path\":\"../plugin.lua\",\"url\":\"https://example.com/plugin.lua\"}," ++
        "{\"path\":\"init.lua\",\"url\":\"https://example.com/init.lua\"}]}]}";
    try std.testing.expectError(error.InvalidFilePath, parseCatalog(std.testing.allocator, "x", traversal, ".", false));

    const bad_id = "{\"name\":\"Test\",\"plugins\":[{\"id\":\"Bad_Name\",\"name\":\"x\",\"version\":\"1\",\"sourceDir\":\"examples/x\"}]}";
    try std.testing.expectError(error.InvalidPluginId, parseCatalog(std.testing.allocator, "x", bad_id, ".", true));
}

test "validRelativePath rejects empty and traversal segments" {
    try std.testing.expect(validRelativePath("nested/init.lua"));
    try std.testing.expect(!validRelativePath(""));
    try std.testing.expect(!validRelativePath("../init.lua"));
    try std.testing.expect(!validRelativePath("nested//init.lua"));
}

test "installPlugin publishes a local package once and is idempotent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "plugin-install" });
    defer gpa.free(root);
    const source = try std.fs.path.join(gpa, &.{ root, "examples", "demo" });
    defer gpa.free(source);
    try std.Io.Dir.createDirPath(.cwd(), io, source);
    const manifest_path = try std.fs.path.join(gpa, &.{ source, "plugin.lua" });
    defer gpa.free(manifest_path);
    try writeFile(io, manifest_path, "return { name = \"demo\", version = \"1.0.0\" }");
    const init_path = try std.fs.path.join(gpa, &.{ source, "init.lua" });
    defer gpa.free(init_path);
    try writeFile(io, init_path, "return true");

    const json = "{\"name\":\"Local\",\"plugins\":[{\"id\":\"demo\",\"name\":\"Demo\",\"version\":\"1.0.0\",\"sourceDir\":\"examples/demo\"}]}";
    var catalog = try parseCatalog(gpa, "local", json, root, true);
    defer catalog.deinit(gpa);

    const install_dir = try std.fs.path.join(gpa, &.{ root, "global", "plugins" });
    defer gpa.free(install_dir);
    var first = try installPlugin(gpa, io, install_dir, &catalog.plugins[0], "local", root);
    defer first.deinit(gpa);
    try std.testing.expectEqual(InstallStatus.installed, first.status);
    const installed_init = try std.fs.path.join(gpa, &.{ install_dir, "demo", "init.lua" });
    defer gpa.free(installed_init);
    try std.testing.expect(pathExists(io, installed_init));

    var second = try installPlugin(gpa, io, install_dir, &catalog.plugins[0], "local", root);
    defer second.deinit(gpa);
    try std.testing.expectEqual(InstallStatus.already_installed, second.status);

    try std.Io.Dir.deleteFile(.cwd(), io, installed_init);
    try std.testing.expectError(error.InvalidPluginPackage, installPlugin(gpa, io, install_dir, &catalog.plugins[0], "local", root));
    try std.Io.Dir.createDir(.cwd(), io, installed_init, .default_dir);
    try std.testing.expectError(error.InvalidPluginPackage, installPlugin(gpa, io, install_dir, &catalog.plugins[0], "local", root));

    const installed_manifest = try std.fs.path.join(gpa, &.{ install_dir, "demo", "plugin.lua" });
    defer gpa.free(installed_manifest);
    try std.Io.Dir.deleteFile(.cwd(), io, installed_manifest);
    var inventory: package.Inventory = .{};
    // Inventory discovery must retain receipt-bearing damaged packages.
    const home = try std.fs.path.join(gpa, &.{ root, "home" });
    defer gpa.free(home);
    const global = try paths.globalPluginsDir(gpa, io, home);
    defer gpa.free(global);
    try std.Io.Dir.createDirPath(.cwd(), io, global);
    const damaged = try std.fs.path.join(gpa, &.{ global, "demo" });
    defer gpa.free(damaged);
    const original = try std.fs.path.join(gpa, &.{ install_dir, "demo" });
    defer gpa.free(original);
    try std.Io.Dir.renamePreserve(.cwd(), original, .cwd(), damaged, io);
    inventory = try package.loadInventory(gpa, io, home, root);
    defer inventory.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), inventory.packages.len);
    try std.testing.expect(inventory.packages[0].manifest == null);
    try std.testing.expect(inventory.packages[0].receipt != null);
    try std.testing.expectEqualStrings("FileNotFound", inventory.packages[0].diagnostic.?);
}

test "catalog parsing preserves allocation failures" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, parseCatalog(failing.allocator(), "test", "{\"name\":\"Test\",\"plugins\":[]}", ".", false));
}

test "plugin_store rejects malformed managed receipt identities and fingerprints" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root);
    const receipt_path = try std.fs.path.join(gpa, &.{ root, package.receipt_name });
    defer gpa.free(receipt_path);
    const valid_hash = "0000000000000000000000000000000000000000000000000000000000000000";
    const invalid_hash = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";
    const invalid = [_]package.Receipt{
        .{ .id = "../escape", .name = "demo", .version = "1", .catalog = "test", .fingerprint = valid_hash },
        .{ .id = "demo", .name = "", .version = "1", .catalog = "test", .fingerprint = valid_hash },
        .{ .id = "demo", .name = "demo", .version = "", .catalog = "test", .fingerprint = valid_hash },
        .{ .id = "demo", .name = "demo", .version = "1", .catalog = "", .fingerprint = valid_hash },
        .{ .id = "demo", .name = "demo", .version = "1", .catalog = "test", .fingerprint = invalid_hash },
    };
    for (invalid) |receipt| {
        var payload: std.Io.Writer.Allocating = .init(gpa);
        defer payload.deinit();
        try std.json.Stringify.value(receipt, .{}, &payload.writer);
        try package.atomicWrite(io, receipt_path, payload.written());
        try std.testing.expectError(error.InvalidInstallReceipt, package.readReceipt(gpa, io, root));
    }
}

test "plugin_store official catalog pins one revision and verifies every file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const bytes = try readFile(gpa, io, "plugins/store.json", catalog_max_bytes);
    defer gpa.free(bytes);
    var catalog = try parseCatalog(gpa, "official", bytes, ".", false);
    defer catalog.deinit(gpa);
    const prefix = "https://raw.githubusercontent.com/ozgurulukir/zay/";
    var revision: ?[]const u8 = null;
    var count: usize = 0;
    for (catalog.plugins) |plugin| {
        for (plugin.source.files) |file| {
            try std.testing.expect(file.sha256 != null and file.size != null);
            try std.testing.expect(std.mem.startsWith(u8, file.url, prefix));
            const tail = file.url[prefix.len..];
            const separator = std.mem.indexOfScalar(u8, tail, '/') orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 40), separator);
            var commit_bytes: [20]u8 = undefined;
            _ = try std.fmt.hexToBytes(&commit_bytes, tail[0..separator]);
            if (revision) |expected| {
                try std.testing.expectEqualStrings(expected, tail[0..separator]);
            } else revision = tail[0..separator];
            const actual_path = try std.fs.path.join(gpa, &.{ "plugins/packages", plugin.id, file.path });
            defer gpa.free(actual_path);
            // URL paths always use '/', including when the test runs on Windows.
            const url_path = try std.fmt.allocPrint(gpa, "plugins/packages/{s}/{s}", .{ plugin.id, file.path });
            defer gpa.free(url_path);
            try std.testing.expectEqualStrings(url_path, tail[separator + 1 ..]);
            const contents = try readFile(gpa, io, actual_path, plugin_file_max_bytes);
            defer gpa.free(contents);
            try verifyFile(&file, contents);
            count += 1;
        }
    }
    try std.testing.expect(count > 0);
}
