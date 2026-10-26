//! Bridge between the MCP subsystem and the agent's `ToolRegistry` — the
//! MCP counterpart of `lua/registry_bridge.zig`. Each tool discovered on a
//! connected server is materialized as a plain `tools.Tool` record and
//! synced into the registry by `ToolRegistry.syncMcpTools`, so dispatch,
//! schema resolution, display, and `tools_json` assembly all read the same
//! registry path as builtins and plugin tools.
//!
//! The `Tool.userdata` carries an owned `McpToolKey` of NAMES plus a deep
//! copy of the tool's schema — not a client pointer: connections drop and
//! reconnect asynchronously, so the record
//! must stay valid across churn. At run time the key is resolved back to the
//! live client through `Env.ctx.mcp_manager`; a stale record (server
//! disconnected) degrades to a failed result instead of a dangling call.

const std = @import("std");
const manager_mod = @import("manager.zig");
const naming = @import("naming.zig");
const tools_common = @import("../tools/common.zig");

const McpManager = manager_mod.McpManager;

/// Per-tool context owned by the registry; freed by `freeMcpToolKey` when
/// the record is removed. Holds copies of the server and tool names, a DEEP
/// COPY of the tool's parameter schema, and a copy of the server's raw
/// `inputSchema` JSON — not client pointers: connections drop and reconnect
/// asynchronously, so every field must stay valid across churn. At run time
/// the key is resolved back to the live client through `Env.ctx.mcp_manager`;
/// a stale record (server disconnected) degrades to a failed result instead
/// of a dangling call.
pub const McpToolKey = struct {
    server_name: []u8,
    tool_name: []u8,
    schema: tools_common.Schema,
    /// The server's original `inputSchema` as raw JSON (lossless copy). The
    /// registry record must outlive the client that discovered it, so this
    /// is a deep copy too — same lifetime as `schema`.
    raw_input_schema: ?[]u8 = null,
};

/// Free callback for `Tool.userdata_free`.
pub fn freeMcpToolKey(gpa: std.mem.Allocator, ud: *anyopaque) void {
    const key: *McpToolKey = @ptrCast(@alignCast(ud));
    gpa.free(key.server_name);
    gpa.free(key.tool_name);
    key.schema.deinit(gpa);
    if (key.raw_input_schema) |raw| gpa.free(raw);
    gpa.destroy(key);
}

/// Run one MCP tool call: resolve the live client for the key's server and
/// post the arguments. Resolution failures mirror the executor's MCP error
/// wording so the model sees the same messages on either dispatch path.
pub fn runMcpTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    args: []const u8,
    env: tools_common.Env,
) tools_common.Error!tools_common.Output {
    _ = cwd;
    const key: *McpToolKey = @ptrCast(@alignCast(env.userdata));
    const manager = env.ctx.mcp_manager orelse
        return tools_common.fail(gpa, "no MCP manager is configured", 1);
    const server_args = normalizeArguments(gpa, key.schema, args) catch |err| {
        return tools_common.failFmt(gpa, 1, "Invalid MCP arguments: {s}", .{@errorName(err)});
    };
    defer gpa.free(server_args);

    const result_text = blk: {
        for (manager.clients.items) |*client| {
            if (client.status() != .connected) continue;
            if (!std.mem.eql(u8, client.name, key.server_name)) continue;
            break :blk client.callTool(io, key.tool_name, server_args) catch |err| {
                return tools_common.failFmt(gpa, 1, "MCP tool '{s}' failed: {s}", .{ key.tool_name, @errorName(err) });
            };
        }
        return tools_common.fail(gpa, "MCP server not found", 1);
    };

    // Single ownership: `stdout` owns the final text from here on — the
    // empty case frees `result_text` inline before substituting the
    // placeholder, so a second errdefer on `result_text` would double-free
    // on the `stdout` allocation failure.
    const stdout = if (result_text.len > 0)
        result_text
    else blk2: {
        gpa.free(result_text);
        break :blk2 try gpa.dupe(u8, "(no output)");
    };
    errdefer gpa.free(stdout);
    const stderr = try gpa.alloc(u8, 0);
    return .{ .stdout = stdout, .stderr = stderr, .code = 0 };
}

/// Undo the provider's optional-null encoding only for non-nullable server fields.
fn normalizeArguments(gpa: std.mem.Allocator, schema: tools_common.Schema, args: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, args, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    for (schema.properties) |prop| {
        const value = parsed.value.object.get(prop.name) orelse continue;
        if (value != .null or prop.nullable) continue;
        if (prop.required) return error.RequiredArgumentNull;
        _ = parsed.value.object.swapRemove(prop.name);
    }
    return std.json.Stringify.valueAlloc(gpa, parsed.value, .{});
}

