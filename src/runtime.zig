const std = @import("std");

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
const codex_mod = @import("codex.zig");
const compaction = @import("compaction.zig");
const config_mod = @import("config.zig");
const os = @import("os.zig");
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
    skills: []skill_mod.Skill,
    session_writer: session_mod.SessionWriter,
    agent: agent_mod.Agent,
    diagnostics: []config_mod.Diagnostic,
    codex_connection_expired: bool = false,
    owned_client: ?OwnedClient = null,
    /// Second client, same config as `owned_client`, used only by the agent's
    /// background summarizer so the two never share a connection.
    owned_compaction_client: ?OwnedClient = null,

    pub const ClientState = union(enum) {
        disconnected,
        connected: ai.LanguageModel,
    };

    const OwnedClient = union(enum) {
        codex_responses: *ai.codex_responses.Client,
        openai_compatible: *ai.openai_compatible.Client,
        openai_responses: *ai.openai_responses.Client,

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
                .openai_responses => |client| {
                    client.deinit();
                    gpa.destroy(client);
                },
            }
        }

        fn languageModel(self: OwnedClient) ai.LanguageModel {
            return switch (self) {
                .codex_responses => |client| .{ .codex_responses = client },
                .openai_compatible => |client| .{ .openai_compatible = client },
                .openai_responses => |client| .{ .openai_responses = client },
            };
        }
    };

    pub fn initNew(
        target: *AgentRuntime,
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        home_dir: []const u8,
        base_system_prompt: []const u8,
        config: config_mod.Config,
        diagnostics: []config_mod.Diagnostic,
    ) !void {
        try target.initSession(gpa, io, cwd, home_dir, base_system_prompt, config, diagnostics, null);
    }

    pub fn initResume(
        target: *AgentRuntime,
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        home_dir: []const u8,
        base_system_prompt: []const u8,
        config: config_mod.Config,
        diagnostics: []config_mod.Diagnostic,
        session_id: []const u8,
    ) !void {
        assert(session_id.len > 0);
        try target.initSession(gpa, io, cwd, home_dir, base_system_prompt, config, diagnostics, session_id);
    }

    fn initSession(
        target: *AgentRuntime,
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        home_dir: []const u8,
        base_system_prompt: []const u8,
        config: config_mod.Config,
        diagnostics: []config_mod.Diagnostic,
        session_id: ?[]const u8,
    ) !void {
        assert(cwd.len > 0);
        assert(base_system_prompt.len > 0);
        if (session_id) |id| assert(id.len > 0);

        const owned_base_system_prompt = try gpa.dupe(u8, base_system_prompt);
        errdefer gpa.free(owned_base_system_prompt);
        const skills = try skill_mod.loadProject(gpa, io, cwd);
        errdefer skill_mod.deinitAll(gpa, skills);
        const owned_system_prompt = try createSystemPromptWithContext(gpa, io, owned_base_system_prompt, cwd, skills);
        errdefer gpa.free(owned_system_prompt);

        target.* = .{
            .gpa = gpa,
            .io = io,
            .cwd = cwd,
            .home_dir = home_dir,
            .client = .none,
            .base_system_prompt = owned_base_system_prompt,
            .system_prompt = owned_system_prompt,
            .skills = skills,
            .session_writer = undefined,
            .agent = undefined,
            .diagnostics = diagnostics,
            .codex_connection_expired = false,
        };

        if (session_id) |id| {
            try target.session_writer.initResumeDefault(gpa, io, cwd, id);
        } else {
            try target.session_writer.initDefault(gpa, io, cwd);
        }
        errdefer target.session_writer.deinit();

        target.agent = agent_mod.Agent.init(gpa, io, cwd, .none);
        errdefer target.agent.deinit();
        target.agent.skills = target.skills;
        target.agent.attachSessionWriter(&target.session_writer);
        try target.agent.addSystem(owned_system_prompt);

        if (session_id != null) {
            const messages = try target.session_writer.session.messages(gpa);
            defer gpa.free(messages);
            for (messages) |message| try target.agent.takeMessage(message);
        }

        try target.applyFromConfig(config);
    }

    /// Rehydrate the agent's conversation from the session's current leaf.
    /// Call after `session_writer.navigate(...)` switches branches: clears the
    /// in-memory messages (keeping the system prompt) and reloads the new
    /// active path. Must not be called mid-turn.
    pub fn reloadMessages(self: *AgentRuntime) !void {
        self.agent.clearNonSystemMessages();
        const messages = try self.session_writer.messages(self.gpa);
        defer self.gpa.free(messages);
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
        skill_mod.deinitAll(self.gpa, self.skills);
        // `agent.deinit` above joined the summarizer thread, so its client is
        // no longer in use and is safe to free.
        if (self.owned_compaction_client) |client| client.deinit(self.gpa);
        if (self.owned_client) |client| client.deinit(self.gpa);
        for (self.diagnostics) |*d| d.deinit(self.gpa);
        self.gpa.free(self.diagnostics);
        self.* = undefined;
    }

    /// Pick and wire the LanguageModel adapter specified in `config`.
    /// Also handles providers that require sign-in (codex).
    pub fn applyFromConfig(self: *AgentRuntime, config: config_mod.Config) !void {
        const selection = config.activeModelSelection() orelse return;
        const adapter = adapterForConfig(selection.provider, config) orelse return;
        switch (adapter) {
            .codex_responses => try self.tryConnectCodexFromAuth(config),
            .openai_compatible => try self.tryAttachOpenAiCompatibleFromConfig(selection.provider, config),
            .openai_responses => try self.tryAttachOpenAiResponsesFromConfig(selection.provider, config),
        }
    }

    fn adapterForConfig(provider: config_mod.Provider, config: config_mod.Config) ?config_mod.AdapterKind {
        const adapter = provider.adapter() orelse return null;
        if (adapter == .openai_compatible) {
            if (config.use_responses_endpoint orelse false) return .openai_responses;
        }
        return adapter;
    }

    fn tryConnectCodexFromAuth(self: *AgentRuntime, config: config_mod.Config) !void {
        if (self.home_dir.len == 0) return;
        var creds = (codex_mod.load(self.gpa, self.io, self.home_dir) catch null) orelse return;
        defer creds.deinit(self.gpa);
        try self.refreshCodexCredentialsIfNeeded(&creds);
        if (self.codex_connection_expired) return;
        const model_id = if (config.model) |m| m.id else "gpt-5.5";
        const effort = if (config.model) |m| (m.reasoning_effort orelse .medium) else .medium;
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
            std.log.warn("codex.refresh.failed err={s}", .{@errorName(err)});
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
        const base_url = config.base_url orelse provider.defaultBaseUrl() orelse return;
        const model = config.model orelse return;
        const effort = model.reasoning_effort orelse .medium;
        var loaded_key: ?[]u8 = null;
        defer if (loaded_key) |k| self.gpa.free(k);
        const api_key = config.api_key orelse blk: {
            if (provider.isCatalogue() and self.home_dir.len > 0) {
                loaded_key = codex_mod.loadProviderApiKey(self.gpa, self.io, self.home_dir, provider.label()) catch null;
                if (loaded_key) |k| break :blk k;
            }
            // No stored key — use the anonymous sentinel (e.g. OpenCode Zen's
            // `public`) when the provider supports it, else send no key.
            break :blk provider.anonymousApiKey() orelse "";
        };
        try self.attachOpenAiCompatibleClient(base_url, api_key, model.id, effort);
    }

    fn tryAttachOpenAiResponsesFromConfig(
        self: *AgentRuntime,
        provider: config_mod.Provider,
        config: config_mod.Config,
    ) !void {
        const base_url = config.base_url orelse provider.defaultBaseUrl() orelse return;
        const api_key = config.api_key orelse "";
        const model_id = if (config.model) |m| m.id else return;
        const reasoning: ai.Reasoning = if (config.model) |m|
            .{ .effort = m.reasoning_effort orelse .medium, .summary = .auto }
        else
            .{};
        try self.attachOpenAiResponsesClient(base_url, api_key, model_id, reasoning);
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
        const client = try self.gpa.create(ai.codex_responses.Client);
        errdefer self.gpa.destroy(client);
        try client.init(self.gpa, self.io, .{
            .base_url = "https://chatgpt.com/backend-api",
            .api_key = credentials.access,
            .model = model_id,
            .tools = tools_mod.registry,
            .reasoning = .{ .effort = effort, .summary = .auto },
            .account_id = credentials.account_id,
            .session_id = self.session_writer.session.id.slice(),
            .system_prompt = self.system_prompt,
        });
        errdefer client.deinit();
        self.replaceClient(.{ .codex_responses = client });
        self.agent.context_window_tokens = compaction.contextWindowTokens(model_id);

        attach_compaction: {
            const compaction_client = self.gpa.create(ai.codex_responses.Client) catch break :attach_compaction;
            compaction_client.init(self.gpa, self.io, .{
                .base_url = "https://chatgpt.com/backend-api",
                .api_key = credentials.access,
                .model = model_id,
                .tools = tools_mod.registry,
                .reasoning = .{ .effort = effort, .summary = .auto },
                .account_id = credentials.account_id,
                .session_id = self.session_writer.session.id.slice(),
                .system_prompt = self.system_prompt,
            }) catch {
                self.gpa.destroy(compaction_client);
                break :attach_compaction;
            };
            self.setCompactionClient(.{ .codex_responses = compaction_client });
        }
        self.codex_connection_expired = false;
    }

    pub fn disconnectCodexClient(self: *AgentRuntime) void {
        const owned_client = self.owned_client orelse return;
        if (owned_client != .codex_responses) return;
        self.clearCompactionClient();
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
        owned_client.deinit(self.gpa);
        self.owned_client = null;
        self.client = .none;
        self.agent.client = .none;
        self.assertClientInvariant();
    }

    pub fn attachOpenAiCompatibleClient(
        self: *AgentRuntime,
        base_url: []const u8,
        api_key: []const u8,
        model_id: []const u8,
        effort: ai.ReasoningEffort,
    ) !void {
        const client = try self.gpa.create(ai.openai_compatible.Client);
        errdefer self.gpa.destroy(client);
        try client.init(self.gpa, self.io, .{
            .base_url = base_url,
            .api_key = api_key,
            .model = model_id,
            .tools = tools_mod.registry,
            .reasoning = .{ .effort = effort },
            .session_id = self.session_writer.session.id.slice(),
        });
        errdefer client.deinit();
        self.replaceClient(.{ .openai_compatible = client });
        self.agent.context_window_tokens = compaction.contextWindowTokens(model_id);

        attach_compaction: {
            const compaction_client = self.gpa.create(ai.openai_compatible.Client) catch break :attach_compaction;
            compaction_client.init(self.gpa, self.io, .{
                .base_url = base_url,
                .api_key = api_key,
                .model = model_id,
                .tools = tools_mod.registry,
                .reasoning = .{ .effort = effort },
            }) catch {
                self.gpa.destroy(compaction_client);
                break :attach_compaction;
            };
            self.setCompactionClient(.{ .openai_compatible = compaction_client });
        }
    }

    pub fn attachOpenAiResponsesClient(
        self: *AgentRuntime,
        base_url: []const u8,
        api_key: []const u8,
        model_id: []const u8,
        reasoning: ai.Reasoning,
    ) !void {
        const client = try self.gpa.create(ai.openai_responses.Client);
        errdefer self.gpa.destroy(client);
        try client.init(self.gpa, self.io, .{
            .base_url = base_url,
            .api_key = api_key,
            .model = model_id,
            .tools = tools_mod.registry,
            .reasoning = reasoning,
            .session_id = self.session_writer.session.id.slice(),
            .system_prompt = self.system_prompt,
        });
        errdefer client.deinit();
        self.replaceClient(.{ .openai_responses = client });
        self.agent.context_window_tokens = compaction.contextWindowTokens(model_id);

        attach_compaction: {
            const compaction_client = self.gpa.create(ai.openai_responses.Client) catch break :attach_compaction;
            compaction_client.init(self.gpa, self.io, .{
                .base_url = base_url,
                .api_key = api_key,
                .model = model_id,
                .tools = tools_mod.registry,
                .reasoning = reasoning,
                .session_id = self.session_writer.session.id.slice(),
                .system_prompt = self.system_prompt,
            }) catch {
                self.gpa.destroy(compaction_client);
                break :attach_compaction;
            };
            self.setCompactionClient(.{ .openai_responses = compaction_client });
        }
    }

    fn languageModelMatches(a: ai.LanguageModel, b: ai.LanguageModel) bool {
        return switch (a) {
            .none => b == .none,
            .codex_responses => |client| b == .codex_responses and b.codex_responses == client,
            .openai_compatible => |client| b == .openai_compatible and b.openai_compatible == client,
            .openai_responses => |client| b == .openai_responses and b.openai_responses == client,
        };
    }

    fn languageModelMatchesOwned(model: ai.LanguageModel, owned: OwnedClient) bool {
        return switch (owned) {
            .codex_responses => |client| model == .codex_responses and model.codex_responses == client,
            .openai_compatible => |client| model == .openai_compatible and model.openai_compatible == client,
            .openai_responses => |client| model == .openai_responses and model.openai_responses == client,
        };
    }

    fn replaceClient(self: *AgentRuntime, next: OwnedClient) void {
        self.codex_connection_expired = false;
        if (self.owned_client) |old| old.deinit(self.gpa);
        self.owned_client = next;
        self.client = next.languageModel();
        self.agent.client = self.client;
        self.assertClientInvariant();
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
};

