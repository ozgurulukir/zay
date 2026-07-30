//! Plugin API bridge — exposes Nova's filesystem to Lua plugins.
//!
//! Each function is a C-callable `lua_CFunction` registered in the `nova`
//! table before the sandbox is created. Plugins call these instead of `io.*`,
//! which is blocked by the sandbox. All file operations go through
//! path validation (traversal guard) and size limits.
//!
//! ## Registered functions
//!
//! - `nova.read_file(path, opts?)` — read file with line range + metadata
//! - `nova.write_file(path, content)` — atomic file write
//! - `nova.edit_file(path, old_string, new_string)` — safe find-and-replace
//! - `nova.search_files(root, pattern, opts?)` — recursive grep
//! - `nova.find_files(root, pattern, opts?)` — recursive filename glob match
//! - `nova.list_dir(path)` — list directory contents
//! - `nova.file_info(path)` — file metadata
//! - `nova.mkdir(path)` — create a directory (recursive)
//! - `nova.copy_path(src, dst)` — copy a file
//! - `nova.move_path(src, dst)` — move/rename a file or directory
//! - `nova.delete_path(path, opts?)` — delete a file or directory
//! - `nova.run_bash(cmd, opts?)` — shell command execution
//! - `nova.get_env(name)` — environment variable reading
//! - `nova.get_cwd()` — current working directory
//! - `nova.get_project_root()` — project root
//! - `nova.register_tool(spec)` — register a tool for the AI model
//! - `nova.on(event, callback)` — subscribe to a lifecycle event

const std = @import("std");
const c = @import("c");
const State = @import("state.zig").State;
const bridge = @import("bridge.zig");
const bash_exec = @import("../tools/bash_exec.zig");

/// Maximum file size for read_file (1 MB).
const max_read_size: usize = 1 * 1024 * 1024;

/// Maximum results for search_files.
const max_search_results: u32 = 200;

/// Language map for file extension → language name.
const lang_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "lua", "lua" },
    .{ "py", "python" },
    .{ "js", "javascript" },
    .{ "ts", "typescript" },
    .{ "zig", "zig" },
    .{ "c", "c" },
    .{ "cpp", "cpp" },
    .{ "h", "c" },
    .{ "rs", "rust" },
    .{ "go", "go" },
    .{ "java", "java" },
    .{ "rb", "ruby" },
    .{ "php", "php" },
    .{ "sh", "bash" },
    .{ "bash", "bash" },
    .{ "zsh", "bash" },
    .{ "json", "json" },
    .{ "xml", "xml" },
    .{ "yaml", "yaml" },
    .{ "yml", "yaml" },
    .{ "toml", "toml" },
    .{ "md", "markdown" },
    .{ "txt", "text" },
    .{ "log", "log" },
    .{ "conf", "config" },
    .{ "cfg", "config" },
    .{ "ini", "ini" },
});

/// MIME type map.
const mime_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "lua", "text/x-lua" },
    .{ "py", "text/x-python" },
    .{ "js", "application/javascript" },
    .{ "json", "application/json" },
    .{ "html", "text/html" },
    .{ "css", "text/css" },
    .{ "xml", "application/xml" },
    .{ "md", "text/markdown" },
    .{ "txt", "text/plain" },
    .{ "png", "image/png" },
    .{ "jpg", "image/jpeg" },
    .{ "jpeg", "image/jpeg" },
    .{ "gif", "image/gif" },
    .{ "svg", "image/svg+xml" },
});

/// Retrieve the Io instance stored in the Lua registry.
fn getIo(L: *c.lua_State) std.Io {
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "nova_io");
    defer c.lua_pop(L, 1);
    const ptr = c.lua_touserdata(L, -1);
    return @as(*const std.Io, @ptrCast(@alignCast(ptr))).*;
}

/// ── nova.read_file(path, opts?) ──────────────────────────────────────
///
/// Reads a file and returns a table with:
///   { content, size, lines, language, mime_type, path }
///
/// Optional `opts` table fields:
///   start_line (number) — first line to return (1-indexed)
///   end_line   (number) — last line to return
///   max_size   (number) — max bytes to read (default 1MB)
///
/// Returns nil + error message on failure.
pub fn readFile(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("path argument is required");
        return 2;
    };

    const clean_path = sanitizePath(io, path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_path);

    var start_line: ?u32 = null;
    var end_line: ?u32 = null;
    var max_size: usize = max_read_size;

    if (state.getTop() >= 2 and state.isTable(2)) {
        if (bridge.getTableInteger(&state, 2, "start_line")) |v| start_line = @intCast(@max(v, 1));
        if (bridge.getTableInteger(&state, 2, "end_line")) |v| end_line = @intCast(@max(v, 1));
        if (bridge.getTableInteger(&state, 2, "max_size")) |v| max_size = @min(@as(usize, @intCast(v)), max_read_size);
    }

    const content = readFileBytes(io, clean_path, max_size) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(content);

    const final_content = if (start_line != null or end_line != null)
        applyLineRange(content, start_line, end_line)
    else
        content;

    state.newTable();
    state.pushString(clean_path);
    _ = c.lua_setfield(L_ptr, -2, "path");
    state.pushString(final_content);
    _ = c.lua_setfield(L_ptr, -2, "content");
    state.pushInteger(@as(i64, @intCast(final_content.len)));
    _ = c.lua_setfield(L_ptr, -2, "size");
    state.pushInteger(@as(i64, @intCast(countLines(final_content))));
    _ = c.lua_setfield(L_ptr, -2, "lines");
    state.pushString(detectLanguage(clean_path, content));
    _ = c.lua_setfield(L_ptr, -2, "language");
    state.pushString(getMimeType(clean_path));
    _ = c.lua_setfield(L_ptr, -2, "mime_type");
    return 1;
}

/// ── nova.write_file(path, content) ──────────────────────────────────
///
/// Writes content to a file atomically. Returns true on success.
/// Returns nil + error message on failure.
pub fn writeFile(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("path argument is required");
        return 2;
    };
    const content = bridge.pullValue(&state, []const u8, 2) orelse {
        state.pushNil();
        state.pushString("content argument is required");
        return 2;
    };

    const clean_path = sanitizePath(io, path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_path);

    writeFileAtomic(io, clean_path, content) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };

    state.pushBoolean(true);
    return 1;
}

/// ── nova.edit_file(path, old_string, new_string) ─────────────────────
///
/// Replaces first occurrence of old_string with new_string in a file.
/// Returns true on success, or nil + error on failure.
pub fn editFile(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("path argument is required");
        return 2;
    };
    const old_string = bridge.pullValue(&state, []const u8, 2) orelse {
        state.pushNil();
        state.pushString("old_string argument is required");
        return 2;
    };
    const new_string = bridge.pullValue(&state, []const u8, 3) orelse {
        state.pushNil();
        state.pushString("new_string argument is required");
        return 2;
    };

    const clean_path = sanitizePath(io, path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_path);

    const content = readFileBytes(io, clean_path, max_read_size) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(content);

    const index = std.mem.indexOf(u8, content, old_string) orelse {
        state.pushNil();
        state.pushString("old_string not found in file");
        return 2;
    };

    const new_content = std.mem.concat(std.heap.page_allocator, u8, &.{
        content[0..index],
        new_string,
        content[index + old_string.len ..],
    }) catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(new_content);

    writeFileAtomic(io, clean_path, new_content) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };

    state.pushBoolean(true);
    return 1;
}

