//! MCP JSON-RPC response parsing and JSON-Schema → tools_common.Schema
//! conversion. Pure functions — no McpClient dependency — so they can be
//! tested in isolation and reused by future MCP server tooling.

const std = @import("std");
const log = std.log.scoped(.mcp);
const tools_common = @import("../tools/common.zig");

/// Parse a JSON-RPC response line and extract the `result` value.
/// Returns null when the response contains an error or no result.
/// Caller owns the returned value and must free with `parsed.deinit()`.
pub fn parseResponse(gpa: std.mem.Allocator, response: []const u8) !?std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, response, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Allocate parsed via a temporary optional so the `result`-found path can
    // transfer ownership; every other path deinits to avoid leaks.
    var maybe_parsed: ?std.json.Parsed(std.json.Value) =
        try std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{});
    errdefer if (maybe_parsed) |*p| p.deinit();
    const parsed = &(maybe_parsed orelse return null);

    if (parsed.value != .object) {
        parsed.deinit();
        return null;
    }
    const obj = parsed.value.object;

    // Check for error
    if (obj.get("error")) |err_val| {
        if (err_val == .object) {
            const code = if (err_val.object.get("code")) |c| (if (c == .integer) c.integer else 0) else 0;
            const message = if (err_val.object.get("message")) |m| (if (m == .string) m.string else "unknown error") else "unknown error";
            log.warn("MCP JSON-RPC error (code {d}): {s}", .{ code, message });
        }
        parsed.deinit();
        return null;
    }

    if (obj.get("result") == null) {
        parsed.deinit();
        return null;
    }

    return maybe_parsed;
}

/// Extract text content from a `tools/call` result.
/// Non-text content types (image, resource) produce descriptive placeholders
/// so the model is aware they exist even though it can't consume binary data.
pub fn extractContentText(gpa: std.mem.Allocator, result: std.json.Value) ![]u8 {
    const content_val = result.object.get("content") orelse return gpa.dupe(u8, "");
    if (content_val != .array) return gpa.dupe(u8, "");

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);

    for (content_val.array.items) |item| {
        if (item != .object) continue;
        const item_type = item.object.get("type") orelse continue;
        if (item_type != .string) continue;

        if (text.items.len > 0) try text.append(gpa, '\n');

        if (std.mem.eql(u8, item_type.string, "text")) {
            const text_val = item.object.get("text") orelse continue;
            if (text_val != .string) continue;
            try text.appendSlice(gpa, text_val.string);
        } else if (std.mem.eql(u8, item_type.string, "image")) {
            const mime = if (item.object.get("mimeType")) |m|
                (if (m == .string) m.string else "unknown")
            else
                "unknown";
            var buf: [128]u8 = undefined;
            const label = try std.fmt.bufPrint(&buf, "[Image content ({s})]", .{mime});
            try text.appendSlice(gpa, label);
        } else {
            var buf: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "[Content type: {s}]", .{item_type.string}) catch "[Unknown content]";
            try text.appendSlice(gpa, label);
        }
    }

    if (text.items.len == 0) {
        text.deinit(gpa);
        return gpa.dupe(u8, "");
    }
    return text.toOwnedSlice(gpa);
}

