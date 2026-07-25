const std = @import("std");
const ai = @import("../ai.zig");
const core = @import("responses_core.zig");

pub const Client = struct {
    core_client: core.Client,

    pub fn init(target: *Client, gpa: std.mem.Allocator, io: std.Io, config: ai.Config) !void {
        try target.core_client.init(gpa, io, config, .{});
    }

    pub fn deinit(self: *Client) void {
        self.core_client.deinit();
        self.* = undefined;
    }

    /// Rebuild the serialized tool definitions after the MCP tool set changes.
    pub fn updateMcpTools(self: *Client, mcp_tools: []const ai.McpToolSchema) !void {
        try self.core_client.updateMcpTools(mcp_tools);
    }

    pub fn prompt(self: *Client, messages: []const ai.ChatMessage, observer: anytype) !ai.Turn {
        return self.core_client.prompt(messages, observer);
    }
};

test {
    std.testing.refAllDecls(@This());
}
