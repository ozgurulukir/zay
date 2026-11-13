//! MCP discovery cache: the tool records a server advertises plus the
//! re-discovery bookkeeping that keeps them current.
//!
//! Ownership (#367 slice 3): this module holds the `McpTool` record type, the
//! per-client tool list, the `notifications/tools/list_changed` pending flag,
//! and the `capabilities.tools.listChanged` capability bit, together with the
//! record construction shared by `addTool` and `tools/list` parsing. The
//! orchestration that fills and drains the cache — the JSON-RPC `tools/list`
//! request in `McpClient.listTools`, the transport read loops that route
//! notifications — stays on `McpClient`; `Discovery` is deliberately a plain
//! value struct with no back-reference (extraction over facade).
//!
//! The #384 invariants live with the code that enforces them:
//! - A non-connected lifecycle never carries tools. Any transition off a
//!   live transport must `clear` the cache alongside it, or the manager's
//!   reconcile wedges the server in CONNECTING with stale tools (bug 1).
//! - `replaceAll` swaps atomically: on success the cache equals exactly the
//!   server's response; on failure the previous list stays fully intact
//!   (bug 2). A failed re-discovery never empties the cache.
//! - `pending_refresh` is written on transport worker threads and read and
//!   cleared on the UI thread, so it is atomic (bug "formal"): the store and
//!   the load-and-clear swap can never race, and a notification landing
//!   between a read and a clear survives to the next poll.

const std = @import("std");
const naming = @import("naming.zig");
const schema_mod = @import("schema.zig");
const tools_common = @import("../tools/common.zig");

/// One discovered tool. Owned by the discovery cache; `deinit` frees the
/// record's strings and schema projection.
pub const McpTool = struct {
    server_name: []u8,
    name: []u8,
    full_name: []u8,
    description: []u8,
    schema: tools_common.Schema,
    /// The server's original `inputSchema` as raw JSON (lossless) — the
    /// source of truth for provider serialization on pass-through-capable
    /// dialects, while `schema` stays the best-effort local projection.
    /// Owned; null when the server sent no object-typed `inputSchema`.
    raw_input_schema: ?[]u8 = null,

    pub fn deinit(self: *McpTool, gpa: std.mem.Allocator) void {
        gpa.free(self.server_name);
        gpa.free(self.name);
        gpa.free(self.full_name);
        gpa.free(self.description);
        if (self.raw_input_schema) |raw| gpa.free(raw);
        self.schema.deinit(gpa);
        self.* = undefined;
    }
};

