const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
const codex = @import("codex.zig");
const config_mod = @import("config.zig");
const openai_compatible_mod = @import("ai/openai_compatible.zig");
const runtime_mod = @import("runtime.zig");
const session_mod = @import("session.zig");
const thread_mod = @import("thread.zig");
const tools_mod = @import("tools.zig");

const Render = thread_mod.Render;

const ToolPolicy = struct {
    expand_by_default: bool,
    render: Render,
};

const tool_policies = [_]struct { name: []const u8, policy: ToolPolicy }{
    .{ .name = "bash", .policy = .{ .expand_by_default = false, .render = .plain } },
    .{ .name = "read", .policy = .{ .expand_by_default = false, .render = .plain } },
    .{ .name = "search_codebase", .policy = .{ .expand_by_default = false, .render = .plain } },
    .{ .name = "write_file", .policy = .{ .expand_by_default = true, .render = .plain } },
    .{ .name = "edit_file", .policy = .{ .expand_by_default = true, .render = .diff } },
};

comptime {
    // Every tool in the registry has a policy entry.
    for (tools_mod.registry) |tool| {
        var found = false;
        for (tool_policies) |p| if (std.mem.eql(u8, p.name, tool.name)) {
            found = true;
        };
        if (!found) @compileError("missing TUI policy for tool: " ++ tool.name);
    }
    // Every policy entry maps to a registry tool — no orphans.
    for (tool_policies) |p| {
        var found = false;
        for (tools_mod.registry) |tool| if (std.mem.eql(u8, p.name, tool.name)) {
            found = true;
        };
        if (!found) @compileError("orphan TUI policy entry: " ++ p.name);
    }
}

fn policyFor(name: []const u8) ToolPolicy {
    for (tool_policies) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.policy;
    }
    unreachable; // guaranteed by the comptime check above
}

