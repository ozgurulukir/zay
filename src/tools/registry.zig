const std = @import("std");

const background_tool = @import("background.zig");
const bash_tool = @import("bash.zig");
const common = @import("common.zig");
const database_tool = @import("database.zig");
const lane_tool = @import("lane.zig");
const mcp_bridge = @import("../mcp/registry_bridge.zig");
const mcp_mod = @import("../mcp/manager.zig");
const os = @import("../os.zig");
const pwsh_tool = @import("pwsh.zig");
const skill_tool = @import("skill.zig");
const Tool = common.Tool;

const log = std.log.scoped(.registry);

/// Runtime-mutable tool registry. The App owns one; builtin tools live in
/// its immutable `builtin` slice, plugin tools are appended at runtime
/// through `addPluginTool`. This is the single source of truth for tools
/// in the agent — `tools.runWith` (dispatch) and each `LanguageModel`
/// adapter (schema serialization) read from `all`.
///
/// `all()` returns a borrowed slice that aliases the registry's internal
/// storage. It is invalidated by any `addPluginTool` / `removePluginToolsOf`
/// call — callers must consume the slice before mutating.
pub const ToolRegistry = struct {
    /// Immutable builtin tools (bash or pwsh, per `shell_tool`). Same backing as
    /// `builtinRegistry()`.
    builtin: []const Tool,
    /// Plugin tools appended at runtime. Each owns its `userdata` allocation
    /// through `Tool.userdata_free`; `deinit` calls them.
    plugin: std.ArrayList(Tool) = .empty,
    /// Backing storage for the borrowed slice returned by `all`. The capacity
    /// is reused across calls so the `all()` pointer is stable between calls
    /// that don't add or remove tools.
    scratch: std.ArrayList(Tool) = .empty,
    /// Hash map index for O(1) tool lookups by name. Builtins take precedence
    /// over plugin tools on name collisions. Eagerly populated on init/add/remove.
    lookup_index: std.StringHashMapUnmanaged(Tool) = .empty,

    pub fn init(gpa: std.mem.Allocator, builtin_slice: []const Tool) !ToolRegistry {
        var reg = ToolRegistry{ .builtin = builtin_slice };
        try reg.lookup_index.ensureTotalCapacity(gpa, @intCast(builtin_slice.len));
        for (builtin_slice) |tool| {
            reg.lookup_index.putAssumeCapacity(tool.name, tool);
        }
        return reg;
    }

    pub fn deinit(self: *ToolRegistry, gpa: std.mem.Allocator) void {
        for (self.plugin.items) |*t| {
            // Plugin tool's `name` and `description` are always owned and
            // heap-allocated (see `buildPluginTool` in the registry
            // bridge). Free them here so the registry is the single
            // source of truth for plugin tool lifetimes.
            gpa.free(t.name);
            gpa.free(t.description);
            if (t.userdata_free) |free_fn| free_fn(gpa, t.userdata);
        }
        self.plugin.deinit(gpa);
        self.scratch.deinit(gpa);
        self.lookup_index.deinit(gpa);
    }

    /// Borrowed flat slice of every registered tool (builtin + plugin). The
    /// slice aliases `scratch` storage; it is invalidated by any mutation
    /// that adds or removes a tool. Callers should consume the slice
    /// synchronously — do not stash it across `addPluginTool` calls.
    pub fn all(self: *ToolRegistry, gpa: std.mem.Allocator) ![]const Tool {
        self.scratch.clearRetainingCapacity();
        try self.scratch.appendSlice(gpa, self.builtin);
        try self.scratch.appendSlice(gpa, self.plugin.items);
        return self.scratch.items;
    }

    /// Look up a tool by name (O(1)). Read-only operation. Safe without locks
    /// during turn execution when no mutations occur concurrently (guaranteed
    /// while the `anyLaneTurnActive` mutation gate is active; plugin/MCP tools
    /// are registered at initRuntime before worker turns start).
    pub fn lookup(self: *const ToolRegistry, name: []const u8) ?Tool {
        return self.lookup_index.get(name);
    }

    /// Append a plugin tool and update the lookup index eagerly. Builtin tools
    /// always win name collisions.
    pub fn addPluginTool(self: *ToolRegistry, gpa: std.mem.Allocator, tool: Tool) !void {
        try self.plugin.append(gpa, tool);
        errdefer _ = self.plugin.pop();
        if (!self.lookup_index.contains(tool.name)) {
            try self.lookup_index.put(gpa, tool.name, tool);
        } else {
            // The record still lands in `all()` (assembleToolSpecs dedups
            // first-wins at serialization), but it can never dispatch — say
            // which tool it lost to, or the shadow is undiagnosable.
            const kind: []const u8 = blk: {
                for (self.builtin) |b| {
                    if (std.mem.eql(u8, b.name, tool.name)) break :blk "builtin";
                }
                break :blk "earlier plugin";
            };
            log.warn("plugin tool '{s}' is shadowed by a {s} with the same name; the new record will not dispatch", .{ tool.name, kind });
        }
    }

    /// Remove every plugin tool whose name starts with the
    /// `<prefix>__` namespace (e.g. `lua__<plugin_name>__`). Frees each
    /// matching tool's `userdata` before splicing it out. Idempotent: a
    /// no-op when no tools match. Rebuilds the lookup index eagerly when tools
    /// are removed.
    pub fn removePluginToolsWithPrefix(
        self: *ToolRegistry,
        gpa: std.mem.Allocator,
        prefix: []const u8,
    ) void {
        var i: usize = 0;
        var removed = false;
        while (i < self.plugin.items.len) {
            const t = self.plugin.items[i];
            if (std.mem.startsWith(u8, t.name, prefix)) {
                gpa.free(t.name);
                gpa.free(t.description);
                if (t.userdata_free) |free_fn| free_fn(gpa, t.userdata);
                _ = self.plugin.orderedRemove(i);
                removed = true;
            } else {
                i += 1;
            }
        }
        if (removed) {
            self.lookup_index.clearRetainingCapacity();
            self.lookup_index.ensureTotalCapacity(gpa, @intCast(self.builtin.len + self.plugin.items.len)) catch |err| {
                log.warn("failed to reserve lookup_index capacity: {s}", .{@errorName(err)});
            };
            for (self.builtin) |tool| {
                self.lookup_index.put(gpa, tool.name, tool) catch |err| {
                    log.warn("failed to index builtin tool '{s}': {s}", .{ tool.name, @errorName(err) });
                };
            }
            for (self.plugin.items) |tool| {
                if (!self.lookup_index.contains(tool.name)) {
                    self.lookup_index.put(gpa, tool.name, tool) catch |err| {
                        log.warn("failed to index plugin tool '{s}': {s}", .{ tool.name, @errorName(err) });
                    };
                }
            }
        }
    }

    /// Replace every `mcp__`-namespaced record with one `Tool` per tool
    /// discovered on the manager's connected clients (see
    /// `mcp/registry_bridge.zig`). A client that dropped since the last sync
    /// simply stops contributing records; a stale record therefore degrades
    /// to "MCP server not found" at dispatch until the next sync. Idempotent.
    /// Caller must hold the registry mutation gate (no lane turn active) —
    /// same contract as plugin re-registration.
    pub fn syncMcpTools(self: *ToolRegistry, gpa: std.mem.Allocator, manager: *mcp_mod.McpManager) !void {
        self.removePluginToolsWithPrefix(gpa, "mcp__");
        for (manager.clients.items) |*client| {
            if (client.status() != .connected) continue;
            for (client.tools.items) |*tool| {
                const record = mcp_bridge.buildMcpTool(gpa, client.name, tool.name, tool.description, tool.schema, tool.raw_input_schema) catch |err| {
                    log.warn("syncMcpTools: buildMcpTool '{s}' failed: {s}", .{ tool.full_name, @errorName(err) });
                    continue;
                };
                self.addPluginTool(gpa, record) catch |err| {
                    // The record was fully built — free it before propagating
                    // or its name/description/key leak on the error path.
                    gpa.free(record.name);
                    gpa.free(record.description);
                    if (record.userdata_free) |free_fn| free_fn(gpa, record.userdata);
                    return err;
                };
            }
        }
    }
};

