//! Lua Search bridge module — extracted from `plugin_api.zig`.
//!
//! Provides `zay.search_files`, `zay.find_files`, `matchGlob`.

const std = @import("std");
const c = @import("c");
const os = @import("../../os.zig");
const State = @import("../state.zig").State;
const bridge = @import("../bridge.zig");
const execution = @import("../execution.zig");
const shell_bridge = @import("shell.zig");
const fs_bridge = @import("fs.zig");

pub const sanitizePath = shell_bridge.sanitizePath;
pub const max_read_size = fs_bridge.max_read_size;

/// Maximum search results returned by search_files / find_files.
pub const max_search_results: u32 = 200;

/// Default search results limit for find_files.
pub const find_files_default_max_results: u32 = 100;

/// Line-content truncation for search_files results.
pub const search_line_truncate_bytes: usize = 200;

fn getIo(L: *c.lua_State) std.Io {
    return bridge.getIo(L);
}

/// ── zay.search_files(root, pattern, opts?) ──────────────────────────
///
/// Recursively searches files matching pattern. Returns a table with:
///   { query, total_matches, results: [{file, line, content, match}], truncated }
///
/// Optional opts:
///   file_pattern  (string) — glob filter (e.g. "*.lua")
///   case_sensitive (bool)  — default false
///   max_results   (number) — default 50, max 200
pub fn searchFiles(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const root = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("root path argument is required");
        return 2;
    };
    const pattern = bridge.pullValue(&state, []const u8, 2) orelse {
        state.pushNil();
        state.pushString("pattern argument is required");
        return 2;
    };

    var file_pattern: ?[]const u8 = null;
    var case_sensitive = false;
    var max_results: u32 = 50;

    if (state.getTop() >= 3 and state.isTable(3)) {
        if (bridge.getTableString(&state, 3, "file_pattern")) |v| file_pattern = v;
        if (bridge.getTableBoolean(&state, 3, "case_sensitive")) |v| case_sensitive = v;
        if (bridge.getTableInteger(&state, 3, "max_results")) |v| max_results = @intCast(std.math.clamp(v, 1, max_search_results));
    }

    const clean_root = sanitizePath(io, root, execution.dispatchCtx(L_ptr).cwd) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_root);

    state.newTable();
    state.pushString(pattern);
    _ = c.lua_setfield(L_ptr, -2, "query");

    state.newTable();
    var total: u32 = 0;
    var result_count: u32 = 0;

    walkAndSearch(io, clean_root, file_pattern, pattern, case_sensitive, max_results, &total, &result_count, L_ptr) catch |err| {
        _ = c.lua_setfield(L_ptr, -2, "results");
        state.pushString(@errorName(err));
        _ = c.lua_setfield(L_ptr, -2, "error");
        state.pushInteger(@as(i64, @intCast(total)));
        _ = c.lua_setfield(L_ptr, -2, "total_matches");
        state.pushBoolean(result_count < total);
        _ = c.lua_setfield(L_ptr, -2, "truncated");
        return 1;
    };

    _ = c.lua_setfield(L_ptr, -2, "results");
    state.pushInteger(@as(i64, @intCast(total)));
    _ = c.lua_setfield(L_ptr, -2, "total_matches");
    state.pushBoolean(result_count < total);
    _ = c.lua_setfield(L_ptr, -2, "truncated");
    return 1;
}