const logo_bytes_max = 64 * 1024;
const loading_spinners = [4][]const u8{ "Firing Neurons", "Multiplying Matrices", "brr..brr...", "Warping" };
const loading_frames = [8][]const u8{ "⣼", "⣹", "⢻", "⠿", "⡟", "⣏", "⣧", "⣶" };
const loading_frame_ms = 40;
// TODO: Investigate jumpToItem as an alternative to handrolling logic
pub const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    agent: *agent_mod.Agent,
    runtime: ?*runtime_mod.AgentRuntime = null,
    thread: thread_mod.Thread = .{},
    input: vxfw.TextField,
    worker_context: AgentWorkerContext,
    turn_future: ?std.Io.Future(void) = null,
    owns_runtime: bool = false,
    mode: Mode = .normal,
    command_selection: u32 = 0,
    resume_selection: u32 = 0,
    resume_global: bool = false,
    resume_summaries: std.ArrayList(session_mod.SessionSummary) = .empty,
    codex_models: std.ArrayList(codex.Model) = .empty,
    model_reasoning: std.ArrayList(u32) = .empty,
    model_selection: u32 = 0,
    model_column: ModelColumn = .model,
    model_reasoning_snapshot: std.ArrayList(u32) = .empty,
    model_selection_snapshot: u32 = 0,
    provider_selection: u32 = 0,
    cached_config: config_mod.Config = .{},
    cached_config_owned: bool = false,
    retired_threads: std.ArrayList(thread_mod.Thread) = .empty,
    in_flight: bool = false,
    loading_index: ?u32 = null,
    loading_frame: u8 = 0,
    loading_word_index: u8 = 0,
    loading_tick_active: bool = false,
    agent_index: ?u32 = null,
    thinking_index: ?u32 = null,
    tool_seen_in_response: bool = false,
    awaiting_tool_call: bool = false,
    pending_redraw: bool = false,
    thread_auto_scroll: bool = true,
    tool_indexes: std.ArrayList(?u32) = .empty,
    thread_list: vxfw.ListView = .{
        .children = .{ .slice = &.{} },
        .draw_cursor = false,
        .wheel_scroll = 4,
    },
    resume_list: vxfw.ListView = .{
        .children = .{ .slice = &.{} },
        .draw_cursor = false,
        .wheel_scroll = 3,
    },
    model_list: vxfw.ListView = .{
        .children = .{ .slice = &.{} },
        .draw_cursor = false,
        .wheel_scroll = 3,
    },

    const Mode = enum { normal, command, picker, provider_picker, model_picker };
    const ModelColumn = enum { model, reasoning };

    pub fn init(io: std.Io, gpa: std.mem.Allocator, agent: *agent_mod.Agent) App {
        return .{
            .io = io,
            .gpa = gpa,
            .agent = agent,
            .input = .init(gpa),
            .worker_context = .{
                .io = io,
                .gpa = agent.gpa,
                .agent = agent,
            },
        };
    }

    pub fn initRuntime(
        io: std.Io,
        gpa: std.mem.Allocator,
        runtime: *runtime_mod.AgentRuntime,
        config: config_mod.Config,
    ) App {
        var app = init(io, gpa, &runtime.agent);
        app.runtime = runtime;
        app.owns_runtime = true;
        app.cached_config = config;
        app.cached_config_owned = true;
        return app;
    }

    pub fn bindInputCallbacks(self: *App) void {
        self.input.userdata = self;
        self.input.onChange = inputChanged;
    }

    pub fn deinit(self: *App) void {
        self.awaitTurn();
        for (self.retired_threads.items) |*thread| thread.deinit(self.gpa);
        self.retired_threads.deinit(self.gpa);
        self.resumeClear();
        self.codexModelsClear();
        self.codex_models.deinit(self.gpa);
        self.model_reasoning.deinit(self.gpa);
        self.model_reasoning_snapshot.deinit(self.gpa);
        if (self.cached_config_owned) {
            self.cached_config.deinit(self.gpa);
            self.cached_config_owned = false;
        }
        if (self.owns_runtime) {
            if (self.runtime) |runtime| {
                runtime.deinit();
                self.gpa.destroy(runtime);
            }
        }
        self.worker_context.queue.deinit(self.worker_context.io, self.worker_context.gpa);
        self.tool_indexes.deinit(self.gpa);
        self.thread.deinit(self.gpa);
        self.input.deinit();
        self.* = undefined;
    }

    fn awaitTurn(self: *App) void {
        if (self.turn_future) |*future| {
            future.await(self.io);
            self.turn_future = null;
        }
    }

    pub fn beginSubmit(self: *App) !?u32 {
        if (self.in_flight) return null;
        const prompt = try self.input.toOwnedSlice();
        self.resetInputChangeTracking();
        defer self.gpa.free(prompt);
        if (prompt.len == 0) return null;

        if (self.runtime != null and self.runtime.?.client == .none) {
            _ = try self.thread.append(self.gpa, .user, "you", prompt);
            const message = try self.formatNoProviderMessage();
            defer self.gpa.free(message);
            _ = try self.thread.append(self.gpa, .agent, "agent", message);
            return null;
        }

        self.resetTurnState();
        _ = try self.thread.append(self.gpa, .user, "you", prompt);
        try self.agent.addUser(prompt);
        try self.appendLoading();
        self.in_flight = true;
        return self.loading_index;
    }

    fn formatNoProviderMessage(self: *App) ![]u8 {
        if (self.runtime) |rt| {
            for (rt.diagnostics) |d| {
                switch (d) {
                    .config_parse_error => |e| return std.fmt.allocPrint(
                        self.gpa,
                        "Failed to load {s}: {s}",
                        .{ e.path, e.reason },
                    ),
                    .bad_env_model => |raw| return std.fmt.allocPrint(
                        self.gpa,
                        "Invalid OPENAI_MODEL: expected <provider>/<model>, got '{s}'",
                        .{raw},
                    ),
                }
            }
        }
        if (self.cached_config.provider) |p| {
            if (p.adapter() == null) {
                return std.fmt.allocPrint(
                    self.gpa,
                    "Provider '{s}' is not yet supported in Nova.",
                    .{p.label()},
                );
            }
            if (p == .openai) {
                return self.gpa.dupe(u8, "No OpenAI Codex session — type :connect to sign in.");
            }
        }
        return self.gpa.dupe(
            u8,
            "No provider connected. Type :connect to pick one, or set OPENAI_MODEL=<provider>/<model>.",
        );
    }

    fn resetTurnState(self: *App) void {
        self.agent_index = null;
        self.thinking_index = null;
        self.loading_index = null;
        self.loading_frame = 0;
        self.loading_word_index = chooseLoadingWordIndex(self.io);
        self.tool_seen_in_response = false;
        self.awaiting_tool_call = true;
        self.pending_redraw = false;
        // Leave `thread_auto_scroll` alone — if the user has scrolled away
        // from the tail to read older context, submitting another message
        // should not yank them back. They can scroll down (or arrow-down)
        // to opt back into auto-follow.
        self.tool_indexes.clearRetainingCapacity();
    }

    pub fn startTurn(self: *App) !void {
        self.turn_future = try self.io.concurrent(runAgentTurn, .{
            self.agent,
            &self.worker_context,
        });
    }

    fn appendLoading(self: *App) !void {
        std.debug.assert(self.loading_index == null);
        std.debug.assert(self.loading_word_index < loading_spinners.len);
        self.loading_index = try self.thread.append(
            self.gpa,
            .status,
            loading_spinners[self.loading_word_index],
            "",
        );
    }

    fn removeLoading(self: *App) void {
        const index = self.loading_index orelse return;
        self.loading_index = null;
        if (index >= self.thread.messages.items.len) return;
        self.thread.remove(self.gpa, index);
        self.adjustIndexesAfterRemove(index);
    }

    fn adjustIndexesAfterRemove(self: *App, removed_index: u32) void {
        adjustOptionalIndex(&self.agent_index, removed_index);
        adjustOptionalIndex(&self.thinking_index, removed_index);
        for (self.tool_indexes.items) |*tool_index| adjustOptionalIndex(tool_index, removed_index);
    }

    fn advanceLoadingFrame(self: *App) void {
        std.debug.assert(loading_frames.len > 0);
        self.loading_frame +%= 1;
        if (self.loading_frame >= loading_frames.len) self.loading_frame = 0;
    }

    pub fn applyAgentEvent(self: *App, event: agent_mod.Agent.Event) !bool {
        switch (event) {
            .turn_started => return false,
            .response_delta => |delta| {
                self.removeLoading();
                if (delta.len == 0) return false;
                _ = try self.finishThinking();
                try self.applyContentDelta(delta);
                self.pending_redraw = true;
                return true;
            },
            .thinking_delta => |delta| {
                self.removeLoading();
                if (try self.applyReasoningDelta(delta)) {
                    self.pending_redraw = true;
                }
                return false;
            },
            .tool_delta => |tool| {
                const thinking_finished = try self.finishThinking();
                if (try self.applyToolDelta(tool)) {
                    self.pending_redraw = true;
                }
                if (thinking_finished) {
                    self.pending_redraw = true;
                }
                return false;
            },
            .delta_end => {
                const redraw = self.pending_redraw;
                self.pending_redraw = false;
                // Once the model has started streaming (reasoning, content, or
                // a tool call), we are committed to this turn — no need to put
                // the spinner back between chunks. The visible streaming text
                // is its own progress indicator, and any future "waiting" gap
                // (between tool batches, or before the next turn) is handled
                // by the explicit appendLoading sites.
                return redraw;
            },
            .tool_call_finished => |tool| {
                self.removeLoading();
                const thinking_finished = try self.finishThinking();
                return thinking_finished or try self.applyToolFinished(tool);
            },
            .tool_batch_finished => {
                self.removeLoading();
                const thinking_finished = try self.finishThinking();
                self.agent_index = null;
                self.thinking_index = null;
                self.tool_seen_in_response = false;
                self.awaiting_tool_call = false;
                self.tool_indexes.clearRetainingCapacity();
                try self.appendLoading();
                _ = thinking_finished;
                return true;
            },
            .turn_failed => |message| {
                self.removeLoading();
                _ = try self.thread.append(self.gpa, .agent, "agent", message);
                return true;
            },
            .turn_finished => {
                self.removeLoading();
                _ = try self.finishThinking();
                self.in_flight = false;
                self.awaitTurn();
                return true;
            },
        }
    }

    fn applyContentDelta(self: *App, delta: []const u8) !void {
        if (delta.len == 0) return;
        if (self.agent_index) |index| {
            try self.thread.appendAgentDelta(self.gpa, index, delta);
        } else {
            self.agent_index = try self.thread.append(self.gpa, .agent, "agent", delta);
        }
        if (!self.tool_seen_in_response) {
            self.selectGeneratedMessage(self.agent_index.?);
        }
    }

    fn finishThinking(self: *App) !bool {
        const index = self.thinking_index orelse return false;
        if (index >= self.thread.messages.items.len) return false;
        if (std.mem.eql(u8, self.thread.messages.items[index].title, "Thoughts")) return false;
        try self.thread.finishThinking(self.gpa, index);
        return true;
    }

    fn applyReasoningDelta(self: *App, delta: []const u8) !bool {
        if (delta.len == 0) return false;
        var visible_change = false;
        if (self.thinking_index) |index| {
            try self.thread.appendThinkingDelta(self.gpa, index, delta);
        } else if (self.agent_index) |agent_index| {
            self.thinking_index = try self.thread.insert(
                self.gpa,
                agent_index,
                .thinking,
                "Thinking...",
                delta,
            );
            self.agent_index = agent_index + 1;
            self.thread.select(self.thinking_index.?);
            visible_change = true;
        } else {
            self.thinking_index = try self.thread.append(self.gpa, .thinking, "Thinking...", delta);
            visible_change = true;
        }
        if (self.agent_index == null and !self.tool_seen_in_response) {
            self.selectGeneratedMessage(self.thinking_index.?);
        }
        return visible_change;
    }

    fn applyToolDelta(self: *App, tool: ai.ToolDelta) !bool {
        if (std.mem.eql(u8, tool.name, "bash")) {
            const command = agent_mod.parseCommand(self.gpa, tool.arguments) catch return false;
            self.gpa.free(command);
        }
        const title = try agent_mod.formatToolTitle(self.gpa, tool.name, tool.arguments);
        defer self.gpa.free(title);

        if (std.mem.eql(u8, tool.name, "bash")) self.removeLoading();

        var visible_change = false;
        if (self.toolThreadIndex(tool.index)) |index| {
            visible_change = !toolTitleMatchesCommand(self.thread.messages.items[index].title, title);
            try self.thread.updateTool(self.gpa, index, title);
        } else {
            const index = try self.thread.startTool(self.gpa, title);
            try self.putToolThreadIndex(tool.index, index);
            visible_change = true;
        }
        self.tool_seen_in_response = true;
        return visible_change;
    }

    fn applyToolFinished(self: *App, tool: agent_mod.Agent.Event.ToolCallFinished) !bool {
        const policy = policyFor(tool.name);
        const existing_index = self.toolThreadIndex(tool.index);
        const index = if (existing_index) |index| index else index: {
            const created = try self.thread.startTool(self.gpa, tool.display_label);
            try self.putToolThreadIndex(tool.index, created);
            break :index created;
        };

        const visible_before = self.toolFinishVisibleChange(index, tool.display_label);
        const was_expanded = self.thread.messages.items[index].expanded;
        try self.thread.updateTool(self.gpa, index, tool.display_label);
        try self.thread.finishTool(self.gpa, index, tool.display_body, tool.stderr, tool.failed);
        self.thread.messages.items[index].expanded = policy.expand_by_default;
        self.thread.messages.items[index].tool_render = policy.render;
        self.selectGeneratedMessage(index);
        self.tool_seen_in_response = true;
        return existing_index == null or visible_before or policy.expand_by_default != was_expanded;
    }

    fn selectGeneratedMessage(self: *App, index: u32) void {
        // Re-assert selection only when the user is already on this exact
        // message (or has no selection yet). A scrolled-up user, or a user
        // parked at the tail while an *earlier* message is being finished,
        // stays put.
        if (self.thread.selected) |selected| {
            if (selected != index) return;
        }
        self.thread.select(index);
    }

    fn toolFinishVisibleChange(self: *const App, index: u32, command: []const u8) bool {
        if (index >= self.thread.messages.items.len) return true;
        const message = self.thread.messages.items[index];
        if (message.kind != .tool) return true;
        if (message.expanded) return true;
        return !toolTitleMatchesCommand(message.title, command);
    }

    fn toolThreadIndex(self: *const App, tool_index: u32) ?u32 {
        if (tool_index >= self.tool_indexes.items.len) return null;
        return self.tool_indexes.items[tool_index];
    }

    fn putToolThreadIndex(self: *App, tool_index: u32, thread_index: u32) !void {
        while (self.tool_indexes.items.len <= tool_index) {
            try self.tool_indexes.append(self.gpa, null);
        }
        self.tool_indexes.items[tool_index] = thread_index;
    }

    pub fn handleCommandKey(self: *App, key: vaxis.Key) !bool {
        if (self.mode == .provider_picker) {
            if (key.matches(vaxis.Key.up, .{})) return true;
            if (key.matches(vaxis.Key.down, .{})) return true;
            return false;
        }
        if (self.mode == .model_picker) {
            if (key.matches(vaxis.Key.left, .{})) {
                self.model_column = .model;
                return true;
            }
            if (key.matches(vaxis.Key.right, .{})) {
                if (self.codex_models.items.len > 0) self.model_column = .reasoning;
                return true;
            }
            if (key.matches(vaxis.Key.tab, .{})) {
                if (self.model_column == .reasoning) try self.cycleSelectedReasoning();
                return true;
            }
            if (key.matches(vaxis.Key.up, .{})) {
                self.model_selection = previousIndex(self.model_selection, @intCast(self.codex_models.items.len));
                self.syncModelListCursor();
                return true;
            }
            if (key.matches(vaxis.Key.down, .{})) {
                self.model_selection = nextIndex(self.model_selection, @intCast(self.codex_models.items.len));
                self.syncModelListCursor();
                return true;
            }
            return false;
        }
        if (self.mode == .picker) {
            if (key.matches('g', .{})) {
                self.resume_global = !self.resume_global;
                try self.reloadResumeSessions();
                return true;
            }
            if (key.matches(vaxis.Key.up, .{})) {
                self.resume_selection = previousIndex(self.resume_selection, try self.visibleResumeCount());
                self.syncResumeListCursor();
                return true;
            }
            if (key.matches(vaxis.Key.down, .{})) {
                self.resume_selection = nextIndex(self.resume_selection, try self.visibleResumeCount());
                self.syncResumeListCursor();
                return true;
            }
            return false;
        }
        if (self.mode == .command) {
            if (key.matches(vaxis.Key.up, .{})) {
                self.command_selection = previousIndex(self.command_selection, commandMatchesCount(self));
                return true;
            }
            if (key.matches(vaxis.Key.down, .{})) {
                self.command_selection = nextIndex(self.command_selection, commandMatchesCount(self));
                return true;
            }
            return false;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            self.thread.moveSelection(.previous);
            self.thread_auto_scroll = false;
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            self.thread.moveSelection(.next);
            self.thread_auto_scroll = self.selectionIsLastMessage();
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            self.thread.toggleSelected();
            return true;
        }
        return false;
    }

    fn syncModeWithInput(self: *App, value: []const u8) !void {
        if (self.mode == .picker or self.mode == .provider_picker or self.mode == .model_picker) {
            if (value.len > 0) {
                if (value[0] == ':') {
                    self.mode = .command;
                    self.command_selection = 0;
                    return;
                }
            }
            if (self.mode == .picker) {
                if (self.resume_selection >= try self.visibleResumeCount()) self.resume_selection = 0;
            }
            return;
        }
        if (value.len == 0) {
            self.mode = .normal;
            self.command_selection = 0;
            return;
        }
        if (value[0] == ':') {
            self.mode = .command;
            const count = commandMatchesCountForFilter(value[1..]);
            if (self.command_selection >= count) self.command_selection = 0;
            return;
        }
        self.mode = .normal;
        self.command_selection = 0;
    }

    fn cancelMode(self: *App) !bool {
        if (self.mode == .normal) return false;
        if (self.mode == .model_picker) self.revertModelPickerSnapshot();
        if (self.mode == .picker or self.mode == .provider_picker or self.mode == .model_picker) {
            try self.openCommandMenu();
            self.resumeClear();
            return true;
        }
        self.mode = .normal;
        self.clearInput();
        self.resumeClear();
        return true;
    }

    fn revertModelPickerSnapshot(self: *App) void {
        self.model_reasoning.clearRetainingCapacity();
        self.model_reasoning.appendSlice(self.gpa, self.model_reasoning_snapshot.items) catch {};
        self.model_selection = self.model_selection_snapshot;
    }

    fn submitMode(self: *App) !bool {
        const input = try self.peekInput();
        defer self.gpa.free(input);
        if (self.mode == .provider_picker) {
            self.connectCodex() catch |err| try self.reportConnectionError(err);
            return true;
        }
        if (self.mode == .model_picker) {
            if (self.codex_models.items.len == 0) return true;
            self.applySelectedModel() catch |err| try self.reportConnectionError(err);
            return true;
        }
        if (self.mode == .picker) {
            const summary = try self.selectedResumeSummary() orelse return true;
            self.switchToSession(summary.id) catch |err| {
                try self.reportSessionSwitchError(err);
                return true;
            };
            return true;
        }
        if (input.len == 0) return false;
        if (input[0] != ':') return false;
        self.mode = .command;
        if (resolveCommand(self, input[1..])) |command| {
            self.clearInput();
            switch (command) {
                .new => self.switchToNewSession() catch |err| try self.reportSessionSwitchError(err),
                .resume_session => try self.openResumePicker(),
                .connect => try self.openProviderPicker(),
                .model => try self.openModelPicker(),
            }
        }
        return true;
    }

    fn openCommandMenu(self: *App) !void {
        self.mode = .command;
        self.clearInput();
        try self.input.insertSliceAtCursor(":");
        self.command_selection = 0;
    }

    fn openResumePicker(self: *App) !void {
        self.mode = .picker;
        self.resume_global = false;
        self.resume_selection = 0;
        self.clearInput();
        try self.reloadResumeSessions();
    }

    fn openProviderPicker(self: *App) !void {
        self.mode = .provider_picker;
        self.provider_selection = 0;
        self.clearInput();
    }

    fn openModelPicker(self: *App) !void {
        self.mode = .model_picker;
        self.model_column = .model;
        self.clearInput();
        if (self.codex_models.items.len == 0) {
            self.reloadCodexModels() catch {};
        }
        // Snapshot for Escape revert. See `cancelMode`.
        self.model_reasoning_snapshot.clearRetainingCapacity();
        try self.model_reasoning_snapshot.appendSlice(self.gpa, self.model_reasoning.items);
        self.model_selection_snapshot = self.model_selection;
    }

    fn connectCodex(self: *App) !void {
        if (self.in_flight) return error.InFlightTurn;
        var credentials = try codex.login(self.gpa, self.io, self.runtime.?.home_dir);
        defer credentials.deinit(self.gpa);
        try self.reloadCodexModels();
        const model = self.selectedCodexModel() orelse return error.NoModels;
        const effort = self.selectedReasoningEffort();
        try self.installCodexClient(credentials, model.id, effort);
        try self.persistCodexSelection(model.id, effort);
        self.mode = .normal;
        self.clearInput();
        _ = try self.thread.append(self.gpa, .agent, "agent", "Connected to OpenAI Codex.");
    }

    fn applySelectedModel(self: *App) !void {
        if (self.in_flight) return error.InFlightTurn;
        const loaded = try codex.load(self.gpa, self.io, self.runtime.?.home_dir);
        var credentials = loaded orelse return error.NotConnected;
        defer credentials.deinit(self.gpa);
        if (self.codex_models.items.len == 0) try self.reloadCodexModels();
        const model = self.selectedCodexModel() orelse return error.NoModels;
        const effort = self.selectedReasoningEffort();
        try self.installCodexClient(credentials, model.id, effort);
        try self.persistCodexSelection(model.id, effort);
        self.mode = .normal;
        self.clearInput();
    }

    fn persistCodexSelection(self: *App, model_id: []const u8, effort: ai.ReasoningEffort) !void {
        const new_id = try self.gpa.dupe(u8, model_id);
        errdefer self.gpa.free(new_id);
        if (self.cached_config_owned) {
            if (self.cached_config.model) |*old| old.deinit(self.gpa);
            self.cached_config.provider = .openai;
            self.cached_config.model = .{ .id = new_id, .reasoning_effort = effort };
        } else {
            self.gpa.free(new_id);
        }
        var updates: config_mod.Config = .{
            .provider = .openai,
            .model = .{
                .id = try self.gpa.dupe(u8, model_id),
                .reasoning_effort = effort,
            },
        };
        defer updates.deinit(self.gpa);
        config_mod.mergeAndWriteGlobal(self.gpa, self.io, self.runtime.?.home_dir, updates) catch |err| {
            std.log.warn("config.write.failed err={s}", .{@errorName(err)});
        };
    }

    fn reloadCodexModels(self: *App) !void {
        const models = try codex.loadStaticModels(self.gpa);
        self.codexModelsClear();
        try self.codex_models.appendSlice(self.gpa, models);
        self.gpa.free(models);
        self.model_reasoning.clearRetainingCapacity();
        try self.model_reasoning.appendNTimes(self.gpa, 0, self.codex_models.items.len);
        if (self.model_selection >= self.codex_models.items.len) self.model_selection = 0;
        self.syncModelListCursor();
    }

    fn selectedReasoningIndex(self: *App) u32 {
        if (self.model_selection >= self.model_reasoning.items.len) return 0;
        return self.model_reasoning.items[self.model_selection];
    }

    fn selectedReasoningEffort(self: *App) ai.ReasoningEffort {
        return reasoningOptions()[self.selectedReasoningIndex()].effort;
    }

    fn cycleSelectedReasoning(self: *App) !void {
        if (self.model_selection >= self.codex_models.items.len) return;
        while (self.model_reasoning.items.len < self.codex_models.items.len) {
            try self.model_reasoning.append(self.gpa, 0);
        }
        self.model_reasoning.items[self.model_selection] = nextIndex(self.model_reasoning.items[self.model_selection], @intCast(reasoningOptions().len));
    }

    fn selectedCodexModel(self: *App) ?codex.Model {
        if (self.model_selection >= self.codex_models.items.len) return null;
        return self.codex_models.items[self.model_selection];
    }

    fn codexModelsClear(self: *App) void {
        for (self.codex_models.items) |*model| model.deinit(self.gpa);
        self.codex_models.clearRetainingCapacity();
        self.model_reasoning.clearRetainingCapacity();
    }

    fn installCodexClient(
        self: *App,
        credentials: codex.Credentials,
        model: []const u8,
        effort: ai.ReasoningEffort,
    ) !void {
        try self.runtime.?.installCodexClient(credentials, model, effort);
        self.agent.client = self.runtime.?.client;
    }

    fn reloadResumeSessions(self: *App) !void {
        self.resumeClear();
        var manager = try session_mod.SessionManager.initDefault(self.gpa, self.io, self.runtime.?.cwd);
        defer manager.deinit();
        const cwd = if (self.resume_global) null else self.runtime.?.cwd;
        const summaries = try manager.list(self.gpa, cwd);
        try self.resume_summaries.appendSlice(self.gpa, summaries);
        if (self.resume_selection >= try self.visibleResumeCount()) self.resume_selection = 0;
        self.syncResumeListCursor();
    }

    fn selectedResumeSummary(self: *App) !?*session_mod.SessionSummary {
        const filter = try self.peekInput();
        defer self.gpa.free(filter);
        var visible_index: u32 = 0;
        for (self.resume_summaries.items) |*summary| {
            if (!resumeMatches(summary, filter)) continue;
            if (visible_index == self.resume_selection) return summary;
            visible_index += 1;
        }
        return null;
    }

    fn visibleResumeCount(self: *App) !u32 {
        const filter = try self.peekInput();
        defer self.gpa.free(filter);
        var count: u32 = 0;
        for (self.resume_summaries.items) |*summary| {
            if (resumeMatches(summary, filter)) count += 1;
        }
        return count;
    }

    fn resumeClear(self: *App) void {
        for (self.resume_summaries.items) |*summary| summary.deinit(self.gpa);
        self.resume_summaries.clearRetainingCapacity();
    }

    fn syncResumeListCursor(self: *App) void {
        self.resume_list.cursor = self.resume_selection;
        self.resume_list.ensureScroll();
    }

    fn syncModelListCursor(self: *App) void {
        self.model_list.cursor = self.model_selection;
        self.model_list.ensureScroll();
    }

    fn clearInput(self: *App) void {
        self.input.clearRetainingCapacity();
        self.resetInputChangeTracking();
    }

    fn resetInputChangeTracking(self: *App) void {
        self.input.buf.allocator.free(self.input.previous_val);
        self.input.previous_val = "";
    }

    fn reportSessionSwitchError(self: *App, err: anyerror) !void {
        self.mode = .normal;
        self.clearInput();
        var buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "Could not switch session: {s}", .{@errorName(err)}) catch "Could not switch session.";
        _ = try self.thread.append(self.gpa, .agent, "agent", message);
    }

    fn reportConnectionError(self: *App, err: anyerror) !void {
        self.mode = .normal;
        self.clearInput();
        var buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "Could not connect provider: {s}", .{@errorName(err)}) catch "Could not connect provider.";
        _ = try self.thread.append(self.gpa, .agent, "agent", message);
    }

    fn switchToNewSession(self: *App) !void {
        if (self.in_flight) return error.InFlightTurn;
        const runtime = try self.createRuntime(null);
        errdefer {
            runtime.deinit();
            self.gpa.destroy(runtime);
        }
        try self.installRuntime(runtime);
        try self.clearConversation();
    }

    fn switchToSession(self: *App, session_id: []const u8) !void {
        if (self.in_flight) return error.InFlightTurn;
        const runtime = try self.createRuntime(session_id);
        errdefer {
            runtime.deinit();
            self.gpa.destroy(runtime);
        }
        try self.installRuntime(runtime);
        try self.rebuildThreadFromAgent();
    }

    fn createRuntime(self: *App, session_id: ?[]const u8) !*runtime_mod.AgentRuntime {
        const current = self.runtime.?;
        const runtime = try self.gpa.create(runtime_mod.AgentRuntime);
        errdefer self.gpa.destroy(runtime);
        const diagnostics = try self.gpa.alloc(config_mod.Diagnostic, 0);
        errdefer self.gpa.free(diagnostics);
        if (session_id) |id| {
            try runtime.initResume(
                current.gpa,
                self.io,
                current.cwd,
                current.home_dir,
                current.system_prompt,
                self.cached_config,
                diagnostics,
                id,
            );
        } else {
            try runtime.initNew(
                current.gpa,
                self.io,
                current.cwd,
                current.home_dir,
                current.system_prompt,
                self.cached_config,
                diagnostics,
            );
        }
        return runtime;
    }

    fn installRuntime(self: *App, runtime: *runtime_mod.AgentRuntime) !void {
        if (self.in_flight) return error.InFlightTurn;
        self.runtime.?.deinit();
        self.gpa.destroy(self.runtime.?);
        self.runtime = runtime;
        self.agent = &runtime.agent;
        self.worker_context.agent = &runtime.agent;
        self.mode = .normal;
        self.clearInput();
        self.resetTurnState();
    }

    fn clearConversation(self: *App) !void {
        if (self.thread.messages.items.len > 0) {
            try self.retired_threads.append(self.gpa, self.thread);
        }
        self.thread = .{};
        self.thread_list.scroll = .{};
    }

    fn rebuildThreadFromAgent(self: *App) !void {
        try self.clearConversation();
        for (self.agent.messages.items) |message| {
            if (message.role == .system) continue;
            const text = message.text();
            if (message.role == .user) {
                _ = try self.thread.append(self.gpa, .user, "you", text);
            } else if (message.role == .assistant) {
                if (text.len > 0) _ = try self.thread.append(self.gpa, .agent, "agent", text);
            } else if (message.role == .tool) {
                const title = try self.resumedToolTitle(message.call_id);
                defer self.gpa.free(title);
                _ = try self.thread.append(self.gpa, .tool, title, text);
            }
        }
        if (self.thread.messages.items.len > 0) self.thread.selected = @intCast(self.thread.messages.items.len - 1);
    }

    fn resumedToolTitle(self: *App, call_id: ?[]const u8) ![]u8 {
        const id = call_id orelse return self.gpa.dupe(u8, "tool");
        for (self.agent.messages.items) |message| {
            for (message.content) |block| {
                if (block != .tool_call) continue;
                if (!std.mem.eql(u8, block.tool_call.call_id, id)) continue;
                return agent_mod.formatToolTitle(self.gpa, block.tool_call.name, block.tool_call.arguments);
            }
        }
        return self.gpa.dupe(u8, id);
    }

    fn peekInput(self: *App) ![]u8 {
        const left = self.input.buf.firstHalf();
        const right = self.input.buf.secondHalf();
        const out = try self.gpa.alloc(u8, left.len + right.len);
        @memcpy(out[0..left.len], left);
        @memcpy(out[left.len..], right);
        return out;
    }

    fn selectionIsLastMessage(self: *const App) bool {
        const selected = self.thread.selected orelse return false;
        if (self.thread.messages.items.len == 0) return false;
        return selected == self.thread.messages.items.len - 1;
    }
};

