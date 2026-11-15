//! AgentRuntime session-init spoke, extracted from runtime.zig (issue #367
//! slice 13). Owns session birth/resume/reload: `initSession` (the full
//! birth path — owned prompt/cwd/skills/plugin-prompts assembly, the
//! `target.* = .{...}` literal, diagnostics logging, the models.dev
//! registry, the session store wiring, agent construction with its config
//! knob planting, and the resume-vs-new attach dispatch),
//! `restoreResumedModel` (the overwrite-in-arena model restore), and
//! `reloadMessages` (branch rehydration).
//!
//! The `AgentRuntime` TYPE and all of its state stay in runtime.zig; this
//! file imports runtime.zig only for the type (and `Genesis`). Spoke
//! pattern (runtime/connection.zig, mcp/lifecycle.zig): free functions over
//! `*AgentRuntime`; mutual import terminates at the type level; runtime.zig
//! keeps unchanged-signature method delegates for the externally-called
//! surface (`initNew`/`initResume` dispatch to `initSession`;
//! `reloadMessages` is called by tui/session_switcher). Teardown stays in
//! the hub: `deinit` keeps its call positions, pinned by connection.zig's
//! header doc. Log scope stays `.runtime`, identical to runtime.zig.

const std = @import("std");
const log = std.log.scoped(.runtime);

const runtime_mod = @import("../runtime.zig");
const agent_mod = @import("../agent.zig");
const ai = @import("../ai.zig");
const context_assembly = @import("../context/assembly.zig");
const config_mod = @import("../config/config.zig");
const modelsdev = @import("../models/registry.zig");
const plugin_prompt = @import("../plugin_prompt.zig");
const session_mod = @import("../session.zig");
const skill_mod = @import("../skill.zig");

const AgentRuntime = runtime_mod.AgentRuntime;
const assert = std.debug.assert;