/// The implementation module for the host shell — THE single shell-selection
/// point. `shell_tool` below is its model-facing `Tool` record, and the
/// executor routes special cases (containment guard, background routing)
/// through `shell_impl`'s namespace, so name and behavior can never drift.
pub const shell_impl = if (os.is_windows) pwsh_tool else bash_tool;

/// The model-facing shell tool selected at comptime: `pwsh` on Windows,
/// `bash` elsewhere. Every consumer (the builtin list below, the executor's
/// dispatch, the TUI display policy) reads the selected name from here.
pub const shell_tool: Tool = shell_impl.tool;

/// Canonical builtin tool list. Consumed by `ToolRegistry.init` and by
/// `src/tools.zig`'s re-export (all single-registry call sites).
pub fn builtin() []const Tool {
    return &.{ shell_tool, lane_tool.tool, background_tool.tool, skill_tool.tool, database_tool.tool };
}

const tools_common = @import("common.zig");

// Sentinel tool for testing — has a valid name/description/schema so the
// test doesn't trip on dereferencing dangling slices.
const dummy_free: *const fn (gpa: std.mem.Allocator, ud: *anyopaque) void = struct {
    fn free(gpa: std.mem.Allocator, ud: *anyopaque) void {
        _ = gpa;
        _ = ud;
    }
}.free;

