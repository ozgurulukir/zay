const std = @import("std");
const builtin = @import("builtin");

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
    base_system_prompt: []const u8,
    system_prompt: []const u8,
    session_writer: session_mod.SessionWriter,
    agent: agent_mod.Agent,
    diagnostics: []config_mod.Diagnostic,
    owned_client: ?OwnedClient = null,

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
        const owned_system_prompt = try createSystemPromptWithContext(gpa, io, owned_base_system_prompt, cwd);
        errdefer gpa.free(owned_system_prompt);

        target.* = .{
            .gpa = gpa,
            .io = io,
            .cwd = cwd,
            .home_dir = home_dir,
            .client = .none,
            .base_system_prompt = owned_base_system_prompt,
            .system_prompt = owned_system_prompt,
            .session_writer = undefined,
            .agent = undefined,
            .diagnostics = diagnostics,
        };

        if (session_id) |id| {
            try target.session_writer.initResumeDefault(gpa, io, cwd, id);
        } else {
            try target.session_writer.initDefault(gpa, io, cwd);
        }
        errdefer target.session_writer.deinit();

        target.agent = agent_mod.Agent.init(gpa, io, cwd, .none);
        errdefer target.agent.deinit();
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
    }

    pub fn deinit(self: *AgentRuntime) void {
        self.agent.deinit();
        self.session_writer.deinit();
        self.gpa.free(self.base_system_prompt);
        self.gpa.free(self.system_prompt);
        if (self.owned_client) |client| client.deinit(self.gpa);
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
            .session_id = &self.session_writer.session.id,
            .system_prompt = self.system_prompt,
        });
        errdefer client.deinit();
        self.replaceClient(.{ .codex_responses = client });
    }

    pub fn disconnectCodexClient(self: *AgentRuntime) void {
        const owned_client = self.owned_client orelse return;
        if (owned_client != .codex_responses) return;
        owned_client.deinit(self.gpa);
        self.owned_client = null;
        self.client = .none;
        self.agent.client = .none;
    }

    pub fn hasCodexClient(self: *const AgentRuntime) bool {
        const owned_client = self.owned_client orelse return false;
        return owned_client == .codex_responses;
    }

    pub fn disconnectClient(self: *AgentRuntime) void {
        const owned_client = self.owned_client orelse return;
        owned_client.deinit(self.gpa);
        self.owned_client = null;
        self.client = .none;
        self.agent.client = .none;
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
        });
        errdefer client.deinit();
        self.replaceClient(.{ .openai_compatible = client });
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
            .session_id = &self.session_writer.session.id,
            .system_prompt = self.system_prompt,
        });
        errdefer client.deinit();
        self.replaceClient(.{ .openai_responses = client });
    }

    fn replaceClient(self: *AgentRuntime, next: OwnedClient) void {
        if (self.owned_client) |old| old.deinit(self.gpa);
        self.owned_client = next;
        self.client = next.languageModel();
        self.agent.client = self.client;
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
    return try std.mem.replaceOwned(u8, gpa, cwd_resolved, "${OS}", os_label);
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
) ![]u8 {
    const system_prompt = try createSystemPrompt(gpa, base_system_prompt, cwd);
    errdefer gpa.free(system_prompt);

    const maybe_context = try readContextFile(gpa, io, cwd);
    defer if (maybe_context) |context| gpa.free(context);

    if (maybe_context) |context| {
        const combined = try std.fmt.allocPrint(
            gpa,
            "{s}\n\n<project_instructions path=\"AGENTS.md\">\n{s}\n</project_instructions>\n",
            .{ system_prompt, context },
        );
        gpa.free(system_prompt);
        return combined;
    }

    return system_prompt;
}

const os_label: []const u8 = switch (builtin.os.tag) {
    .windows => "Windows",
    .linux => "Linux",
    .macos => "macOS",
    .freebsd => "FreeBSD",
    .netbsd => "NetBSD",
    .openbsd => "OpenBSD",
    else => @tagName(builtin.os.tag),
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
