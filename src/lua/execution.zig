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

test "execution: StopReason message returns expected strings" {
    const testing = std.testing;
    try testing.expectEqualStrings("plugin execution canceled", StopReason.canceled.message());
    try testing.expectEqualStrings("instruction limit exceeded", StopReason.instruction_limit.message());
    try testing.expectEqualStrings("timeout exceeded", StopReason.timeout.message());
    try testing.expectEqualStrings("memory limit exceeded", StopReason.memory_limit.message());
}

test "execution: budget retrieval and stopped check" {
    const testing = std.testing;
    const State = @import("state.zig").State;
    var L = try State.init();
    defer L.deinit();

    try testing.expect(budget(L.handle) == null);
    try testing.expect(!stopped(L.handle));

    var b: Budget = .{
        .instruction_limit = 1000,
        .instruction_count = 0,
        .memory_limit = 1024 * 1024,
        .timeout_ms = 1000,
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    try testing.expectEqual(&b, budget(L.handle));
    try testing.expect(!stopped(L.handle));

    b.stop_reason = .canceled;
    try testing.expect(stopped(L.handle));

    b.stop_reason = .instruction_limit;
    try testing.expect(stopped(L.handle));

    b.stop_reason = .timeout;
    try testing.expect(stopped(L.handle));

    b.stop_reason = .memory_limit;
    try testing.expect(stopped(L.handle));
}

test "execution: check handles timeout and atomic cancellation" {
    const testing = std.testing;
    const State = @import("state.zig").State;
    var L = try State.init();
    defer L.deinit();

    var b: Budget = .{
        .instruction_limit = 0,
        .instruction_count = 0,
        .memory_limit = 0,
        .timeout_ms = 100,
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    // Set deadline in past
    b.deadline_ns = platform.monotonicNowNs() - 1000;
    check(L.handle);
    try testing.expectEqual(StopReason.timeout, b.stop_reason);

    // Reset stop reason & test atomic cancellation flag slot
    b.stop_reason = .none;
    b.deadline_ns = 0;
    var flag = std.atomic.Value(bool).init(true);
    bridge.cancel_requested_slot = &flag;
    defer bridge.cancel_requested_slot = null;

    check(L.handle);
    try testing.expectEqual(StopReason.canceled, b.stop_reason);
}

test "execution: noteError sets canceled stop_reason on error.Canceled" {
    const testing = std.testing;
    const State = @import("state.zig").State;
    var L = try State.init();
    defer L.deinit();

    var b: Budget = .{
        .instruction_limit = 0,
        .instruction_count = 0,
        .memory_limit = 0,
        .timeout_ms = 0,
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    noteError(L.handle, error.OutOfMemory);
    try testing.expectEqual(StopReason.none, b.stop_reason);

    noteError(L.handle, error.Canceled);
    try testing.expectEqual(StopReason.canceled, b.stop_reason);
}

test "execution: capDeadline and ioTimeout calculation" {
    const testing = std.testing;
    const State = @import("state.zig").State;
    var L = try State.init();
    defer L.deinit();

    var b: Budget = .{
        .instruction_limit = 0,
        .instruction_count = 0,
        .memory_limit = 0,
        .timeout_ms = 0,
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    // ioTimeout with no deadline
    const t1 = ioTimeout(L.handle, 10);
    try testing.expectEqual(@as(i128, 10) * std.time.ns_per_s, t1.duration.raw.toNanoseconds());

    // capDeadline sets initial deadline
    capDeadline(L.handle, 5000);
    try testing.expect(b.deadline_ns > 0);
    const initial_deadline = b.deadline_ns;

    // capDeadline with larger remaining_ms does not extend deadline
    capDeadline(L.handle, 10000);
    try testing.expectEqual(initial_deadline, b.deadline_ns);

    // capDeadline with smaller remaining_ms tightens deadline
    capDeadline(L.handle, 100);
    try testing.expect(b.deadline_ns < initial_deadline);

    // ioTimeout is now bounded by the tighter deadline
    const t2 = ioTimeout(L.handle, 10);
    try testing.expect(t2.duration.raw.toNanoseconds() < @as(i128, 10) * std.time.ns_per_s);
}

test "execution: pushGuardedFunction executes when active and raises when stopped" {
    const testing = std.testing;
    const State = @import("state.zig").State;
    var L = try State.init();
    defer L.deinit();

    var b: Budget = .{
        .instruction_limit = 0,
        .instruction_count = 0,
        .memory_limit = 0,
        .timeout_ms = 0,
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    const Dummy = struct {
        fn add(state: ?*c.lua_State) callconv(.c) c_int {
            const raw = state.?;
            const a = c.lua_tointeger(raw, 1);
            const b_val = c.lua_tointeger(raw, 2);
            c.lua_pushinteger(raw, a + b_val);
            return 1;
        }
    };

    pushGuardedFunction(L.handle, Dummy.add);
    c.lua_setglobal(L.handle, "guarded_add");

    // Call normally
    try testing.expect(L.doString("return guarded_add(10, 20)"));
    try testing.expectEqual(@as(i64, 30), L.toInteger(-1));
    L.pop(1);

    // Stop VM and call again
    b.stop_reason = .canceled;
    try testing.expect(!L.doString("return guarded_add(10, 20)"));
    const msg = L.getErrorMessage();
    try testing.expect(msg != null);
    try testing.expect(std.mem.indexOf(u8, msg.?, "plugin execution canceled") != null);
    L.pop(1);
}

test "execution: installProtectedCallGuards makes cancellation sticky across pcall, xpcall, coroutines" {
    const testing = std.testing;
    const State = @import("state.zig").State;
    var L = try State.init();
    defer L.deinit();

    var b: Budget = .{
        .instruction_limit = 0,
        .instruction_count = 0,
        .memory_limit = 0,
        .timeout_ms = 0,
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    installProtectedCallGuards(L.handle);

    // Run normal pcall before stopping
    try testing.expect(L.doString("local ok, res = pcall(function() return 42 end); return ok and res == 42"));
    try testing.expect(L.toBoolean(-1));
    L.pop(1);

    // Set stop_reason to timeout
    b.stop_reason = .timeout;

    // Protected pcall cannot catch or swallow the timeout stop reason
    try testing.expect(!L.doString("local ok, err = pcall(function() return 1 end)"));
    const pcall_err = L.getErrorMessage();
    try testing.expect(pcall_err != null);
    try testing.expect(std.mem.indexOf(u8, pcall_err.?, "timeout exceeded") != null);
    L.pop(1);

    // Protected xpcall cannot catch or swallow the stop reason
    try testing.expect(!L.doString("local ok, err = xpcall(function() return 1 end, function(e) return e end)"));
    const xpcall_err = L.getErrorMessage();
    try testing.expect(xpcall_err != null);
    try testing.expect(std.mem.indexOf(u8, xpcall_err.?, "timeout exceeded") != null);
    L.pop(1);

    // Protected coroutine.resume re-raises stop reason
    try testing.expect(!L.doString("local co = coroutine.create(function() end); coroutine.resume(co)"));
    const co_err = L.getErrorMessage();
    try testing.expect(co_err != null);
    try testing.expect(std.mem.indexOf(u8, co_err.?, "timeout exceeded") != null);
    L.pop(1);
}

// ── Tests ────────────────────────────────────────────────────────────

const sandbox = @import("sandbox.zig");

test "noteError_ignoresNonCanceledErrors_whenErrorIsNotCanceled" {
    var L = try sandbox.createSandboxedState(.{});
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    const data = budget(L.handle).?;
    try std.testing.expectEqual(StopReason.none, data.stop_reason);

    noteError(L.handle, error.OutOfMemory);

    try std.testing.expectEqual(StopReason.none, data.stop_reason);
    try std.testing.expect(!stopped(L.handle));
}

test "noteError_handlesNullBudget_whenExtraspaceIsNull" {
    const L = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(L);

    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L)))).* = null;

    try std.testing.expect(budget(L) == null);

    noteError(L, error.Canceled);

    try std.testing.expect(!stopped(L));
}

test "noteError_setsStopReasonToCanceled_whenErrorIsCanceled" {
    var L = try sandbox.createSandboxedState(.{});
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    const data = budget(L.handle).?;
    try std.testing.expectEqual(StopReason.none, data.stop_reason);
    try std.testing.expect(!stopped(L.handle));

    noteError(L.handle, error.Canceled);

    try std.testing.expectEqual(StopReason.canceled, data.stop_reason);
    try std.testing.expect(stopped(L.handle));
}

test "noteError_recancelsIo_whenIoIsPresentAndErrorIsCanceled" {
    const io = std.testing.io;
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    const data = budget(L.handle).?;
    try std.testing.expect(data.io != null);
    try std.testing.expectEqual(StopReason.none, data.stop_reason);

    noteError(L.handle, error.Canceled);

    try std.testing.expectEqual(StopReason.canceled, data.stop_reason);
    try std.testing.expect(stopped(L.handle));
}

// ── Tests ────────────────────────────────────────────────────────────

test "budget_returnsNull_whenExtraSpaceIsEmpty" {
    const L = c.luaL_newstate() orelse return error.LuaInitFailed;
    defer c.lua_close(L);

    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L)))).* = null;
    try std.testing.expectEqual(@as(?*Budget, null), budget(L));
}