pub const Discovery = struct {
    gpa: std.mem.Allocator,
    /// Discovered tool records. The cache belongs to a live transport: only
    /// a `.connected` client carries entries (see `clear`).
    tools: std.ArrayList(McpTool) = .empty,
    /// Set by `onNotification` when a `notifications/tools/list_changed`
    /// arrives mid-request — written on the transport's worker thread (stdio
    /// read loop, SSE accumulation, both under the client's `request_mutex`),
    /// read and cleared on the UI thread via `takeRefreshPending`. Atomic so
    /// the worker's store and the UI's load-and-clear can never race (a plain
    /// bool was a formal data race; #384). This avoids re-entering
    /// `tools/list` synchronously from inside a JSON-RPC read loop (which
    /// would deadlock the request mutex).
    pending_refresh: std.atomic.Value(bool) = .init(false),
    /// True when the server advertised `capabilities.tools.listChanged`. When
    /// set, the server may send `notifications/tools/list_changed` and the
    /// App should re-discover tools. False otherwise (including when the
    /// server advertises tools but not the listChanged flag).
    server_supports_tools_list_changed: bool = false,

    pub fn init(gpa: std.mem.Allocator) Discovery {
        return .{ .gpa = gpa };
    }

    /// Release the cache: every record, the list's backing allocation, and
    /// the pending flag. Part of `McpClient.deinit`.
    pub fn deinit(self: *Discovery) void {
        self.clear();
        self.tools.deinit(self.gpa);
    }

    /// Free every discovered tool record and empty the list, clearing the
    /// pending-refresh flag with it. Owns the discovery-cache invariant the
    /// disable/reconnect transitions rely on: the cache belongs to a live
    /// transport, so stopping the transport without dropping the cache would
    /// leave stale tools that wedge the next reconcile in CONNECTING (#384).
    /// Retains the list's capacity — a reconnect re-fills the cache soon.
    pub fn clear(self: *Discovery) void {
        for (self.tools.items) |*tool| tool.deinit(self.gpa);
        self.tools.clearRetainingCapacity();
        self.pending_refresh.store(false, .release);
    }

    /// Swap in a fully-built replacement list, releasing the previous cache
    /// (records and backing allocation). The caller owns the failure-half of
    /// the #384 bug 2 invariant: `listTools` only calls this after every
    /// record in `fresh` is successfully built and owned, so a failed
    /// re-discovery never reaches the swap and the previous list stays
    /// fully intact.
    pub fn replaceAll(self: *Discovery, fresh: std.ArrayList(McpTool)) void {
        for (self.tools.items) |*tool| tool.deinit(self.gpa);
        self.tools.deinit(self.gpa);
        self.tools = fresh;
    }

    /// Number of discovered tools — the count the manager aggregates and the
    /// TUI overlay renders.
    pub fn count(self: *const Discovery) usize {
        return self.tools.items.len;
    }

    /// Register a mock or discovered tool. `server_name` is the owning
    /// server's name (duped into the record; feeds the
    /// `mcp__<server>__<tool>` full name). `raw_input_schema` is the server's
    /// original `inputSchema` JSON (borrowed; duped into the record) — pass
    /// null for mock tools that have no source schema. The record takes
    /// ownership of `schema` on success; on error `schema` stays
    /// caller-owned.
    pub fn addTool(
        self: *Discovery,
        server_name: []const u8,
        tool_name: []const u8,
        description: []const u8,
        schema: tools_common.Schema,
        raw_input_schema: ?[]const u8,
    ) !void {
        const record = try buildToolRecord(self.gpa, server_name, tool_name, description, schema, raw_input_schema);
        // Append may fail; on failure the schema stays caller-owned (the
        // discovery loop's errdefer frees it), so release every field the
        // record owns EXCEPT the schema.
        self.tools.append(self.gpa, record) catch |err| {
            self.gpa.free(record.server_name);
            self.gpa.free(record.name);
            self.gpa.free(record.full_name);
            self.gpa.free(record.description);
            if (record.raw_input_schema) |raw| self.gpa.free(raw);
            return err;
        };
    }

    /// Mark the cache stale after a `notifications/tools/list_changed`.
    /// Release-store: pairs with `takeRefreshPending`'s swap.
    pub fn storeRefreshPending(self: *Discovery) void {
        self.pending_refresh.store(true, .release);
    }

    /// True when a `notifications/tools/list_changed` arrived since the last
    /// check. The App calls this on each tick and, when true, calls
    /// `refreshMcpTools` (which re-runs `tools/list` and reinjects schemas).
    /// Read-and-clear is one atomic swap: a notification landing between the
    /// read and the clear survives to the next poll instead of being lost.
    pub fn takeRefreshPending(self: *Discovery) bool {
        return self.pending_refresh.swap(false, .acq_rel);
    }

    /// Route a server-initiated notification captured during a request read.
    /// Only `notifications/tools/list_changed` is consumed (marks the cache
    /// stale); other notifications (progress, logging,
    /// resources/list_changed, prompts/list_changed) are accepted but ignored
    /// — Zay doesn't expose those primitives yet.
    pub fn onNotification(self: *Discovery, method: []const u8) void {
        if (std.mem.eql(u8, method, "notifications/tools/list_changed")) {
            // Honor the capability flag — a server that didn't advertise
            // listChanged shouldn't be sending these, but we still set the
            // flag: re-discovery is idempotent and harmless.
            self.storeRefreshPending();
            return;
        }
        // Silently accept other notifications — they're informational.
    }
};

/// Build one owned tool record from borrowed discovery fields — the shared
/// construction behind `addTool` and `tools/list` parsing. `server_name` is
/// duped into the record and feeds the `mcp__<server>__<tool>` full name. On
/// success the record owns `schema`; on error nothing is allocated and
/// `schema` stays caller-owned.
pub fn buildToolRecord(
    gpa: std.mem.Allocator,
    server_name: []const u8,
    tool_name: []const u8,
    description: []const u8,
    schema: tools_common.Schema,
    raw_input_schema: ?[]const u8,
) !McpTool {
    const full_name = try naming.toolFullName(gpa, server_name, tool_name);
    errdefer gpa.free(full_name);

    // Hoist the record's owned fields into locals so every errdefer below
    // frees an initialized slice — `try` dupes inside the return's struct
    // literal would leave the earlier copies stranded when a later one
    // failed (same hazard `buildMcpTool` fixed in the registry bridge).
    const server_name_owned = try gpa.dupe(u8, server_name);
    errdefer gpa.free(server_name_owned);
    const tool_name_owned = try gpa.dupe(u8, tool_name);
    errdefer gpa.free(tool_name_owned);
    const description_owned = try gpa.dupe(u8, description);
    errdefer gpa.free(description_owned);
    const raw_owned = if (raw_input_schema) |raw| try gpa.dupe(u8, raw) else null;
    errdefer if (raw_owned) |raw| gpa.free(raw);

    return .{
        .server_name = server_name_owned,
        .name = tool_name_owned,
        .full_name = full_name,
        .description = description_owned,
        .schema = schema,
        .raw_input_schema = raw_owned,
    };
}

