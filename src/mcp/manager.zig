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

    /// Reconcile client list against config: remove stale, add new, update status.
    /// No I/O connections — pure list management. Safe to call repeatedly.
    /// Misconfigured servers (no command/url) are registered as .failed with
    /// an error message. Duplicate names are skipped with a warning.
    pub fn syncFromConfig(self: *McpManager, io: std.Io, config: *const config_mod.Config) !void {
        // Phase 1: Remove clients no longer in config (zombie cleanup)
        self.removeStaleClients(io, config);

        // Phase 2: Add new or update status of existing
        for (config.mcp_servers, 0..) |server_cfg, cfg_idx| {
            // Skip duplicate names within the same config
            var is_dup = false;
            for (config.mcp_servers[0..cfg_idx]) |prev| {
                if (std.mem.eql(u8, server_cfg.name, prev.name)) {
                    is_dup = true;
                    break;
                }
            }
            if (is_dup) {
                std.log.warn("MCP server '{s}': duplicate name in config, skipping", .{server_cfg.name});
                continue;
            }

            const has_transport = server_cfg.command != null or server_cfg.url != null;

            if (self.findClient(server_cfg.name)) |c| {
                if (!has_transport) {
                    c.status = .failed;
                    c.setError("No command or url configured", .{});
                } else if (server_cfg.enabled) {
                    if (c.status != .connected) c.status = .connecting;
                } else {
                    c.status = .disabled;
                }
            } else {
                var c = try client_mod.McpClient.init(
                    self.gpa,
                    server_cfg.name,
                    server_cfg.command,
                    server_cfg.args,
                    server_cfg.url,
                );
                errdefer c.deinit(io);
                if (!has_transport) {
                    c.status = .failed;
                    c.setError("No command or url configured", .{});
                } else {
                    c.status = if (server_cfg.enabled) .connecting else .disabled;
                }
                try self.clients.append(self.gpa, c);
            }
        }
    }

    /// Extended sync: reconcile client list, then connect enabled servers.
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
        self.syncFromConfig(io, config) catch {};
        for (self.clients.items) |*c| {
            if (c.status != .connecting) continue;
            if (c.tools.items.len > 0) continue;
            connectAndDiscover(io, c) catch {
                c.status = .failed;
            };
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
    /// Duplicate full_names (same server+tool from two sources) are skipped
    /// with a warning — first writer wins.
    pub fn buildMcpToolSchemas(self: *const McpManager, gpa: std.mem.Allocator) ![]ai.McpToolSchema {
        var total: usize = 0;
        for (self.clients.items) |c| {
            if (c.status == .connected) total += c.tools.items.len;
        }
        var schemas = try gpa.alloc(ai.McpToolSchema, total);
        var idx: usize = 0;
        next_tool: for (self.clients.items) |c| {
            if (c.status != .connected) continue;
            for (c.tools.items) |tool| {
                // Collision check: skip if a tool with this full_name was already added
                for (schemas[0..idx]) |existing| {
                    if (std.mem.eql(u8, existing.name, tool.full_name)) {
                        std.log.warn("MCP tool name collision: '{s}' — skipping duplicate", .{tool.full_name});
                        continue :next_tool;
                    }
                }
                schemas[idx] = .{
                    .name = tool.full_name,
                    .description = tool.description,
                    .schema = tool.schema,
                };
                idx += 1;
            }
        }
        // Trim unused tail if duplicates were skipped
        return gpa.realloc(schemas, idx);
    }

    /// Brief one-line summary of connected servers and tool counts.
    /// Caller owns the returned slice.
    pub fn serverSummary(self: *const McpManager, gpa: std.mem.Allocator) ![]u8 {
        if (self.activeServerCount() == 0) return gpa.dupe(u8, "");

        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try out.writer.writeAll("Connected MCP servers: ");
        var first = true;
        for (self.clients.items) |c| {
            if (c.status != .connected) continue;
            if (!first) try out.writer.writeAll(", ");
            first = false;
            try out.writer.print("{s} ({d} tools)", .{ c.name, c.tools.items.len });
        }
        return out.toOwnedSlice();
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

    fn findClient(self: *McpManager, name: []const u8) ?*client_mod.McpClient {
        for (self.clients.items) |*c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    /// Remove clients that are no longer in config. Iterates backwards so
    /// orderedRemove indices stay valid. Deinits the client (kills subprocess).
    fn removeStaleClients(self: *McpManager, io: std.Io, config: *const config_mod.Config) void {
        var i: usize = self.clients.items.len;
        while (i > 0) {
            i -= 1;
            const client = &self.clients.items[i];
            var found = false;
            for (config.mcp_servers) |server_cfg| {
                if (std.mem.eql(u8, client.name, server_cfg.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                client.deinit(io);
                _ = self.clients.orderedRemove(i);
            }
        }
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

    try manager.syncFromConfig(std.testing.io, &cfg);
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items.len);
    // syncFromConfig only registers the client — actual connection happens in syncFromConfigEx
    try std.testing.expectEqual(client_mod.ServerStatus.connecting, manager.clients.items[0].status);
    try std.testing.expectEqual(@as(usize, 0), manager.activeServerCount());
}

test "McpManager removes stale clients not in config" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    // First sync: add two servers
    var servers1 = try gpa.alloc(config_mod.McpServerConfig, 2);
    servers1[0] = .{ .name = try gpa.dupe(u8, "alpha"), .enabled = true };
    servers1[1] = .{ .name = try gpa.dupe(u8, "beta"), .enabled = true };
    var cfg1: config_mod.Config = .{ .mcp_servers = servers1 };
    defer cfg1.deinit(gpa);

    try manager.syncFromConfig(std.testing.io, &cfg1);
    try std.testing.expectEqual(@as(usize, 2), manager.clients.items.len);

    // Second sync: only "alpha" remains — "beta" should be removed
    var servers2 = try gpa.alloc(config_mod.McpServerConfig, 1);
    servers2[0] = .{ .name = try gpa.dupe(u8, "alpha"), .enabled = true };
    var cfg2: config_mod.Config = .{ .mcp_servers = servers2 };
    defer cfg2.deinit(gpa);

    try manager.syncFromConfig(std.testing.io, &cfg2);
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items.len);
    try std.testing.expectEqualStrings("alpha", manager.clients.items[0].name);
}

test "McpManager does not reconnect already connected clients" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    var servers = try gpa.alloc(config_mod.McpServerConfig, 1);
    servers[0] = .{
        .name = try gpa.dupe(u8, "stable"),
        .command = try gpa.dupe(u8, "echo"),
        .enabled = true,
    };
    var cfg: config_mod.Config = .{ .mcp_servers = servers };
    defer cfg.deinit(gpa);

    // First sync: registers as .connecting
    try manager.syncFromConfig(std.testing.io, &cfg);
    try std.testing.expectEqual(client_mod.ServerStatus.connecting, manager.clients.items[0].status);

    // Simulate a successful connection
    manager.clients.items[0].status = .connected;

    // Second sync: should NOT change status of already-connected client
    try manager.syncFromConfig(std.testing.io, &cfg);
    try std.testing.expectEqual(client_mod.ServerStatus.connected, manager.clients.items[0].status);
}

test "McpManager marks misconfigured servers as failed" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    // Server with no command and no url
    var servers = try gpa.alloc(config_mod.McpServerConfig, 1);
    servers[0] = .{ .name = try gpa.dupe(u8, "broken"), .enabled = true };
    var cfg: config_mod.Config = .{ .mcp_servers = servers };
    defer cfg.deinit(gpa);

    try manager.syncFromConfig(std.testing.io, &cfg);
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items.len);
    try std.testing.expectEqual(client_mod.ServerStatus.failed, manager.clients.items[0].status);
    try std.testing.expect(manager.clients.items[0].error_message != null);
    try std.testing.expectEqualStrings("No command or url configured", manager.clients.items[0].error_message.?);
}

test "McpManager skips duplicate server names in config" {
    const gpa = std.testing.allocator;
    var manager = McpManager.init(gpa);
    defer manager.deinit(std.testing.io);

    var servers = try gpa.alloc(config_mod.McpServerConfig, 2);
    servers[0] = .{
        .name = try gpa.dupe(u8, "dup"),
        .command = try gpa.dupe(u8, "echo"),
        .enabled = true,
    };
    servers[1] = .{
        .name = try gpa.dupe(u8, "dup"),
        .command = try gpa.dupe(u8, "cat"),
        .enabled = true,
    };
    var cfg: config_mod.Config = .{ .mcp_servers = servers };
    defer cfg.deinit(gpa);

    try manager.syncFromConfig(std.testing.io, &cfg);
    // Only the first "dup" should be registered
    try std.testing.expectEqual(@as(usize, 1), manager.clients.items.len);
    try std.testing.expectEqualStrings("echo", manager.clients.items[0].command.?);
}