fn nextIndex(current: u32, count: u32) u32 {
    if (count == 0) return 0;
    if (current + 1 >= count) return 0;
    return current + 1;
}

fn previousIndex(current: u32, count: u32) u32 {
    if (count == 0) return 0;
    if (current == 0) return count - 1;
    return current - 1;
}

fn adjustOptionalIndex(index: *?u32, removed_index: u32) void {
    const current = index.* orelse return;
    if (current == removed_index) {
        index.* = null;
    } else if (current > removed_index) {
        index.* = current - 1;
    }
}

fn toolTitleMatchesCommand(title: []const u8, command: []const u8) bool {
    const prefix = "$ ";
    return std.mem.startsWith(u8, title, prefix) and
        std.mem.eql(u8, title[prefix.len..], command);
}

fn chooseLoadingWordIndex(io: std.Io) u8 {
    std.debug.assert(loading_spinners.len > 0);
    const timestamp: std.Io.Timestamp = .now(io, .awake);
    const index = @mod(timestamp.nanoseconds, loading_spinners.len);
    return @intCast(index);
}

const AgentEventQueue = struct {
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(*agent_mod.Agent.Event) = .empty,

    fn push(
        self: *AgentEventQueue,
        io: std.Io,
        gpa: std.mem.Allocator,
        event: *agent_mod.Agent.Event,
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.items.append(gpa, event);
    }

    fn drainInto(
        self: *AgentEventQueue,
        io: std.Io,
        gpa: std.mem.Allocator,
        sink: *std.ArrayList(*agent_mod.Agent.Event),
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try sink.appendSlice(gpa, self.items.items);
        self.items.clearRetainingCapacity();
    }

    fn deinit(self: *AgentEventQueue, io: std.Io, gpa: std.mem.Allocator) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        for (self.items.items) |event_ptr| {
            event_ptr.deinit(gpa);
            gpa.destroy(event_ptr);
        }
        self.items.deinit(gpa);
    }
};