/// Session birth/resume: shared entry for `initNew` and `initResume` (the
/// hub asserts on the genesis invariants before dispatching here).
pub fn initSession(target: *AgentRuntime, genesis: AgentRuntime.Genesis) !void {
    const gpa = genesis.gpa;
    const io = genesis.io;
    const cwd = genesis.cwd;
    const session_dir = genesis.session_dir;
    const home_dir = genesis.home_dir;
    const base_system_prompt = genesis.base_system_prompt;
    const config = genesis.config;
    const diagnostics = genesis.diagnostics;
    const session_id = genesis.session_id;
    const template = genesis.template;
    assert(cwd.len > 0);
    assert(base_system_prompt.len > 0);
    if (session_id) |id| assert(id.len > 0);

    const owned_base_system_prompt = try gpa.dupe(u8, base_system_prompt);
    errdefer gpa.free(owned_base_system_prompt);
    // `cwd` is borrowed from callers that may free it — a cross-project
    // resume hands us `summary.cwd`, and the next `reloadResumeSessions`
    // frees the summaries via `resumeClear`. Own it so the runtime's
    // workspace path can't dangle underneath later reads (e.g. the resume
    // picker's `bindText(1, cwd)`, which sqlite_transient copies at bind).
    const owned_cwd = try gpa.dupe(u8, cwd);
    errdefer gpa.free(owned_cwd);
    // A `template` (the primary lane) shares the same project, so clone its
    // already-loaded skills + plugin prompts + assembled system prompt
    // instead of re-scanning the workspace (which is a checkout of the same repo).
    const skills = if (template) |t| try skill_mod.cloneAll(gpa, t.skills) else try skill_mod.loadProject(gpa, io, home_dir, cwd);
    errdefer skill_mod.deinitAll(gpa, skills);
    const plugin_prompts = if (template) |t| try plugin_prompt.cloneAll(gpa, t.plugin_prompts) else try plugin_prompt.loadConfigured(gpa, io, home_dir, cwd, config.plugins);
    errdefer plugin_prompt.deinitAll(gpa, plugin_prompts);
    // A lane shares the parent's stable skills/plugin prompt inputs, but
    // Git and project rules belong to its own worktree.
    const owned_system_prompt = try context_assembly.assembleSystemPrompt(gpa, io, owned_base_system_prompt, home_dir, owned_cwd, skills, plugin_prompts);
    errdefer gpa.free(owned_system_prompt);
    var refresh_snapshot = context_assembly.captureRefreshSnapshot(gpa, io, home_dir, owned_cwd) catch |err| snapshot: {
        log.warn("context.refresh.initial_snapshot_failed err={s}", .{@errorName(err)});
        break :snapshot null;
    };
    errdefer if (refresh_snapshot) |*snapshot| snapshot.deinit(gpa);

    target.* = .{
        .gpa = gpa,
        .io = io,
        .cwd = owned_cwd,
        .home_dir = home_dir,
        .client = .none,
        .base_system_prompt = owned_base_system_prompt,
        .system_prompt = owned_system_prompt,
        .refresh_snapshot = refresh_snapshot,
        .skills = skills,
        .plugin_prompts = plugin_prompts,
        .session_writer = undefined,
        .agent = undefined,
        .diagnostics = diagnostics,
        .codex_connection_expired = false,
        .strict_outputs = config.strict_outputs orelse false,
        .context_settings = config.context,
        .config_arena = genesis.config_arena,
    };
    // The only other reader of diagnostics is the no-provider submit
    // error, so a dropped config field (oversized systemPrompt / plugin
    // settings, invalid model selection) would otherwise be invisible.
    // Log each one: with the TUI up, warn routes to the toast bus.
    for (diagnostics) |d| {
        switch (d) {
            .config_parse_error => |e| log.warn("config.diagnostic file={s} reason={s}", .{ e.path, e.reason }),
            .bad_env_model => |raw| log.warn("config.diagnostic invalid OPENAI_MODEL={s}", .{raw}),
        }
    }

    // Load the models.dev registry (cache-only, no network) for model
    // capability lookups (reasoning, context window). The TUI's lazy
    // loadOrFetchRegistry refreshes the cache for next time. Skipped in
    // test environments where home_dir is empty.
    if (home_dir.len > 0) {
        target.modelsdev_registry = modelsdev.loadRegistryCached(gpa, io, home_dir);
    }
    // Hoisted out of the `if` above: errdefer is block-scoped, so an
    // inside placement would leak the registry when a later init step
    // fails. On the success path `deinit` frees it; on the error path
    // `deinit` never runs, so exactly one of them applies.
    errdefer if (target.modelsdev_registry) |*reg| reg.deinit(gpa);

    const store: session_mod.SessionStore = genesis.session_store orelse session_mod.SessionStore.fromDatabase(
        config.effectiveDatabaseBackend(),
        config.effectiveDatabaseUrl(),
        config.effectiveDatabaseAuthToken(),
        config.effectiveDatabasePath(),
    );

    if (session_id) |id| {
        // Resume never falls back across stores: an unreachable remote
        // store must fail loudly, not surface a misleading MissingSession.
        try target.session_writer.initResumeFromStore(gpa, io, home_dir, id, store, genesis.host_id);
    } else {
        try target.session_writer.initFromStore(gpa, io, home_dir, session_dir, store, genesis.host_id);
    }
    target.session_writer_started = true;
    errdefer target.session_writer.deinit();

    // The agent must share the runtime's owned cwd, NOT the borrowed
    // `cwd` parameter — a cross-project resume hands us `summary.cwd`,
    // and the next `reloadResumeSessions` frees it via `resumeClear`
    // while the worker thread may still be running tools against it.
    // `agent.deinit` does not free cwd; `deinit` frees `self.cwd` (this
    // same allocation) after the agent, so ownership is unambiguous.
    target.agent = agent_mod.Agent.init(gpa, io, owned_cwd, .none);
    errdefer target.agent.deinit();
    target.agent.skills = target.skills;
    target.agent.compaction_settings = config.context.compaction;
    // Resolved per-agent budget knobs (non-optional on the agent so the
    // run loop never branches on config optionality). Lane worker and
    // resume runtimes all construct through here, so they inherit.
    if (config.context.tool_call_limit_per_turn) |v| target.agent.turn_budget.tool_call_limit_per_turn = v;
    if (config.context.soft_stop_on_tool_call_limit) |b| target.agent.turn_budget.soft_stop_on_tool_call_limit = b;
    if (config.context.auto_continue_on_length_cut) |b| target.agent.turn_budget.auto_continue_on_length_cut = b;
    if (config.model_selection) |ms| {
        if (ms.bashClassifierUrl()) |url| {
            target.agent.bash_classifier_url = try gpa.dupe(u8, url);
        }
    } else if (config.bash_classifier_url) |url| {
        // Legacy-shape config (model_selection null — a partial legacy
        // file or an env-only override): the flat field is the resolved
        // classifier URL (#284). The settings live-sync resolves the
        // same way (`settings_lifecycle.cachedClassifierUrl`), so a save
        // and a restart arm agents identically.
        target.agent.bash_classifier_url = try gpa.dupe(u8, url);
    }
    if (config.effectiveDatabaseUrl()) |url| {
        target.agent.database_server_url = try gpa.dupe(u8, url);
    }
    if (config.effectiveDatabaseAuthToken()) |token| {
        target.agent.database_auth_token = try gpa.dupe(u8, token);
    }
    target.agent.attachSessionWriter(&target.session_writer);
    try target.agent.addSystem(owned_system_prompt);

    if (session_id != null) {
        try reloadMessages(target);
    }

    // When resuming a session, try to restore the model used in that
    // session; a new session attaches straight from the config.
    if (session_id != null) {
        try restoreResumedModel(target, config);
    } else {
        // New session - will save model info after applyFromConfig
        try target.applyFromConfig(config);
    }
}

