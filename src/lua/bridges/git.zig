//! Lua Git bridge module — extracted from `plugin_api.zig`.
//!
//! Provides `zay.git_status`, `zay.git_diff`, `zay.git_log`, `zay.git_branch`,
//! `zay.git_add`, and `zay.git_commit`.

const std = @import("std");
const c = @import("c");
const State = @import("../state.zig").State;
const bridge = @import("../bridge.zig");
const bash_exec = @import("../../tools/bash_exec.zig");

fn getIo(L: *c.lua_State) std.Io {
    return bridge.getIo(L);
}

/// Helper: shell-quote an argument using single quotes and append to ArrayList.
pub fn appendQuotedArg(list: *std.ArrayList(u8), gpa: std.mem.Allocator, arg: []const u8) !void {
    try list.append(gpa, '\'');
    for (arg) |byte| {
        if (byte == '\'') {
            try list.appendSlice(gpa, "'\\''");
        } else {
            try list.append(gpa, byte);
        }
    }
    try list.append(gpa, '\'');
}

/// Quote one argument for shell command line.
pub fn quoteShellArg(gpa: std.mem.Allocator, s: []const u8, pwsh_rules: bool) std.mem.Allocator.Error![]u8 {
    var quotes: usize = 0;
    for (s) |ch| {
        if (ch == '\'') quotes += 1;
    }
    const extra: usize = if (pwsh_rules) quotes else quotes * 3; // `''` vs `'\''`
    const out = try gpa.alloc(u8, s.len + 2 + extra);
    var i: usize = 0;
    out[i] = '\'';
    i += 1;
    for (s) |ch| {
        out[i] = ch;
        i += 1;
        if (ch == '\'') {
            if (pwsh_rules) {
                out[i] = '\'';
                i += 1;
            } else {
                out[i] = '\\';
                out[i + 1] = '\'';
                out[i + 2] = '\'';
                i += 3;
            }
        }
    }
    out[i] = '\'';
    i += 1;
    std.debug.assert(i == out.len);
    return out;
}

/// Build a plugin-facing error string for a failed git command. Prefers the
/// trimmed stderr (git's own message, e.g. "fatal: not a git repository"),
/// falling back to a generic exit-code message. Returns a slice valid for the
/// duration of the caller's `result` (no allocation).
pub fn gitErrorString(stderr: []const u8, code: u32) []const u8 {
    const trimmed = std.mem.trim(u8, stderr, " \n\r\t");
    if (trimmed.len > 0) return trimmed;
    return std.fmt.bufPrint(&git_err_buf, "git exited with code {d}", .{code}) catch "git failed";
}

var git_err_buf: [64]u8 = undefined;