/// Convert a JSON Schema object to a tools_common.Schema.
/// Handles `properties`, `required`, `type`, `description`, `enum`,
/// and `default`. Simple JSON Schema unions preserve their primitive kinds
/// instead of collapsing a mixed union to `string`; nullable single-kind unions
/// preserve their enum constraint as well. Unsupported composition keywords
/// ($ref, allOf, or complex union branches) log a warning and fall back to
/// string kind so the tool is still callable.
pub fn schemaFromJsonSchema(gpa: std.mem.Allocator, value: std.json.Value) !tools_common.Schema {
    if (value != .object) return tools_common.Schema{ .properties = &.{} };
    const obj = value.object;
    const allow_extra_properties = if (obj.get("additionalProperties")) |extra|
        extra != .bool or extra.bool
    else
        true;

    const properties_val = obj.get("properties") orelse return tools_common.Schema{
        .properties = &.{},
        .allow_extra_properties = allow_extra_properties,
    };
    if (properties_val != .object) return tools_common.Schema{
        .properties = &.{},
        .allow_extra_properties = allow_extra_properties,
    };

    var required_set: std.StringHashMapUnmanaged(void) = .empty;
    defer required_set.deinit(gpa);
    if (obj.get("required")) |req_val| {
        if (req_val == .array) {
            for (req_val.array.items) |item| {
                if (item == .string) required_set.put(gpa, item.string, {}) catch {};
            }
        }
    }

    var props: std.ArrayList(tools_common.Schema.Property) = .empty;
    errdefer {
        for (props.items) |*p| {
            gpa.free(p.name);
            gpa.free(p.description);
            if (p.enum_values) |ev| {
                for (ev) |v| gpa.free(v);
                gpa.free(ev);
            }
            if (p.default_value) |dv| gpa.free(dv);
            if (p.kind_alternatives.len > 0) gpa.free(p.kind_alternatives);
        }
        props.deinit(gpa);
    }

    var iter = properties_val.object.iterator();
    while (iter.next()) |entry| {
        const prop_name = entry.key_ptr.*;
        const prop_val = entry.value_ptr.*;
        if (prop_val != .object) continue;
        const prop_obj = prop_val.object;

        var kind_alternatives: []const tools_common.Schema.Kind = &.{};
        var kind_alternatives_owned = false;
        errdefer if (kind_alternatives_owned) gpa.free(kind_alternatives);

        // Determine kind — preserve simple oneOf/anyOf primitive branches,
        // including mixed unions such as seek's array-or-empty-string fields.
        const kind = blk: {
            if (prop_obj.get("$ref") != null) {
                log.warn("MCP schema: $ref unsupported for '{s}', using string", .{prop_name});
                break :blk tools_common.Schema.Kind.string;
            }

            const one_of = prop_obj.get("oneOf");
            const any_of = prop_obj.get("anyOf");
            if (one_of != null and any_of != null) {
                log.warn("MCP schema: both oneOf and anyOf unsupported for '{s}', using string", .{prop_name});
                break :blk tools_common.Schema.Kind.string;
            }
            if (one_of orelse any_of) |branches| {
                if (try resolveUnionKinds(gpa, &branches, one_of != null)) |parsed_union| {
                    if (unionHasEnumConstraint(&branches) and
                        enumValueFromNullableUnion(&prop_val, parsed_union.primary, parsed_union.alternatives) == null)
                    {
                        if (parsed_union.owned) gpa.free(parsed_union.alternatives);
                        log.warn("MCP schema: oneOf/anyOf unsupported for '{s}', using string", .{prop_name});
                        break :blk tools_common.Schema.Kind.string;
                    }
                    kind_alternatives = parsed_union.alternatives;
                    kind_alternatives_owned = parsed_union.owned;
                    break :blk parsed_union.primary;
                }
                log.warn("MCP schema: oneOf/anyOf unsupported for '{s}', using string", .{prop_name});
                break :blk tools_common.Schema.Kind.string;
            }

            if (prop_obj.get("type")) |types| {
                if (types == .array) {
                    for (types.array.items) |item| {
                        if (item == .string and !std.mem.eql(u8, item.string, "null"))
                            break :blk kindFromString(item.string);
                    }
                }
            }
            const type_str = if (prop_obj.get("type")) |t|
                (if (t == .string) t.string else "string")
            else
                "string";
            break :blk kindFromString(type_str);
        };

        // Build description — append enum values if present
        const base_desc = if (prop_obj.get("description")) |d|
            (if (d == .string) d.string else "")
        else
            "";

        // Per-property owned fields. All are transferred to `props` on a
        // successful append; this errdefer cleans them up on any error exit
        // before that point (a partial enum extraction, a later failed dupe,
        // or the append itself). On success each optional is nulled so the
        // errdefer is inert. Without it, a `try` after the enum block (the
        // name dupe, the desc writer, or `props.append`) would leak the enum
        // list + its already-duped strings, since the outer `props` errdefer
        // only covers already-appended items.
        var p_name: ?[]u8 = null;
        var p_desc: ?[]const u8 = null;
        var p_enum: ?[]const []const u8 = null;
        var p_enum_count: usize = 0; // populated entries in p_enum (for partial-free)
        var p_default: ?[]const u8 = null;
        errdefer {
            if (p_name) |n| gpa.free(n);
            if (p_desc) |d| gpa.free(d);
            if (p_enum) |ev| {
                for (ev[0..p_enum_count]) |v| gpa.free(v);
                gpa.free(ev);
            }
            if (p_default) |dv| gpa.free(dv);
        }

        // Extract enum values into the dedicated field. Assign the list to
        // `p_enum` immediately so the errdefer owns it (and every partial
        // string) even when a mid-loop dupe fails — a bare `ev_list` local
        // would be unreachable from the errdefer and leak on partial failure.
        const enum_value: ?std.json.Value = if (prop_obj.get("enum")) |enum_val|
            enum_val
        else
            enumValueFromNullableUnion(&prop_val, kind, kind_alternatives);
        if (enum_value) |enum_val| {
            if (enum_val == .array and enum_val.array.items.len > 0) {
                const ev_list = try gpa.alloc([]const u8, enum_val.array.items.len);
                p_enum = ev_list;
                for (enum_val.array.items) |ev| {
                    switch (ev) {
                        .string => |s| {
                            ev_list[p_enum_count] = try gpa.dupe(u8, s);
                            p_enum_count += 1;
                        },
                        .integer => |n| {
                            var buf: [32]u8 = undefined;
                            const formatted = try std.fmt.bufPrint(&buf, "{d}", .{n});
                            ev_list[p_enum_count] = try gpa.dupe(u8, formatted);
                            p_enum_count += 1;
                        },
                        else => continue,
                    }
                }
                if (p_enum_count == 0) {
                    gpa.free(ev_list);
                    p_enum = null;
                } else if (p_enum_count != ev_list.len) {
                    p_enum = try gpa.realloc(ev_list, p_enum_count);
                }
            }
        }

        p_desc = if (p_enum) |ev| blk: {
            // Append [enum: ...] to description when enum values exist
            var total_len = base_desc.len + 8; // "[enum: " (7) + "]" (1) = 8
            if (base_desc.len > 0) total_len += 1; // " "
            for (ev, 0..) |v, ei| {
                if (ei > 0) total_len += 2; // ", "
                total_len += v.len;
            }

            const buf = try gpa.alloc(u8, total_len);
            errdefer gpa.free(buf);

            var offset: usize = 0;
            if (base_desc.len > 0) {
                @memcpy(buf[offset .. offset + base_desc.len], base_desc);
                offset += base_desc.len;
                buf[offset] = ' ';
                offset += 1;
            }
            @memcpy(buf[offset .. offset + 7], "[enum: ");
            offset += 7;
            for (ev, 0..) |v, ei| {
                if (ei > 0) {
                    @memcpy(buf[offset .. offset + 2], ", ");
                    offset += 2;
                }
                @memcpy(buf[offset .. offset + v.len], v);
                offset += v.len;
            }
            buf[offset] = ']';
            offset += 1;
            std.debug.assert(offset == total_len);

            break :blk buf;
        } else try gpa.dupe(u8, base_desc);

        // Extract default value as a raw JSON string fragment.
        if (prop_obj.get("default")) |def_val| {
            p_default = try jsonValueToRawFragment(gpa, def_val);
        }

        p_name = try gpa.dupe(u8, prop_name);

        try props.append(gpa, .{
            .name = p_name.?,
            .kind = kind,
            .description = p_desc.?,
            .required = required_set.contains(prop_name),
            .nullable = schemaAllowsNull(&prop_val),
            .enum_values = p_enum,
            .default_value = p_default,
            .kind_alternatives = kind_alternatives,
        });
        // Ownership transferred to `props`; null the locals so a later
        // iteration's error doesn't double-free them via this errdefer.
        p_name = null;
        p_desc = null;
        p_enum = null;
        p_default = null;
        kind_alternatives = &.{};
        kind_alternatives_owned = false;
    }

    return .{
        .properties = try props.toOwnedSlice(gpa),
        .allow_extra_properties = allow_extra_properties,
    };
}

