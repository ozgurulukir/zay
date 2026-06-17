const std = @import("std");

pub const agent = @import("agent.zig");
pub const ai = @import("ai.zig");
pub const at_mention = @import("at_mention.zig");
pub const bash = @import("bash.zig");
pub const codex = @import("codex.zig");
pub const compaction = @import("compaction.zig");
pub const config = @import("config.zig");
pub const context = @import("context.zig");
pub const db = @import("db.zig");
pub const executor = @import("executor.zig");
pub const os = @import("os.zig");
pub const search = @import("search.zig");
pub const session = @import("session.zig");
pub const skill = @import("skill.zig");
pub const symbols = @import("symbols.zig");
pub const terminal_markdown = @import("terminal_markdown");
pub const logger = @import("logger");
pub const runtime = @import("runtime.zig");
pub const jj = @import("jj.zig");
pub const transcript = @import("transcript.zig");
pub const tools = @import("tools.zig");
pub const tui = @import("tui.zig");
pub const thread = @import("tui/thread.zig");

pub fn run(init: std.process.Init, gpa: std.mem.Allocator) !void {
    if (logger.enabled) {
        if (resolveLogPath(gpa, init.environ_map)) |log_path| {
            defer gpa.free(log_path);
            try logger.init(.{ .io = init.io, .log_path = log_path });
        } else |_| {}
    }
    defer logger.deinit();

    const cwd = try std.process.currentPathAlloc(init.io, gpa);
    defer gpa.free(cwd);

    const home_dir = try resolveHomeDir(gpa, init.environ_map);
    defer gpa.free(home_dir);

    var load_result = try config.load(gpa, init.io, cwd, home_dir, init.environ_map);
    // The TUI is long-running and streams unbounded content, so it must use a
    // real freeing allocator — an arena never reclaims, and `Transcript`'s
    // streaming-body `realloc` degrades to O(N²) abandoned buffers on one (see
    // `appendOwned` in transcript.zig). `smp_allocator` is a thread-safe global
    // singleton, so this matches `App.gpa` (tui.zig) exactly — required because
    // `agent_runtime`/`tui_config` are allocated here and freed in `App.deinit`.
    const tui_gpa = std.heap.smp_allocator;
    const tui_config = try load_result.config.cloneForTui(tui_gpa);

    const runtime_gpa = std.heap.smp_allocator;

    defer search.deinit(runtime_gpa, init.io);

    const system_prompt = if (load_result.config.system_prompt) |s| s else @embedFile("prompts/system.md");
    const agent_runtime = try tui_gpa.create(runtime.AgentRuntime);
    errdefer tui_gpa.destroy(agent_runtime);
    try agent_runtime.initNew(
        runtime_gpa,
        init.io,
        cwd,
        home_dir,
        system_prompt,
        load_result.config,
        load_result.takeDiagnostics(),
    );
    load_result.config.deinit(gpa);

    try tui.run(init, agent_runtime, tui_config);
}

fn resolveLogPath(gpa: std.mem.Allocator, env: anytype) ![]u8 {
    if (env.get("NOVA_LOG_FILE")) |path| return gpa.dupe(u8, path);
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return error.HomeNotSet;
    return std.fs.path.join(gpa, &.{ home, ".nova", "nova.log" });
}

fn resolveHomeDir(gpa: std.mem.Allocator, env: anytype) std.mem.Allocator.Error![]u8 {
    if (env.get("HOME")) |home| return gpa.dupe(u8, home);
    if (env.get("USERPROFILE")) |home| return gpa.dupe(u8, home);
    return gpa.dupe(u8, "");
}

test {
    std.testing.refAllDecls(@This());
}
