//! Restricted Lua environment builder.
//!
//! Creates a sandboxed Lua state by replacing the global table (_G) with a
//! controlled environment containing only safe functions and libraries.
//! Resource limits (instruction count, memory) are enforced via a Lua hook.

const std = @import("std");
const c = @import("c");
const State = @import("state.zig").State;
const plugin_api = @import("plugin_api.zig");

/// Permissions granted to a plugin.
pub const Permissions = struct {
    /// Allow file read/write via io.*
    file_access: bool = false,
    /// Allow network access via socket.*
    network_access: bool = false,
    /// Allow requiring other plugins
    require_others: bool = true,
    /// Full access to all Lua standard libraries (embedded plugins only)
    full_access: bool = false,
    /// Allow rawget/rawset (can be used for sandbox escape)
    allow_rawget_rawset: bool = false,
    /// Allow os.execute
    allow_os_execute: bool = false,
    /// Allow os.exit
    allow_os_exit: bool = false,
    /// Allow os.remove/os.rename
    allow_os_remove: bool = false,
    /// Maximum Lua instructions before abort (0 = unlimited)
    instruction_limit: u32 = 100_000,
    /// Maximum memory in MB (0 = unlimited)
    memory_limit_mb: u32 = 16,
    /// Timeout in ms (approximate, based on instruction count)
    timeout_ms: u32 = 5000,
};

/// Data stored in lua_getextraspace for the instruction hook.
const HookData = struct {
    instruction_limit: u32,
    instruction_count: u32,
    memory_limit: usize,
};

/// Instruction count hook function.
/// Fires every 1000 instructions and checks resource limits.
fn instructionHook(L: ?*c.lua_State, ar: [*c]c.lua_Debug) callconv(.c) void {
    _ = ar;
    const L_ptr = L orelse return;
    const slot = @as(*?*HookData, @ptrCast(@alignCast(c.lua_getextraspace(L_ptr))));
    const data = slot.* orelse return;
    data.instruction_count += 1;
    if (data.instruction_count >= data.instruction_limit) {
        _ = c.luaL_error(L_ptr, "instruction limit exceeded");
    }
    // Check memory every 1000 instructions
    const mem_kb = c.lua_gc(L_ptr, c.LUA_GCCOUNT, @as(c_int, 0));
    if (@as(usize, @intCast(mem_kb)) * 1024 >= data.memory_limit) {
        _ = c.luaL_error(L_ptr, "memory limit exceeded");
    }
}

/// Create a new sandboxed Lua state with restricted permissions.
/// `io` is optional — when provided, plugin API functions (read_file, etc.)
/// are registered in the `nova` table. When undefined, only the sandboxed
/// environment is created (for test runners that don't have a real Io).
/// Caller owns the returned State and must call `deinit`.
pub fn createSandboxedState(permissions: Permissions) State {
    return createSandboxedStateWithIo(permissions, null);
}

/// Create a sandboxed state with a specific Io instance (for plugin API).
pub fn createSandboxedStateWithIo(permissions: Permissions, io: ?std.Io) State {
    const L = c.luaL_newstate() orelse @panic("luaL_newstate returned null");

    // Initialize extraspace to null (no hook data yet)
    @as(*?*HookData, @ptrCast(@alignCast(c.lua_getextraspace(L)))).* = null;

    // Open all standard libraries
    c.luaL_openlibs(L);

    // Register plugin API functions when Io is provided
    if (io != null) {
        const io_storage = @as(*std.Io, @ptrCast(@alignCast(c.lua_newuserdata(L, @sizeOf(std.Io)))));
        io_storage.* = io.?;
        c.lua_setfield(L, c.LUA_REGISTRYINDEX, "nova_io");
        registerPluginApi(L);
    }

    if (!permissions.full_access) {
        createRestrictedEnvironment(L, permissions);
        setupInstructionHook(L, permissions);
    }

    return State{ .handle = L };
}

