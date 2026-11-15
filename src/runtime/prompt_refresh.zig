//! AgentRuntime prompt-refresh spoke, extracted from runtime.zig (issue #367
//! slice 13). Owns turn-scoped context reassembly: `reconcilePluginPrompts`
//! (plugin prompt set re-selection after a plugin repoint/reload) and
//! `refreshSystemPrompt` (the snapshot-guarded Git/rules refresh).
//!
//! The `AgentRuntime` TYPE and all of its state stay in runtime.zig; this
//! file imports runtime.zig only for the type. Spoke pattern
//! (runtime/connection.zig, runtime/session_init.zig): free functions over
//! `*AgentRuntime`; mutual import terminates at the type level; runtime.zig
//! keeps unchanged-signature method delegates for the externally-called
//! surface (tui.zig, tui/session_switcher.zig, tui/agent_worker.zig).

const std = @import("std");

const runtime_mod = @import("../runtime.zig");
const context_assembly = @import("../context/assembly.zig");
const paths = @import("../paths.zig");
const plugin_prompt = @import("../plugin_prompt.zig");
const plugin_manager_mod = @import("../lua/manager.zig");

const AgentRuntime = runtime_mod.AgentRuntime;

/// Refresh turn-scoped context on the worker, before user messages enter
/// history. A failed assembly leaves the last-good prompt untouched.
/// Startup/repoint only: callers must keep lane turns quiescent. Prompts
/// describe the loaded physical copy, rather than another copy with the
/// same manifest name. Standalone text directories remain supported.
pub fn reconcilePluginPrompts(self: *AgentRuntime, manager: *const plugin_manager_mod.PluginManager) !void {
    var selected: std.ArrayList(plugin_prompt.PluginPrompt) = .empty;
    defer selected.deinit(self.gpa);
    for (self.plugin_prompts) |prompt| {
        if (prompt.associated_plugin) {
            const instance = manager.plugins.get(prompt.name) orelse continue;
            if (!instance.active) continue;
            const directory = std.fs.path.dirname(prompt.path) orelse continue;
            if (!paths.pathsEqual(directory, instance.dir_path)) continue;
        }
        try selected.append(self.gpa, prompt);
    }
    if (selected.items.len == self.plugin_prompts.len) return;
    const prompts = try plugin_prompt.cloneAll(self.gpa, selected.items);
    errdefer plugin_prompt.deinitAll(self.gpa, prompts);
    const next = try context_assembly.assembleSystemPrompt(self.gpa, self.io, self.base_system_prompt, self.home_dir, self.cwd, self.skills, prompts);
    errdefer self.gpa.free(next);
    try self.client.updateSystemPrompt(next);
    try self.agent.replaceSystem(next);
    plugin_prompt.deinitAll(self.gpa, self.plugin_prompts);
    self.plugin_prompts = prompts;
    self.gpa.free(self.system_prompt);
    self.system_prompt = next;
    if (self.refresh_snapshot) |*snapshot| snapshot.deinit(self.gpa);
    self.refresh_snapshot = null;
}

pub fn refreshSystemPrompt(self: *AgentRuntime, cwd: []const u8) !void {
    var next_snapshot = try context_assembly.captureRefreshSnapshot(self.gpa, self.io, self.home_dir, cwd);
    errdefer next_snapshot.deinit(self.gpa);
    if (self.refresh_snapshot) |*current| {
        if (current.eql(&next_snapshot)) {
            next_snapshot.deinit(self.gpa);
            return;
        }
    }

    const next = try context_assembly.assembleSystemPromptForRefresh(
        self.gpa,
        self.io,
        self.base_system_prompt,
        self.home_dir,
        cwd,
        self.skills,
        self.plugin_prompts,
        &next_snapshot,
    );
    errdefer self.gpa.free(next);

    var verified_snapshot = try context_assembly.captureRefreshSnapshot(self.gpa, self.io, self.home_dir, cwd);
    defer verified_snapshot.deinit(self.gpa);
    if (!next_snapshot.eql(&verified_snapshot)) return error.RefreshInputsChanged;

    if (std.mem.eql(u8, next, self.system_prompt)) {
        self.gpa.free(next);
        if (self.refresh_snapshot) |*current| current.deinit(self.gpa);
        self.refresh_snapshot = next_snapshot;
        return;
    }

    // The concrete Responses clients own a separate `instructions` copy.
    // Allocate/update it before mutating the cached Agent history.
    try self.client.updateSystemPrompt(next);
    try self.agent.replaceSystem(next);

    self.gpa.free(self.system_prompt);
    self.system_prompt = next;
    if (self.refresh_snapshot) |*current| current.deinit(self.gpa);
    self.refresh_snapshot = next_snapshot;
}

test "plugin prompts exclude failed and shadowed copies and survive lane cloning" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const package = @import("../plugin_package.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const process_cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(process_cwd);
    const root = try std.fs.path.join(gpa, &.{ process_cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root);
    const fixtures = [_][2][]const u8{
        .{ ".config/zay/plugins/shadow/plugin.lua", "return {name='shadow',version='1'}" },
        .{ ".config/zay/plugins/shadow/init.lua", "return {}" },
        .{ ".config/zay/plugins/shadow/prompt.md", "Global shadow instructions." },
        .{ "plugins/shadow/plugin.lua", "return {name='shadow',version='2'}" },
        .{ "plugins/shadow/init.lua", "error('failed override')" },
        .{ "plugins/shadow/prompt.md", "Failed override instructions." },
        .{ "plugins/good/plugin.lua", "return {name='good',version='1'}" },
        .{ "plugins/good/init.lua", "return {}" },
        .{ "plugins/good/prompt.md", "Working tool instructions." },
        .{ "plugins/standalone/prompt.md", "Standalone instructions." },
    };
    for (fixtures) |fixture| {
        const path = try std.fs.path.join(gpa, &.{ root, fixture[0] });
        defer gpa.free(path);
        try package.atomicWrite(io, path, fixture[1]);
    }
    var runtime: AgentRuntime = undefined;
    try runtime.initNew(.{
        .gpa = gpa,
        .io = io,
        .cwd = root,
        .home_dir = root,
        .session_dir = root,
        .base_system_prompt = "Test system prompt.",
        .host_id = "test-host",
        .config = .{},
        .diagnostics = &.{},
    });
    defer runtime.deinit();
    var manager = plugin_manager_mod.PluginManager.init(gpa, io, root, root);
    defer manager.deinit();
    _ = try manager.loadAll();
    try std.testing.expectEqualStrings("1", manager.plugins.get("shadow").?.manifest.version);
    try runtime.reconcilePluginPrompts(&manager);
    try std.testing.expectEqual(@as(usize, 3), runtime.plugin_prompts.len);
    try std.testing.expect(std.mem.indexOf(u8, runtime.system_prompt, "Global shadow instructions.") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.system_prompt, "Working tool instructions.") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.system_prompt, "Standalone instructions.") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.system_prompt, "Failed override instructions.") == null);
    const cloned = try plugin_prompt.cloneAll(gpa, runtime.plugin_prompts);
    defer plugin_prompt.deinitAll(gpa, cloned);
    try std.testing.expectEqual(@as(usize, 3), cloned.len);
    for (runtime.plugin_prompts, cloned) |original, copy| {
        try std.testing.expectEqualStrings(original.path, copy.path);
        try std.testing.expectEqual(original.associated_plugin, copy.associated_plugin);
    }
}