// Keep server nullability separate from the provider's optional-null encoding.
// Preserve null when unsupported schema constraints leave nullability unknown.
// Only known non-nullable types/unions justify optional-null omission.
fn schemaAllowsNull(value: *const std.json.Value) bool {
    if (value.* != .object) return true;
    if (value.object.get("type")) |kind| {
        if (kind == .string) return std.mem.eql(u8, kind.string, "null");
        if (kind == .array) {
            for (kind.array.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, "null")) return true;
            }
            return false;
        }
    }
    if (value.object.get("oneOf")) |branches| {
        if (branches != .array) return true;
        var null_matching_branches: usize = 0;
        for (branches.array.items) |branch| {
            if (branch != .object) return true;
            const kind = branch.object.get("type") orelse return true;
            if (kind == .string) {
                if (std.mem.eql(u8, kind.string, "null")) null_matching_branches += 1;
                continue;
            }
            if (kind != .array) return true;
            var branch_accepts_null = false;
            for (kind.array.items) |item| {
                if (item != .string) return true;
                if (std.mem.eql(u8, item.string, "null")) branch_accepts_null = true;
            }
            if (branch_accepts_null) null_matching_branches += 1;
        }
        return null_matching_branches == 1;
    }
    if (value.object.get("anyOf")) |branches| {
        if (branches != .array) return true;
        for (branches.array.items) |branch| {
            if (branch != .object) return true;
            const kind = branch.object.get("type") orelse return true;
            if (kind == .string and std.mem.eql(u8, kind.string, "null")) return true;
            if (kind == .array) {
                for (kind.array.items) |item| {
                    if (item == .string and std.mem.eql(u8, item.string, "null")) return true;
                }
            }
        }
        return false;
    }
    return true;
}