/// Register Nova plugin API functions into the `nova` global table.
/// These are safe C functions that plugins can call instead of blocked
/// libraries like `io.*`.
fn registerPluginApi(L: *c.lua_State) void {
    // Create the nova table
    c.lua_newtable(L);

    // Register each function
    const funcs = [_]struct { name: [:0]const u8, func: c.lua_CFunction }{
        .{ .name = "read_file", .func = plugin_api.readFile },
        .{ .name = "write_file", .func = plugin_api.writeFile },
        .{ .name = "edit_file", .func = plugin_api.editFile },
        .{ .name = "search_files", .func = plugin_api.searchFiles },
        .{ .name = "list_dir", .func = plugin_api.listDir },
        .{ .name = "file_info", .func = plugin_api.fileInfo },
        .{ .name = "run_bash", .func = plugin_api.runBash },
        .{ .name = "get_env", .func = plugin_api.getEnv },
        .{ .name = "get_cwd", .func = plugin_api.getCwd },
        .{ .name = "get_project_root", .func = plugin_api.getProjectRoot },
        .{ .name = "register_tool", .func = plugin_api.registerTool },
        .{ .name = "on", .func = plugin_api.onEvent },
        .{ .name = "git_status", .func = plugin_api.gitStatus },
        .{ .name = "git_diff", .func = plugin_api.gitDiff },
        .{ .name = "git_log", .func = plugin_api.gitLog },
        .{ .name = "git_branch", .func = plugin_api.gitBranch },
        .{ .name = "git_commit", .func = plugin_api.gitCommit },
        .{ .name = "think", .func = plugin_api.think },
    };

    for (funcs) |f| {
        c.lua_pushcfunction(L, f.func);
        c.lua_setfield(L, -2, f.name.ptr);
    }

    // Set nova as a global
    c.lua_setglobal(L, "nova");
}

/// Create a restricted global environment by replacing _G with a new table
/// containing only safe functions and libraries.
fn createRestrictedEnvironment(L: *c.lua_State, permissions: Permissions) void {
    // Create a new environment table
    c.lua_newtable(L);
    const env_index = c.lua_gettop(L);

    // Copy safe basic functions from the real _G
    copyGlobal(L, env_index, "assert");
    copyGlobal(L, env_index, "error");
    copyGlobal(L, env_index, "getmetatable");
    copyGlobal(L, env_index, "ipairs");
    copyGlobal(L, env_index, "next");
    copyGlobal(L, env_index, "pairs");
    copyGlobal(L, env_index, "pcall");
    copyGlobal(L, env_index, "rawequal");
    copyGlobal(L, env_index, "rawlen");
    copyGlobal(L, env_index, "select");
    copyGlobal(L, env_index, "setmetatable");
    copyGlobal(L, env_index, "tonumber");
    copyGlobal(L, env_index, "tostring");
    copyGlobal(L, env_index, "type");
    copyGlobal(L, env_index, "xpcall");
    copyGlobal(L, env_index, "_VERSION");

    // rawget/rawset — dangerous for sandbox escape, controlled by permission
    if (permissions.allow_rawget_rawset) {
        copyGlobal(L, env_index, "rawget");
        copyGlobal(L, env_index, "rawset");
    }

    // Copy safe library tables
    copyGlobal(L, env_index, "string");
    copyGlobal(L, env_index, "table");
    copyGlobal(L, env_index, "math");
    copyGlobal(L, env_index, "coroutine");
    copyGlobal(L, env_index, "utf8");

    // Copy the Nova plugin API table so plugins can call nova.register_tool, etc.
    copyGlobal(L, env_index, "nova");

    // Safe os subset
    c.lua_newtable(L);
    const os_index = c.lua_gettop(L);
    _ = c.lua_getglobal(L, "os");
    if (!c.lua_isnil(L, -1)) {
        copyOsFunction(L, os_index, "clock");
        copyOsFunction(L, os_index, "date");
        copyOsFunction(L, os_index, "time");
        copyOsFunction(L, os_index, "difftime");
        if (permissions.allow_os_execute) {
            copyOsFunction(L, os_index, "execute");
        }
        if (permissions.allow_os_exit) {
            copyOsFunction(L, os_index, "exit");
        }
        if (permissions.allow_os_remove) {
            copyOsFunction(L, os_index, "remove");
            copyOsFunction(L, os_index, "rename");
        }
    }
    c.lua_pop(L, 1); // pop real os
    c.lua_setfield(L, env_index, "os");

    // Set _G in the environment to point to itself
    c.lua_pushvalue(L, env_index);
    c.lua_setfield(L, env_index, "_G");

    // Replace _G in the registry with the restricted environment
    c.lua_pushvalue(L, env_index);
    c.lua_rawseti(L, c.LUA_REGISTRYINDEX, c.LUA_RIDX_GLOBALS);

    // Pop the environment table
    c.lua_pop(L, 1);
}

