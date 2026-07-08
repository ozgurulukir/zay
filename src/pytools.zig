//! pytools.zig — materializes Nova's project-scoped Python helpers.
//!
//! Bash is Nova's only tool; the model reaches richer capabilities (targeted
//! edits, fuzzy file search, its own reusable helpers) by writing Python
//! through it: `uv run --project .nova python`. This module makes that
//! invocation work by writing the embedded `src/py/` sources into
//! `<cwd>/.nova/` at startup:
//!
//!   - `.owned` files (the `nova` package internals) are rewritten whenever
//!     the embedded content differs, so binary upgrades propagate.
//!   - `.create_once` files are seeded and never touched again: users may add
//!     dependencies to `pyproject.toml`, and `nova/tools/` belongs to the
//!     model's own saved helpers.

const std = @import("std");

const common = @import("tools/common.zig");

const file_bytes_max: usize = 1024 * 1024;

const Policy = enum { owned, create_once };

const File = struct {
    relative: []const u8,
    content: []const u8,
    policy: Policy,
};

const gitignore = ".venv/\n__pycache__/\n*.egg-info/\n";

const files = [_]File{
    .{ .relative = ".nova/pyproject.toml", .content = @embedFile("py/pyproject.toml"), .policy = .create_once },
    .{ .relative = ".nova/.gitignore", .content = gitignore, .policy = .create_once },
    .{ .relative = ".nova/nova/__init__.py", .content = @embedFile("py/nova/__init__.py"), .policy = .owned },
    .{ .relative = ".nova/nova/_display.py", .content = @embedFile("py/nova/_display.py"), .policy = .owned },
    .{ .relative = ".nova/nova/_edit.py", .content = @embedFile("py/nova/_edit.py"), .policy = .owned },
    .{ .relative = ".nova/nova/_search.py", .content = @embedFile("py/nova/_search.py"), .policy = .owned },
    .{ .relative = ".nova/nova/tools/__init__.py", .content = @embedFile("py/nova/tools/__init__.py"), .policy = .create_once },
};

/// Write the helper package into `<cwd>/.nova`, respecting each file's
/// ownership policy. Best-effort per file: a failure on one file does not
/// stop the others; the first error is returned at the end so callers can
/// log it without losing the rest of the install.
pub fn ensureInstalled(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) !void {
    var first_error: ?anyerror = null;
    for (files) |file| {
        ensureFile(gpa, io, cwd, file) catch |err| {
            if (first_error == null) first_error = err;
        };
    }
    if (first_error) |err| return err;
}

fn ensureFile(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, file: File) !void {
    const absolute = try std.fs.path.join(gpa, &.{ cwd, file.relative });
    defer gpa.free(absolute);

    const existing: ?[]u8 = common.readFileBytes(gpa, io, absolute, file_bytes_max) catch null;
    defer if (existing) |data| gpa.free(data);
    if (existing != null and file.policy == .create_once) return;
    if (existing) |data| if (std.mem.eql(u8, data, file.content)) return;

    if (std.fs.path.dirname(absolute)) |dir| {
        try std.Io.Dir.createDirPath(.cwd(), io, dir);
    }
    var out = try std.Io.Dir.createFile(.cwd(), io, absolute, .{ .truncate = true });
    defer out.close(io);
    var buffer: [1024]u8 = undefined;
    var writer = out.writer(io, &buffer);
    try writer.interface.writeAll(file.content);
    try writer.interface.flush();
}

fn readInstalled(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, relative: []const u8) ![]u8 {
    const absolute = try std.fs.path.join(gpa, &.{ cwd, relative });
    defer gpa.free(absolute);
    return common.readFileBytes(gpa, io, absolute, file_bytes_max);
}

fn overwriteInstalled(io: std.Io, cwd_relative: []const u8, data: []const u8) !void {
    var out = try std.Io.Dir.createFile(.cwd(), io, cwd_relative, .{ .truncate = true });
    defer out.close(io);
    var buffer: [256]u8 = undefined;
    var writer = out.writer(io, &buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

test "ensureInstalled writes the package and repairs owned files only" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    const rel_root = ".zig-cache/pytools-test";
    try std.Io.Dir.createDirPath(.cwd(), io, rel_root);
    const cwd = try std.fs.path.join(gpa, &.{ root, rel_root });
    defer gpa.free(cwd);

    try ensureInstalled(gpa, io, cwd);
    const installed = try readInstalled(gpa, io, cwd, ".nova/nova/__init__.py");
    defer gpa.free(installed);
    try std.testing.expect(std.mem.indexOf(u8, installed, "from nova._edit import edit") != null);

    // Drift in an owned file is repaired; a user-owned file is left alone.
    try overwriteInstalled(io, rel_root ++ "/.nova/nova/_edit.py", "corrupted");
    try overwriteInstalled(io, rel_root ++ "/.nova/pyproject.toml", "user-customized");
    try ensureInstalled(gpa, io, cwd);

    const repaired = try readInstalled(gpa, io, cwd, ".nova/nova/_edit.py");
    defer gpa.free(repaired);
    try std.testing.expect(std.mem.indexOf(u8, repaired, "def edit(") != null);
    const preserved = try readInstalled(gpa, io, cwd, ".nova/pyproject.toml");
    defer gpa.free(preserved);
    try std.testing.expectEqualStrings("user-customized", preserved);
}