/// ── nova.search_files(root, pattern, opts?) ──────────────────────────
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
        if (bridge.getTableInteger(&state, 3, "max_results")) |v| max_results = @min(@as(u32, @intCast(v)), max_search_results);
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

/// ── nova.list_dir(path) ─────────────────────────────────────────────
///
/// Lists directory contents. Returns a table with:
///   { path, files: [{name}], directories: [{name}], total_items }
pub fn listDir(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("path argument is required");
        return 2;
    };

    const clean_path = sanitizePath(io, path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_path);

    var dir = std.Io.Dir.openDirAbsolute(io, clean_path, .{ .iterate = true }) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer dir.close(io);

    state.newTable();
    state.pushString(clean_path);
    _ = c.lua_setfield(L_ptr, -2, "path");

    state.newTable();
    const files_table = c.lua_gettop(L_ptr);
    state.newTable();
    const dirs_table = c.lua_gettop(L_ptr);
    var file_count: u32 = 0;
    var dir_count: u32 = 0;

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        switch (entry.kind) {
            .file => {
                file_count += 1;
                state.pushString(entry.name);
                _ = c.lua_rawseti(L_ptr, files_table, @as(c_int, @intCast(file_count)));
            },
            .directory => {
                dir_count += 1;
                state.pushString(entry.name);
                _ = c.lua_rawseti(L_ptr, dirs_table, @as(c_int, @intCast(dir_count)));
            },
            else => {},
        }
    }

    _ = c.lua_setfield(L_ptr, -3, "directories");
    _ = c.lua_setfield(L_ptr, -2, "files");
    state.pushInteger(@as(i64, @intCast(file_count + dir_count)));
    _ = c.lua_setfield(L_ptr, -2, "total_items");
    return 1;
}

/// ── nova.find_files(root, pattern, opts?) ───────────────────────────
///
/// Recursively walk `root` and return every file whose **path relative to
/// root** matches a glob `pattern`. The match covers the path relative to
/// `root`, so `**/*.zig` matches every `.zig` file at any depth and
/// `src/**/*.ts` only matches under `src/`.
///
/// Optional `opts` table fields:
///   max_results (number) — cap on returned paths (default 100, hard cap 200)
///
/// Returns a table: `{ root, total_matches, truncated, results: [{path, name}] }`.
/// `truncated` is true when more files matched than were returned. Directory
/// walk skips dotfile entries (names beginning with `.`). gitignore is NOT
/// honored (documented gap — use `run_bash` with `rg --files` if needed).
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

    var max_results: u32 = 100;
    if (state.getTop() >= 3 and state.isTable(3)) {
        if (bridge.getTableInteger(&state, 3, "max_results")) |v| {
            max_results = @min(@as(u32, @intCast(v)), max_search_results);
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
const FindCtx = struct {
    total: u32,
    result_count: u32,
    max_results: u32,
    /// Length of the cleaned root path, used to derive the relative path
    /// (the portion of `full_path` after `root + sep`) for glob matching.
    root_len: usize,
    L: ?*c.lua_State,
};

/// Walk a directory recursively, matching each file's relative path against
/// `pattern`. Mirrors `walkAndSearch`'s structure but matches filenames
/// instead of file contents, and never opens the file body.
fn walkAndMatch(io: std.Io, dir_path: []const u8, pattern: []const u8, ctx: *FindCtx) !void {
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
                // Relative path = full_path with the root prefix stripped.
                const rel_offset = if (full_path.len > ctx.root_len) ctx.root_len + 1 else full_path.len;
                const rel_path = if (rel_offset <= full_path.len) full_path[rel_offset..] else entry.name;
                if (!matchGlob(rel_path, pattern) and !matchGlob(entry.name, pattern)) continue;

                ctx.total += 1;
                if (ctx.result_count < ctx.max_results) {
                    ctx.result_count += 1;
                    var st = State{ .handle = ctx.L orelse return };
                    // [ ... | results_table ]
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

/// Glob match `name` (a relative path or a bare filename) against `pattern`.
///
/// Supports the wildcards coding-agent models commonly emit:
///   `**` — match any number of path segments (incl. across separators)
///   `*`  — match any run of characters within a single path segment
///   `?`  — match exactly one character
///   literal text — match verbatim
/// An empty pattern matches everything. Matching is case-sensitive (paths are
/// case-sensitive on Linux); the `*` and `?` semantics deliberately do not
/// cross `/` so `src/*.ts` does not match `src/nested/a.ts`.
pub fn matchGlob(name: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    return globMatchSegment(name, pattern);
}

/// Recursive segment-aware glob matcher. `*` and `?` stop at `/`; only `**`
/// spans separators. Implemented iteratively over pattern segments to keep the
/// recursion bounded by pattern length (not input length).
fn globMatchSegment(name: []const u8, pattern: []const u8) bool {
    // Split the pattern and name into `/`-delimited segments and match segment
    // by segment. A `**` segment consumes zero or more name segments.
    var n_it = std.mem.splitScalar(u8, name, '/');
    var p_it = std.mem.splitScalar(u8, pattern, '/');
    var n_segs: std.ArrayList([]const u8) = .empty;
    defer n_segs.deinit(std.heap.page_allocator);
    var p_segs: std.ArrayList([]const u8) = .empty;
    defer p_segs.deinit(std.heap.page_allocator);
    while (n_it.next()) |s| n_segs.append(std.heap.page_allocator, s) catch return false;
    while (p_it.next()) |s| p_segs.append(std.heap.page_allocator, s) catch return false;
    return globMatchSegs(n_segs.items, p_segs.items);
}

fn globMatchSegs(name_segs: []const []const u8, pat_segs: []const []const u8) bool {
    var ni: usize = 0;
    var pi: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: usize = 0;

    while (ni < name_segs.len) {
        if (pi < pat_segs.len and std.mem.eql(u8, pat_segs[pi], "**")) {
            // `**` matches zero or more segments; record backtrack point.
            star_pi = pi;
            star_ni = ni;
            pi += 1;
        }
        if (pi < pat_segs.len and segMatch(name_segs[ni], pat_segs[pi])) {
            ni += 1;
            pi += 1;
        } else if (star_pi) |spi| {
            // Backtrack: let `**` consume one more segment.
            pi = spi + 1;
            star_ni += 1;
            ni = star_ni;
        } else {
            return false;
        }
    }
    // Trailing `**` segments match the (now-empty) remainder.
    while (pi < pat_segs.len and std.mem.eql(u8, pat_segs[pi], "**")) pi += 1;
    return pi == pat_segs.len;
}

/// Match a single path segment (no `/`) against a single pattern segment
/// supporting `*` (zero+ chars) and `?` (one char).
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

/// ── nova.mkdir(path) ─────────────────────────────────────────────────
///
/// Create a directory, including parents (recursive). Returns `true` or
/// `nil, err`. The path is sanitized — traversal outside the project root is
/// rejected. Prefer this over `run_bash("mkdir ...")` so the path stays
/// sandboxed.
pub fn mkdir(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("path argument is required");
        return 2;
    };

    const clean_path = sanitizePath(io, path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_path);

    std.Io.Dir.createDirPath(.cwd(), io, clean_path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    state.pushBoolean(true);
    return 1;
}

/// ── nova.copy_path(src, dst) ─────────────────────────────────────────
///
/// Copy a file from `src` to `dst`. Both paths are sanitized. Returns `true`
/// or `nil, err`. Directories are not supported (use `run_bash` for tree
/// copies); this keeps the operation simple and predictable.
pub fn copyPath(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const src = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("source path argument is required");
        return 2;
    };
    const dst = bridge.pullValue(&state, []const u8, 2) orelse {
        state.pushNil();
        state.pushString("destination path argument is required");
        return 2;
    };

    const clean_src = sanitizePath(io, src) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_src);
    const clean_dst = sanitizePath(io, dst) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_dst);

    std.Io.Dir.copyFileAbsolute(clean_src, clean_dst, io, .{}) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    state.pushBoolean(true);
    return 1;
}

/// ── nova.move_path(src, dst) ─────────────────────────────────────────
///
/// Move (rename) a file or directory from `src` to `dst`. Both paths are
/// sanitized; works across directory boundaries on the same filesystem.
/// Returns `true` or `nil, err`.
pub fn movePath(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const src = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("source path argument is required");
        return 2;
    };
    const dst = bridge.pullValue(&state, []const u8, 2) orelse {
        state.pushNil();
        state.pushString("destination path argument is required");
        return 2;
    };

    const clean_src = sanitizePath(io, src) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_src);
    const clean_dst = sanitizePath(io, dst) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_dst);

    std.Io.Dir.renameAbsolute(clean_src, clean_dst, io) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    state.pushBoolean(true);
    return 1;
}

