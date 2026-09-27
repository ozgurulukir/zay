//! Platform-tolerant path helpers.
//!
//! Two concerns live here:
//!   1. Path comparison (`pathsEqual`) — the single source of truth for
//!      matching workspace/worktree paths across git's forward-slash reporting
//!      and platform-native storage.
//!   2. The platform-aware global config directory (`platformConfigDir`) —
//!      the single base every global Zay path (config, worktrees, logs,
//!      session DB) is derived from, so Windows maps to `%APPDATA%\zay`
//!      consistently with the plugin-discovery probe.
//!
//! Extracted from `tui/lanes.zig` so the execution layer (`tools/pwsh.zig`,
//! `background.zig`) can compare paths without importing the TUI module —
//! that import pulled the whole App into the executor's dependency closure.
//! `tui/lanes.zig` re-exports these symbols for its in-TUI callers; never
//! re-introduce a `tui/` import from the execution layer to reach them.

const std = @import("std");
const os = @import("os.zig");

const log = std.log.scoped(.paths);

/// Final path segment, tolerant of both `/` and `\` separators and trailing
/// slashes. Used to match worktree paths across git's forward-slash reporting
/// and the platform-native paths Zay stores.
pub fn lastPathSegment(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    var start = end;
    while (start > 0 and path[start - 1] != '/' and path[start - 1] != '\\') start -= 1;
    return path[start..end];
}

/// True when two filesystem paths point to the same location, tolerant of
/// mixed `/` and `\` separators, redundant slashes, trailing slashes, and
/// case-insensitivity on Windows. Allocator-free.
pub fn pathsEqual(a: []const u8, b: []const u8) bool {
    return pathsEqualInternal(a, b, os.is_windows);
}

pub fn pathsEqualInternal(a: []const u8, b: []const u8, is_windows: bool) bool {
    if (a.len == 0 or b.len == 0) return a.len == b.len;

    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ca = a[i];
        const cb = b[j];
        const is_sep_a = (ca == '/' or ca == '\\');
        const is_sep_b = (cb == '/' or cb == '\\');

        if (is_sep_a and is_sep_b) {
            while (i + 1 < a.len and (a[i + 1] == '/' or a[i + 1] == '\\')) i += 1;
            while (j + 1 < b.len and (b[j + 1] == '/' or b[j + 1] == '\\')) j += 1;
        } else {
            const eq = if (is_windows)
                std.ascii.toLower(ca) == std.ascii.toLower(cb)
            else
                ca == cb;
            if (!eq) return false;
        }
        i += 1;
        j += 1;
    }
    while (i < a.len and (a[i] == '/' or a[i] == '\\')) i += 1;
    while (j < b.len and (b[j] == '/' or b[j] == '\\')) j += 1;
    return i == a.len and j == b.len;
}

test "lastPathSegment: empty, trailing slashes, mixed separators, root" {
    try std.testing.expectEqualStrings("", lastPathSegment(""));
    try std.testing.expectEqualStrings("bar", lastPathSegment("/foo/bar"));
    try std.testing.expectEqualStrings("bar", lastPathSegment("/foo/bar/"));
    try std.testing.expectEqualStrings("bar", lastPathSegment("/foo\\bar\\"));
    try std.testing.expectEqualStrings("worktrees", lastPathSegment("/home/zay/.config/zay/worktrees/"));
    try std.testing.expectEqualStrings("", lastPathSegment("/"));
    try std.testing.expectEqualStrings("", lastPathSegment("\\"));
    try std.testing.expectEqualStrings("wt-1", lastPathSegment("C:\\Users\\zay\\worktrees\\wt-1"));
    try std.testing.expectEqualStrings("repo", lastPathSegment("repo"));
}

test "pathsEqual: identical paths and separator permutations" {
    try std.testing.expect(pathsEqual("/foo/bar", "/foo/bar"));
    try std.testing.expect(pathsEqual("C:/Users/zay/worktrees/1", "C:\\Users\\zay\\worktrees\\1"));
    try std.testing.expect(pathsEqual("C:/Users//zay///worktrees/1", "C:\\Users\\zay\\worktrees\\1"));
    try std.testing.expect(pathsEqual("/foo/bar/", "/foo/bar"));
    try std.testing.expect(pathsEqual("C:\\repo\\", "C:/repo"));
    try std.testing.expect(pathsEqual("", ""));
    try std.testing.expect(!pathsEqual("", "/"));
    try std.testing.expect(!pathsEqual("/", ""));
    try std.testing.expect(!pathsEqual("", "\\"));
    try std.testing.expect(!pathsEqual("/foo/bar", "/foo/baz"));
    try std.testing.expect(!pathsEqual("/foo/bar", "/foo/bar/sub"));
}

