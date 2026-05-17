const std = @import("std");

pub const agent = @import("agent.zig");
pub const ai = @import("ai.zig");
pub const bash = @import("bash.zig");
pub const db = @import("db.zig");
pub const executor = @import("executor.zig");
pub const search = @import("search.zig");
pub const session = @import("session.zig");
pub const runtime = @import("runtime.zig");
pub const thread = @import("thread.zig");
pub const tools = @import("tools.zig");
pub const tui = @import("tui.zig");

/// The flat, OpenAI-shaped configuration `nova.run` consumes. When a
/// second LM adapter arrives, this evolves to carry an `LmConfig` union;
/// today the single-variant shape is the simplest user-facing surface.
pub const Config = struct {
    base_url: []const u8 = "https://api.openai.com",
    api_key: []const u8 = "",
    model: []const u8 = "gpt-5.5",
    /// When null, the embedded `src/prompts/system.md` is used.
    system_prompt: ?[]const u8 = null,

    /// Derive a Config from `OPENAI_BASE_URL` / `OPENAI_API_KEY` /
    /// `OPENAI_MODEL` env vars, with sensible defaults. Embedders that
    /// don't want env lookups construct a `Config{ ... }` literal directly.
    /// `env` is `anytype` to accept whatever shape `std.process.Init`
    /// exposes for its environment map across Zig versions.
    pub fn fromEnv(env: anytype) Config {
        return .{
            .base_url = env.get("OPENAI_BASE_URL") orelse "https://api.openai.com",
            .api_key = env.get("OPENAI_API_KEY") orelse "",
            .model = env.get("OPENAI_MODEL") orelse "gpt-5.5",
        };
    }
};

/// The single user-facing entry point. Wires `openai.Client` →
/// `ExecutorService` (via the agent's internal bridge) → `Agent` → TUI,
/// then blocks until the TUI exits. Embedders that need a different
/// listener (headless mode, FFI shim, test harness) drop down to
/// `Agent.run(listener)` directly with their own `Agent.Listener`.
pub fn run(init: std.process.Init, gpa: std.mem.Allocator, config: Config) !void {
    const cwd = try std.process.currentPathAlloc(init.io, gpa);
    defer gpa.free(cwd);

    const runtime_gpa = std.heap.smp_allocator;

    var openai_client: ai.openai.Client = undefined;
    try openai_client.init(runtime_gpa, init.io, .{
        .base_url = config.base_url,
        .api_key = config.api_key,
        .model = config.model,
        .tools = tools.registry,
    });
    defer openai_client.deinit();

    search.start(gpa, cwd);
    defer search.deinit(gpa);

    const system_prompt = config.system_prompt orelse @embedFile("prompts/system.md");
    const agent_runtime = try gpa.create(runtime.AgentRuntime);
    try agent_runtime.initNew(runtime_gpa, init.io, cwd, .{ .openai = &openai_client }, system_prompt);

    try tui.run(init, agent_runtime);
}

test {
    std.testing.refAllDecls(@This());
}
