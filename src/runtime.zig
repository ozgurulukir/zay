const std = @import("std");

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
const codex_mod = @import("codex.zig");
const config_mod = @import("config.zig");
const session_mod = @import("session.zig");
const tools_mod = @import("tools.zig");

const assert = std.debug.assert;

pub const AgentRuntime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home_dir: []const u8,
    client: ai.LanguageModel,
    system_prompt: []const u8,
    session_writer: session_mod.SessionWriter,
    agent: agent_mod.Agent,
    diagnostics: []config_mod.Diagnostic,
    owned_codex_responses: ?*ai.codex_responses.Client = null,
    owned_openai_compatible: ?*ai.openai_compatible.Client = null,
    owned_openai_responses: ?*ai.openai_responses.Client = null,

    pub fn initNew(
        target: *AgentRuntime,
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        home_dir: []const u8,
        system_prompt: []const u8,
        config: config_mod.Config,
        diagnostics: []config_mod.Diagnostic,
    ) !void {
        assert(cwd.len > 0);
        assert(system_prompt.len > 0);
        const owned_system_prompt = try gpa.dupe(u8, system_prompt);
        errdefer gpa.free(owned_system_prompt);
        target.* = .{
            .gpa = gpa,
            .io = io,
            .cwd = cwd,
            .home_dir = home_dir,
            .client = .none,
            .system_prompt = owned_system_prompt,
            .session_writer = undefined,
            .agent = undefined,
            .diagnostics = diagnostics,
        };
        try target.session_writer.initDefault(gpa, io, cwd);
        errdefer target.session_writer.deinit();

        target.agent = agent_mod.Agent.init(gpa, io, cwd, .none);
        errdefer target.agent.deinit();
        target.agent.attachSessionWriter(&target.session_writer);
        try target.agent.addSystem(owned_system_prompt);

        try target.applyFromConfig(config);
    }

    pub fn initResume(
        target: *AgentRuntime,
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        home_dir: []const u8,
        system_prompt: []const u8,
        config: config_mod.Config,
        diagnostics: []config_mod.Diagnostic,
        session_id: []const u8,
    ) !void {
        assert(cwd.len > 0);
        assert(session_id.len > 0);
        const owned_system_prompt = try gpa.dupe(u8, system_prompt);
        errdefer gpa.free(owned_system_prompt);
        target.* = .{
            .gpa = gpa,
            .io = io,
            .cwd = cwd,
            .home_dir = home_dir,
            .client = .none,
            .system_prompt = owned_system_prompt,
            .session_writer = undefined,
            .agent = undefined,
            .diagnostics = diagnostics,
        };
        try target.session_writer.initResumeDefault(gpa, io, cwd, session_id);
        errdefer target.session_writer.deinit();

        target.agent = agent_mod.Agent.init(gpa, io, cwd, .none);
        errdefer target.agent.deinit();
        target.agent.attachSessionWriter(&target.session_writer);
        try target.agent.addSystem(owned_system_prompt);
        const messages = try target.session_writer.session.messages(gpa);
        defer gpa.free(messages);
        for (messages) |message| try target.agent.takeMessage(message);

        try target.applyFromConfig(config);
    }

    pub fn deinit(self: *AgentRuntime) void {
        self.agent.deinit();
        self.session_writer.deinit();
        self.gpa.free(self.system_prompt);
        if (self.owned_codex_responses) |c| {
            c.deinit();
            self.gpa.destroy(c);
        }
        if (self.owned_openai_compatible) |c| {
            c.deinit();
            self.gpa.destroy(c);
        }
        if (self.owned_openai_responses) |c| {
            c.deinit();
            self.gpa.destroy(c);
        }
        for (self.diagnostics) |*d| d.deinit(self.gpa);
        self.gpa.free(self.diagnostics);
        self.* = undefined;
    }

    /// Pick and wire the LanguageModel adapter specified in `config`.
    /// Also handles providers that require sign-in (codex).
    pub fn applyFromConfig(self: *AgentRuntime, config: config_mod.Config) !void {
        const provider = config.provider orelse return;
        const adapter = adapterForConfig(provider, config) orelse return;
        switch (adapter) {
            .codex_responses => try self.tryConnectCodexFromAuth(config),
            .openai_compatible => try self.tryAttachOpenAiCompatibleFromConfig(provider, config),
            .openai_responses => try self.tryAttachOpenAiResponsesFromConfig(provider, config),
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
        const model_id = if (config.model) |m| m.id else "gpt-5.5";
        const effort = if (config.model) |m| (m.reasoning_effort orelse .medium) else .medium;
        try self.connectCodexClient(creds, model_id, effort);
    }

    fn tryAttachOpenAiCompatibleFromConfig(
        self: *AgentRuntime,
        provider: config_mod.Provider,
        config: config_mod.Config,
    ) !void {
        const base_url = config.base_url orelse provider.defaultBaseUrl() orelse return;
        const api_key = config.api_key orelse "";
        const model_id = if (config.model) |m| m.id else return;
        try self.attachOpenAiCompatibleClient(base_url, api_key, model_id);
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
            .responses_mode = .codex,
            .account_id = credentials.account_id,
            .session_id = &self.session_writer.session.id,
            .system_prompt = self.system_prompt,
        });
        errdefer client.deinit();
        if (self.owned_codex_responses) |old| {
            old.deinit();
            self.gpa.destroy(old);
        }
        self.owned_codex_responses = client;
        self.client = .{ .codex_responses = client };
        self.agent.client = self.client;
    }

    pub fn disconnectCodexClient(self: *AgentRuntime) void {
        if (self.owned_codex_responses) |client| {
            client.deinit();
            self.gpa.destroy(client);
            self.owned_codex_responses = null;
        }
        if (self.client == .codex_responses) {
            self.client = .none;
            self.agent.client = .none;
        }
    }

    pub fn attachOpenAiCompatibleClient(
        self: *AgentRuntime,
        base_url: []const u8,
        api_key: []const u8,
        model_id: []const u8,
    ) !void {
        const client = try self.gpa.create(ai.openai_compatible.Client);
        errdefer self.gpa.destroy(client);
        try client.init(self.gpa, self.io, .{
            .base_url = base_url,
            .api_key = api_key,
            .model = model_id,
            .tools = tools_mod.registry,
            .reasoning = .{},
            .responses_mode = .standard,
        });
        errdefer client.deinit();
        if (self.owned_openai_compatible) |old| {
            old.deinit();
            self.gpa.destroy(old);
        }
        self.owned_openai_compatible = client;
        self.client = .{ .openai_compatible = client };
        self.agent.client = self.client;
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
            .responses_mode = .standard,
        });
        errdefer client.deinit();
        if (self.owned_openai_responses) |old| {
            old.deinit();
            self.gpa.destroy(old);
        }
        self.owned_openai_responses = client;
        self.client = .{ .openai_responses = client };
        self.agent.client = self.client;
    }
};

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