/// Resolve the model recorded in the session summary onto the config and
/// attach from it: provider (builtin enum, then the providers[] map for
/// custom names), model id, custom base_url, and the session-scoped
/// reasoning effort. Unknown provider or missing model ids degrade to
/// attaching the config as-is — resume is never fatal for restore gaps.
pub fn restoreResumedModel(self: *AgentRuntime, config: config_mod.Config) !void {
    const gpa = self.gpa;
    var summary = try self.session_writer.session.summary(gpa);
    defer summary.deinit(gpa);
    // Resolve the session's stored reasoning effort (if any) so resume
    // restores the exact effort in use at save time. Invalid DB values
    // (newer schema, hand-edited) degrade to "no override" — never fatal.
    const resume_effort: ?ai.ReasoningEffort = if (summary.reasoning_effort) |label|
        (ai.ReasoningEffort.fromString(label) catch null)
    else
        null;
    if (summary.model_provider) |mp| {
        // Resolve the provider: try builtin enum first, then the
        // providers[] config map (custom providers like "qwen-cloud").
        const provider_enum = std.meta.stringToEnum(config_mod.Provider, mp) orelse blk: {
            for (config.providers) |pc| {
                if (std.mem.eql(u8, pc.name, mp)) break :blk pc.provider;
            }
            log.warn("session.resume.unknown_provider: {s}, using config default", .{mp});
            try self.applyFromConfig(config);
            return;
        };

        // Resolve base_url from the providers[] map when the provider
        // is custom (defaultBaseUrl() is null for .openai_compatible).
        var resolved_base_url: []const u8 = provider_enum.defaultBaseUrl() orelse "";
        for (config.providers) |pc| {
            if (!std.mem.eql(u8, pc.name, mp)) continue;
            switch (pc.base_url) {
                .custom => |url| resolved_base_url = url,
                .default => {},
            }
            break;
        }

        var session_config = config;
        if (session_config.model_selection) |*ms| {
            // Overwrite-in-arena: the model id planted into the session
            // config copy is duped into the App config arena when one is
            // installed and never freed — the arena is released wholesale
            // by root after tui.run. Bare test runtimes without an arena
            // keep the gpa dupe→free dance (applyFromConfig duplicates
            // everything it keeps into the client).
            const plant: std.mem.Allocator = self.config_arena orelse gpa;
            const plant_free_on_gpa = self.config_arena == null;
            var planted_mid: ?[]const u8 = null;
            switch (ms.*) {
                .builtin => |*b| {
                    b.provider = provider_enum;
                    b.provider_name = @constCast(mp);
                    if (summary.model_id) |mid| {
                        // mid is borrowed from summary — dupe into the plant allocator.
                        b.model.id = try plant.dupe(u8, mid);
                        planted_mid = b.model.id;
                    }
                },
                .custom => |*c| {
                    c.provider_name = @constCast(mp);
                    if (summary.model_id) |mid| {
                        // mid is borrowed from summary — dupe into the plant allocator.
                        c.model.id = try plant.dupe(u8, mid);
                        planted_mid = c.model.id;
                    }
                    if (c.base_url.len == 0 and resolved_base_url.len > 0) {
                        c.base_url = @constCast(resolved_base_url);
                    }
                },
            }
            // Restore the session's reasoning effort override (if any)
            // onto the selection before applying it to the client.
            if (resume_effort) |effort| {
                switch (ms.*) {
                    .builtin => |*b| b.model.reasoning = .{ .effort = effort },
                    .custom => |*c| c.model.reasoning = .{ .effort = effort },
                }
            }
            // gpa plants must not leak if attach fails mid-restore
            // (arena plants are reclaimed with the arena wholesale).
            errdefer if (plant_free_on_gpa) if (planted_mid) |mid| gpa.free(mid);
            try self.applyFromConfig(session_config);
            // Fallback-only cleanup: the arena-backed plant stays valid
            // for the arena's lifetime, the gpa plant dies with the copy.
            if (plant_free_on_gpa) if (planted_mid) |mid| gpa.free(mid);
        } else {
            const is_builtin = std.meta.stringToEnum(config_mod.Provider, mp) != null;
            if (summary.model_id) |mid| {
                // Overwrite-in-arena (see the branch above): plant the
                // model id into the App config arena when available.
                const plant: std.mem.Allocator = self.config_arena orelse gpa;
                const plant_free_on_gpa = self.config_arena == null;
                // mid is borrowed from summary's internal allocation —
                // dupe it so the selection outlives summary.deinit.
                const planted_mid = try plant.dupe(u8, mid);
                errdefer if (plant_free_on_gpa) gpa.free(planted_mid);
                if (is_builtin) {
                    session_config.model_selection = .{
                        .builtin = .{
                            .provider = provider_enum,
                            .provider_name = @constCast(mp),
                            .model = .{
                                .id = planted_mid,
                                .reasoning = if (resume_effort) |effort| .{ .effort = effort } else .unset,
                            },
                            .use_responses_endpoint = false,
                            .bash_classifier_url = null,
                        },
                    };
                } else {
                    session_config.model_selection = .{
                        .custom = .{
                            .provider_name = @constCast(mp),
                            .base_url = @constCast(resolved_base_url),
                            .api_key = "",
                            .model = .{
                                .id = planted_mid,
                                .reasoning = if (resume_effort) |effort| .{ .effort = effort } else .unset,
                            },
                            .use_responses_endpoint = false,
                            .bash_classifier_url = null,
                        },
                    };
                }
                try self.applyFromConfig(session_config);
                // Free the dupe'd model_id — applyFromConfig dupe'd it
                // again into the client. (Arena plants are never freed.)
                if (plant_free_on_gpa) gpa.free(planted_mid);
            } else {
                // No model_id saved in session — fall back to config's
                // default model rather than synthesizing an empty one.
                try self.applyFromConfig(config);
            }
        }
    } else {
        // No model saved in session, use config as-is
        try self.applyFromConfig(config);
    }
}

