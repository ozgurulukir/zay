//! Bridge between the Lua plugin system and the agent's `ToolRegistry`.
//!
//! Plugin tools (registered through `zay.register_tool` from inside
//! `init.lua`) are materialized as `tools.Tool` records and inserted into
//! the registry. Each `Tool` carries a `PluginToolKey` in its `userdata`
//! field; the shared `runPluginTool` / `displayPluginTool` dispatchers
//! decode the key and route the call to the correct `(plugin_name,
//! tool_name)` handler through `PluginManager.callTool`.
//!
//! This replaces the previous "schema-only `McpToolSchema`" path used by
//! MCP — plugin tools now flow through the same `Tool.run`/`Tool.display`
//! pipeline as builtins, so they get the bash-style display policy and
//! schema parsing for free.

const std = @import("std");
const lua_mod = @import("root.zig");
const PluginManager = lua_mod.PluginManager;
const PluginInstance = lua_mod.PluginInstance;
const tools_mod = @import("../tools.zig");
const tools_common = @import("../tools/common.zig");
const Tool = tools_common.Tool;

/// Per-tool context owned by the registry; freed by `freePluginToolKey`
/// when the tool is removed. Holds the parsed `plugin_name` and
/// `tool_name` extracted from the descriptor's `name` field. The
/// `*PluginManager` is no longer stored here: it is reachable from
/// `executor.plugin_manager` (set on every `App` by-value copy), so
/// storing a manager pointer here would dangle the moment the App
/// struct is re-copied through the run call chain.
pub const PluginToolKey = struct {
    plugin_name: []u8,
    tool_name: []u8,
    schema: tools_common.Schema = .{ .properties = &.{} },
};

/// Free callback for `Tool.userdata_free`. Decodes the `*anyopaque` back
/// to a `*PluginToolKey` and releases it.
pub fn freePluginToolKey(gpa: std.mem.Allocator, ud: *anyopaque) void {
    const key: *PluginToolKey = @ptrCast(@alignCast(ud));
    gpa.free(key.plugin_name);
    gpa.free(key.tool_name);
    key.schema.deinit(gpa);
    gpa.destroy(key);
}

/// Update the manager pointer inside an already-allocated `PluginToolKey`
/// to track the App's `plugin_manager` field across reassignments. The
/// slot allocated in `allocPluginToolKey` stays at the same address; only
/// its `.*` is rewritten. Called from `registerPluginTools` after every
/// `app.plugin_manager = PluginManager.init(...)`.
/// No-op retained as a marker so callers can still use a uniform rebind
/// pattern; kept here only to make it obvious that the manager indirection
/// was removed on purpose.
pub fn rebindPluginToolKey(_: *PluginToolKey, _: *PluginManager) void {}

/// Build the `lua__<plugin>__<tool>` full name for a tool. Returns an
/// owned slice the caller must free.
pub fn buildPluginToolName(
    gpa: std.mem.Allocator,
    plugin_name: []const u8,
    tool_name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(gpa, "lua__{s}__{s}", .{ plugin_name, tool_name });
}

/// Allocate and initialize a `PluginToolKey` for a freshly-discovered tool.
fn allocPluginToolKey(
    gpa: std.mem.Allocator,
    plugin_name: []const u8,
    tool_name: []const u8,
) !*PluginToolKey {
    const key = try gpa.create(PluginToolKey);
    errdefer gpa.destroy(key);
    const owned_plugin_name = try gpa.dupe(u8, plugin_name);
    errdefer gpa.free(owned_plugin_name);
    key.* = .{
        .plugin_name = owned_plugin_name,
        .tool_name = try gpa.dupe(u8, tool_name),
    };
    return key;
}

/// Shared dispatcher for every plugin tool. The `Env.userdata` argument
/// carries the `*PluginToolKey` set at registration time; the live
/// `*PluginManager` comes from `Env.ctx.plugin_manager` — the executor-owned
/// runtime context, always the App's current field.
pub fn runPluginTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    args: []const u8,
    env: tools_common.Env,
) tools_common.Error!tools_common.Output {
    _ = cwd;
    _ = io;
    const key: *PluginToolKey = @ptrCast(@alignCast(env.userdata));
    const manager = env.ctx.plugin_manager orelse
        return tools_common.fail(gpa, "plugin dispatcher: no live plugin manager"[0..], 1);
    var result = manager.callTool(
        key.plugin_name[0..],
        key.tool_name[0..],
        args,
    ) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return tools_common.failFmt(
            gpa,
            1,
            "plugin tool '{s}.{s}' failed: {s}",
            .{ key.plugin_name, key.tool_name, @errorName(err) },
        );
    };
    errdefer result.deinit(gpa);
    const stderr = try gpa.alloc(u8, 0);
    const stdout = result.text;
    result.text = undefined;
    return .{ .stdout = stdout, .stderr = stderr, .code = result.code };
}

/// Human display metadata for a plugin tool. The `Env.userdata` carries the
/// `(plugin_name, tool_name)` key set at registration time.
pub fn displayPluginTool(
    gpa: std.mem.Allocator,
    args: []const u8,
    env: tools_common.Env,
) std.mem.Allocator.Error!tools_common.ToolDisplay {
    const key: *PluginToolKey = @ptrCast(@alignCast(env.userdata));
    if (args.len == 0) return .{ .label = try gpa.dupe(u8, key.tool_name) };
    return .{
        .label = try gpa.dupe(u8, key.tool_name),
        .expanded_label = try std.fmt.allocPrint(gpa, "{s} {s}", .{ key.tool_name, args }),
    };
}