const AgentWorkerContext = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    agent: *agent_mod.Agent,
    queue: AgentEventQueue = .{},
};

fn runAgentTurn(agent: *agent_mod.Agent, worker_context: *AgentWorkerContext) void {
    agent.run(.{
        .ptr = worker_context,
        .on_event = postAgentEvent,
    }) catch |err| {
        const message = std.fmt.allocPrint(
            worker_context.gpa,
            "agent turn failed: {s}",
            .{@errorName(err)},
        ) catch return;
        postAgentEvent(worker_context, .{ .turn_failed = message }) catch {
            worker_context.gpa.free(message);
            return;
        };
    };
    postAgentEvent(worker_context, .turn_finished) catch {};
}

fn postAgentEvent(context: *anyopaque, event: agent_mod.Agent.Event) anyerror!void {
    const worker_context: *AgentWorkerContext = @ptrCast(@alignCast(context));
    var owned_event = event;
    errdefer owned_event.deinit(worker_context.gpa);
    const event_ptr = try worker_context.gpa.create(agent_mod.Agent.Event);
    errdefer worker_context.gpa.destroy(event_ptr);
    event_ptr.* = owned_event;
    owned_event = .delta_end;
    errdefer event_ptr.deinit(worker_context.gpa);
    try worker_context.queue.push(worker_context.io, worker_context.gpa, event_ptr);
}

pub fn run(
    init: std.process.Init,
    runtime: *runtime_mod.AgentRuntime,
    config: config_mod.Config,
) !void {
    const gpa = init.arena.allocator();
    var tty_buffer: [8192]u8 = undefined;
    var fw_app = try vxfw.App.init(init.io, gpa, init.environ_map, &tty_buffer);
    defer fw_app.deinit();

    var app = App.initRuntime(init.io, gpa, runtime, config);
    app.bindInputCallbacks();
    defer app.deinit();

    const logo = try loadStartupLogo(init.io, gpa);
    defer gpa.free(logo);
    _ = try app.thread.append(gpa, .logo, "logo", logo);

    var root: RootWidget = .{ .app = &app };
    try fw_app.run(root.widget(), .{});
}

fn loadStartupLogo(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    var cwd = std.Io.Dir.cwd();
    return cwd.readFileAllocOptions(io, "src/assets/logo.txt", gpa, .limited(logo_bytes_max), .of(u8), 0);
}

