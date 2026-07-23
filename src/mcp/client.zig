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
        for (self.schema.properties) |*prop| {
            gpa.free(prop.name);
            gpa.free(prop.description);
        }
        if (self.schema.properties.len > 0) gpa.free(self.schema.properties);
        self.* = undefined;
    }
};

pub const McpClient = struct {
    gpa: std.mem.Allocator,
    name: []u8,
    /// The static transport configuration. Variants make illegal
    /// combinations unrepresentable: a stdio client always has
    /// command+args, an sse client always has a url.
    transport: union(enum) {
        stdio: struct {
            command: []u8,
            args: [][]u8,
        },
        sse: struct {
            url: []u8,
        },
    },
    /// Runtime lifecycle. Variants make illegal combinations
    /// unrepresentable: only stdio can have a `process`, only failed
    /// has a reason, only disabled/connecting/ready are valid for the
    /// inner status.
    lifecycle: union(enum) {
        disabled,
        stdio: struct {
            process: std.process.Child,
            status: enum { connecting, ready },
        },
        sse: struct {
            status: enum { connecting, ready },
        },
        failed: struct {
            reason: []u8,
        },
    },
    latency_ms: u32 = 0,
    tools: std.ArrayList(McpTool) = .empty,
    next_request_id: i64 = 1,
    /// Serializes JSON-RPC requests — stdin/stdout pipes can't handle
    /// concurrent requests. Defensive for future parallel tool execution.
    request_mutex: std.Io.Mutex = .init,
    /// Read timeout for sendRequest poll, in milliseconds.
    read_timeout_ms: u32 = 30_000,

    pub fn init(gpa: std.mem.Allocator, name: []const u8, command: ?[]const u8, args: []const []const u8, url: ?[]const u8) !McpClient {
        // Legacy init: if url is set, build an sse client; otherwise stdio.
        // The caller picks the transport via the (command, url) pair.
        if (url) |u| {
            if (command != null) return error.AmbiguousTransport;
            return initSse(gpa, name, u);
        }
        const cmd = command orelse return error.NoTransport;
        return initStdio(gpa, name, cmd, args);
    }

    /// Internal: build a McpClient from explicit stdio parameters. The
    /// manager now constructs Transport unions directly via this path.
    pub fn initStdio(gpa: std.mem.Allocator, name: []const u8, command: []const u8, args: []const []const u8) !McpClient {
        var owned_args = try gpa.alloc([]u8, args.len);
        errdefer {
            for (owned_args) |a| gpa.free(a);
            gpa.free(owned_args);
        }
        for (args, 0..) |arg, i| {
            owned_args[i] = try gpa.dupe(u8, arg);
        }
        return .{
            .gpa = gpa,
            .name = try gpa.dupe(u8, name),
            .transport = .{
                .stdio = .{
                    .command = try gpa.dupe(u8, command),
                    .args = owned_args,
                },
            },
            .lifecycle = .disabled,
        };
    }

    pub fn initSse(gpa: std.mem.Allocator, name: []const u8, url: []const u8) !McpClient {
        return .{
            .gpa = gpa,
            .name = try gpa.dupe(u8, name),
            .transport = .{ .sse = .{ .url = try gpa.dupe(u8, url) } },
            .lifecycle = .disabled,
        };
    }

    /// Map the lifecycle union to the public `ServerStatus` enum. The
    /// union is the canonical state; this is the legacy API surface
    /// for callers (manager, TUI) that read the status field.
    pub fn status(self: *const McpClient) ServerStatus {
        return switch (self.lifecycle) {
            .disabled => .disabled,
            .stdio => |s| switch (s.status) {
                .connecting => .connecting,
                .ready => .connected,
            },
            .sse => |s| switch (s.status) {
                .connecting => .connecting,
                .ready => .connected,
            },
            .failed => .failed,
        };
    }

    /// Move the lifecycle to connecting (preserves any existing
    /// stdio process handle or sse url). Used by the manager after
    /// syncFromConfig to mark a previously-disabled client as
    /// about-to-connect.
    pub fn markConnecting(self: *McpClient) void {
        switch (self.lifecycle) {
            .stdio => |*s| s.status = .connecting,
            .sse => |*s| s.status = .connecting,
            .disabled => {
                self.lifecycle = switch (self.transport) {
                    .stdio => .{ .stdio = .{
                        .process = std.mem.zeroes(std.process.Child),
                        .status = .connecting,
                    } },
                    .sse => .{ .sse = .{ .status = .connecting } },
                };
            },
            .failed => {
                self.gpa.free(self.lifecycle.failed.reason);
                self.lifecycle = switch (self.transport) {
                    .stdio => .{ .stdio = .{
                        .process = std.mem.zeroes(std.process.Child),
                        .status = .connecting,
                    } },
                    .sse => .{ .sse = .{ .status = .connecting } },
                };
            },
        }
    }

    pub fn deinit(self: *McpClient, io: std.Io) void {
        self.stop(io);
        self.gpa.free(self.name);
        switch (self.transport) {
            .stdio => |t| {
                self.gpa.free(t.command);
                for (t.args) |arg| self.gpa.free(arg);
                if (t.args.len > 0) self.gpa.free(t.args);
            },
            .sse => |t| self.gpa.free(t.url),
        }
        switch (self.lifecycle) {
            .failed => |f| self.gpa.free(f.reason),
            else => {},
        }
        for (self.tools.items) |*tool| tool.deinit(self.gpa);
        self.tools.deinit(self.gpa);
        self.* = undefined;
    }

    /// Set the lifecycle to failed (or replace the existing reason).
    pub fn setError(self: *McpClient, comptime fmt: []const u8, args: anytype) void {
        if (self.lifecycle == .failed) self.gpa.free(self.lifecycle.failed.reason);
        const reason = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        self.lifecycle = .{ .failed = .{ .reason = reason } };
    }

    /// Spawn the MCP server subprocess (stdio transport).
    /// Sets up stdin/stdout pipes for JSON-RPC communication.
    pub fn startStdio(self: *McpClient, io: std.Io) !void {
        const t = switch (self.transport) {
            .stdio => |t| t,
            .sse => return error.NoStdioTransport,
        };
        // Build argv: command + args
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.append(self.gpa, t.command);
        for (t.args) |arg| try argv.append(self.gpa, arg);

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer child.kill(io);

        self.lifecycle = .{
            .stdio = .{
                .process = child,
                .status = .connecting,
            },
        };
    }

    /// Stop the subprocess: SIGTERM first, then SIGKILL via kill().
    /// Closes stdin/stdout pipes and reaps the child.
    pub fn stop(self: *McpClient, io: std.Io) void {
        if (self.lifecycle == .stdio) {
            var child = self.lifecycle.stdio.process;
            // Close stdin so the child sees EOF and can exit gracefully.
            if (child.stdin) |*stdin_file| {
                stdin_file.close(io);
                child.stdin = null;
            }
            if (child.stdout) |*stdout_file| {
                stdout_file.close(io);
                child.stdout = null;
            }
            // SIGTERM first — gives well-behaved servers a chance to clean up.
            // kill() below sends SIGKILL and reaps the zombie regardless.
            if (child.id) |pid| {
                std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch {};
            }
            child.kill(io);
        }
        self.lifecycle = .disabled;
    }

    /// Send a JSON-RPC request and read the response line.
    /// Returns the raw response line (owned, caller must free).
    /// Blocks up to `read_timeout_ms` waiting for a response.
    /// Serialized via request_mutex — concurrent calls queue, not interleave.
    pub fn sendRequest(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) ![]u8 {
        const child = if (self.lifecycle == .stdio) &self.lifecycle.stdio.process else return error.NotConnected;
        const stdin_file = child.stdin orelse return error.NotConnected;
        const stdout_file = child.stdout orelse return error.NotConnected;

        // Serialize requests: stdin/stdout pipes can't handle concurrent I/O.
        try self.request_mutex.lock(io);
        defer self.request_mutex.unlock(io);

        const id = self.next_request_id;
        self.next_request_id += 1;

        const request = try transport.formatRequest(self.gpa, id, method, params_json);
        defer self.gpa.free(request);

        try stdin_file.writeStreamingAll(io, request);

        // Wait for data on stdout with a timeout to prevent infinite hangs.
        var poll_fds: [1]std.posix.pollfd = .{
            .{ .fd = stdout_file.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&poll_fds, @intCast(self.read_timeout_ms)) catch return error.ReadFailed;
        if (ready == 0) return error.Timeout;
        // Server exited with no data — only crash when POLLIN is NOT set.
        // When both POLLIN and HUP are set, the pipe has buffered data from
        // a just-exited server that we still need to read.
        if (poll_fds[0].revents & std.posix.POLL.IN == 0 and
            poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0)
        {
            return error.McpServerCrashed;
        }

        // Read one line from stdout (newline-delimited JSON-RPC).
        // line_writer grows dynamically — response size is unbounded.
        var buf: [64 * 1024]u8 = undefined;
        var reader = stdout_file.reader(io, &buf);
        var line_writer: std.Io.Writer.Allocating = .init(self.gpa);
        defer line_writer.deinit();
        _ = reader.interface.streamDelimiterEnding(&line_writer.writer, '\n') catch |err| switch (err) {
            // Server closed the pipe mid-response
            error.ReadFailed => return error.McpServerCrashed,
            error.WriteFailed => return error.OutOfMemory,
        };
        // Consume the delimiter
        _ = reader.interface.take(1) catch {};
        return line_writer.toOwnedSlice();
    }

    /// Send a JSON-RPC notification (no response expected).
    pub fn sendNotification(self: *McpClient, io: std.Io, method: []const u8, params_json: ?[]const u8) !void {
        const child = if (self.lifecycle == .stdio) &self.lifecycle.stdio.process else return error.NotConnected;
        const stdin_file = child.stdin orelse return error.NotConnected;

        const request = try transport.formatNotification(self.gpa, method, params_json);
        defer self.gpa.free(request);

        try stdin_file.writeStreamingAll(io, request);
    }

    /// Parse a JSON-RPC response line and extract the `result` value.
    /// Returns null when the response contains an error.
    /// Caller owns the returned value and must free with `parsed.deinit()`.
    fn parseResponse(gpa: std.mem.Allocator, response: []const u8) !?std.json.Parsed(std.json.Value) {
        const trimmed = std.mem.trim(u8, response, " \t\r\n");
        if (trimmed.len == 0) return null;

        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{});
        errdefer parsed.deinit();

        if (parsed.value != .object) return null;
        const obj = parsed.value.object;

        // Check for error
        if (obj.get("error")) |err_val| {
            if (err_val == .object) {
                const code = if (err_val.object.get("code")) |c| (if (c == .integer) c.integer else 0) else 0;
                const message = if (err_val.object.get("message")) |m| (if (m == .string) m.string else "unknown error") else "unknown error";
                std.log.warn("MCP JSON-RPC error (code {d}): {s}", .{ code, message });
            }
            return null;
        }

        _ = obj.get("result") orelse return null;
        return parsed;
    }

    /// Perform the MCP initialize handshake.
    /// On success, sets status to .connected and records latency.
    pub fn initialize(self: *McpClient, io: std.Io) !void {
        const start = std.Io.Timestamp.now(io, .awake);

        const response = try self.sendRequest(io, "initialize",
            \\{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"nova","version":"1.0"}}
        );
        defer self.gpa.free(response);

        const parsed = try parseResponse(self.gpa, response);
        if (parsed) |p| {
            defer p.deinit();
            _ = p.value.object.get("result");
        } else {
            self.setError("handshake returned no result", .{});
            return error.McpHandshakeFailed;
        }

        // Send initialized notification
        try self.sendNotification(io, "notifications/initialized", null);

        const end = std.Io.Timestamp.now(io, .awake);
        const elapsed_ns = start.durationTo(end).nanoseconds;
        self.latency_ms = @intCast(@max(elapsed_ns, 0) / std.time.ns_per_ms);
        // Mark the active transport as ready.
        switch (self.lifecycle) {
            .stdio => |*s| s.status = .ready,
            .sse => |*s| s.status = .ready,
            else => {},
        }
    }

    /// Query tools/list and populate the client's tool list.
    pub fn listTools(self: *McpClient, io: std.Io) !void {
        const response = try self.sendRequest(io, "tools/list", null);
        defer self.gpa.free(response);

        const parsed = try parseResponse(self.gpa, response) orelse return;
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return;
        if (result != .object) return;

        const tools_val = result.object.get("tools") orelse return;
        if (tools_val != .array) return;

        for (tools_val.array.items) |tool_val| {
            if (tool_val != .object) continue;
            const obj = tool_val.object;

            const tool_name = if (obj.get("name")) |n| (if (n == .string) n.string else continue) else continue;
            const description = if (obj.get("description")) |d| (if (d == .string) d.string else "") else "";
            const schema = if (obj.get("inputSchema")) |s| (try schemaFromJsonSchema(self.gpa, s)) else tools_common.Schema{ .properties = &.{} };

            try self.addTool(tool_name, description, schema);
        }
    }

    /// Call a tool via `tools/call` JSON-RPC.
    /// Returns the text content from the tool response (owned, caller must free).
    /// JSON-RPC errors and `isError: true` both return the server's message
    /// as text (not a Zig error) so the model can read what went wrong.
    pub fn callTool(self: *McpClient, io: std.Io, tool_name: []const u8, arguments_json: []const u8) ![]u8 {
        // Build params JSON with proper escaping for tool_name
        var pw: std.Io.Writer.Allocating = .init(self.gpa);
        defer pw.deinit();
        try pw.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(tool_name, .{}, &pw.writer);
        try pw.writer.writeAll(",\"arguments\":");
        try pw.writer.writeAll(arguments_json);
        try pw.writer.writeAll("}");
        const params = try pw.toOwnedSlice();
        defer self.gpa.free(params);

        const response = try self.sendRequest(io, "tools/call", params);
        defer self.gpa.free(response);

        // Parse response inline to handle JSON-RPC errors with full context
        const trimmed = std.mem.trim(u8, response, " \t\r\n");
        if (trimmed.len == 0) return error.McpToolCallFailed;

        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, trimmed, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.McpToolCallFailed;
        const obj = parsed.value.object;

        // JSON-RPC error — return the server's error message as text
        if (obj.get("error")) |err_val| {
            if (err_val == .object) {
                const msg = if (err_val.object.get("message")) |m|
                    (if (m == .string) m.string else "unknown error")
                else
                    "unknown error";
                const code = if (err_val.object.get("code")) |c|
                    (if (c == .integer) c.integer else 0)
                else
                    0;
                std.log.warn("MCP tool '{s}' JSON-RPC error (code {d}): {s}", .{ tool_name, code, msg });
                return self.gpa.dupe(u8, msg);
            }
            return error.McpToolCallFailed;
        }

        const result = obj.get("result") orelse return error.McpToolCallFailed;
        if (result != .object) return error.McpToolCallFailed;

        // Log server-side errors but still return the text content so the
        // model can read the server's error description (per MCP spec).
        if (result.object.get("isError")) |is_err| {
            if (is_err == .bool and is_err.bool) {
                std.log.warn("MCP tool '{s}' returned isError: true", .{tool_name});
            }
        }

        return extractContentText(self.gpa, result);
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

/// Extract text content from a tools/call result.
/// Non-text content types (image, resource) produce descriptive placeholders
/// so the model is aware they exist even though it can't consume binary data.
fn extractContentText(gpa: std.mem.Allocator, result: std.json.Value) ![]u8 {
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
/// Handles `properties`, `required`, `type`, `description`, and `enum`.
/// Unsupported features ($ref, oneOf, anyOf, allOf) log a warning and
/// fall back to string kind so the tool is still callable.
fn schemaFromJsonSchema(gpa: std.mem.Allocator, value: std.json.Value) !tools_common.Schema {
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
    errdefer props.deinit(gpa);

    var iter = properties_val.object.iterator();
    while (iter.next()) |entry| {
        const prop_name = entry.key_ptr.*;
        const prop_val = entry.value_ptr.*;
        if (prop_val != .object) continue;
        const prop_obj = prop_val.object;

        // Determine kind — handle unsupported composition keywords gracefully
        const kind = blk: {
            if (prop_obj.get("$ref") != null) {
                std.log.warn("MCP schema: $ref unsupported for '{s}', using string", .{prop_name});
                break :blk tools_common.Schema.Kind.string;
            }
            if (prop_obj.get("oneOf") != null or prop_obj.get("anyOf") != null) {
                std.log.warn("MCP schema: oneOf/anyOf unsupported for '{s}', using string", .{prop_name});
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

        const desc_owned = if (prop_obj.get("enum")) |enum_val| blk: {
            if (enum_val != .array or enum_val.array.items.len == 0) break :blk try gpa.dupe(u8, base_desc);
            var dw: std.Io.Writer.Allocating = .init(gpa);
            errdefer dw.deinit();
            try dw.writer.writeAll(base_desc);
            if (base_desc.len > 0) try dw.writer.writeAll(" ");
            try dw.writer.writeAll("[enum: ");
            for (enum_val.array.items, 0..) |ev, ei| {
                if (ei > 0) try dw.writer.writeAll(", ");
                switch (ev) {
                    .string => |s| try dw.writer.writeAll(s),
                    .integer => |n| try dw.writer.print("{d}", .{n}),
                    else => try dw.writer.writeAll("?"),
                }
            }
            try dw.writer.writeAll("]");
            break :blk try dw.toOwnedSlice();
        } else try gpa.dupe(u8, base_desc);

        try props.append(gpa, .{
            .name = try gpa.dupe(u8, prop_name),
            .kind = kind,
            .description = desc_owned,
            .required = required_set.contains(prop_name),
        });
    }

    return .{ .properties = try props.toOwnedSlice(gpa) };
}

fn kindFromString(kind: []const u8) tools_common.Schema.Kind {
    if (std.mem.eql(u8, kind, "integer")) return .integer;
    if (std.mem.eql(u8, kind, "number")) return .number;
    if (std.mem.eql(u8, kind, "object")) return .object;
    if (std.mem.eql(u8, kind, "array")) return .array;
    if (std.mem.eql(u8, kind, "boolean")) return .boolean;
    return .string;
}

test "McpClient initializes and formats namespaced tool names" {
    const gpa = std.testing.allocator;
    var client = try McpClient.init(gpa, "memory", "npx", &.{}, null);
    defer client.deinit(std.testing.io);

    client.lifecycle = .{
        .stdio = .{
            .process = std.mem.zeroes(std.process.Child),
            .status = .ready,
        },
    };
    try client.addTool("create_entities", "Create entities in graph", .{ .properties = &.{} });

    try std.testing.expectEqualStrings("memory", client.name);
    try std.testing.expectEqual(ServerStatus.connected, client.status());
    try std.testing.expectEqual(@as(usize, 1), client.tools.items.len);
    try std.testing.expectEqualStrings("mcp__memory__create_entities", client.tools.items[0].full_name);
}

test "McpClient startStdio + stop lifecycle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Spawn a simple echo server that reads one line and echoes it back.
    var client = try McpClient.init(gpa, "echo-test", "bash", &.{
        "-c",
        "read line; echo \"$line\"",
    }, null);
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    try std.testing.expect(client.lifecycle == .stdio);
    try std.testing.expectEqual(ServerStatus.connecting, client.status());
}

test "McpClient sendRequest round-trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Bash one-liner: read one line from stdin, echo a fixed JSON-RPC response.
    var client = try McpClient.init(gpa, "echo-test", "bash", &.{
        "-c",
        "read line; echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\"}}'",
    }, null);
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    const response = try client.sendRequest(io, "initialize", "{\"protocolVersion\":\"2024-11-05\"}");
    defer gpa.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"protocolVersion\"") != null);
}