/// Rehydrate the agent's conversation from the session's current leaf.
/// Call after `session_writer.navigate(...)` switches branches: clears the
/// in-memory messages (keeping the system prompt) and reloads the new
/// active path. Must not be called mid-turn.
pub fn reloadMessages(self: *AgentRuntime) !void {
    // Project first, swap second: a failed reprojection leaves the live
    // cache intact instead of stranded with only the system prompt (TD-5).
    if (self.agent.skill_context_dirty) return error.SkillContextNotPersisted;
    var projected = try self.session_writer.conversation(self.gpa);
    defer projected.deinit(self.gpa);
    try agent_mod.replaceConversation(&self.agent, &projected);
    // The conversation is now a different branch; the usage anchor no
    // longer refers to these messages.
    agent_mod.resetContextUsage(&self.agent);
}

test "runtime agent aliases the owned cwd, not the borrowed input" {
    // Regression for the segfault in `std.fs.path.isAbsolute` reached from
    // `bash.validateCwd`: `Agent.init` was handed the raw borrowed `cwd`
    // parameter, which callers (a cross-project resume hands us
    // `summary.cwd`) free via `resumeClear` while the runtime still lives.
    // The agent must point at the runtime-owned dupe so a later bash tool
    // call can't dereference freed memory.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const home_abs = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_abs);

    var runtime: AgentRuntime = undefined;
    try runtime.initNew(.{
        .gpa = gpa,
        .io = std.testing.io,
        .cwd = home_abs,
        .session_dir = home_abs,
        .home_dir = home_abs,
        .base_system_prompt = "test system prompt",
        .host_id = "test-host",
        .config = .{},
        .diagnostics = &.{},
    });
    defer runtime.deinit();

    try std.testing.expectEqualStrings(home_abs, runtime.cwd);
    try std.testing.expectEqualStrings(home_abs, runtime.agent.cwd);
    // The agent must alias the runtime's owned dupe — never the borrowed
    // parameter the caller may free.
    try std.testing.expect(runtime.agent.cwd.ptr == runtime.cwd.ptr);
}

test "initNew arms agent database_server_url from canonical database block" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const home_abs = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_abs);

    var runtime: AgentRuntime = undefined;
    var cfg: config_mod.Config = .{};
    cfg.database = .{
        .url = try gpa.dupe(u8, "http://db-companion:8766"),
        .auth_token = try gpa.dupe(u8, "test-auth-token"),
    };
    defer cfg.deinit(gpa);

    try runtime.initNew(.{
        .gpa = gpa,
        .io = std.testing.io,
        .cwd = home_abs,
        .session_dir = home_abs,
        .home_dir = home_abs,
        .base_system_prompt = "test system prompt",
        .host_id = "test-host",
        .config = cfg,
        .diagnostics = &.{},
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.agent.database_server_url != null);
    try std.testing.expectEqualStrings("http://db-companion:8766", runtime.agent.database_server_url.?);
    try std.testing.expect(runtime.agent.database_auth_token != null);
    try std.testing.expectEqualStrings("test-auth-token", runtime.agent.database_auth_token.?);
}