const RootWidget = struct {
    app: *App,
    spinner_tick_accum: u32 = 0,

    fn widget(self: *RootWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .captureHandler = captureEvent,
            .eventHandler = handleEvent,
            .drawFn = drawRoot,
        };
    }

    fn captureEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                try ctx.requestFocus(self.app.input.widget());
                ctx.consumeAndRedraw();
            },
            .mouse => |mouse| {
                if (mouse.button == .wheel_up) self.app.thread_auto_scroll = false;
                if (mouse.button == .wheel_down) self.app.thread_auto_scroll = !self.app.thread_list.scroll.has_more;
            },
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{})) {
                    if (try self.app.cancelMode()) {
                        ctx.consumeAndRedraw();
                        return;
                    }
                    ctx.quit = true;
                    ctx.consume_event = true;
                    return;
                }
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    ctx.consume_event = true;
                    return;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    try self.submit(ctx);
                    return;
                }
                if (try self.app.handleCommandKey(key)) {
                    ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
    }

    fn handleEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        switch (event) {
            .tick => try self.handleTick(ctx),
            else => {},
        }
    }

    const drain_tick_ms: u32 = 30;
    const spinner_tick_threshold_ms: u32 = loading_frame_ms;

    fn handleTick(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        var visible_change = try self.drainAgentEvents(ctx);

        if (self.app.loading_index) |_| {
            self.spinner_tick_accum += drain_tick_ms;
            if (self.spinner_tick_accum >= spinner_tick_threshold_ms) {
                self.spinner_tick_accum = 0;
                self.app.advanceLoadingFrame();
                visible_change = true;
            }
        } else {
            self.spinner_tick_accum = 0;
        }

        const should_tick = self.app.in_flight or self.app.loading_index != null;
        if (should_tick) {
            try ctx.tick(drain_tick_ms, self.widget());
        } else {
            self.app.loading_tick_active = false;
        }

        if (visible_change) {
            ctx.consumeAndRedraw();
        } else {
            ctx.consumeEvent();
        }
    }

    fn startLoadingTick(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        if (self.app.loading_tick_active) return;
        self.app.loading_tick_active = true;
        self.spinner_tick_accum = 0;
        try ctx.tick(drain_tick_ms, self.widget());
    }

    fn submit(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        if (try self.app.submitMode()) {
            ctx.consumeAndRedraw();
            return;
        }
        const loading_index = (try self.app.beginSubmit()) orelse return;
        _ = loading_index;
        try self.app.startTurn();
        try self.startLoadingTick(ctx);
        ctx.consumeAndRedraw();
    }

    fn drainAgentEvents(self: *RootWidget, ctx: *vxfw.EventContext) !bool {
        const worker_io = self.app.worker_context.io;
        const worker_gpa = self.app.worker_context.gpa;
        var batch: std.ArrayList(*agent_mod.Agent.Event) = .empty;
        defer batch.deinit(worker_gpa);
        try self.app.worker_context.queue.drainInto(worker_io, worker_gpa, &batch);

        var visible_change = false;
        for (batch.items) |event_ptr| {
            defer worker_gpa.destroy(event_ptr);
            defer event_ptr.deinit(worker_gpa);

            if (self.app.loading_index != null) try self.startLoadingTick(ctx);
            if (try self.app.applyAgentEvent(event_ptr.*)) visible_change = true;
            if (self.app.loading_index != null) try self.startLoadingTick(ctx);
        }
        return visible_change;
    }

    fn drawRoot(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        const input_height: u16 = @min(max_height, 3);
        const panel_height: u16 = if (self.app.mode == .normal) 0 else @min(max_height -| input_height, 7);
        const thread_height: u16 = max_height - input_height - panel_height;

        var thread_view: ThreadWidget = .{ .app = self.app };
        var panel_view: PanelWidget = .{ .app = self.app };
        var input_view: InputWidget = .{ .app = self.app };

        const thread_ctx = ctx.withConstraints(
            .{ .width = max_width, .height = thread_height },
            .{ .width = max_width, .height = thread_height },
        );
        const panel_ctx = ctx.withConstraints(
            .{ .width = max_width, .height = panel_height },
            .{ .width = max_width, .height = panel_height },
        );
        const input_ctx = ctx.withConstraints(
            .{ .width = max_width, .height = input_height },
            .{ .width = max_width, .height = input_height },
        );

        const child_count: usize = if (panel_height == 0) 2 else 3;
        const children = try ctx.arena.alloc(vxfw.SubSurface, child_count);
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try thread_view.widget().draw(thread_ctx),
            .z_index = 0,
        };
        if (panel_height > 0) {
            children[1] = .{
                .origin = .{ .row = thread_height, .col = 0 },
                .surface = try panel_view.widget().draw(panel_ctx),
                .z_index = 0,
            };
            children[2] = .{
                .origin = .{ .row = thread_height + panel_height, .col = 0 },
                .surface = try input_view.widget().draw(input_ctx),
                .z_index = 0,
            };
        } else {
            children[1] = .{
                .origin = .{ .row = thread_height, .col = 0 },
                .surface = try input_view.widget().draw(input_ctx),
                .z_index = 0,
            };
        }

        return .{
            .size = .{ .width = max_width, .height = max_height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

const ConversationLayout = struct {
    const left: u16 = 2;
    const right: u16 = 2;
    const top: u16 = 1;
    const bottom: u16 = 1;

    fn verticalPadding() @TypeOf(vxfw.Padding.vertical(0)) {
        return .{
            .top = top,
            .bottom = bottom,
        };
    }

    fn contentWidth(width: u16) u16 {
        return width -| left -| right;
    }
};

const ThreadWidget = struct {
    app: *App,

    fn widget(self: *ThreadWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawThread,
        };
    }

    fn drawThread(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *ThreadWidget = @ptrCast(@alignCast(ptr));
        const widgets = try self.messageWidgets(ctx);
        self.app.thread_list.children = .{ .slice = widgets };
        self.app.thread_list.item_count = @intCast(widgets.len);
        self.syncCursor(ctx);

        var list_padding: vxfw.Padding = .{
            .child = self.app.thread_list.widget(),
            .padding = ConversationLayout.verticalPadding(),
        };
        return list_padding.widget().draw(ctx);
    }

    fn messageWidgets(self: *ThreadWidget, ctx: vxfw.DrawContext) ![]vxfw.Widget {
        const messages = self.app.thread.messages.items;
        const widgets = try ctx.arena.alloc(vxfw.Widget, messages.len);
        const bodies = try ctx.arena.alloc(MessageWidget, messages.len);
        for (messages, 0..) |message, index| {
            const selected = if (self.app.thread.selected) |selected_index| selected_index == index else false;
            bodies[index] = .{ .message = message, .selected = selected, .loading_frame = self.app.loading_frame };
            widgets[index] = bodies[index].widget();
        }
        return widgets;
    }

    fn syncCursor(self: *ThreadWidget, ctx: vxfw.DrawContext) void {
        // Auto-scroll follows the actual tail of the thread, NOT the user's
        // selection. The user can wheel-scroll to the bottom (turning auto-
        // scroll on) while their selection still points at an earlier
        // message — in that case we must keep them at the tail and leave
        // the selection untouched. Tying the scroll cursor to `selected`
        // here used to make every keystroke (which triggers a redraw via
        // the focused TextField) snap the viewport up to the selection.
        const messages = self.app.thread.messages.items;
        if (messages.len == 0) return;
        if (self.app.thread_auto_scroll) {
            const tail_index: u32 = @intCast(messages.len - 1);
            const cursor = self.app.loading_index orelse tail_index;
            self.app.thread_list.cursor = cursor;
            self.scrollCursorToTail(ctx, cursor);
            return;
        }
        const cursor = self.app.thread.selected orelse self.app.loading_index orelse 0;
        const cursor_changed = self.app.thread_list.cursor != cursor;
        self.app.thread_list.cursor = cursor;
        if (cursor_changed) self.app.thread_list.ensureScroll();
    }

    fn scrollCursorToTail(self: *ThreadWidget, ctx: vxfw.DrawContext, cursor: u32) void {
        if (cursor >= self.app.thread.messages.items.len) return;
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        const list_height = max_height -| ConversationLayout.top -| ConversationLayout.bottom;
        const message = self.app.thread.messages.items[cursor];
        const message_height = messageRows(message, ConversationLayout.contentWidth(max_width));
        self.app.thread_list.scroll.top = cursor;
        self.app.thread_list.scroll.pending_lines = 0;
        self.app.thread_list.scroll.wants_cursor = false;
        if (message_height > list_height) {
            self.app.thread_list.scroll.offset = @intCast(message_height - list_height);
        } else {
            self.app.thread_list.scroll.offset = 0;
        }
    }
};

const MessageWidget = struct {
    message: thread_mod.Message,
    selected: bool,
    loading_frame: u8,

    fn widget(self: *MessageWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = draw,
        };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *MessageWidget = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse ctx.min.width;
        const height = messageRows(self.message, ConversationLayout.contentWidth(width));
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = width,
            .height = height,
        });
        self.drawBody(&surface, ctx);
        return surface;
    }

    fn drawBody(self: *MessageWidget, surface: *vxfw.Surface, ctx: vxfw.DrawContext) void {
        var row: u16 = 0;
        fillRow(surface, row, self.selected);
        row += 1;
        switch (self.message.kind) {
            .user => drawWrapped(surface, self.message.body, StylePalette.user, self.selected, &row, ctx, 2, StylePalette.user),
            .agent => drawWrapped(surface, self.message.body, .{}, self.selected, &row, ctx, 0, null),
            .logo => drawLogo(surface, self.message.body, &row, ctx),
            .tool => {
                drawWrapped(surface, self.message.title, StylePalette.tool, self.selected, &row, ctx, 0, null);
                if (self.message.expanded) drawToolBody(surface, self.message, self.selected, &row, ctx);
            },
            .thinking => {
                drawLine(surface, self.message.title, StylePalette.thinking_label, self.selected, &row, ctx, 2, StylePalette.thinking_bar);
                if (self.message.expanded) drawWrapped(surface, self.message.body, StylePalette.thinking_body, self.selected, &row, ctx, 2, StylePalette.thinking_bar);
            },
            .status => drawLoading(surface, self.message.title, self.loading_frame, &row, ctx),
        }
        fillRow(surface, row, self.selected);
    }

    fn drawLoading(
        surface: *vxfw.Surface,
        text: []const u8,
        loading_frame: u8,
        row: *u16,
        ctx: vxfw.DrawContext,
    ) void {
        std.debug.assert(loading_frame < loading_frames.len);
        if (row.* >= surface.size.height) return;
        fillRow(surface, row.*, false);
        writeText(surface, loading_frames[loading_frame], StylePalette.thinking_label, false, row.*, ctx, 0);
        writeText(surface, text, StylePalette.thinking_body, false, row.*, ctx, 2);
        row.* += 1;
    }

    fn drawLogo(surface: *vxfw.Surface, text: []const u8, row: *u16, ctx: vxfw.DrawContext) void {
        var line_start: usize = 0;
        while (line_start <= text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            writeGradient(surface, text[line_start..line_end], row.*, ctx);
            row.* += 1;
            if (line_end == text.len) break;
            line_start = line_end + 1;
        }
    }

    fn drawWrapped(
        surface: *vxfw.Surface,
        text: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: *u16,
        ctx: vxfw.DrawContext,
        indent: u16,
        bar_style: ?vaxis.Style,
    ) void {
        const content_width = ConversationLayout.contentWidth(surface.size.width);
        const width = @max(@as(usize, content_width -| indent), 1);
        if (text.len == 0) {
            drawLine(surface, "", style, selected, row, ctx, indent, bar_style);
            return;
        }

        var line_start: usize = 0;
        while (line_start <= text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            if (line_start == line_end) {
                drawLine(surface, "", style, selected, row, ctx, indent, bar_style);
            } else {
                var chunk_start = line_start;
                while (chunk_start < line_end) {
                    const chunk_end = @min(chunk_start + width, line_end);
                    drawLine(surface, text[chunk_start..chunk_end], style, selected, row, ctx, indent, bar_style);
                    chunk_start = chunk_end;
                }
            }
            if (line_end == text.len) break;
            line_start = line_end + 1;
        }
    }

    fn drawLine(
        surface: *vxfw.Surface,
        text: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: *u16,
        ctx: vxfw.DrawContext,
        indent: u16,
        bar_style: ?vaxis.Style,
    ) void {
        if (row.* >= surface.size.height) return;
        fillRow(surface, row.*, selected);
        if (bar_style) |active_bar_style| writeText(surface, "┃", active_bar_style, selected, row.*, ctx, 0);
        writeText(surface, text, style, selected, row.*, ctx, indent);
        row.* += 1;
    }

    fn fillRow(surface: *vxfw.Surface, row: u16, selected: bool) void {
        if (!selected) return;
        var col: u16 = 0;
        while (col < surface.size.width) : (col += 1) {
            surface.writeCell(col, row, .{ .style = StylePalette.selected });
        }
    }

    fn writeText(
        surface: *vxfw.Surface,
        text: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: u16,
        ctx: vxfw.DrawContext,
        start_col: u16,
    ) void {
        var col = ConversationLayout.left + start_col;
        const col_limit = surface.size.width -| ConversationLayout.right;
        var iter = ctx.graphemeIterator(text);
        while (iter.next()) |grapheme| {
            if (col >= col_limit) return;
            const bytes = grapheme.bytes(text);
            const width: u8 = @intCast(ctx.stringWidth(bytes));
            if (width == 0) continue;
            if (col + width > col_limit) return;
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = bytes, .width = width },
                .style = mergedSelectedStyle(style, selected),
            });
            col += width;
        }
    }

    fn writeGradient(surface: *vxfw.Surface, text: []const u8, row: u16, ctx: vxfw.DrawContext) void {
        const gradient_width: u16 = @max(@min(ctx.stringWidth(text), std.math.maxInt(u16)), 1);
        var col: u16 = ConversationLayout.left;
        const col_limit = surface.size.width -| ConversationLayout.right;
        var iter = ctx.graphemeIterator(text);
        while (iter.next()) |grapheme| {
            if (col >= col_limit) return;
            const bytes = grapheme.bytes(text);
            const width: u8 = @intCast(ctx.stringWidth(bytes));
            if (width == 0) continue;
            if (col + width > col_limit) return;
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = bytes, .width = width },
                .style = gradientStyle(col - ConversationLayout.left, gradient_width, false),
            });
            col += width;
        }
    }
};

const Command = enum { connect, model, new, resume_session };
const commands = [_]struct { name: []const u8, command: Command }{
    .{ .name = "Connect", .command = .connect },
    .{ .name = "Models", .command = .model },
    .{ .name = "New", .command = .new },
    .{ .name = "Resume", .command = .resume_session },
};

fn inputLabel(app: *const App) []const u8 {
    return switch (app.mode) {
        .normal => "Build",
        .command => "Command",
        .picker => "Search for Sessions",
        .provider_picker => "Connect Provider",
        .model_picker => "Select Model",
    };
}

fn resolveCommand(app: *App, filter: []const u8) ?Command {
    var selected: ?Command = null;
    var index: u32 = 0;
    for (commands) |entry| {
        if (!startsWithIgnoreCase(entry.name, filter)) continue;
        if (index == app.command_selection) selected = entry.command;
        index += 1;
    }
    if (selected) |command| return command;
    if (index == 1) {
        for (commands) |entry| if (startsWithIgnoreCase(entry.name, filter)) return entry.command;
    }
    return null;
}

fn commandMatchesCount(app: *App) u32 {
    const input = app.peekInput() catch return 0;
    defer app.gpa.free(input);
    if (input.len == 0) return 0;
    if (input[0] != ':') return 0;
    return commandMatchesCountForFilter(input[1..]);
}

fn commandMatchesCountForFilter(filter: []const u8) u32 {
    var count: u32 = 0;
    for (commands) |entry| {
        if (startsWithIgnoreCase(entry.name, filter)) count += 1;
    }
    return count;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (prefix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn inputChanged(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(userdata.?));
    try app.syncModeWithInput(value);
    ctx.consumeAndRedraw();
}

const PanelWidget = struct {
    app: *App,

    fn widget(self: *PanelWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawPanel };
    }

    fn drawPanel(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *PanelWidget = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        if (self.app.mode == .command) {
            var content: CommandPanelContent = .{ .app = self.app };
            var border: vxfw.Border = .{ .child = content.widget(), .style = StylePalette.tool };
            return border.widget().draw(ctx);
        }
        if (self.app.mode == .picker) {
            var content: ResumePanelContent = .{ .app = self.app };
            var border: vxfw.Border = .{ .child = content.widget(), .style = StylePalette.tool };
            return border.widget().draw(ctx);
        }
        if (self.app.mode == .provider_picker) {
            var content: ProviderPanelContent = .{ .app = self.app };
            var border: vxfw.Border = .{ .child = content.widget(), .style = StylePalette.tool };
            return border.widget().draw(ctx);
        }
        if (self.app.mode == .model_picker) {
            var content: ModelPanelContent = .{ .app = self.app };
            var border: vxfw.Border = .{ .child = content.widget(), .style = StylePalette.tool };
            return border.widget().draw(ctx);
        }

        return vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
    }
};

const CommandPanelContent = struct {
    app: *App,

    fn widget(self: *CommandPanelContent) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawContent };
    }

    fn drawContent(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *CommandPanelContent = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        try drawCommandPanel(self.app, &surface, ctx);
        return surface;
    }
};

fn drawCommandPanel(app: *App, surface: *vxfw.Surface, ctx: vxfw.DrawContext) std.mem.Allocator.Error!void {
    const input = app.peekInput() catch return;
    defer app.gpa.free(input);
    const filter = if (input.len > 0 and input[0] == ':') input[1..] else "";
    var row: u16 = 0;
    var index: u32 = 0;
    for (commands) |entry| {
        if (!startsWithIgnoreCase(entry.name, filter)) continue;
        var buffer: [32]u8 = undefined;
        const selected = index == app.command_selection;
        const prefix = if (selected) "‣ " else "  ";
        const text = std.fmt.bufPrint(&buffer, "{s}{s}", .{ prefix, entry.name }) catch entry.name;
        try writeCommandLine(surface, row, text, ctx, selected);
        row += 1;
        index += 1;
        if (row >= surface.size.height) return;
    }
}