const dummy_run: *const fn (
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    args: []const u8,
    env: tools_common.Env,
) tools_common.Error!tools_common.Output = struct {
    fn run(
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        args: []const u8,
        env: tools_common.Env,
    ) tools_common.Error!tools_common.Output {
        _ = io;
        _ = cwd;
        _ = args;
        _ = env;
        const stdout = try gpa.dupe(u8, "ok");
        const stderr = try gpa.alloc(u8, 0);
        return .{ .stdout = stdout, .stderr = stderr, .code = 0 };
    }
}.run;

const dummy_display: *const fn (
    gpa: std.mem.Allocator,
    args: []const u8,
    env: tools_common.Env,
) std.mem.Allocator.Error!tools_common.ToolDisplay = struct {
    fn display(
        gpa: std.mem.Allocator,
        args: []const u8,
        env: tools_common.Env,
    ) std.mem.Allocator.Error!tools_common.ToolDisplay {
        _ = args;
        _ = env;
        return .{ .label = try gpa.dupe(u8, "dummy") };
    }
}.display;

test "ToolRegistry: lookup finds builtin tools" {
    const gpa = std.testing.allocator;
    var reg = try ToolRegistry.init(gpa, @import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);

    const maybe_tool = reg.lookup(shell_tool.name);
    try std.testing.expect(maybe_tool != null);
    const tool = maybe_tool.?;
    try std.testing.expectEqualStrings(shell_tool.name, tool.name);
}

test "ToolRegistry: lookup returns null for unknown tool" {
    const gpa = std.testing.allocator;
    var reg = try ToolRegistry.init(gpa, @import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);

    try std.testing.expect((reg.lookup("nope")) == null);
}

