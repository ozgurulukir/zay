//! Lua Search bridge module — extracted from `plugin_api.zig`.
//!
//! Provides `zay.search_files`, `zay.find_files`, `matchGlob`, `fileNameMatches`.

const std = @import("std");
const c = @import("c");
const State = @import("../state.zig").State;
const bridge = @import("../bridge.zig");
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
        if (bridge.getTableInteger(&state, 3, "max_results")) |v| max_results = @min(@as(u32, @intCast(@max(v, 1))), max_search_results);
    }

    const clean_root = sanitizePath(io, root) catch |err| {
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
/// Recursively walk `root` and return every file whose **path relative to
/// root** matches a glob `pattern`.
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
            max_results = @min(@as(u32, @intCast(@max(v, 1))), max_search_results);
        }
    }

    const clean_root = sanitizePath(io, root) catch |err| {
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

/// Walk a directory recursively, matching each file's relative path against pattern.
pub fn walkAndMatch(io: std.Io, dir_path: []const u8, pattern: []const u8, ctx: *FindCtx) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.') continue;

        const full_path = try std.fs.path.join(std.heap.page_allocator, &.{ dir_path, entry.name });
        defer std.heap.page_allocator.free(full_path);

        switch (entry.kind) {
            .directory => try walkAndMatch(io, full_path, pattern, ctx),
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

/// Test whether `name` matches the user-supplied `file_pattern`.
pub fn fileNameMatches(name: []const u8, file_pattern: []const u8) bool {
    if (file_pattern.len == 0) return true;
    const suffix = if (file_pattern[0] == '*') file_pattern[1..] else file_pattern;
    return std.mem.endsWith(u8, name, suffix);
}

/// Walk directory recursively and search for pattern.
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
    const L_ptr = L orelse return;
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.') continue;

        const full_path = try std.fs.path.join(std.heap.page_allocator, &.{ dir_path, entry.name });
        defer std.heap.page_allocator.free(full_path);

        switch (entry.kind) {
            .directory => {
                try walkAndSearch(io, full_path, file_pattern, pattern, case_sensitive, max_results, total, result_count, L);
            },
            .file => {
                if (file_pattern) |fp| {
                    if (!fileNameMatches(entry.name, fp)) continue;
                }

                var file = std.Io.Dir.openFileAbsolute(io, full_path, .{}) catch continue;
                defer file.close(io);

                var reader = file.reader(io, &.{});
                const content = reader.interface.allocRemaining(std.heap.page_allocator, .limited(max_read_size)) catch continue;
                defer std.heap.page_allocator.free(content);

                var line_num: u32 = 0;
                var pos: usize = 0;
                while (pos < content.len) {
                    const next_newline = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
                    const line = content[pos..next_newline];
                    pos = next_newline + 1;
                    line_num += 1;

                    const found = if (case_sensitive)
                        std.mem.indexOf(u8, line, pattern) != null
                    else
                        std.ascii.indexOfIgnoreCase(line, pattern) != null;

                    if (found) {
                        total.* += 1;
                        if (result_count.* < max_results) {
                            result_count.* += 1;
                            var st = State{ .handle = L_ptr };
                            st.newTable();
                            st.pushString(full_path);
                            _ = c.lua_setfield(L_ptr, -2, "file");
                            st.pushInteger(@as(i64, @intCast(line_num)));
                            _ = c.lua_setfield(L_ptr, -2, "line");
                            const truncated = if (line.len > search_line_truncate_bytes) line[0..search_line_truncate_bytes] else line;
                            st.pushString(truncated);
                            _ = c.lua_setfield(L_ptr, -2, "content");
                            _ = c.lua_rawseti(L_ptr, -2, @as(c_int, @intCast(result_count.*)));
                        }
                    }
                }
            },
            else => {},
        }
    }
}
