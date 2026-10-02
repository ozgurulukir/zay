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

    pub fn deinit(self: *CatalogBundle, gpa: std.mem.Allocator) void {
        for (self.catalogs) |*catalog| catalog.deinit(gpa);
        gpa.free(self.catalogs);
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

    const local_path = try std.fs.path.join(gpa, &.{ project_root, "plugins", "store.json" });
    defer gpa.free(local_path);
    var has_local_catalog = false;
    if (readFile(gpa, io, local_path, catalog_max_bytes)) |bytes| {
        defer gpa.free(bytes);
        var catalog = try parseCatalog(gpa, local_path, bytes, project_root, true);
        var appended = false;
        errdefer if (!appended) catalog.deinit(gpa);
        try catalogs.append(gpa, catalog);
        appended = true;
        has_local_catalog = true;
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    }

    if (!has_local_catalog) {
        if (fetchHttp(gpa, io, default_store_url, catalog_max_bytes)) |bytes| {
            defer gpa.free(bytes);
            const maybe_catalog: ?Catalog = parseCatalog(gpa, default_store_url, bytes, project_root, false) catch |err| blk: {
                log.warn("default_catalog_invalid url={s} reason={s}", .{ default_store_url, @errorName(err) });
                break :blk null;
            };
            if (maybe_catalog) |catalog_value| {
                var catalog = catalog_value;
                var appended = false;
                errdefer if (!appended) catalog.deinit(gpa);
                try catalogs.append(gpa, catalog);
                appended = true;
            }
        } else |err| {
            log.warn("default_catalog_unavailable url={s} reason={s}", .{ default_store_url, @errorName(err) });
        }
    }

    var urls = try loadStoreUrls(gpa, io, home_dir);
    defer deinitStringList(gpa, &urls);
    for (urls.items) |url| {
        const bytes = try fetchHttp(gpa, io, url, catalog_max_bytes);
        defer gpa.free(bytes);
        var catalog = try parseCatalog(gpa, url, bytes, project_root, false);
        var appended = false;
        errdefer if (!appended) catalog.deinit(gpa);
        try catalogs.append(gpa, catalog);
        appended = true;
    }

    return .{ .catalogs = try catalogs.toOwnedSlice(gpa) };
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

    var urls = try loadStoreUrls(gpa, io, home_dir);
    defer deinitStringList(gpa, &urls);
    for (urls.items) |existing| {
        if (std.mem.eql(u8, existing, url)) return;
    }
    if (urls.items.len >= max_store_urls) return error.TooManyStores;
    const url_copy = try gpa.dupe(u8, url);
    var appended = false;
    errdefer if (!appended) gpa.free(url_copy);
    try urls.append(gpa, url_copy);
    appended = true;
    try writeStoreUrls(gpa, io, home_dir, urls.items);
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
) !InstallReport {
    var bundle = try loadCatalogs(gpa, io, home_dir, project_root);
    defer bundle.deinit(gpa);
    const selected = findEntry(&bundle, catalog_source, plugin_id) orelse return error.PluginNotFound;
    const install_dir = try paths.globalPluginsDir(gpa, io, home_dir);
    defer gpa.free(install_dir);
    return installPlugin(gpa, io, install_dir, selected.plugin);
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
) !InstallReport {
    try std.Io.Dir.createDirPath(.cwd(), io, plugins_dir);

    const final_dir = try std.fs.path.join(gpa, &.{ plugins_dir, plugin.id });
    defer gpa.free(final_dir);
    if (std.Io.Dir.access(.cwd(), io, final_dir, .{})) |_| {
        return makeInstallReport(gpa, .already_installed, plugin);
    } else |_| {}

    const staging_dir = try std.fmt.allocPrint(gpa, "{s}/.staging-{s}", .{ plugins_dir, plugin.id });
    defer gpa.free(staging_dir);
    std.Io.Dir.deleteTree(.cwd(), io, staging_dir) catch {};
    errdefer std.Io.Dir.deleteTree(.cwd(), io, staging_dir) catch {};
    try std.Io.Dir.createDirPath(.cwd(), io, staging_dir);

    var total_bytes: usize = 0;
    var file_count: usize = 0;
    switch (plugin.source) {
        .local_dir => |source_dir| try copyTree(gpa, io, source_dir, staging_dir, &total_bytes, &file_count),
        .files => |files| {
            if (files.len > max_plugin_files) return error.TooManyFiles;
            for (files) |file| {
                const bytes = try fetchHttp(gpa, io, file.url, plugin_file_max_bytes);
                defer gpa.free(bytes);
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

    try std.Io.Dir.rename(.cwd(), staging_dir, .cwd(), final_dir, io);
    return makeInstallReport(gpa, .installed, plugin);
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
    source_dir: []const u8,
    target_dir: []const u8,
    total_bytes: *usize,
    file_count: *usize,
) !void {
    var source = std.Io.Dir.openDir(.cwd(), io, source_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.InvalidPluginPackage,
        else => return err,
    };
    defer source.close(io);
    try std.Io.Dir.createDirPath(.cwd(), io, target_dir);

    var iter = source.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const source_path = try std.fs.path.join(gpa, &.{ source_dir, entry.name });
        defer gpa.free(source_path);
        const target_path = try std.fs.path.join(gpa, &.{ target_dir, entry.name });
        defer gpa.free(target_path);

        switch (entry.kind) {
            .directory => try copyTree(gpa, io, source_path, target_path, total_bytes, file_count),
            .file => {
                file_count.* += 1;
                if (file_count.* > max_plugin_files) return error.TooManyFiles;
                const bytes = try readFile(gpa, io, source_path, plugin_file_max_bytes);
                defer gpa.free(bytes);
                total_bytes.* = std.math.add(usize, total_bytes.*, bytes.len) catch return error.PluginTooLarge;
                if (total_bytes.* > plugin_total_max_bytes) return error.PluginTooLarge;
                try writeFile(io, target_path, bytes);
            },
            else => {},
        }
    }
}

fn parseCatalog(
    gpa: std.mem.Allocator,
    source: []const u8,
    bytes: []const u8,
    project_root: []const u8,
    local_source: bool,
) !Catalog {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.InvalidCatalog;
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
        if (!local_source or source_value != .string or !validRelativePath(source_value.string)) return error.InvalidSourceDir;
        const source_dir = try std.fs.path.join(gpa, &.{ project_root, source_value.string });
        return .{
            .id = id,
            .name = name,
            .version = version,
            .description = description,
            .source = .{ .local_dir = source_dir },
        };
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
        for (files.items) |existing| {
            if (std.mem.eql(u8, existing.path, path)) return error.DuplicateFile;
        }
        try files.append(gpa, .{ .path = path, .url = url });
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
    if (value[0] == '/' or value[0] == '\\' or std.mem.indexOfScalar(u8, value, ':') != null) return false;
    var segments = std.mem.splitAny(u8, value, "/\\");
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |byte| if (byte < 0x20) return false;
    }
    return true;
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

fn loadStoreUrls(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !std.ArrayList([]u8) {
    var urls: std.ArrayList([]u8) = .empty;
    errdefer deinitStringList(gpa, &urls);
    if (home_dir.len == 0) return urls;
    const path = try storeUrlsPath(gpa, home_dir);
    defer gpa.free(path);
    const bytes = readFile(gpa, io, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return urls,
        else => return err,
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.InvalidStoreList;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidStoreList;
    const value = parsed.value.object.get("stores") orelse return urls;
    if (value != .array or value.array.items.len > max_store_urls) return error.InvalidStoreList;
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidStoreList;
        validateHttpUrl(item.string) catch return error.InvalidStoreList;
        const copy = try gpa.dupe(u8, item.string);
        var appended = false;
        errdefer if (!appended) gpa.free(copy);
        try urls.append(gpa, copy);
        appended = true;
    }
    return urls;
}

fn writeStoreUrls(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, urls: []const []u8) !void {
    const path = try storeUrlsPath(gpa, home_dir);
    defer gpa.free(path);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.createDirPath(.cwd(), io, parent);
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try payload.writer.writeAll("{\"stores\":[");
    for (urls, 0..) |url, i| {
        if (i > 0) try payload.writer.writeByte(',');
        try std.json.Stringify.value(url, .{}, &payload.writer);
    }
    try payload.writer.writeAll("]}");

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);
    errdefer std.Io.Dir.deleteFile(.cwd(), io, tmp_path) catch {};
    try writeFile(io, tmp_path, payload.written());
    try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), path, io);
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
    var first = try installPlugin(gpa, io, install_dir, &catalog.plugins[0]);
    defer first.deinit(gpa);
    try std.testing.expectEqual(InstallStatus.installed, first.status);
    const installed_init = try std.fs.path.join(gpa, &.{ install_dir, "demo", "init.lua" });
    defer gpa.free(installed_init);
    try std.testing.expect(pathExists(io, installed_init));

    var second = try installPlugin(gpa, io, install_dir, &catalog.plugins[0]);
    defer second.deinit(gpa);
    try std.testing.expectEqual(InstallStatus.already_installed, second.status);
}
