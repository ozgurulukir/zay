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
//! - `nova.list_dir(path)` — list directory contents
//! - `nova.file_info(path)` — file metadata
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

    const cmd = if (path) |p|
        std.fmt.allocPrint(std.heap.page_allocator, "git diff -- {s}", .{p}) catch {
            state.pushNil();
            state.pushString("out of memory");
            return 2;
        }
    else
        std.heap.page_allocator.dupe(u8, "git diff") catch {
            state.pushNil();
            state.pushString("out of memory");
            return 2;
        };
    defer std.heap.page_allocator.free(cmd);

    var result = bash_exec.run(std.heap.page_allocator, io, cwd, cmd) catch |err| {
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

    var result = bash_exec.run(std.heap.page_allocator, io, cwd, cmd) catch |err| {
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

    // Stage all and commit
    const cmd = std.fmt.allocPrint(std.heap.page_allocator, "git add -A && git commit -m \"{s}\"", .{msg}) catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(cmd);

    var result = bash_exec.run(std.heap.page_allocator, io, cwd, cmd) catch |err| {
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
    const handler_ref = @as(c_int, @intCast(c.lua_tointeger(L, -1)));
    c.lua_pop(L, 2); // pop handler_ref and entry table

    // Get the handler function from registry
    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, handler_ref);

    // Push params as a Lua table (simple: just push the JSON string for now)
    // In a full implementation, we'd parse JSON to a Lua table.
    // For now, push the raw string — plugins can parse it.
    c.lua_pushlstring(L, params_json.ptr, params_json.len);

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
                    if (!std.mem.endsWith(u8, entry.name, fp[1..])) continue;
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
                            const truncated = if (line.len > 200) line[0..200] else line;
                            st.pushString(truncated);
                            _ = c.lua_setfield(L_ptr, -2, "content");
                            st.pushInteger(@as(i64, @intCast(result_count.*)));
                            _ = c.lua_rawseti(L_ptr, -3, @as(c_int, @intCast(result_count.*)));
                        }
                    }
                }
            },
            else => {},
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────

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