/// Build a single `Tool` descriptor for one plugin tool. The returned
/// `Tool.userdata` is a heap-allocated `*PluginToolKey`; ownership
/// transfers to the registry through `ToolRegistry.addPluginTool`. The
/// returned `name` and `description` are owned and freed by the registry
/// when the tool is removed. `desc` is copied.
pub fn buildPluginTool(
    gpa: std.mem.Allocator,
    plugin: *PluginInstance,
    tool_name: []const u8,
    desc: []const u8,
    schema: tools_common.Schema,
) !Tool {
    const full_name = try buildPluginToolName(gpa, plugin.manifest.name, tool_name);
    errdefer gpa.free(full_name);
    const desc_owned = try gpa.dupe(u8, desc);
    errdefer gpa.free(desc_owned);
    const key = try allocPluginToolKey(gpa, plugin.manifest.name, tool_name);
    errdefer freePluginToolKey(gpa, @ptrCast(key));
    key.schema = try schema.clone(gpa);
    return .{
        .name = full_name,
        .description = desc_owned,
        .schema = key.schema,
        .run = runPluginTool,
        .display = displayPluginTool,
        .userdata = @ptrCast(key),
        .userdata_free = freePluginToolKey,
    };
}

/// Walk every active plugin in `manager`, materialize one `Tool` per
/// registered handler, and return them as a freshly-allocated slice.
/// Each `Tool` carries an owned `*PluginToolKey` (freed via
/// `userdata_free`) and owned `name` / `description` strings (freed by
/// the caller when the tool is removed from the registry). The slice
/// itself is freed by the caller with `gpa.free`.
pub fn buildPluginToolDescriptors(
    gpa: std.mem.Allocator,
    manager: *PluginManager,
) ![]Tool {
    try manager.beginUse();
    defer manager.endUse();
    var out: std.ArrayList(Tool) = .empty;
    errdefer {
        for (out.items) |*tool| {
            if (tool.userdata_free) |free_fn| free_fn(gpa, tool.userdata);
            gpa.free(tool.name);
            gpa.free(tool.description);
        }
        out.deinit(gpa);
    }
    var iter = manager.iterator();
    while (iter.next()) |entry| {
        const plugin = entry.value_ptr.*;
        if (!plugin.active) continue;
        for (plugin.tool_snapshots) |snapshot| {
            const tool = try buildPluginTool(gpa, plugin, snapshot.name, snapshot.description, snapshot.schema);
            errdefer {
                freePluginToolKey(gpa, tool.userdata);
                gpa.free(tool.name);
                gpa.free(tool.description);
            }
            try out.append(gpa, tool);
        }
    }
    return out.toOwnedSlice(gpa);
}

test "buildPluginToolName: formats lua__<plugin>__<tool>" {
    const gpa = std.testing.allocator;
    const name = try buildPluginToolName(gpa, "hello-world", "greet");
    defer gpa.free(name);
    try std.testing.expectEqualStrings("lua__hello-world__greet", name);
}

test "PluginManager: init+deinit cycle (no plugins)" {
    // The refactor splits `App.init`'s placeholder plugin_manager (empty
    // home/cwd) from `App.initRuntime`'s real one. Both must clean up
    // independently so a second initRuntime doesn't double-free.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var m1 = PluginManager.init(gpa, io, "", "");
    defer m1.deinit();
    var m2 = PluginManager.init(gpa, io, "/tmp", "/tmp");
    defer m2.deinit();
    try std.testing.expect(m1.plugins.count() == 0);
    try std.testing.expect(m2.plugins.count() == 0);
}

test "buildPluginToolDescriptors: returns empty slice when no plugins" {
    var manager = PluginManager.init(std.testing.allocator, std.testing.io, "", "");
    defer manager.deinit();
    const descs = try buildPluginToolDescriptors(std.testing.allocator, &manager);
    try std.testing.expectEqual(@as(usize, 0), descs.len);
}

test "PluginManager: heap-allocated tool registry round-trip" {
    // The App holds a `*ToolRegistry` (heap-allocated) that plugin tools
    // get appended to. This test mirrors that flow: create a registry,
    // build descriptors from a (mock) plugin manager, append them, and
    // free the registry — verifying the lifetime is correct.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var manager = PluginManager.init(gpa, io, "", "");
    defer manager.deinit();

    const reg = try gpa.create(tools_mod.ToolRegistry);
    defer {
        reg.deinit(gpa);
        gpa.destroy(reg);
    }
    reg.* = try tools_mod.ToolRegistry.init(gpa, tools_mod.builtinRegistry());

    const descs = try buildPluginToolDescriptors(gpa, &manager);
    defer {
        for (descs) |*t| {
            if (t.userdata_free) |f| f(gpa, t.userdata);
            gpa.free(t.name);
            gpa.free(t.description);
        }
        gpa.free(descs);
    }
    // all() should not crash and the slice should include the builtin
    // shell tool (pwsh on Windows, bash elsewhere) plus any plugin tools
    // (none in this case).
    const all = try reg.all(gpa);
    try std.testing.expect(all.len >= 1);
    try std.testing.expectEqualStrings(tools_mod.shellToolName, all[0].name);
}
