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
/// and `default`. Unsupported composition keywords ($ref, oneOf, anyOf, allOf)
/// log a warning and fall back to string kind so the tool is still callable.
pub fn schemaFromJsonSchema(gpa: std.mem.Allocator, value: std.json.Value) !tools_common.Schema {
    if (value != .object) return tools_common.Schema{ .properties = &.{} };
    const obj = value.object;

    const properties_val = obj.get("properties") orelse return tools_common.Schema{ .properties = &.{} };
    if (properties_val != .object) return tools_common.Schema{ .properties = &.{} };

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
        }
        props.deinit(gpa);
    }

    var iter = properties_val.object.iterator();
    while (iter.next()) |entry| {
        const prop_name = entry.key_ptr.*;
        const prop_val = entry.value_ptr.*;
        if (prop_val != .object) continue;
        const prop_obj = prop_val.object;

        // Determine kind — handle unsupported composition keywords gracefully
        const kind = blk: {
            if (prop_obj.get("$ref") != null) {
                log.warn("MCP schema: $ref unsupported for '{s}', using string", .{prop_name});
                break :blk tools_common.Schema.Kind.string;
            }
            if (prop_obj.get("oneOf") != null or prop_obj.get("anyOf") != null) {
                log.warn("MCP schema: oneOf/anyOf unsupported for '{s}', using string", .{prop_name});
                break :blk tools_common.Schema.Kind.string;
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

        // Extract enum values into the dedicated field.
        var enum_values: ?[]const []const u8 = null;
        if (prop_obj.get("enum")) |enum_val| {
            if (enum_val == .array and enum_val.array.items.len > 0) {
                var ev_list = try gpa.alloc([]const u8, enum_val.array.items.len);
                var ev_idx: usize = 0;
                for (enum_val.array.items) |ev| {
                    switch (ev) {
                        .string => |s| ev_list[ev_idx] = try gpa.dupe(u8, s),
                        .integer => |n| ev_list[ev_idx] = try std.fmt.allocPrint(gpa, "{d}", .{n}),
                        else => continue,
                    }
                    ev_idx += 1;
                }
                if (ev_idx == 0) {
                    gpa.free(ev_list);
                } else {
                    enum_values = try gpa.realloc(ev_list, ev_idx);
                }
            }
        }

        const desc_owned = if (enum_values != null) blk: {
            // Append [enum: ...] to description when enum values exist
            var dw: std.Io.Writer.Allocating = .init(gpa);
            errdefer dw.deinit();
            try dw.writer.writeAll(base_desc);
            if (base_desc.len > 0) try dw.writer.writeAll(" ");
            try dw.writer.writeAll("[enum: ");
            if (enum_values) |ev| {
                for (ev, 0..) |v, ei| {
                    if (ei > 0) try dw.writer.writeAll(", ");
                    try dw.writer.writeAll(v);
                }
            }
            try dw.writer.writeAll("]");
            break :blk try dw.toOwnedSlice();
        } else try gpa.dupe(u8, base_desc);

        // Extract default value as a raw JSON string fragment.
        var default_value: ?[]const u8 = null;
        if (prop_obj.get("default")) |def_val| {
            default_value = try jsonValueToRawFragment(gpa, def_val);
        }

        try props.append(gpa, .{
            .name = try gpa.dupe(u8, prop_name),
            .kind = kind,
            .description = desc_owned,
            .required = required_set.contains(prop_name),
            .enum_values = enum_values,
            .default_value = default_value,
        });
    }

    return .{ .properties = try props.toOwnedSlice(gpa) };
}

/// Convert a std.json.Value to a raw JSON fragment string suitable for
/// embedding in a tool definition's `"default"` field. Strings are JSON-quoted;
/// numbers/booleans/null are emitted as their JSON literal; objects and arrays
/// fall back to `"null"`.
fn jsonValueToRawFragment(gpa: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    switch (value) {
        .string => |s| {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            try aw.writer.writeByte('"');
            try aw.writer.writeAll(s);
            try aw.writer.writeByte('"');
            return aw.toOwnedSlice();
        },
        .integer => |n| return std.fmt.allocPrint(gpa, "{d}", .{n}),
        .float => |f| return std.fmt.allocPrint(gpa, "{d}", .{f}),
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

test "schemaFromJsonSchema falls back to string for $ref and oneOf" {
    const gpa = std.testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{
        \\  "ref_item":{"$ref":"#/definitions/Item","description":"Referenced"},
        \\  "union":{"oneOf":[{"type":"string"},{"type":"integer"}],"description":"Union type"}
        \\}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();

    var schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer schema.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), schema.properties.len);
    for (schema.properties) |prop| {
        try std.testing.expectEqual(tools_common.Schema.Kind.string, prop.kind);
    }
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
