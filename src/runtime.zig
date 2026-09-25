const std = @import("std");
const log = std.log.scoped(.runtime);

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
const auth_mod = @import("auth/store.zig");
const codex_mod = @import("auth/codex.zig");
const compaction = @import("context/compaction.zig");
const config_mod = @import("config/config.zig");
const provider_types = @import("config/provider.zig");
const context_assembly = @import("context/assembly.zig");
const modelsdev = @import("models/registry.zig");
const plugin_prompt = @import("plugin_prompt.zig");
const session_mod = @import("session.zig");
const skill_mod = @import("skill.zig");
const tools_mod = @import("tools.zig");

const assert = std.debug.assert;

const codex_refresh_margin_ms: i64 = 5 * std.time.ms_per_min;

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
    /// Runtime models.dev registry (cache-only, no network). Loaded once
    /// at init for model capability lookups (reasoning, context window).
    /// The TUI's lazy `loadOrFetchRegistry` refreshes the cache for next time.
    modelsdev_registry: ?modelsdev.Registry = null,
    /// True once `initSession` has brought up `session_writer` (background
    /// thread + sqlite handle). Some TUI test harnesses construct a partial
    /// runtime with `session_writer = undefined`; gates session-DB writes so
    /// those harnesses can still exercise the picker without touching sqlite.
    session_writer_started: bool = false,

    /// Look up per-model capability data from the runtime's models.dev registry.
    /// Returns null when the registry isn't loaded or the model isn't found.
    fn lookupModelInfo(self: *const AgentRuntime, model_id: []const u8) ?modelsdev.ModelInfo {
        if (self.modelsdev_registry) |*reg| return reg.lookupModel(model_id);
        return null;
    }

    pub const ClientState = union(enum) {
        disconnected,
        connected: ai.LanguageModel,
    };

    const OwnedClient = union(enum) {
        codex_responses: *ai.codex_responses.Client,
        openai_compatible: *ai.openai_compatible.Client,
        responses: *ai.responses_core.Client,

        fn deinit(self: OwnedClient, gpa: std.mem.Allocator) void {
            switch (self) {
                .codex_responses => |client| {
                    client.deinit();
                    gpa.destroy(client);
                },
                .openai_compatible => |client| {
                    client.deinit();
                    gpa.destroy(client);
                },
                .responses => |client| {
                    client.deinit();
                    gpa.destroy(client);
                },
            }
        }

        fn languageModel(self: OwnedClient) ai.LanguageModel {
            return switch (self) {
                .codex_responses => |client| .{ .codex_responses = client },
                .openai_compatible => |client| .{ .openai_compatible = client },
                .responses => |client| .{ .responses = client },
            };
        }

        /// Push the final, already-deduped tool list into the client. Every
        /// concrete client exposes `updateTools(specs)`; this helper
        /// dispatches through the union so `replaceClient` can push the
        /// current tool set into the freshly-attached client without the
        /// attach functions each repeating the call.
        ///
        /// Without this, a newly-attached client keeps the `tools_json` it
        /// built at `init` time (builtin only) and never learns about
        /// `lua__<plugin>__<tool>` or `mcp__<server>__<tool>` entries — the
        /// model then tries to invoke them as shell commands.
        fn updateTools(self: OwnedClient, specs: []const ai.tool_schema.ToolSpec) anyerror!void {
            switch (self) {
                inline else => |client| try client.updateTools(specs),
            }
        }
    };

    /// Birth parameters for a runtime session — one named struct instead of
    /// a 10-positional-param contract where a transposition compiles
    /// silently. `session_id == null` starts a new session; non-null
    /// resumes that session.
    pub const Genesis = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: []const u8,
        home_dir: []const u8,
        base_system_prompt: []const u8,
        config: config_mod.Config,
        diagnostics: []config_mod.Diagnostic,
        session_id: ?[]const u8 = null,
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
        const plugin_prompts = if (template) |t| try plugin_prompt.cloneAll(gpa, t.plugin_prompts) else try plugin_prompt.loadAll(gpa, io, home_dir, cwd);
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

        if (session_id) |id| {
            try target.session_writer.initResumeDefault(gpa, io, home_dir, id);
        } else {
            try target.session_writer.initDefault(gpa, io, home_dir, session_dir);
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
        if (config.context.tool_call_limit_per_turn) |v| target.agent.tool_call_limit_per_turn = v;
        if (config.context.soft_stop_on_tool_call_limit) |b| target.agent.soft_stop_on_tool_call_limit = b;
        if (config.context.auto_continue_on_length_cut) |b| target.agent.auto_continue_on_length_cut = b;
        if (config.model_selection) |ms| {
            if (ms.bashClassifierUrl()) |url| {
                target.agent.bash_classifier_url = try gpa.dupe(u8, url);
            }
        }
        target.agent.attachSessionWriter(&target.session_writer);
        try target.agent.addSystem(owned_system_prompt);

        if (session_id != null) {
            const messages = try target.session_writer.session.messages(gpa);
            defer gpa.free(messages);
            for (messages) |message| try target.agent.takeMessage(message);
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
                switch (ms.*) {
                    .builtin => |*b| {
                        b.provider = provider_enum;
                        b.provider_name = @constCast(mp);
                        if (summary.model_id) |mid| {
                            // mid is borrowed from summary — dupe into owned memory.
                            b.model.id = try gpa.dupe(u8, mid);
                        }
                    },
                    .custom => |*c| {
                        c.provider_name = @constCast(mp);
                        if (summary.model_id) |mid| {
                            // mid is borrowed from summary — dupe into owned memory.
                            c.model.id = try gpa.dupe(u8, mid);
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
                try self.applyFromConfig(session_config);
                // Free the dupe'd model_id — applyFromConfig dupe'd it again
                // into the client, so the session_config copy is no longer needed.
                if (summary.model_id) |_| {
                    const mid_to_free = switch (ms.*) {
                        .builtin => |b| b.model.id,
                        .custom => |c| c.model.id,
                    };
                    gpa.free(mid_to_free);
                }
            } else {
                const is_builtin = std.meta.stringToEnum(config_mod.Provider, mp) != null;
                if (summary.model_id) |mid| {
                    // mid is borrowed from summary's internal allocation.
                    // Dupe it into owned memory so it survives summary.deinit.
                    const owned_mid = try gpa.dupe(u8, mid);
                    errdefer gpa.free(owned_mid);
                    if (is_builtin) {
                        session_config.model_selection = .{
                            .builtin = .{
                                .provider = provider_enum,
                                .provider_name = @constCast(mp),
                                .model = .{
                                    .id = owned_mid,
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
                                    .id = owned_mid,
                                    .reasoning = if (resume_effort) |effort| .{ .effort = effort } else .unset,
                                },
                                .use_responses_endpoint = false,
                                .bash_classifier_url = null,
                            },
                        };
                    }
                    try self.applyFromConfig(session_config);
                    // Free the dupe'd model_id — applyFromConfig dupe'd it
                    // again into the client.
                    gpa.free(owned_mid);
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
        const messages = try self.session_writer.messages(self.gpa);
        defer self.gpa.free(messages);
        self.agent.clearNonSystemMessages();
        for (messages) |message| try self.agent.takeMessage(message);
        // The conversation is now a different branch; the usage anchor no
        // longer refers to these messages.
        self.agent.resetContextUsage();
    }

    pub fn clientState(self: *const AgentRuntime) ClientState {
        if (self.client == .none) return .disconnected;
        return .{ .connected = self.client };
    }

    pub fn assertClientInvariant(self: *const AgentRuntime) void {
        if (self.owned_client) |owned| {
            assert(self.client != .none);
            assert(self.agent.client != .none);
            assert(languageModelMatchesOwned(self.client, owned));
            assert(languageModelMatches(self.agent.client, self.client));
        } else {
            assert(self.client == .none);
            assert(self.agent.client == .none);
        }
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

    /// Pick and wire the LanguageModel adapter specified in `config`.
    /// Also handles providers that require sign-in (codex).
    pub fn applyFromConfig(self: *AgentRuntime, config: config_mod.Config) !void {
        const selection = config.activeModelSelection() orelse return;
        const model_id = selection.model().id;
        if (model_id.len == 0) {
            log.warn("runtime.applyFromConfig: empty model_id for provider {s}, skipping model attachment", .{selection.providerName()});
            return;
        }
        const adapter = adapterForConfig(selection.provider(), config) orelse return;
        switch (adapter) {
            .codex_responses => try self.tryConnectCodexFromAuth(config),
            .openai_compatible => try self.tryAttachOpenAiCompatibleFromConfig(selection.provider(), config),
            .openai_responses => try self.tryAttachOpenAiResponsesFromConfig(selection.provider(), config),
        }
        // Save the model selection to the session so it can be restored on resume.
        // Use provider_name (the config key) so custom providers round-trip.
        // The resolved reasoning effort is persisted too so session-scoped
        // effort survives restart.
        try self.session_writer.session.updateModel(selection.providerName(), model_id, selection.model().reasoning.resolve().label());
    }

    fn adapterForConfig(provider: config_mod.Provider, config: config_mod.Config) ?config_mod.AdapterKind {
        const adapter = provider.adapter() orelse return null;
        if (adapter == .openai_compatible) {
            if (config.model_selection) |ms| {
                if (ms.useResponsesEndpoint()) return .openai_responses;
            }
        }
        return adapter;
    }

    fn tryConnectCodexFromAuth(self: *AgentRuntime, config: config_mod.Config) !void {
        if (self.home_dir.len == 0) return;
        var creds = (codex_mod.load(self.gpa, self.io, self.home_dir) catch null) orelse return;
        defer creds.deinit(self.gpa);
        try self.refreshCodexCredentialsIfNeeded(&creds);
        if (self.codex_connection_expired) return;
        const ms = config.model_selection orelse return;
        const model_id = ms.model().id;
        const effort = ms.model().reasoning.resolve();
        try self.connectCodexClient(creds, model_id, effort);
    }

    fn refreshCodexCredentialsIfNeeded(self: *AgentRuntime, creds: *codex_mod.Credentials) !void {
        const now_ms = std.Io.Clock.now(.real, self.io).toMilliseconds();
        if (!codexRefreshNeeded(creds.expires, now_ms)) {
            self.codex_connection_expired = false;
            return;
        }
        const refresh_token = try self.gpa.dupe(u8, creds.refresh);
        defer self.gpa.free(refresh_token);
        var refreshed = codex_mod.refresh(self.gpa, self.io, self.home_dir, refresh_token) catch |err| {
            log.warn("codex.refresh.failed err={s}", .{@errorName(err)});
            self.codex_connection_expired = true;
            return;
        };
        creds.deinit(self.gpa);
        creds.* = refreshed;
        refreshed = undefined;
        self.codex_connection_expired = false;
    }

    fn tryAttachOpenAiCompatibleFromConfig(
        self: *AgentRuntime,
        provider: config_mod.Provider,
        config: config_mod.Config,
    ) !void {
        // Resolve wire dialect from provider identity before any attach.
        self.wire_dialect = ai.WireDialect.resolve(
            provider,
            config.provider_name orelse "",
            config.base_url orelse "",
        );
        // C1: read the prompt-cache-disable flag once here so all three
        // attached clients (main / compaction / naming) inherit it.
        self.disable_prompt_cache = config.context.disable_prompt_cache orelse false;
        const ms = config.model_selection orelse {
            // No typed selection — fall back to legacy fields. For builtin
            // providers defaultBaseUrl() suffices; for .openai_compatible
            // the base_url was hydrated from the providers[] map by
            // hydrateActiveModel during config merge.
            const base_url = config.base_url orelse provider.defaultBaseUrl() orelse return;
            const model_id = if (config.model) |m| m.id else "default";
            const effort = if (config.model) |m| m.reasoning.resolve() else ai.ReasoningEffort.medium;
            var loaded_key: ?[]u8 = null;
            defer if (loaded_key) |k| self.gpa.free(k);
            const api_key = blk: {
                const name = config.provider_name orelse provider.label();
                if (self.home_dir.len > 0) {
                    loaded_key = auth_mod.loadProviderApiKey(self.gpa, self.io, self.home_dir, name) catch null;
                    if (loaded_key) |k| break :blk k;
                }
                break :blk provider.anonymousApiKey() orelse "";
            };
            try self.attachOpenAiCompatibleClient(
                config.provider_name orelse provider.label(),
                base_url,
                api_key,
                model_id,
                effort,
                config.providerHeadersByName(config.provider_name orelse provider.label()),
            );
            return;
        };
        const base_url = blk: {
            if (ms.baseUrl()) |url| {
                if (url.len > 0) break :blk url;
            }
            break :blk provider.defaultBaseUrl() orelse return;
        };
        const effort = ms.model().reasoning.resolve();
        self.resolveModelContextFallbacks(ms);
        var loaded_key: ?[]u8 = null;
        defer if (loaded_key) |k| self.gpa.free(k);
        const api_key = blk: {
            if (ms.apiKey()) |key| {
                if (key.len > 0) break :blk key;
            }
            // Auth lookup uses provider_name (the config map key / defaultModel
            // prefix) so custom providers like "qwen-cloud" resolve their own
            // stored key from auth.json.
            if (self.home_dir.len > 0) {
                loaded_key = auth_mod.loadProviderApiKey(self.gpa, self.io, self.home_dir, ms.providerName()) catch null;
                if (loaded_key) |k| break :blk k;
            }
            // No stored key — log for diagnostics when the provider requires
            // one, so a 402/401 on the first turn is traceable.
            if (provider.requiresApiKey()) {
                log.warn("auth.missing_key provider={s} — requests will likely fail with 402", .{ms.providerName()});
            }
            break :blk provider.anonymousApiKey() orelse "";
        };
        const model_id_to_attach = switch (ms) {
            .builtin => |b| b.model.id,
            .custom => |c| c.model.id,
        };
        try self.attachOpenAiCompatibleClient(ms.providerName(), base_url, api_key, model_id_to_attach, effort, config.providerHeadersByName(ms.providerName()));
    }

    fn tryAttachOpenAiResponsesFromConfig(
        self: *AgentRuntime,
        provider: config_mod.Provider,
        config: config_mod.Config,
    ) !void {
        const ms = config.model_selection orelse return;
        // Resolve the wire dialect here too: `buildProviderHeaders` consumes
        // it for the OpenRouter attribution arm, so a stale value from a
        // previous attach would mis-emit `X-Title` on this one.
        self.wire_dialect = ai.WireDialect.resolve(
            provider,
            config.provider_name orelse "",
            config.base_url orelse "",
        );
        self.disable_prompt_cache = config.context.disable_prompt_cache orelse false;
        const base_url = if (ms.baseUrl()) |url| if (url.len > 0) url else provider.defaultBaseUrl() orelse return else provider.defaultBaseUrl() orelse return;
        self.resolveModelContextFallbacks(ms);
        const reasoning: ai.Reasoning = .{
            .effort = ms.model().reasoning.resolve(),
            .summary = .auto,
        };
        try self.attachOpenAiResponsesClient(ms.providerName(), base_url, ms.apiKey() orelse "", ms.model().id, reasoning, config.providerHeadersByName(ms.providerName()));
    }

    /// Per-model context_window and max_output_tokens from the providers map
    /// act as fallbacks when the global overrides are not set. Capability
    /// fallbacks are adapter-independent, so every attach path resolves them
    /// (the responses path previously skipped them — the chat path's block,
    /// deduplicated here).
    fn resolveModelContextFallbacks(self: *AgentRuntime, ms: config_mod.ModelSelection) void {
        if (self.context_settings.override_context_window == null) {
            self.context_settings.override_context_window = ms.model().context_window;
        }
        if (self.context_settings.max_output_tokens == null) {
            self.context_settings.max_output_tokens = ms.model().max_output_tokens;
        }
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
        return self.attachClients(.{
            .adapter = .codex,
            .base_url = ai.codex_responses.default_codex_endpoint,
            .api_key = credentials.access,
            .model_id = model_id,
            .reasoning = .{ .effort = effort, .summary = .auto },
            .account_id = credentials.account_id,
            .provider_name = "openai",
            .main_system_prompt = self.system_prompt,
        });
    }

    pub fn disconnectCodexClient(self: *AgentRuntime) void {
        const owned_client = self.owned_client orelse return;
        if (owned_client != .codex_responses) return;
        self.clearCompactionClient();
        self.clearNamingClient();
        owned_client.deinit(self.gpa);
        self.owned_client = null;
        self.client = .none;
        self.agent.client = .none;
        self.assertClientInvariant();
    }

    pub fn hasCodexClient(self: *const AgentRuntime) bool {
        const owned_client = self.owned_client orelse return false;
        return owned_client == .codex_responses;
    }

    pub fn disconnectClient(self: *AgentRuntime) void {
        const owned_client = self.owned_client orelse return;
        self.clearCompactionClient();
        self.clearNamingClient();
        owned_client.deinit(self.gpa);
        self.owned_client = null;
        self.client = .none;
        self.agent.client = .none;
        self.assertClientInvariant();
    }

    /// Expand `{env:VAR}` in the user's raw provider headers and merge them
    /// with the provider-required auto headers (OpenCode Zen routing, which
    /// the provider mandates as of 2026-09-05, plus OpenRouter attribution).
    /// Precedence — user-configured names win — is resolved inside
    /// `provider_headers.build`; the result is fully owned, freed with
    /// `provider_headers.freeHeaders`.
    fn buildProviderHeaders(
        self: *AgentRuntime,
        base_url: []const u8,
        user_headers: []const config_mod.ProviderHeader,
    ) ![]ai.provider_headers.Header {
        const expanded = try provider_types.expandProviderHeaders(self.gpa, user_headers);
        defer ai.provider_headers.freeHeaders(self.gpa, expanded);
        return ai.provider_headers.build(self.gpa, base_url, self.wire_dialect, expanded);
    }

    /// Which wire adapter the plan attaches. One arm per adapter in
    /// `createAttachClient`; a fourth adapter earns an arm here and a
    /// wrapper, nothing more.
    const AttachAdapter = enum { chat, responses, codex };

    /// Everything the unified attach path needs to build all three role
    /// clients: one endpoint, one model, one plan. The per-role deltas
    /// (tool surface cleared, prompt source) are derived in `attachClients`,
    /// so a role can never drift from the plan again.
    const AttachPlan = struct {
        adapter: AttachAdapter,
        base_url: []const u8,
        api_key: []const u8,
        model_id: []const u8,
        reasoning: ai.Reasoning,
        /// Provider key of the connection (auth-key id for openai_compatible,
        /// config key for a builtin, "openai" for codex). Borrowed; carried
        /// into the client's ai.Config so the TUI can display the ACTUAL
        /// provider of a live connection after a resume (when cached_config
        /// lags). Empty = derive the display name from config.
        provider_name: []const u8 = "",
        user_headers: []const config_mod.ProviderHeader = &.{},
        /// Codex only: the OAuth account id the client's init asserts on.
        account_id: []const u8 = "",
        /// The main role's system prompt. Null = keep `ai.Config`'s default
        /// (chat: the agent prompt lives in history, not on the wire).
        main_system_prompt: ?[]const u8 = null,
    };

    /// The main role's `ai.Config` from the plan. Chat-only wire knobs
    /// (dialect, timeout, caps) ride on the chat adapter; codex carries its
    /// OAuth account id; responses consumes only the shared fields.
    fn attachBaseConfig(
        self: *AgentRuntime,
        plan: AttachPlan,
        model_info: ?modelsdev.ModelInfo,
        provider_specs: []const ai.provider_headers.Header,
    ) ai.Config {
        var cfg: ai.Config = .{
            .provider_name = plan.provider_name,
            .base_url = plan.base_url,
            .api_key = plan.api_key,
            .model = plan.model_id,
            .tools = tools_mod.builtinRegistry(),
            .mcp_tools = self.mcp_tools,
            .reasoning = plan.reasoning,
            .strict = self.strict_outputs,
            .disable_prompt_cache = self.disable_prompt_cache,
            .session_id = self.session_writer.session.id.slice(),
            .system_prompt = plan.main_system_prompt orelse ai.default_system_prompt,
            .headers = provider_specs,
        };
        switch (plan.adapter) {
            .chat => {
                cfg.wire_dialect = self.wire_dialect;
                cfg.is_reasoning_model = compaction.isReasoningModel(model_info);
                cfg.max_output_tokens = self.context_settings.max_output_tokens;
                cfg.max_parallel_tool_calls = self.context_settings.max_parallel_tool_calls orelse ai.default_max_parallel_tool_calls;
                cfg.request_timeout_seconds = self.context_settings.request_timeout_seconds orelse ai.default_request_timeout_seconds;
            },
            .codex => cfg.account_id = plan.account_id,
            .responses => {},
        }
        return cfg;
    }

    /// A secondary role (compaction/naming) is the main config minus the
    /// tool surface, plus its prompt — derived by copy so the field list
    /// exists once and a role can never drift from the plan again.
    /// `max_output_tokens` stays unset: it serializes as `max_tokens` on the
    /// wire, and a small global cap must never truncate a persisted summary.
    fn attachSecondaryConfig(main: ai.Config, system_prompt: []const u8) ai.Config {
        var cfg = main;
        cfg.tools = &.{};
        cfg.mcp_tools = &.{};
        cfg.strict = false;
        cfg.max_output_tokens = null;
        cfg.system_prompt = system_prompt;
        return cfg;
    }

    /// Create + init the concrete client for the plan's adapter.
    fn createAttachClient(self: *AgentRuntime, plan: AttachPlan, cfg: ai.Config) !OwnedClient {
        switch (plan.adapter) {
            .chat => {
                const client = try self.gpa.create(ai.openai_compatible.Client);
                errdefer self.gpa.destroy(client);
                try client.init(self.gpa, self.io, cfg);
                errdefer client.deinit();
                return .{ .openai_compatible = client };
            },
            .responses => {
                const client = try self.gpa.create(ai.responses_core.Client);
                errdefer self.gpa.destroy(client);
                try client.init(self.gpa, self.io, cfg, .{});
                errdefer client.deinit();
                return .{ .responses = client };
            },
            .codex => {
                const client = try self.gpa.create(ai.codex_responses.Client);
                errdefer self.gpa.destroy(client);
                try client.init(self.gpa, self.io, cfg);
                errdefer client.deinit();
                return .{ .codex_responses = client };
            },
        }
    }

    /// Attach the three-role client trio for one endpoint plan: main (tools
    /// on), compaction (summarizer carrier prompt, C4), naming (same prompt
    /// as main). Main attach is fatal on failure; the secondaries are
    /// best-effort — on failure the previous secondary (if any) stays
    /// attached, matching the historical per-adapter attach behavior.
    fn attachClients(self: *AgentRuntime, plan: AttachPlan) !void {
        const model_info = self.lookupModelInfo(plan.model_id);
        var provider_specs: []ai.provider_headers.Header = &.{};
        if (plan.adapter != .codex) {
            provider_specs = try self.buildProviderHeaders(plan.base_url, plan.user_headers);
        }
        // Every init deep-copies the header specs, so the single free at
        // scope end spans all three roles — the one lifetime rule the plan
        // exists to centralize.
        defer if (plan.adapter != .codex) ai.provider_headers.freeHeaders(self.gpa, provider_specs);

        const main_config = self.attachBaseConfig(plan, model_info, provider_specs);
        const main_client = try self.createAttachClient(plan, main_config);
        // Ownership hands off here: nothing after this line may fail before
        // `replaceClient` runs, or `main_client` would leak.
        self.replaceClient(main_client);
        self.agent.context_window_tokens = compaction.contextWindowTokens(model_info, self.context_settings.override_context_window);
        self.agent.resetContextUsage();

        attach_compaction: {
            const compaction_config = attachSecondaryConfig(main_config, compaction.summarizer_system_prompt);
            const client = self.createAttachClient(plan, compaction_config) catch |err| {
                log.warn("attach.secondary role=compaction adapter={s} err={s}", .{ @tagName(plan.adapter), @errorName(err) });
                break :attach_compaction;
            };
            self.setCompactionClient(client);
        }
        attach_naming: {
            const naming_config = attachSecondaryConfig(main_config, main_config.system_prompt);
            const client = self.createAttachClient(plan, naming_config) catch |err| {
                log.warn("attach.secondary role=naming adapter={s} err={s}", .{ @tagName(plan.adapter), @errorName(err) });
                break :attach_naming;
            };
            self.setNamingClient(client);
        }
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
        return self.attachClients(.{
            .adapter = .chat,
            .provider_name = provider_name,
            .base_url = base_url,
            .api_key = api_key,
            .model_id = model_id,
            .reasoning = .{ .effort = effort },
            .user_headers = user_headers,
            // The chat agent prompt lives in history, not on the wire — the
            // ai.Config default stays for main and naming.
            .main_system_prompt = null,
        });
    }

    /// Sole caller is `tryAttachOpenAiResponsesFromConfig` — private.
    fn attachOpenAiResponsesClient(
        self: *AgentRuntime,
        provider_name: []const u8,
        base_url: []const u8,
        api_key: []const u8,
        model_id: []const u8,
        reasoning: ai.Reasoning,
        user_headers: []const config_mod.ProviderHeader,
    ) !void {
        return self.attachClients(.{
            .adapter = .responses,
            .provider_name = provider_name,
            .base_url = base_url,
            .api_key = api_key,
            .model_id = model_id,
            .reasoning = reasoning,
            .user_headers = user_headers,
            .main_system_prompt = self.system_prompt,
        });
    }

    fn languageModelMatches(a: ai.LanguageModel, b: ai.LanguageModel) bool {
        return switch (a) {
            .none => b == .none,
            .codex_responses => |client| b == .codex_responses and b.codex_responses == client,
            .openai_compatible => |client| b == .openai_compatible and b.openai_compatible == client,
            .responses => |client| b == .responses and b.responses == client,
            .scripted => |client| b == .scripted and b.scripted == client,
        };
    }

    fn languageModelMatchesOwned(model: ai.LanguageModel, owned: OwnedClient) bool {
        return switch (owned) {
            .codex_responses => |client| model == .codex_responses and model.codex_responses == client,
            .openai_compatible => |client| model == .openai_compatible and model.openai_compatible == client,
            .responses => |client| model == .responses and model.responses == client,
        };
    }

    fn replaceClient(self: *AgentRuntime, next: OwnedClient) void {
        self.codex_connection_expired = false;
        if (self.owned_client) |old| old.deinit(self.gpa);
        self.owned_client = next;
        self.client = next.languageModel();
        self.agent.client = self.client;
        self.assertClientInvariant();
        // The client built its `tools_json` from builtin + mcp_tools only.
        // Rebuild it now from the live registry so plugin tools
        // (`lua__<plugin>__<tool>`) are visible to the model on the next
        // prompt. Best-effort: a failure leaves the builtin-only set and is
        // logged — the attach itself already succeeded.
        //
        // Guard: during `initSession` (applyFromConfig — every /new,
        // /resume, lane spawn) the App has not wired `agent.tool_registry`
        // yet — it lands after `createRuntime` returns. Rebuilding with a
        // null registry and the empty builtin override serializes `"[]"`,
        // wiping the bash/lane definitions `init` just built and leaving
        // the whole session tool-less (the "sending request with NO tools"
        // turn-loop warning). When unwired, keep the init-time set; the App
        // pushes the merged list once the registry is wired.
        if (self.agent.tool_registry != null) {
            const specs = self.assembleToolSpecs(self.gpa) catch |err| {
                log.warn("replaceClient: assembleToolSpecs failed: {s}", .{@errorName(err)});
                return;
            };
            defer self.gpa.free(specs);
            next.updateTools(specs) catch |err| {
                log.warn("replaceClient: updateTools failed: {s}", .{@errorName(err)});
            };
        }
    }

    /// Assemble the final, deduped wire-tool spec list: the registry's
    /// builtin + plugin + MCP records when wired, else the static builtin
    /// registry (tests and the pre-wire init path). First-wins by name.
    /// Caller frees the returned slice.
    fn assembleToolSpecs(self: *AgentRuntime, gpa: std.mem.Allocator) anyerror![]ai.tool_schema.ToolSpec {
        var specs: std.ArrayList(ai.tool_schema.ToolSpec) = .empty;
        errdefer specs.deinit(gpa);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        const source: []const tools_mod.Tool = if (self.agent.tool_registry) |reg|
            try reg.all(gpa)
        else
            tools_mod.builtinRegistry();
        for (source) |t| {
            const gop = try seen.getOrPut(gpa, t.name);
            if (gop.found_existing) {
                log.warn("assembleToolSpecs: duplicate tool '{s}' dropped (first registration wins)", .{t.name});
                continue;
            }
            try specs.append(gpa, ai.tool_schema.specFromTool(t));
        }
        return specs.toOwnedSlice(gpa);
    }

    /// Serialize + push the current tool set into the attached client. Call
    /// between turns or right after wiring the registry — never mid-turn.
    pub fn syncToolJson(self: *AgentRuntime) !void {
        const owned = self.owned_client orelse return;
        const specs = try self.assembleToolSpecs(self.gpa);
        defer self.gpa.free(specs);
        try owned.updateTools(specs);
    }

    /// Install the dedicated background-summarizer client, replacing any
    /// previous one. Connecting happens between turns, so no summarizer is in
    /// flight against the old client when it is freed.
    fn setCompactionClient(self: *AgentRuntime, next: OwnedClient) void {
        self.agent.drainBackgroundCompaction();
        if (self.owned_compaction_client) |old| old.deinit(self.gpa);
        self.owned_compaction_client = next;
        self.agent.compaction_client = next.languageModel();
    }

    /// Tear down the background-summarizer client (after draining any in-flight
    /// summary), disabling compaction until the next connect.
    fn clearCompactionClient(self: *AgentRuntime) void {
        self.agent.drainBackgroundCompaction();
        if (self.owned_compaction_client) |old| old.deinit(self.gpa);
        self.owned_compaction_client = null;
        self.agent.compaction_client = .none;
    }

    /// Install the dedicated branch-naming client, replacing any previous one.
    /// The caller (App) guarantees no naming job is in flight against the old
    /// client — it cancels naming before connecting/reconnecting.
    fn setNamingClient(self: *AgentRuntime, next: OwnedClient) void {
        if (self.owned_naming_client) |old| old.deinit(self.gpa);
        self.owned_naming_client = next;
        self.naming_client = next.languageModel();
    }

    /// Tear down the branch-naming client, disabling naming until the next
    /// connect. Same caller contract as `setNamingClient`.
    fn clearNamingClient(self: *AgentRuntime) void {
        if (self.owned_naming_client) |old| old.deinit(self.gpa);
        self.owned_naming_client = null;
        self.naming_client = .none;
    }
};
fn codexRefreshNeeded(expires_ms: i64, now_ms: i64) bool {
    return expires_ms <= now_ms + codex_refresh_margin_ms;
}

test "OwnedClient.updateTools pushes plugin tools into a freshly-attached client" {
    // Regression for the user-reported "lua__write-tool__edit: command not
    // found" bug: a newly-attached client built `tools_json` from builtin +
    // mcp_tools only, so plugin tools never reached the model and it tried
    // to invoke them as shell commands. `replaceClient` now calls
    // `OwnedClient.updateTools` with the live registry right after the
    // client is attached — this test pins that dispatch in place by driving
    // the helper directly with an openai_compatible client + a registry
    // carrying one plugin tool.
    const gpa = std.testing.allocator;

    var client = try gpa.create(ai.openai_compatible.Client);
    try client.init(gpa, std.testing.io, .{
        .base_url = "https://example.invalid",
        .api_key = "test-key",
        .model = "test-model",
        .tools = tools_mod.builtinRegistry(),
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
    });
    defer {
        client.deinit();
        gpa.destroy(client);
    }

    // Plugin tools are absent from the initial tools_json (builtin only).
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "lua__p__t") == null);

    const reg = try gpa.create(tools_mod.ToolRegistry);
    defer {
        reg.deinit(gpa);
        gpa.destroy(reg);
    }
    reg.* = try tools_mod.ToolRegistry.init(gpa, tools_mod.builtinRegistry());
    const owned_name = try gpa.dupe(u8, "lua__p__t");
    const owned_desc = try gpa.dupe(u8, "test");
    try reg.addPluginTool(gpa, .{
        .name = owned_name,
        .description = owned_desc,
        .schema = .{ .properties = &.{} },
        .run = undefined,
        .display = undefined,
    });

    // The exact dispatch path `replaceClient` now uses.
    const owned: AgentRuntime.OwnedClient = .{ .openai_compatible = client };
    var specs: std.ArrayList(ai.tool_schema.ToolSpec) = .empty;
    defer specs.deinit(gpa);
    const reg_slice = try reg.all(gpa);
    for (reg_slice) |t| try specs.append(gpa, ai.tool_schema.specFromTool(t));
    try owned.updateTools(specs.items);

    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "lua__p__t") != null);
}

test "attach during initSession keeps builtin tools when registry is unwired" {
    // Regression for the user-reported "sending request with NO tools
    // (tools_json is empty)" turn loop: `replaceClient` unconditionally
    // rebuilt `tools_json` from the live registry, but during `initSession`
    // (applyFromConfig — every /new, /resume, lane spawn) the App has not
    // wired `agent.tool_registry` yet. The rebuild with a null registry and
    // the empty builtin override serialized "[]", wiping the bash/lane
    // definitions `init` had just built, and nothing re-injected tools until
    // an unrelated MCP event. The unwired rebuild must be skipped so the
    // client keeps its init-time builtin set.
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
        .config = .{
            .model_selection = .{
                .builtin = .{
                    .provider = .ollama,
                    .provider_name = @constCast("ollama"),
                    .model = .{ .id = @constCast("test-model") },
                },
            },
        },
        .diagnostics = &.{},
    });
    defer runtime.deinit();

    // No registry wired yet — exactly the state `createRuntime` leaves the
    // runtime in before the App finishes wiring. The builtin tools must
    // have survived the attach.
    try std.testing.expect(runtime.agent.tool_registry == null);
    const client = switch (runtime.client) {
        .openai_compatible => |c| c,
        else => return error.TestUnexpectedResult,
    };
    const shell_needle = try std.fmt.allocPrint(gpa, "\"name\":\"{s}\"", .{tools_mod.shellToolName});
    defer gpa.free(shell_needle);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, shell_needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "\"name\":\"lane\"") != null);
}