test "ToolRegistry: addPluginTool makes plugin tool discoverable" {
    const gpa = std.testing.allocator;
    var reg = try ToolRegistry.init(gpa, @import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);

    const name = try gpa.dupe(u8, "lua__p__t");
    errdefer gpa.free(name);
    const desc = try gpa.dupe(u8, "plugin tool");
    errdefer gpa.free(desc);

    try reg.addPluginTool(gpa, .{
        .name = name,
        .description = desc,
        .schema = .{ .properties = &.{} },
        .run = dummy_run,
        .display = dummy_display,
        .userdata = undefined,
        .userdata_free = dummy_free,
    });

    const maybe_tool = reg.lookup("lua__p__t");
    try std.testing.expect(maybe_tool != null);
    const tool = maybe_tool.?;
    try std.testing.expectEqualStrings("lua__p__t", tool.name);
    try std.testing.expectEqualStrings("plugin tool", tool.description);

    const all = try reg.all(gpa);
    try std.testing.expectEqual(@as(usize, 6), all.len); // shell + lane + background + skill + database + plugin
    try std.testing.expectEqualStrings(shell_tool.name, all[0].name);
    try std.testing.expectEqualStrings("lane", all[1].name);
    try std.testing.expectEqualStrings("background", all[2].name);
    try std.testing.expectEqualStrings("skill", all[3].name);
    try std.testing.expectEqualStrings("database", all[4].name);
    try std.testing.expectEqualStrings("lua__p__t", all[5].name);
}

test "ToolRegistry: removePluginToolsWithPrefix strips matching tools" {
    const gpa = std.testing.allocator;
    var reg = try ToolRegistry.init(gpa, @import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);

    const mk = struct {
        fn make(gpa_: std.mem.Allocator, reg_: *ToolRegistry, n: []const u8) !void {
            const name = try gpa_.dupe(u8, n);
            errdefer gpa_.free(name);
            const desc = try gpa_.dupe(u8, "d");
            errdefer gpa_.free(desc);
            try reg_.addPluginTool(gpa_, .{
                .name = name,
                .description = desc,
                .schema = .{ .properties = &.{} },
                .run = dummy_run,
                .display = dummy_display,
                .userdata = undefined,
                .userdata_free = dummy_free,
            });
        }
    }.make;
    try mk(gpa, &reg, "lua__p__a");
    try mk(gpa, &reg, "lua__p__b");
    try mk(gpa, &reg, "mcp__x__c"); // should not be removed

    reg.removePluginToolsWithPrefix(gpa, "lua__p__");
    try std.testing.expect((reg.lookup("lua__p__a")) == null);
    try std.testing.expect((reg.lookup("lua__p__b")) == null);
    try std.testing.expect((reg.lookup("mcp__x__c")) != null);
    try std.testing.expect((reg.lookup(shell_tool.name)) != null);
    try std.testing.expect((reg.lookup("skill")) != null);
}

test "ToolRegistry: strip-and-rebuild keeps plugin tools unique across re-registration" {
    // Pins registerPluginTools' re-sync semantics (P8): strip all `lua__`
    // tools, then append fresh — duplicate names can never reach
    // buildAllToolsJson (strict providers 400 on duplicate tool names).
    // registerPluginTools runs at initRuntime today; this pins the
    // idempotency contract for any future re-registration site.
    const gpa = std.testing.allocator;
    var reg = try ToolRegistry.init(gpa, @import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);

    const mk = struct {
        fn make(gpa_: std.mem.Allocator, reg_: *ToolRegistry, n: []const u8) !void {
            const name = try gpa_.dupe(u8, n);
            errdefer gpa_.free(name);
            const desc = try gpa_.dupe(u8, "d");
            errdefer gpa_.free(desc);
            try reg_.addPluginTool(gpa_, .{
                .name = name,
                .description = desc,
                .schema = .{ .properties = &.{} },
                .run = dummy_run,
                .display = dummy_display,
                .userdata = undefined,
                .userdata_free = dummy_free,
            });
        }
    }.make;

    // Non-lua plugin tools (the MCP path injects those; registerPluginTools
    // never touches them) are added once, before the re-registration cycles.
    try mk(gpa, &reg, "mcp__x__c");

    // The registerPluginTools sequence, twice (initial sync + any future
    // re-sync).
    for (0..2) |_| {
        reg.removePluginToolsWithPrefix(gpa, "lua__");
        try mk(gpa, &reg, "lua__p__a");
        try mk(gpa, &reg, "lua__p__b");
    }

    // Each lua__ name appears exactly once; non-lua plugin tools survive.
    const all = try reg.all(gpa);
    var lua_a: usize = 0;
    var lua_b: usize = 0;
    var mcp_c: usize = 0;
    for (all) |t| {
        if (std.mem.eql(u8, t.name, "lua__p__a")) lua_a += 1;
        if (std.mem.eql(u8, t.name, "lua__p__b")) lua_b += 1;
        if (std.mem.eql(u8, t.name, "mcp__x__c")) mcp_c += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), lua_a);
    try std.testing.expectEqual(@as(usize, 1), lua_b);
    try std.testing.expectEqual(@as(usize, 1), mcp_c);
}