/// Convert a std.json.Value to a raw JSON fragment string suitable for
/// embedding in a tool definition's `"default"` field. Strings are JSON-quoted;
/// numbers/booleans/null are emitted as their JSON literal; objects and arrays
/// fall back to `"null"`.
fn jsonValueToRawFragment(gpa: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    switch (value) {
        .string => |s| return std.json.Stringify.valueAlloc(gpa, s, .{}),
        .integer => |n| {
            var buf: [32]u8 = undefined;
            const formatted = try std.fmt.bufPrint(&buf, "{d}", .{n});
            return gpa.dupe(u8, formatted);
        },
        .float => |f| return std.json.Stringify.valueAlloc(gpa, f, .{}),
        .bool => |b| return gpa.dupe(u8, if (b) "true" else "false"),
        .null => return gpa.dupe(u8, "null"),
        else => return gpa.dupe(u8, "null"),
    }
}

fn kindFromString(kind: []const u8) tools_common.Schema.Kind {
    if (std.mem.eql(u8, kind, "integer")) return .integer;
    if (std.mem.eql(u8, kind, "number")) return .number;
    if (std.mem.eql(u8, kind, "object")) return .object;
    if (std.mem.eql(u8, kind, "array")) return .array;
    if (std.mem.eql(u8, kind, "boolean")) return .boolean;
    return .string;
}

const ParsedUnion = struct {
    primary: tools_common.Schema.Kind,
    alternatives: []const tools_common.Schema.Kind,
    owned: bool,
};

fn resolveUnionKinds(gpa: std.mem.Allocator, value: *const std.json.Value, exclusive: bool) !?ParsedUnion {
    if (value.* != .array or value.array.items.len == 0) return null;
    var kinds: std.ArrayList(tools_common.Schema.Kind) = .empty;
    errdefer kinds.deinit(gpa);

    var has_null_branch = false;
    const supported = blk: {
        for (value.array.items) |branch| {
            if (branch != .object) break :blk false;
            if (!unionBranchHasOnlyTypeAndAnnotations(&branch.object)) break :blk false;
            const type_value = branch.object.get("type") orelse break :blk false;
            const branch_kinds = unionBranchKinds(&type_value) orelse break :blk false;

            if (exclusive) {
                if (has_null_branch and branch_kinds.has_null) break :blk false;
                if (unionKindsOverlap(kinds.items, branch_kinds.kinds())) break :blk false;
            }
            has_null_branch = has_null_branch or branch_kinds.has_null;

            for (branch_kinds.kinds()) |kind| {
                var already_present = false;
                for (kinds.items) |existing| {
                    if (existing == kind) {
                        already_present = true;
                        break;
                    }
                }
                if (!already_present) try kinds.append(gpa, kind);
            }
        }
        break :blk true;
    };
    if (!supported) {
        kinds.deinit(gpa);
        return null;
    }
    if (kinds.items.len == 0) return null;
    const primary = kinds.items[0];
    if (kinds.items.len == 1) {
        kinds.deinit(gpa);
        return .{ .primary = primary, .alternatives = &.{}, .owned = false };
    }
    const alternatives = try gpa.alloc(tools_common.Schema.Kind, kinds.items.len - 1);
    @memcpy(alternatives, kinds.items[1..]);
    kinds.deinit(gpa);
    return .{ .primary = primary, .alternatives = alternatives, .owned = true };
}

const UnionBranchKinds = struct {
    items: [6]tools_common.Schema.Kind = undefined,
    len: usize = 0,
    has_null: bool = false,

    fn kinds(self: *const UnionBranchKinds) []const tools_common.Schema.Kind {
        return self.items[0..self.len];
    }

    fn append(self: *UnionBranchKinds, kind: tools_common.Schema.Kind) bool {
        for (self.kinds()) |existing| {
            if (existing == kind) return true;
        }
        if (self.len == self.items.len) return false;
        self.items[self.len] = kind;
        self.len += 1;
        return true;
    }
};

fn unionBranchHasOnlyTypeAndAnnotations(branch: *const std.json.ObjectMap) bool {
    var iterator = branch.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "type")) continue;
        if (std.mem.eql(u8, key, "title")) continue;
        if (std.mem.eql(u8, key, "description")) continue;
        if (std.mem.eql(u8, key, "default")) continue;
        if (std.mem.eql(u8, key, "enum")) continue;
        if (std.mem.eql(u8, key, "examples")) continue;
        if (std.mem.eql(u8, key, "$comment")) continue;
        if (std.mem.eql(u8, key, "deprecated")) continue;
        if (std.mem.eql(u8, key, "readOnly")) continue;
        if (std.mem.eql(u8, key, "writeOnly")) continue;
        return false;
    }
    return true;
}

fn unionHasEnumConstraint(branches: *const std.json.Value) bool {
    if (branches.* != .array) return false;
    for (branches.array.items) |branch| {
        if (branch == .object and branch.object.get("enum") != null) return true;
    }
    return false;
}