test "attach rebuilds tools from the registry once it is wired" {
    // Complement to the unwired-guard test: once the App has wired
    // `agent.tool_registry`, an attach MUST rebuild `tools_json` from it so
    // plugin tools reach the model (the original `replaceClient` purpose).
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
        .config = .{
            .model_selection = .{
                .builtin = .{
                    .provider = .ollama,
                    .provider_name = @constCast("ollama"),
                    .model = .{ .id = @constCast("test-model") },
                },
            },
        },
        .diagnostics = &.{},
    });
    defer runtime.deinit();

    const reg = try gpa.create(tools_mod.ToolRegistry);
    defer {
        reg.deinit(gpa);
        gpa.destroy(reg);
    }
    reg.* = try tools_mod.ToolRegistry.init(gpa, tools_mod.builtinRegistry());
    const owned_name = try gpa.dupe(u8, "lua__p__t");
    const owned_desc = try gpa.dupe(u8, "test");
    try reg.addPluginTool(gpa, .{
        .name = owned_name,
        .description = owned_desc,
        .schema = .{ .properties = &.{} },
        .run = undefined,
        .display = undefined,
    });
    runtime.agent.tool_registry = reg;

    // A model switch re-attaches; with the registry wired the rebuild runs.
    try runtime.attachOpenAiCompatibleClient("ollama", "http://localhost:11434", "", "test-model", .medium, &.{});
    const client = switch (runtime.client) {
        .openai_compatible => |c| c,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "lua__p__t") != null);
    const shell_needle = try std.fmt.allocPrint(gpa, "\"name\":\"{s}\"", .{tools_mod.shellToolName});
    defer gpa.free(shell_needle);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, shell_needle) != null);
}