/// ── nova.delete_path(path, opts?) ───────────────────────────────────
///
/// Delete a file or directory. Optional `opts.recursive` (boolean, default
/// `false`) controls whether a non-empty directory is removed with its
/// contents. The path is sanitized — traversal outside the project root is
/// rejected, and `recursive` defaults off so a plugin must explicitly opt in
/// to tree deletion. Prefer this over `run_bash("rm -rf ...")` which runs
/// unclassified and unguarded in the plugin sandbox.
pub fn deletePath(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("path argument is required");
        return 2;
    };
    var recursive = false;
    if (state.getTop() >= 2 and state.isTable(2)) {
        if (bridge.getTableBoolean(&state, 2, "recursive")) |v| recursive = v;
    }

    const clean_path = sanitizePath(io, path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_path);

    // Stat to decide file vs directory, then call the matching deleter. This
    // avoids relying on error-kind discrimination from the delete call.
    var dir = std.Io.Dir.openDirAbsolute(io, clean_path, .{}) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    const is_dir = blk: {
        const dstat = dir.stat(io) catch {
            dir.close(io);
            state.pushNil();
            state.pushString("stat failed");
            return 2;
        };
        break :blk dstat.kind == .directory;
    };
    dir.close(io);

    if (is_dir) {
        if (recursive) {
            // No static `deleteTreeAbsolute`; open the parent and delete the
            // leaf by basename so the whole tree is removed in one call.
            const parent = std.fs.path.dirname(clean_path) orelse {
                state.pushNil();
                state.pushString("cannot determine parent directory");
                return 2;
            };
            const base = std.fs.path.basename(clean_path);
            var parent_dir = std.Io.Dir.openDirAbsolute(io, parent, .{}) catch |err| {
                state.pushNil();
                state.pushString(@errorName(err));
                return 2;
            };
            defer parent_dir.close(io);
            parent_dir.deleteTree(io, base) catch |err| {
                state.pushNil();
                state.pushString(@errorName(err));
                return 2;
            };
        } else {
            std.Io.Dir.deleteDirAbsolute(io, clean_path) catch |err| {
                state.pushNil();
                state.pushString(@errorName(err));
                return 2;
            };
        }
    } else {
        std.Io.Dir.deleteFileAbsolute(io, clean_path) catch |err| {
            state.pushNil();
            state.pushString(@errorName(err));
            return 2;
        };
    }
    state.pushBoolean(true);
    return 1;
}

/// ── nova.file_info(path) ─────────────────────────────────────────────
///
/// Returns file metadata: { size, type, extension, language, mime_type }
/// Returns nil + error on failure.
pub fn fileInfo(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("path argument is required");
        return 2;
    };

    const clean_path = sanitizePath(io, path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_path);

    var file = std.Io.Dir.openFileAbsolute(io, clean_path, .{}) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };

    state.newTable();
    state.pushInteger(@as(i64, @intCast(stat.size)));
    _ = c.lua_setfield(L_ptr, -2, "size");

    const kind_str = switch (stat.kind) {
        .file => "file",
        .directory => "directory",
        else => "other",
    };
    state.pushString(kind_str);
    _ = c.lua_setfield(L_ptr, -2, "type");

    state.pushString(getExtension(clean_path));
    _ = c.lua_setfield(L_ptr, -2, "extension");

    state.pushString(detectLanguage(clean_path, ""));
    _ = c.lua_setfield(L_ptr, -2, "language");

    state.pushString(getMimeType(clean_path));
    _ = c.lua_setfield(L_ptr, -2, "mime_type");
    return 1;
}

/// ── nova.run_bash(cmd, opts?) ────────────────────────────────────────
///
/// Runs a shell command and returns a table with:
///   { stdout, stderr, code }
///
/// Optional `opts` table fields:
///   cwd     (string) — working directory (default: project root)
///   timeout (number) — timeout in seconds (default: 10)
///
/// Returns nil + error message on failure.
pub fn runBash(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const cmd = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("command argument is required");
        return 2;
    };

    var cwd: ?[]const u8 = null;
    var timeout_seconds: u32 = bash_exec.timeout_seconds_default;

    if (state.getTop() >= 2 and state.isTable(2)) {
        if (bridge.getTableString(&state, 2, "cwd")) |v| cwd = v;
        if (bridge.getTableInteger(&state, 2, "timeout")) |v| timeout_seconds = @max(@as(u32, @intCast(v)), 1);
    }

    const resolved_cwd = if (cwd) |path| blk: {
        break :blk sanitizePath(io, path) catch {
            state.pushNil();
            state.pushString("invalid cwd path");
            return 2;
        };
    } else blk: {
        break :blk std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
            state.pushNil();
            state.pushString("could not resolve cwd");
            return 2;
        };
    };
    defer std.heap.page_allocator.free(resolved_cwd);

    var result = bash_exec.runWithOptions(std.heap.page_allocator, io, .{
        .cwd = resolved_cwd,
        .command = cmd,
        .timeout = bash_exec.timeoutFromSeconds(timeout_seconds),
    }) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    state.newTable();
    state.pushString(result.stdout);
    _ = c.lua_setfield(L_ptr, -2, "stdout");
    state.pushString(result.stderr);
    _ = c.lua_setfield(L_ptr, -2, "stderr");
    state.pushInteger(@as(i64, @intCast(result.code)));
    _ = c.lua_setfield(L_ptr, -2, "code");
    return 1;
}

