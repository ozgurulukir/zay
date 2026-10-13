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


test "returnsParsedManifest_whenPluginLuaIsValid" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "read-manifest-valid" });
    defer gpa.free(root);
    try std.Io.Dir.createDirPath(.cwd(), io, root);

    const plugin_lua_path = try std.fs.path.join(gpa, &.{ root, "plugin.lua" });
    defer gpa.free(plugin_lua_path);

    var file = try std.Io.Dir.createFile(.cwd(), io, plugin_lua_path, .{ .truncate = true });
    var buf: [256]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll("return { name = \"test_pkg\", version = \"1.0.0\", author = \"jules\" }");
    try writer.interface.flush();
    file.close(io);

    var manifest = try readManifest(gpa, io, root);
    defer manifest.deinit(gpa);

    try std.testing.expectEqualStrings("test_pkg", manifest.name);
    try std.testing.expectEqualStrings("1.0.0", manifest.version);
    try std.testing.expectEqualStrings("jules", manifest.author);
}

test "returnsFileNotFound_whenPluginLuaMissing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "read-manifest-missing" });
    defer gpa.free(root);
    try std.Io.Dir.createDirPath(.cwd(), io, root);

    try std.testing.expectError(error.FileNotFound, readManifest(gpa, io, root));
}

test "returnsInvalidManifest_whenPluginLuaHasInvalidSyntax" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "read-manifest-syntax-err" });
    defer gpa.free(root);
    try std.Io.Dir.createDirPath(.cwd(), io, root);

    const plugin_lua_path = try std.fs.path.join(gpa, &.{ root, "plugin.lua" });
    defer gpa.free(plugin_lua_path);

    var file = try std.Io.Dir.createFile(.cwd(), io, plugin_lua_path, .{ .truncate = true });
    var buf: [256]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll("return { name = ");
    try writer.interface.flush();
    file.close(io);

    try std.testing.expectError(error.InvalidManifest, readManifest(gpa, io, root));
}

test "returnsMissingPluginName_whenPluginLuaLacksName" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "read-manifest-no-name" });
    defer gpa.free(root);
    try std.Io.Dir.createDirPath(.cwd(), io, root);

    const plugin_lua_path = try std.fs.path.join(gpa, &.{ root, "plugin.lua" });
    defer gpa.free(plugin_lua_path);

    var file = try std.Io.Dir.createFile(.cwd(), io, plugin_lua_path, .{ .truncate = true });
    var buf: [256]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll("return { version = \"1.0.0\" }");
    try writer.interface.flush();
    file.close(io);

    try std.testing.expectError(error.MissingPluginName, readManifest(gpa, io, root));
}

test "returnsManifestTooLarge_whenPluginLuaExceedsSizeLimit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "read-manifest-too-large" });
    defer gpa.free(root);
    try std.Io.Dir.createDirPath(.cwd(), io, root);

    const plugin_lua_path = try std.fs.path.join(gpa, &.{ root, "plugin.lua" });
    defer gpa.free(plugin_lua_path);

    var file = try std.Io.Dir.createFile(.cwd(), io, plugin_lua_path, .{ .truncate = true });
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    const chunk = "-- " ++ ("a" ** 100) ++ "\n";
    var written: usize = 0;
    while (written <= manifest_mod.max_manifest_bytes) {
        try writer.interface.writeAll(chunk);
        written += chunk.len;
    }
    try writer.interface.flush();
    file.close(io);

    try std.testing.expectError(error.ManifestTooLarge, readManifest(gpa, io, root));
}


test "readReceipt_returnsParsedReceipt_whenValidJson" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root);
    const receipt_path = try std.fs.path.join(gpa, &.{ root, receipt_name });
    defer gpa.free(receipt_path);

    const valid_receipt = Receipt{
        .schema = 1,
        .id = "my-plugin",
        .name = "My Plugin",
        .version = "1.0.0",
        .catalog = "official",
        .fingerprint = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
    };

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try std.json.Stringify.value(valid_receipt, .{}, &payload.writer);
    try atomicWrite(io, receipt_path, payload.written());

    var parsed = try readReceipt(gpa, io, root);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 1), parsed.value.schema);
    try std.testing.expectEqualStrings("my-plugin", parsed.value.id);
    try std.testing.expectEqualStrings("My Plugin", parsed.value.name);
    try std.testing.expectEqualStrings("1.0.0", parsed.value.version);
    try std.testing.expectEqualStrings("official", parsed.value.catalog);
    try std.testing.expectEqualStrings("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff", parsed.value.fingerprint);
}