/// ── zay.find_files(root, pattern, opts?) ───────────────────────────
///
/// Match an exact file's basename or recursively return files whose paths
/// relative to `root` match a glob `pattern`.
pub fn findFiles(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const root = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("root path argument is required");
        return 2;
    };
    const pattern = bridge.pullValue(&state, []const u8, 2) orelse {
        state.pushNil();
        state.pushString("pattern argument is required");
        return 2;
    };

    var max_results: u32 = find_files_default_max_results;
    if (state.getTop() >= 3 and state.isTable(3)) {
        if (bridge.getTableInteger(&state, 3, "max_results")) |v| {
            max_results = @intCast(std.math.clamp(v, 1, @as(i64, max_search_results)));
        }
    }

    const clean_root = sanitizePath(io, root, execution.dispatchCtx(L_ptr).cwd) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_root);

    state.newTable();
    state.pushString(clean_root);
    _ = c.lua_setfield(L_ptr, -2, "root");

    state.newTable();
    var ctx = FindCtx{ .total = 0, .result_count = 0, .max_results = max_results, .root_len = clean_root.len, .L = L_ptr };
    walkAndMatch(io, clean_root, pattern, &ctx) catch |err| {
        _ = c.lua_setfield(L_ptr, -2, "results");
        state.pushString(@errorName(err));
        _ = c.lua_setfield(L_ptr, -2, "error");
        state.pushInteger(@as(i64, @intCast(ctx.total)));
        _ = c.lua_setfield(L_ptr, -2, "total_matches");
        state.pushBoolean(ctx.result_count < ctx.total);
        _ = c.lua_setfield(L_ptr, -2, "truncated");
        return 1;
    };

    _ = c.lua_setfield(L_ptr, -2, "results");
    state.pushInteger(@as(i64, @intCast(ctx.total)));
    _ = c.lua_setfield(L_ptr, -2, "total_matches");
    state.pushBoolean(ctx.result_count < ctx.total);
    _ = c.lua_setfield(L_ptr, -2, "truncated");
    return 1;
}

/// Accumulator threaded through `walkAndMatch`.
pub const FindCtx = struct {
    total: u32,
    result_count: u32,
    max_results: u32,
    root_len: usize,
    L: ?*c.lua_State,
};

/// Cooperative-stop checkpoint for the walk loops (#448): honor the dispatch
/// budget's timeout/cancellation state so a wide tree cannot pin a plugin
/// dispatch. A stopped budget surfaces as a Zig error — the bridge's catch
/// records it and the execution hook re-raises once Lua resumes. Safe no-op
/// without a budget (`execution.check` returns early).
fn checkWalkBudget(L: ?*c.lua_State) !void {
    const l = L orelse return;
    execution.check(l);
    if (execution.stopped(l)) return error.PluginExecutionStopped;
}

/// What a walk can fail with: the dispatch stop, allocation, and the
/// filesystem errors of one entry's open, stat or iteration step. Named
/// because the walks are recursive and classify their own nested failures.
const WalkError = error{ PluginExecutionStopped, OutOfMemory } ||
    std.Io.Dir.OpenError || std.Io.Dir.StatFileError || std.Io.Dir.Iterator.Error;

/// Walk a directory recursively, matching each file's relative path against pattern.
pub fn walkAndMatch(io: std.Io, dir_path: []const u8, pattern: []const u8, ctx: *FindCtx) WalkError!void {
    try checkWalkBudget(ctx.L);
    // An exact root uses the same basename glob contract as search_files.
    if (dir_path.len == ctx.root_len) {
        const stat = try std.Io.Dir.cwd().statFile(io, dir_path, .{});
        if (stat.kind == .file) {
            const name = std.fs.path.basename(dir_path);
            if (!matchGlob(name, pattern)) return;
            ctx.total = 1;
            ctx.result_count = 1;
            var state = State{ .handle = ctx.L orelse return };
            state.newTable();
            state.pushString(dir_path);
            _ = c.lua_setfield(ctx.L.?, -2, "path");
            state.pushString(name);
            _ = c.lua_setfield(ctx.L.?, -2, "name");
            _ = c.lua_rawseti(ctx.L.?, -2, 1);
            return;
        }
    }
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.') continue;

        const full_path = try std.fs.path.join(std.heap.page_allocator, &.{ dir_path, entry.name });
        defer std.heap.page_allocator.free(full_path);

        switch (entry.kind) {
            // Same skip-unreadable policy as the content walk: a
            // dispatch-wide stop ends the listing, an unreadable
            // subdirectory only removes itself from it.
            .directory => walkAndMatch(io, full_path, pattern, ctx) catch |err| return switch (err) {
                error.PluginExecutionStopped, error.OutOfMemory => err,
                else => continue,
            },
            .file => {
                const rel_offset = if (full_path.len > ctx.root_len) ctx.root_len + 1 else full_path.len;
                const rel_path = if (rel_offset <= full_path.len) full_path[rel_offset..] else entry.name;
                if (!matchGlob(rel_path, pattern) and !matchGlob(entry.name, pattern)) continue;

                ctx.total += 1;
                if (ctx.result_count < ctx.max_results) {
                    ctx.result_count += 1;
                    var st = State{ .handle = ctx.L orelse return };
                    st.newTable();
                    st.pushString(full_path);
                    _ = c.lua_setfield(ctx.L.?, -2, "path");
                    st.pushString(entry.name);
                    _ = c.lua_setfield(ctx.L.?, -2, "name");
                    _ = c.lua_rawseti(ctx.L.?, -2, @as(c_int, @intCast(ctx.result_count)));
                }
            },
            else => {},
        }
    }
}

