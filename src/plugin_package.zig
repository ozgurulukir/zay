//! On-disk plugin identity, provenance and cross-process coordination. No live
//! Lua states or TUI state are owned here. Manifest evaluation is metadata-only.
const std = @import("std");
const paths = @import("paths.zig");
const manifest_mod = @import("lua/manifest.zig");
const Manifest = manifest_mod.Manifest;

pub const receipt_name = ".zay-store.json";
pub const Origin = enum { global, legacy_project, project };

pub const Receipt = struct {
    schema: u32 = 1,
    id: []const u8,
    name: []const u8,
    version: []const u8,
    catalog: []const u8,
    fingerprint: []const u8,
};

pub const Package = struct {
    directory: []u8,
    path: []u8,
    origin: Origin,
    manifest: ?Manifest = null,
    receipt: ?std.json.Parsed(Receipt) = null,
    diagnostic: ?[]u8 = null,
    ordinary_directory: bool = true,

    pub fn name(self: *const Package) []const u8 {
        return if (self.manifest) |value| value.name else self.directory;
    }

    pub fn version(self: *const Package) []const u8 {
        return if (self.manifest) |value| value.version else "unknown";
    }

    pub fn deinit(self: *Package, gpa: std.mem.Allocator) void {
        gpa.free(self.directory);
        gpa.free(self.path);
        if (self.manifest) |*value| value.deinit(gpa);
        if (self.receipt) |*value| value.deinit();
        if (self.diagnostic) |value| gpa.free(value);
        self.* = undefined;
    }
};

pub const Inventory = struct {
    packages: []Package = &.{},

    pub fn deinit(self: *Inventory, gpa: std.mem.Allocator) void {
        for (self.packages) |*value| value.deinit(gpa);
        if (self.packages.len > 0) gpa.free(self.packages);
        self.* = .{};
    }
};

pub fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]u8 {
    const file = try std.Io.Dir.openFile(.cwd(), io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.InvalidPluginPackage;
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(limit));
}

pub fn readManifest(gpa: std.mem.Allocator, io: std.Io, directory: []const u8) !Manifest {
    const path = try std.fs.path.join(gpa, &.{ directory, "plugin.lua" });
    defer gpa.free(path);
    const bytes = try readFile(gpa, io, path, manifest_mod.max_manifest_bytes);
    defer gpa.free(bytes);
    return manifest_mod.evaluate(gpa, bytes);
}

pub fn readReceipt(gpa: std.mem.Allocator, io: std.Io, directory: []const u8) !std.json.Parsed(Receipt) {
    const path = try std.fs.path.join(gpa, &.{ directory, receipt_name });
    defer gpa.free(path);
    const bytes = try readFile(gpa, io, path, 16 * 1024);
    defer gpa.free(bytes);
    var parsed = try std.json.parseFromSlice(Receipt, gpa, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value.schema != 1 or parsed.value.fingerprint.len != 64 or
        !safeDirectoryName(parsed.value.id) or parsed.value.name.len == 0 or
        parsed.value.version.len == 0 or parsed.value.catalog.len == 0) return error.InvalidInstallReceipt;
    var fingerprint: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&fingerprint, parsed.value.fingerprint) catch return error.InvalidInstallReceipt;
    return parsed;
}

pub fn atomicWrite(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.createFileAtomic(.cwd(), io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// Lock files remain at a stable inode; deleting one would let another process
/// lock a new inode while an old holder still owns the previous lock.
pub fn lock(gpa: std.mem.Allocator, io: std.Io, root: []const u8, key: []const u8) !std.Io.File {
    if (!safeDirectoryName(key)) return error.InvalidPluginName;
    const locks = try std.fs.path.join(gpa, &.{ root, ".locks" });
    defer gpa.free(locks);
    try std.Io.Dir.createDirPath(.cwd(), io, locks);
    const path = try std.fs.path.join(gpa, &.{ locks, key });
    defer gpa.free(path);
    return std.Io.Dir.createFile(.cwd(), io, path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
}

pub fn safeDirectoryName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

pub fn loadInventory(gpa: std.mem.Allocator, io: std.Io, home: []const u8, project: []const u8) !Inventory {
    var result: std.ArrayList(Package) = .empty;
    errdefer {
        for (result.items) |*value| value.deinit(gpa);
        result.deinit(gpa);
    }
    const global = try paths.globalPluginsDir(gpa, io, home);
    defer gpa.free(global);
    try scan(gpa, io, global, .global, &result);
    const legacy = try std.fs.path.join(gpa, &.{ project, ".zay", "plugins" });
    defer gpa.free(legacy);
    try scan(gpa, io, legacy, .legacy_project, &result);
    const current = try std.fs.path.join(gpa, &.{ project, "plugins" });
    defer gpa.free(current);
    try scan(gpa, io, current, .project, &result);
    std.mem.sort(Package, result.items, {}, struct {
        fn less(_: void, left: Package, right: Package) bool {
            return std.mem.order(u8, left.path, right.path) == .lt;
        }
    }.less);
    return .{ .packages = try result.toOwnedSlice(gpa) };
}

fn scan(gpa: std.mem.Allocator, io: std.Io, root: []const u8, origin: Origin, out: *std.ArrayList(Package)) !void {
    var dir = std.Io.Dir.openDir(.cwd(), io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        const path = try std.fs.path.join(gpa, &.{ root, entry.name });
        var path_owned = true;
        defer if (path_owned) gpa.free(path);
        const manifest_path = try std.fs.path.join(gpa, &.{ path, "plugin.lua" });
        defer gpa.free(manifest_path);
        std.Io.Dir.access(.cwd(), io, manifest_path, .{}) catch {
            const receipt_path = try std.fs.path.join(gpa, &.{ path, receipt_name });
            defer gpa.free(receipt_path);
            std.Io.Dir.access(.cwd(), io, receipt_path, .{}) catch continue;
        };
        // Reserve/allocate before moving ownership into a Package.
        const directory = try gpa.dupe(u8, entry.name);
        var value: Package = .{ .directory = directory, .path = path, .origin = origin, .ordinary_directory = entry.kind == .directory };
        path_owned = false;
        errdefer value.deinit(gpa);
        value.manifest = readManifest(gpa, io, path) catch |err| blk: {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            value.diagnostic = try gpa.dupe(u8, @errorName(err));
            break :blk null;
        };
        value.receipt = readReceipt(gpa, io, path) catch |err| blk: {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            break :blk null;
        };
        try out.append(gpa, value);
    }
}

/// Deletion uses the selected physical directory and revalidates the receipt
/// under the same lock used by publication. Unmanaged copies require a
/// separate manual removal workflow; this operation never adopts them.
pub fn remove(gpa: std.mem.Allocator, io: std.Io, root: []const u8, directory: []const u8, expected_fingerprint: []const u8) !void {
    const guard = try lock(gpa, io, root, directory);
    defer guard.close(io);
    var parent = try std.Io.Dir.openDir(.cwd(), io, root, .{});
    defer parent.close(io);
    var dir = try parent.openDir(io, directory, .{ .follow_symlinks = false });
    dir.close(io);
    const path = try std.fs.path.join(gpa, &.{ root, directory });
    defer gpa.free(path);
    var receipt = try readReceipt(gpa, io, path);
    defer receipt.deinit();
    if (!std.mem.eql(u8, receipt.value.fingerprint, expected_fingerprint)) return error.InstallationChanged;
    try parent.deleteTree(io, directory);
}
