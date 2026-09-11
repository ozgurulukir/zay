//! Lua JSON bridge module — extracted from `plugin_api.zig`.
//!
//! Provides `zay.json_decode` and `zay.json_encode` bridge functions,
//! plus bidirectional conversion between `std.json.Value` and Lua stack values.

const std = @import("std");
const c = @import("c");
const State = @import("../state.zig").State;
const bridge = @import("../bridge.zig");

/// ── zay.json_decode(string) ─────────────────────────────────────────
///
/// Parses a JSON string into a native Lua value (table/string/number/boolean/
/// nil). Returns the value on success, or nil + error message on failure.
pub fn jsonDecode(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const gpa = std.heap.page_allocator;

    const json = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("json_decode: string argument is required");
        return 2;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch |err| {
        state.pushNil();
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "json_decode: {s}", .{@errorName(err)}) catch "json_decode: parse error";
        state.pushString(msg);
        return 2;
    };
    defer parsed.deinit();

    pushJsonValue(L_ptr, gpa, parsed.value) catch {
        state.pushNil();
        state.pushString("json_decode: failed to push value");
        return 2;
    };
    return 1;
}

/// ── zay.json_encode(value, opts?) ───────────────────────────────────
///
/// Converts a Lua value to a JSON string. `opts` is an optional table with:
///   pretty (bool) — emit indented (indent_2) output for human editing.
/// Returns the JSON string on success, or nil + error message on failure.
pub fn jsonEncode(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const gpa = std.heap.page_allocator;

    // Optional opts table at index 2: { pretty: bool }.
    var pretty: bool = false;
    if (c.lua_gettop(L_ptr) >= 2 and c.lua_istable(L_ptr, 2)) {
        pretty = bridge.getTableBoolean(&state, 2, "pretty") orelse false;
    }

    const out = luaValueToJsonString(gpa, L_ptr, 1, pretty, 0) catch |err| {
        state.pushNil();
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "json_encode: {s}", .{@errorName(err)}) catch "json_encode: failed";
        state.pushString(msg);
        return 2;
    };
    defer gpa.free(out);

    state.pushString(out);
    return 1;
}

/// Recursively serialize the Lua value at `index` into a JSON string.
pub fn luaValueToJsonString(
    gpa: std.mem.Allocator,
    L: *c.lua_State,
    index: c_int,
    pretty: bool,
    depth: usize,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try writeLuaValueJson(&aw.writer, L, index, pretty, depth);
    return aw.toOwnedSlice();
}

/// Write one Lua value (at `index`) as JSON into `writer`.
const JsonWriteError = std.Io.Writer.Error;
fn writeLuaValueJson(
    writer: *std.Io.Writer,
    L: *c.lua_State,
    index: c_int,
    pretty: bool,
    depth: usize,
) JsonWriteError!void {
    switch (c.lua_type(L, index)) {
        c.LUA_TNIL => try writer.writeAll("null"),
        c.LUA_TBOOLEAN => try writer.writeAll(if (c.lua_toboolean(L, index) != 0) "true" else "false"),
        c.LUA_TNUMBER => {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, index, &len);
            if (ptr) |p| try writer.writeAll(p[0..len]) else try writer.writeAll("0");
        },
        c.LUA_TSTRING => {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, index, &len) orelse {
                try writer.writeAll("\"\"");
                return;
            };
            try writeJsonString(writer, ptr[0..len]);
        },
        c.LUA_TTABLE => try writeTableJson(writer, L, index, pretty, depth),
        else => try writer.writeAll("null"),
    }
}

/// Quote and escape a byte slice as a JSON string literal.
fn writeJsonString(writer: *std.Io.Writer, s: []const u8) JsonWriteError!void {
    try writer.writeByte('"');
    for (s) |b| switch (b) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        else => {
            if (b < 0x20) {
                var hex_buf: [6]u8 = undefined;
                const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{b}) catch unreachable;
                try writer.writeAll(hex);
            } else {
                try writer.writeByte(b);
            }
        },
    };
    try writer.writeByte('"');
}

/// Serialize a Lua table, inferring array vs object from its key shape.
fn writeTableJson(
    writer: *std.Io.Writer,
    L: *c.lua_State,
    index: c_int,
    pretty: bool,
    depth: usize,
) JsonWriteError!void {
    const array_len = c.lua_rawlen(L, index);

    var total: usize = 0;
    c.lua_pushnil(L);
    while (c.lua_next(L, index) != 0) : (total += 1) {
        c.lua_pop(L, 1);
    }

    if (total == 0) {
        try writer.writeAll("[]");
        return;
    }

    if (array_len == total) {
        try writeTableAsArray(writer, L, index, pretty, depth, @intCast(array_len));
    } else {
        try writeTableAsObject(writer, L, index, pretty, depth);
    }
}