/// Glob match `name` against `pattern`.
pub fn matchGlob(name: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    return globMatchSegment(name, pattern);
}

fn isPathSep(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn appendSegments(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), path: []const u8) !void {
    var start: usize = 0;
    for (path, 0..) |b, i| {
        if (isPathSep(b)) {
            if (i > start) try list.append(allocator, path[start..i]);
            start = i + 1;
        }
    }
    if (start < path.len) {
        try list.append(allocator, path[start..]);
    }
}

pub fn globMatchSegment(name: []const u8, pattern: []const u8) bool {
    var n_segs: std.ArrayList([]const u8) = .empty;
    defer n_segs.deinit(std.heap.page_allocator);
    var p_segs: std.ArrayList([]const u8) = .empty;
    defer p_segs.deinit(std.heap.page_allocator);

    appendSegments(std.heap.page_allocator, &n_segs, name) catch return false;
    appendSegments(std.heap.page_allocator, &p_segs, pattern) catch return false;

    return globMatchSegs(n_segs.items, p_segs.items);
}

fn globMatchSegs(name_segs: []const []const u8, pat_segs: []const []const u8) bool {
    var ni: usize = 0;
    var pi: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: usize = 0;

    while (ni < name_segs.len) {
        if (pi < pat_segs.len and std.mem.eql(u8, pat_segs[pi], "**")) {
            star_pi = pi;
            star_ni = ni;
            pi += 1;
        }
        if (pi < pat_segs.len and segMatch(name_segs[ni], pat_segs[pi])) {
            ni += 1;
            pi += 1;
        } else if (star_pi) |spi| {
            pi = spi + 1;
            star_ni += 1;
            ni = star_ni;
        } else {
            return false;
        }
    }
    while (pi < pat_segs.len and std.mem.eql(u8, pat_segs[pi], "**")) pi += 1;
    return pi == pat_segs.len;
}

