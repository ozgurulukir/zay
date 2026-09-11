//! Lua Shell bridge module — extracted from `plugin_api.zig`.
//!
//! Provides `zay.run_bash`, `zay.run_shell`, `zay.get_env`, `zay.get_cwd`,
//! `zay.get_project_root`, and `zay.shell_quote`.

const std = @import("std");
const c = @import("c");
const State = @import("../state.zig").State;
const bridge = @import("../bridge.zig");
const bash_exec = @import("../../tools/bash_exec.zig");
const pwsh_exec = @import("../../tools/pwsh_exec.zig");
const bash_safety = @import("../../tools/bash_safety.zig");
const os = @import("../../os.zig");
const git_bridge = @import("git.zig");

fn getIo(L: *c.lua_State) std.Io {
    return bridge.getIo(L);
}

const ShellBackend = enum {
    bash,
    pwsh,
};

fn shellBackendErrorMessage(err: anyerror, backend: ShellBackend) []const u8 {
    return switch (backend) {
        .bash => @errorName(err),
        .pwsh => switch (err) {
            error.FileNotFound => "pwsh executable not found in PATH; ensure PowerShell is installed",
            else => @errorName(err),
        },
    };
}

/// Best-effort plugin directory identifier for logging.
fn pluginDirBestEffort(L: *c.lua_State) []const u8 {
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "zay_plugin_dir");
    defer c.lua_pop(L, 1);
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len);
    return if (ptr) |p| p[0..len] else "";
}

/// Sanitize a path: resolve `..` and `.` segments, reject traversal.
pub fn sanitizePath(io: std.Io, path: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;

    var resolved_cwd = bridge.resolvePluginCwd(io) orelse return error.OutOfMemory;
    defer resolved_cwd.deinit();
    const raw_cwd = resolved_cwd.path;

    var abs_cwd_buf: ?[]u8 = null;
    defer if (abs_cwd_buf) |b| std.heap.page_allocator.free(b);
    const cwd = if (std.fs.path.isAbsolute(raw_cwd))
        raw_cwd
    else blk: {
        abs_cwd_buf = try std.fs.path.resolve(std.heap.page_allocator, &.{raw_cwd});
        break :blk abs_cwd_buf.?;
    };

    const resolved = try std.fs.path.resolve(std.heap.page_allocator, &.{ cwd, path });
    errdefer std.heap.page_allocator.free(resolved);
    if (!std.mem.startsWith(u8, resolved, cwd)) return error.PathTraversal;
    if (resolved.len > cwd.len and resolved[cwd.len] != std.fs.path.sep) return error.PathTraversal;

    if (!os.is_windows) {
        const resolved_z = std.heap.page_allocator.dupeZ(u8, resolved) catch return resolved;
        defer std.heap.page_allocator.free(resolved_z);
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real_ptr = std.c.realpath(resolved_z.ptr, &real_buf);
        if (real_ptr) |rp| {
            const real = std.mem.span(rp);
            const cwd_z = std.heap.page_allocator.dupeZ(u8, cwd) catch return resolved;
            defer std.heap.page_allocator.free(cwd_z);
            var real_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const rcwd_ptr = std.c.realpath(cwd_z.ptr, &real_cwd_buf);
            const real_cwd = if (rcwd_ptr) |rcp| std.mem.span(rcp) else cwd;
            if (!std.mem.startsWith(u8, real, real_cwd)) return error.PathTraversal;
            if (real.len > real_cwd.len and real[real_cwd.len] != std.fs.path.sep) return error.PathTraversal;
        }
    }

    return resolved;
}

/// ── zay.shell_quote(s, dialect?) ────────────────────────────────────
pub fn shellQuote(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    const s = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("string argument is required");
        return 2;
    };

    var pwsh_rules = false;
    if (state.getTop() >= 2 and !state.isNil(2)) {
        const dialect = bridge.pullValue(&state, []const u8, 2) orelse {
            state.pushNil();
            state.pushString("shell_quote: dialect must be \"posix\" or \"native\"");
            return 2;
        };
        if (std.mem.eql(u8, dialect, "posix")) {
            // POSIX quoting is default.
        } else if (std.mem.eql(u8, dialect, "native")) {
            pwsh_rules = os.is_windows;
        } else {
            state.pushNil();
            state.pushString("shell_quote: dialect must be \"posix\" or \"native\"");
            return 2;
        }
    }

    const gpa = std.heap.page_allocator;
    const quoted = git_bridge.quoteShellArg(gpa, s, pwsh_rules) catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer gpa.free(quoted);
    state.pushString(quoted);
    return 1;
}