const ReasoningOption = struct { label: []const u8, effort: ai.ReasoningEffort };

fn reasoningOptions() []const ReasoningOption {
    return &.{
        .{ .label = "medium (Default)", .effort = .medium },
        .{ .label = "high", .effort = .high },
        .{ .label = "xhigh", .effort = .xhigh },
        .{ .label = "low", .effort = .low },
    };
}

const ProviderPanelContent = struct {
    app: *App,

    fn widget(self: *ProviderPanelContent) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawContent };
    }

    fn drawContent(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *ProviderPanelContent = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        try writeCommandLine(&surface, 0, "‣ OpenAI Codex", ctx, true);
        try writePanelLine(&surface, 1, "Press Enter to open browser sign-in", ctx, false);
        return surface;
    }
};

const ModelPanelContent = struct {
    app: *App,

    fn widget(self: *ModelPanelContent) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawContent };
    }

    fn drawContent(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *ModelPanelContent = @ptrCast(@alignCast(ptr));
        if (self.app.codex_models.items.len == 0) return self.drawEmpty(ctx);
        const widgets = try self.modelWidgets(ctx);
        self.app.model_list.children = .{ .slice = widgets };
        self.app.model_list.item_count = @intCast(widgets.len);
        self.app.model_list.cursor = self.app.model_selection;
        self.app.model_list.ensureScroll();
        return self.app.model_list.widget().draw(ctx);
    }

    fn drawEmpty(self: *ModelPanelContent, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        try writePanelLineAt(&surface, 0, "No provider models available. Run :connect first.", ctx, false, ConversationLayout.left -| 1);
        return surface;
    }

    fn modelWidgets(self: *ModelPanelContent, ctx: vxfw.DrawContext) ![]vxfw.Widget {
        const widgets = try ctx.arena.alloc(vxfw.Widget, self.app.codex_models.items.len);
        const rows = try ctx.arena.alloc(ModelRowWidget, self.app.codex_models.items.len);
        for (self.app.codex_models.items, 0..) |*model, index| {
            rows[index] = .{
                .app = self.app,
                .model = model,
                .index = @intCast(index),
                .selected = self.app.model_selection == index,
            };
            widgets[index] = rows[index].widget();
        }
        return widgets;
    }
};

const ModelRowWidget = struct {
    app: *App,
    model: *const codex.Model,
    index: u32,
    selected: bool,

    fn widget(self: *ModelRowWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawRow };
    }

    fn drawRow(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *ModelRowWidget = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = 1 }, &.{});
        const model_focused = self.selected and self.app.model_column == .model;
        const prefix = if (self.selected) "‣ " else "  ";
        const text = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, self.model.label });
        try writePanelLineAt(&surface, 0, text, ctx, model_focused, ConversationLayout.left -| 1);
        if (self.selected) try self.drawReasoning(&surface, ctx);
        return surface;
    }

    fn drawReasoning(self: *const ModelRowWidget, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const effort_focused = self.app.model_column == .reasoning;
        const effort = reasoningOptions()[self.app.selectedReasoningIndex()].label;
        const effort_prefix = if (effort_focused) "‣ " else "  ";
        const effort_text = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ effort_prefix, effort });
        try writePanelLineAt(surface, 0, effort_text, ctx, effort_focused, surface.size.width / 2);
    }
};

const ResumePanelContent = struct {
    app: *App,

    fn widget(self: *ResumePanelContent) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawContent };
    }

    fn drawContent(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *ResumePanelContent = @ptrCast(@alignCast(ptr));
        const widgets = try self.resumeWidgets(ctx);
        self.app.resume_list.children = .{ .slice = widgets };
        self.app.resume_list.item_count = @intCast(widgets.len);
        self.app.resume_list.cursor = self.app.resume_selection;
        self.app.resume_list.ensureScroll();
        return self.app.resume_list.widget().draw(ctx);
    }

    fn resumeWidgets(self: *ResumePanelContent, ctx: vxfw.DrawContext) ![]vxfw.Widget {
        const filter = self.app.peekInput() catch "";
        defer if (filter.len > 0) self.app.gpa.free(filter);
        const count = try self.app.visibleResumeCount();
        const widgets = try ctx.arena.alloc(vxfw.Widget, count);
        const rows = try ctx.arena.alloc(ResumeRowWidget, count);
        var index: u32 = 0;
        for (self.app.resume_summaries.items) |*summary| {
            if (!resumeMatches(summary, filter)) continue;
            rows[index] = .{ .app = self.app, .summary = summary, .selected = index == self.app.resume_selection };
            widgets[index] = rows[index].widget();
            index += 1;
        }
        return widgets;
    }
};

const ResumeRowWidget = struct {
    app: *App,
    summary: *const session_mod.SessionSummary,
    selected: bool,

    fn widget(self: *ResumeRowWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawRow };
    }

    fn drawRow(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *ResumeRowWidget = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = 1 }, &.{});
        var buffer: [128]u8 = undefined;
        const modified = modifiedTime(self.app.io, buffer[0..], self.summary.updated_at_ms);
        const left = try self.leftText(ctx, width, modified);
        try writeCommandLine(&surface, 0, left, ctx, self.selected);
        try writePanelRight(&surface, 0, modified, ctx, self.selected);
        return surface;
    }

    fn leftText(self: *const ResumeRowWidget, ctx: vxfw.DrawContext, width: u16, modified: []const u8) std.mem.Allocator.Error![]const u8 {
        const marker = if (self.selected) "‣ " else "  ";
        const available = resumeLeftWidth(ctx, width, modified);
        const marker_width = ctx.stringWidth(marker);
        if (available <= marker_width) return ctx.arena.dupe(u8, marker);

        const name = self.summary.title orelse "Untitled";
        if (!self.app.resume_global) {
            const title = try truncateText(ctx, name, available - marker_width);
            return std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ marker, title });
        }

        const separator = " · ";
        const separator_width = ctx.stringWidth(separator);
        if (available <= marker_width + separator_width + 4) {
            const title = try truncateText(ctx, name, available - marker_width);
            return std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ marker, title });
        }

        const content_width = available - marker_width - separator_width;
        const title_width = @max(@as(usize, 8), content_width / 2);
        const path_width = content_width - @min(title_width, content_width);
        const title = try truncateText(ctx, name, @min(title_width, content_width));
        const path = try truncateText(ctx, self.summary.cwd, path_width);
        return std.fmt.allocPrint(ctx.arena, "{s}{s}{s}{s}", .{ marker, title, separator, path });
    }
};

fn resumeLeftWidth(ctx: vxfw.DrawContext, row_width: u16, modified: []const u8) usize {
    const start_col = ConversationLayout.left -| 1;
    const end_col = row_width -| ConversationLayout.right;
    const date_width = ctx.stringWidth(modified);
    if (end_col <= start_col) return 0;
    if (date_width + 1 >= end_col - start_col) return 0;
    return end_col - start_col - date_width - 1;
}

fn truncateText(ctx: vxfw.DrawContext, text: []const u8, width: usize) std.mem.Allocator.Error![]const u8 {
    if (width == 0) return ctx.arena.dupe(u8, "");
    if (ctx.stringWidth(text) <= width) return ctx.arena.dupe(u8, text);
    if (width <= 3) return ctx.arena.dupe(u8, "...");

    var out: std.ArrayList(u8) = .empty;
    var used: usize = 0;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const grapheme_width = ctx.stringWidth(bytes);
        if (used + grapheme_width + 3 > width) break;
        try out.appendSlice(ctx.arena, bytes);
        used += grapheme_width;
    }
    try out.appendSlice(ctx.arena, "...");
    return out.toOwnedSlice(ctx.arena);
}

fn writeCommandLine(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, selected: bool) std.mem.Allocator.Error!void {
    try writePanelLineAt(surface, row, text, ctx, selected, ConversationLayout.left -| 1);
}

fn writePanelLine(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, selected: bool) std.mem.Allocator.Error!void {
    try writePanelLineAt(surface, row, text, ctx, selected, ConversationLayout.left);
}

fn writePanelRight(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, selected: bool) std.mem.Allocator.Error!void {
    if (row >= surface.size.height) return;
    const stable_text = try ctx.arena.dupe(u8, text);
    const style = if (selected) StylePalette.tool else StylePalette.thinking_body;
    const text_width: u16 = @intCast(@min(ctx.stringWidth(stable_text), std.math.maxInt(u16)));
    const end_col = surface.size.width -| ConversationLayout.right;
    if (text_width >= end_col) return;
    var col = end_col - text_width;
    var iter = ctx.graphemeIterator(stable_text);
    while (iter.next()) |grapheme| {
        if (col >= surface.size.width) return;
        const bytes = grapheme.bytes(stable_text);
        const width: u8 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        if (col + width > surface.size.width) return;
        surface.writeCell(col, row, .{ .char = .{ .grapheme = bytes, .width = width }, .style = style });
        col += width;
    }
}

fn writePanelLineAt(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, selected: bool, start_col: u16) std.mem.Allocator.Error!void {
    if (row >= surface.size.height) return;
    const stable_text = try ctx.arena.dupe(u8, text);
    const style = if (selected) StylePalette.tool else StylePalette.thinking_body;
    var col: u16 = start_col;
    var iter = ctx.graphemeIterator(stable_text);
    while (iter.next()) |grapheme| {
        if (col + 1 >= surface.size.width) return;
        const bytes = grapheme.bytes(stable_text);
        const width: u8 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        surface.writeCell(col, row, .{ .char = .{ .grapheme = bytes, .width = width }, .style = style });
        col += width;
    }
}

fn resumeMatches(summary: *const session_mod.SessionSummary, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (summary.title) |title| {
        if (std.mem.indexOf(u8, title, filter) != null) return true;
    }
    if (std.mem.indexOf(u8, summary.cwd, filter) != null) return true;
    if (std.mem.indexOf(u8, summary.id, filter) != null) return true;
    return false;
}

/// Format a recency label for the resume picker. Buckets:
///   just now  < 60s
///   Nm ago    1..59 minutes
///   Nh ago    1..23 hours
///   Nd ago    1..6 days
///   Nw ago    1..3 weeks (7..27 days)
///   Nmo ago   1..11 months (~28..364 days)
///   Ny ago    1+ years
///
fn modifiedTime(io: std.Io, buffer: []u8, updated_at_ms: i64) []const u8 {
    if (updated_at_ms < 0) return "unknown time";
    if (buffer.len == 0) return "unknown time";
    const now_ms = std.Io.Clock.now(.real, io).toMilliseconds();
    const diff_ms = now_ms - updated_at_ms;
    if (diff_ms < 0) return "in the future";
    const seconds: i64 = @divTrunc(diff_ms, 1000);
    if (seconds < 60) return "just now";
    const minutes: i64 = @divTrunc(seconds, 60);
    if (minutes < 60) {
        return std.fmt.bufPrint(buffer, "{d}m ago", .{minutes}) catch "unknown time";
    }
    const hours: i64 = @divTrunc(minutes, 60);
    if (hours < 24) {
        return std.fmt.bufPrint(buffer, "{d}h ago", .{hours}) catch "unknown time";
    }
    const days: i64 = @divTrunc(hours, 24);
    if (days < 7) {
        return std.fmt.bufPrint(buffer, "{d}d ago", .{days}) catch "unknown time";
    }
    if (days < 28) {
        return std.fmt.bufPrint(buffer, "{d}w ago", .{@divTrunc(days, 7)}) catch "unknown time";
    }
    if (days < 365) {
        return std.fmt.bufPrint(buffer, "{d}mo ago", .{@divTrunc(days, 30)}) catch "unknown time";
    }
    return std.fmt.bufPrint(buffer, "{d}y ago", .{@divTrunc(days, 365)}) catch "unknown time";
}