test "pathsEqualInternal: Windows case-insensitivity control" {
    // Under Windows semantics (is_windows = true):
    try std.testing.expect(pathsEqualInternal("c:\\users\\repo", "C:/USERS/REPO", true));
    try std.testing.expect(pathsEqualInternal("C:/Users/Repo/wt", "c:\\users\\repo\\wt\\", true));

    // Under POSIX semantics (is_windows = false):
    try std.testing.expect(!pathsEqualInternal("c:\\users\\repo", "C:\\users\\repo", false));
    try std.testing.expect(pathsEqualInternal("/home/user/repo", "/home/user/repo/", false));
    try std.testing.expect(!pathsEqualInternal("/home/user/repo", "/Home/user/repo", false));
}

/// Platform-aware global config directory — the single base from which every
/// global Zay path (config.json, worktrees, zay.log, sessions.sqlite) is
/// derived.
///
/// Mirrors the plugin-discovery probe in `plugin_prompt.zig` (which already
/// checks `%APPDATA%\Roaming\zay\plugins` first on Windows) so the whole
/// global tree stays inside one platform-correct root:
///   - Windows: <USERPROFILE>/AppData/Roaming/zay   (== %APPDATA%\zay)
///   - POSIX:   <home>/.config/zay                  (XDG base directory)
///
/// Callers must pass a non-empty `home_dir`: the production caller
/// (`root.zig`'s `resolveHome`) validates the env-derived value before it
/// reaches here; tests pass controlled relative homes to pin global state
/// under a scratch directory. `defaultPath` asserts the resulting layout so
/// a layout regression fails the suite immediately. Caller owns the returned
/// slice.
pub fn platformConfigDir(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    if (os.is_windows) {
        return std.fs.path.join(gpa, &.{ home_dir, "AppData", "Roaming", "zay" });
    }
    return std.fs.path.join(gpa, &.{ home_dir, ".config", "zay" });
}

test "platformConfigDir: XDG under POSIX, APPDATA under Windows" {
    const gpa = std.testing.allocator;
    // The platform branch is selected at compile time (os.is_windows), so this
    // test asserts the separator-agnostic *shape* of the path on the host OS.
    const dir = try platformConfigDir(gpa, "HOME");
    defer gpa.free(dir);

    // POSIX host: HOME/.config/zay ; Windows host: HOME/AppData/Roaming/zay.
    // Compare with pathsEqual (slash-agnostic) so the asserted suffix is stable
    // regardless of the host separator.
    const want_suffix = if (os.is_windows) "AppData/Roaming/zay" else ".config/zay";
    const expected = try std.fmt.allocPrint(gpa, "HOME/{s}", .{want_suffix});
    defer gpa.free(expected);
    try std.testing.expect(pathsEqual(dir, expected));
}

test "platformConfigDir: appends the zay segment under the platform base" {
    const gpa = std.testing.allocator;
    const dir = try platformConfigDir(gpa, "PREFIX");
    defer gpa.free(dir);
    // The trailing segment must always be `zay`, never a double separator.
    try std.testing.expect(std.mem.endsWith(u8, dir, "zay"));
    try std.testing.expect(!std.mem.endsWith(u8, dir, "zay/"));
    try std.testing.expect(!std.mem.endsWith(u8, dir, "zay\\"));
}

test "platformConfigDir: rejects a path that drifts from the platform layout" {
    const gpa = std.testing.allocator;
    const dir = try platformConfigDir(gpa, "HOME");
    defer gpa.free(dir);
    // Regression guard: the second-to-last segment must be the platform base
    // (AppData/Roaming on Windows, .config on POSIX), never a typo'd variant.
    // pathsEqual is separator-agnostic, so assert the canonical suffix shape.
    const want_base = if (os.is_windows) "AppData/Roaming" else ".config";
    const expected = try std.fmt.allocPrint(gpa, "HOME/{s}/zay", .{want_base});
    defer gpa.free(expected);
    try std.testing.expect(pathsEqual(dir, expected));
    // The literal 'zay' must appear exactly once, as the final segment.
    var count: u32 = 0;
    var it = std.mem.splitScalar(u8, dir, if (os.is_windows) '\\' else '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "zay")) count += 1;
    }
    try std.testing.expectEqual(count, 1);
}

