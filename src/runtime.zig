const std = @import("std");

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
const codex_mod = @import("auth/codex.zig");
const config_mod = @import("config/config.zig");
const connection = @import("runtime/connection.zig");
const session_init = @import("runtime/session_init.zig");
const prompt_refresh = @import("runtime/prompt_refresh.zig");
const context_assembly = @import("context/assembly.zig");
const modelsdev = @import("models/registry.zig");
const plugin_prompt = @import("plugin_prompt.zig");
const plugin_manager_mod = @import("lua/manager.zig");
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
        try session_init.initSession(target, genesis);
    }

    pub fn initResume(target: *AgentRuntime, genesis: Genesis) !void {
        assert(genesis.session_id != null);
        try session_init.initSession(target, genesis);
    }

    /// Rehydrate the agent's conversation from the session's current leaf.
    /// Unchanged-signature delegate: the body moved to
    /// `runtime/session_init.zig` (`reloadMessages`) in issue #367 slice 13.
    pub fn reloadMessages(self: *AgentRuntime) !void {
        return session_init.reloadMessages(self);
    }

    /// Refresh turn-scoped context on the worker, before user messages enter
    /// history. Unchanged-signature delegate: the body moved to
    /// `runtime/prompt_refresh.zig` (`reconcilePluginPrompts`) in issue #367
    /// slice 13.
    pub fn reconcilePluginPrompts(self: *AgentRuntime, manager: *const plugin_manager_mod.PluginManager) !void {
        return prompt_refresh.reconcilePluginPrompts(self, manager);
    }

    /// Snapshot-guarded Git/rules system-prompt refresh.
    /// Unchanged-signature delegate: the body moved to
    /// `runtime/prompt_refresh.zig` (`refreshSystemPrompt`) in issue #367
    /// slice 13.
    pub fn refreshSystemPrompt(self: *AgentRuntime, cwd: []const u8) !void {
        return prompt_refresh.refreshSystemPrompt(self, cwd);
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
