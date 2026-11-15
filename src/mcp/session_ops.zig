//! MCP client session-ops spoke, extracted from mcp/client.zig (issue #367
//! slice 12). Owns the session protocol above the wire: the `initialize`
//! handshake (protocol negotiation, serverInfo capture, the
//! `tools.listChanged` capability bit), `tools/list` discovery requests
//! (`listTools` replace-cache / `listToolsFresh` fetch-only), and
//! `tools/call`. This completes the client.zig split started by
//! lifecycle.zig (slice 11): what remains in client.zig is the struct, the
//! delegates, and the discovery/wire dispatch.
//!
//! The `McpClient` TYPE and all of its state stay in client.zig; this file
//! imports client.zig only for the type and the test fixture. Spoke pattern
//! (mcp/wire.zig, mcp/lifecycle.zig): free functions over `*McpClient`;
//! mutual import terminates at the type level; client.zig keeps
//! unchanged-signature method delegates for the externally-called surface
//! (manager.zig calls `listToolsFresh` directly, wire.zig drives the rest
//! through the client facade in its tests). Log scope stays `.mcp`,
//! identical to client.zig.

const std = @import("std");
const log = std.log.scoped(.mcp);
const schema_mod = @import("schema.zig");
const discovery_mod = @import("discovery.zig");
const tools_common = @import("../tools/common.zig");
const client_mod = @import("client.zig");

const McpClient = client_mod.McpClient;

// MCP protocol version strings (spec-mandated — the server echoes one back
// during `initialize` negotiation, so these values can never change).
const protocol_version_stdio = "2024-11-05";
const protocol_version_streamable_http = "2025-03-26";

/// Perform the MCP initialize handshake.
/// On success, sets status to .connected, records latency, and captures
/// the server's reported protocol version, serverInfo, and the
/// `tools.listChanged` capability flag (for `notifications/tools/list_changed`
/// subscription). Zay is a client only — it advertises no client
/// capabilities (no sampling, no roots, no elicitation server-side).
pub fn initialize(self: *McpClient, io: std.Io) !void {
    const start = std.Io.Timestamp.now(io, .awake);

    // Streamable HTTP requires protocol 2025-03-26+; stdio keeps the
    // original version so existing local servers are unaffected.
    const protocol_version: []const u8 = switch (self.transport) {
        .stdio => protocol_version_stdio,
        .sse => protocol_version_streamable_http,
    };
    const params = try std.fmt.allocPrint(self.gpa,
        \\{{"protocolVersion":"{s}","capabilities":{{}},"clientInfo":{{"name":"zay","version":"1.0"}}}}
    , .{protocol_version});
    defer self.gpa.free(params);

    const response = try self.sendRequest(io, "initialize", params);
    defer self.gpa.free(response);

    const parsed = try schema_mod.parseResponse(self.gpa, response) orelse {
        self.setError(io, "handshake returned no result", .{});
        return error.McpHandshakeFailed;
    };
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse {
        self.setError(io, "handshake result missing", .{});
        return error.McpHandshakeFailed;
    };
    if (result != .object) {
        self.setError(io, "handshake result not an object", .{});
        return error.McpHandshakeFailed;
    }
    const result_obj = result.object;

    // Negotiate protocol version — the server may echo or downgrade.
    // We accept whatever the server returns; no version pinning yet.
    if (result_obj.get("protocolVersion")) |pv| {
        if (pv == .string) {
            if (self.negotiated_protocol) |old| self.gpa.free(old);
            self.negotiated_protocol = self.gpa.dupe(u8, pv.string) catch null;
        }
    }

    // Capture server identity for diagnostics and TUI display.
    if (result_obj.get("serverInfo")) |si| {
        if (si == .object) {
            const sname = if (si.object.get("name")) |n| (if (n == .string) n.string else "") else "";
            const sver = if (si.object.get("version")) |v| (if (v == .string) v.string else "") else "";
            if (self.server_info) |*old| old.deinit(self.gpa);
            self.server_info = .{
                .name = self.gpa.dupe(u8, sname) catch "",
                .version = self.gpa.dupe(u8, sver) catch "",
            };
        }
    }

    // Parse server capabilities — record `tools.listChanged` on the
    // discovery spoke so the App can subscribe to
    // `notifications/tools/list_changed` and re-discover.
    self.discovery.server_supports_tools_list_changed = false;
    if (result_obj.get("capabilities")) |caps| {
        if (caps == .object) {
            if (caps.object.get("tools")) |tools_cap| {
                if (tools_cap == .object) {
                    if (tools_cap.object.get("listChanged")) |lc| {
                        if (lc == .bool) self.discovery.server_supports_tools_list_changed = lc.bool;
                    }
                }
            }
        }
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

/// Query tools/list and REPLACE the client's tool list. On success the
/// cache equals exactly the server's response — tools removed server-side
/// disappear and re-discovery never duplicates records (the old append
/// path inflated every count on `tools/list_changed`, #384 bug 2). On
/// failure (request error, parse error, OOM) the previous list stays
/// fully intact: the replacement is built first and swapped in only once
/// every record is owned.
pub fn listTools(self: *McpClient, io: std.Io) !void {
    const fresh = try listToolsFresh(self, io);
    self.discovery.replaceAll(fresh);
}

/// tools/list WITHOUT touching the discovery cache: returns freshly-built
/// owned records for the caller to install via `Discovery.replaceAll` (the
/// background re-discovery path, #385). A malformed response (no result
/// object, `tools` not an array) errors instead of returning an empty list
/// — installing empty would wipe the cache, so failure-keeps-old holds by
/// construction. Thread-safety: runs on refresh worker threads,
/// concurrent with in-flight tool calls (`request_mutex`) and with `stop`
/// (`transport_mutex` capture bracket); never mutates shared state except
/// the request-serialized fields and the atomic refresh flag.
pub fn listToolsFresh(self: *McpClient, io: std.Io) !std.ArrayList(discovery_mod.McpTool) {
    const response = try self.sendRequest(io, "tools/list", null);
    defer self.gpa.free(response);

    const parsed = try schema_mod.parseResponse(self.gpa, response) orelse return error.McpInvalidToolsResponse;
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.McpInvalidToolsResponse;
    if (result != .object) return error.McpInvalidToolsResponse;

    const tools_val = result.object.get("tools") orelse return error.McpInvalidToolsResponse;
    if (tools_val != .array) return error.McpInvalidToolsResponse;

    var fresh: std.ArrayList(discovery_mod.McpTool) = .empty;
    errdefer {
        for (fresh.items) |*tool| tool.deinit(self.gpa);
        fresh.deinit(self.gpa);
    }
    for (tools_val.array.items) |tool_val| {
        var record = try discovery_mod.toolRecordFromListEntry(self.gpa, self.name, tool_val) orelse continue;
        fresh.append(self.gpa, record) catch |err| {
            record.deinit(self.gpa);
            return err;
        };
    }
    return fresh;
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
            log.warn("MCP tool '{s}' JSON-RPC error (code {d}): {s}", .{ tool_name, code, msg });
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
            log.warn("MCP tool '{s}' returned isError: true", .{tool_name});
        }
    }

    return schema_mod.extractContentText(self.gpa, result);
}