/// Extract one `tools/list` entry into an owned record. Null when the
/// entry is malformed (skipped silently, matching the discovery
/// contract); an error only for allocation failure. On success the
/// record owns the schema projection and raw capture, so the caller's
/// errdefer scope can end at the return without ownership overlap.
pub fn toolRecordFromListEntry(
    gpa: std.mem.Allocator,
    server_name: []const u8,
    tool_val: std.json.Value,
) !?McpTool {
    if (tool_val != .object) return null;
    const obj = tool_val.object;

    const tool_name = if (obj.get("name")) |n| (if (n == .string) n.string else return null) else return null;
    const description = if (obj.get("description")) |d| (if (d == .string) d.string else "") else "";
    const input_schema = obj.get("inputSchema");
    var schema = if (input_schema) |s| (try schema_mod.schemaFromJsonSchema(gpa, s)) else tools_common.Schema{ .properties = &.{} };
    // Covers the OOM window before the record takes ownership (raw
    // capture or record construction); after that, deinit-ing here would
    // double-free — the record now owns the projection.
    errdefer schema.deinit(gpa);
    const raw_input_schema = try schema_mod.rawInputSchemaJson(gpa, input_schema);
    defer if (raw_input_schema) |raw| gpa.free(raw);

    return try buildToolRecord(gpa, server_name, tool_name, description, schema, raw_input_schema);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Discovery addTool owns extended schema fields and deinits them" {
    const gpa = std.testing.allocator;
    var discovery = Discovery.init(gpa);
    defer discovery.deinit();

    const schema_json =
        \\{"type":"object","properties":{
        \\  "time_range":{"anyOf":[{"type":"string","enum":["day","week"]},{"type":"null"}],"default":null},
        \\  "value":{"anyOf":[{"type":"object"},{"type":"array"}]}
        \\}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_json, .{});
    defer parsed.deinit();
    const schema = try schema_mod.schemaFromJsonSchema(gpa, parsed.value);

    try discovery.addTool("schema-server", "search", "Search", schema, null);
    try std.testing.expectEqual(@as(usize, 1), discovery.count());
    try std.testing.expectEqualStrings("mcp__schema-server__search", discovery.tools.items[0].full_name);
}

test "Discovery addTool leaves raw_input_schema null without a source schema" {
    const gpa = std.testing.allocator;
    var discovery = Discovery.init(gpa);
    defer discovery.deinit();

    // addTool's null raw path is the mock registration contract; discovery
    // only produces a non-null raw for object-typed inputSchemas.
    try discovery.addTool("bare", "noop", "No schema", .{ .properties = &.{} }, null);
    try std.testing.expect(discovery.tools.items[0].raw_input_schema == null);
}