/// Substitute the `${CWD}` and `${OS}` placeholders in a system-prompt template
/// with the working directory and host operating system. The template may come
/// from the embedded `src/prompts/system.md` or from a user-supplied override in
/// `config.json`
fn createSystemPrompt(gpa: std.mem.Allocator, template: []const u8, cwd: []const u8) ![]u8 {
    assert(template.len > 0);
    assert(cwd.len > 0);
    const cwd_resolved = try std.mem.replaceOwned(u8, gpa, template, "${CWD}", cwd);
    defer gpa.free(cwd_resolved);
    return try std.mem.replaceOwned(u8, gpa, cwd_resolved, "${OS}", os.label);
}

/// Reads AGENTS.md in the root directory if it exists. Returns null otherwise.
fn readContextFile(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) !?[]u8 {
    assert(cwd.len > 0);
    const context_file_path = try std.fs.path.join(gpa, &.{ cwd, "AGENTS.md" });
    defer gpa.free(context_file_path);
    return std.Io.Dir.readFileAllocOptions(
        .cwd(),
        io,
        context_file_path,
        gpa,
        .limited(64 * 1024),
        .of(u8),
        null,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn createSystemPromptWithContext(
    gpa: std.mem.Allocator,
    io: std.Io,
    base_system_prompt: []const u8,
    cwd: []const u8,
    skills: []const skill_mod.Skill,
) ![]u8 {
    const system_prompt = try createSystemPrompt(gpa, base_system_prompt, cwd);
    errdefer gpa.free(system_prompt);

    const maybe_context = try readContextFile(gpa, io, cwd);
    defer if (maybe_context) |context| gpa.free(context);
    const skill_prompt = try skill_mod.formatForPrompt(gpa, skills);
    defer gpa.free(skill_prompt);

    if (maybe_context) |context| {
        const combined = try std.fmt.allocPrint(
            gpa,
            "{s}\n\n<project_instructions path=\"AGENTS.md\">\n{s}\n</project_instructions>\n{s}",
            .{ system_prompt, context, skill_prompt },
        );
        gpa.free(system_prompt);
        return combined;
    }

    if (skill_prompt.len > 0) {
        const combined = try std.fmt.allocPrint(gpa, "{s}{s}", .{ system_prompt, skill_prompt });
        gpa.free(system_prompt);
        return combined;
    }

    return system_prompt;
}

fn codexRefreshNeeded(expires_ms: i64, now_ms: i64) bool {
    return expires_ms <= now_ms + codex_refresh_margin_ms;
}

test "codex refresh starts before token expiry" {
    const now_ms: i64 = 10_000;
    try std.testing.expect(codexRefreshNeeded(now_ms - 1, now_ms));
    try std.testing.expect(codexRefreshNeeded(now_ms + codex_refresh_margin_ms, now_ms));
    try std.testing.expect(!codexRefreshNeeded(now_ms + codex_refresh_margin_ms + 1, now_ms));
}

test "runtime selects responses adapter when requested" {
    const config: config_mod.Config = .{ .use_responses_endpoint = true };
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
    const rendered = try createSystemPrompt(gpa, "header\nYou are in ${CWD}.\n", "C:\\repos\\nova");
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings("header\nYou are in C:\\repos\\nova.\n", rendered);
}

test "createSystemPrompt leaves a template without the placeholder untouched" {
    const gpa = std.testing.allocator;
    const rendered = try createSystemPrompt(gpa, "no placeholder here", "/tmp/nova");
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings("no placeholder here", rendered);
}

test "createSystemPrompt substitutes ${OS} with the host operating system" {
    const gpa = std.testing.allocator;
    const rendered = try createSystemPrompt(gpa, "OS: ${OS}", "/tmp/nova");
    defer gpa.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "${OS}") == null);
    try std.testing.expect(std.mem.startsWith(u8, rendered, "OS: "));
    try std.testing.expect(rendered.len > "OS: ".len);
}

test "readContextFile reads AGENTS.md when it exists" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var file = try tmp.dir.createFile(io, "AGENTS.md", .{ .truncate = true });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll("# Guidelines\nThis is a test.");
        try writer.interface.flush();
    }

    const cwd = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(cwd);

    const agents_md = (try readContextFile(gpa, io, cwd)) orelse return error.MissingContextFile;
    defer gpa.free(agents_md);
    try std.testing.expectEqualStrings("# Guidelines\nThis is a test.", agents_md);
}