/// ── nova.get_env(name) ───────────────────────────────────────────────
///
/// Returns the value of an environment variable, or nil if not set.
pub fn getEnv(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    const name = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("name argument is required");
        return 2;
    };

    // Ensure null-terminated for C API
    const name_buf = std.heap.page_allocator.alloc(u8, name.len + 1) catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(name_buf);
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;

    const value_ptr = std.c.getenv(name_buf[0..name.len :0]) orelse {
        state.pushNil();
        return 1;
    };

    const value = std.mem.sliceTo(value_ptr, 0);
    state.pushString(value);
    return 1;
}

/// ── nova.get_cwd() ──────────────────────────────────────────────────
///
/// Returns the current working directory as a string.
pub fn getCwd(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const cwd = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer std.heap.page_allocator.free(cwd);

    state.pushString(cwd);
    return 1;
}

/// ── nova.get_project_root() ─────────────────────────────────────────
///
/// Returns the project root directory (git repo root, or cwd if not a repo).
pub fn getProjectRoot(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const cwd = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer std.heap.page_allocator.free(cwd);

    const root = findGitRoot(io, cwd) catch cwd;
    defer if (root.ptr != cwd.ptr) std.heap.page_allocator.free(root);

    state.pushString(root);
    return 1;
}

/// ── nova.git_status() ───────────────────────────────────────────────
///
/// Returns git status as a string (porcelain format).
pub fn gitStatus(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const cwd = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer std.heap.page_allocator.free(cwd);

    var result = bash_exec.run(std.heap.page_allocator, io, cwd, "git status --porcelain") catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    state.pushString(result.stdout);
    return 1;
}

/// ── nova.git_diff(path?) ─────────────────────────────────────────────
///
/// Returns git diff as a string. Optional path limits diff to a file.
pub fn gitDiff(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1);
    const cwd = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer std.heap.page_allocator.free(cwd);

    // Build `git diff [-- <escaped-path>]`. The path is single-quote-escaped so
    // a malicious `path = "x; rm -rf ~"` cannot break out of the argument —
    // it becomes a literal argument to `git diff`, not shell syntax. Quotes
    // inside the path are neutralized by the `'` → `'\''` transform.
    var cmd: []u8 = undefined;
    if (path) |p| {
        const quoted = shellQuote(std.heap.page_allocator, p) catch {
            state.pushNil();
            state.pushString("out of memory");
            return 2;
        };
        defer std.heap.page_allocator.free(quoted);
        cmd = std.fmt.allocPrint(std.heap.page_allocator, "git diff -- {s}", .{quoted}) catch {
            state.pushNil();
            state.pushString("out of memory");
            return 2;
        };
    } else {
        cmd = std.heap.page_allocator.dupe(u8, "git diff") catch {
            state.pushNil();
            state.pushString("out of memory");
            return 2;
        };
    }
    defer std.heap.page_allocator.free(cmd);

    var result = bash_exec.runWithOptions(std.heap.page_allocator, io, .{ .cwd = cwd, .command = cmd }) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    state.pushString(result.stdout);
    return 1;
}

/// ── nova.git_log(n) ─────────────────────────────────────────────────
///
/// Returns recent git log entries as a string. n = number of commits (default 10).
pub fn gitLog(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    var n: u32 = 10;
    if (bridge.pullValue(&state, i64, 1)) |v| n = @intCast(@max(v, 1));

    const cwd = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer std.heap.page_allocator.free(cwd);

    const cmd = std.fmt.allocPrint(std.heap.page_allocator, "git log --oneline -{d}", .{n}) catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(cmd);

    // `n` is a clamped integer, so it carries no injection risk; routing through
    // runWithOptions keeps the command on the classified path regardless.
    var result = bash_exec.runWithOptions(std.heap.page_allocator, io, .{ .cwd = cwd, .command = cmd }) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    state.pushString(result.stdout);
    return 1;
}

/// ── nova.git_branch() ───────────────────────────────────────────────
///
/// Returns the current git branch name.
pub fn gitBranch(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const cwd = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer std.heap.page_allocator.free(cwd);

    var result = bash_exec.run(std.heap.page_allocator, io, cwd, "git branch --show-current") catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    // Trim trailing newline
    const output = std.mem.trimEnd(u8, result.stdout, "\n\r ");
    state.pushString(output);
    return 1;
}

/// ── nova.git_commit(msg) ────────────────────────────────────────────
///
/// Creates a git commit with the given message. Returns { hash, success }.
pub fn gitCommit(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const msg = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("commit message argument is required");
        return 2;
    };

    const cwd = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer std.heap.page_allocator.free(cwd);

    // Stage all and commit. The message is piped via stdin to `git commit -F -`
    // so shell metacharacters in `msg` are never interpreted — embedding it in
    // `-m "{msg}"` would let `msg = 'x"; rm -rf ~; #'` break out of the quotes.
    var result = bash_exec.runWithOptions(std.heap.page_allocator, io, .{
        .cwd = cwd,
        .command = "git add -A && git commit -F -",
        .stdin = msg,
    }) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    state.newTable();
    state.pushBoolean(result.code == 0);
    _ = c.lua_setfield(L_ptr, -2, "success");
    state.pushString(result.stderr);
    _ = c.lua_setfield(L_ptr, -2, "output");
    return 1;
}

/// ── nova.think(prompt) ──────────────────────────────────────────────
///
/// Sends a prompt to the LLM and returns the response.
/// This is a stub implementation — full integration requires access to
/// the active AI client, which will be wired in a future phase.
/// For now, returns an error message indicating the feature is not yet available.
pub fn think(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    const prompt = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("prompt argument is required");
        return 2;
    };

    // Stub: full implementation requires threading the AI client into the
    // plugin API. The Lua registry only stores std.Io; we'd need to also
    // store a pointer to the LanguageModel for recursive LLM calls.
    // For now, return an informative message.
    _ = prompt;
    state.pushNil();
    state.pushString("nova.think() is not yet implemented — requires AI client integration");
    return 2;
}

