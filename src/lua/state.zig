//! Thin Zig wrapper around a `lua_State*` handle.
//!
//! Provides safe init/deinit, chunk loading, and value conversion
//! so callers never touch the raw C API directly.

const std = @import("std");
const c = @import("c");

const assert = std.debug.assert;

/// Wraps a `lua_State*` with safe init/deinit and common operations.
pub const State = struct {
    handle: *c.lua_State,

    const Self = @This();

    /// Create a new Lua state with all standard libraries opened.
    /// Returns `error.LuaInitFailed` if the Lua runtime cannot allocate the state.
    pub fn init() error{LuaInitFailed}!Self {
        const L = c.luaL_newstate() orelse return error.LuaInitFailed;
        c.luaL_openlibs(L);
        return Self{ .handle = L };
    }

    /// Close the Lua state and free all resources.
    pub fn deinit(self: *Self) void {
        c.lua_close(self.handle);
    }

    // ── chunk loading ──────────────────────────────────────────────

    /// Load a Lua chunk from a null-terminated string.
    /// The chunk is left on the stack as a function.
    pub fn loadString(self: *Self, chunk: [:0]const u8) !void {
        const rc = c.luaL_loadstring(self.handle, chunk.ptr);
        if (rc != c.LUA_OK) {
            return error.LuaLoadError;
        }
    }

    /// Load a Lua chunk from pre-compiled bytecode.
    /// The chunk is left on the stack as a function.
    /// Returns error.LuaLoadError if the bytecode is invalid or
    /// incompatible with the current Lua version.
    pub fn loadBuffer(self: *Self, bytecode: []const u8, name: [:0]const u8) !void {
        const rc = c.luaL_loadbufferx(self.handle, bytecode.ptr, bytecode.len, name.ptr, null);
        if (rc != c.LUA_OK) {
            return error.LuaLoadError;
        }
    }

    /// Dump the function at the top of the stack as binary bytecode.
    /// The function is NOT popped. Returns the bytecode or an error.
    /// Caller owns the returned slice.
    pub fn dump(self: *Self, gpa: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);

        const WriterContext = struct {
            buf: *std.ArrayList(u8),
            gpa: std.mem.Allocator,
        };

        var ctx = WriterContext{ .buf = &buf, .gpa = gpa };

        const writer_fn: c.lua_Writer = struct {
            fn write(L: ?*c.lua_State, p: ?*const anyopaque, sz: usize, ud: ?*anyopaque) callconv(.c) c_int {
                _ = L;
                const wctx: *WriterContext = @ptrCast(@alignCast(ud.?));
                const bytes: [*]const u8 = @ptrCast(p.?);
                wctx.buf.appendSlice(wctx.gpa, bytes[0..sz]) catch return 1;
                return 0;
            }
        }.write;

        const rc = c.lua_dump(self.handle, writer_fn, &ctx, 0);
        if (rc != 0) return error.LuaDumpError;

        return try buf.toOwnedSlice(gpa);
    }

    /// Load and run a Lua chunk. Returns true on success, false on error
    /// (error message is left on the stack).
    pub fn doString(self: *Self, chunk: [:0]const u8) bool {
        if (c.luaL_loadstring(self.handle, chunk.ptr) != c.LUA_OK) return false;
        return self.pcall(0, c.LUA_MULTRET) == c.LUA_OK;
    }

    // ── protected call ─────────────────────────────────────────────

    /// Protected call to a function on the stack.
    /// `nargs` = number of arguments on the stack (below the function).
    /// `nresults` = number of expected results (-1 = all, LUA_MULTRET).
    /// Returns `LUA_OK` on success, or an error code on failure.
    /// On error, the error message is on top of the stack.
    pub fn pcall(self: *Self, nargs: c_int, nresults: c_int) c_int {
        // Use lua_pcallk directly to avoid the translated-C inline wrapper
        // that has a type mismatch with NULL as lua_KFunction.
        return c.lua_pcallk(self.handle, nargs, nresults, 0, 0, null);
    }

    // ── stack introspection ────────────────────────────────────────

    /// Return the index of the top element (1-based). 0 means empty stack.
    pub fn getTop(self: *Self) c_int {
        return c.lua_gettop(self.handle);
    }

    /// Return the type of the value at the given index.
    pub fn typeOf(self: *Self, index: c_int) c_int {
        return c.lua_type(self.handle, index);
    }

    /// Check if the value at `index` is a string.
    pub fn isString(self: *Self, index: c_int) bool {
        return c.lua_isstring(self.handle, index) != 0;
    }

    /// Check if the value at `index` is an integer.
    pub fn isInteger(self: *Self, index: c_int) bool {
        return c.lua_isinteger(self.handle, index) != 0;
    }

    /// Check if the value at `index` is a number.
    pub fn isNumber(self: *Self, index: c_int) bool {
        return c.lua_isnumber(self.handle, index) != 0;
    }

    /// Check if the value at `index` is a table.
    pub fn isTable(self: *Self, index: c_int) bool {
        return c.lua_istable(self.handle, index);
    }

    /// Check if the value at `index` is a function.
    pub fn isFunction(self: *Self, index: c_int) bool {
        return c.lua_isfunction(self.handle, index);
    }

    /// Check if the value at `index` is nil.
    pub fn isNil(self: *Self, index: c_int) bool {
        return c.lua_isnil(self.handle, index);
    }

    // ── value extraction ───────────────────────────────────────────

    /// Get the value at `index` as an integer. Returns 0 if not an integer.
    pub fn toInteger(self: *Self, index: c_int) i64 {
        var isnum: c_int = 0;
        return c.lua_tointegerx(self.handle, index, &isnum);
    }

    /// Get the value at `index` as a number (f64). Returns 0.0 if not a number.
    pub fn toNumber(self: *Self, index: c_int) f64 {
        var isnum: c_int = 0;
        return c.lua_tonumberx(self.handle, index, &isnum);
    }

    /// Get the value at `index` as a string. Returns null if not a string.
    /// The returned slice is owned by Lua (valid while value is on stack).
    pub fn toString(self: *Self, index: c_int) ?[]const u8 {
        var len: usize = 0;
        const ptr = c.lua_tolstring(self.handle, index, &len);
        return if (ptr) |p| p[0..len] else null;
    }

    /// Get the value at `index` as a boolean.
    pub fn toBoolean(self: *Self, index: c_int) bool {
        return c.lua_toboolean(self.handle, index) != 0;
    }

    // ── stack manipulation ─────────────────────────────────────────

    /// Push a string onto the stack.
    pub fn pushString(self: *Self, s: []const u8) void {
        _ = c.lua_pushlstring(self.handle, s.ptr, s.len);
    }

    /// Push a null-terminated string onto the stack.
    pub fn pushCString(self: *Self, s: [:0]const u8) void {
        _ = c.lua_pushstring(self.handle, s.ptr);
    }

    /// Push an integer onto the stack.
    pub fn pushInteger(self: *Self, n: i64) void {
        c.lua_pushinteger(self.handle, n);
    }

    /// Push a number (f64) onto the stack.
    pub fn pushNumber(self: *Self, n: f64) void {
        c.lua_pushnumber(self.handle, n);
    }

    /// Push a boolean onto the stack.
    pub fn pushBoolean(self: *Self, b: bool) void {
        c.lua_pushboolean(self.handle, @intFromBool(b));
    }

    /// Push nil onto the stack.
    pub fn pushNil(self: *Self) void {
        c.lua_pushnil(self.handle);
    }

    /// Pop `n` elements from the stack.
    pub fn pop(self: *Self, n: c_int) void {
        c.lua_pop(self.handle, n);
    }

    /// Remove the element at `index`, shifting down elements above it.
    pub fn remove(self: *Self, index: c_int) void {
        c.lua_remove(self.handle, index);
    }

    /// Set the stack top to `index` (removes elements above).
    pub fn setTop(self: *Self, index: c_int) void {
        c.lua_settop(self.handle, index);
    }

    // ── table operations ────────────────────────────────────────────

    /// Push the value of `key` from the table at `index` onto the stack.
    /// `key` is a string. Returns the type of the pushed value.
    pub fn getField(self: *Self, index: c_int, key: [:0]const u8) c_int {
        return c.lua_getfield(self.handle, index, key.ptr);
    }

    /// Set the value on top of the stack as a field `key` in the table at `index`.
    /// Pops the value from the stack.
    pub fn setField(self: *Self, index: c_int, key: [:0]const u8) void {
        c.lua_setfield(self.handle, index, key.ptr);
    }

    /// Create a new table and push it onto the stack.
    pub fn newTable(self: *Self) void {
        c.lua_newtable(self.handle);
    }

    /// Push the value at `key` (integer) from the table at `index`.
    /// Returns the type of the pushed value.
    pub fn rawGetI(self: *Self, index: c_int, key: c_int) c_int {
        return c.lua_rawgeti(self.handle, index, key);
    }

    /// Set the value on top of the stack at `key` (integer) in the table at `index`.
    /// Pops the value.
    pub fn rawSetI(self: *Self, index: c_int, key: c_int) void {
        c.lua_rawseti(self.handle, index, key);
    }

    // ── error handling ─────────────────────────────────────────────

    /// Get the error message from the top of the stack after a failed pcall.
    /// Returns null if the top value is not a string.
    pub fn getErrorMessage(self: *Self) ?[]const u8 {
        return self.toString(-1);
    }

    /// Format and raise a Lua error. Does not return.
    pub fn raiseError(self: *Self, comptime fmt: []const u8, args: anytype) noreturn {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "Lua runtime error";
        _ = c.lua_pushlstring(self.handle, msg.ptr, msg.len);
        _ = c.lua_error(self.handle);
        unreachable;
    }
};

