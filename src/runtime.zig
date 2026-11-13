const std = @import("std");
const log = std.log.scoped(.runtime);

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
const codex_mod = @import("auth/codex.zig");
const config_mod = @import("config/config.zig");
const connection = @import("runtime/connection.zig");
const context_assembly = @import("context/assembly.zig");
const modelsdev = @import("models/registry.zig");
const plugin_prompt = @import("plugin_prompt.zig");
const plugin_manager_mod = @import("lua/manager.zig");
const paths = @import("paths.zig");
const session_mod = @import("session.zig");
const skill_mod = @import("skill.zig");

const assert = std.debug.assert;

pub const codex_connection_expired_message = "Codex connection expired. Run /connect to reconnect.";

pub const AgentRuntime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home_dir: []const u8,
    client: ai.LanguageModel,
    base_system_prompt: []const u8,
    system_prompt: []const u8,
    refresh_snapshot: ?context_assembly.RefreshSnapshot = null,
    skills: []skill_mod.Skill,
    /// Per-plugin `prompt.md` bodies, injected into the system prompt at
    /// assembly time so the model learns how to use each plugin's tools.
    /// Cloned from the primary lane for sub-lanes (same project, same plugins).
    plugin_prompts: []plugin_prompt.PluginPrompt,
    session_writer: session_mod.SessionWriter,
    agent: agent_mod.Agent,
    diagnostics: []config_mod.Diagnostic,
    codex_connection_expired: bool = false,
    owned_client: ?OwnedClient = null,
    /// Second client, same config as `owned_client`, used only by the agent's
    /// background summarizer so the two never share a connection.
    owned_compaction_client: ?OwnedClient = null,
    /// Third client, same config as `owned_client` (no tools), used only by
    /// the TUI's background branch-naming request so it never shares a
    /// connection with the live turn or the summarizer. The App cancels any
    /// in-flight naming job before this runtime is torn down or reconnected.
    owned_naming_client: ?OwnedClient = null,
    naming_client: ai.LanguageModel = .none,
    /// MCP tool schemas to inject into the AI config at connection time.
    /// Set by the App before calling connectXxxClient.
    mcp_tools: []const ai.McpToolSchema = &.{},
    /// Whether to send OpenAI strict structured-outputs mode in tool
    /// definitions. Forwarded to every attached client's `ai.Config`.
    /// Default `false` — strict is OpenAI-only and breaks function-calling
    /// on gateways. Set from `config.strict_outputs` at session init.
    strict_outputs: bool = false,
    /// Wire-format dialect for vendor-specific request fields.
    /// Resolved from provider identity at connect time and forwarded
    /// to every attached client's `ai.Config`. Default `.minimal` is
    /// safe for all providers (no vendor-specific fields emitted).
    wire_dialect: ai.WireDialect = .minimal,
    /// Disable provider prompt-caching fields (C1). Populated from
    /// `context_settings.disable_prompt_cache` at the dialect-resolution
    /// site and forwarded to every attached client's `ai.Config`. When
    /// true, neither `cache_control` nor `prompt_cache_key` is emitted.
    disable_prompt_cache: bool = false,
    /// Context window and compaction settings from config. Stored so
    /// the attach/connect functions can pass the override to
    /// `compaction.contextWindowTokens` and the agent can use the
    /// compaction policy.
    context_settings: config_mod.ContextSettings = .{},
    /// The App's config arena (non-owning), handed over by the resume
    /// call sites (root.zig, session switcher). `restoreResumedModel`
    /// plants the resumed model slices here — overwrite-in-arena, never
    /// freed — instead of the gpa dupe→free dance. Null in bare test
    /// runtimes, which fall back to the gpa and free after
    /// `applyFromConfig` to stay leak-clean under the test allocator.
    config_arena: ?std.mem.Allocator = null,
    /// Runtime models.dev registry (cache-only, no network). Loaded once
    /// at init for model capability lookups (reasoning, context window).
    /// The TUI's lazy `loadOrFetchRegistry` refreshes the cache for next time.
    modelsdev_registry: ?modelsdev.Registry = null,
    /// True once `initSession` has brought up `session_writer` (background
    /// thread + sqlite handle). Some TUI test harnesses construct a partial
    /// runtime with `session_writer = undefined`; gates session-DB writes so
    /// those harnesses can still exercise the picker without touching sqlite.
    session_writer_started: bool = false,

    // Connection-concern types live in `runtime/connection.zig`; these
    // aliases keep the field decls above and external consumers reading as
    // before.
    pub const ClientState = connection.ClientState;
    const OwnedClient = connection.OwnedClient;

    /// Birth parameters for a runtime session — one named struct instead of
    /// a 10-positional-param contract where a transposition compiles
    /// silently. `session_id == null` starts a new session; non-null
    /// resumes that session. `host_id` is resolved ONCE at the process
    /// boundary and propagated to every new/resumed/lane runtime
    /// (INV-HOST-ID). `session_store` overrides the config-derived backend
    /// selection — the resume picker passes the store the session was listed
    /// from, so the id is never resolved against a different database.
    pub const Genesis = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: []const u8,
        home_dir: []const u8,
        base_system_prompt: []const u8,
        config: config_mod.Config,
        diagnostics: []config_mod.Diagnostic,
        host_id: []const u8,
        session_id: ?[]const u8 = null,
        session_store: ?session_mod.SessionStore = null,
        /// App config arena for `restoreResumedModel`'s overwrite-in-arena
        /// planting (resume call sites only). Null keeps the gpa fallback.
        config_arena: ?std.mem.Allocator = null,
        template: ?*const AgentRuntime = null,
    };

    pub fn initNew(target: *AgentRuntime, genesis: Genesis) !void {
        assert(genesis.session_id == null);
        try target.initSession(genesis);
    }

    pub fn initResume(target: *AgentRuntime, genesis: Genesis) !void {
        assert(genesis.session_id != null);
        try target.initSession(genesis);
    }

    /// `cwd` is where the agent runs tools and loads skills (a lane's workspace);
    /// `session_dir` is where the session DB lives and what the session records
    /// as its cwd — the repo root, so all lanes share one DB and group together.
    fn initSession(target: *AgentRuntime, genesis: Genesis) !void {
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
            try target.reloadMessages();
        }

        // When resuming a session, try to restore the model used in that
        // session; a new session attaches straight from the config.
        if (session_id != null) {
            try target.restoreResumedModel(config);
        } else {
            // New session - will save model info after applyFromConfig
            try target.applyFromConfig(config);
        }
    }

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

    /// Resolve the model recorded in the session summary onto the config and
    /// attach from it: provider (builtin enum, then the providers[] map for
    /// custom names), model id, custom base_url, and the session-scoped
    /// reasoning effort. Unknown provider or missing model ids degrade to
    /// attaching the config as-is — resume is never fatal for restore gaps.
    fn restoreResumedModel(self: *AgentRuntime, config: config_mod.Config) !void {
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
        try self.agent.replaceConversation(&projected);
        // The conversation is now a different branch; the usage anchor no
        // longer refers to these messages.
        self.agent.resetContextUsage();
    }

    // ── Connection concern (`runtime/connection.zig`) ──
    // The attach/connect logic lives in the spoke as free functions over
    // `*AgentRuntime`. These delegates keep the externally-called method
    // surface byte-identical for its callers (tui status / session_switcher /
    // provider_model / lane_lifecycle, plus this file's own init path);
    // spoke-internal helpers moved without a delegate. `deinit` below keeps
    // its call positions — the invariant check before teardown and the
    // owned-client frees AFTER `agent.deinit` joins the summarizer thread —
    // so teardown order is unchanged.

    /// Connection-state projection: `.disconnected` or the live client.
    pub fn clientState(self: *const AgentRuntime) ClientState {
        return connection.clientState(self);
    }

    /// Owned client, runtime projection, and agent handle must agree, or the
    /// runtime is fully disconnected. The connection spoke checks it after
    /// every swap; `deinit` checks it before teardown.
    pub fn assertClientInvariant(self: *const AgentRuntime) void {
        connection.assertClientInvariant(self);
    }

    /// Pick and wire the LanguageModel adapter specified in `config`.
    /// Also handles providers that require sign-in (codex).
    pub fn applyFromConfig(self: *AgentRuntime, config: config_mod.Config) !void {
        return connection.applyFromConfig(self, config);
    }

    /// Establish a Codex session — uses OAuth credentials to identify
    /// against `/backend-api/codex/responses`. Replaces any previously
    /// connected codex client.
    pub fn connectCodexClient(
        self: *AgentRuntime,
        credentials: codex_mod.Credentials,
        model_id: []const u8,
        effort: ai.ReasoningEffort,
    ) !void {
        return connection.connectCodexClient(self, credentials, model_id, effort);
    }

    pub fn disconnectCodexClient(self: *AgentRuntime) void {
        connection.disconnectCodexClient(self);
    }

    pub fn hasCodexClient(self: *const AgentRuntime) bool {
        return connection.hasCodexClient(self);
    }

    pub fn disconnectClient(self: *AgentRuntime) void {
        connection.disconnectClient(self);
    }

    pub fn attachOpenAiCompatibleClient(
        self: *AgentRuntime,
        provider_name: []const u8,
        base_url: []const u8,
        api_key: []const u8,
        model_id: []const u8,
        effort: ai.ReasoningEffort,
        user_headers: []const config_mod.ProviderHeader,
    ) !void {
        return connection.attachOpenAiCompatibleClient(self, provider_name, base_url, api_key, model_id, effort, user_headers);
    }

    pub fn attachOpenAiCompatibleClientWithPolicy(
        self: *AgentRuntime,
        provider_name: []const u8,
        base_url: []const u8,
        api_key: []const u8,
        model_id: []const u8,
        effort: ai.ReasoningEffort,
        user_headers: []const config_mod.ProviderHeader,
        response_policy: ai.response_policy.Policy,
    ) !void {
        return connection.attachOpenAiCompatibleClientWithPolicy(self, provider_name, base_url, api_key, model_id, effort, user_headers, response_policy);
    }

    /// Serialize + push the current tool set into the attached client.
    /// Call between turns or right after wiring the registry — never mid-turn.
    pub fn syncToolJson(self: *AgentRuntime) !void {
        return connection.syncToolJson(self);
    }

    pub fn deinit(self: *AgentRuntime) void {
        self.assertClientInvariant();
        self.agent.deinit();
        self.session_writer.deinit();
        self.gpa.free(self.base_system_prompt);
        self.gpa.free(self.system_prompt);
        if (self.refresh_snapshot) |*snapshot| snapshot.deinit(self.gpa);
        // `cwd` is runtime-owned (duped in initSession); `home_dir` is borrowed
        // from the root config and lives until the app exits — not freed here.
        self.gpa.free(self.cwd);
        skill_mod.deinitAll(self.gpa, self.skills);
        plugin_prompt.deinitAll(self.gpa, self.plugin_prompts);
        // `agent.deinit` above joined the summarizer thread, so its client is
        // no longer in use and is safe to free. The naming client's borrower
        // (the App's branch-naming job) is cancelled before runtime teardown.
        if (self.owned_naming_client) |client| client.deinit(self.gpa);
        if (self.owned_compaction_client) |client| client.deinit(self.gpa);
        if (self.owned_client) |client| client.deinit(self.gpa);
        if (self.modelsdev_registry) |*reg| reg.deinit(self.gpa);
        for (self.diagnostics) |*d| d.deinit(self.gpa);
        self.gpa.free(self.diagnostics);
        self.* = undefined;
    }
};