/// Return the enum from a nullable union only when it describes the union's
/// sole non-null branch. A branch-specific enum cannot be represented when
/// multiple non-null kinds are accepted by `Schema.Property`.
fn enumValueFromNullableUnion(
    value: *const std.json.Value,
    primary_kind: tools_common.Schema.Kind,
    alternatives: []const tools_common.Schema.Kind,
) ?std.json.Value {
    if (alternatives.len > 0 or value.* != .object) return null;
    const branches = value.object.get("oneOf") orelse value.object.get("anyOf") orelse return null;
    if (branches != .array) return null;

    var typed_branch: ?std.json.Value = null;
    var typed_branch_count: usize = 0;
    var has_null_branch = false;
    for (branches.array.items) |branch| {
        if (branch != .object) return null;
        if (!unionBranchHasOnlyTypeAndAnnotations(&branch.object)) return null;
        const type_value = branch.object.get("type") orelse return null;
        const branch_kinds = unionBranchKinds(&type_value) orelse return null;
        if (branch_kinds.has_null) has_null_branch = true;
        if (branch_kinds.kinds().len == 0) {
            if (!branch_kinds.has_null) return null;
            continue;
        }
        if (branch_kinds.kinds().len != 1 or branch_kinds.kinds()[0] != primary_kind) return null;
        typed_branch = branch;
        typed_branch_count += 1;
    }

    if (typed_branch_count != 1 or !has_null_branch) return null;
    const enum_value = typed_branch.?.object.get("enum") orelse return null;
    if (enum_value != .array or enum_value.array.items.len == 0) return null;
    return enum_value;
}

fn unionBranchKinds(value: *const std.json.Value) ?UnionBranchKinds {
    var branch: UnionBranchKinds = .{};
    switch (value.*) {
        .string => |type_name| {
            if (std.mem.eql(u8, type_name, "null")) {
                branch.has_null = true;
            } else {
                const kind = supportedUnionKind(type_name) orelse return null;
                if (!branch.append(kind)) return null;
            }
        },
        .array => |type_names| {
            if (type_names.items.len == 0) return null;
            for (type_names.items) |item| {
                if (item != .string) return null;
                if (std.mem.eql(u8, item.string, "null")) {
                    branch.has_null = true;
                } else {
                    const kind = supportedUnionKind(item.string) orelse return null;
                    if (!branch.append(kind)) return null;
                }
            }
        },
        else => return null,
    }
    return branch;
}

fn supportedUnionKind(type_name: []const u8) ?tools_common.Schema.Kind {
    if (std.mem.eql(u8, type_name, "string")) return .string;
    if (std.mem.eql(u8, type_name, "integer")) return .integer;
    if (std.mem.eql(u8, type_name, "number")) return .number;
    if (std.mem.eql(u8, type_name, "object")) return .object;
    if (std.mem.eql(u8, type_name, "array")) return .array;
    if (std.mem.eql(u8, type_name, "boolean")) return .boolean;
    return null;
}

fn unionKindsOverlap(left: []const tools_common.Schema.Kind, right: []const tools_common.Schema.Kind) bool {
    for (left) |left_kind| {
        for (right) |right_kind| {
            if (left_kind == right_kind) return true;
            if (left_kind == .integer and right_kind == .number) return true;
            if (left_kind == .number and right_kind == .integer) return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "schemaFromJsonSchema handles array and number types" {
    const gpa = std.testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{
        \\  "items":{"type":"array","description":"List of items"},
        \\  "price":{"type":"number","description":"Item price"},
        \\  "count":{"type":"integer","description":"Number of items"}
        \\}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();

    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), schema.properties.len);
    for (schema.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "items"))
            try std.testing.expectEqual(tools_common.Schema.Kind.array, prop.kind);
        if (std.mem.eql(u8, prop.name, "price"))
            try std.testing.expectEqual(tools_common.Schema.Kind.number, prop.kind);
        if (std.mem.eql(u8, prop.name, "count"))
            try std.testing.expectEqual(tools_common.Schema.Kind.integer, prop.kind);
    }
}

test "tool contract: MCP additionalProperties policy survives conversion" {
    const gpa = std.testing.allocator;
    const closed_json =
        \\{"type":"object","additionalProperties":false,"properties":{}}
    ;
    const open_json =
        \\{"type":"object","properties":{}}
    ;
    const closed_parsed = try std.json.parseFromSlice(std.json.Value, gpa, closed_json, .{});
    defer closed_parsed.deinit();
    const open_parsed = try std.json.parseFromSlice(std.json.Value, gpa, open_json, .{});
    defer open_parsed.deinit();

    var closed_schema = try schemaFromJsonSchema(gpa, closed_parsed.value);
    defer closed_schema.deinit(gpa);
    var open_schema = try schemaFromJsonSchema(gpa, open_parsed.value);
    defer open_schema.deinit(gpa);

    try std.testing.expect(!closed_schema.allow_extra_properties);
    try std.testing.expect(open_schema.allow_extra_properties);
}

