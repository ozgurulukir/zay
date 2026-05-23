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
const agent_worker = @import("tui/agent_worker.zig");
const tool_policy = @import("tui/tool_policy.zig");
const tui_metrics = @import("tui/metrics.zig");
const tui_style = @import("tui/style.zig");

const StylePalette = tui_style.Palette;
const gradientStyle = tui_style.gradientStyle;
const mergedSelectedStyle = tui_style.mergedSelectedStyle;
const firstVisibleMessage = tui_metrics.firstVisibleMessage;
const messageRows = tui_metrics.messageRows;
const messageStartRow = tui_metrics.messageStartRow;
const threadRows = tui_metrics.threadRows;
const visibleRows = tui_metrics.visibleRows;

const logo_bytes_max = 64 * 1024;
const loading_spinners = [4][]const u8{ "Firing Neurons", "Multiplying Matrices", "brr..brr...", "Warping" };
const loading_frames = [8][]const u8{ "⣼", "⣹", "⢻", "⠿", "⡟", "⣏", "⣧", "⣶" };
const loading_frame_ms = 40;
const command_prefix: u8 = '/';
const picker_secondary_column: u16 = 52;
// TODO: Investigate jumpToItem as an alternative to handrolling logic
pub const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    agent: *agent_mod.Agent,
    runtime: ?*runtime_mod.AgentRuntime = null,
    thread: thread_mod.Thread = .{},
    input: vxfw.TextField,
    worker_context: agent_worker.Context,
    turn_future: ?std.Io.Future(void) = null,
    owns_runtime: bool = false,
    mode: Mode = .normal,
    command_selection: u32 = 0,
    resume_selection: u32 = 0,
    resume_global: bool = false,
    resume_summaries: std.ArrayList(session_mod.SessionSummary) = .empty,
    codex_models: std.ArrayList(codex.Model) = .empty,
    compatible_models: std.ArrayList(codex.Model) = .empty,
    compatible_models_fetched: bool = false,
    model_sources: std.ArrayList(ModelSource) = .empty,
    model_reasoning: std.ArrayList(u32) = .empty,
    model_selection: u32 = 0,
    model_column: ModelColumn = .model,
    model_reasoning_snapshot: std.ArrayList(u32) = .empty,
    model_selection_snapshot: u32 = 0,
    provider_selection: u32 = 0,
    provider_column: ProviderColumn = .provider,
    codex_signed_in: bool = false,
    custom_connection_field: CustomConnectionField = .base_url,
    custom_connection_show_errors: bool = false,
    custom_base_url: std.ArrayList(u8) = .empty,
    custom_api_key: std.ArrayList(u8) = .empty,
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

    const Mode = enum { normal, command, session_picker, provider_picker, custom_connection_form, model_picker };
    const ModelCatalog = enum { connected_provider, openai_codex };
    const ModelColumn = enum { model, reasoning };
    const ModelSource = enum { openai_codex, openai_compatible };
    const ProviderColumn = enum { provider, sign_out };
    const CustomConnectionField = enum { base_url, api_key };

    pub fn init(io: std.Io, gpa: std.mem.Allocator, agent: *agent_mod.Agent) App {
        return .{
            .io = io,
            .gpa = gpa,
            .agent = agent,
            .input = .init(gpa),
            .worker_context = .{
                .io = io,
                .gpa = agent.gpa,
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
        app.codex_signed_in = runtime.owned_codex_responses != null or detectCodexSignIn(gpa, io, runtime.home_dir);
        app.cached_config = config;
        app.cached_config_owned = true;
        app.hydrateCustomProviderFromAuth() catch |err| {
            std.log.warn("custom_provider.auth.load.failed err={s}", .{@errorName(err)});
        };
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
        self.compatibleModelsCacheClear();
        self.compatible_models.deinit(self.gpa);
        self.model_sources.deinit(self.gpa);
        self.model_reasoning.deinit(self.gpa);
        self.model_reasoning_snapshot.deinit(self.gpa);
        self.custom_base_url.deinit(self.gpa);
        self.custom_api_key.deinit(self.gpa);
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

    fn hydrateCustomProviderFromAuth(self: *App) !void {
        const runtime = self.runtime orelse return;
        var custom = (try codex.loadCustomProvider(self.gpa, self.io, runtime.home_dir)) orelse return;
        defer custom.deinit(self.gpa);
        if (self.cached_config_owned) {
            if (self.cached_config.api_key) |old| self.gpa.free(old);
            self.cached_config.api_key = try self.gpa.dupe(u8, custom.api_key);
            if (self.cached_config.provider == null) {
                if (self.cached_config.base_url) |base_url| self.cached_config.provider = compatibleProviderFromBaseUrl(base_url);
            }
        }
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
                return self.gpa.dupe(u8, "No OpenAI Codex session — type /connect to sign in.");
            }
        }
        return self.gpa.dupe(
            u8,
            "No provider connected. Type /connect to pick one, or set OPENAI_MODEL=<provider>/<model>.",
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
        self.turn_future = try self.io.concurrent(agent_worker.runAgentTurn, .{
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
        const policy = tool_policy.forName(tool.name);
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
            if (key.matches(vaxis.Key.left, .{})) {
                self.provider_column = .provider;
                return true;
            }
            if (key.matches(vaxis.Key.right, .{})) {
                if (self.provider_selection == 0) {
                    if (self.isCodexSignedIn()) self.provider_column = .sign_out;
                }
                return true;
            }
            if (key.matches(vaxis.Key.tab, .{})) {
                if (self.provider_selection == 0) {
                    if (self.isCodexSignedIn()) self.provider_column = nextProviderColumn(self.provider_column);
                }
                return true;
            }
            if (key.matches(vaxis.Key.up, .{})) {
                self.provider_selection = previousIndex(self.provider_selection, providerOptionCount());
                self.provider_column = .provider;
                return true;
            }
            if (key.matches(vaxis.Key.down, .{})) {
                self.provider_selection = nextIndex(self.provider_selection, providerOptionCount());
                self.provider_column = .provider;
                return true;
            }
            return false;
        }
        if (self.mode == .custom_connection_form) {
            if (key.matches(vaxis.Key.up, .{}) or key.matches(vaxis.Key.down, .{}) or key.matches(vaxis.Key.tab, .{})) {
                try self.toggleCustomConnectionField();
                return true;
            }
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
        if (self.mode == .session_picker) {
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
        if (self.mode == .custom_connection_form) return;
        if (self.mode == .session_picker or self.mode == .provider_picker or self.mode == .model_picker) {
            if (value.len > 0) {
                if (value[0] == command_prefix) {
                    self.mode = .command;
                    self.command_selection = 0;
                    return;
                }
            }
            if (self.mode == .session_picker) {
                if (self.resume_selection >= try self.visibleResumeCount()) self.resume_selection = 0;
            }
            return;
        }
        if (value.len == 0) {
            self.mode = .normal;
            self.command_selection = 0;
            return;
        }
        if (value[0] == command_prefix) {
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
        if (self.mode == .session_picker or self.mode == .provider_picker or self.mode == .custom_connection_form or self.mode == .model_picker) {
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
            if (self.provider_selection == 0) {
                if (self.provider_column == .sign_out) {
                    if (self.isCodexSignedIn()) {
                        self.signOutCodex() catch |err| try self.reportConnectionError(err);
                    } else {
                        self.connectCodex() catch |err| try self.reportConnectionError(err);
                    }
                } else {
                    self.connectCodex() catch |err| try self.reportConnectionError(err);
                }
            } else {
                self.openCustomConnectionForm() catch |err| try self.reportConnectionError(err);
            }
            return true;
        }
        if (self.mode == .custom_connection_form) {
            self.submitCustomConnectionForm() catch |err| try self.reportConnectionError(err);
            return true;
        }
        if (self.mode == .model_picker) {
            if (self.codex_models.items.len == 0) return true;
            self.applySelectedModel() catch |err| try self.reportConnectionError(err);
            return true;
        }
        if (self.mode == .session_picker) {
            const summary = try self.selectedResumeSummary() orelse return true;
            self.switchToSession(summary.id) catch |err| {
                try self.reportSessionSwitchError(err);
                return true;
            };
            return true;
        }
        if (input.len == 0) return false;
        if (input[0] != command_prefix) return false;
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
        try self.input.insertSliceAtCursor(&.{command_prefix});
        self.command_selection = 0;
    }

    fn openResumePicker(self: *App) !void {
        self.mode = .session_picker;
        self.resume_global = false;
        self.resume_selection = 0;
        self.clearInput();
        try self.reloadResumeSessions();
    }

    fn openProviderPicker(self: *App) !void {
        self.mode = .provider_picker;
        self.provider_selection = 0;
        self.provider_column = .provider;
        self.clearInput();
    }

    fn openCustomConnectionForm(self: *App) !void {
        self.mode = .custom_connection_form;
        self.custom_connection_field = .base_url;
        self.custom_connection_show_errors = false;
        try self.customConnectionLoadCachedValues();
        try self.loadCustomConnectionFieldInput();
    }

    fn openModelPicker(self: *App) !void {
        self.mode = .model_picker;
        self.model_column = .model;
        self.model_selection = 0;
        self.clearInput();
        self.reloadModelCatalog(.connected_provider) catch {};
        // Snapshot for Escape revert. See `cancelMode`.
        self.model_reasoning_snapshot.clearRetainingCapacity();
        try self.model_reasoning_snapshot.appendSlice(self.gpa, self.model_reasoning.items);
        self.model_selection_snapshot = self.model_selection;
    }

    fn connectCodex(self: *App) !void {
        if (self.in_flight) return error.InFlightTurn;
        var credentials = try codex.login(self.gpa, self.io, self.runtime.?.home_dir);
        defer credentials.deinit(self.gpa);
        try self.reloadModelCatalog(.openai_codex);
        const model = self.selectedCodexModel() orelse return error.NoModels;
        const effort = self.selectedReasoningEffort();
        try self.connectCodexClient(credentials, model.id, effort);
        self.codex_signed_in = true;
        try self.persistModelSelection(.openai, model.id, effort);
        self.mode = .normal;
        self.clearInput();
        _ = try self.thread.append(self.gpa, .agent, "agent", "Connected to OpenAI Codex.");
    }

    fn customConnectionLoadCachedValues(self: *App) !void {
        self.custom_base_url.clearRetainingCapacity();
        self.custom_api_key.clearRetainingCapacity();
        if (self.cached_config.base_url) |base_url| try self.custom_base_url.appendSlice(self.gpa, base_url);
        if (self.cached_config.api_key) |api_key| try self.custom_api_key.appendSlice(self.gpa, api_key);
    }

    fn loadCustomConnectionFieldInput(self: *App) !void {
        self.clearInput();
        const value = switch (self.custom_connection_field) {
            .base_url => self.custom_base_url.items,
            .api_key => self.custom_api_key.items,
        };
        try self.input.insertSliceAtCursor(value);
    }

    fn storeCustomConnectionFieldInput(self: *App) !void {
        const input = try self.peekInput();
        defer self.gpa.free(input);
        const target = switch (self.custom_connection_field) {
            .base_url => &self.custom_base_url,
            .api_key => &self.custom_api_key,
        };
        target.clearRetainingCapacity();
        try target.appendSlice(self.gpa, input);
    }

    fn toggleCustomConnectionField(self: *App) !void {
        try self.storeCustomConnectionFieldInput();
        self.custom_connection_field = switch (self.custom_connection_field) {
            .base_url => .api_key,
            .api_key => .base_url,
        };
        try self.loadCustomConnectionFieldInput();
    }

    fn customConnectionFieldFilled(self: *App, field: CustomConnectionField) !bool {
        if (self.custom_connection_field == field) {
            const input = try self.peekInput();
            defer self.gpa.free(input);
            return input.len > 0;
        }
        return switch (field) {
            .base_url => self.custom_base_url.items.len > 0,
            .api_key => self.custom_api_key.items.len > 0,
        };
    }

    fn customConnectionFieldMarker(self: *App, field: CustomConnectionField) ![]const u8 {
        if (try self.customConnectionFieldFilled(field)) return "✓";
        if (self.custom_connection_show_errors) return "✗";
        return " ";
    }

    fn submitCustomConnectionForm(self: *App) !void {
        if (self.in_flight) return error.InFlightTurn;
        try self.storeCustomConnectionFieldInput();
        if (self.custom_connection_field == .base_url) {
            if (self.custom_base_url.items.len == 0) {
                self.custom_connection_show_errors = true;
                return;
            }
            self.custom_connection_field = .api_key;
            try self.loadCustomConnectionFieldInput();
            return;
        }
        if (self.custom_base_url.items.len == 0) {
            self.custom_connection_show_errors = true;
            return;
        }
        if (self.custom_api_key.items.len == 0) {
            self.custom_connection_show_errors = true;
            return;
        }
        try self.applyCustomConnectionCredentials();
        try self.openModelPicker();
    }

    fn applyCustomConnectionCredentials(self: *App) !void {
        const base_url = try self.gpa.dupe(u8, self.custom_base_url.items);
        errdefer self.gpa.free(base_url);
        const api_key = try self.gpa.dupe(u8, self.custom_api_key.items);
        errdefer self.gpa.free(api_key);
        if (self.cached_config_owned) {
            if (self.cached_config.base_url) |old| self.gpa.free(old);
            if (self.cached_config.api_key) |old| self.gpa.free(old);
        } else {
            self.cached_config = .{};
            self.cached_config_owned = true;
        }
        if (self.cached_config.model) |*old| old.deinit(self.gpa);
        self.cached_config.provider = compatibleProviderFromBaseUrl(self.custom_base_url.items);
        self.cached_config.base_url = base_url;
        self.cached_config.api_key = api_key;
        self.cached_config.model = null;
        self.compatibleModelsCacheClear();
        try codex.saveCustomProvider(self.gpa, self.io, self.runtime.?.home_dir, .{
            .api_key = self.custom_api_key.items,
        });
        var updates: config_mod.Config = .{
            .provider = compatibleProviderFromBaseUrl(self.custom_base_url.items),
            .base_url = try self.gpa.dupe(u8, self.custom_base_url.items),
        };
        defer updates.deinit(self.gpa);
        config_mod.mergeAndWriteGlobal(self.gpa, self.io, self.runtime.?.home_dir, updates) catch |err| {
            std.log.warn("config.write.failed err={s}", .{@errorName(err)});
        };
    }

    fn signOutCodex(self: *App) !void {
        if (self.in_flight) return error.InFlightTurn;
        try codex.signOut(self.gpa, self.io, self.runtime.?.home_dir);
        self.runtime.?.disconnectCodexClient();
        self.codex_signed_in = false;
        self.agent.client = self.runtime.?.client;
        self.codexModelsClear();
        self.mode = .normal;
        self.clearInput();
        _ = try self.thread.append(self.gpa, .agent, "agent", "Signed out from OpenAI Codex.");
    }

    fn applySelectedModel(self: *App) !void {
        if (self.in_flight) return error.InFlightTurn;
        if (self.codex_models.items.len == 0) try self.reloadModelCatalog(.connected_provider);
        const model = self.selectedCodexModel() orelse return error.NoModels;
        const effort = self.selectedReasoningEffort();

        const source = self.selectedModelSource() orelse return error.NoModels;
        switch (source) {
            .openai_codex => {
                const loaded = try codex.load(self.gpa, self.io, self.runtime.?.home_dir);
                if (loaded) |codex_creds| {
                    var credentials = codex_creds;
                    defer credentials.deinit(self.gpa);
                    try self.connectCodexClient(credentials, model.id, effort);
                    self.codex_signed_in = true;
                    try self.persistModelSelection(.openai, model.id, effort);
                } else {
                    return error.NotConnected;
                }
            },
            .openai_compatible => {
                if (!self.hasOpenAICompatibleCredentials()) return error.NotConnected;
                const base_url = self.cached_config.base_url.?;
                const api_key = self.cached_config.api_key.?;
                try self.attachOpenAiCompatibleClient(base_url, api_key, model.id);
                const provider = compatibleProviderFromBaseUrl(base_url);
                try self.persistModelSelection(provider, model.id, effort);
            },
        }
        self.mode = .normal;
        self.clearInput();
    }

    fn persistModelSelection(
        self: *App,
        provider: config_mod.Provider,
        model_id: []const u8,
        effort: ai.ReasoningEffort,
    ) !void {
        const new_id = try self.gpa.dupe(u8, model_id);
        errdefer self.gpa.free(new_id);
        if (self.cached_config_owned) {
            if (self.cached_config.model) |*old| old.deinit(self.gpa);
            self.cached_config.provider = provider;
            self.cached_config.model = .{ .id = new_id, .reasoning_effort = effort };
        } else {
            self.gpa.free(new_id);
        }
        var updates: config_mod.Config = .{
            .provider = provider,
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

    fn reloadModelCatalog(self: *App, catalog: ModelCatalog) !void {
        self.codexModelsClear();
        switch (catalog) {
            .connected_provider => {
                if (self.hasOpenAICompatibleCredentials()) {
                    self.loadCompatibleCatalog() catch |err| {
                        if (!self.isCodexSignedIn()) return err;
                        std.log.warn("compatible.models.failed err={s}", .{@errorName(err)});
                    };
                }
                if (self.isCodexSignedIn()) try self.loadCodexStaticCatalog();
            },
            .openai_codex => try self.loadCodexStaticCatalog(),
        }
        try self.finishModelCatalogReload();
    }

    fn finishModelCatalogReload(self: *App) !void {
        self.moveActiveModelFirst();
        self.model_reasoning.clearRetainingCapacity();
        try self.model_reasoning.appendNTimes(self.gpa, 0, self.codex_models.items.len);
        if (self.model_selection >= self.codex_models.items.len) self.model_selection = 0;
        self.syncModelListCursor();
    }

    fn moveActiveModelFirst(self: *App) void {
        const status = modelStatus(self) orelse return;
        for (self.codex_models.items, 0..) |model, index| {
            if (!std.mem.eql(u8, model.id, status.model)) continue;
            if (index == 0) return;
            std.mem.swap(codex.Model, &self.codex_models.items[0], &self.codex_models.items[index]);
            std.mem.swap(ModelSource, &self.model_sources.items[0], &self.model_sources.items[index]);
            return;
        }
    }

    fn loadCodexStaticCatalog(self: *App) !void {
        const models = try codex.loadStaticModels(self.gpa);
        defer self.gpa.free(models);
        for (models) |*model| {
            try self.codex_models.append(self.gpa, model.*);
            try self.model_sources.append(self.gpa, .openai_codex);
            model.* = .{ .id = &.{}, .label = &.{} };
        }
        for (models) |*model| {
            if (model.id.len == 0) continue;
            model.deinit(self.gpa);
        }
    }

    fn loadCompatibleCatalog(self: *App) !void {
        if (!self.compatible_models_fetched) try self.fetchCompatibleCatalog();
        for (self.compatible_models.items) |model| {
            const id = try self.gpa.dupe(u8, model.id);
            errdefer self.gpa.free(id);
            const label = try self.gpa.dupe(u8, model.label);
            errdefer self.gpa.free(label);
            try self.codex_models.append(self.gpa, .{ .id = id, .label = label });
            try self.model_sources.append(self.gpa, .openai_compatible);
        }
    }

    fn fetchCompatibleCatalog(self: *App) !void {
        std.debug.assert(!self.compatible_models_fetched);
        const base_url = self.cached_config.base_url.?;
        const api_key = self.cached_config.api_key.?;
        const fetched = try openai_compatible_mod.listModels(self.gpa, self.io, base_url, api_key);
        defer {
            for (fetched) |*entry| entry.deinit(self.gpa);
            self.gpa.free(fetched);
        }
        errdefer self.compatibleModelsCacheClear();
        for (fetched) |entry| {
            const id = try self.gpa.dupe(u8, entry.id);
            errdefer self.gpa.free(id);
            const label = try self.gpa.dupe(u8, entry.id);
            errdefer self.gpa.free(label);
            try self.compatible_models.append(self.gpa, .{ .id = id, .label = label });
        }
        self.compatible_models_fetched = true;
    }

    fn compatibleModelsCacheClear(self: *App) void {
        for (self.compatible_models.items) |*model| model.deinit(self.gpa);
        self.compatible_models.clearRetainingCapacity();
        self.compatible_models_fetched = false;
    }

    fn isCodexSignedIn(self: *const App) bool {
        return self.codex_signed_in;
    }

    fn hasOpenAICompatibleCredentials(self: *const App) bool {
        const base_url = self.cached_config.base_url orelse return false;
        const api_key = self.cached_config.api_key orelse return false;
        if (base_url.len == 0) return false;
        if (api_key.len == 0) return false;
        return true;
    }

    fn selectedReasoningIndex(self: *const App) u32 {
        if (self.model_selection >= self.model_reasoning.items.len) return 0;
        return self.model_reasoning.items[self.model_selection];
    }

    fn selectedReasoningEffort(self: *const App) ai.ReasoningEffort {
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

    fn selectedModelSource(self: *const App) ?ModelSource {
        if (self.model_selection >= self.model_sources.items.len) return null;
        return self.model_sources.items[self.model_selection];
    }

    fn codexModelsClear(self: *App) void {
        for (self.codex_models.items) |*model| model.deinit(self.gpa);
        self.codex_models.clearRetainingCapacity();
        self.model_sources.clearRetainingCapacity();
        self.model_reasoning.clearRetainingCapacity();
    }

    fn connectCodexClient(
        self: *App,
        credentials: codex.Credentials,
        model: []const u8,
        effort: ai.ReasoningEffort,
    ) !void {
        try self.runtime.?.connectCodexClient(credentials, model, effort);
        self.agent.client = self.runtime.?.client;
    }

    fn attachOpenAiCompatibleClient(
        self: *App,
        base_url: []const u8,
        api_key: []const u8,
        model_id: []const u8,
    ) !void {
        try self.runtime.?.attachOpenAiCompatibleClient(base_url, api_key, model_id);
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
        const message = std.fmt.bufPrint(&buffer, "Could not connect to provider: {s}", .{@errorName(err)}) catch "Could not connect to provider.";
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
        const diagnostics = try current.gpa.alloc(config_mod.Diagnostic, 0);
        errdefer current.gpa.free(diagnostics);
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

fn detectCodexSignIn(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) bool {
    if (home_dir.len == 0) return false;
    var credentials = (codex.load(gpa, io, home_dir) catch null) orelse return false;
    credentials.deinit(gpa);
    return true;
}

fn providerOptionCount() u32 {
    return 2;
}

fn compatibleProviderFromBaseUrl(base_url: []const u8) config_mod.Provider {
    if (std.mem.indexOf(u8, base_url, "localhost:11434") != null) return .ollama;
    if (std.mem.indexOf(u8, base_url, "127.0.0.1:11434") != null) return .ollama;
    if (std.mem.indexOf(u8, base_url, "localhost:8080") != null) return .llama_cpp;
    if (std.mem.indexOf(u8, base_url, "127.0.0.1:8080") != null) return .llama_cpp;
    return .openai_compatible;
}

fn nextProviderColumn(current: App.ProviderColumn) App.ProviderColumn {
    return switch (current) {
        .provider => .sign_out,
        .sign_out => .provider,
    };
}

fn pickerSecondaryColumn(width: u16) u16 {
    return @min(picker_secondary_column, width / 2);
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
        const input_height: u16 = @min(max_height, 5);
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
        .session_picker => "Search for Sessions",
        .provider_picker => "Connect to Provider",
        .custom_connection_form => switch (app.custom_connection_field) {
            .base_url => "Custom Base URL",
            .api_key => "Custom API Key",
        },
        .model_picker => "Select Model",
    };
}

const ModelStatus = struct {
    provider: []const u8,
    model: []const u8,
    thinking: ?[]const u8,
};

fn modelStatus(app: *const App) ?ModelStatus {
    if (app.runtime) |runtime| {
        switch (runtime.client) {
            .codex_responses => |client| return .{
                .provider = "openai",
                .model = client.core_client.config.model,
                .thinking = reasoningLabel(client.core_client.config.reasoning),
            },
            .openai_responses => |client| return .{
                .provider = providerLabel(app) orelse "openai",
                .model = client.core_client.config.model,
                .thinking = reasoningLabel(client.core_client.config.reasoning),
            },
            .openai_compatible => |client| return .{
                .provider = providerLabel(app) orelse "openai_compatible",
                .model = client.config.model,
                .thinking = configThinkingLabel(app),
            },
            .none => return null,
        }
    }

    const model = if (app.cached_config.model) |m| m.id else return null;
    return .{
        .provider = providerLabel(app) orelse return null,
        .model = model,
        .thinking = configThinkingLabel(app),
    };
}

fn providerLabel(app: *const App) ?[]const u8 {
    const provider = app.cached_config.provider orelse return null;
    return provider.label();
}

fn reasoningLabel(reasoning: ?ai.Reasoning) ?[]const u8 {
    const value = reasoning orelse return null;
    const effort = value.effort orelse return "Thinking";
    return effort.label();
}

fn configThinkingLabel(app: *const App) ?[]const u8 {
    if (app.cached_config.model) |model| {
        if (model.reasoning_effort) |effort| return effort.label();
    }
    if (app.cached_config.enable_thinking) |enabled| {
        if (enabled) return "Thinking";
    }
    return null;
}

fn formatModelStatus(gpa: std.mem.Allocator, status: ModelStatus) ![]u8 {
    if (status.thinking) |thinking| {
        return std.fmt.allocPrint(gpa, "{s}/{s} · {s}", .{ status.provider, status.model, thinking });
    }
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ status.provider, status.model });
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
    if (input[0] != command_prefix) return 0;
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
        if (self.app.mode == .session_picker) {
            var content: ResumePanelContent = .{ .app = self.app };
            var border: vxfw.Border = .{ .child = content.widget(), .style = StylePalette.tool };
            return border.widget().draw(ctx);
        }
        if (self.app.mode == .provider_picker) {
            var content: ProviderPanelContent = .{ .app = self.app };
            var border: vxfw.Border = .{ .child = content.widget(), .style = StylePalette.tool };
            return border.widget().draw(ctx);
        }
        if (self.app.mode == .custom_connection_form) {
            var content: CustomConnectionPanelContent = .{ .app = self.app };
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
    const filter = if (input.len > 0 and input[0] == command_prefix) input[1..] else "";
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

fn drawListSurface(
    ctx: vxfw.DrawContext,
    owner: vxfw.Widget,
    list: vxfw.Widget,
) std.mem.Allocator.Error!vxfw.Surface {
    const width = ctx.max.width orelse 0;
    const height = ctx.max.height orelse 0;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{
        .origin = .{ .row = 0, .col = 0 },
        .surface = try list.draw(ctx.withConstraints(
            .{ .width = width, .height = height },
            .{ .width = width, .height = height },
        )),
        .z_index = 0,
    };
    return vxfw.Surface.initWithChildren(ctx.arena, owner, .{ .width = width, .height = height }, children);
}

fn inputHintText(mode: App.Mode) []const u8 {
    return switch (mode) {
        .command => "↑↓ Navigate · [ENTER] Select · [ESC] Back",
        .session_picker => "↑↓ Navigate · [TAB] Toggle · [ENTER] Select · [ESC] Back",
        .provider_picker => "↑↓ Navigate · ←→ Actions · [ENTER] Select · [ESC] Back",
        .custom_connection_form => "↑↓ Navigate · [ENTER] Save · [ESC] Back",
        .model_picker => "↑↓ Navigate · [TAB] Toggle Effort · ←→ Actions · [ENTER] Select · [ESC] Back",
        .normal => "↑↓ Navigate · [TAB] Expand",
    };
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
        const connected = self.app.isCodexSignedIn();
        const codex_focused = self.app.provider_selection == 0 and self.app.provider_column == .provider;
        const codex_prefix = if (codex_focused) "‣ " else "  ";
        const codex_label = if (connected) "OpenAI Codex [CONNECTED]" else "OpenAI Codex";
        const codex_text = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ codex_prefix, codex_label });
        try writeCommandLine(&surface, 0, codex_text, ctx, codex_focused);
        if (connected) {
            const signout_focused = self.app.provider_selection == 0 and self.app.provider_column == .sign_out;
            const signout_prefix = if (signout_focused) "‣ " else "  ";
            const signout_text = try std.fmt.allocPrint(ctx.arena, "{s}Sign out", .{signout_prefix});
            try writePanelLineAt(&surface, 0, signout_text, ctx, signout_focused, pickerSecondaryColumn(surface.size.width));
        }
        const custom_focused = self.app.provider_selection == 1;
        const custom_prefix = if (custom_focused) "‣ " else "  ";
        const custom_text = try std.fmt.allocPrint(ctx.arena, "{s}Custom", .{custom_prefix});
        try writeCommandLine(&surface, 1, custom_text, ctx, custom_focused);
        return surface;
    }
};

const CustomConnectionPanelContent = struct {
    app: *App,

    fn widget(self: *CustomConnectionPanelContent) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawContent };
    }

    fn drawContent(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *CustomConnectionPanelContent = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        const base_focused = self.app.custom_connection_field == .base_url;
        const key_focused = self.app.custom_connection_field == .api_key;
        const base_prefix = if (base_focused) "‣ " else "  ";
        const key_prefix = if (key_focused) "‣ " else "  ";
        const base_marker = try self.app.customConnectionFieldMarker(.base_url);
        const key_marker = try self.app.customConnectionFieldMarker(.api_key);
        const base_text = try std.fmt.allocPrint(ctx.arena, "{s}{s} Base URL", .{ base_prefix, base_marker });
        const key_text = try std.fmt.allocPrint(ctx.arena, "{s}{s} API Key", .{ key_prefix, key_marker });
        try writeCommandLine(&surface, 0, base_text, ctx, base_focused);
        try writeCommandLine(&surface, 1, key_text, ctx, key_focused);
        try writePanelLineAt(&surface, 3, "Enter a value below.", ctx, false, ConversationLayout.left -| 1);
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
        self.app.model_list.cursor = self.app.model_selection + 1;
        self.app.model_list.ensureScroll();
        return drawListSurface(ctx, self.widget(), self.app.model_list.widget());
    }

    fn drawEmpty(self: *ModelPanelContent, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        try writePanelLineAt(&surface, 0, "No provider models available. Run /connect first.", ctx, false, ConversationLayout.left -| 1);
        return surface;
    }

    fn modelWidgets(self: *ModelPanelContent, ctx: vxfw.DrawContext) ![]vxfw.Widget {
        const widgets = try ctx.arena.alloc(vxfw.Widget, self.app.codex_models.items.len + 1);
        const header = try ctx.arena.create(ModelHeaderWidget);
        header.* = .{};
        widgets[0] = header.widget();
        const rows = try ctx.arena.alloc(ModelRowWidget, self.app.codex_models.items.len);
        for (self.app.codex_models.items, 0..) |*model, index| {
            rows[index] = .{
                .app = self.app,
                .model = model,
                .index = @intCast(index),
                .selected = self.app.model_selection == index,
            };
            widgets[index + 1] = rows[index].widget();
        }
        return widgets;
    }
};

const ModelHeaderWidget = struct {
    fn widget(self: *ModelHeaderWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawHeader };
    }

    fn drawHeader(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *ModelHeaderWidget = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = 1 }, &.{});
        try writePanelLineStyledAt(&surface, 0, "NAME", ctx, false, ConversationLayout.left + 1, StylePalette.panel_header);
        try writePanelLineStyledAt(&surface, 0, "REASONING EFFORT", ctx, false, pickerSecondaryColumn(surface.size.width) + 2, StylePalette.panel_header);
        return surface;
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
        const prefix = if (model_focused) "‣ " else "  ";
        const text = if (self.activeModel())
            try std.fmt.allocPrint(ctx.arena, "{s}{s} [ACTIVE]", .{ prefix, self.model.label })
        else
            try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, self.model.label });
        try writePanelLineAt(&surface, 0, text, ctx, model_focused, ConversationLayout.left -| 1);
        if (self.selected) try self.drawReasoning(&surface, ctx);
        return surface;
    }

    fn activeModel(self: *const ModelRowWidget) bool {
        const status = modelStatus(self.app) orelse return false;
        return std.mem.eql(u8, status.model, self.model.id);
    }

    fn drawReasoning(self: *const ModelRowWidget, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const effort_focused = self.app.model_column == .reasoning;
        const effort = reasoningOptions()[self.app.selectedReasoningIndex()].label;
        const effort_prefix = if (effort_focused) "‣ " else "  ";
        const effort_text = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ effort_prefix, effort });
        try writePanelLineAt(surface, 0, effort_text, ctx, effort_focused, pickerSecondaryColumn(surface.size.width));
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
        return drawListSurface(ctx, self.widget(), self.app.resume_list.widget());
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

