//! Model Context Protocol (MCP) Client.
//! Implements protocol state machine, tool discovery, execution, and health monitoring.

const std = @import("std");
const ai = @import("../ai.zig");
const tools_common = @import("../tools/common.zig");
const transport = @import("transport.zig");

const assert = std.debug.assert;

pub const ServerStatus = enum {
    connecting,
    connected,
    failed,
    disabled,

    pub fn label(self: ServerStatus) []const u8 {
        return switch (self) {
            .connecting => "CONNECTING",
            .connected => "CONNECTED",
            .failed => "FAILED",
            .disabled => "DISABLED",
        };
    }
};

pub const McpTool = struct {
    server_name: []u8,
    name: []u8,
    full_name: []u8,
    description: []u8,
    schema: tools_common.Schema,

    pub fn deinit(self: *McpTool, gpa: std.mem.Allocator) void {
        gpa.free(self.server_name);
        gpa.free(self.name);
        gpa.free(self.full_name);
        gpa.free(self.description);
        self.* = undefined;
    }
};

pub const McpClient = struct {
    gpa: std.mem.Allocator,
    name: []u8,
    command: ?[]u8 = null,
    url: ?[]u8 = null,
    status: ServerStatus = .disabled,
    latency_ms: u32 = 0,
    tools: std.ArrayList(McpTool) = .empty,
    next_request_id: i64 = 1,

    pub fn init(gpa: std.mem.Allocator, name: []const u8, command: ?[]const u8, url: ?[]const u8) !McpClient {
        return .{
            .gpa = gpa,
            .name = try gpa.dupe(u8, name),
            .command = if (command) |c| try gpa.dupe(u8, c) else null,
            .url = if (url) |u| try gpa.dupe(u8, u) else null,
            .status = .disabled,
        };
    }

    pub fn deinit(self: *McpClient) void {
        self.gpa.free(self.name);
        if (self.command) |c| self.gpa.free(c);
        if (self.url) |u| self.gpa.free(u);
        for (self.tools.items) |*tool| tool.deinit(self.gpa);
        self.tools.deinit(self.gpa);
        self.* = undefined;
    }

    /// Register a mock or discovered tool for testing / dynamic loading.
    pub fn addTool(
        self: *McpClient,
        tool_name: []const u8,
        description: []const u8,
        schema: tools_common.Schema,
    ) !void {
        const full_name = try std.fmt.allocPrint(self.gpa, "mcp__{s}__{s}", .{ self.name, tool_name });
        errdefer self.gpa.free(full_name);

        try self.tools.append(self.gpa, .{
            .server_name = try self.gpa.dupe(u8, self.name),
            .name = try self.gpa.dupe(u8, tool_name),
            .full_name = full_name,
            .description = try self.gpa.dupe(u8, description),
            .schema = schema,
        });
    }
};

test "McpClient initializes and formats namespaced tool names" {
    const gpa = std.testing.allocator;
    var client = try McpClient.init(gpa, "memory", "npx", null);
    defer client.deinit();

    client.status = .connected;
    try client.addTool("create_entities", "Create entities in graph", .{ .properties = &.{} });

    try std.testing.expectEqualStrings("memory", client.name);
    try std.testing.expectEqual(ServerStatus.connected, client.status);
    try std.testing.expectEqual(@as(usize, 1), client.tools.items.len);
    try std.testing.expectEqualStrings("mcp__memory__create_entities", client.tools.items[0].full_name);
}