test "schemaFromJsonSchema appends enum values to description and populates enum_values" {
    const gpa = std.testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{
        \\  "color":{"type":"string","description":"Color choice","enum":["red","green","blue"]}
        \\}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();

    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), schema.properties.len);
    try std.testing.expect(std.mem.indexOf(u8, schema.properties[0].description, "[enum: red, green, blue]") != null);
    // Verify enum_values field is populated.
    const ev = schema.properties[0].enum_values orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(usize, 3), ev.len);
    try std.testing.expectEqualStrings("red", ev[0]);
    try std.testing.expectEqualStrings("green", ev[1]);
    try std.testing.expectEqualStrings("blue", ev[2]);
}

test "MCP default fragments round-trip escaped strings and extreme floats" {
    const gpa = std.testing.allocator;
    const text = "quoted \"value\"\\path\n\r\t";
    const string_fragment = try jsonValueToRawFragment(gpa, .{ .string = text });
    defer gpa.free(string_fragment);
    const parsed_string = try std.json.parseFromSlice([]const u8, gpa, string_fragment, .{});
    defer parsed_string.deinit();
    try std.testing.expectEqualStrings(text, parsed_string.value);

    const number = std.math.floatMax(f64);
    const float_fragment = try jsonValueToRawFragment(gpa, .{ .float = number });
    defer gpa.free(float_fragment);
    const parsed_float = try std.json.parseFromSlice(f64, gpa, float_fragment, .{});
    defer parsed_float.deinit();
    try std.testing.expectEqual(number, parsed_float.value);
}

test "schemaFromJsonSchema extracts default value" {
    const gpa = std.testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{
        \\  "mode":{"type":"string","description":"Run mode","default":"fast"},
        \\  "count":{"type":"integer","description":"Repeat count","default":3}
        \\}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();

    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), schema.properties.len);
    // String default → JSON-quoted.
    const mode_default = schema.properties[0].default_value orelse "";
    try std.testing.expectEqualStrings("\"fast\"", mode_default);
    // Integer default → bare number.
    const count_default = schema.properties[1].default_value orelse "";
    try std.testing.expectEqualStrings("3", count_default);
}

test "schemaFromJsonSchema resolves simple homogeneous anyOf to shared kind" {
    const gpa = std.testing.allocator;
    // Non-string primitives prove the resolver actually ran: the fallback is
    // also .string, so a string/string union would be indistinguishable from it.
    const schema_json =
        \\{"type":"object","properties":{
        \\  "limit":{"anyOf":[{"type":"integer"},{"type":"integer"}],"description":"Max results"},
        \\  "ratio":{"anyOf":[{"type":"number"},{"type":"number"}],"description":"Ratio"},
        \\  "enabled":{"anyOf":[{"type":"boolean"},{"type":"boolean"}],"description":"Flag"}
        \\}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();

    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), schema.properties.len);
    for (schema.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "limit"))
            try std.testing.expectEqual(tools_common.Schema.Kind.integer, prop.kind);
        if (std.mem.eql(u8, prop.name, "ratio"))
            try std.testing.expectEqual(tools_common.Schema.Kind.number, prop.kind);
        if (std.mem.eql(u8, prop.name, "enabled"))
            try std.testing.expectEqual(tools_common.Schema.Kind.boolean, prop.kind);
    }
}

test "schemaFromJsonSchema preserves nullable enum unions" {
    const gpa = std.testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{
        \\  "time_range":{"anyOf":[{"type":"string","enum":["day","week","month","year"]},{"type":"null"}]},
        \\  "exact_match":{"anyOf":[{"type":"boolean"},{"type":"null"}]}
        \\}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();

    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), schema.properties.len);
    var found_time_range = false;
    var found_exact_match = false;
    for (schema.properties) |prop| {
        try std.testing.expect(prop.nullable);
        if (std.mem.eql(u8, prop.name, "time_range")) {
            found_time_range = true;
            try std.testing.expectEqual(tools_common.Schema.Kind.string, prop.kind);
            try std.testing.expectEqual(@as(usize, 0), prop.kind_alternatives.len);
            const enum_values = prop.enum_values orelse return error.MissingEnumValues;
            try std.testing.expectEqual(@as(usize, 4), enum_values.len);
            try std.testing.expectEqualStrings("day", enum_values[0]);
            try std.testing.expectEqualStrings("week", enum_values[1]);
            try std.testing.expectEqualStrings("month", enum_values[2]);
            try std.testing.expectEqualStrings("year", enum_values[3]);
        } else if (std.mem.eql(u8, prop.name, "exact_match")) {
            found_exact_match = true;
            try std.testing.expectEqual(tools_common.Schema.Kind.boolean, prop.kind);
        }
    }
    try std.testing.expect(found_time_range);
    try std.testing.expect(found_exact_match);
}