fn formatCwdRelative(
    arena: std.mem.Allocator,
    cwd: []const u8,
    home_dir: []const u8,
) std.mem.Allocator.Error![]const u8 {
    std.debug.assert(cwd.len > 0);
    if (home_dir.len == 0) return cwd;
    if (cwd.len < home_dir.len) return cwd;

    const prefix = cwd[0..home_dir.len];
    const prefix_matches = switch (@import("builtin").target.os.tag) {
        .windows => std.ascii.eqlIgnoreCase(prefix, home_dir),
        else => std.mem.eql(u8, prefix, home_dir),
    };
    if (!prefix_matches) return cwd;

    const tail = cwd[home_dir.len..];
    if (tail.len == 0) return "~";
    if (tail[0] != '/' and tail[0] != '\\') return cwd;

    std.debug.assert(tail.len >= 1);
    return std.fmt.allocPrint(arena, "~{s}", .{tail});
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
    const style = if (selected) StylePalette.tool else StylePalette.thinking_body;
    try writePanelLineStyledAt(surface, row, text, ctx, selected, start_col, style);
}

fn writePanelLineStyledAt(
    surface: *vxfw.Surface,
    row: u16,
    text: []const u8,
    ctx: vxfw.DrawContext,
    selected: bool,
    start_col: u16,
    style: vaxis.Style,
) std.mem.Allocator.Error!void {
    if (row >= surface.size.height) return;
    _ = selected;
    const stable_text = try ctx.arena.dupe(u8, text);
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

test "model status includes reasoning effort when present" {
    const gpa = std.testing.allocator;
    const text = try formatModelStatus(gpa, .{ .provider = "openai", .model = "gpt-5.5", .thinking = "medium" });
    defer gpa.free(text);
    try std.testing.expectEqualStrings("openai/gpt-5.5 · medium", text);
}

test "model status omits separator when thinking is unavailable" {
    const gpa = std.testing.allocator;
    const text = try formatModelStatus(gpa, .{ .provider = "ollama", .model = "llama", .thinking = null });
    defer gpa.free(text);
    try std.testing.expectEqualStrings("ollama/llama", text);
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

const CommandInputText = struct {
    app: *App,

    fn widget(self: *CommandInputText) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawInputText,
        };
    }

    fn drawInputText(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *CommandInputText = @ptrCast(@alignCast(ptr));
        var surface = try self.app.input.draw(ctx);
        try tintCommandInput(&surface, self.app, ctx);
        return surface;
    }
};

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
        const height: u16 = ctx.max.height orelse 4;

        var prompt: vxfw.Text = .{
            .text = ">",
            .softwrap = false,
            .width_basis = .parent,
        };
        var prompt_box: vxfw.SizedBox = .{
            .child = prompt.widget(),
            .size = .{ .width = 2, .height = 1 },
        };
        var command_input: CommandInputText = .{ .app = self.app };
        var input_box: vxfw.SizedBox = .{
            .child = command_input.widget(),
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
        if (height <= 3) {
            var box: vxfw.SizedBox = .{
                .child = border.widget(),
                .size = .{ .width = max_width, .height = height },
            };
            return box.widget().draw(ctx);
        }

        var border_box: vxfw.SizedBox = .{
            .child = border.widget(),
            .size = .{ .width = max_width, .height = 3 },
        };

        const show_status = height > 3;
        const show_hint = height > 4;
        const children = try ctx.arena.alloc(vxfw.SubSurface, if (show_hint) 4 else if (show_status) 3 else 1);
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try border_box.widget().draw(ctx.withConstraints(
                .{ .width = max_width, .height = 3 },
                .{ .width = max_width, .height = 3 },
            )),
            .z_index = 0,
        };
        if (!show_status) {
            return .{
                .size = .{ .width = max_width, .height = height },
                .widget = self.widget(),
                .buffer = &.{},
                .children = children,
            };
        }

        const cwd_raw = if (self.app.runtime) |runtime| runtime.cwd else self.app.agent.cwd;
        const home_dir = if (self.app.runtime) |runtime| runtime.home_dir else "";
        const cwd = try formatCwdRelative(ctx.arena, cwd_raw, home_dir);
        var cwd_text: vxfw.Text = .{
            .text = cwd,
            .style = StylePalette.cwd,
            .softwrap = false,
            .overflow = .ellipsis,
            .width_basis = .parent,
        };
        var hint_text: vxfw.Text = .{
            .text = inputHintText(self.app.mode),
            .style = StylePalette.thinking_body,
            .text_align = .center,
            .softwrap = false,
            .overflow = .ellipsis,
            .width_basis = .parent,
        };
        const status_text = if (modelStatus(self.app)) |status|
            formatModelStatus(ctx.arena, status) catch ""
        else
            "";
        var model_text: vxfw.Text = .{
            .text = status_text,
            .style = StylePalette.model_status,
            .text_align = .right,
            .softwrap = false,
            .overflow = .ellipsis,
            .width_basis = .parent,
        };

        const status_padding_x: u16 = @min(@as(u16, 1), max_width);
        const status_inner_width = max_width -| (status_padding_x * 2);
        const status_gap: u16 = if (cwd.len > 0 and status_text.len > 0) 1 else 0;
        const status_width = @min(ctx.stringWidth(status_text), @as(usize, status_inner_width));
        const model_width: u16 = @intCast(status_width);
        const cwd_width: u16 = status_inner_width -| model_width -| status_gap;
        const status_row = @as(u16, 3);
        children[1] = .{
            .origin = .{ .row = status_row, .col = status_padding_x },
            .surface = try cwd_text.widget().draw(ctx.withConstraints(
                .{ .width = cwd_width, .height = 1 },
                .{ .width = cwd_width, .height = 1 },
            )),
            .z_index = 0,
        };
        children[2] = .{
            .origin = .{ .row = status_row, .col = status_padding_x + status_inner_width -| model_width },
            .surface = try model_text.widget().draw(ctx.withConstraints(
                .{ .width = model_width, .height = 1 },
                .{ .width = model_width, .height = 1 },
            )),
            .z_index = 0,
        };
        if (show_hint) {
            children[3] = .{
                .origin = .{ .row = status_row + 1, .col = status_padding_x },
                .surface = try hint_text.widget().draw(ctx.withConstraints(
                    .{ .width = status_inner_width, .height = 1 },
                    .{ .width = status_inner_width, .height = 1 },
                )),
                .z_index = 0,
            };
        }

        return .{
            .size = .{ .width = max_width, .height = height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

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

fn tintCommandInput(surface: *vxfw.Surface, app: *App, ctx: vxfw.DrawContext) !void {
    const input = try app.peekInput();
    defer app.gpa.free(input);
    const command_end = commandInputSegmentEnd(input);
    if (command_end == 0) return;

    var byte_index: usize = 0;
    var grapheme_index: u16 = 0;
    var col: u16 = 0;
    var iter = ctx.graphemeIterator(input);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(input);
        defer byte_index += bytes.len;
        defer grapheme_index += 1;
        if (grapheme_index < app.input.draw_offset) continue;
        const width: u8 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        if (col >= surface.size.width) return;
        if (col + width > surface.size.width) return;
        if (byte_index >= command_end) return;
        const cell = surface.readCell(col, 0);
        surface.writeCell(col, 0, .{ .char = cell.char, .style = StylePalette.tool });
        col += width;
    }
}

fn commandInputSegmentEnd(input: []const u8) usize {
    if (input.len == 0) return 0;
    if (input[0] != command_prefix) return 0;
    for (input, 0..) |byte, index| {
        if (byte == ' ') return index;
    }
    return input.len;
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

test "opening model picker starts at top" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.model_selection = 4;
    try app.openModelPicker();

    try std.testing.expectEqual(@as(u32, 0), app.model_selection);
}

test "model picker hides model arrow when reasoning column is focused" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .model_picker;
    app.model_column = .reasoning;
    app.model_selection = 0;
    const models = try codex.loadStaticModels(gpa);
    defer gpa.free(models);
    try app.codex_models.appendSlice(gpa, models);
    try app.model_reasoning.appendNTimes(gpa, 0, app.codex_models.items.len);

    var row: ModelRowWidget = .{
        .app = &app,
        .model = &app.codex_models.items[0],
        .index = 0,
        .selected = true,
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try row.widget().draw(ctx);

    try std.testing.expectEqualStrings(" ", surface.readCell(ConversationLayout.left -| 1, 0).char.grapheme);
    try std.testing.expectEqualStrings("‣", surface.readCell(pickerSecondaryColumn(surface.size.width), 0).char.grapheme);
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

test "provider picker opens custom connection form" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.openProviderPicker();
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expectEqual(@as(u32, 1), app.provider_selection);
    try std.testing.expect(try app.submitMode());

    try std.testing.expectEqual(App.Mode.custom_connection_form, app.mode);
    try std.testing.expectEqual(App.CustomConnectionField.base_url, app.custom_connection_field);
}

test "custom connection form marks empty base url invalid" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .custom_connection_form;
    app.custom_connection_field = .base_url;
    try app.submitCustomConnectionForm();

    try std.testing.expectEqual(App.Mode.custom_connection_form, app.mode);
    try std.testing.expectEqual(App.CustomConnectionField.base_url, app.custom_connection_field);
    try std.testing.expect(app.custom_connection_show_errors);
    try std.testing.expectEqualStrings("✗", try app.customConnectionFieldMarker(.base_url));
}