/// Serialize a table known to have contiguous integer keys 1..len as a JSON array.
fn writeTableAsArray(
    writer: *std.Io.Writer,
    L: *c.lua_State,
    index: c_int,
    pretty: bool,
    depth: usize,
    len: c_int,
) JsonWriteError!void {
    try writer.writeByte('[');
    var i: c_int = 1;
    while (i <= len) : (i += 1) {
        if (i > 1) try writer.writeByte(',');
        if (pretty) try writeIndent(writer, depth + 1);
        _ = c.lua_rawgeti(L, index, i);
        try writeLuaValueJson(writer, L, c.lua_gettop(L), pretty, depth + 1);
        c.lua_pop(L, 1);
    }
    if (pretty and len > 0) try writeIndent(writer, depth);
    try writer.writeByte(']');
}

/// Serialize a table as a JSON object, iterating all key/value pairs.
fn writeTableAsObject(
    writer: *std.Io.Writer,
    L: *c.lua_State,
    index: c_int,
    pretty: bool,
    depth: usize,
) JsonWriteError!void {
    try writer.writeByte('{');
    var first = true;
    c.lua_pushnil(L);
    while (c.lua_next(L, index) != 0) {
        if (!first) try writer.writeByte(',');
        first = false;
        if (pretty) try writeIndent(writer, depth + 1);

        const key_type = c.lua_type(L, -2);
        switch (key_type) {
            c.LUA_TSTRING, c.LUA_TNUMBER => {
                var klen: usize = 0;
                const kptr = c.lua_tolstring(L, -2, &klen) orelse continue;
                try writeJsonString(writer, kptr[0..klen]);
            },
            c.LUA_TBOOLEAN => {
                const s = if (c.lua_toboolean(L, -2) != 0) "true" else "false";
                try writeJsonString(writer, s);
            },
            else => continue,
        }

        if (pretty) try writer.writeAll(": ") else try writer.writeByte(':');
        try writeLuaValueJson(writer, L, c.lua_gettop(L), pretty, depth + 1);
        c.lua_pop(L, 1);
    }
    if (pretty and !first) try writeIndent(writer, depth);
    try writer.writeByte('}');
}

/// Write `depth` levels of 2-space indentation (the indent_2 convention).
fn writeIndent(writer: *std.Io.Writer, depth: usize) JsonWriteError!void {
    try writer.writeByte('\n');
    var i: usize = 0;
    while (i < depth) : (i += 1) try writer.writeAll("  ");
}

/// Recursively push a `std.json.Value` onto the Lua stack.
pub fn pushJsonValue(L: *c.lua_State, gpa: std.mem.Allocator, value: std.json.Value) !void {
    switch (value) {
        .null => c.lua_pushnil(L),
        .bool => |b| c.lua_pushboolean(L, if (b) 1 else 0),
        .integer => |i| c.lua_pushinteger(L, i),
        .float => |f| c.lua_pushnumber(L, f),
        .number_string => |s| {
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

/// Parse a JSON string and push the result onto the Lua stack as a Lua value.
pub fn pushJsonToLua(L: *c.lua_State, gpa: std.mem.Allocator, json: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    try pushJsonValue(L, gpa, parsed.value);
}

// ── Tests ────────────────────────────────────────────────────────────

fn expectLuaOk(L: *State, chunk: [:0]const u8) !void {
    const ok = L.doString(chunk);
    if (!ok) {
        const err = L.getErrorMessage();
        std.debug.print("Lua error: {s}\n", .{err orelse "unknown"});
        L.pop(1);
        try std.testing.expect(ok);
    }
    var len: usize = 0;
    const ptr = c.lua_tolstring(L.handle, -1, &len);
    const got = if (ptr) |p| p[0..len] else "";
    defer c.lua_pop(L.handle, 1);
    try std.testing.expectEqualStrings("OK", got);
}

test "bridges.json: object becomes Lua table" {
    const sandbox = @import("../sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local t = zay.json_decode('{"a": 1, "b": "hi"}')
        \\assert(type(t) == "table", "expected table")
        \\assert(t.a == 1, "a should be 1")
        \\assert(t.b == "hi", "b should be hi")
        \\return "OK"
    );
}

test "bridges.json: array becomes 1-indexed table" {
    const sandbox = @import("../sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local arr = zay.json_decode('[10, 20, 30]')
        \\assert(arr[1] == 10, "arr[1] should be 10")
        \\assert(arr[2] == 20, "arr[2] should be 20")
        \\assert(arr[3] == 30, "arr[3] should be 30")
        \\return "OK"
    );
}

test "bridges.json: round-trip preserves structure" {
    const sandbox = @import("../sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local original = '{"id": 7, "steps": [{"text": "a", "done": true}]}'
        \\local decoded = zay.json_decode(original)
        \\local encoded = zay.json_encode(decoded)
        \\local redecoded = zay.json_decode(encoded)
        \\assert(redecoded.id == 7, "top-level scalar preserved")
        \\assert(redecoded.steps[1].text == "a", "nested object.text preserved")
        \\assert(redecoded.steps[1].done == true, "nested object.done preserved")
        \\return "OK"
    );
}