test "initResume plants the restored model in the config arena (overwrite-in-arena)" {
    // PR-2b regression: the resume path dupes the restored model id into the
    // App config arena and never frees it — the arena is released wholesale
    // by root after tui.run. A gpa plant without the matching free would trip
    // the testing allocator, so the leak check here guards the hand-off; the
    // client's restored model id proves the session's stored selection wins
    // over the resume config's own model.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const home_abs = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_abs);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    // Session 1: attach from the config, then switch the model mid-session —
    // updateModel persists provider/id/effort for the resume below.
    var runtime: AgentRuntime = undefined;
    try runtime.initNew(.{
        .gpa = gpa,
        .io = std.testing.io,
        .cwd = home_abs,
        .session_dir = home_abs,
        .home_dir = home_abs,
        .base_system_prompt = "test system prompt",
        .host_id = "test-host",
        .config = .{
            .model_selection = .{ .builtin = .{
                .provider = .ollama,
                .provider_name = @constCast("ollama"),
                .model = .{ .id = @constCast("init-model") },
            } },
        },
        .diagnostics = &.{},
    });
    const session_id = try gpa.dupe(u8, runtime.session_writer.session.id.slice());
    defer gpa.free(session_id);
    try runtime.session_writer.updateModel("ollama", "resumed-model", "high");
    runtime.deinit();

    // Resume with a DIFFERENT config model: the session's stored selection
    // must win, and its planted slices land in the arena (never freed).
    try runtime.initResume(.{
        .gpa = gpa,
        .io = std.testing.io,
        .cwd = home_abs,
        .session_dir = home_abs,
        .home_dir = home_abs,
        .base_system_prompt = "test system prompt",
        .host_id = "test-host",
        .config = .{
            .model_selection = .{ .builtin = .{
                .provider = .ollama,
                .provider_name = @constCast("ollama"),
                .model = .{ .id = @constCast("config-model") },
            } },
        },
        .config_arena = arena_state.allocator(),
        .diagnostics = &.{},
        .session_id = session_id,
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.client != .none);
    const client = switch (runtime.client) {
        .openai_compatible => |c| c,
        else => return error.UnexpectedAdapter,
    };
    try std.testing.expectEqualStrings("resumed-model", client.config.model);
    try std.testing.expectEqual(ai.ReasoningEffort.high, client.config.reasoning.?.effort.?);
}

test "initResume gpa fallback frees the planted model id (no arena installed)" {
    // Pins the fallback path: a bare runtime without `config_arena` keeps
    // the gpa dupe→free dance, so the testing allocator's leak check is
    // the guard — a missing free on either the success or the attach-failure
    // path would surface here.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const home_abs = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_abs);

    var runtime: AgentRuntime = undefined;
    try runtime.initNew(.{
        .gpa = gpa,
        .io = std.testing.io,
        .cwd = home_abs,
        .session_dir = home_abs,
        .home_dir = home_abs,
        .base_system_prompt = "test system prompt",
        .host_id = "test-host",
        .config = .{
            .model_selection = .{ .builtin = .{
                .provider = .ollama,
                .provider_name = @constCast("ollama"),
                .model = .{ .id = @constCast("init-model") },
            } },
        },
        .diagnostics = &.{},
    });
    const session_id = try gpa.dupe(u8, runtime.session_writer.session.id.slice());
    defer gpa.free(session_id);
    try runtime.session_writer.updateModel("ollama", "resumed-model", null);
    runtime.deinit();

    try runtime.initResume(.{
        .gpa = gpa,
        .io = std.testing.io,
        .cwd = home_abs,
        .session_dir = home_abs,
        .home_dir = home_abs,
        .base_system_prompt = "test system prompt",
        .host_id = "test-host",
        .config = .{
            .model_selection = .{ .builtin = .{
                .provider = .ollama,
                .provider_name = @constCast("ollama"),
                .model = .{ .id = @constCast("config-model") },
            } },
        },
        .diagnostics = &.{},
        .session_id = session_id,
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.client != .none);
    const client = switch (runtime.client) {
        .openai_compatible => |c| c,
        else => return error.UnexpectedAdapter,
    };
    try std.testing.expectEqualStrings("resumed-model", client.config.model);
}