test "modifiedTime buckets" {
    const io = std.testing.io;
    var buf: [32]u8 = undefined;
    const now = std.Io.Clock.now(.real, io).toMilliseconds();
    const sec_ms: i64 = 1000;
    const min_ms: i64 = 60 * sec_ms;
    const hour_ms: i64 = 60 * min_ms;
    const day_ms: i64 = 24 * hour_ms;
    try std.testing.expectEqualStrings("just now", modifiedTime(io, &buf, now - 30 * sec_ms));
    try std.testing.expectEqualStrings("5m ago", modifiedTime(io, &buf, now - 5 * min_ms));
    try std.testing.expectEqualStrings("3h ago", modifiedTime(io, &buf, now - 3 * hour_ms));
    try std.testing.expectEqualStrings("3d ago", modifiedTime(io, &buf, now - 3 * day_ms));
    try std.testing.expectEqualStrings("2w ago", modifiedTime(io, &buf, now - 14 * day_ms));
    try std.testing.expectEqualStrings("3mo ago", modifiedTime(io, &buf, now - 90 * day_ms));
    try std.testing.expectEqualStrings("2y ago", modifiedTime(io, &buf, now - 730 * day_ms));
}

const InputWidget = struct {
    app: *App,

    fn widget(self: *InputWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawInput,
        };
    }

    fn drawInput(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *InputWidget = @ptrCast(@alignCast(ptr));
        const max_width = ctx.max.width orelse 0;
        const height: u16 = 3;

        var prompt: vxfw.Text = .{
            .text = ">",
            .softwrap = false,
            .width_basis = .parent,
        };
        var prompt_box: vxfw.SizedBox = .{
            .child = prompt.widget(),
            .size = .{ .width = 2, .height = 1 },
        };
        var input_box: vxfw.SizedBox = .{
            .child = self.app.input.widget(),
            .size = .{ .width = max_width -| 2, .height = 1 },
        };
        var row: vxfw.FlexRow = .{
            .children = &.{
                .{ .widget = prompt_box.widget(), .flex = 0 },
                .{ .widget = input_box.widget(), .flex = 1 },
            },
        };
        var row_box: vxfw.SizedBox = .{
            .child = row.widget(),
            .size = .{ .width = max_width -| 2, .height = 1 },
        };
        var border: vxfw.Border = .{
            .child = row_box.widget(),
            .style = StylePalette.thinking_body,
            .labels = &.{.{ .text = inputLabel(self.app), .alignment = .top_left }},
        };
        var box: vxfw.SizedBox = .{
            .child = border.widget(),
            .size = .{ .width = max_width, .height = height },
        };
        return box.widget().draw(ctx);
    }
};

const RowViewport = struct {
    first: u32,
    height: u16,
};

fn visibleRows(
    messages: []const thread_mod.Message,
    selected: ?u32,
    width: u16,
    height: u16,
) RowViewport {
    const total = threadRows(messages, width);
    if (total <= height) return .{ .first = 0, .height = height };

    const selected_index = selected orelse return .{
        .first = total - height,
        .height = height,
    };
    std.debug.assert(selected_index < messages.len);

    const last_index: u32 = @intCast(messages.len - 1);
    if (selected_index == last_index) {
        return .{ .first = total - height, .height = height };
    }

    const selected_start = messageStartRow(messages, selected_index, width);
    const selected_rows = messageRows(messages[selected_index], width);
    const selected_end = selected_start + selected_rows;
    if (selected_rows >= height) {
        return .{ .first = selected_start, .height = height };
    }
    if (selected_end <= height) {
        return .{ .first = 0, .height = height };
    }
    return .{ .first = selected_end - height, .height = height };
}

fn drawToolBody(
    surface: *vxfw.Surface,
    message: thread_mod.Message,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
) void {
    if (message.body.len > 0) {
        switch (message.tool_render) {
            .plain => MessageWidget.drawWrapped(surface, message.body, StylePalette.thinking_body, selected, row, ctx, 0, null),
            .diff => drawWrappedDiff(surface, message.body, selected, row, ctx),
        }
    }
    if (message.stderr_body) |stderr| {
        MessageWidget.drawWrapped(surface, stderr, StylePalette.tool_failed, selected, row, ctx, 0, null);
    }
}

fn drawWrappedDiff(
    surface: *vxfw.Surface,
    text: []const u8,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
) void {
    const content_width = ConversationLayout.contentWidth(surface.size.width);
    const width = @max(@as(usize, content_width), 1);
    if (text.len == 0) {
        MessageWidget.drawLine(surface, "", StylePalette.thinking_body, selected, row, ctx, 0, null);
        return;
    }

    var line_start: usize = 0;
    while (line_start <= text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        const style = diffLineStyle(line);
        if (line.len == 0) {
            MessageWidget.drawLine(surface, "", style, selected, row, ctx, 0, null);
        } else {
            var chunk_start: usize = 0;
            while (chunk_start < line.len) {
                const chunk_end = @min(chunk_start + width, line.len);
                MessageWidget.drawLine(surface, line[chunk_start..chunk_end], style, selected, row, ctx, 0, null);
                chunk_start = chunk_end;
            }
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
}

fn diffLineStyle(line: []const u8) vaxis.Style {
    if (line.len == 0) return StylePalette.thinking_body;
    return switch (line[0]) {
        '+' => StylePalette.tool,
        '-' => StylePalette.tool_failed,
        else => StylePalette.thinking_body,
    };
}

const StylePalette = struct {
    const thinking_blue = .{ 96, 165, 250 };
    const user_yellow = .{ 212, 175, 55 };

    const selected: vaxis.Style = .{ .bg = .{ .rgb = .{ 38, 38, 38 } } };
    const user: vaxis.Style = .{ .fg = .{ .rgb = user_yellow }, .italic = true };
    const tool: vaxis.Style = .{ .fg = .{ .rgb = .{ 34, 197, 94 } } };
    const tool_failed: vaxis.Style = .{ .fg = .{ .rgb = .{ 239, 68, 68 } } };
    const thinking_label: vaxis.Style = .{ .fg = .{ .rgb = thinking_blue } };
    const thinking_body: vaxis.Style = .{ .fg = .{ .rgb = .{ 138, 138, 138 } } };
    const thinking_bar: vaxis.Style = .{ .fg = .{ .rgb = thinking_blue } };
};

fn mergedSelectedStyle(style: vaxis.Style, selected: bool) vaxis.Style {
    var merged = style;
    if (selected) merged.bg = StylePalette.selected.bg;
    return merged;
}

fn gradientStyle(col: u16, width: u16, selected: bool) vaxis.Style {
    std.debug.assert(width > 0);
    const denominator: u32 = @max(@as(u32, width) - 1, 1);
    const numerator: u32 = @min(@as(u32, col), denominator);
    const yellow = .{ 252, 211, 77 };
    const orange = .{ 249, 115, 22 };
    return mergedSelectedStyle(.{ .fg = .{ .rgb = .{
        gradientChannel(yellow[0], orange[0], numerator, denominator),
        gradientChannel(yellow[1], orange[1], numerator, denominator),
        gradientChannel(yellow[2], orange[2], numerator, denominator),
    } } }, selected);
}

fn gradientChannel(start: u8, end: u8, numerator: u32, denominator: u32) u8 {
    std.debug.assert(denominator > 0);
    const start_value: u32 = start;
    const end_value: u32 = end;
    if (end_value >= start_value) {
        return @intCast(start_value + ((end_value - start_value) * numerator) / denominator);
    }
    return @intCast(start_value - ((start_value - end_value) * numerator) / denominator);
}

fn firstVisibleMessage(
    messages: []const thread_mod.Message,
    selected: ?u32,
    width: u16,
    height: u16,
) u32 {
    const first_row = visibleRows(messages, selected, width, height).first;
    var row: u32 = 0;
    var index: u32 = 0;
    while (index < messages.len) : (index += 1) {
        const next = row + messageRows(messages[index], width);
        if (next > first_row) return index;
        row = next;
    }
    return 0;
}

fn threadRows(messages: []const thread_mod.Message, width: u16) u32 {
    var rows: u32 = 0;
    for (messages) |message| {
        rows += messageRows(message, width);
    }
    return rows;
}

fn messageStartRow(messages: []const thread_mod.Message, index: u32, width: u16) u32 {
    std.debug.assert(index < messages.len);
    var rows: u32 = 0;
    var current: u32 = 0;
    while (current < index) : (current += 1) {
        rows += messageRows(messages[current], width);
    }
    return rows;
}

fn messageRows(message: thread_mod.Message, width: u16) u16 {
    return messageContentRows(message, width) + 2;
}

fn messageContentRows(message: thread_mod.Message, width: u16) u16 {
    return switch (message.kind) {
        .user => textRows(message.body, width -| 2),
        .agent => textRows(message.body, width),
        .logo => logoRows(message.body),
        .thinking => if (message.expanded)
            1 + textRows(message.body, width -| 2)
        else
            1,
        .status => 1,
        .tool => if (message.expanded)
            textRows(message.title, width) + toolBodyRows(message, width)
        else
            textRows(message.title, width),
    };
}

fn toolBodyRows(message: thread_mod.Message, width: u16) u16 {
    var rows: u16 = 0;
    if (message.body.len > 0) rows += textRows(message.body, width);
    if (message.stderr_body) |stderr| rows += textRows(stderr, width);
    return rows;
}

fn logoRows(text: []const u8) u16 {
    if (text.len == 0) return 1;
    var rows: u16 = 1;
    for (text) |byte| {
        if (byte == '\n') rows += 1;
    }
    return rows;
}

fn textRows(text: []const u8, width: u16) u16 {
    if (text.len == 0) return 1;
    const row_width = @max(@as(usize, width), 1);
    var rows: u16 = 1;
    var col: usize = 0;
    for (text) |byte| {
        if (byte == '\n') {
            rows += 1;
            col = 0;
            continue;
        }

        if (col >= row_width) {
            rows += 1;
            col = 0;
        }
        col += 1;
    }
    return rows;
}

test "begin submit clears input and appends loading row before agent turn" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    const loading_index = (try app.beginSubmit()).?;

    try std.testing.expectEqual(@as(usize, 0), app.input.buf.firstHalf().len);
    try std.testing.expectEqual(@as(usize, 0), app.input.buf.secondHalf().len);
    try std.testing.expectEqualStrings("hello", app.thread.messages.items[0].body);
    try std.testing.expectEqual(.status, app.thread.messages.items[loading_index].kind);
    try std.testing.expect(isLoadingWord(app.thread.messages.items[loading_index].title));
    try std.testing.expectEqual(@as(u16, 3), messageRows(app.thread.messages.items[loading_index], 80));
    try std.testing.expectEqual(@as(u32, 0), app.thread.selected.?);
}

test "model picker without models stays on model column" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .model_picker;
    app.model_column = .model;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.right }));
    try std.testing.expectEqual(App.ModelColumn.model, app.model_column);
}