test "readReceipt_returnsInvalidInstallReceipt_whenReceiptIsInvalid" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root);
    const receipt_path = try std.fs.path.join(gpa, &.{ root, receipt_name });
    defer gpa.free(receipt_path);

    const valid_fingerprint = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

    const invalid_cases = [_]Receipt{
        // Invalid schema
        .{ .schema = 2, .id = "plugin-a", .name = "Plugin A", .version = "1.0.0", .catalog = "official", .fingerprint = valid_fingerprint },
        // Short fingerprint
        .{ .schema = 1, .id = "plugin-a", .name = "Plugin A", .version = "1.0.0", .catalog = "official", .fingerprint = "0011223344" },
        // Non-hex fingerprint of length 64
        .{ .schema = 1, .id = "plugin-a", .name = "Plugin A", .version = "1.0.0", .catalog = "official", .fingerprint = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" },
        // Unsafe id (path traversal / special characters)
        .{ .schema = 1, .id = "../escape", .name = "Plugin A", .version = "1.0.0", .catalog = "official", .fingerprint = valid_fingerprint },
        // Empty id
        .{ .schema = 1, .id = "", .name = "Plugin A", .version = "1.0.0", .catalog = "official", .fingerprint = valid_fingerprint },
        // Empty name
        .{ .schema = 1, .id = "plugin-a", .name = "", .version = "1.0.0", .catalog = "official", .fingerprint = valid_fingerprint },
        // Empty version
        .{ .schema = 1, .id = "plugin-a", .name = "Plugin A", .version = "", .catalog = "official", .fingerprint = valid_fingerprint },
        // Empty catalog
        .{ .schema = 1, .id = "plugin-a", .name = "Plugin A", .version = "1.0.0", .catalog = "", .fingerprint = valid_fingerprint },
    };

    for (invalid_cases) |invalid_receipt| {
        var payload: std.Io.Writer.Allocating = .init(gpa);
        defer payload.deinit();
        try std.json.Stringify.value(invalid_receipt, .{}, &payload.writer);
        try atomicWrite(io, receipt_path, payload.written());

        try std.testing.expectError(error.InvalidInstallReceipt, readReceipt(gpa, io, root));
    }
}

test "readReceipt_returnsFileNotFound_whenFileDoesNotExist" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root);

    try std.testing.expectError(error.FileNotFound, readReceipt(gpa, io, root));
}

test "readFile reads regular file contents within limit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "sample.lua" });
    defer gpa.free(path);

    const expected_content = "return { name = \"test-plugin\", version = \"1.0.0\" }";
    try atomicWrite(io, path, expected_content);

    const content = try readFile(gpa, io, path, 1024);
    defer gpa.free(content);

    try std.testing.expectEqualStrings(expected_content, content);
}

test "readFile returns StreamTooLong when file exceeds limit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "large.txt" });
    defer gpa.free(path);

    try atomicWrite(io, path, "12345678901234567890");

    try std.testing.expectError(error.StreamTooLong, readFile(gpa, io, path, 5));
}

test "readFile returns InvalidPluginPackage when path points to a directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "sub_dir" });
    defer gpa.free(dir_path);

    try std.Io.Dir.createDirPath(.cwd(), io, dir_path);

    try std.testing.expectError(error.InvalidPluginPackage, readFile(gpa, io, dir_path, 1024));
}

test "readFile returns FileNotFound when file does not exist" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const missing_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "nonexistent.file" });
    defer gpa.free(missing_path);

    try std.testing.expectError(error.FileNotFound, readFile(gpa, io, missing_path, 1024));
}

test "readFile reads empty file successfully" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "empty.txt" });
    defer gpa.free(path);

    try atomicWrite(io, path, "");

    const content = try readFile(gpa, io, path, 1024);
    defer gpa.free(content);

    try std.testing.expectEqualStrings("", content);
}

test "safeDirectoryName validates directory names correctly" {
    try std.testing.expect(safeDirectoryName("valid-name"));
    try std.testing.expect(safeDirectoryName("valid_name_123"));
    try std.testing.expect(safeDirectoryName("a"));
    try std.testing.expect(!safeDirectoryName(""));
    try std.testing.expect(!safeDirectoryName("invalid/path"));
    try std.testing.expect(!safeDirectoryName("invalid..name"));
    try std.testing.expect(!safeDirectoryName("invalid space"));
    try std.testing.expect(!safeDirectoryName("a" ** 65));
}