test "schemaFromJsonSchema resolves nullable primitive unions (type:null branch ignored)" {
    const gpa = std.testing.allocator;
    // count is the load-bearing case: without skipping "null", integer != the
    // .string that kindFromString("null") yields, so resolution would fail and
    // fall back to .string. Asserting .integer proves the skip works.
    const schema_json =
        \\{"type":"object","properties":{
        \\  "count":{"anyOf":[{"type":"integer"},{"type":"null"}],"description":"Optional count"},
        \\  "name":{"oneOf":[{"type":"string"},{"type":"null"}],"description":"Optional name"}
        \\}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();

    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), schema.properties.len);
    for (schema.properties) |prop| {
        try std.testing.expect(prop.nullable);
        if (std.mem.eql(u8, prop.name, "count"))
            try std.testing.expectEqual(tools_common.Schema.Kind.integer, prop.kind);
        if (std.mem.eql(u8, prop.name, "name"))
            try std.testing.expectEqual(tools_common.Schema.Kind.string, prop.kind);
    }
}

test "MCP schema preserves explicit nullability separately from optionality" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"type":"object","properties":{"repo":{"type":"string"},"count":{"type":["integer","null"]}},"required":["count"]}
    , .{});
    defer parsed.deinit();
    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);
    for (schema.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "repo")) {
            try std.testing.expect(!prop.required);
            try std.testing.expect(!prop.nullable);
        } else {
            try std.testing.expect(prop.required);
            try std.testing.expect(prop.nullable);
            try std.testing.expectEqual(tools_common.Schema.Kind.integer, prop.kind);
        }
    }
}

test "MCP schema preserves null when a property's constraints are unknown" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"properties":{"anything":{},"reference":{"$ref":"#/definitions/Item"}}}
    , .{});
    defer parsed.deinit();
    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);
    for (schema.properties) |prop| try std.testing.expect(prop.nullable);
}

test "schemaFromJsonSchema falls back to string for $ref properties" {
    const gpa = std.testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{
        \\  "ref_item":{"$ref":"#/definitions/Item","description":"Referenced"}
        \\}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();

    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), schema.properties.len);
    try std.testing.expectEqual(tools_common.Schema.Kind.string, schema.properties[0].kind);
}

test "schemaFromJsonSchema leaks no per-property fields on a mid-iteration OOM" {
    // Regression for the per-iteration errdefer: when an allocation fails
    // AFTER the per-property owned fields are built (enum list + duped
    // strings, desc, default, name) but BEFORE ownership transfers to
    // `props`, those fields must be freed, not leaked. Iterate every
    // allocation index so every failure point is covered (including the
    // append itself); the FailingAllocator wraps the testing allocator, so
    // any leak surfaces as a testing-allocator leak at process end.
    const gpa = std.testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{
        \\  "mode":{"type":"string","description":"Run mode","enum":["a","b"],"default":"x"}
        \\}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();

    var succeeded = false;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = i });
        if (schemaFromJsonSchema(failing.allocator(), parsed.value)) |schema| {
            var s = schema;
            s.deinit(failing.allocator());
            succeeded = true;
            break;
        } else |err| {
            // The FailingAllocator surfaces direct allocs as OutOfMemory, but
            // the Allocating writer maps an OOM inside a write to WriteFailed
            // — both are valid OOM-class failures. The load-bearing assertion
            // is leak-freedom (checked by the testing allocator at process end),
            // not the exact error code.
            try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
        }
    }
    // Sanity: the function must reach a successful iteration within the bound,
    // otherwise the loop tested nothing but OOMs.
    try std.testing.expect(succeeded);
}

test "schemaFromJsonSchema preserves mixed primitive union alternatives" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"type":"object","properties":{"field":{"anyOf":[{"type":["null","array"]},{"type":"string"}]}}}
    , .{});
    defer parsed.deinit();

    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);
    try std.testing.expectEqual(tools_common.Schema.Kind.array, schema.properties[0].kind);
    try std.testing.expectEqual(@as(usize, 1), schema.properties[0].kind_alternatives.len);
    try std.testing.expectEqual(tools_common.Schema.Kind.string, schema.properties[0].kind_alternatives[0]);
    try std.testing.expect(schema.properties[0].nullable);
}

test "schemaFromJsonSchema preserves disjoint oneOf alternatives" {
    const gpa = std.testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{"field":{"oneOf":[{"type":"integer"},{"type":"string"}]}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();

    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);
    try std.testing.expectEqual(tools_common.Schema.Kind.integer, schema.properties[0].kind);
    try std.testing.expectEqual(@as(usize, 1), schema.properties[0].kind_alternatives.len);
    try std.testing.expectEqual(tools_common.Schema.Kind.string, schema.properties[0].kind_alternatives[0]);
}