test "custom connection form advances from base url to api key" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .custom_connection_form;
    app.custom_connection_field = .base_url;
    try app.input.insertSliceAtCursor("http://localhost:11434/v1");
    try app.submitCustomConnectionForm();

    try std.testing.expectEqual(App.Mode.custom_connection_form, app.mode);
    try std.testing.expectEqual(App.CustomConnectionField.api_key, app.custom_connection_field);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", app.custom_base_url.items);
    try std.testing.expectEqualStrings("✓", try app.customConnectionFieldMarker(.base_url));
}

test "provider picker selects sign out horizontally" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    var codex_client: ai.codex_responses.Client = undefined;
    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.client = .{ .codex_responses = &codex_client };
    app.runtime = &runtime;
    app.codex_signed_in = true;

    app.mode = .provider_picker;
    app.provider_column = .provider;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.right }));
    try std.testing.expectEqual(App.ProviderColumn.sign_out, app.provider_column);
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(App.ProviderColumn.provider, app.provider_column);
}

test "codex sign-in survives selecting custom provider" {
    const gpa = std.testing.allocator;
    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.gpa = gpa;
    runtime.io = std.testing.io;
    runtime.cwd = ".";
    runtime.home_dir = ".";
    runtime.client = .none;
    runtime.system_prompt = "test";
    runtime.session_writer = undefined;
    runtime.agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer runtime.agent.deinit();
    runtime.diagnostics = &.{};
    runtime.owned_codex_responses = null;
    runtime.owned_openai_compatible = null;
    runtime.owned_openai_responses = null;
    var app = App.init(std.testing.io, gpa, &runtime.agent);
    app.runtime = &runtime;
    defer app.deinit();
    defer if (runtime.owned_openai_compatible) |client| {
        client.deinit();
        gpa.destroy(client);
    };

    app.codex_signed_in = true;
    try app.codex_models.append(gpa, .{ .id = try gpa.dupe(u8, "llama3"), .label = try gpa.dupe(u8, "llama3") });
    try app.model_sources.append(gpa, .openai_compatible);
    try app.model_reasoning.append(gpa, 0);
    app.model_selection = 0;
    app.cached_config_owned = true;
    app.cached_config.base_url = try gpa.dupe(u8, "http://localhost:11434/v1");
    app.cached_config.api_key = try gpa.dupe(u8, "ollama");

    try app.applySelectedModel();

    try std.testing.expect(app.isCodexSignedIn());
    try std.testing.expectEqual(config_mod.Provider.ollama, app.cached_config.provider.?);
}