test "McpClient full handshake + tools/list" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try client_mod.initMockClient(gpa, "mock-server", "default");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    // Handshake
    try client.initialize(io);
    try std.testing.expectEqual(client_mod.ServerStatus.connected, client.status());

    // Capability negotiation — server reported serverInfo + protocolVersion
    // and `capabilities.tools` without the listChanged flag.
    try std.testing.expect(client.server_info != null);
    try std.testing.expectEqualStrings("mock", client.server_info.?.name);
    try std.testing.expectEqualStrings("1.0", client.server_info.?.version);
    try std.testing.expect(client.negotiated_protocol != null);
    try std.testing.expectEqualStrings("2024-11-05", client.negotiated_protocol.?);
    try std.testing.expectEqual(false, client.discovery.server_supports_tools_list_changed);

    // Tool discovery
    try client.listTools(io);
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    try std.testing.expectEqualStrings("mcp__mock-server__greet", client.discovery.tools.items[0].full_name);
    try std.testing.expectEqualStrings("greet", client.discovery.tools.items[0].name);
    try std.testing.expectEqualStrings("Say hello", client.discovery.tools.items[0].description);
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items[0].schema.properties.len);
    try std.testing.expectEqualStrings("name", client.discovery.tools.items[0].schema.properties[0].name);
    try std.testing.expectEqual(tools_common.Schema.Kind.string, client.discovery.tools.items[0].schema.properties[0].kind);
    try std.testing.expect(client.discovery.tools.items[0].schema.properties[0].required);
}

test "McpClient listTools preserves the raw inputSchema of a rich schema" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try client_mod.initMockClient(gpa, "rich-server", "rich_schema");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    try client.initialize(io);
    try client.listTools(io);

    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    const tool = client.discovery.tools.items[0];
    const raw = tool.raw_input_schema orelse return error.RawSchemaMissing;

    // Every construct the projection drops survives the raw capture.
    for ([_][]const u8{ "$defs", "$ref", "prefixItems", "allOf", "oneOf", "anyOf", "\"not\"", "pattern", "minimum", "maxItems", "\"const\"", "exclusiveMaximum" }) |construct| {
        try std.testing.expect(std.mem.indexOf(u8, raw, construct) != null);
    }

    // The raw capture is valid JSON — provider pass-through writes it verbatim.
    const round_tripped = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer round_tripped.deinit();
    try std.testing.expect(round_tripped.value == .object);

    // The projection is still built alongside it and stays lossy-by-design:
    // a $ref property projects to an unconstrained string, never a claim
    // about the referenced shape.
    const filter_property = tool.schema.properties[0];
    try std.testing.expectEqualStrings("filter", filter_property.name);
    try std.testing.expectEqual(tools_common.Schema.Kind.string, filter_property.kind);
    try std.testing.expect(filter_property.kind_unconstrained);
}

