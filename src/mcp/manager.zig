//! McpManager — Multi-server MCP supervisor and tool aggregator for Nova Agent.

const std = @import("std");
const ai = @import("../ai.zig");
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

    pub fn deinit(self: *McpManager, io: std.Io) void {
        for (self.clients.items) |*client| client.deinit(io);
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
                c.status = if (server_cfg.enabled) .connecting else .disabled;
            } else {
                var c = try client_mod.McpClient.init(
                    self.gpa,
                    server_cfg.name,
                    server_cfg.command,
                    server_cfg.args,
                    server_cfg.url,
                );
                c.status = if (server_cfg.enabled) .connecting else .disabled;
                try self.clients.append(self.gpa, c);
            }
        }
    }

    /// Extended sync: spawns subprocess, performs MCP handshake, and
    /// discovers tools via `tools/list` JSON-RPC for each enabled server.
    pub fn syncFromConfigEx(
        self: *McpManager,
        gpa: std.mem.Allocator,
        io: std.Io,
        config: *const config_mod.Config,
        home_dir: []const u8,
        cwd: []const u8,
    ) void {
        _ = gpa;
        _ = home_dir;
        _ = cwd;
        for (config.mcp_servers) |server_cfg| {
            var existing: ?*client_mod.McpClient = null;
            for (self.clients.items) |*c| {
                if (std.mem.eql(u8, c.name, server_cfg.name)) {
                    existing = c;
                    break;
                }
            }

            if (existing) |c| {
                if (!server_cfg.enabled) {
                    c.status = .disabled;
                    continue;
                }
                if (c.tools.items.len > 0) continue;
                // Re-discover: start, handshake, list tools
                connectAndDiscover(io, c) catch {
                    c.status = .failed;
                };
            } else {
                var c = client_mod.McpClient.init(
                    self.gpa,
                    server_cfg.name,
                    server_cfg.command,
                    server_cfg.args,
                    server_cfg.url,
                ) catch continue;
                c.status = if (server_cfg.enabled) .connecting else .disabled;
                if (server_cfg.enabled) {
                    connectAndDiscover(io, &c) catch {
                        c.status = .failed;
                    };
                }
                self.clients.append(self.gpa, c) catch {};
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

    /// Build an `ai.McpToolSchema` slice from all connected clients' tools.
    /// Caller owns the returned slice and must free with `gpa.free()`.
    /// Each schema's name/description strings borrow from the McpTool — the
    /// caller must keep the McpManager alive while using the result.
    pub fn buildMcpToolSchemas(self: *const McpManager, gpa: std.mem.Allocator) ![]ai.McpToolSchema {
        var total: usize = 0;
        for (self.clients.items) |c| {
            if (c.status == .connected) total += c.tools.items.len;
        }
        var schemas = try gpa.alloc(ai.McpToolSchema, total);
        var idx: usize = 0;
        for (self.clients.items) |c| {
            if (c.status != .connected) continue;
            for (c.tools.items) |tool| {
                schemas[idx] = .{
                    .name = tool.full_name,
                    .description = tool.description,
                    .schema = tool.schema,
                };
                idx += 1;
            }
        }
        return schemas;
    }

    /// Reconnect a specific client by index: stop, clear tools, and re-discover.
    pub fn reconnectClient(self: *McpManager, io: std.Io, index: usize) void {
        if (index >= self.clients.items.len) return;
        const client = &self.clients.items[index];
        client.stop(io);
        // Clear existing tools
        for (client.tools.items) |*tool| tool.deinit(self.gpa);
        client.tools.clearRetainingCapacity();
        client.error_message = null;
        client.latency_ms = 0;
        // Re-discover
        connectAndDiscover(io, client) catch {
            client.status = .failed;
        };
    }
};

/// Spawn the MCP server subprocess, perform handshake, and discover tools.
/// On any failure, the caller should set status to .failed.
fn connectAndDiscover(io: std.Io, client: *client_mod.McpClient) !void {
    // stdio transport: spawn subprocess
    if (client.command != null) {
        client.startStdio(io) catch |err| {
            client.setError("Failed to spawn: {s}", .{@errorName(err)});
            return err;
        };
    } else if (client.url != null) {
        // SSE transport — not yet implemented
        client.setError("SSE transport not yet implemented", .{});
        return error.SseNotImplemented;
    } else {
        client.setError("No command or url configured", .{});
        return error.NoTransport;
    }

    // MCP handshake
    client.initialize(io) catch |err| {
        client.setError("Handshake failed: {s}", .{@errorName(err)});
        client.stop(io);
        return err;
    };

    // Discover tools
    client.listTools(io) catch |err| {
        client.setError("Tool discovery failed: {s}", .{@errorName(err)});
        client.stop(io);
        return err;
    };
}

test "McpManager syncs servers from config and counts tools" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

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
    // syncFromConfig only registers the client — actual connection happens in syncFromConfigEx
    try std.testing.expectEqual(client_mod.ServerStatus.connecting, manager.clients.items[0].status);
    try std.testing.expectEqual(@as(usize, 0), manager.activeServerCount());
}