test "budget_returnsBudgetPointer_whenExtraSpaceIsSet" {
    const L = c.luaL_newstate() orelse return error.LuaInitFailed;
    defer c.lua_close(L);

    var test_budget: Budget = .{
        .instruction_limit = 1000,
        .instruction_count = 0,
        .memory_limit = 1024 * 1024,
        .timeout_ms = 5000,
    };

    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L)))).* = &test_budget;

    const b = budget(L);
    try std.testing.expect(b != null);
    try std.testing.expectEqual(&test_budget, b.?);
    try std.testing.expectEqual(@as(u32, 1000), b.?.instruction_limit);
    try std.testing.expectEqual(StopReason.none, b.?.stop_reason);

    b.?.stop_reason = .canceled;
    try std.testing.expectEqual(StopReason.canceled, test_budget.stop_reason);
}

const State = @import("state.zig").State;
const testing = std.testing;

test "returnsUncappedTimeout_whenNoBudgetAttached" {
    // Arrange
    var L_state = try State.init();
    defer L_state.deinit();
    const L = L_state.handle;

    // Act
    const timeout = ioTimeout(L, 5);

    // Assert
    try testing.expectEqual(@as(i128, 5) * std.time.ns_per_s, timeout.duration.raw.nanoseconds);
}

test "returnsUncappedTimeout_whenBudgetHasZeroDeadline" {
    // Arrange
    var L_state = try State.init();
    defer L_state.deinit();
    const L = L_state.handle;

    var b: Budget = .{
        .instruction_limit = 0,
        .instruction_count = 0,
        .memory_limit = 0,
        .timeout_ms = 0,
        .deadline_ns = 0,
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L)))).* = &b;

    // Act
    const timeout = ioTimeout(L, 10);

    // Assert
    try testing.expectEqual(@as(i128, 10) * std.time.ns_per_s, timeout.duration.raw.nanoseconds);
}

