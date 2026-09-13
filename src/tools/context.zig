//! Per-runtime execution context handed to every `Tool.run` / `Tool.display`
//! callback through `Tool.Env`. This is the tool-context seam: the
//! dependencies a tool needs at run time live in one record owned by the
//! executor, instead of being routed around the fixed `*const fn` signature
//! through per-tool thread-local slots.
//!
//! Lifetime: the executor owns the record and passes `&executor.ctx` — it
//! outlives every call dispatched through it. Fields are borrowed pointers;
//! nothing here is freed by the tools.

const std = @import("std");

const lane_bridge = @import("lane_bridge.zig");
const background = @import("../background.zig");
const skill_mod = @import("../skill.zig");
const plugin_manager_mod = @import("../lua/manager.zig");
const mcp_mod = @import("../mcp/manager.zig");

pub const ToolContext = struct {
    /// `lane` tool: the App-owned bridge plus the requesting agent (as
    /// `*anyopaque`) that identifies the lane for the role guard and
    /// completion routing. Null both = headless/tests → the tool reports
    /// that lanes are unavailable.
    lane_bridge: ?*lane_bridge.LaneBridge = null,
    lane_requester: ?*anyopaque = null,
    /// `background` tool, plus the shell tool's `run_in_background` routing.
    background_manager: ?*background.BackgroundManager = null,
    /// Lane generation identifying the job owner; handed back at completion
    /// so the UI routes delivery to the right lane.
    owner_generation: u64 = 1,
    /// `skill` tool: the runtime's loaded skills. Empty = no runtime attached.
    skills: []const skill_mod.Skill = &.{},
    /// Plugin tool dispatch (`registry_bridge.runPluginTool`). Null = plugin
    /// tools report that no live manager exists (never invoke a freed one).
    plugin_manager: ?*plugin_manager_mod.PluginManager = null,
    /// Plugin cwd: the source of truth for the Lua bridge's derived
    /// `plugin_cwd_slot` binding (same value as the executor `cwd` snapshot;
    /// refreshed by `rerootFromRequester` on mid-batch lane ops).
    plugin_cwd: ?[]const u8 = null,
    /// Shell-safety classifier URL for plugin `zay.run_bash` shells; also the
    /// source of the derived `bash_classifier_url_slot` binding. Null keeps
    /// the always-armed local matcher.
    bash_classifier_url: ?[]const u8 = null,
    /// MCP dispatch: resolved at dispatch time through the manager so
    /// registry records survive client reconnects.
    mcp_manager: ?*mcp_mod.McpManager = null,

    /// Shared no-context value for tests and headless fallbacks: every
    /// optional field is null, so tools degrade exactly as they did when the
    /// slots were unset. Its address is stable, so `Env{ .ctx = &ToolContext.headless }`
    /// is valid from anywhere.
    pub const headless: ToolContext = .{};
};

test "headless context degrades every dependency" {
    const ctx = &ToolContext.headless;
    try std.testing.expect(ctx.lane_bridge == null);
    try std.testing.expect(ctx.lane_requester == null);
    try std.testing.expect(ctx.background_manager == null);
    try std.testing.expectEqual(@as(u64, 1), ctx.owner_generation);
    try std.testing.expectEqual(@as(usize, 0), ctx.skills.len);
    try std.testing.expect(ctx.plugin_manager == null);
    try std.testing.expect(ctx.mcp_manager == null);
    try std.testing.expect(ctx.plugin_cwd == null);
    try std.testing.expect(ctx.bash_classifier_url == null);
}