test "active model moves to top of model catalog" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    const active_model_id = try gpa.dupe(u8, "gpt-5.4-mini");
    defer gpa.free(active_model_id);
    app.cached_config.provider = .openai;
    app.cached_config.model = .{ .id = active_model_id };

    try app.reloadModelCatalog(.openai_codex);

    try std.testing.expectEqualStrings("gpt-5.4-mini", app.codex_models.items[0].id);
}

test "explicit codex catalog loads before runtime is connected" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.reloadModelCatalog(.openai_codex);

    try std.testing.expect(app.codex_models.items.len > 0);
    try std.testing.expectEqual(app.codex_models.items.len, app.model_reasoning.items.len);
    try std.testing.expect(app.selectedCodexModel() != null);
}

test "compatible provider is inferred from base url" {
    try std.testing.expectEqual(config_mod.Provider.ollama, compatibleProviderFromBaseUrl("http://localhost:11434/v1"));
    try std.testing.expectEqual(config_mod.Provider.ollama, compatibleProviderFromBaseUrl("http://127.0.0.1:11434/v1"));
    try std.testing.expectEqual(config_mod.Provider.llama_cpp, compatibleProviderFromBaseUrl("http://localhost:8080/v1"));
    try std.testing.expectEqual(config_mod.Provider.openai_compatible, compatibleProviderFromBaseUrl("https://example.com/v1"));
}

test "picker secondary column keeps related options close" {
    try std.testing.expectEqual(@as(u16, 50), pickerSecondaryColumn(100));
    try std.testing.expectEqual(@as(u16, 20), pickerSecondaryColumn(40));
}

test "command input segment ends at first space" {
    try std.testing.expectEqual(@as(usize, 0), commandInputSegmentEnd(""));
    try std.testing.expectEqual(@as(usize, 0), commandInputSegmentEnd("hello"));
    try std.testing.expectEqual(@as(usize, 1), commandInputSegmentEnd("/"));
    try std.testing.expectEqual(@as(usize, 8), commandInputSegmentEnd("/connect"));
    try std.testing.expectEqual(@as(usize, 8), commandInputSegmentEnd("/connect now"));
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
    try std.testing.expectEqualStrings("/", input);
}

test "typing slash inside picker opens command menu" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .session_picker;
    try app.syncModeWithInput("/");
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