test "returnsRequestedTimeout_whenDeadlineIsFurtherThanRequested" {
    // Arrange
    var L_state = try State.init();
    defer L_state.deinit();
    const L = L_state.handle;

    const now = platform.monotonicNowNs();
    var b: Budget = .{
        .instruction_limit = 0,
        .instruction_count = 0,
        .memory_limit = 0,
        .timeout_ms = 0,
        .deadline_ns = @intCast(now + 10 * std.time.ns_per_s),
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L)))).* = &b;

    // Act
    const timeout = ioTimeout(L, 2);

    // Assert
    try testing.expectEqual(@as(i128, 2) * std.time.ns_per_s, timeout.duration.raw.nanoseconds);
}

test "returnsCappedTimeout_whenDeadlineIsSoonerThanRequested" {
    // Arrange
    var L_state = try State.init();
    defer L_state.deinit();
    const L = L_state.handle;

    const now = platform.monotonicNowNs();
    const deadline_delta: i128 = 3 * std.time.ns_per_s;
    var b: Budget = .{
        .instruction_limit = 0,
        .instruction_count = 0,
        .memory_limit = 0,
        .timeout_ms = 0,
        .deadline_ns = @intCast(now + deadline_delta),
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L)))).* = &b;

    // Act
    const timeout = ioTimeout(L, 10);

    // Assert
    const remaining_ns = timeout.duration.raw.nanoseconds;
    try testing.expect(remaining_ns <= deadline_delta);
    try testing.expect(remaining_ns > 0);
}

test "returnsZeroTimeout_whenDeadlineIsExpired" {
    // Arrange
    var L_state = try State.init();
    defer L_state.deinit();
    const L = L_state.handle;

    const now = platform.monotonicNowNs();
    var b: Budget = .{
        .instruction_limit = 0,
        .instruction_count = 0,
        .memory_limit = 0,
        .timeout_ms = 0,
        .deadline_ns = @intCast(now - 1 * std.time.ns_per_s),
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L)))).* = &b;

    // Act
    const timeout = ioTimeout(L, 5);

    // Assert
    try testing.expectEqual(@as(i128, 0), timeout.duration.raw.nanoseconds);
}

// ── Tests ────────────────────────────────────────────────────────────

const State = @import("state.zig").State;

test "returnsSafely_whenBudgetIsNull" {
    var L = try State.init();
    defer L.deinit();

    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = null;

    check(L.handle);
    try std.testing.expectEqual(@as(?*Budget, null), budget(L.handle));
}