test "canceling a picker returns to command menu" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .model_picker;
    try std.testing.expect(try app.cancelMode());
    try std.testing.expectEqual(App.Mode.command, app.mode);
    const input = try app.peekInput();
    defer gpa.free(input);
    try std.testing.expectEqualStrings(":", input);
}

test "typing colon inside picker opens command menu" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .picker;
    try app.syncModeWithInput(":");
    try std.testing.expectEqual(App.Mode.command, app.mode);
}

test "menu navigation wraps and model reasoning tab cycles" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .command;
    app.command_selection = commandMatchesCountForFilter("") - 1;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expectEqual(@as(u32, 0), app.command_selection);

    const models = try codex.loadStaticModels(gpa);
    defer gpa.free(models);
    try app.codex_models.appendSlice(gpa, models);
    try app.model_reasoning.appendNTimes(gpa, 0, app.codex_models.items.len);
    app.mode = .model_picker;
    app.model_selection = @intCast(app.codex_models.items.len - 1);
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expectEqual(@as(u32, 0), app.model_selection);

    app.model_column = .reasoning;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(@as(u32, 1), app.model_reasoning.items[0]);
    try std.testing.expectEqual(@as(u32, 0), app.model_reasoning.items[1]);
}

fn isLoadingWord(text: []const u8) bool {
    for (loading_spinners) |loading_spinner| {
        if (std.mem.eql(u8, text, loading_spinner)) return true;
    }
    return false;
}

test "empty text deltas do not create selectable messages" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .response_delta = "" }));
    try std.testing.expectEqual(@as(usize, 1), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);

    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = "" }));
    try std.testing.expectEqual(@as(usize, 1), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
}

test "agent app events update thread on the ui side" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = "checking" }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = " files" }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\n\nstderr:\n",
    } }));

    try std.testing.expectEqual(@as(usize, 3), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.thinking, app.thread.messages.items[1].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[2].kind);
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);
    try std.testing.expectEqualStrings("checking files", app.thread.messages.items[1].body);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[2].title);
}

test "user can navigate away from a streaming thinking block" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    _ = try app.applyAgentEvent(.{ .thinking_delta = "first chunk" });
    try std.testing.expectEqual(.thinking, app.thread.messages.items[app.thread.selected.?].kind);

    app.thread.moveSelection(.previous);
    try std.testing.expectEqual(.user, app.thread.messages.items[app.thread.selected.?].kind);

    _ = try app.applyAgentEvent(.{ .thinking_delta = " more" });
    try std.testing.expectEqual(.user, app.thread.messages.items[app.thread.selected.?].kind);
}

test "user can navigate away from a streaming agent message" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    _ = try app.applyAgentEvent(.{ .response_delta = "first chunk" });
    try std.testing.expectEqual(.agent, app.thread.messages.items[app.thread.selected.?].kind);

    app.thread.moveSelection(.previous);
    try std.testing.expectEqual(.user, app.thread.messages.items[app.thread.selected.?].kind);

    _ = try app.applyAgentEvent(.{ .response_delta = " more" });
    try std.testing.expectEqual(.user, app.thread.messages.items[app.thread.selected.?].kind);
}

test "empty content delta does not finalize thinking" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    _ = try app.applyAgentEvent(.{ .thinking_delta = "thinking" });
    const thinking_index = app.thinking_index.?;
    try std.testing.expectEqualStrings("Thinking...", app.thread.messages.items[thinking_index].title);

    _ = try app.applyAgentEvent(.{ .response_delta = "" });
    try std.testing.expectEqualStrings("Thinking...", app.thread.messages.items[thinking_index].title);

    _ = try app.applyAgentEvent(.{ .thinking_delta = " more" });
    try std.testing.expectEqualStrings("Thinking...", app.thread.messages.items[thinking_index].title);

    _ = try app.applyAgentEvent(.{ .response_delta = "answer" });
    try std.testing.expectEqualStrings("Thoughts", app.thread.messages.items[thinking_index].title);
}

test "content deltas do not override user scroll state" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    _ = try app.applyAgentEvent(.{ .response_delta = "first" });
    try std.testing.expect(app.thread_auto_scroll);

    app.thread_auto_scroll = false;
    _ = try app.applyAgentEvent(.{ .response_delta = " second" });
    try std.testing.expect(!app.thread_auto_scroll);
}

test "loading does not appear during final answer after tool batch" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("inspect");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    try std.testing.expectEqual(.status, app.thread.messages.items[2].kind);

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "Final answer" }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(usize, 3), app.thread.messages.items.len);
    try std.testing.expectEqual(.agent, app.thread.messages.items[2].kind);
}

test "loading does not reappear between content chunks" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("implement dijkstra");
    _ = (try app.beginSubmit()).?;

    // Once a content delta has arrived we are committed to streaming. The gap
    // between chunks must NOT bring the spinner back — the streaming text is
    // its own progress indicator.
    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "Here's the implementation plan:" }));
    _ = try app.applyAgentEvent(.delta_end);
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.agent, app.thread.messages.items[1].kind);
}

test "structured tool keeps loading status while arguments stream" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("write file");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "write_file",
        .arguments = "{\"path\":\"main.zig\",\"content\":\"const std = @import(\\\"std\\\");",
    } }));
    try std.testing.expectEqual(@as(usize, 3), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.status, app.thread.messages.items[1].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[2].kind);

    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "write_file",
        .display_label = "write_file {\"path\":\"main.zig\",\"content\":\"const std = @import(\\\"std\\\");\"}",
        .display_body = "Successfully wrote 27 bytes to main.zig\n",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
}

test "tool row persists through finish and turn completion" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run ls");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[1].title);

    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[1].title);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[1].title);

    try std.testing.expect(try app.applyAgentEvent(.turn_finished));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[1].title);
}

test "partial tool arguments do not create visible tool rows" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run ls");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.status, app.thread.messages.items[1].kind);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[1].title);
}

test "tool finish creates row if no complete streamed arguments appeared" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run ls");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));

    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[1].title);
}

test "new tool response index creates a new thread row" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run tools");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));

    try std.testing.expectEqual(@as(usize, 3), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[2].kind);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[1].title);
    try std.testing.expectEqualStrings("$ pwd", app.thread.messages.items[2].title);
}

test "late tool finish does not move selection upward" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run tools");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expectEqual(@as(u32, 1), app.thread.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 1,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "done" }));
    try std.testing.expectEqual(@as(u32, 3), app.thread.selected.?);
}

test "loading does not resume after post-tool thinking delta" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("inspect");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));

    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = "checking output" }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));

    try std.testing.expectEqual(@as(usize, 3), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqual(.thinking, app.thread.messages.items[2].kind);
    try std.testing.expectEqualStrings("Thinking...", app.thread.messages.items[2].title);
}

test "agent response after tool batch appears below tool rows" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("inspect");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "I will check." }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "The repo is in /tmp." }));

    try std.testing.expectEqual(@as(usize, 4), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.agent, app.thread.messages.items[1].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[2].kind);
    try std.testing.expectEqual(.agent, app.thread.messages.items[3].kind);
    try std.testing.expectEqualStrings("I will check.", app.thread.messages.items[1].body);
    try std.testing.expectEqualStrings("$ pwd", app.thread.messages.items[2].title);
    try std.testing.expectEqualStrings("The repo is in /tmp.", app.thread.messages.items[3].body);
    try std.testing.expectEqual(@as(u32, 3), app.thread.selected.?);
}

test "content delta after tool preview does not move selection away from tool row" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("inspect");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "I will check." }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(u32, 1), app.thread.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = " Still checking." }));
    _ = try app.applyAgentEvent(.delta_end);
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);
    try std.testing.expectEqualStrings("I will check. Still checking.", app.thread.messages.items[1].body);
    try std.testing.expectEqualStrings("$ pwd", app.thread.messages.items[2].title);
}

test "collapsed thinking and tool rows have stable heights" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    const thinking_index = try thread.append(gpa, .thinking, "Thinking...", "short");
    try std.testing.expectEqual(@as(u16, 3), messageRows(thread.messages.items[thinking_index], 80));

    try thread.appendThinkingDelta(gpa, thinking_index, " ");
    try thread.appendThinkingDelta(gpa, thinking_index, "this is a much longer thinking body that should not change the collapsed row height");
    try std.testing.expectEqual(@as(u16, 3), messageRows(thread.messages.items[thinking_index], 80));

    const tool_index = try thread.startTool(gpa, "pwd");
    try std.testing.expectEqual(@as(u16, 3), messageRows(thread.messages.items[tool_index], 80));
}

test "first visible message tracks bottom viewport row" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    _ = try thread.append(gpa, .user, "you", "one");
    _ = try thread.append(gpa, .agent, "agent", "two");
    _ = try thread.append(gpa, .agent, "agent", "three");

    try std.testing.expectEqual(
        @as(u32, 1),
        firstVisibleMessage(thread.messages.items, thread.selected, 80, 6),
    );
}

test "latest tall message scrolls by rows instead of message boundaries" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    _ = try thread.append(gpa, .agent, "agent", "one");
    _ = try thread.append(gpa, .agent, "agent", "line1\nline2\nline3\nline4\nline5\nline6");

    const viewport = visibleRows(thread.messages.items, thread.selected, 80, 4);
    try std.testing.expectEqual(@as(u32, 7), viewport.first);
    try std.testing.expectEqual(@as(u32, 11), threadRows(thread.messages.items, 80));
}

test "collapsed tool title wraps to visible rows" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    const index = try thread.startTool(gpa, "edit_file {\"input\":\"a very long patch document\"}");
    try std.testing.expect(!thread.messages.items[index].expanded);
    try std.testing.expect(messageRows(thread.messages.items[index], 12) > 3);
}

test "collapsed tool messages render no body text" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    const index = try thread.startTool(gpa, "printf hello");
    try thread.finishTool(gpa, index, "hello", null, false);

    try std.testing.expect(!thread.messages.items[index].expanded);
    try std.testing.expectEqual(@as(u16, 3), messageRows(thread.messages.items[index], 80));
    thread.toggleSelected();
    try std.testing.expect(thread.messages.items[index].expanded);
    try std.testing.expectEqualStrings("hello", thread.messages.items[index].body);
}

test "selected collapsed tools stay visible for tight viewport heights" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    _ = try thread.append(gpa, .agent, "agent", "one two three four five six seven eight nine ten");
    const tool_index = try thread.startTool(gpa, "zig build test");
    _ = try thread.append(gpa, .agent, "agent", "done");

    thread.selected = tool_index;
    var height: u16 = 1;
    while (height <= 8) : (height += 1) {
        const first = firstVisibleMessage(thread.messages.items, thread.selected, 12, height);
        try std.testing.expect(first <= tool_index);
        try std.testing.expect(selectedRowFits(thread.messages.items, thread.selected.?, 12, height));
    }
}

fn selectedRowFits(
    messages: []const thread_mod.Message,
    selected: u32,
    width: u16,
    height: u16,
) bool {
    const viewport = visibleRows(messages, selected, width, height);
    const selected_start = messageStartRow(messages, selected, width);
    const selected_end = selected_start + messageRows(messages[selected], width);
    const viewport_end = viewport.first + viewport.height;
    return selected_start < viewport_end and selected_end > viewport.first;
}
