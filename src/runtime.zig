const std = @import("std");

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
const session_mod = @import("session.zig");

const assert = std.debug.assert;

pub const AgentRuntime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    client: ai.LanguageModel,
    system_prompt: []const u8,
    session_writer: session_mod.SessionWriter,
    agent: agent_mod.Agent,

    pub fn initNew(
        target: *AgentRuntime,
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        client: ai.LanguageModel,
        system_prompt: []const u8,
    ) !void {
        assert(cwd.len > 0);
        assert(system_prompt.len > 0);
        target.* = .{
            .gpa = gpa,
            .io = io,
            .cwd = cwd,
            .client = client,
            .system_prompt = system_prompt,
            .session_writer = undefined,
            .agent = undefined,
        };
        try target.session_writer.initDefault(gpa, io, cwd);
        errdefer target.session_writer.deinit();

        target.agent = agent_mod.Agent.init(gpa, io, cwd, client);
        errdefer target.agent.deinit();
        target.agent.attachSessionWriter(&target.session_writer);
        try target.agent.addSystem(system_prompt);
    }

    pub fn initResume(
        target: *AgentRuntime,
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        client: ai.LanguageModel,
        system_prompt: []const u8,
        session_id: []const u8,
    ) !void {
        assert(cwd.len > 0);
        assert(session_id.len > 0);
        target.* = .{
            .gpa = gpa,
            .io = io,
            .cwd = cwd,
            .client = client,
            .system_prompt = system_prompt,
            .session_writer = undefined,
            .agent = undefined,
        };
        try target.session_writer.initResumeDefault(gpa, io, cwd, session_id);
        errdefer target.session_writer.deinit();

        target.agent = agent_mod.Agent.init(gpa, io, cwd, client);
        errdefer target.agent.deinit();
        target.agent.attachSessionWriter(&target.session_writer);
        try target.agent.addSystem(system_prompt);
        const messages = try target.session_writer.session.messages(gpa);
        defer gpa.free(messages);
        for (messages) |message| try target.agent.takeMessage(message);
    }

    pub fn deinit(self: *AgentRuntime) void {
        self.agent.deinit();
        self.session_writer.deinit();
        self.* = undefined;
    }
};
