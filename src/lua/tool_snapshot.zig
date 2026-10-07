//! Owned, immutable tool metadata captured before a plugin is published.
//! Only capture reads Lua; registry/UI consumers clone host-owned snapshots.

const std = @import("std");
const c = @import("c");
const tools_common = @import("../tools/common.zig");

pub const registration_closed_key = "zay_tool_registration_closed";

pub const ToolSnapshot = struct {
    name: []const u8,
    description: []const u8,
    schema: tools_common.Schema,
    index: c_int,

    pub fn deinit(self: *ToolSnapshot, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.description);
        self.schema.deinit(gpa);
    }
};

pub fn deinit(gpa: std.mem.Allocator, snapshots: []ToolSnapshot) void {
    for (snapshots) |*snapshot| snapshot.deinit(gpa);
    gpa.free(snapshots);
}

/// The caller exclusively owns L (initialization, before publication).
pub fn capture(gpa: std.mem.Allocator, L: *c.lua_State) ![]ToolSnapshot {
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    c.lua_pushboolean(L, 1);
    c.lua_setfield(L, c.LUA_REGISTRYINDEX, registration_closed_key);
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "zay_tools");
    if (c.lua_isnil(L, -1)) return try gpa.alloc(ToolSnapshot, 0);
    const count = c.lua_rawlen(L, -1);
    const snapshots = try gpa.alloc(ToolSnapshot, count);
    errdefer gpa.free(snapshots);
    var built: usize = 0;
    errdefer for (snapshots[0..built]) |*snapshot| snapshot.deinit(gpa);
    for (snapshots, 0..) |*snapshot, i| {
        const index: c_int = @intCast(i + 1);
        _ = c.lua_rawgeti(L, -1, index);
        const name = try copyField(gpa, L, "name");
        errdefer gpa.free(name);
        const description = try copyField(gpa, L, "description");
        errdefer gpa.free(description);
        var schema = try buildToolSchemaFromLua(gpa, L);
        errdefer schema.deinit(gpa);
        snapshot.* = .{ .name = name, .description = description, .schema = schema, .index = index };
        built += 1;
        c.lua_pop(L, 1);
    }
    return snapshots;
}

fn copyField(gpa: std.mem.Allocator, L: *c.lua_State, field: [:0]const u8) ![]u8 {
    _ = c.lua_getfield(L, -1, field);
    defer c.lua_pop(L, 1);
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return error.InvalidToolMetadata;
    return gpa.dupe(u8, ptr[0..len]);
}