test "McpClient full handshake + tools/list" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Mock MCP server that handles initialize + initialized + tools/list.
    // Protocol: read initialize → respond → read initialized (ignore) → read tools/list → respond.
    var client = try McpClient.init(gpa, "mock-server", "bash", &.{
        "-c",
        \\read line
        \\echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"mock","version":"1.0"},"capabilities":{"tools":{}}}}'
        \\read line
        \\read line
        \\echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"greet","description":"Say hello","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Name to greet"}},"required":["name"]}}]}}'
    }, null);
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    // Handshake
    try client.initialize(io);
    try std.testing.expectEqual(ServerStatus.connected, client.status());

    // Tool discovery
    try client.listTools(io);
    try std.testing.expectEqual(@as(usize, 1), client.tools.items.len);
    try std.testing.expectEqualStrings("mcp__mock-server__greet", client.tools.items[0].full_name);
    try std.testing.expectEqualStrings("greet", client.tools.items[0].name);
    try std.testing.expectEqualStrings("Say hello", client.tools.items[0].description);
    try std.testing.expectEqual(@as(usize, 1), client.tools.items[0].schema.properties.len);
    try std.testing.expectEqualStrings("name", client.tools.items[0].schema.properties[0].name);
    try std.testing.expectEqual(tools_common.Schema.Kind.string, client.tools.items[0].schema.properties[0].kind);
    try std.testing.expect(client.tools.items[0].schema.properties[0].required);
}