test "McpClient initialize captures tools.listChanged capability" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try client_mod.initMockClient(gpa, "changeful", "list_changed");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    try client.initialize(io);
    try std.testing.expectEqual(client_mod.ServerStatus.connected, client.status());
    try std.testing.expect(client.discovery.server_supports_tools_list_changed);
    try std.testing.expectEqualStrings("changeful", client.server_info.?.name);
    try std.testing.expectEqualStrings("2.0", client.server_info.?.version);
}

test "McpClient callTool round-trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try client_mod.initMockClient(gpa, "mock-server", "default");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    // Handshake + discovery
    try client.initialize(io);
    try client.listTools(io);
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);

    // Call the tool
    const result = try client.callTool(io, "greet", "{\"name\":\"World\"}");
    defer gpa.free(result);

    try std.testing.expectEqualStrings("Hello, World!", result);
}

// ---------------------------------------------------------------------------
// Discovery-cache and failure-path invariants (#384)
// ---------------------------------------------------------------------------

test "McpClient listTools replaces the cache instead of appending" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try client_mod.initMockClient(gpa, "rediscover", "default");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    try client.initialize(io);

    // Prime the cache with a record a previous discovery left behind and the
    // server has since removed. Re-discovery REPLACES the cache: the result
    // must be exactly the server's catalog, never the union of both lists
    // (the old append path grew the list on every `tools/list_changed`).
    try client.addTool("stale", "Removed server-side", .{ .properties = &.{} }, null);
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);

    try client.listTools(io);
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    try std.testing.expectEqualStrings("greet", client.discovery.tools.items[0].name);
    try std.testing.expectEqualStrings("mcp__rediscover__greet", client.discovery.tools.items[0].full_name);

    // The list_changed path re-runs listTools on the same client — a second
    // discovery must keep the count at the server's catalog size, with
    // unique names (no duplicates).
    try client.listTools(io);
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    try std.testing.expectEqualStrings("greet", client.discovery.tools.items[0].name);
}

test "McpClient keeps the previous tool list when re-discovery fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // malformed_tools: the discovery response is not JSON, so listTools
    // fails (or finds no result) after the request itself round-trips.
    var client = try client_mod.initMockClient(gpa, "broken-list", "malformed_tools");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);

    try client.initialize(io);

    // Prime via the registration seam, as an earlier successful discovery
    // would have: exactly one record, which the failed refresh must leave
    // fully intact — a failed re-discovery never empties the cache.
    try client.addTool("kept", "Survives the failed refresh", .{ .properties = &.{} }, null);

    if (client.listTools(io)) |_| {
        // parseResponse may also reject the line as a null result — a void
        // success. Both outcomes must leave the cache untouched.
    } else |_| {}

    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    try std.testing.expectEqualStrings("kept", client.discovery.tools.items[0].name);
    try std.testing.expectEqualStrings("mcp__broken-list__kept", client.discovery.tools.items[0].full_name);
    try std.testing.expectEqual(client_mod.ServerStatus.connected, client.status());
}

// ---------------------------------------------------------------------------
// Transport-lifetime races + background re-discovery (#385)
// ---------------------------------------------------------------------------

test "McpClient listToolsFresh returns owned records and never touches the cache" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // default mode: the discovery response round-trips normally.
    var client = try client_mod.initMockClient(gpa, "fresh", "default");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);
    try client.initialize(io);

    // Prime the cache as a completed discovery would have; listToolsFresh
    // must leave it untouched — the caller owns installation.
    try client.addTool("cached", "Primed before the fetch", .{ .properties = &.{} }, null);

    var fresh = try client.listToolsFresh(io);
    defer {
        for (fresh.items) |*tool| tool.deinit(gpa);
        fresh.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), fresh.items.len);
    try std.testing.expectEqualStrings("greet", fresh.items[0].name);
    // The cache still holds exactly the primed record.
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    try std.testing.expectEqualStrings("cached", client.discovery.tools.items[0].name);
}

test "McpClient listToolsFresh errors on a malformed response and keeps the cache" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var client = try client_mod.initMockClient(gpa, "broken-fresh", "malformed_tools");
    defer client.deinit(io);

    try client.startStdio(io);
    defer client.stop(io);
    try client.initialize(io);
    try client.addTool("kept", "Survives the failed fetch", .{ .properties = &.{} }, null);

    // A malformed tools/list response must error — never return an empty
    // list, which the installer would swap in and wipe the cache. The error
    // identity depends on where parsing rejects the line (SyntaxError from
    // the JSON scanner, McpInvalidToolsResponse from the shape checks) —
    // either keeps the cache intact.
    if (client.listToolsFresh(io)) |_| return error.ExpectedError else |_| {}
    try std.testing.expectEqual(@as(usize, 1), client.discovery.tools.items.len);
    try std.testing.expectEqualStrings("kept", client.discovery.tools.items[0].name);
}