test "ToolRegistry: all() returns valid slices after multiple calls" {
    // Regression: a refactor that frees a tool's `name`/`description` after
    // addPluginTool corrupts the registry. all() must always return slices
    // whose tool data is fully owned by the registry.
    const gpa = std.testing.allocator;
    var reg = try ToolRegistry.init(gpa, @import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);

    const mk = struct {
        fn make(gpa_: std.mem.Allocator, reg_: *ToolRegistry, n: []const u8) !void {
            const name = try gpa_.dupe(u8, n);
            errdefer gpa_.free(name);
            const desc = try gpa_.dupe(u8, "test desc");
            errdefer gpa_.free(desc);
            try reg_.addPluginTool(gpa_, .{
                .name = name,
                .description = desc,
                .schema = .{ .properties = &.{} },
                .run = dummy_run,
                .display = dummy_display,
                .userdata = undefined,
                .userdata_free = dummy_free,
            });
        }
    }.make;
    try mk(gpa, &reg, "lua__p__a");
    try mk(gpa, &reg, "lua__p__b");

    // First all(): tools are still allocated.
    {
        const all = try reg.all(gpa);
        try std.testing.expect(all.len == 7); // shell + lane + background + skill + database + 2 plugin
        for (all) |t| {
            try std.testing.expect(t.name.len > 0);
            try std.testing.expect(t.description.len > 0);
        }
    }

    // Reuse the same registry; backing storage must still be intact.
    {
        const all = try reg.all(gpa);
        try std.testing.expect(all.len == 7);
        for (all) |t| {
            try std.testing.expect(t.name.len > 0);
            try std.testing.expect(t.description.len > 0);
        }
    }
}

test "registry builtin carries exactly one shell tool" {
    // SSOT vector (Phase 3): the builtin list must expose exactly one shell
    // tool (`pwsh` on Windows, `bash` elsewhere) plus `lane`, `background`, `skill`, and `database`.
    const tools = builtin();
    try std.testing.expectEqual(@as(usize, 5), tools.len);
    try std.testing.expect(std.mem.eql(u8, tools[0].name, shell_tool.name));
    try std.testing.expectEqualStrings("lane", tools[1].name);
    try std.testing.expectEqualStrings("background", tools[2].name);
    try std.testing.expectEqualStrings("skill", tools[3].name);
    try std.testing.expectEqualStrings("database", tools[4].name);
    try std.testing.expect(shell_tool.name.len == 4 or std.mem.eql(u8, shell_tool.name, "pwsh"));
}

test "ToolRegistry: plugin tool colliding with a builtin keeps builtin dispatch and both records" {
    const gpa = std.testing.allocator;
    var reg = try ToolRegistry.init(gpa, @import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);

    const name = try gpa.dupe(u8, shell_tool.name);
    errdefer gpa.free(name);
    const desc = try gpa.dupe(u8, "shadower");
    errdefer gpa.free(desc);
    try reg.addPluginTool(gpa, .{
        .name = name,
        .description = desc,
        .schema = .{ .properties = &.{} },
        .run = dummy_run,
        .display = dummy_display,
        .userdata = undefined,
        .userdata_free = dummy_free,
    });

    // Dispatch still resolves to the builtin (first-wins by name).
    const winner = reg.lookup(shell_tool.name).?;
    try std.testing.expectEqual(shell_tool.run, winner.run);
    try std.testing.expectEqualStrings(shell_tool.description, winner.description);
    // Both records survive in all() (builtin + lane + background + skill + database + shadower).
    const all = try reg.all(gpa);
    try std.testing.expectEqual(@as(usize, 6), all.len);
    // deinit frees the heap-duped name/description without crashing — the
    // testing allocator's leak check is part of the assertion.
}