test "codex refresh starts before token expiry" {
    const now_ms: i64 = 10_000;
    try std.testing.expect(codexRefreshNeeded(now_ms - 1, now_ms));
    try std.testing.expect(codexRefreshNeeded(now_ms + codex_refresh_margin_ms, now_ms));
    try std.testing.expect(!codexRefreshNeeded(now_ms + codex_refresh_margin_ms + 1, now_ms));
}

test "zen attach wires routing headers and session id into all chat clients" {
    // Regression for two behaviors: (a) the mandatory OpenCode Zen routing
    // headers (required by the provider as of 2026-09-05) must land on the
    // main, compaction, and naming clients alike, with a user-configured
    // same-name header replacing the auto value; (b) the chat-path
    // compaction and naming clients used to receive no session_id at all,
    // leaving the zen session header empty on summarizer/branch-naming
    // traffic.
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
        .config = .{},
        .diagnostics = &.{},
    });
    defer runtime.deinit();

    const user_headers = [_]config_mod.ProviderHeader{
        .{ .name = @constCast("x-opencode-session"), .value = @constCast("pinned-session") },
    };
    try runtime.attachOpenAiCompatibleClient("opencode", "https://opencode.ai/zen/v1", "public", "test-model", .medium, &user_headers);

    const main_client = switch (runtime.owned_client.?) {
        .openai_compatible => |client| client,
        else => return error.TestUnexpectedResult,
    };
    const compaction_client = switch (runtime.owned_compaction_client.?) {
        .openai_compatible => |client| client,
        else => return error.TestUnexpectedResult,
    };
    const naming_client = switch (runtime.owned_naming_client.?) {
        .openai_compatible => |client| client,
        else => return error.TestUnexpectedResult,
    };

    for ([_]*const ai.openai_compatible.Client{ main_client, compaction_client, naming_client }) |client| {
        const specs = client.provider_headers_owned;
        try std.testing.expectEqual(@as(usize, 2), specs.len);
        // The user's pinned session value replaced the auto header, in place.
        try std.testing.expectEqualStrings("x-opencode-session", specs[0].name);
        try std.testing.expectEqualStrings("pinned-session", specs[0].value.literal);
        try std.testing.expectEqualStrings(ai.provider_headers.zen_client_header, specs[1].name);
        try std.testing.expectEqualStrings(ai.provider_headers.zen_client_value, specs[1].value.literal);
    }

    // The session-id gap fill: summarizer and naming traffic now carry the
    // session id the zen header resolves against.
    try std.testing.expect(compaction_client.config.session_id.len > 0);
    try std.testing.expect(naming_client.config.session_id.len > 0);
    try std.testing.expectEqualStrings(main_client.config.session_id, compaction_client.config.session_id);
    try std.testing.expectEqualStrings(main_client.config.session_id, naming_client.config.session_id);
}

