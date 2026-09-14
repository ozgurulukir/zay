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
/// the record is removed. Holds copies of the server and tool names plus a
/// DEEP COPY of the tool's parameter schema, so the record never borrows
/// from a client that may disconnect: `McpTool.deinit` frees the client-side
/// schema (disconnect/reconnect keep the client in the list), and a record
/// borrowing it would dangle through every registry read and `tools_json`
/// rebuild until the (turn-gated) next sync.
pub const McpToolKey = struct {
    server_name: []u8,
    tool_name: []u8,
    schema: tools_common.Schema,
};

/// Free callback for `Tool.userdata_free`.
pub fn freeMcpToolKey(gpa: std.mem.Allocator, ud: *anyopaque) void {
    const key: *McpToolKey = @ptrCast(@alignCast(ud));
    gpa.free(key.server_name);
    gpa.free(key.tool_name);
    key.schema.deinit(gpa);
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

    const result_text = blk: {
        for (manager.clients.items) |*client| {
            if (client.status() != .connected) continue;
            if (!std.mem.eql(u8, client.name, key.server_name)) continue;
            break :blk client.callTool(io, key.tool_name, args) catch |err| {
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

/// Human display metadata for an MCP tool: the bare tool name, plus the
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
/// the registry (`userdata_free`). `name`, `description`, and the deep-copied
/// `schema` are owned and freed when the record is removed. `schema` is
/// cloned: the client may free its `McpTool.schema` on a mid-turn
/// disconnect/reconnect while this record is still alive.
pub fn buildMcpTool(
    gpa: std.mem.Allocator,
    server_name: []const u8,
    tool_name: []const u8,
    description: []const u8,
    schema: tools_common.Schema,
) !tools_common.Tool {
    const full_name = try naming.toolFullName(gpa, server_name, tool_name);
    errdefer gpa.free(full_name);
    const desc_owned = try gpa.dupe(u8, description);
    errdefer gpa.free(desc_owned);
    const key = try gpa.create(McpToolKey);
    errdefer gpa.destroy(key);
    errdefer {
        gpa.free(key.server_name);
        gpa.free(key.tool_name);
    }
    key.* = .{
        .server_name = try gpa.dupe(u8, server_name),
        .tool_name = try gpa.dupe(u8, tool_name),
        .schema = undefined,
    };
    key.schema = try schema.clone(gpa);
    return .{
        .name = full_name,
        .description = desc_owned,
        .schema = key.schema,
        .run = runMcpTool,
        .display = displayMcpTool,
        .userdata = @ptrCast(key),
        .userdata_free = freeMcpToolKey,
    };
}

test "buildMcpTool produces a record that parses back through the naming SSOT" {
    const gpa = std.testing.allocator;
    var tool = try buildMcpTool(gpa, "mock_server", "search", "Search the index", .{ .properties = &.{} });
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

    const tool = try buildMcpTool(gpa, "mock_server", "search", "Search the index", source);
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