fn runShellWithBackend(L: ?*c.lua_State, backend: ShellBackend) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const cmd = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("command argument is required");
        return 2;
    };

    if (cmd.len == 0) {
        state.pushNil();
        state.pushString("command argument must not be empty");
        return 2;
    }

    var cwd: ?[]const u8 = null;
    var timeout_seconds: u32 = bash_exec.timeout_seconds_default;
    var stdin_bytes: ?[]const u8 = null;

    if (state.getTop() >= 2 and state.isTable(2)) {
        if (bridge.getTableString(&state, 2, "cwd")) |v| cwd = v;
        if (bridge.getTableString(&state, 2, "stdin")) |v| stdin_bytes = v;
        if (bridge.getTableInteger(&state, 2, "timeout")) |v| timeout_seconds = @min(@max(@as(u32, @intCast(@max(v, 1))), 1), bash_exec.timeout_seconds_max);
    }

    const resolved_cwd = if (cwd) |path| blk: {
        break :blk sanitizePath(io, path) catch {
            state.pushNil();
            state.pushString("invalid cwd path");
            return 2;
        };
    } else blk: {
        var resolved = bridge.resolvePluginCwd(io) orelse {
            state.pushNil();
            state.pushString("could not resolve cwd");
            return 2;
        };
        defer resolved.deinit();
        break :blk std.heap.page_allocator.dupe(u8, resolved.path) catch {
            state.pushNil();
            state.pushString("out of memory");
            return 2;
        };
    };
    defer std.heap.page_allocator.free(resolved_cwd);

    const verdict = bash_safety.classify(std.heap.page_allocator, io, bridge.bash_classifier_url_slot, resolved_cwd, cmd);
    if (verdict == .unsafe) {
        const backend_name = if (backend == .pwsh) "pwsh" else "bash";
        std.log.warn("plugin.shell.blocked plugin_dir={s} backend={s} cmd=\"{s}\"", .{
            pluginDirBestEffort(L_ptr),
            backend_name,
            cmd[0..@min(cmd.len, 80)],
        });
        state.pushNil();
        state.pushString("UnsafeShellBlocked: command rejected by Zay's shell safety classifier; use the built-in bash tool for destructive commands");
        return 2;
    }

    if (backend == .pwsh) {
        var result = pwsh_exec.runWithOptions(std.heap.page_allocator, io, .{
            .cwd = resolved_cwd,
            .command = cmd,
            .stdin = stdin_bytes,
            .timeout = pwsh_exec.timeoutFromSeconds(timeout_seconds),
        }) catch |err| {
            state.pushNil();
            state.pushString(shellBackendErrorMessage(err, backend));
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
    } else {
        var result = bash_exec.runWithOptions(std.heap.page_allocator, io, .{
            .cwd = resolved_cwd,
            .command = cmd,
            .stdin = stdin_bytes,
            .timeout = bash_exec.timeoutFromSeconds(timeout_seconds),
        }) catch |err| {
            state.pushNil();
            state.pushString(shellBackendErrorMessage(err, backend));
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
}

pub fn runBash(L: ?*c.lua_State) callconv(.c) c_int {
    return runShellWithBackend(L, .bash);
}

pub fn runShell(L: ?*c.lua_State) callconv(.c) c_int {
    return runShellWithBackend(L, if (os.is_windows) .pwsh else .bash);
}

pub fn getEnv(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    const name = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("name argument is required");
        return 2;
    };

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

pub fn getCwd(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    var resolved = bridge.resolvePluginCwd(io) orelse {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer resolved.deinit();

    state.pushString(resolved.path);
    return 1;
}

pub fn getProjectRoot(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    var resolved = bridge.resolvePluginCwd(io) orelse {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer resolved.deinit();

    const root = git_bridge.findGitRoot(io, resolved.path) catch resolved.path;
    defer if (root.ptr != resolved.path.ptr) std.heap.page_allocator.free(root);

    state.pushString(root);
    return 1;
}