test "MCP arguments omit optional non-nullable nulls and preserve server nulls" {
    const gpa = std.testing.allocator;
    const schema: tools_common.Schema = .{ .properties = &.{
        .{ .name = "repo", .kind = .string, .description = "", .required = false },
        .{ .name = "nullable", .kind = .string, .description = "", .required = false, .nullable = true },
        .{ .name = "query", .kind = .string, .description = "", .required = true },
    } };
    const args = try normalizeArguments(gpa, schema, "{\"repo\":null,\"nullable\":null,\"query\":\"hello\",\"extra\":null}");
    defer gpa.free(args);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, args, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.contains("repo"));
    try std.testing.expectEqual(std.json.Value.null, parsed.value.object.get("nullable").?);
    try std.testing.expect(parsed.value.object.contains("extra"));
    try std.testing.expectEqualStrings("hello", parsed.value.object.get("query").?.string);
    try std.testing.expectError(error.RequiredArgumentNull, normalizeArguments(gpa, schema, "{\"query\":null}"));
}

test "MCP arguments preserve unconstrained nullable nulls" {
    const gpa = std.testing.allocator;
    const schema: tools_common.Schema = .{ .properties = &.{.{
        .name = "value",
        .kind = .string,
        .description = "",
        .required = true,
        .nullable = true,
        .kind_unconstrained = true,
    }} };
    const args = try normalizeArguments(gpa, schema, "{\"value\":null}");
    defer gpa.free(args);
    try std.testing.expectEqualStrings("{\"value\":null}", args);
}

test "MCP arguments enforce nullability for unconstrained properties" {
    const gpa = std.testing.allocator;
    const schema: tools_common.Schema = .{ .properties = &.{.{
        .name = "value",
        .kind = .string,
        .description = "",
        .required = false,
        .kind_unconstrained = true,
    }} };
    const args = try normalizeArguments(gpa, schema, "{\"value\":null}");
    defer gpa.free(args);
    try std.testing.expectEqualStrings("{}", args);

    const required_schema: tools_common.Schema = .{ .properties = &.{.{
        .name = "value",
        .kind = .string,
        .description = "",
        .required = true,
        .kind_unconstrained = true,
    }} };
    try std.testing.expectError(
        error.RequiredArgumentNull,
        normalizeArguments(gpa, required_schema, "{\"value\":null}"),
    );
}

/// arguments when expanded (mirrors the plugin display policy).
pub fn displayMcpTool(
    gpa: std.mem.Allocator,
    args: []const u8,
    env: tools_common.Env,
) std.mem.Allocator.Error!tools_common.ToolDisplay {
    const key: *McpToolKey = @ptrCast(@alignCast(env.userdata));
    if (args.len == 0) return .{ .label = try gpa.dupe(u8, key.tool_name) };
    return .{
        .label = try gpa.dupe(u8, key.tool_name),
        .expanded_label = try std.fmt.allocPrint(gpa, "{s} {s}", .{ key.tool_name, args }),
    };
}

/// Build one `Tool` record for a discovered MCP tool. The returned
/// `Tool.userdata` is a heap-allocated `*McpToolKey`; ownership transfers to
/// the registry (`userdata_free`). `name`, `description`, the deep-copied
/// `schema`, and the copied `raw_input_schema` are owned and freed when the
/// record is removed. Both schema forms are cloned: the client may free its
/// copies on a mid-turn disconnect/reconnect while this record is still
/// alive.
pub fn buildMcpTool(
    gpa: std.mem.Allocator,
    server_name: []const u8,
    tool_name: []const u8,
    description: []const u8,
    schema: tools_common.Schema,
    raw_input_schema: ?[]const u8,
) !tools_common.Tool {
    const full_name = try naming.toolFullName(gpa, server_name, tool_name);
    errdefer gpa.free(full_name);
    const desc_owned = try gpa.dupe(u8, description);
    errdefer gpa.free(desc_owned);

    // Hoist the key's owned fields into locals so every errdefer below frees
    // an initialized slice — `try` dupes inside a struct literal would leave
    // the key's fields undefined when a later one fails.
    const server_name_owned = try gpa.dupe(u8, server_name);
    errdefer gpa.free(server_name_owned);
    const tool_name_owned = try gpa.dupe(u8, tool_name);
    errdefer gpa.free(tool_name_owned);
    const raw_owned = if (raw_input_schema) |raw| try gpa.dupe(u8, raw) else null;
    errdefer if (raw_owned) |raw| gpa.free(raw);

    const schema_clone = try schema.clone(gpa);
    errdefer {
        var clone = schema_clone;
        clone.deinit(gpa);
    }

    const key = try gpa.create(McpToolKey);
    errdefer gpa.destroy(key);
    key.* = .{
        .server_name = server_name_owned,
        .tool_name = tool_name_owned,
        .schema = schema_clone,
        .raw_input_schema = raw_owned,
    };
    return .{
        .name = full_name,
        .description = desc_owned,
        .schema = key.schema,
        .raw_input_schema = key.raw_input_schema,
        .run = runMcpTool,
        .display = displayMcpTool,
        .userdata = @ptrCast(key),
        .userdata_free = freeMcpToolKey,
    };
}