test "attach parity: every role inherits plan fields across all adapters" {
    // The unified attach path derives the compaction and naming clients from
    // the main client's config by copy. This table pins the derivation per
    // adapter so a role can never silently drift again — the chat naming
    // client lost wire_dialect/request_timeout_seconds exactly this way, and
    // the chat compaction prompt missed the C4 carrier intent.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const home_abs = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_abs);

    // ── chat: dialect, timeout, and prompt roles reach every role ──
    {
        var runtime: AgentRuntime = undefined;
        try runtime.initNew(.{
            .gpa = gpa,
            .io = std.testing.io,
            .cwd = home_abs,
            .session_dir = home_abs,
            .home_dir = home_abs,
            .base_system_prompt = "test system prompt",
            .config = .{
                .model_selection = .{
                    .builtin = .{
                        .provider = .alibaba,
                        .provider_name = @constCast("dashscope"),
                        .model = .{ .id = @constCast("qwen3-max") },
                    },
                },
            },
            .diagnostics = &.{},
        });
        defer runtime.deinit();

        // Re-attach with a non-default timeout so the parity check reads a
        // plan value no default could mask.
        runtime.wire_dialect = .dashscope;
        runtime.context_settings.request_timeout_seconds = 777;
        try runtime.attachOpenAiCompatibleClient(
            "dashscope",
            "https://dashscope.aliyuncs.com/compatible-mode/v1",
            "test-key",
            "qwen3-max",
            .medium,
            &.{},
        );

        const main_client = runtime.owned_client.?.openai_compatible;
        const comp_client = runtime.owned_compaction_client.?.openai_compatible;
        const naming_client = runtime.owned_naming_client.?.openai_compatible;
        const roles = [_]*const ai.openai_compatible.Client{ main_client, comp_client, naming_client };
        for (roles) |client| {
            try std.testing.expectEqual(ai.WireDialect.dashscope, client.config.wire_dialect);
            try std.testing.expectEqual(@as(u32, 777), client.config.request_timeout_seconds);
            try std.testing.expectEqualStrings(main_client.config.session_id, client.config.session_id);
            try std.testing.expectEqual(runtime.disable_prompt_cache, client.config.disable_prompt_cache);
        }
        // Tool surface: main only.
        try std.testing.expect(main_client.tools_json.len > 2);
        try std.testing.expectEqualStrings("[]", comp_client.tools_json);
        try std.testing.expectEqualStrings("[]", naming_client.tools_json);
        try std.testing.expectEqual(runtime.strict_outputs, main_client.config.strict);
        try std.testing.expect(!comp_client.config.strict);
        try std.testing.expect(!naming_client.config.strict);
        // Prompt roles: main/naming on the default carrier, compaction on
        // the summarizer carrier (C4) — on every adapter.
        try std.testing.expectEqualStrings(ai.default_system_prompt, main_client.config.system_prompt);
        try std.testing.expectEqualStrings(ai.default_system_prompt, naming_client.config.system_prompt);
        try std.testing.expectEqualStrings(compaction.summarizer_system_prompt, comp_client.config.system_prompt);
    }

    // ── responses: prompt roles + per-model context fallbacks on attach ──
    {
        var runtime: AgentRuntime = undefined;
        try runtime.initNew(.{
            .gpa = gpa,
            .io = std.testing.io,
            .cwd = home_abs,
            .session_dir = home_abs,
            .home_dir = home_abs,
            .base_system_prompt = "test system prompt",
            .config = .{
                .model_selection = .{
                    .builtin = .{
                        // A chat-adapter provider flagged for the Responses
                        // endpoint: `.openai` itself resolves to the codex
                        // adapter, which would skip this path entirely.
                        .provider = .ollama,
                        .provider_name = @constCast("ollama"),
                        .model = .{
                            .id = @constCast("gpt-5"),
                            .reasoning = .unset,
                            .context_window = 12345,
                            .max_output_tokens = 999,
                        },
                        .use_responses_endpoint = true,
                        .bash_classifier_url = null,
                    },
                },
            },
            .diagnostics = &.{},
        });
        defer runtime.deinit();

        // The per-model context fallbacks ride the responses path too —
        // capability fallbacks are adapter-independent.
        try std.testing.expectEqual(@as(?u32, 12345), runtime.context_settings.override_context_window);
        try std.testing.expectEqual(@as(?u32, 999), runtime.context_settings.max_output_tokens);

        const main_client = runtime.owned_client.?.responses;
        const comp_client = runtime.owned_compaction_client.?.responses;
        const naming_client = runtime.owned_naming_client.?.responses;
        const roles = [_]*const ai.responses_core.Client{ main_client, comp_client, naming_client };
        for (roles) |client| {
            try std.testing.expectEqualStrings(main_client.config.session_id, client.config.session_id);
        }
        // Naming carries the main client's (assembled) system prompt; the
        // runtime prompt is assembled, so assert the pairing, not a literal.
        try std.testing.expect(naming_client.config.system_prompt.len > 0);
        try std.testing.expectEqualStrings(main_client.config.system_prompt, naming_client.config.system_prompt);
        try std.testing.expectEqualStrings(compaction.summarizer_system_prompt, comp_client.config.system_prompt);
        try std.testing.expect(main_client.tools_json.len > 2);
        try std.testing.expectEqualStrings("[]", comp_client.tools_json);
        try std.testing.expectEqualStrings("[]", naming_client.tools_json);
        try std.testing.expectEqual(runtime.strict_outputs, main_client.config.strict);
        try std.testing.expect(!comp_client.config.strict);
        try std.testing.expect(!naming_client.config.strict);
    }

    // ── codex: account id and prompt roles on every role ──
    {
        var runtime: AgentRuntime = undefined;
        try runtime.initNew(.{
            .gpa = gpa,
            .io = std.testing.io,
            .cwd = home_abs,
            .session_dir = home_abs,
            .home_dir = home_abs,
            .base_system_prompt = "test system prompt",
            .config = .{},
            .diagnostics = &.{},
        });
        defer runtime.deinit();

        try runtime.connectCodexClient(.{
            .access = @constCast("test-access"),
            .refresh = @constCast("test-refresh"),
            .account_id = @constCast("acct_123"),
            .expires = 0,
        }, "gpt-5-codex", .medium);

        const main_client = runtime.owned_client.?.codex_responses;
        const comp_client = runtime.owned_compaction_client.?.codex_responses;
        const naming_client = runtime.owned_naming_client.?.codex_responses;
        const roles = [_]*const ai.codex_responses.Client{ main_client, comp_client, naming_client };
        for (roles) |client| {
            try std.testing.expectEqualStrings("acct_123", client.core_client.config.account_id);
            try std.testing.expectEqualStrings(main_client.core_client.config.session_id, client.core_client.config.session_id);
            try std.testing.expectEqual(ai.ReasoningSummary.auto, client.core_client.config.reasoning.?.summary.?);
        }
        try std.testing.expect(naming_client.core_client.config.system_prompt.len > 0);
        try std.testing.expectEqualStrings(main_client.core_client.config.system_prompt, naming_client.core_client.config.system_prompt);
        try std.testing.expectEqualStrings(compaction.summarizer_system_prompt, comp_client.core_client.config.system_prompt);
        try std.testing.expectEqualStrings("[]", comp_client.core_client.tools_json);
        try std.testing.expectEqualStrings("[]", naming_client.core_client.tools_json);
    }
}

test "runtime selects responses adapter when requested" {
    const config: config_mod.Config = .{
        .model_selection = .{
            .custom = .{
                .provider_name = @constCast("openai_compatible"),
                .base_url = @constCast(""),
                .api_key = @constCast(""),
                .model = .{ .id = @constCast("test") },
                .use_responses_endpoint = true,
            },
        },
    };
    try std.testing.expectEqual(
        config_mod.AdapterKind.openai_responses,
        AgentRuntime.adapterForConfig(.openai_compatible, config).?,
    );
}

test "runtime keeps codex adapter for openai provider" {
    const config: config_mod.Config = .{ .use_responses_endpoint = true };
    try std.testing.expectEqual(
        config_mod.AdapterKind.codex_responses,
        AgentRuntime.adapterForConfig(.openai, config).?,
    );
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