/// Discover the rich-schema mock tool over real stdio JSON-RPC and install
/// the connected client into a fresh manager — the state an installed async
/// connect result leaves behind. Caller owns the returned manager and must
/// deinit it (which also stops the spawned server).
fn managerWithRichServer(gpa: std.mem.Allocator, io: std.Io) !mcp_mod.McpManager {
    const client_mod = @import("../mcp/client.zig");
    var manager = mcp_mod.McpManager.init(gpa);
    errdefer manager.deinit(io);
    var client = try client_mod.McpClient.init(gpa, "rich", @import("mcp_mock_server").path, &.{"rich_schema"}, null);
    errdefer client.deinit(io);
    try client.startStdio(io);
    try client.initialize(io);
    try client.listTools(io);
    // The list owns the client from here; manager.deinit (or the errdefer on
    // a failed append) stops the spawned server.
    try manager.clients.append(gpa, client);
    return manager;
}

test "ToolRegistry: MCP raw inputSchema survives discovery, registry, and provider serialization" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tool_schema = @import("../ai/tool_schema.zig");

    var manager = try managerWithRichServer(gpa, io);
    defer manager.deinit(io);

    var reg = try ToolRegistry.init(gpa, @import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);
    try reg.syncMcpTools(gpa, &manager);

    const record = reg.lookup("mcp__rich__query") orelse return error.McpToolMissing;
    const raw = record.raw_input_schema orelse return error.RawSchemaMissing;
    const specs = [_]tool_schema.ToolSpec{tool_schema.specFromTool(record)};

    // Pass-through-capable dialect (non-strict, both envelopes): the provider
    // `parameters` is the server's schema verbatim — every construct the
    // projection drops ($defs, $ref, prefixItems, allOf, pattern, bounds)
    // reaches the wire without semantic loss and without injected rewrites.
    for ([_]tool_schema.Envelope{ .completions, .responses }) |envelope| {
        const json = try tool_schema.buildToolsJson(gpa, &specs, false, envelope);
        defer gpa.free(json);
        const expected_parameters = try std.fmt.allocPrint(gpa, "\"parameters\":{s}", .{raw});
        defer gpa.free(expected_parameters);
        try std.testing.expect(std.mem.indexOf(u8, json, expected_parameters) != null);

        // Semantic equality, not just a substring: the wire form parses in
        // place and re-serializes to the server's schema byte-for-byte, so
        // the embedded parameters value is structurally identical to the
        // source — nothing was dropped or reshaped in between.
        const parsed_json = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
        defer parsed_json.deinit();
        const parameters = switch (envelope) {
            .completions => parsed_json.value.array.items[0].object.get("function").?.object.get("parameters").?,
            .responses => parsed_json.value.array.items[0].object.get("parameters").?,
        };
        const reserialized = try std.json.Stringify.valueAlloc(gpa, parameters, .{});
        defer gpa.free(reserialized);
        try std.testing.expectEqualStrings(raw, reserialized);
        // No fabricated projection content: the raw's constrained array items
        // never degrade to the projection's empty `items:{}` marker.
        try std.testing.expect(std.mem.indexOf(u8, json, "\"items\":{}") == null);
    }

    // Strict structured-outputs contract: the raw schema is NOT passed
    // through (the dialect accepts only a JSON Schema subset); the projected
    // form is transformed instead and stays a valid tool definition.
    const strict_json = try tool_schema.buildToolsJson(gpa, &specs, true, .completions);
    defer gpa.free(strict_json);
    try std.testing.expect(std.mem.indexOf(u8, strict_json, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, strict_json, "$defs") == null);
    const strict_parsed = try std.json.parseFromSlice(std.json.Value, gpa, strict_json, .{});
    defer strict_parsed.deinit();
    try std.testing.expect(strict_parsed.value == .array);
}