test "preservesStopReason_whenAlreadyStopped" {
    var L = try State.init();
    defer L.deinit();

    var b = Budget{
        .instruction_limit = 100,
        .instruction_count = 0,
        .memory_limit = 1024 * 1024,
        .timeout_ms = 1000,
        .stop_reason = .memory_limit,
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    check(L.handle);
    try std.testing.expectEqual(StopReason.memory_limit, b.stop_reason);
}

test "setsCanceled_whenCancelRequestedSlotIsTrue" {
    var L = try State.init();
    defer L.deinit();

    var b = Budget{
        .instruction_limit = 100,
        .instruction_count = 0,
        .memory_limit = 1024 * 1024,
        .timeout_ms = 1000,
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    var cancel_flag = std.atomic.Value(bool).init(true);
    bridge.cancel_requested_slot = &cancel_flag;
    defer bridge.cancel_requested_slot = null;

    check(L.handle);
    try std.testing.expectEqual(StopReason.canceled, b.stop_reason);
}

test "preservesNone_whenCancelRequestedSlotIsFalse" {
    var L = try State.init();
    defer L.deinit();

    var b = Budget{
        .instruction_limit = 100,
        .instruction_count = 0,
        .memory_limit = 1024 * 1024,
        .timeout_ms = 1000,
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    var cancel_flag = std.atomic.Value(bool).init(false);
    bridge.cancel_requested_slot = &cancel_flag;
    defer bridge.cancel_requested_slot = null;

    check(L.handle);
    try std.testing.expectEqual(StopReason.none, b.stop_reason);
}

test "setsCanceled_whenIoCheckCancelFails" {
    var L = try State.init();
    defer L.deinit();

    const mockIo = struct {
        fn checkCancel(_: ?*anyopaque) error{Canceled}!void {
            return error.Canceled;
        }
        fn recancel(_: ?*anyopaque) void {}
    };

    var mock_vtable = std.testing.io.vtable.*;
    mock_vtable.checkCancel = mockIo.checkCancel;
    mock_vtable.recancel = mockIo.recancel;
    const mock_io = std.Io{ .userdata = null, .vtable = &mock_vtable };

    var b = Budget{
        .instruction_limit = 100,
        .instruction_count = 0,
        .memory_limit = 1024 * 1024,
        .timeout_ms = 1000,
        .io = mock_io,
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    check(L.handle);
    try std.testing.expectEqual(StopReason.canceled, b.stop_reason);
}

test "setsTimeout_whenMonotonicDeadlineHasPassed" {
    var L = try State.init();
    defer L.deinit();

    var b = Budget{
        .instruction_limit = 100,
        .instruction_count = 0,
        .memory_limit = 1024 * 1024,
        .timeout_ms = 1000,
        .deadline_ns = @intCast(platform.monotonicNowNs() - 1),
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    check(L.handle);
    try std.testing.expectEqual(StopReason.timeout, b.stop_reason);
}

test "preservesNone_whenMonotonicDeadlineIsInFuture" {
    var L = try State.init();
    defer L.deinit();

    var b = Budget{
        .instruction_limit = 100,
        .instruction_count = 0,
        .memory_limit = 1024 * 1024,
        .timeout_ms = 1000,
        .deadline_ns = @intCast(platform.monotonicNowNs() + std.time.ns_per_s * 10),
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    check(L.handle);
    try std.testing.expectEqual(StopReason.none, b.stop_reason);
}

test "noteError_setsCanceled_onlyForCanceledError" {
    var L = try State.init();
    defer L.deinit();

    var b = Budget{
        .instruction_limit = 100,
        .instruction_count = 0,
        .memory_limit = 1024 * 1024,
        .timeout_ms = 1000,
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    // Arrange & Act: non-canceled error
    noteError(L.handle, error.OutOfMemory);
    // Assert
    try std.testing.expectEqual(StopReason.none, b.stop_reason);

    // Arrange & Act: canceled error
    noteError(L.handle, error.Canceled);
    // Assert
    try std.testing.expectEqual(StopReason.canceled, b.stop_reason);
}

test "stopped_returnsTrue_whenStopReasonIsNotNone" {
    var L = try State.init();
    defer L.deinit();

    var b = Budget{
        .instruction_limit = 100,
        .instruction_count = 0,
        .memory_limit = 1024 * 1024,
        .timeout_ms = 1000,
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    try std.testing.expect(!stopped(L.handle));

    b.stop_reason = .canceled;
    try std.testing.expect(stopped(L.handle));
}

test "capDeadline_restrictsDeadline_withoutExtendingIt" {
    var L = try State.init();
    defer L.deinit();

    var b = Budget{
        .instruction_limit = 100,
        .instruction_count = 0,
        .memory_limit = 1024 * 1024,
        .timeout_ms = 1000,
        .deadline_ns = 0,
    };
    @as(*?*Budget, @ptrCast(@alignCast(c.lua_getextraspace(L.handle)))).* = &b;

    // Arrange & Act: initial cap
    capDeadline(L.handle, 5000);
    try std.testing.expect(b.deadline_ns > 0);

    const old_deadline = b.deadline_ns;
    // Act: cap with larger duration should not extend existing deadline
    capDeadline(L.handle, 10000);
    // Assert
    try std.testing.expectEqual(old_deadline, b.deadline_ns);
}