test "lua state: create and destroy" {
    var L = try State.init();
    defer L.deinit();
    try std.testing.expect(L.getTop() == 0);
}

test "lua state: doString with arithmetic" {
    var L = try State.init();
    defer L.deinit();

    // Run a simple expression
    try std.testing.expect(L.doString("return 1 + 1"));
    try std.testing.expect(L.isInteger(-1));
    try std.testing.expectEqual(@as(i64, 2), L.toInteger(-1));
    L.pop(1);
}

test "lua state: doString with string" {
    var L = try State.init();
    defer L.deinit();

    try std.testing.expect(L.doString("return 'hello, world'"));
    try std.testing.expect(L.isString(-1));
    const s = L.toString(-1);
    try std.testing.expect(s != null);
    try std.testing.expectEqualStrings("hello, world", s.?);
    L.pop(1);
}

test "lua state: loadString + pcall" {
    var L = try State.init();
    defer L.deinit();

    try L.loadString("return 3 * 4");
    const rc = L.pcall(0, 1);
    try std.testing.expectEqual(@as(c_int, c.LUA_OK), rc);
    try std.testing.expectEqual(@as(i64, 12), L.toInteger(-1));
    L.pop(1);
}

test "lua state: load error" {
    var L = try State.init();
    defer L.deinit();

    // Syntax error
    try std.testing.expectError(error.LuaLoadError, L.loadString("syntax error here @@@"));
}

