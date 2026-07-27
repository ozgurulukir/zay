//! Zig ↔ Lua value conversion helpers.
//!
//! Provides typed push/pull functions for common Zig types
//! so callers don't need to touch the raw stack API.

const std = @import("std");
const c = @import("c");
const State = @import("state.zig").State;

/// Returns true if T is an array of u8 (e.g. [5:0]u8).
fn isArrayOfU8(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .array) return false;
    return info.array.child == u8;
}

/// Push a Zig value onto the Lua stack.
/// Supported types: []const u8, [:0]const u8, i64, f64, bool, void (nil).
pub fn pushValue(L: *State, value: anytype) void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .int => L.pushInteger(@as(i64, @intCast(value))),
        .float => L.pushNumber(@as(f64, value)),
        .bool => L.pushBoolean(value),
        .optional => {
            if (value) |v| pushValue(L, v) else L.pushNil();
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    if (ptr_info.child == u8) {
                        L.pushString(value);
                    } else {
                        @compileError("unsupported slice type: " ++ @typeName(T));
                    }
                },
                .one => {
                    if (ptr_info.child == u8 and ptr_info.sentinel != null) {
                        L.pushCString(@as([*:0]const u8, @ptrCast(value)));
                    } else if (comptime isArrayOfU8(ptr_info.child)) {
                        // String literal: *const [N:0]u8
                        const arr_info = @typeInfo(ptr_info.child).array;
                        const arr = @as(*const [arr_info.len]u8, @ptrCast(value));
                        L.pushString(arr[0..]);
                    } else {
                        @compileError("unsupported pointer type: " ++ @typeName(T));
                    }
                },
                else => @compileError("unsupported pointer type: " ++ @typeName(T)),
            }
        },
        .void => L.pushNil(),
        else => @compileError("unsupported type for Lua push: " ++ @typeName(T)),
    }
}

/// Pull a typed value from the Lua stack at `index`.
/// Returns `null` if the type doesn't match.
pub fn pullValue(L: *State, comptime T: type, index: c_int) ?T {
    const info = @typeInfo(T);

    switch (info) {
        .int => {
            if (!L.isInteger(index)) return null;
            return @as(T, @intCast(L.toInteger(index)));
        },
        .float => {
            if (!L.isNumber(index)) return null;
            return @as(T, @floatCast(L.toNumber(index)));
        },
        .bool => {
            if (L.isNil(index)) return null;
            return L.toBoolean(index);
        },
        .optional => |opt_info| {
            if (L.isNil(index)) return null;
            return pullValue(L, opt_info.child, index);
        },
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                const s = L.toString(index) orelse return null;
                return s;
            }
            @compileError("unsupported pull type: " ++ @typeName(T));
        },
        else => @compileError("unsupported pull type: " ++ @typeName(T)),
    }
}

/// Read a string field from a table at `table_index`.
pub fn getTableString(L: *State, table_index: c_int, key: [:0]const u8) ?[]const u8 {
    const t = c.lua_getfield(L.handle, table_index, key.ptr);
    defer L.pop(1);
    if (t != c.LUA_TSTRING) return null;
    return L.toString(-1);
}

/// Read an integer field from a table at `table_index`.
pub fn getTableInteger(L: *State, table_index: c_int, key: [:0]const u8) ?i64 {
    const t = c.lua_getfield(L.handle, table_index, key.ptr);
    defer L.pop(1);
    if (t != c.LUA_TNUMBER) return null;
    return L.toInteger(-1);
}

/// Read a boolean field from a table at `table_index`.
pub fn getTableBoolean(L: *State, table_index: c_int, key: [:0]const u8) ?bool {
    const t = c.lua_getfield(L.handle, table_index, key.ptr);
    defer L.pop(1);
    if (t == c.LUA_TNIL) return null;
    return L.toBoolean(-1);
}

test "push and pull integer" {
    var L = State.init();
    defer L.deinit();

    pushValue(&L, @as(i64, 42));
    try std.testing.expectEqual(@as(i64, 42), pullValue(&L, i64, -1).?);
    L.pop(1);
}

test "push and pull string" {
    var L = State.init();
    defer L.deinit();

    pushValue(&L, "hello");
    try std.testing.expectEqualStrings("hello", pullValue(&L, []const u8, -1).?);
    L.pop(1);
}

test "push and pull boolean" {
    var L = State.init();
    defer L.deinit();

    pushValue(&L, true);
    try std.testing.expectEqual(true, pullValue(&L, bool, -1).?);
    L.pop(1);

    pushValue(&L, false);
    try std.testing.expectEqual(false, pullValue(&L, bool, -1).?);
    L.pop(1);
}

test "push nil" {
    var L = State.init();
    defer L.deinit();

    pushValue(&L, {});
    try std.testing.expect(L.isNil(-1));
    L.pop(1);
}

test "pull from nil returns null" {
    var L = State.init();
    defer L.deinit();

    L.pushNil();
    try std.testing.expect(pullValue(&L, i64, -1) == null);
    try std.testing.expect(pullValue(&L, []const u8, -1) == null);
    L.pop(1);
}