<<<<<<< HEAD
/// Ensures that a directory exists, creating it and any parent directories if
/// needed. Idempotent: returns without error if the directory already exists.
pub fn ensureDir(dir_path: []const u8) !void {
    std.fs.cwd().makePath(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            log.warn("Failed to create directory {s}: {}", .{ dir_path, err });
            return err;
        }
    };
}

test "ensureDir: creates new directory and nested parents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const gpa = std.testing.allocator;
    const path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "nested", "dir", "sub" });
    defer gpa.free(path);

    // Verify directory does not exist yet
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openDir(path, .{}));

    // ensureDir creates the directory structure
    try ensureDir(path);

    // Verify directory now exists
    var dir = try std.fs.cwd().openDir(path, .{});
    dir.close();
}

test "ensureDir: succeeds idempotently when directory already exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const gpa = std.testing.allocator;
    const path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "existing_dir" });
    defer gpa.free(path);

    // Create directory first time
    try ensureDir(path);

    // Second call on already existing directory must succeed without error
    try ensureDir(path);

    // Verify directory still exists
    var dir = try std.fs.cwd().openDir(path, .{});
    dir.close();
}

test "ensureDir: returns error when path component is a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const gpa = std.testing.allocator;
    const file_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "file.txt" });
    defer gpa.free(file_path);

    // Create a file
    const file = try std.fs.cwd().createFile(file_path, .{});
    file.close();

    // Attempting ensureDir on a subpath of a file should fail (NotDir or similar)
    const invalid_subpath = try std.fs.path.join(gpa, &.{ file_path, "sub" });
    defer gpa.free(invalid_subpath);

    try std.testing.expectError(error.NotDir, ensureDir(invalid_subpath));
}

/// Ensures the platform config directory exists by creating it (and parent
/// directories if needed) on disk. Returns the allocated path slice.
/// Caller owns the returned slice.
pub fn ensureConfigDir(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    const dir = try platformConfigDir(gpa, home_dir);
    errdefer gpa.free(dir);
    try std.fs.cwd().makePath(dir);
    return dir;
}

test "ensureConfigDir_createsDirectoryStructureAndIsIdempotent_whenCalled" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_abs = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_abs);

    const home_dir = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path, "home" });
    defer gpa.free(home_dir);

    // Initial call: creates home_dir + config_dir structure on disk.
    const dir_path = try ensureConfigDir(gpa, home_dir);
    defer gpa.free(dir_path);

    // Assert created path matches platformConfigDir layout
    const expected_dir = try platformConfigDir(gpa, home_dir);
    defer gpa.free(expected_dir);
    try std.testing.expect(pathsEqual(dir_path, expected_dir));

    // Verify directory exists on disk
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    dir.close();

    // Idempotency check: calling ensureConfigDir again when dir already exists succeeds without error
    const dir_path2 = try ensureConfigDir(gpa, home_dir);
    defer gpa.free(dir_path2);
    try std.testing.expect(pathsEqual(dir_path2, expected_dir));
}

/// Returns the global prompt/session history directory derived from the
/// platform config root (`<platformConfigDir>/history`). Caller owns the
/// returned slice.
pub fn getHistoryDir(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    const config_dir = try platformConfigDir(gpa, home_dir);
    defer gpa.free(config_dir);
    return std.fs.path.join(gpa, &.{ config_dir, "history" });
}

test "getHistoryDir: appends history segment under platformConfigDir" {
    const gpa = std.testing.allocator;
    const dir = try getHistoryDir(gpa, "HOME");
    defer gpa.free(dir);

    const want_suffix = if (os.is_windows) "AppData/Roaming/zay/history" else ".config/zay/history";
    const expected = try std.fmt.allocPrint(gpa, "HOME/{s}", .{want_suffix});
    defer gpa.free(expected);

    try std.testing.expect(pathsEqual(dir, expected));
    try std.testing.expectEqualStrings("history", lastPathSegment(dir));
    try std.testing.expect(!std.mem.endsWith(u8, dir, "history/"));
    try std.testing.expect(!std.mem.endsWith(u8, dir, "history\\"));
}

test "getHistoryDir: maintains correct platform layout hierarchy" {
    const gpa = std.testing.allocator;
    const dir = try getHistoryDir(gpa, "MYHOME");
    defer gpa.free(dir);

    const config_dir = try platformConfigDir(gpa, "MYHOME");
    defer gpa.free(config_dir);

    const expected = try std.fs.path.join(gpa, &.{ config_dir, "history" });
    defer gpa.free(expected);

    try std.testing.expect(pathsEqual(dir, expected));
}