test "ToolRegistry: MCP records outlive a server disconnect with their raw schema" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tool_schema = @import("../ai/tool_schema.zig");

    var manager = try managerWithRichServer(gpa, io);
    defer manager.deinit(io);

    var reg = try ToolRegistry.init(gpa, @import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);
    try reg.syncMcpTools(gpa, &manager);

    const record = reg.lookup("mcp__rich__query") orelse return error.McpToolMissing;
    const raw_before = try gpa.dupe(u8, record.raw_input_schema.?);
    defer gpa.free(raw_before);

    // Disconnect the server: every client-side McpTool (and its raw schema)
    // is freed. The registry record's deep copy must remain valid until the
    // next (turn-gated) sync removes it.
    manager.disconnectClient(io, 0);
    try std.testing.expectEqual(@as(usize, 0), manager.clients.items[0].tools.items.len);

    const stale = reg.lookup("mcp__rich__query") orelse return error.McpToolMissing;
    try std.testing.expectEqualStrings(raw_before, stale.raw_input_schema.?);

    // The stale record still serializes for the provider — no dangling read
    // through `raw_input_schema` or the projected `schema`.
    const specs = [_]tool_schema.ToolSpec{tool_schema.specFromTool(stale)};
    const json = try tool_schema.buildToolsJson(gpa, &specs, false, .completions);
    defer gpa.free(json);
    const expected_parameters = try std.fmt.allocPrint(gpa, "\"parameters\":{s}", .{raw_before});
    defer gpa.free(expected_parameters);
    try std.testing.expect(std.mem.indexOf(u8, json, expected_parameters) != null);
}

test "ToolRegistry: benchmark lookup performance" {
    const platform = @import("platform");
    const gpa = std.testing.allocator;
    var reg = try ToolRegistry.init(gpa, @import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);

    // Add 50 plugin tools to simulate a populated registry
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const name = try std.fmt.allocPrint(gpa, "lua__plugin_{d}__tool", .{i});
        errdefer gpa.free(name);
        const desc = try gpa.dupe(u8, "plugin tool desc");
        errdefer gpa.free(desc);

        try reg.addPluginTool(gpa, .{
            .name = name,
            .description = desc,
            .schema = .{ .properties = &.{} },
            .run = dummy_run,
            .display = dummy_display,
            .userdata = undefined,
            .userdata_free = dummy_free,
        });
    }

    const start_time = platform.monotonicNowNs();
    const iterations: usize = 100_000;
    var iterations_done: usize = 0;

    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        // Look up builtin tool
        if (reg.lookup(shell_tool.name)) |t| {
            _ = t;
            iterations_done += 1;
        }
        // Look up last plugin tool (worst case for linear scan)
        if (reg.lookup("lua__plugin_49__tool")) |t| {
            _ = t;
            iterations_done += 1;
        }
        // Look up non-existent tool
        if (reg.lookup("non_existent_tool_name")) |t| {
            _ = t;
            iterations_done += 1;
        }
    }

    const elapsed_ns = platform.monotonicNowNs() - start_time;
    var env_map = platform.getEnvMap(gpa) catch null;
    if (env_map) |*m| {
        defer m.deinit();
        if (m.get("ZAY_BENCHMARK") != null) {
            std.debug.print("\n[BENCHMARK] ToolRegistry lookup: {d} ops in {d} ns ({d} ns/op)\n", .{
                iterations_done,
                elapsed_ns,
                @divTrunc(elapsed_ns, @as(i128, @intCast(iterations_done))),
            });
        }
    }
}