test "plugin prompts exclude failed and shadowed copies and survive lane cloning" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const package = @import("plugin_package.zig");
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

test "createSystemPrompt substitutes ${CWD} with the working directory" {
    const gpa = std.testing.allocator;
    const rendered = try context_assembly.substituteBaseTemplate(gpa, "header\nYou are in ${CWD}.\n", "C:\\repos\\zay", "2026-08-04", "C:\\config\\zay");
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings("header\nYou are in C:\\repos\\zay.\n", rendered);
}

test "createSystemPrompt leaves a template without the placeholder untouched" {
    const gpa = std.testing.allocator;
    const rendered = try context_assembly.substituteBaseTemplate(gpa, "no placeholder here", "/tmp/zay", "2026-08-04", "/home/user/.config/zay");
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings("no placeholder here", rendered);
}

test "createSystemPrompt substitutes ${OS} with the host operating system" {
    const gpa = std.testing.allocator;
    const rendered = try context_assembly.substituteBaseTemplate(gpa, "OS: ${OS}", "/tmp/zay", "2026-08-04", "/home/user/.config/zay");
    defer gpa.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "${OS}") == null);
    try std.testing.expect(std.mem.startsWith(u8, rendered, "OS: "));
    try std.testing.expect(rendered.len > "OS: ".len);
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