test "schemaFromJsonSchema falls back for constrained or overlapping unions" {
    const gpa = std.testing.allocator;
    const schema_json =
        \\{"type":"object","required":["duplicate_null"],"properties":{
        \\  "constrained":{"anyOf":[{"type":"integer","minimum":5},{"type":"string","pattern":"^x"}]},
        \\  "overlapping":{"oneOf":[{"type":"integer"},{"type":"number"}]},
        \\  "duplicate_null":{"oneOf":[{"type":"null"},{"type":"null"}]}
        \\}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();

    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);

    var found_constrained = false;
    var found_overlapping = false;
    var found_duplicate_null = false;
    for (schema.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "constrained")) {
            found_constrained = true;
            try std.testing.expectEqual(tools_common.Schema.Kind.string, prop.kind);
            try std.testing.expectEqual(@as(usize, 0), prop.kind_alternatives.len);
        }
        if (std.mem.eql(u8, prop.name, "overlapping")) {
            found_overlapping = true;
            try std.testing.expectEqual(tools_common.Schema.Kind.string, prop.kind);
            try std.testing.expectEqual(@as(usize, 0), prop.kind_alternatives.len);
        }
        if (std.mem.eql(u8, prop.name, "duplicate_null")) {
            found_duplicate_null = true;
            try std.testing.expectEqual(tools_common.Schema.Kind.string, prop.kind);
            try std.testing.expectEqual(@as(usize, 0), prop.kind_alternatives.len);
            try std.testing.expect(!prop.nullable);
        }
    }
    try std.testing.expect(found_constrained);
    try std.testing.expect(found_overlapping);
    try std.testing.expect(found_duplicate_null);

    const tools_schema = @import("../tools/schema.zig");
    var constrained_validation = try tools_schema.validateArgs(
        gpa,
        schema,
        "{\"constrained\":4,\"duplicate_null\":\"present\"}",
    );
    defer constrained_validation.deinit(gpa);
    try std.testing.expect(!constrained_validation.isValid());

    var overlapping_validation = try tools_schema.validateArgs(
        gpa,
        schema,
        "{\"overlapping\":1,\"duplicate_null\":\"present\"}",
    );
    defer overlapping_validation.deinit(gpa);
    try std.testing.expect(!overlapping_validation.isValid());

    var duplicate_null_validation = try tools_schema.validateArgs(
        gpa,
        schema,
        "{\"duplicate_null\":null}",
    );
    defer duplicate_null_validation.deinit(gpa);
    try std.testing.expect(!duplicate_null_validation.isValid());
}

test "schemaFromJsonSchema falls back to string for empty unions" {
    const gpa = std.testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{"empty":{"oneOf":[]}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();

    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);
    try std.testing.expectEqual(tools_common.Schema.Kind.string, schema.properties[0].kind);
}

test "schemaFromJsonSchema preserves object and array union alternatives" {
    const gpa = std.testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{"value":{"anyOf":[{"type":"object"},{"type":"array"}]}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();

    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);
    try std.testing.expectEqual(tools_common.Schema.Kind.object, schema.properties[0].kind);
    try std.testing.expectEqual(@as(usize, 1), schema.properties[0].kind_alternatives.len);
    try std.testing.expectEqual(tools_common.Schema.Kind.array, schema.properties[0].kind_alternatives[0]);
}

test "parseResponse extracts result from a JSON-RPC response" {
    const gpa = std.testing.allocator;
    const response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\"}}";
    const parsed = try parseResponse(gpa, response) orelse return error.NoResult;
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NoResultField;
    try std.testing.expectEqualStrings("2024-11-05", result.object.get("protocolVersion").?.string);
}

test "parseResponse returns null for an error response" {
    const gpa = std.testing.allocator;
    const response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600,\"message\":\"Bad Request\"}}";
    const parsed = try parseResponse(gpa, response);
    try std.testing.expect(parsed == null);
}

test "parseResponse returns null for empty input" {
    const gpa = std.testing.allocator;
    const parsed = try parseResponse(gpa, "   \n\t  ");
    try std.testing.expect(parsed == null);
}

test "extractContentText joins text items with newlines" {
    const gpa = std.testing.allocator;
    const result_json =
        \\{"content":[
        \\  {"type":"text","text":"Hello"},
        \\  {"type":"text","text":"World"}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, result_json, .{});
    defer parsed.deinit();
    const text = try extractContentText(gpa, parsed.value);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("Hello\nWorld", text);
}

test "extractContentText labels image content with mime type" {
    const gpa = std.testing.allocator;
    const result_json =
        \\{"content":[
        \\  {"type":"image","mimeType":"image/png"}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, result_json, .{});
    defer parsed.deinit();
    const text = try extractContentText(gpa, parsed.value);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("[Image content (image/png)]", text);
}

test "extractContentText returns empty string for missing content" {
    const gpa = std.testing.allocator;
    const result_json = "{}";
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, result_json, .{});
    defer parsed.deinit();
    const text = try extractContentText(gpa, parsed.value);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("", text);
}