/// Find git repository root by walking up from `cwd`.
pub fn findGitRoot(io: std.Io, cwd: []const u8) ![]u8 {
    var abs_cwd_buf: ?[]u8 = null;
    defer if (abs_cwd_buf) |b| std.heap.page_allocator.free(b);

    const abs_cwd = if (std.fs.path.isAbsolute(cwd))
        cwd
    else blk: {
        const proc_cwd = try std.process.currentPathAlloc(io, std.heap.page_allocator);
        defer std.heap.page_allocator.free(proc_cwd);
        abs_cwd_buf = try std.fs.path.resolve(std.heap.page_allocator, &.{ proc_cwd, cwd });
        break :blk abs_cwd_buf.?;
    };

    var current = try std.heap.page_allocator.dupe(u8, abs_cwd);
    defer std.heap.page_allocator.free(current);

    while (current.len > 0) {
        const git_path = try std.fs.path.join(std.heap.page_allocator, &.{ current, ".git" });
        defer std.heap.page_allocator.free(git_path);

        var is_git = false;
        if (std.Io.Dir.openDirAbsolute(io, git_path, .{})) |*d| {
            d.close(io);
            is_git = true;
        } else |_| {
            if (std.Io.Dir.openFileAbsolute(io, git_path, .{})) |*f| {
                f.close(io);
                is_git = true;
            } else |_| {}
        }

        if (is_git) {
            return try std.heap.page_allocator.dupe(u8, current);
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const new_current = try std.heap.page_allocator.dupe(u8, parent);
        std.heap.page_allocator.free(current);
        current = new_current;
    }

    return error.NotAGitRepository;
}

/// ── zay.git_status() ───────────────────────────────────────────────
///
/// Returns git status as a string (porcelain format).
pub fn gitStatus(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    var resolved = bridge.resolvePluginCwd(io) orelse {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer resolved.deinit();

    var result = bash_exec.run(std.heap.page_allocator, io, resolved.path, "git status --porcelain") catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    if (result.code != 0) {
        state.pushNil();
        state.pushString(gitErrorString(result.stderr, result.code));
        return 2;
    }

    state.pushString(result.stdout);
    return 1;
}

/// ── zay.git_diff(path?) ─────────────────────────────────────────────
///
/// Returns git diff as a string. Optional path limits diff to a file.
pub fn gitDiff(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1);
    var resolved = bridge.resolvePluginCwd(io) orelse {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer resolved.deinit();

    var cmd: []u8 = undefined;
    if (path) |p| {
        const quoted = quoteShellArg(std.heap.page_allocator, p, false) catch {
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

    var result = bash_exec.runWithOptions(std.heap.page_allocator, io, .{ .cwd = resolved.path, .command = cmd }) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    if (result.code != 0) {
        state.pushNil();
        state.pushString(gitErrorString(result.stderr, result.code));
        return 2;
    }

    state.pushString(result.stdout);
    return 1;
}

/// ── zay.git_log(n) ─────────────────────────────────────────────────
///
/// Returns recent git log entries as a string. n = number of commits (default 10).
pub fn gitLog(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    var n: u32 = 10;
    if (bridge.pullValue(&state, i64, 1)) |v| n = @intCast(@max(v, 1));

    var resolved = bridge.resolvePluginCwd(io) orelse {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer resolved.deinit();

    const cmd = std.fmt.allocPrint(std.heap.page_allocator, "git log --oneline -{d}", .{n}) catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(cmd);

    var result = bash_exec.runWithOptions(std.heap.page_allocator, io, .{ .cwd = resolved.path, .command = cmd }) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    if (result.code != 0) {
        state.pushNil();
        state.pushString(gitErrorString(result.stderr, result.code));
        return 2;
    }

    state.pushString(result.stdout);
    return 1;
}

/// ── zay.git_branch() ───────────────────────────────────────────────
///
/// Returns the current git branch name.
pub fn gitBranch(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    var resolved = bridge.resolvePluginCwd(io) orelse {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer resolved.deinit();

    var result = bash_exec.run(std.heap.page_allocator, io, resolved.path, "git branch --show-current") catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    if (result.code != 0) {
        state.pushNil();
        state.pushString(gitErrorString(result.stderr, result.code));
        return 2;
    }

    const output = std.mem.trimEnd(u8, result.stdout, "\n\r ");
    state.pushString(output);
    return 1;
}

/// ── zay.git_add(files) ─────────────────────────────────────────────
///
/// Stages specific files for git commit. Accepts a single file path string,
/// or an array of file path strings. Returns { success, output }.
pub fn gitAdd(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    if (state.getTop() < 1 or state.isNil(1)) {
        state.pushNil();
        state.pushString("files argument is required");
        return 2;
    }

    var resolved = bridge.resolvePluginCwd(io) orelse {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer resolved.deinit();
    const cwd = resolved.path;

    var cmd_buf: std.ArrayList(u8) = .empty;
    defer cmd_buf.deinit(std.heap.page_allocator);

    cmd_buf.appendSlice(std.heap.page_allocator, "git add --") catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };

    if (state.isString(1)) {
        const file_str = state.toString(1) orelse {
            state.pushNil();
            state.pushString("invalid files string");
            return 2;
        };
        if (std.mem.eql(u8, file_str, ".") or std.mem.eql(u8, file_str, "-A")) {
            cmd_buf.clearRetainingCapacity();
            cmd_buf.appendSlice(std.heap.page_allocator, "git add -A") catch {
                state.pushNil();
                state.pushString("out of memory");
                return 2;
            };
        } else {
            var it = std.mem.tokenizeScalar(u8, file_str, ',');
            while (it.next()) |item| {
                const trimmed = std.mem.trim(u8, item, " \t\r\n");
                if (trimmed.len == 0) continue;
                cmd_buf.append(std.heap.page_allocator, ' ') catch continue;
                appendQuotedArg(&cmd_buf, std.heap.page_allocator, trimmed) catch continue;
            }
        }
    } else if (state.isTable(1)) {
        const len = c.lua_rawlen(L_ptr, 1);
        var i: usize = 1;
        while (i <= len) : (i += 1) {
            _ = c.lua_rawgeti(L_ptr, 1, @intCast(i));
            if (state.isString(-1)) {
                if (state.toString(-1)) |s| {
                    cmd_buf.append(std.heap.page_allocator, ' ') catch continue;
                    appendQuotedArg(&cmd_buf, std.heap.page_allocator, s) catch continue;
                }
            }
            c.lua_pop(L_ptr, 1);
        }
    } else {
        state.pushNil();
        state.pushString("files argument must be a string or table of strings");
        return 2;
    }

    const cmd = cmd_buf.toOwnedSlice(std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(cmd);

    var result = bash_exec.runWithOptions(std.heap.page_allocator, io, .{
        .cwd = cwd,
        .command = cmd,
    }) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    state.newTable();
    state.pushBoolean(result.code == 0);
    _ = c.lua_setfield(L_ptr, -2, "success");
    state.pushString(if (result.code == 0) result.stdout else result.stderr);
    _ = c.lua_setfield(L_ptr, -2, "output");
    return 1;
}

/// ── zay.git_commit(msg, opts?) ────────────────────────────────────
///
/// Creates a git commit with the given message. Returns { success, output }
/// (output = git stderr on failure, or the commit summary on success).
pub fn gitCommit(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const msg = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("commit message argument is required");
        return 2;
    };

    var resolved = bridge.resolvePluginCwd(io) orelse {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer resolved.deinit();
    const cwd = resolved.path;

    var cmd_buf: std.ArrayList(u8) = .empty;
    defer cmd_buf.deinit(std.heap.page_allocator);

    var has_custom_command = false;

    if (state.getTop() >= 2 and state.isTable(2)) {
        if (bridge.getTableBoolean(&state, 2, "staged_only")) |staged_only| {
            if (staged_only) {
                cmd_buf.appendSlice(std.heap.page_allocator, "git commit -F -") catch {};
                has_custom_command = true;
            }
        }

        if (!has_custom_command) {
            _ = c.lua_getfield(L_ptr, 2, "files");
            if (!state.isNil(-1)) {
                if (state.isString(-1)) {
                    if (state.toString(-1)) |f_str| {
                        cmd_buf.appendSlice(std.heap.page_allocator, "git add --") catch {};
                        var it = std.mem.tokenizeScalar(u8, f_str, ',');
                        while (it.next()) |item| {
                            const trimmed = std.mem.trim(u8, item, " \t\r\n");
                            if (trimmed.len == 0) continue;
                            cmd_buf.append(std.heap.page_allocator, ' ') catch continue;
                            appendQuotedArg(&cmd_buf, std.heap.page_allocator, trimmed) catch continue;
                        }
                        cmd_buf.appendSlice(std.heap.page_allocator, " && git commit -F -") catch {};
                        has_custom_command = true;
                    }
                } else if (state.isTable(-1)) {
                    cmd_buf.appendSlice(std.heap.page_allocator, "git add --") catch {};
                    const len = c.lua_rawlen(L_ptr, -1);
                    var i: usize = 1;
                    while (i <= len) : (i += 1) {
                        _ = c.lua_rawgeti(L_ptr, -1, @intCast(i));
                        if (state.isString(-1)) {
                            if (state.toString(-1)) |s| {
                                cmd_buf.append(std.heap.page_allocator, ' ') catch continue;
                                appendQuotedArg(&cmd_buf, std.heap.page_allocator, s) catch continue;
                            }
                        }
                        c.lua_pop(L_ptr, 1);
                    }
                    cmd_buf.appendSlice(std.heap.page_allocator, " && git commit -F -") catch {};
                    has_custom_command = true;
                }
            }
            c.lua_pop(L_ptr, 1); // pop "files"
        }
    }

    if (!has_custom_command) {
        cmd_buf.appendSlice(std.heap.page_allocator, "git add -A && git commit -F -") catch {
            state.pushNil();
            state.pushString("out of memory");
            return 2;
        };
    }

    const cmd = cmd_buf.toOwnedSlice(std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(cmd);

    var result = bash_exec.runWithOptions(std.heap.page_allocator, io, .{
        .cwd = cwd,
        .command = cmd,
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
    state.pushString(if (result.code == 0) result.stdout else result.stderr);
    _ = c.lua_setfield(L_ptr, -2, "output");
    return 1;
}