test "buildMcpTool produces a record that parses back through the naming SSOT" {
    const gpa = std.testing.allocator;
    var tool = try buildMcpTool(gpa, "mock_server", "search", "Search the index", .{ .properties = &.{} }, null);
    _ = &tool;
    defer {
        gpa.free(tool.name);
        gpa.free(tool.description);
        freeMcpToolKey(gpa, tool.userdata);
    }
    const parsed = naming.parse(tool.name).?;
    try std.testing.expectEqualStrings("mock_server", parsed.server);
    try std.testing.expectEqualStrings("search", parsed.tool);
}

test "buildMcpTool deep-copies the schema so a client deinit cannot dangle it" {
    const gpa = std.testing.allocator;
    // Client-owned schema: allocated exactly like `McpTool` builds it, so
    // `source.deinit` below reproduces the disconnect-time free (it owns the
    // properties array too — do not free `props` separately).
    const props = try gpa.alloc(tools_common.Schema.Property, 1);
    const enum_values = try gpa.alloc([]const u8, 2);
    enum_values[0] = try gpa.dupe(u8, "all");
    enum_values[1] = try gpa.dupe(u8, "recent");
    props[0] = .{
        .name = try gpa.dupe(u8, "query"),
        .kind = .string,
        .description = try gpa.dupe(u8, "Search query"),
        .required = true,
        .enum_values = enum_values,
        .default_value = try gpa.dupe(u8, "\"all\""),
    };
    var source: tools_common.Schema = .{ .properties = props };
    defer source.deinit(gpa);

    const tool = try buildMcpTool(gpa, "mock_server", "search", "Search the index", source, null);
    defer {
        gpa.free(tool.name);
        gpa.free(tool.description);
        freeMcpToolKey(gpa, tool.userdata);
    }

    // The client's schema going away (disconnect) must leave the record's
    // copy fully readable — the strings differ in address, not content.
    try std.testing.expect(tool.schema.properties.ptr != source.properties.ptr);
    try std.testing.expectEqualStrings("query", tool.schema.properties[0].name);
    try std.testing.expectEqualStrings("Search query", tool.schema.properties[0].description);
    try std.testing.expectEqual(@as(usize, 2), tool.schema.properties[0].enum_values.?.len);
    try std.testing.expectEqualStrings("recent", tool.schema.properties[0].enum_values.?[1]);
}

test "buildMcpTool deep-copies the raw inputSchema so a client deinit cannot dangle it" {
    const gpa = std.testing.allocator;
    // Client-owned raw schema, allocated exactly like discovery does; freed
    // below to reproduce the disconnect-time release of the client's copy.
    const raw =
        \\{"type":"object","$defs":{"F":{"type":"object"}},"properties":{"filter":{"$ref":"#/$defs/F"}},"additionalProperties":false}
    ;
    const source_raw = try gpa.dupe(u8, raw);
    defer gpa.free(source_raw);

    const tool = try buildMcpTool(gpa, "mock_server", "search", "Search the index", .{ .properties = &.{} }, source_raw);
    defer {
        gpa.free(tool.name);
        gpa.free(tool.description);
        freeMcpToolKey(gpa, tool.userdata);
    }

    // The record's raw schema is a distinct allocation whose contents — and
    // the provider pass-through form on `Tool` — survive the client's copy
    // going away.
    try std.testing.expect(tool.raw_input_schema.?.ptr != source_raw.ptr);
    try std.testing.expectEqualStrings(raw, tool.raw_input_schema.?);
}
