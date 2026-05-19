const std = @import("std");

pub const agent = @import("agent.zig");
pub const ai = @import("ai.zig");
pub const bash = @import("bash.zig");
pub const codex = @import("codex.zig");
pub const db = @import("db.zig");
pub const executor = @import("executor.zig");
pub const search = @import("search.zig");
pub const session = @import("session.zig");
pub const logger = @import("logger");
pub const runtime = @import("runtime.zig");
pub const thread = @import("thread.zig");
pub const tools = @import("tools.zig");
pub const tui = @import("tui.zig");

const default_openai_endpoint = "https://api.openai.com";
const default_model = "gpt-5.5";

/// The flat, OpenAI-shaped configuration `nova.run` consumes. When a
/// second LM adapter arrives, this evolves to carry an `LmConfig` union;
/// today the single-variant shape is the simplest user-facing surface.
pub const Config = struct {
    base_url: []const u8 = default_openai_endpoint,
    api_key: []const u8 = "",
    model: []const u8 = "gpt-5.5",
    use_responses_endpoint: bool = false,
    reasoning: ?ai.Reasoning = .{},
    /// When null, the embedded `src/prompts/system.md` is used.
    system_prompt: ?[]const u8 = null,

    /// Derive a Config from `OPENAI_BASE_URL` / `OPENAI_API_KEY` /
    /// `OPENAI_MODEL` env vars, with sensible defaults. Embedders that
    /// don't want env lookups construct a `Config{ ... }` literal directly.
    /// `env` is `anytype` to accept whatever shape `std.process.Init`
    /// exposes for its environment map across Zig versions.
    pub fn fromEnv(env: anytype) Config {
        return .{
            .base_url = env.get("OPENAI_BASE_URL") orelse default_openai_endpoint,
            .api_key = env.get("OPENAI_API_KEY") orelse "",
            .model = env.get("OPENAI_MODEL") orelse default_model,
            .use_responses_endpoint = if (env.get("USE_RESPONSES_ENDPOINT")) |value| std.mem.eql(u8, value, "1") else false,
        };
    }
};

/// The single user-facing entry point. Wires `openai_compatible.Client` →
/// `ExecutorService` (via the agent's internal bridge) → `Agent` → TUI,
/// then blocks until the TUI exits. Embedders that need a different
/// listener (headless mode, FFI shim, test harness) drop down to
/// `Agent.run(listener)` directly with their own `Agent.Listener`.
pub fn run(init: std.process.Init, gpa: std.mem.Allocator, config: Config) !void {
    defer logger.deinit();
    const cwd = try std.process.currentPathAlloc(init.io, gpa);
    defer gpa.free(cwd);

    const runtime_gpa = std.heap.smp_allocator;

    var openai_compatible_client: ai.openai_compatible.Client = undefined;
    var openai_responses_client: ai.openai_responses.Client = undefined;
    const client: ai.LanguageModel = if (config.use_responses_endpoint) blk: {
        try openai_responses_client.init(runtime_gpa, init.io, .{
            .base_url = config.base_url,
            .api_key = config.api_key,
            .model = config.model,
            .tools = tools.registry,
            .reasoning = config.reasoning,
            .system_prompt = config.system_prompt orelse @embedFile("prompts/system.md"),
        });
        break :blk .{ .openai_responses = &openai_responses_client };
    } else blk: {
        try openai_compatible_client.init(runtime_gpa, init.io, .{
            .base_url = config.base_url,
            .api_key = config.api_key,
            .model = config.model,
            .tools = tools.registry,
            .reasoning = config.reasoning,
        });
        break :blk .{ .openai_compatible = &openai_compatible_client };
    };
    defer switch (client) {
        .codex_responses => unreachable,
        .openai_compatible => openai_compatible_client.deinit(),
        .openai_responses => openai_responses_client.deinit(),
    };

    search.start(gpa, cwd);
    defer search.deinit(gpa);

    const system_prompt = config.system_prompt orelse @embedFile("prompts/system.md");
    const agent_runtime = try gpa.create(runtime.AgentRuntime);
    try agent_runtime.initNew(runtime_gpa, init.io, cwd, client, system_prompt);

    try tui.run(init, agent_runtime);
}

test {
    std.testing.refAllDecls(@This());
}