/// ── nova.register_tool(spec) ─────────────────────────────────────────
///
/// Registers a tool that the AI model can call. The spec table must have:
///   name (string) — tool name (lowercase, underscores)
///   description (string) — description for the model
///   parameters (table) — parameter definitions
///   handler (function) — called with params when the model invokes the tool
///
/// Stores the spec in the Lua registry under "nova_tools" as a table of
/// { name, description, parameters, handler_ref } entries. The handler is
/// stored as a registry reference (luaL_ref) so it survives garbage collection.
/// Returns true on success.
pub fn registerTool(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    // arg 1: spec table
    if (!state.isTable(1)) {
        state.pushNil();
        state.pushString("spec table argument is required");
        return 2;
    }

    std.log.debug("plugin.registerTool.start", .{});

    // Extract fields from spec
    const name = bridge.getTableString(&state, 1, "name") orelse {
        state.pushNil();
        state.pushString("spec.name is required");
        return 2;
    };
    const description = bridge.getTableString(&state, 1, "description") orelse {
        state.pushNil();
        state.pushString("spec.description is required");
        return 2;
    };

    // Get the handler function and store it as a registry reference
    _ = c.lua_getfield(L_ptr, 1, "handler");
    if (!state.isFunction(-1)) {
        state.pop(1);
        state.pushNil();
        state.pushString("spec.handler must be a function");
        return 2;
    }
    const handler_ref = c.luaL_ref(L_ptr, c.LUA_REGISTRYINDEX);

    // Get or create the nova_tools table in the registry
    _ = c.lua_getfield(L_ptr, c.LUA_REGISTRYINDEX, "nova_tools");
    if (state.isNil(-1)) {
        state.pop(1);
        state.newTable();
        _ = c.lua_pushvalue(L_ptr, -1);
        _ = c.lua_setfield(L_ptr, c.LUA_REGISTRYINDEX, "nova_tools");
    }
    const tools_table = c.lua_gettop(L_ptr);

    // Count existing entries to get next index
    const next_idx = c.lua_rawlen(L_ptr, tools_table) + 1;

    // Create entry table: { name, description, parameters, handler_ref }
    state.newTable();
    state.pushString(name);
    _ = c.lua_setfield(L_ptr, -2, "name");
    state.pushString(description);
    _ = c.lua_setfield(L_ptr, -2, "description");

    // Copy parameters table from spec
    _ = c.lua_getfield(L_ptr, 1, "parameters");
    if (state.isTable(-1)) {
        _ = c.lua_setfield(L_ptr, -2, "parameters");
    } else {
        state.pop(1);
        state.newTable();
        _ = c.lua_setfield(L_ptr, -2, "parameters");
    }

    // Store handler_ref as integer
    state.pushInteger(@as(i64, @intCast(handler_ref)));
    _ = c.lua_setfield(L_ptr, -2, "handler_ref");

    // Append entry to tools table
    _ = c.lua_rawseti(L_ptr, tools_table, @as(c_int, @intCast(next_idx)));

    // Pop tools table
    state.pop(1);

    std.log.debug("plugin.registerTool.ok name={s}", .{name});
    state.pushBoolean(true);
    return 1;
}

/// ── nova.on(event, callback) ────────────────────────────────────────
///
/// Subscribes to a lifecycle event. Stores the callback as a registry
/// reference in the "nova_events" table keyed by event name.
/// Returns true on success.
pub fn onEvent(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    const event_name = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("event name argument is required");
        return 2;
    };

    if (!state.isFunction(2)) {
        state.pushNil();
        state.pushString("callback must be a function");
        return 2;
    }

    // Store callback as registry reference
    const callback_ref = c.luaL_ref(L_ptr, c.LUA_REGISTRYINDEX);

    // Get or create nova_events table in registry
    _ = c.lua_getfield(L_ptr, c.LUA_REGISTRYINDEX, "nova_events");
    if (state.isNil(-1)) {
        state.pop(1);
        state.newTable();
        _ = c.lua_pushvalue(L_ptr, -1);
        _ = c.lua_setfield(L_ptr, c.LUA_REGISTRYINDEX, "nova_events");
    }
    const events_table = c.lua_gettop(L_ptr);

    // Get or create the event's sub-table
    _ = c.lua_getfield(L_ptr, events_table, event_name.ptr);
    if (state.isNil(-1)) {
        state.pop(1);
        state.newTable();
        _ = c.lua_pushvalue(L_ptr, -1);
        _ = c.lua_setfield(L_ptr, events_table, event_name.ptr);
    }
    const event_subtable = c.lua_gettop(L_ptr);

    // Append callback_ref to the event's sub-table
    const next_idx = c.lua_rawlen(L_ptr, event_subtable) + 1;
    state.pushInteger(@as(i64, @intCast(callback_ref)));
    _ = c.lua_rawseti(L_ptr, event_subtable, @as(c_int, @intCast(next_idx)));

    state.pop(2); // pop event_subtable and events_table

    state.pushBoolean(true);
    return 1;
}

/// Count registered tools in a Lua state by reading "nova_tools" from registry.
pub fn countTools(L: *c.lua_State) u32 {
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "nova_tools");
    defer c.lua_pop(L, 1);
    if (c.lua_isnil(L, -1)) return 0;
    return @intCast(c.lua_rawlen(L, -1));
}

/// Find the index of a registered tool by name in the Lua registry.
/// Returns the 1-based index used by `callToolHandler`, or null if not found.
pub fn findToolIndex(L: *c.lua_State, tool_name: []const u8) ?c_int {
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "nova_tools");
    defer c.lua_pop(L, 1);
    if (c.lua_isnil(L, -1)) return null;

    const tools_len = c.lua_rawlen(L, -1);
    var i: c_int = 1;
    while (i <= @as(c_int, @intCast(tools_len))) : (i += 1) {
        _ = c.lua_rawgeti(L, -1, i);
        _ = c.lua_getfield(L, -1, "name");
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len);
        const found = if (ptr) |p| std.mem.eql(u8, p[0..len], tool_name) else false;
        c.lua_pop(L, 2); // pop name string and entry table
        if (found) return i;
    }
    return null;
}

/// Parse a JSON string and push the result onto the Lua stack as a Lua value
/// (table, string, number, boolean, or nil). The caller owns the parsed JSON
/// value; it is freed before returning.
fn pushJsonToLua(L: *c.lua_State, gpa: std.mem.Allocator, json: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try pushJsonValue(L, gpa, parsed.value);
}

/// Recursively push a `std.json.Value` onto the Lua stack.
fn pushJsonValue(L: *c.lua_State, gpa: std.mem.Allocator, value: std.json.Value) !void {
    switch (value) {
        .null => c.lua_pushnil(L),
        .bool => |b| c.lua_pushboolean(L, if (b) 1 else 0),
        .integer => |i| c.lua_pushinteger(L, i),
        .float => |f| c.lua_pushnumber(L, f),
        .number_string => |s| {
            // Try integer first, then float
            const num = std.fmt.parseFloat(f64, s) catch {
                _ = c.lua_pushstring(L, s.ptr);
                return;
            };
            c.lua_pushnumber(L, num);
        },
        .string => |s| {
            _ = c.lua_pushlstring(L, s.ptr, s.len);
        },
        .array => |items| {
            c.lua_createtable(L, @intCast(items.items.len), 0);
            for (items.items, 0..) |item, i| {
                try pushJsonValue(L, gpa, item);
                c.lua_rawseti(L, -2, @intCast(i + 1));
            }
        },
        .object => |obj| {
            c.lua_createtable(L, 0, @intCast(obj.count()));
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                _ = c.lua_pushlstring(L, entry.key_ptr.ptr, entry.key_ptr.len);
                try pushJsonValue(L, gpa, entry.value_ptr.*);
                _ = c.lua_settable(L, -3);
            }
        },
    }
}

