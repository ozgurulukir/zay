//! Dispatch limits shared by a Lua VM and its coroutines. Termination is
//! sticky until the host starts the next dispatch; protected Lua calls cannot
//! turn a resource/cancellation failure back into successful execution.
const std = @import("std");
const c = @import("c");
const platform = @import("platform");
const bridge = @import("bridge.zig");

pub const StopReason = enum {
    none,
    canceled,
    instruction_limit,
    timeout,
    memory_limit,

    fn message(reason: StopReason) [:0]const u8 {
        return switch (reason) {
            .none => unreachable,
            .canceled => "plugin execution canceled",
            .instruction_limit => "instruction limit exceeded",
            .timeout => "timeout exceeded",
            .memory_limit => "memory limit exceeded",
        };
    }
};

pub const Budget = struct {
    instruction_limit: u32,
    instruction_count: u32,
    memory_limit: usize,
    timeout_ms: u32,
    // Eight-byte alignment matches Lua userdata on every supported target.
    deadline_ns: i64 = 0,
    io: ?std.Io = null,
    stop_reason: StopReason = .none,
};

pub fn budget(L: *c.lua_State) ?*Budget {
    return @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L)))).*;
}

pub fn check(L: *c.lua_State) void {
    const data = budget(L) orelse return;
    if (data.stop_reason != .none) return;
    if (bridge.cancel_requested_slot) |flag| {
        if (flag.load(.acquire)) {
            data.stop_reason = .canceled;
            return;
        }
    }
    if (data.io) |io| io.checkCancel() catch {
        // Keep cancellation visible at later host/bridge cancellation points.
        io.recancel();
        data.stop_reason = .canceled;
        return;
    };
    if (data.deadline_ns != 0 and platform.monotonicNowNs() >= data.deadline_ns)
        data.stop_reason = .timeout;
}

pub fn noteError(L: *c.lua_State, err: anyerror) void {
    if (err != error.Canceled) return;
    const data = budget(L) orelse return;
    data.stop_reason = .canceled;
    if (data.io) |io| io.recancel();
}

pub fn stopped(L: *c.lua_State) bool {
    const data = budget(L) orelse return false;
    return data.stop_reason != .none;
}

pub fn raiseIfStopped(L: *c.lua_State) void {
    check(L);
    const data = budget(L) orelse return;
    if (data.stop_reason != .none) _ = c.luaL_error(L, data.stop_reason.message());
}

/// Restrict an event's execution to the remaining aggregate delivery budget.
pub fn capDeadline(L: *c.lua_State, remaining_ms: u32) void {
    const data = budget(L) orelse return;
    const deadline = platform.monotonicNowNs() + @as(i128, remaining_ms) * std.time.ns_per_ms;
    if (data.deadline_ns == 0 or deadline < data.deadline_ns) data.deadline_ns = @intCast(deadline);
}

/// Bridge subprocesses share the Lua deadline instead of restarting it.
pub fn ioTimeout(L: *c.lua_State, seconds: u32) std.Io.Timeout {
    var remaining: i128 = @as(i128, seconds) * std.time.ns_per_s;
    if (budget(L)) |data| {
        if (data.deadline_ns != 0) remaining = @min(remaining, @max(0, data.deadline_ns - platform.monotonicNowNs()));
    }
    return .{ .duration = .{ .raw = .fromNanoseconds(@intCast(remaining)), .clock = .awake } };
}

fn finishGuard(L: ?*c.lua_State, _: c_int, _: c.lua_KContext) callconv(.c) c_int {
    const state = L.?;
    raiseIfStopped(state);
    return c.lua_gettop(state);
}

/// Outside the delegated function's Zig frames, so raising cannot skip its
/// defers. lua_callk preserves yieldable pcall/xpcall/coroutine semantics.
fn guardedCall(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    raiseIfStopped(state);
    const argc = c.lua_gettop(state);
    c.lua_pushvalue(state, c.lua_upvalueindex(1));
    c.lua_insert(state, 1);
    c.lua_callk(state, argc, c.LUA_MULTRET, 0, finishGuard);
    return finishGuard(state, c.LUA_OK, 0);
}

pub fn pushGuardedFunction(L: *c.lua_State, func: c.lua_CFunction) void {
    c.lua_pushcfunction(L, func);
    c.lua_pushcclosure(L, guardedCall, 1);
}

fn guardField(L: *c.lua_State, table: c_int, name: [:0]const u8) void {
    const index = c.lua_absindex(L, table);
    _ = c.lua_getfield(L, index, name);
    c.lua_pushcclosure(L, guardedCall, 1);
    c.lua_setfield(L, index, name);
}

fn guardedWrap(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    raiseIfStopped(state);
    c.lua_pushvalue(state, c.lua_upvalueindex(1));
    c.lua_insert(state, 1);
    c.lua_callk(state, c.lua_gettop(state) - 1, 1, 0, null);
    c.lua_pushcclosure(state, guardedCall, 1);
    return 1;
}

pub fn installProtectedCallGuards(L: *c.lua_State) void {
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, c.LUA_RIDX_GLOBALS);
    guardField(L, -1, "pcall");
    guardField(L, -1, "xpcall");
    _ = c.lua_getglobal(L, "coroutine");
    guardField(L, -1, "resume");
    _ = c.lua_getfield(L, -1, "wrap");
    c.lua_pushcclosure(L, guardedWrap, 1);
    c.lua_setfield(L, -2, "wrap");
}