test "McpClient callTool round-trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Mock MCP server: initialize → tools/list → tools/call → respond with text content.
    var client = try McpClient.init(gpa, "mock-server", "bash", &.{
        "-c",
        \\read line
        \\echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"mock","version":"1.0"},"capabilities":{"tools":{}}}}'
        \\read line
        \\read line
        \\echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"greet","description":"Say hello","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Name to greet"}},"required":["name"]}}]}}'
        \\read line
        \\echo '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"Hello, World!"}]}}'
    }, null);
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    // Handshake + discovery
    try client.initialize(io);
    try client.listTools(io);
    try std.testing.expectEqual(@as(usize, 1), client.tools.items.len);

    // Call the tool
    const result = try client.callTool(io, "greet", "{\"name\":\"World\"}");
    defer gpa.free(result);

    try std.testing.expectEqualStrings("Hello, World!", result);
}

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

    const schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer {
        for (schema.properties) |*prop| {
            gpa.free(prop.name);
            gpa.free(prop.description);
        }
        if (schema.properties.len > 0) gpa.free(schema.properties);
    }

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

test "schemaFromJsonSchema appends enum values to description" {
    const gpa = std.testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{
        \\  "color":{"type":"string","description":"Color choice","enum":["red","green","blue"]}
        \\}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();

    const schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer {
        for (schema.properties) |*prop| {
            gpa.free(prop.name);
            gpa.free(prop.description);
        }
        if (schema.properties.len > 0) gpa.free(schema.properties);
    }

    try std.testing.expectEqual(@as(usize, 1), schema.properties.len);
    try std.testing.expect(std.mem.indexOf(u8, schema.properties[0].description, "[enum: red, green, blue]") != null);
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

    const schema = try schemaFromJsonSchema(gpa, parsed.value);
    defer {
        for (schema.properties) |*prop| {
            gpa.free(prop.name);
            gpa.free(prop.description);
        }
        if (schema.properties.len > 0) gpa.free(schema.properties);
    }

    try std.testing.expectEqual(@as(usize, 2), schema.properties.len);
    for (schema.properties) |prop| {
        try std.testing.expectEqual(tools_common.Schema.Kind.string, prop.kind);
    }
}