/// Call a registered tool handler by index. Pushes the params table onto
/// the Lua stack, calls the handler, and returns the result string.
/// The caller must keep the Lua state alive during the call.
/// Returns the handler's return value as a string (owned by caller).
pub fn callToolHandler(
    L: *c.lua_State,
    gpa: std.mem.Allocator,
    tool_index: c_int,
    params_json: []const u8,
) ![]u8 {
    // Get nova_tools[index].handler_ref
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "nova_tools");
    if (c.lua_isnil(L, -1)) {
        c.lua_pop(L, 1);
        return error.NoToolsRegistered;
    }
    _ = c.lua_rawgeti(L, -1, tool_index);
    _ = c.lua_getfield(L, -1, "handler_ref");
    var isnum: c_int = 0;
    const handler_ref = @as(c_int, @intCast(c.lua_tointegerx(L, -1, &isnum)));
    c.lua_pop(L, 2); // pop handler_ref and entry table

    // Get the handler function from registry
    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, handler_ref);

    // Parse JSON params into a Lua table so handlers can use table access
    // (e.g. params.depth, params.pattern) instead of manual JSON parsing.
    pushJsonToLua(L, gpa, params_json) catch {
        c.lua_newtable(L);
    };

    // Call handler(params_json)
    const rc = c.lua_pcallk(L, 1, 1, 0, 0, null);
    if (rc != c.LUA_OK) {
        const err_msg = c.lua_tolstring(L, -1, null);
        const msg = if (err_msg) |p| std.mem.sliceTo(p, 0) else "unknown error";
        const result = try std.fmt.allocPrint(gpa, "Lua tool error: {s}", .{msg});
        c.lua_pop(L, 1); // pop error
        c.lua_pop(L, 1); // pop tools table
        return result;
    }

    // Get result string
    var len: usize = 0;
    const result_ptr = c.lua_tolstring(L, -1, &len);
    const result = if (result_ptr) |p| try gpa.dupe(u8, p[0..len]) else try gpa.dupe(u8, "");

    c.lua_pop(L, 2); // pop result and tools table
    return result;
}

// ── helpers ──────────────────────────────────────────────────────────

/// Sanitize a path: resolve `..` and `.` segments, reject traversal.
fn sanitizePath(io: std.Io, path: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const cwd = try std.process.currentPathAlloc(io, std.heap.page_allocator);
    defer std.heap.page_allocator.free(cwd);
    const resolved = try std.fs.path.resolve(std.heap.page_allocator, &.{ cwd, path });
    errdefer std.heap.page_allocator.free(resolved);
    if (!std.mem.startsWith(u8, resolved, cwd)) return error.PathTraversal;
    if (resolved.len > cwd.len and resolved[cwd.len] != std.fs.path.sep) return error.PathTraversal;
    return resolved;
}

/// Read file bytes with size limit.
fn readFileBytes(io: std.Io, path: []const u8, max_size: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const read_size = @min(@as(usize, @intCast(stat.size)), max_size);
    const bytes = try std.heap.page_allocator.alloc(u8, read_size);
    errdefer std.heap.page_allocator.free(bytes);
    var reader = file.reader(io, &.{});
    try reader.interface.readSliceAll(bytes);
    return bytes;
}

/// Atomic file write: write to temp, then rename.
fn writeFileAtomic(io: std.Io, path: []const u8, content: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.tmp", .{path});
    defer std.heap.page_allocator.free(tmp_path);
    var file = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
    try std.Io.Dir.renameAbsolute(tmp_path, path, io);
}

/// Apply line range to content.
fn applyLineRange(content: []const u8, start_line: ?u32, end_line: ?u32) []const u8 {
    const start = start_line orelse 1;
    if (start <= 1 and end_line == null) return content;

    var line_start: usize = 0;
    var current_line: u32 = 1;

    // Advance to start line
    while (current_line < start) {
        if (std.mem.indexOfScalarPos(u8, content, line_start, '\n')) |pos| {
            line_start = pos + 1;
            current_line += 1;
        } else {
            return content[0..0];
        }
    }

    // If no end line, return from start to end of content
    if (end_line == null) return content[line_start..];

    const end = end_line.?;
    var line_end = line_start;
    while (current_line <= end) {
        if (std.mem.indexOfScalarPos(u8, content, line_end, '\n')) |pos| {
            line_end = pos + 1;
            current_line += 1;
        } else {
            line_end = content.len;
            break;
        }
    }

    // Remove trailing newline if present
    if (line_end > line_start and content[line_end - 1] == '\n') {
        return content[line_start .. line_end - 1];
    }
    return content[line_start..line_end];
}

/// Count lines in text.
fn countLines(text: []const u8) u32 {
    var count: u32 = 1;
    for (text) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

/// Detect programming language from file extension.
fn detectLanguage(path: []const u8, content: []const u8) []const u8 {
    const ext = getExtension(path);
    if (lang_map.get(ext)) |lang| return lang;
    if (content.len > 0 and content[0] == '#' and content.len > 1 and content[1] == '!') return "script";
    return "text";
}

/// Get MIME type from file extension.
fn getMimeType(path: []const u8) []const u8 {
    const ext = getExtension(path);
    return mime_map.get(ext) orelse "application/octet-stream";
}

/// Get file extension (lowercase).
fn getExtension(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "";
    return path[dot + 1 ..];
}

/// Find git repository root by walking up from `cwd`.
fn findGitRoot(io: std.Io, cwd: []const u8) ![]u8 {
    var current = try std.heap.page_allocator.dupe(u8, cwd);
    defer std.heap.page_allocator.free(current);

    while (current.len > 0) {
        const git_path = try std.fs.path.join(std.heap.page_allocator, &.{ current, ".git" });
        defer std.heap.page_allocator.free(git_path);

        var file = std.Io.Dir.openFileAbsolute(io, git_path, .{}) catch {
            // Go up one directory
            const parent = std.fs.path.dirname(current) orelse break;
            const new_current = try std.heap.page_allocator.dupe(u8, parent);
            std.heap.page_allocator.free(current);
            current = new_current;
            continue;
        };
        file.close(io);
        return try std.heap.page_allocator.dupe(u8, current);
    }

    return error.GitRootNotFound;
}

/// Single-quote-escape `arg` so it can be embedded as a single shell argument
/// without being interpreted. Wraps the result in `'...'` and rewrites every
/// embedded `'` as `'\''` — the standard idiom that closes the quote, emits a
/// literal quote, and reopens. A malicious `path = "x'; rm -rf ~; #"` becomes
/// `'x'\''; rm -rf ~; #'`, which the shell sees as one inert argument.
/// Caller owns the returned slice.
fn shellQuote(gpa: std.mem.Allocator, arg: []const u8) std.mem.Allocator.Error![]u8 {
    // Worst case: every byte is a quote, each expanding to 4 bytes (`'\''`),
    // plus the two wrapping quotes.
    const max_len = arg.len * 4 + 2;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(gpa, max_len);
    errdefer out.deinit(gpa);

    try out.append(gpa, '\'');
    for (arg) |byte| {
        if (byte == '\'') {
            try out.appendSlice(gpa, "'\\''");
        } else {
            try out.append(gpa, byte);
        }
    }
    try out.append(gpa, '\'');
    return out.toOwnedSlice(gpa);
}

/// Test whether `name` matches the user-supplied `file_pattern`.
///
/// `file_pattern` is the loose glob the plugin passed (e.g. `"*.lua"`). It is
/// matched as a suffix test:
///   - empty  → matches everything (the historical segfault: `fp[1..]` indexed
///     a zero-length slice and panicked with SIGABRT on `list_project_files("")`)
///   - `"*x"` → strip the leading `*`, then suffix-match on `"x"`
///   - `"x"`  → suffix-match verbatim
///
/// Kept as a free function so the suffix logic is unit-testable in isolation.
fn fileNameMatches(name: []const u8, file_pattern: []const u8) bool {
    if (file_pattern.len == 0) return true;
    const suffix = if (file_pattern[0] == '*') file_pattern[1..] else file_pattern;
    return std.mem.endsWith(u8, name, suffix);
}

/// Walk directory recursively and search for pattern.
fn walkAndSearch(
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
                            // Stack layout here: [ ... | results_table ]
                            // Build the entry, then `results[result_count] = entry`
                            // via lua_rawseti which pops it and leaves the
                            // results table on top. The previous code pushed an
                            // extra integer and used -3 as the table index,
                            // which leaked one entry table per match and wrote
                            // the bare integer into results[i] instead of the
                            // entry.
                            var st = State{ .handle = L_ptr };
                            st.newTable(); // [ ... | results_table | entry ]
                            st.pushString(full_path);
                            _ = c.lua_setfield(L_ptr, -2, "file");
                            st.pushInteger(@as(i64, @intCast(line_num)));
                            _ = c.lua_setfield(L_ptr, -2, "line");
                            const truncated = if (line.len > 200) line[0..200] else line;
                            st.pushString(truncated);
                            _ = c.lua_setfield(L_ptr, -2, "content");
                            _ = c.lua_rawseti(L_ptr, -2, @as(c_int, @intCast(result_count.*)));
                            // [ ... | results_table ]
                        }
                    }
                }
            },
            else => {},
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "fileNameMatches: empty pattern matches everything (regression for SIGABRT)" {
    // Used to be `fp[1..]` which panicked (index-out-of-bounds) on `""`,
    // crashing the agent when a plugin passed an empty file_pattern
    // (Lua treats "" as truthy, so project-info/search-tool forwarded it).
    try std.testing.expect(fileNameMatches("anything.lua", ""));
    try std.testing.expect(fileNameMatches("Makefile", ""));
}

