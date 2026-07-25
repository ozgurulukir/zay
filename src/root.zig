const std = @import("std");

pub const agent = @import("agent.zig");
pub const ai = @import("ai.zig");
pub const at_mention = @import("at_mention.zig");
pub const background = @import("background.zig");
pub const bash = @import("bash.zig");
pub const local_models = @import("local_models.zig");
pub const bash_safety = @import("bash_safety.zig");
pub const clipboard = @import("clipboard.zig");
pub const codex = @import("codex.zig");
pub const compaction = @import("compaction.zig");
pub const config = @import("config.zig");
pub const context = @import("context.zig");
pub const context_assembly = @import("context_assembly.zig");
pub const db = @import("db.zig");
pub const executor = @import("executor.zig");
pub const os = @import("os.zig");
pub const pytools = @import("pytools.zig");
pub const search = @import("search.zig");
pub const session = @import("session.zig");
pub const skill = @import("skill.zig");
pub const symbols = @import("symbols.zig");
pub const terminal_markdown = @import("terminal_markdown");
pub const logger = @import("logger");
pub const mcp = @import("mcp/manager.zig");
pub const mcp_client = @import("mcp/client.zig");
pub const mcp_transport = @import("mcp/transport.zig");
pub const runtime = @import("runtime.zig");
pub const vcs = @import("vcs.zig");
pub const transcript = @import("transcript.zig");
pub const tools = @import("tools.zig");
pub const tui = @import("tui.zig");
pub const thread = @import("tui/thread.zig");

pub fn run(init: std.process.Init, gpa: std.mem.Allocator) !void {
    @import("bash.zig").disablePseudoConsole();

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
    var local_models_handle: ?local_models.Server = null;
    {
        const classifier_set = if (load_result.config.model_selection) |*ms|
            (ms.bash_classifier_url != null)
        else
            true;
        if (!classifier_set) {
            local_models_handle = try local_models.ensure(gpa, init.io, cwd);
            errdefer if (local_models_handle) |*server| server.deinit(gpa, init.io);
            if (local_models_handle) |server| {
                if (load_result.config.model_selection) |*ms| {
                    ms.bash_classifier_url = try gpa.dupe(u8, server.url);
                }
            }
        }
    }
    defer if (local_models_handle) |*server| server.deinit(gpa, init.io);

    // The TUI is long-running and streams unbounded content. `SmpAllocator`
    // (Zig 0.16) has a known multi-threaded free-list corruption bug that
    // panics with "incorrect alignment"; `PageAllocator` is the safe fallback:
    // thread-safe, actually frees memory, but each allocation maps a whole page.
    const tui_gpa = gpa;
    const tui_config = try load_result.config.cloneForTui(tui_gpa);
    const runtime_gpa = gpa;

    defer search.deinit(runtime_gpa, init.io);

    const system_prompt = if (load_result.config.model_selection) |ms|
        (ms.system_prompt orelse @embedFile("prompts/system.md"))
    else
        @embedFile("prompts/system.md");
    const agent_runtime = try tui_gpa.create(runtime.AgentRuntime);
    errdefer tui_gpa.destroy(agent_runtime);

    // Auth integrity: prune orphan keys that no longer correspond to any
    // known provider. Builtin labels are always valid; config provider
    // names and the current dynamic_provider_id are collected as the
    // valid set. Idempotent — running again after a prune removes nothing.
    {
        var valid_names: std.ArrayList([]const u8) = .empty;
        defer valid_names.deinit(runtime_gpa);
        for (config.allBuiltinLabels()) |label| {
            valid_names.append(runtime_gpa, label) catch continue;
        }
        for (load_result.config.providers) |p| {
            valid_names.append(runtime_gpa, p.name) catch continue;
        }
        if (load_result.config.dynamic_provider_id) |id| {
            valid_names.append(runtime_gpa, id) catch {};
        }
        const pruned = codex.pruneOrphanKeys(runtime_gpa, init.io, home_dir, valid_names.items) catch 0;
        if (pruned > 0) {
            logger.log("auth.integrity.pruned count={d}", .{pruned});
        }
    }

    // Auto-resume: find the most recently updated session for this cwd.
    const resume_session_id = blk: {
        var manager = session.SessionManager.initDefault(runtime_gpa, init.io, home_dir) catch break :blk null;
        defer manager.deinit();
        const id = manager.findLatest(runtime_gpa, cwd) catch null;
        break :blk id;
    };
    if (resume_session_id) |id| {
        defer runtime_gpa.free(id);
        agent_runtime.initResume(
            runtime_gpa,
            init.io,
            cwd,
            cwd,
            home_dir,
            system_prompt,
            load_result.config,
            load_result.takeDiagnostics(),
            id,
            null,
        ) catch |err| {
            std.log.warn("session.resume.failed err={s}, starting new session", .{@errorName(err)});
            try agent_runtime.initNew(
                runtime_gpa,
                init.io,
                cwd,
                cwd,
                home_dir,
                system_prompt,
                load_result.config,
                load_result.takeDiagnostics(),
                null,
            );
        };
    } else {
        try agent_runtime.initNew(
            runtime_gpa,
            init.io,
            cwd,
            cwd,
            home_dir,
            system_prompt,
            load_result.config,
            load_result.takeDiagnostics(),
            null,
        );
    }
    load_result.config.deinit(gpa);

    try tui.run(init, agent_runtime, tui_config, tui_gpa);
}

fn resolveLogPath(gpa: std.mem.Allocator, env: anytype) ![]u8 {
    if (env.get("NOVA_LOG_FILE")) |path| return gpa.dupe(u8, path);
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return error.HomeNotSet;
    return std.fs.path.join(gpa, &.{ home, ".config", "nova", "nova.log" });
}

fn resolveHomeDir(gpa: std.mem.Allocator, env: anytype) std.mem.Allocator.Error![]u8 {
    if (env.get("HOME")) |home| return gpa.dupe(u8, home);
    if (env.get("USERPROFILE")) |home| return gpa.dupe(u8, home);
    return gpa.dupe(u8, "");
}

test {
    std.testing.refAllDecls(@This());
}