test "toolRecordFromListEntry skips malformed entries and builds valid records" {
    const gpa = std.testing.allocator;
    const input =
        \\{"tools":[
        \\  "not an object",
        \\  {"description":"no name"},
        \\  {"name":"non-string-description","description":42,"inputSchema":{"type":"object"}},
        \\  {"name":"greet","description":"Say hello","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, input, .{});
    defer parsed.deinit();
    const entries = parsed.value.object.get("tools").?.array.items;

    // Malformed entries are skipped (null), not errors — the discovery
    // contract keeps parsing after a bad entry.
    try std.testing.expect((try toolRecordFromListEntry(gpa, "srv", entries[0])) == null);
    try std.testing.expect((try toolRecordFromListEntry(gpa, "srv", entries[1])) == null);

    // A non-string description projects to "" rather than failing.
    var terse = (try toolRecordFromListEntry(gpa, "srv", entries[2])).?;
    defer terse.deinit(gpa);
    try std.testing.expectEqualStrings("", terse.description);
    try std.testing.expectEqualStrings("mcp__srv__non-string-description", terse.full_name);
    try std.testing.expect(terse.raw_input_schema != null);

    // A complete entry keeps every borrowed field.
    var full = (try toolRecordFromListEntry(gpa, "srv", entries[3])).?;
    defer full.deinit(gpa);
    try std.testing.expectEqualStrings("greet", full.name);
    try std.testing.expectEqualStrings("srv", full.server_name);
    try std.testing.expectEqualStrings("Say hello", full.description);
    try std.testing.expectEqual(@as(usize, 1), full.schema.properties.len);
    try std.testing.expect(full.schema.properties[0].required);
}

test "Discovery replaceAll swaps in the fresh list and frees the old one" {
    const gpa = std.testing.allocator;
    var discovery = Discovery.init(gpa);
    defer discovery.deinit();

    // Prime the cache the way an earlier discovery would have.
    try discovery.addTool("srv", "stale", "Removed server-side", .{ .properties = &.{} }, null);
    try discovery.addTool("srv", "stale2", "Also removed", .{ .properties = &.{} }, null);
    try std.testing.expectEqual(@as(usize, 2), discovery.count());

    // Build a replacement the way listTools does, then swap. The testing
    // allocator's leak check pins that the old records (and the old list's
    // backing array) were released.
    var fresh: std.ArrayList(McpTool) = .empty;
    var record = try buildToolRecord(gpa, "srv", "greet", "Say hello", .{ .properties = &.{} }, null);
    fresh.append(gpa, record) catch {
        record.deinit(gpa);
        return error.OutOfMemory;
    };
    discovery.replaceAll(fresh);

    try std.testing.expectEqual(@as(usize, 1), discovery.count());
    try std.testing.expectEqualStrings("greet", discovery.tools.items[0].name);
}

test "Discovery clear empties the cache and drops the pending flag" {
    const gpa = std.testing.allocator;
    var discovery = Discovery.init(gpa);
    defer discovery.deinit();

    try discovery.addTool("srv", "tool", "A tool", .{ .properties = &.{} }, null);
    discovery.onNotification("notifications/tools/list_changed");
    try std.testing.expect(discovery.takeRefreshPending());
    try std.testing.expectEqual(@as(usize, 1), discovery.count());

    // The disable-transition invariant (#384): clear drops the records AND
    // the pending flag together — a cleared cache never triggers a stale
    // re-discovery on the next tick.
    discovery.clear();
    try std.testing.expectEqual(@as(usize, 0), discovery.count());
    try std.testing.expectEqual(false, discovery.takeRefreshPending());

    // Clear is idempotent.
    discovery.clear();
    try std.testing.expectEqual(@as(usize, 0), discovery.count());
}

test "Discovery onNotification sets pending_refresh for tools/list_changed" {
    const gpa = std.testing.allocator;
    var discovery = Discovery.init(gpa);
    defer discovery.deinit();

    // Initially no pending refresh.
    try std.testing.expectEqual(false, discovery.takeRefreshPending());

    // Simulate a server-initiated tools/list_changed notification.
    discovery.onNotification("notifications/tools/list_changed");
    try std.testing.expect(discovery.takeRefreshPending());

    // The flag clears on read — a second poll returns false.
    try std.testing.expectEqual(false, discovery.takeRefreshPending());

    // Other notifications do NOT set the flag.
    discovery.onNotification("notifications/progress");
    discovery.onNotification("notifications/resources/list_changed");
    try std.testing.expectEqual(false, discovery.takeRefreshPending());
}

test "Discovery pending_refresh survives concurrent worker stores" {
    const gpa = std.testing.allocator;
    var discovery = Discovery.init(gpa);

    // Only the atomic flag is shared with the worker — no allocator use, so
    // the plain testing allocator is safe on the UI side.
    const Worker = struct {
        fn run(cache: *Discovery, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) cache.storeRefreshPending();
        }
    };
    var stop_flag = std.atomic.Value(bool).init(false);
    const worker = try std.Thread.spawn(.{}, Worker.run, .{ &discovery, &stop_flag });

    // The UI's swap must observe a store under concurrent writes — a lost
    // notification deadlocks the UI's re-discovery into this deadline. (The
    // clear-exactly-once half is pinned single-threaded by the
    // onNotification test above: after a worker store there is no
    // deterministic flag value to assert once the hammer stops.)
    var observed = false;
    var spins: usize = 0;
    while (!observed and spins < 5_000) : (spins += 1) {
        observed = discovery.takeRefreshPending();
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }

    stop_flag.store(true, .release);
    worker.join();

    try std.testing.expect(observed);
}