test "fileNameMatches: star glob strips leading star" {
    try std.testing.expect(fileNameMatches("main.lua", "*.lua"));
    try std.testing.expect(fileNameMatches("vendor/init.lua", "*.lua"));
    try std.testing.expect(!fileNameMatches("main.zig", "*.lua"));
}

test "fileNameMatches: bare suffix matches verbatim" {
    try std.testing.expect(fileNameMatches("main.lua", ".lua"));
    try std.testing.expect(fileNameMatches("config.json", "json"));
    try std.testing.expect(!fileNameMatches("config.json", ".lua"));
}

test "fileNameMatches: star-only pattern matches everything" {
    try std.testing.expect(fileNameMatches("anything.lua", "*"));
    try std.testing.expect(fileNameMatches("README", "*"));
}

test "detectLanguage: known extensions" {
    try std.testing.expectEqualStrings("zig", detectLanguage("main.zig", ""));
    try std.testing.expectEqualStrings("lua", detectLanguage("init.lua", ""));
    try std.testing.expectEqualStrings("python", detectLanguage("script.py", ""));
    try std.testing.expectEqualStrings("javascript", detectLanguage("app.js", ""));
    try std.testing.expectEqualStrings("markdown", detectLanguage("README.md", ""));
}

test "detectLanguage: shebang detection" {
    try std.testing.expectEqualStrings("script", detectLanguage("script", "#!/usr/bin/env bash"));
}

test "detectLanguage: unknown extension" {
    try std.testing.expectEqualStrings("text", detectLanguage("file.xyz", ""));
}

test "getMimeType: known types" {
    try std.testing.expectEqualStrings("text/x-lua", getMimeType("test.lua"));
    try std.testing.expectEqualStrings("application/json", getMimeType("config.json"));
    try std.testing.expectEqualStrings("text/markdown", getMimeType("README.md"));
}

test "getMimeType: unknown extension" {
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("file.xyz"));
}

test "getExtension: extracts extension" {
    try std.testing.expectEqualStrings("zig", getExtension("main.zig"));
    try std.testing.expectEqualStrings("lua", getExtension("init.lua"));
}

test "getExtension: no extension" {
    try std.testing.expectEqualStrings("", getExtension("Makefile"));
}

test "countLines: empty text" {
    try std.testing.expectEqual(@as(u32, 1), countLines(""));
}

test "countLines: single line" {
    try std.testing.expectEqual(@as(u32, 1), countLines("hello world"));
}

test "countLines: multiple lines" {
    try std.testing.expectEqual(@as(u32, 3), countLines("line1\nline2\nline3"));
}

test "applyLineRange: no range returns full content" {
    const content = "line1\nline2\nline3";
    try std.testing.expectEqualStrings(content, applyLineRange(content, null, null));
}

test "applyLineRange: start_line only" {
    const content = "line1\nline2\nline3\nline4";
    try std.testing.expectEqualStrings("line2\nline3\nline4", applyLineRange(content, 2, null));
}

test "applyLineRange: start and end" {
    const content = "line1\nline2\nline3\nline4";
    try std.testing.expectEqualStrings("line2\nline3", applyLineRange(content, 2, 3));
}

test "applyLineRange: past end returns empty" {
    const content = "line1\nline2";
    try std.testing.expectEqualStrings("", applyLineRange(content, 10, null));
}

test "registerTool + countTools: sandboxed state" {
    const sandbox = @import("sandbox.zig");

    // Create a sandboxed state with Io (so registerPluginApi is called).
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    // Before registration, there should be 0 tools.
    try std.testing.expectEqual(@as(u32, 0), countTools(L.handle));

    // Register a tool via Lua code (same as what init.lua does).
    const ok = L.doString(
        \\nova.register_tool({
        \\  name = "test_tool",
        \\  description = "A test tool",
        \\  parameters = {
        \\    foo = { type = "string", description = "A foo param" },
        \\  },
        \\  handler = function(params) return "ok" end,
        \\})
    );
    if (!ok) {
        const err = L.getErrorMessage();
        std.debug.print("Lua error: {s}\n", .{err orelse "unknown"});
        L.pop(1);
    }
    try std.testing.expect(ok);

    // After registration, countTools should see 1 tool.
    try std.testing.expectEqual(@as(u32, 1), countTools(L.handle));
}

// ── glob matcher unit tests ──────────────────────────────────────────

test "matchGlob: empty pattern matches everything" {
    try std.testing.expect(matchGlob("a.zig", ""));
    try std.testing.expect(matchGlob("src/foo.ts", ""));
}

test "matchGlob: literal pattern matches verbatim" {
    try std.testing.expect(matchGlob("main.zig", "main.zig"));
    try std.testing.expect(!matchGlob("main.zig", "main.lua"));
}

test "matchGlob: star within segment" {
    try std.testing.expect(matchGlob("main.zig", "*.zig"));
    try std.testing.expect(matchGlob("a.ts", "*.ts"));
    try std.testing.expect(!matchGlob("a.js", "*.ts"));
}

test "matchGlob: star does not cross separator" {
    try std.testing.expect(!matchGlob("src/a.ts", "*.ts"));
    try std.testing.expect(matchGlob("a.ts", "*"));
}

