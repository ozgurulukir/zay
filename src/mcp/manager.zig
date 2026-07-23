//! McpManager — Multi-server MCP supervisor and tool aggregator for Nova Agent.

const std = @import("std");
const config_mod = @import("../config.zig");
const tools_common = @import("../tools/common.zig");
const client_mod = @import("client.zig");

const assert = std.debug.assert;

pub const McpManager = struct {
    gpa: std.mem.Allocator,
    clients: std.ArrayList(client_mod.McpClient) = .empty,

    pub fn init(gpa: std.mem.Allocator) McpManager {
        return .{
            .gpa = gpa,
            .clients = .empty,
        };
    }

    pub fn deinit(self: *McpManager) void {
        for (self.clients.items) |*client| client.deinit();
        self.clients.deinit(self.gpa);
        self.* = undefined;
    }

    /// Synchronize MCP manager state against loaded Config.
    pub fn syncFromConfig(self: *McpManager, config: *const config_mod.Config) !void {
        for (config.mcp_servers) |server_cfg| {
            var existing: ?*client_mod.McpClient = null;
            for (self.clients.items) |*c| {
                if (std.mem.eql(u8, c.name, server_cfg.name)) {
                    existing = c;
                    break;
                }
            }

            if (existing) |c| {
                c.status = if (server_cfg.enabled) .connected else .disabled;
            } else {
                var c = try client_mod.McpClient.init(
                    self.gpa,
                    server_cfg.name,
                    server_cfg.command,
                    server_cfg.url,
                );
                c.status = if (server_cfg.enabled) .connected else .disabled;
                try self.clients.append(self.gpa, c);
            }
        }
    }

    /// Count total active tools across all connected MCP servers.
    pub fn totalActiveTools(self: *const McpManager) usize {
        var count: usize = 0;
        for (self.clients.items) |c| {
            if (c.status == .connected) {
                count += c.tools.items.len;
            }
        }
        return count;
    }

    /// Count total connected servers.
    pub fn activeServerCount(self: *const McpManager) usize {
        var count: usize = 0;
        for (self.clients.items) |c| {
            if (c.status == .connected) count += 1;
        }
        return count;
    }
};

test "McpManager syncs servers from config and counts tools" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit();

    var servers = try gpa.alloc(config_mod.McpServerConfig, 1);
    servers[0] = .{
        .name = try gpa.dupe(u8, "memory"),
        .command = try gpa.dupe(u8, "npx"),
        .enabled = true,
    };
    var cfg: config_mod.Config = .{ .mcp_servers = servers };
    defer cfg.deinit(gpa);

    try manager.syncFromConfig(&cfg);
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items.len);
    try std.testing.expectEqual(client_mod.ServerStatus.connected, manager.clients.items[0].status);
    try std.testing.expectEqual(@as(usize, 1), manager.activeServerCount());
}