/// Copy a global function/table from the real _G into the environment.
fn copyGlobal(L: *c.lua_State, env_index: c_int, name: [:0]const u8) void {
    _ = c.lua_getglobal(L, name.ptr);
    if (!c.lua_isnil(L, -1)) {
        _ = c.lua_setfield(L, env_index, name.ptr);
    } else {
        c.lua_pop(L, 1);
    }
}

/// Copy a single function from the os table into the sandbox os table.
fn copyOsFunction(L: *c.lua_State, os_index: c_int, name: [:0]const u8) void {
    _ = c.lua_getfield(L, -1, name.ptr);
    _ = c.lua_setfield(L, os_index, name.ptr);
}

/// Set up the instruction count hook for resource limits.
fn setupInstructionHook(L: *c.lua_State, permissions: Permissions) void {
    if (permissions.instruction_limit == 0 and permissions.memory_limit_mb == 0) return;

    const allocator = std.heap.page_allocator;
    const data = allocator.create(HookData) catch @panic("OOM");
    data.* = HookData{
        .instruction_limit = if (permissions.instruction_limit > 0) permissions.instruction_limit else std.math.maxInt(u32),
        .instruction_count = 0,
        .memory_limit = if (permissions.memory_limit_mb > 0) @as(usize, @intCast(permissions.memory_limit_mb)) * 1024 * 1024 else std.math.maxInt(usize),
    };
    @as(*?*HookData, @ptrCast(@alignCast(c.lua_getextraspace(L)))).* = data;
    c.lua_sethook(L, instructionHook, c.LUA_MASKCOUNT, 1000);
}

/// Free the hook data allocated in setupInstructionHook.
/// Must be called before lua_close.
pub fn freeHookData(L: *c.lua_State) void {
    const slot = @as(*?*HookData, @ptrCast(@alignCast(c.lua_getextraspace(L))));
    if (slot.*) |data| {
        std.heap.page_allocator.destroy(data);
        slot.* = null;
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "sandbox: basic creation" {
    var L = createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return 2 + 2"));
    try std.testing.expectEqual(@as(i64, 4), L.toInteger(-1));
    L.pop(1);
}

test "sandbox: blocks io" {
    var L = createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return io == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: blocks debug" {
    var L = createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return debug == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: blocks package" {
    var L = createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return package == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: globals like type() still work" {
    var L = createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return type('hello')"));
    try std.testing.expectEqualStrings("string", L.toString(-1).?);
    L.pop(1);
}

test "sandbox: full access exposes all libraries" {
    var L = createSandboxedState(.{ .full_access = true });
    defer L.deinit();

    try std.testing.expect(L.doString("return type(io) == 'table'"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: blocks rawget by default" {
    var L = createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return rawget == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: allows rawget when permitted" {
    var L = createSandboxedState(.{ .allow_rawget_rawset = true });
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return type(rawget) == 'function'"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: blocks os.execute by default" {
    var L = createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return os.execute == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: allows os.execute when permitted" {
    var L = createSandboxedState(.{ .allow_os_execute = true });
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return type(os.execute) == 'function'"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: blocks dofile and loadfile" {
    var L = createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return dofile == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);

    try std.testing.expect(L.doString("return loadfile == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: _G points to restricted environment" {
    var L = createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    // _G should not have io
    try std.testing.expect(L.doString("return _G.io == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);

    // _G should have type()
    try std.testing.expect(L.doString("return type(_G.type) == 'function'"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: instruction limit triggers error" {
    var L = createSandboxedState(.{ .instruction_limit = 100 });
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    // Infinite loop should hit the instruction limit
    try std.testing.expect(!L.doString("while true do end"));
    const err = L.getErrorMessage();
    try std.testing.expect(err != null);
    try std.testing.expect(std.mem.indexOf(u8, err.?, "instruction limit") != null);
    L.pop(1);
}

test "sandbox: memory limit triggers error" {
    var L = createSandboxedState(.{ .memory_limit_mb = 1 });
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    // Allocate a large table to exceed 1MB
    try std.testing.expect(!L.doString(
        \\local t = {}
        \\for i = 1, 200000 do
        \\  t[i] = string.rep("x", 100)
        \\end
    ));
    const err = L.getErrorMessage();
    try std.testing.expect(err != null);
    try std.testing.expect(std.mem.indexOf(u8, err.?, "memory limit") != null);
    L.pop(1);
}