fn segMatch(seg: []const u8, pat: []const u8) bool {
    if (std.mem.eql(u8, pat, "*")) return true;
    if (std.mem.eql(u8, pat, "**")) return true;
    var si: usize = 0;
    var pi: usize = 0;
    var star_pi: ?usize = null;
    var star_si: usize = 0;
    while (si < seg.len) {
        if (pi < pat.len and pat[pi] == '*') {
            star_pi = pi;
            star_si = si;
            pi += 1;
        } else if (pi < pat.len and (pat[pi] == '?' or pat[pi] == seg[si])) {
            si += 1;
            pi += 1;
        } else if (star_pi) |spi| {
            pi = spi + 1;
            star_si += 1;
            si = star_si;
        } else {
            return false;
        }
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

/// One search request, shared by the walk and exact-file path.
const SearchCtx = struct {
    root: []const u8,
    file_pattern: ?[]const u8,
    pattern: []const u8,
    case_sensitive: bool,
    max_results: u32,
    total: *u32,
    result_count: *u32,
    L: *c.lua_State,
};

/// Search an exact file or recursively search a directory. The root stays
/// fixed across recursion so path globs are relative to the requested root.
pub fn walkAndSearch(
    io: std.Io,
    dir_path: []const u8,
    file_pattern: ?[]const u8,
    pattern: []const u8,
    case_sensitive: bool,
    max_results: u32,
    total: *u32,
    result_count: *u32,
    L: ?*c.lua_State,
) !void {
    var ctx: SearchCtx = .{
        .root = dir_path,
        .file_pattern = file_pattern,
        .pattern = pattern,
        .case_sensitive = case_sensitive,
        .max_results = max_results,
        .total = total,
        .result_count = result_count,
        .L = L orelse return,
    };
    const stat = try std.Io.Dir.cwd().statFile(io, dir_path, .{});
    if (stat.kind == .file) {
        try searchFile(io, dir_path, &ctx);
    } else {
        try walkSearchDirectory(io, dir_path, &ctx);
    }
}

fn walkSearchDirectory(io: std.Io, dir_path: []const u8, ctx: *SearchCtx) WalkError!void {
    try checkWalkBudget(ctx.L);
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const full_path = try std.fs.path.join(std.heap.page_allocator, &.{ dir_path, entry.name });
        defer std.heap.page_allocator.free(full_path);
        switch (entry.kind) {
            // Preserve the walker's skip-unreadable policy for discovered
            // directories: a dispatch-wide stop still ends the walk, while
            // one unreadable subdirectory only removes itself.
            .directory => walkSearchDirectory(io, full_path, ctx) catch |err| return switch (err) {
                error.PluginExecutionStopped, error.OutOfMemory => err,
                else => continue,
            },
            // Preserve the walker's skip-unreadable policy for discovered files.
            // An explicitly requested file instead reports read errors above.
            .file => searchFile(io, full_path, ctx) catch continue,
            else => {},
        }
    }
}

fn searchFile(io: std.Io, full_path: []const u8, ctx: *SearchCtx) !void {
    if (ctx.file_pattern) |fp| {
        const name = std.fs.path.basename(full_path);
        var relative = full_path[ctx.root.len..];
        if (relative.len > 0 and isPathSep(relative[0])) relative = relative[1..];
        if (relative.len == 0) relative = name;
        if (!matchGlob(relative, fp) and !matchGlob(name, fp)) return;
    }
    // Stat before reading: a file past the cap is skipped without pulling a
    // megabyte off disk first, and only a regular file is ever opened.
    const stat = try std.Io.Dir.cwd().statFile(io, full_path, .{});
    if (stat.kind != .file) return error.UnsupportedFileType;
    if (stat.size > max_read_size) return error.FileTooLarge;

    const L_ptr = ctx.L;
    var file = try std.Io.Dir.openFileAbsolute(io, full_path, .{});
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const content = try reader.interface.allocRemaining(std.heap.page_allocator, .limited(max_read_size));
    defer std.heap.page_allocator.free(content);
    // A NUL byte marks binary content: its "lines" are noise for the model.
    // Ripgrep stops at the first NUL for the same reason.
    if (std.mem.indexOfScalar(u8, content, 0) != null) return;

    var line_num: u32 = 0;
    var pos: usize = 0;
    while (pos < content.len) {
        const next_newline = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
        const line = content[pos..next_newline];
        pos = next_newline + 1;
        line_num += 1;

        const found = if (ctx.case_sensitive)
            std.mem.indexOf(u8, line, ctx.pattern) != null
        else
            std.ascii.indexOfIgnoreCase(line, ctx.pattern) != null;

        if (found) {
            ctx.total.* += 1;
            if (ctx.result_count.* < ctx.max_results) {
                ctx.result_count.* += 1;
                var st = State{ .handle = L_ptr };
                st.newTable();
                st.pushString(full_path);
                _ = c.lua_setfield(L_ptr, -2, "file");
                st.pushInteger(@as(i64, @intCast(line_num)));
                _ = c.lua_setfield(L_ptr, -2, "line");
                st.pushString(truncateLineUtf8(line));
                _ = c.lua_setfield(L_ptr, -2, "content");
                _ = c.lua_rawseti(L_ptr, -2, @as(c_int, @intCast(ctx.result_count.*)));
            }
        }
    }
}

/// Cut `line` to `search_line_truncate_bytes` without splitting a UTF-8
/// sequence: the cut backs up over continuation bytes (`10xxxxxx`).
fn truncateLineUtf8(line: []const u8) []const u8 {
    if (line.len <= search_line_truncate_bytes) return line;
    var end = search_line_truncate_bytes;
    while (end > 0 and (line[end] & 0xc0) == 0x80) end -= 1;
    return line[0..end];
}

test "matchGlob_returnsTrue_whenPatternIsEmpty" {
    // Arrange & Act & Assert
    try std.testing.expect(matchGlob("a.zig", ""));
    try std.testing.expect(matchGlob("src/nested/file.txt", ""));
    try std.testing.expect(matchGlob("", ""));
}

test "matchGlob_returnsTrue_whenLiteralMatchesExactPath" {
    // Arrange & Act & Assert
    try std.testing.expect(matchGlob("main.zig", "main.zig"));
    try std.testing.expect(matchGlob("src/foo/bar.lua", "src/foo/bar.lua"));
}

test "matchGlob_returnsFalse_whenLiteralDiffers" {
    // Arrange & Act & Assert
    try std.testing.expect(!matchGlob("main.zig", "main.lua"));
    try std.testing.expect(!matchGlob("src/foo.zig", "lib/foo.zig"));
}

test "matchGlob_returnsTrue_whenStarMatchesWithinSegment" {
    // Arrange & Act & Assert
    try std.testing.expect(matchGlob("main.zig", "*.zig"));
    try std.testing.expect(matchGlob("test_search.zig", "test_*.zig"));
    try std.testing.expect(matchGlob("file_v1_final.txt", "file_*_final.txt"));
}

test "matchGlob_returnsFalse_whenStarDoesNotCrossDirectorySeparator" {
    // Arrange & Act & Assert
    try std.testing.expect(!matchGlob("src/main.zig", "*.zig"));
    try std.testing.expect(!matchGlob("a/b/c.txt", "a/*.txt"));
}

test "matchGlob_returnsTrue_whenQuestionMarkMatchesSingleChar" {
    // Arrange & Act & Assert
    try std.testing.expect(matchGlob("a.ts", "?.ts"));
    try std.testing.expect(matchGlob("file1.json", "file?.json"));
}

test "matchGlob_returnsFalse_whenQuestionMarkCountMismatches" {
    // Arrange & Act & Assert
    try std.testing.expect(!matchGlob("file12.json", "file?.json"));
    try std.testing.expect(!matchGlob("file.json", "file?.json"));
}

test "matchGlob_returnsTrue_whenDoubleStarMatchesMultipleDirectories" {
    // Arrange & Act & Assert
    try std.testing.expect(matchGlob("src/a/b/c.zig", "src/**/*.zig"));
    try std.testing.expect(matchGlob("src/c.zig", "src/**/*.zig"));
    try std.testing.expect(matchGlob("a/b/c/d/e.txt", "**/*.txt"));
    try std.testing.expect(matchGlob("file.txt", "**/*.txt"));
}

test "matchGlob_returnsTrue_whenTrailingDoubleStarMatchesRemainder" {
    // Arrange & Act & Assert
    try std.testing.expect(matchGlob("src/components/button/index.tsx", "src/**"));
    try std.testing.expect(matchGlob("src", "src/**"));
    try std.testing.expect(!matchGlob("lib/a", "src/**"));
}

test "matchGlob_returnsTrue_whenStarOnlyPatternMatchesAnyName" {
    // Arrange & Act & Assert
    try std.testing.expect(matchGlob("a.ts", "*"));
    // `*` is segment-aware: it matches any single segment, not a whole path.
    try std.testing.expect(!matchGlob("src/a.ts", "*"));
    try std.testing.expect(!matchGlob("", "*.ts"));
}

test "matchGlob_handlesMixedPathSeparators" {
    // Arrange & Act & Assert
    try std.testing.expect(matchGlob("src\\tools\\bash.zig", "src/**/*.zig"));
    try std.testing.expect(matchGlob("src/tools/bash.zig", "src\\**\\*.zig"));
    try std.testing.expect(matchGlob("a\\b\\c.txt", "a/b/*.txt"));
    // Either separator on either side means the same segments.
    try std.testing.expect(matchGlob("src\\tools\\bash.zig", "src/*/*.zig"));
    try std.testing.expect(matchGlob("src\\tools\\bash.zig", "**/*.zig"));
    try std.testing.expect(matchGlob("src\\tools\\bash.zig", "src/tools/bash.zig"));
    try std.testing.expect(matchGlob("src\\tools\\bash.zig", "src\\*\\*.zig"));
    try std.testing.expect(matchGlob("src/tools/bash.zig", "**/*.zig"));
    // Negative space: segment counts still have to line up.
    try std.testing.expect(!matchGlob("src\\tools\\bash.zig", "src/*.zig"));
    try std.testing.expect(!matchGlob("src\\tools\\bash.zig", "lib/**/*.zig"));
}

test "matchGlob_handlesMultipleWildcardsInSingleSegment" {
    // Arrange & Act & Assert
    try std.testing.expect(matchGlob("alpha_beta_gamma.test.js", "*_*_*.test.*"));
    try std.testing.expect(matchGlob("a_b_c.d", "a*b*c*d"));
    try std.testing.expect(matchGlob("abc", "a***b***c"));
}

test "matchGlob_returnsFalse_whenExtensionOrSuffixDiffers" {
    // Arrange & Act & Assert
    try std.testing.expect(!matchGlob("main.zig", "*.lua"));
    try std.testing.expect(!matchGlob("src/a/b.js", "src/**/*.ts"));
}

test "matchGlob_returnsFalse_whenNameIsEmptyAndPatternIsNonEmpty" {
    // Arrange & Act & Assert
    try std.testing.expect(!matchGlob("", "*.zig"));
    try std.testing.expect(matchGlob("", "**"));
}

// ── #448/#449: bounded walks and error-path table shape ──────────────

test "search walks stop with an expired dispatch budget (#448)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "needle here\n" });
    try tmp.dir.createDir(io, "sub", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b.txt", .data = "needle again\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    const sandbox = @import("../sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer sandbox.destroySandboxedState(&L);

    // Deterministic stop: an already-expired deadline arms the timeout stop
    // reason on the first per-directory checkpoint (no wall-clock race).
    execution.budget(L.handle).?.deadline_ns = 1;

    var total: u32 = 0;
    var count: u32 = 0;
    try std.testing.expectError(error.PluginExecutionStopped, walkAndSearch(io, root, null, "needle", false, 50, &total, &count, L.handle));
    try std.testing.expect(execution.stopped(L.handle));

    var ctx = FindCtx{ .total = 0, .result_count = 0, .max_results = 50, .root_len = root.len, .L = L.handle };
    try std.testing.expectError(error.PluginExecutionStopped, walkAndMatch(io, root, "*.txt", &ctx));
}

test "search walks complete under a healthy budget and surface matches" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "needle here\n" });
    try tmp.dir.createDir(io, "sub", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b.txt", .data = "needle again\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    const sandbox = @import("../sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer sandbox.destroySandboxedState(&L);

    // The walks push match rows with lua_rawseti relative to the results
    // table the bridges leave on the stack; mirror that layout here.
    var st = State{ .handle = L.handle };
    st.newTable();
    defer st.pop(1);

    var total: u32 = 0;
    var count: u32 = 0;
    try walkAndSearch(io, root, null, "needle", false, 50, &total, &count, L.handle);
    try std.testing.expectEqual(@as(u32, 2), total);
    try std.testing.expectEqual(@as(u32, 2), count);

    var ctx = FindCtx{ .total = 0, .result_count = 0, .max_results = 50, .root_len = root.len, .L = L.handle };
    try walkAndMatch(io, root, "*.txt", &ctx);
    try std.testing.expectEqual(@as(u32, 2), ctx.total);
    try std.testing.expectEqual(@as(u32, 2), ctx.result_count);
}

test "search bridge error paths keep the table shape including truncated (#449)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);

    const sandbox = @import("../sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer sandbox.destroySandboxedState(&L);
    // Hermetic root: the nonexistent search target resolves under the tmp
    // dir, so the stat failure reaches the walk's error branch instead of
    // the path-sanitizer's.
    execution.setDispatchCtx(L.handle, .{ .cwd = root_buf[0..root_len] });

    try std.testing.expect(L.doString(
        \\local s = zay.search_files("./no-such-zay-dir", "p")
        \\assert(type(s) == "table", "search error path returns a table")
        \\assert(s.error ~= nil, "error field present")
        \\assert(s.total_matches ~= nil, "total_matches field present")
        \\assert(type(s.truncated) == "boolean", "truncated field present on search error path")
        \\local f = zay.find_files("./no-such-zay-dir", "*.p")
        \\assert(type(f) == "table", "find error path returns a table")
        \\assert(f.error ~= nil, "error field present")
        \\assert(type(f.truncated) == "boolean", "truncated field present on find error path")
        \\return "OK"
    ));
}

// ── #590: one bad entry must not take the whole walk down ─────────────

test "search walks skip an unreadable subdirectory and keep searching" {
    if (os.is_windows) return error.SkipZigTest;
    // Root reads a mode-000 directory, so the skip could not be observed.
    if (std.c.getuid() == 0) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "needle here\n" });
    try tmp.dir.createDir(io, "locked", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "locked/b.txt", .data = "needle hidden\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "needle again\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    // Take the read bit off one subdirectory, and put it back on every
    // exit: tmp.cleanup needs it. By path, because a directory opened
    // without iteration is an O_PATH handle, which fchmod rejects.
    const deny_all: std.Io.File.Permissions = @enumFromInt(0o000);
    errdefer tmp.dir.setFilePermissions(io, "locked", .default_dir, .{}) catch {};
    try tmp.dir.setFilePermissions(io, "locked", deny_all, .{});

    const sandbox = @import("../sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer sandbox.destroySandboxedState(&L);
    // The walks push match rows with lua_rawseti relative to the results
    // table the bridges leave on the stack; mirror that layout here.
    var st = State{ .handle = L.handle };
    st.newTable();
    defer st.pop(1);

    var total: u32 = 0;
    var count: u32 = 0;
    try walkAndSearch(io, root, null, "needle", false, 50, &total, &count, L.handle);
    try std.testing.expectEqual(@as(u32, 2), total);
    try std.testing.expectEqual(@as(u32, 2), count);

    var ctx = FindCtx{ .total = 0, .result_count = 0, .max_results = 50, .root_len = root.len, .L = L.handle };
    try walkAndMatch(io, root, "*.txt", &ctx);
    try std.testing.expectEqual(@as(u32, 2), ctx.total);
    try std.testing.expectEqual(@as(u32, 2), ctx.result_count);

    try tmp.dir.setFilePermissions(io, "locked", .default_dir, .{});
}

test "search skips oversized and binary files instead of reading them" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The oversized file opens with the needle: reading it would find it.
    const big = try std.heap.page_allocator.alloc(u8, max_read_size + 6);
    defer std.heap.page_allocator.free(big);
    @memset(big, 'x');
    @memcpy(big[0..6], "needle");
    try tmp.dir.writeFile(io, .{ .sub_path = "big.txt", .data = big });
    try tmp.dir.writeFile(io, .{ .sub_path = "bin.dat", .data = "needle\x00\nneedle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.txt", .data = "needle ok\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const big_path = try std.fs.path.join(std.testing.allocator, &.{ root, "big.txt" });
    defer std.testing.allocator.free(big_path);
    const bin_path = try std.fs.path.join(std.testing.allocator, &.{ root, "bin.dat" });
    defer std.testing.allocator.free(bin_path);

    const sandbox = @import("../sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer sandbox.destroySandboxedState(&L);
    var st = State{ .handle = L.handle };
    st.newTable();
    defer st.pop(1);

    // Discovered: skipped silently, like any other unreadable file.
    var total: u32 = 0;
    var count: u32 = 0;
    try walkAndSearch(io, root, null, "needle", false, 50, &total, &count, L.handle);
    try std.testing.expectEqual(@as(u32, 1), total);
    try std.testing.expectEqual(@as(u32, 1), count);

    // A filename walk never reads the file, so both are still listed.
    var ctx = FindCtx{ .total = 0, .result_count = 0, .max_results = 50, .root_len = root.len, .L = L.handle };
    try walkAndMatch(io, root, "*", &ctx);
    try std.testing.expectEqual(@as(u32, 3), ctx.total);

    // Requested by name: too large is an error the caller asked for; binary
    // simply has no text lines to match.
    total = 0;
    count = 0;
    try std.testing.expectError(error.FileTooLarge, walkAndSearch(io, big_path, null, "needle", false, 50, &total, &count, L.handle));
    try walkAndSearch(io, bin_path, null, "needle", false, 50, &total, &count, L.handle);
    try std.testing.expectEqual(@as(u32, 0), total);

    // Through the bridge the explicit request surfaces as the error field.
    execution.setDispatchCtx(L.handle, .{ .cwd = root });
    const ok = L.doString(
        \\local s = zay.search_files("./big.txt", "needle")
        \\assert(s.error == "FileTooLarge", "oversized explicit file names its error, got " .. tostring(s.error))
        \\local b = zay.search_files("./bin.dat", "needle")
        \\assert(b.error == nil and b.total_matches == 0, "binary explicit file has no matches")
        \\return "OK"
    );
    if (!ok) std.debug.print("Lua error: {s}\n", .{L.getErrorMessage() orelse "unknown"});
    try std.testing.expect(ok);
}

test "search line truncation does not split a UTF-8 sequence" {
    const gpa = std.testing.allocator;
    const limit = search_line_truncate_bytes;
    const pad: []const u8 = "a" ** limit;

    // é (two bytes) starts on the last byte inside the limit: its second
    // byte is the first one cut, so the back-up drops the whole character.
    const straddling = try std.fmt.allocPrint(gpa, "{s}é tail", .{pad[0 .. limit - 1]});
    defer gpa.free(straddling);
    try std.testing.expectEqualStrings(pad[0 .. limit - 1], truncateLineUtf8(straddling));

    // The character ends exactly on the limit and survives whole.
    const inside = try std.fmt.allocPrint(gpa, "{s}é tail", .{pad[0 .. limit - 2]});
    defer gpa.free(inside);
    const inside_expected = try std.fmt.allocPrint(gpa, "{s}é", .{pad[0 .. limit - 2]});
    defer gpa.free(inside_expected);
    try std.testing.expectEqualStrings(inside_expected, truncateLineUtf8(inside));

    // A lead byte right after the limit needs no back-up, and short lines
    // are returned untouched.
    const beyond = try std.fmt.allocPrint(gpa, "{s}é", .{pad});
    defer gpa.free(beyond);
    try std.testing.expectEqualStrings(pad, truncateLineUtf8(beyond));
    try std.testing.expectEqualStrings("short", truncateLineUtf8("short"));
    try std.testing.expectEqualStrings("", truncateLineUtf8(""));
}