/// Parse a `parameters` table at the top of the Lua stack into a
/// `tools_common.Schema`. Mirrors the previous private helper in
/// `tui/provider_model.zig`; relocated here so plugin-side and
/// agent-side share one definition.
fn buildToolSchemaFromLua(
    gpa: std.mem.Allocator,
    L: *c.lua_State,
) !tools_common.Schema {
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    _ = c.lua_getfield(L, -1, "parameters");
    if (!c.lua_istable(L, -1)) return .{ .properties = &.{} };

    var props: std.ArrayList(tools_common.Schema.Property) = .empty;
    errdefer {
        for (props.items) |p| {
            gpa.free(p.name);
            gpa.free(p.description);
            if (p.enum_values) |ev| {
                for (ev) |v| gpa.free(v);
                gpa.free(ev);
            }
            if (p.default_value) |dv| gpa.free(dv);
        }
        props.deinit(gpa);
    }

    c.lua_pushnil(L);
    while (c.lua_next(L, -2) != 0) {
        var key_len: usize = 0;
        const key_ptr = c.lua_tolstring(L, -2, &key_len);
        const param_name = if (key_ptr) |p| try gpa.dupe(u8, p[0..key_len]) else {
            c.lua_pop(L, 1);
            continue;
        };
        if (!c.lua_istable(L, -1)) {
            gpa.free(param_name);
            c.lua_pop(L, 1);
            continue;
        }

        errdefer gpa.free(param_name);
        _ = c.lua_getfield(L, -1, "type");
        var type_len: usize = 0;
        const type_ptr = c.lua_tolstring(L, -1, &type_len);
        const kind = if (type_ptr) |p| parseToolParamType(p[0..type_len]) else .string;
        c.lua_pop(L, 1);

        _ = c.lua_getfield(L, -1, "description");
        var desc_len: usize = 0;
        const desc_ptr = c.lua_tolstring(L, -1, &desc_len);
        const description = if (desc_ptr) |p| try gpa.dupe(u8, p[0..desc_len]) else try gpa.dupe(u8, "");
        c.lua_pop(L, 1);
        errdefer gpa.free(description);

        _ = c.lua_getfield(L, -1, "optional");
        const optional = c.lua_isboolean(L, -1) and c.lua_toboolean(L, -1) != 0;
        c.lua_pop(L, 1);

        _ = c.lua_getfield(L, -1, "nullable");
        const nullable = c.lua_isboolean(L, -1) and c.lua_toboolean(L, -1) != 0;
        c.lua_pop(L, 1);

        _ = c.lua_getfield(L, -1, "enum");
        const enum_values = try copyEnum(gpa, L);
        c.lua_pop(L, 1);
        errdefer if (enum_values) |values| {
            for (values) |value| gpa.free(value);
            gpa.free(values);
        };

        var default_value: ?[]const u8 = null;
        _ = c.lua_getfield(L, -1, "default");
        if (!c.lua_isnil(L, -1)) {
            default_value = try luaValueToJson(gpa, L);
        }
        c.lua_pop(L, 1);

        errdefer if (default_value) |value| gpa.free(value);
        try props.append(gpa, .{
            .name = param_name,
            .kind = kind,
            .description = description,
            .required = !optional,
            .nullable = nullable,
            .enum_values = enum_values,
            .default_value = default_value,
        });
        c.lua_pop(L, 1); // pop value, keep key for next iteration
    }
    return .{ .properties = try props.toOwnedSlice(gpa) };
}

fn parseToolParamType(type_str: []const u8) tools_common.Schema.Kind {
    if (std.mem.eql(u8, type_str, "string")) return .string;
    if (std.mem.eql(u8, type_str, "integer")) return .integer;
    if (std.mem.eql(u8, type_str, "number")) return .number;
    if (std.mem.eql(u8, type_str, "boolean")) return .boolean;
    if (std.mem.eql(u8, type_str, "object")) return .object;
    if (std.mem.eql(u8, type_str, "array")) return .array;
    return .string;
}

fn copyEnum(gpa: std.mem.Allocator, L: *c.lua_State) !?[]const []const u8 {
    if (!c.lua_istable(L, -1)) return null;
    const count = c.lua_rawlen(L, -1);
    if (count == 0) return null;
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    const values = try gpa.alloc([]const u8, count);
    errdefer gpa.free(values);
    var built: usize = 0;
    errdefer for (values[0..built]) |value| gpa.free(value);
    for (values, 0..) |*value, i| {
        _ = c.lua_rawgeti(L, -1, @intCast(i + 1));
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len) orelse return error.InvalidToolMetadata;
        value.* = try gpa.dupe(u8, ptr[0..len]);
        built += 1;
        c.lua_pop(L, 1);
    }
    return values;
}

fn luaValueToJson(gpa: std.mem.Allocator, L: *c.lua_State) ![]const u8 {
    if (c.lua_isboolean(L, -1)) return gpa.dupe(u8, if (c.lua_toboolean(L, -1) != 0) "true" else "false");
    if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len) orelse return error.InvalidToolMetadata;
        return gpa.dupe(u8, ptr[0..len]);
    }
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return gpa.dupe(u8, "null");
    return std.json.Stringify.valueAlloc(gpa, ptr[0..len], .{});
}