test "matchGlob: double-star spans directories" {
    try std.testing.expect(matchGlob("src/a.zig", "**/*.zig"));
    try std.testing.expect(matchGlob("src/nested/b.zig", "**/*.zig"));
    try std.testing.expect(matchGlob("a.zig", "**/*.zig"));
    try std.testing.expect(!matchGlob("a.lua", "**/*.zig"));
}

test "matchGlob: double-star under prefix" {
    try std.testing.expect(matchGlob("src/nested/a.ts", "src/**/*.ts"));
    try std.testing.expect(matchGlob("src/a.ts", "src/**/*.ts"));
    try std.testing.expect(!matchGlob("lib/a.ts", "src/**/*.ts"));
}

test "matchGlob: single-char question mark" {
    try std.testing.expect(matchGlob("a.ts", "?.ts"));
    try std.testing.expect(matchGlob("ab.ts", "a?.ts"));
    try std.testing.expect(!matchGlob("abc.ts", "a?.ts"));
}

test "matchGlob: trailing double-star matches remainder" {
    try std.testing.expect(matchGlob("src/a/b/c", "src/**"));
    try std.testing.expect(matchGlob("src", "src/**"));
    try std.testing.expect(!matchGlob("lib/a", "src/**"));
}

// ── P0: shell-injection regression tests ──────────────────────────────
//
// The git bridges (`gitDiff`/`gitLog`/`gitCommit`) previously embedded
// plugin-supplied strings into a `bash -c` command, letting a malicious plugin
// break out of quotes. Each test drives the exact escaping/stdin path the
// bridges now use and asserts an injection payload leaves no side effect.

/// Run a shell command, discarding its output and any error. For best-effort
/// test cleanup (`rm -rf`) where the result is irrelevant; keeps call sites a
/// single line instead of repeating the bind/deinit/discard ladder.
fn ignoreRun(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, command: []const u8) void {
    var result = bash_exec.run(gpa, io, cwd, command) catch return;
    result.deinit(gpa);
}

/// True when `git` is on PATH (so the git-backed injection tests can run).
fn gitAvailable() bool {
    if (std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "git", "--version" },
    })) |r| {
        std.testing.allocator.free(r.stdout);
        std.testing.allocator.free(r.stderr);
        return true;
    } else |_| return false;
}

/// Create an empty git repo under `/tmp/nova-inject-test`, returning the path.
/// Caller frees the path; the dir is removed via the shell. Sets a deterministic
/// identity so `git commit` does not refuse to run.
fn makeInjectionTestRepo(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const dir = try std.fs.path.join(gpa, &.{ "/tmp", "nova-inject-test" });
    errdefer gpa.free(dir);
    ignoreRun(gpa, io, "/tmp", "rm -rf nova-inject-test");
    var result = try bash_exec.run(
        gpa,
        io,
        "/tmp",
        "mkdir -p nova-inject-test && git -C nova-inject-test init -q && " ++
            "git -C nova-inject-test config user.email t@t && " ++
            "git -C nova-inject-test config user.name t",
    );
    result.deinit(gpa);
    return dir;
}

/// True iff the file at `absolute_path` exists. Routed through the shell so the
/// test does not depend on a specific Dir API name for absolute paths.
fn fileExists(gpa: std.mem.Allocator, io: std.Io, absolute_path: []const u8) bool {
    const cmd = std.fmt.allocPrint(gpa, "test -f {s}", .{absolute_path}) catch return false;
    defer gpa.free(cmd);
    var result = bash_exec.run(gpa, io, "/tmp", cmd) catch return false;
    defer result.deinit(gpa);
    return result.code == 0;
}

test "shellQuote: plain argument is wrapped in single quotes" {
    const gpa = std.testing.allocator;
    const quoted = try shellQuote(gpa, "src/main.zig");
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings("'src/main.zig'", quoted);
}

test "shellQuote: embedded quote is escaped (injection vector neutralized)" {
    const gpa = std.testing.allocator;
    const quoted = try shellQuote(gpa, "x'; rm -rf ~; #");
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings("'x'\\''; rm -rf ~; #'", quoted);
}

test "shellQuote: empty argument becomes two quotes" {
    const gpa = std.testing.allocator;
    const quoted = try shellQuote(gpa, "");
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings("''", quoted);
}

test "gitCommit: injection payload stays a literal commit message (stdin path)" {
    if (!gitAvailable()) return;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = try makeInjectionTestRepo(gpa, io);
    defer {
        ignoreRun(gpa, io, "/tmp", "rm -rf nova-inject-test");
        gpa.free(dir);
    }

    // The injection vector from the plan: a quote-break-out attempt. With the
    // old `-m "{msg}"` it would run `touch /tmp/pwned_nova`; with `-F -` +
    // stdin it must become the literal commit subject.
    const marker = "/tmp/pwned_nova_commit";
    ignoreRun(gpa, io, "/tmp", "rm -f pwned_nova_commit");
    const payload = "x\"; touch " ++ marker ++ "; #";
    var result = try bash_exec.runWithOptions(gpa, io, .{
        .cwd = dir,
        .command = "git add -A && git commit -F -",
        .stdin = payload,
    });
    result.deinit(gpa);

    // The marker file must NOT exist: the payload never reached the shell.
    try std.testing.expect(!fileExists(gpa, io, marker));
    ignoreRun(gpa, io, "/tmp", "rm -f pwned_nova_commit");
}

test "gitDiff: injection payload stays a literal pathspec (shellQuote path)" {
    if (!gitAvailable()) return;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = try makeInjectionTestRepo(gpa, io);
    defer {
        ignoreRun(gpa, io, "/tmp", "rm -rf nova-inject-test");
        gpa.free(dir);
    }

    // A commit so `git diff` has something to diff against.
    var setup = try bash_exec.run(gpa, io, dir, "echo a > f && git add -A && git commit -q -m init");
    setup.deinit(gpa);

    const marker = "/tmp/pwned_nova_diff";
    ignoreRun(gpa, io, "/tmp", "rm -f pwned_nova_diff");
    // The quote-break-out payload, funneled through `shellQuote` exactly as
    // `gitDiff` does, must become one inert pathspec.
    const quoted = try shellQuote(gpa, "x'; touch " ++ marker ++ "; #");
    defer gpa.free(quoted);
    const cmd = try std.fmt.allocPrint(gpa, "git diff -- {s}", .{quoted});
    defer gpa.free(cmd);
    var result = try bash_exec.runWithOptions(gpa, io, .{
        .cwd = dir,
        .command = cmd,
    });
    result.deinit(gpa);

    try std.testing.expect(!fileExists(gpa, io, marker));
    ignoreRun(gpa, io, "/tmp", "rm -f pwned_nova_diff");
}

test "RunOptions.stdin bypasses shell interpretation" {
    // The stdin path passes the payload verbatim to the child, so shell
    // metacharacters in it are data, not syntax. Confirm `cat` echoes the
    // payload untouched (no command-substitution, no quoting collapse).
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var result = try bash_exec.runWithOptions(gpa, std.testing.io, .{
        .cwd = cwd,
        .command = "cat",
        .stdin = "a$(touch /tmp/pwned_nova_stdin)b",
    });
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("a$(touch /tmp/pwned_nova_stdin)b", result.stdout);
    ignoreRun(gpa, std.testing.io, "/tmp", "rm -f pwned_nova_stdin");
}