test "lua state: pcall runtime error" {
    var L = try State.init();
    defer L.deinit();

    try L.loadString("error('boom')");
    const rc = L.pcall(0, 1);
    try std.testing.expect(rc != c.LUA_OK);
    const msg = L.getErrorMessage();
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "boom") != null);
    L.pop(1);
}

test "lua state: table operations" {
    var L = try State.init();
    defer L.deinit();

    try std.testing.expect(L.doString(
        \\return { name = "test", value = 42 }
    ));
    try std.testing.expect(L.isTable(-1));

    // Read fields
    try std.testing.expectEqual(@as(c_int, c.LUA_TSTRING), L.getField(-1, "name"));
    try std.testing.expectEqualStrings("test", L.toString(-1).?);
    L.pop(1);

    try std.testing.expectEqual(@as(c_int, c.LUA_TNUMBER), L.getField(-1, "value"));
    try std.testing.expectEqual(@as(i64, 42), L.toInteger(-1));
    L.pop(1);

    L.pop(1); // pop the table
}

test "lua state: loadBuffer loads pre-compiled bytecode" {
    const gpa = std.testing.allocator;
    var L = try State.init();
    defer L.deinit();

    // Load source, dump to bytecode
    try L.loadString("return 2 + 2");
    const bytecode = try L.dump(gpa);
    defer gpa.free(bytecode);
    L.pop(1); // pop the loaded function

    // Load bytecode in a fresh state
    var L2 = try State.init();
    defer L2.deinit();
    try L2.loadBuffer(bytecode, "test");
    const rc = L2.pcall(0, 1);
    try std.testing.expectEqual(@as(c_int, c.LUA_OK), rc);
    try std.testing.expectEqual(@as(i64, 4), L2.toInteger(-1));
    L2.pop(1);
}

test "lua state: dump and loadBuffer round-trips" {
    const gpa = std.testing.allocator;
    var L = try State.init();
    defer L.deinit();

    try L.loadString("return 'hello, bytecode!'");
    const bytecode = try L.dump(gpa);
    defer gpa.free(bytecode);
    L.pop(1);

    // Verify bytecode is non-empty
    try std.testing.expect(bytecode.len > 0);

    // Load and run in same state
    try L.loadBuffer(bytecode, "roundtrip");
    const rc = L.pcall(0, 1);
    try std.testing.expectEqual(@as(c_int, c.LUA_OK), rc);
    try std.testing.expectEqualStrings("hello, bytecode!", L.toString(-1).?);
    L.pop(1);
}

test "lua state: raiseError raises error caught by pcall" {
    var L = try State.init();
    defer L.deinit();

    const CFunctionHelper = struct {
        fn testCFunction(raw_L: ?*c.lua_State) callconv(.c) c_int {
            var st = State{ .handle = raw_L.? };
            st.raiseError("test error formatted {d}", .{42});
        }
    };

    c.lua_pushcfunction(L.handle, CFunctionHelper.testCFunction);
    const rc = L.pcall(0, 0);
    try std.testing.expect(rc != c.LUA_OK);
    const err_msg = L.getErrorMessage();
    try std.testing.expect(err_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, err_msg.?, "test error formatted 42") != null);
    L.pop(1);
}
