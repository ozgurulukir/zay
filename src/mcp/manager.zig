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

    /// Extended sync with schema discovery for local & system MCP servers.
    pub fn syncFromConfigEx(
        self: *McpManager,
        gpa: std.mem.Allocator,
        io: std.Io,
        config: *const config_mod.Config,
        home_dir: []const u8,
        cwd: []const u8,
    ) !void {
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
                if (c.tools.items.len == 0 and server_cfg.enabled) {
                    discoverToolsForClient(gpa, io, c, home_dir, cwd);
                }
            } else {
                var c = try client_mod.McpClient.init(
                    self.gpa,
                    server_cfg.name,
                    server_cfg.command,
                    server_cfg.url,
                );
                c.status = if (server_cfg.enabled) .connected else .disabled;
                if (server_cfg.enabled) {
                    discoverToolsForClient(gpa, io, &c, home_dir, cwd);
                }
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

fn discoverToolsForClient(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *client_mod.McpClient,
    home_dir: []const u8,
    cwd: []const u8,
) void {
    if (client.tools.items.len > 0) return;

    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }

    if (home_dir.len > 0) {
        if (std.fs.path.join(gpa, &.{ home_dir, ".config", "nova", "mcp", client.name })) |p| {
            paths.append(gpa, p) catch {};
        } else |_| {}
        if (std.fs.path.join(gpa, &.{ home_dir, ".nova", "mcp", client.name })) |p| {
            paths.append(gpa, p) catch {};
        } else |_| {}
    }
    if (cwd.len > 0) {
        if (std.fs.path.join(gpa, &.{ cwd, ".nova", "mcp", client.name })) |p| {
            paths.append(gpa, p) catch {};
        } else |_| {}
    }

    for (paths.items) |dir_path| {
        scanSchemaDir(gpa, io, client, dir_path) catch continue;
        if (client.tools.items.len > 0) break;
    }
}

fn scanSchemaDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *client_mod.McpClient,
    dir_path: []const u8,
) !void {
    var dir = std.Io.Dir.openDir(.cwd(), io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const file_path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        defer gpa.free(file_path);

        const bytes = std.Io.Dir.readFileAllocOptions(.cwd(), io, file_path, gpa, .limited(64 * 1024), .of(u8), 0) catch continue;
        defer gpa.free(bytes);

        parseAndAddToolSchema(gpa, client, entry.name, bytes) catch continue;
    }
}

fn parseAndAddToolSchema(
    gpa: std.mem.Allocator,
    client: *client_mod.McpClient,
    filename: []const u8,
    json_bytes: []const u8,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const obj = parsed.value.object;

    const default_name = filename[0 .. filename.len - 5];
    const tool_name: []const u8 = if (obj.get("name")) |n| (if (n == .string) n.string else default_name) else default_name;
    const description: []const u8 = if (obj.get("description")) |d| (if (d == .string) d.string else "MCP tool") else "MCP tool";

    client.addTool(tool_name, description, .{ .properties = &.{} }) catch {};
}

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
