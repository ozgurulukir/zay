//! Lua Filesystem bridge module — extracted from `plugin_api.zig`.
//!
//! Provides file I/O operations for Lua plugins: `zay.read_file`, `zay.write_file`,
//! `zay.edit_file`, `zay.mkdir`, `zay.copy_path`, `zay.move_path`, `zay.delete_path`,
//! `zay.list_dir`, `zay.file_info`.

const std = @import("std");
const c = @import("c");
const State = @import("../state.zig").State;
const bridge = @import("../bridge.zig");
const shell_bridge = @import("shell.zig");
pub const fs_ops = @import("fs_ops.zig");

pub const sanitizePath = shell_bridge.sanitizePath;
pub const max_read_size = fs_ops.max_read_size;
pub const lang_map = fs_ops.lang_map;
pub const mime_map = fs_ops.mime_map;
pub const EditFileError = fs_ops.EditFileError;
pub const editFileSplice = fs_ops.editFileSplice;
pub const readFileBytes = fs_ops.readFileBytes;
pub const statFileSize = fs_ops.statFileSize;
pub const writeFileAtomic = fs_ops.writeFileAtomic;
pub const deleteFileBestEffort = fs_ops.deleteFileBestEffort;
pub const applyLineRange = fs_ops.applyLineRange;
pub const countLines = fs_ops.countLines;
pub const detectLanguage = fs_ops.detectLanguage;
pub const getMimeType = fs_ops.getMimeType;
pub const getExtension = fs_ops.getExtension;

fn getIo(L: *c.lua_State) std.Io {
    return bridge.getIo(L);
}

/// ── zay.read_file(path, opts?) ──────────────────────────────────────
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
        // Clamp on the i64 before the usize cast so a negative max_size can't
        // panic (safe builds) or wrap to ~2^64 (ReleaseFast).
        if (bridge.getTableInteger(&state, 2, "max_size")) |v| max_size = @min(@as(usize, @intCast(@max(v, 0))), max_read_size);
    }

    const content = readFileBytes(io, clean_path, max_size) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(content);

    // Expose truncation so plugins can detect (and page around) the 1 MB cap.
    const full_size = statFileSize(io, clean_path) catch @as(u64, content.len);

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
    state.pushBoolean(full_size > final_content.len);
    _ = c.lua_setfield(L_ptr, -2, "truncated");
    state.pushInteger(@as(i64, @intCast(full_size)));
    _ = c.lua_setfield(L_ptr, -2, "full_size");
    state.pushString(detectLanguage(clean_path, content));
    _ = c.lua_setfield(L_ptr, -2, "language");
    state.pushString(getMimeType(clean_path));
    _ = c.lua_setfield(L_ptr, -2, "mime_type");
    return 1;
}

/// ── zay.write_file(path, content) ──────────────────────────────────
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

/// ── zay.edit_file(path, old_string, new_string) ─────────────────────
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

    editFileSplice(io, clean_path, old_string, new_string) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };

    state.pushBoolean(true);
    return 1;
}

/// ── zay.list_dir(path) ─────────────────────────────────────────────
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

/// ── zay.mkdir(path) ─────────────────────────────────────────────────
///
/// Create a directory, including parents (recursive). Returns `true` or `nil, err`.
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

/// ── zay.copy_path(src, dst) ─────────────────────────────────────────
///
/// Copy a file from `src` to `dst`. Both paths are sanitized.
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

/// ── zay.move_path(src, dst) ─────────────────────────────────────────
///
/// Move (rename) a file or directory from `src` to `dst`. Both paths are sanitized.
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

/// ── zay.delete_path(path, opts?) ───────────────────────────────────
///
/// Delete a file or directory. Optional `opts.recursive` controls recursive deletion.
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

    var resolved_cwd = bridge.resolvePluginCwd(io);
    defer if (resolved_cwd) |*r| r.deinit();
    const cwd: []const u8 = if (resolved_cwd) |r| r.path else "";
    if (cwd.len > 0 and std.mem.eql(u8, clean_path, cwd)) {
        state.pushNil();
        state.pushString("cannot delete project root directory");
        return 2;
    }

    var is_dir = false;
    if (std.Io.Dir.openDirAbsolute(io, clean_path, .{})) |*dir| {
        dir.close(io);
        is_dir = true;
    } else |_| {}

    if (is_dir) {
        if (recursive) {
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

/// ── zay.file_info(path) ─────────────────────────────────────────────
///
/// Returns file metadata: { size, type, extension, language, mime_type }
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

