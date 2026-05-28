const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
const bash_mod = @import("bash.zig");
const codex = @import("codex.zig");
const config_mod = @import("config.zig");
const openai_compatible_mod = @import("ai/openai_compatible.zig");
const runtime_mod = @import("runtime.zig");
const session_mod = @import("session.zig");
const symbols = @import("symbols.zig");
const thread_mod = @import("thread.zig");
const agent_worker = @import("tui/agent_worker.zig");
const tui_thread_projection = @import("tui/thread_projection.zig");
const tui_metrics = @import("tui/metrics.zig");
const tui_message = @import("tui/widgets/message.zig");
const command_panel = @import("tui/widgets/command_panel.zig");
const model_loader = @import("tui/model_loader.zig");
const model_picker = @import("tui/widgets/model_picker.zig");
const panel_widget = @import("tui/widgets/panel.zig");
const provider_picker = @import("tui/widgets/provider_picker.zig");
const resume_picker = @import("tui/widgets/resume_picker.zig");
const tui_provider = @import("tui/provider_controller.zig");
const tui_status = @import("tui/status.zig");
const tui_app = @import("tui/app.zig");
const tui_style = @import("tui/style.zig");
const logger = @import("logger");

const ConversationLayout = tui_message.ConversationLayout;
const MessageWidget = tui_message.MessageWidget;
const StylePalette = tui_style.Palette;
const mergedSelectedStyle = tui_style.mergedSelectedStyle;
const firstVisibleMessage = tui_metrics.firstVisibleMessage;
const messageRows = tui_metrics.messageRows;
const messageStartRow = tui_metrics.messageStartRow;
const threadRows = tui_metrics.threadRows;
const visibleRows = tui_metrics.visibleRows;

const loading_spinners = tui_thread_projection.loading_spinners;
const loading_frame_ms = tui_message.loading_frame_ms;
const command_prefix: u8 = '/';
const picker_secondary_column: u16 = 52;
const long_message_scroll_step_rows: u16 = 3;
const ThreadNavigation = enum { previous, next };
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
    model_column: model_picker.Column = .model,
    model_scope: ModelScope = .global,
    model_reasoning_snapshot: std.ArrayList(u32) = .empty,
    model_selection_snapshot: u32 = 0,
    provider_picker: provider_picker.State = .{},
    codex_signed_in: bool = false,
    cached_config: config_mod.Config = .{},
    cached_config_owned: bool = false,
    retired_threads: std.ArrayList(thread_mod.Thread) = .empty,
    in_flight: bool = false,
    thread_projection: tui_thread_projection.ThreadProjection = .{},
    loading_frame: u8 = 0,
    loading_tick_active: bool = false,
    thread_auto_scroll: bool = true,
    git_branch: []const u8 = "",
    thread_view_width: u16 = 80,
    thread_view_height: u16 = 1,
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
    model_load_future: ?std.Io.Future(model_loader.Outcome) = null,
    model_load_done: std.atomic.Value(bool) = .init(false),
    model_load_error: ?[]u8 = null,
    /// True once a successful catalog fetch has populated `codex_models`.
    /// Subsequent picker opens skip the network round-trip and just re-sort
    /// for the current active model. Reset on sign-in/sign-out.
    models_cached: bool = false,

    const Mode = enum { normal, command, session_picker, provider_picker, model_picker };
    const ModelCatalog = enum { connected_provider, openai_codex };
    const ModelSource = model_loader.ModelSource;
    const ModelScope = enum { global, project, session };

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
        app.codex_signed_in = runtime.hasCodexClient() or tui_provider.detectCodexSignIn(gpa, io, runtime.home_dir);
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
        self.cancelModelLoad();
        if (self.model_load_error) |message| {
            self.gpa.free(message);
            self.model_load_error = null;
        }
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
        self.thread_projection.deinit(self.gpa);
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
        return self.thread_projection.loading_index;
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
        self.thread_projection.resetTurn(self.io);
        self.loading_frame = 0;
        // Leave `thread_auto_scroll` alone — if the user has scrolled away
        // from the tail to read older context, submitting another message
        // should not yank them back. They can scroll down (or arrow-down)
        // to opt back into auto-follow.
    }

    pub fn startTurn(self: *App) !void {
        self.turn_future = try self.io.concurrent(agent_worker.runAgentTurn, .{
            self.agent,
            &self.worker_context,
        });
    }

    fn appendLoading(self: *App) !void {
        try self.thread_projection.appendLoading(self.gpa, &self.thread);
    }

    fn advanceLoadingFrame(self: *App) void {
        std.debug.assert(tui_message.loading_frames.len > 0);
        self.loading_frame +%= 1;
        if (self.loading_frame >= tui_message.loading_frames.len) self.loading_frame = 0;
    }

    pub fn applyAgentEvent(self: *App, event: agent_mod.Agent.Event) !bool {
        const visible_change = try self.thread_projection.apply(self.gpa, &self.thread, event);
        if (event == .turn_finished) {
            self.in_flight = false;
            self.awaitTurn();
        }
        return visible_change;
    }

    pub fn handleCommandKey(self: *App, key: vaxis.Key) !bool {
        return switch (self.mode) {
            .provider_picker => self.handleProviderPickerKey(key),
            .model_picker => self.handleModelPickerKey(key),
            .session_picker => self.handleSessionPickerKey(key),
            .command => self.handleCommandMenuKey(key),
            .normal => self.handleThreadKey(key),
        };
    }

    fn handleProviderPickerKey(self: *App, key: vaxis.Key) !bool {
        return self.provider_picker.handleKey(key, self.isCodexSignedIn());
    }

    fn handleModelPickerKey(self: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.left, .{})) {
            self.model_column = self.model_column.previous();
            return true;
        }
        if (key.matches(vaxis.Key.right, .{})) {
            if (self.codex_models.items.len > 0) self.model_column = self.model_column.next();
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            switch (self.model_column) {
                .model => self.model_column = self.model_column.next(),
                .reasoning => try self.cycleSelectedReasoning(),
                .scope => self.cycleModelScope(),
            }
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            self.model_selection = previousIndex(self.model_selection, @intCast(self.codex_models.items.len));
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            self.model_selection = nextIndex(self.model_selection, @intCast(self.codex_models.items.len));
            return true;
        }
        return false;
    }

    fn handleSessionPickerKey(self: *App, key: vaxis.Key) !bool {
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

    fn handleCommandMenuKey(self: *App, key: vaxis.Key) !bool {
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

    fn handleThreadKey(self: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.down, .{ .shift = true })) {
            self.jumpThreadToBottom();
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            _ = self.navigateThread(.previous);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            const scrolled = self.navigateThread(.next);
            self.thread_auto_scroll = !scrolled and self.selectionIsLastMessage() and !self.selectedMessageIsLong();
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            self.thread.toggleSelected();
            return true;
        }
        return false;
    }

    fn syncModeWithInput(self: *App, value: []const u8) !void {
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
        if (self.mode == .model_picker) {
            self.cancelModelLoad();
            try self.revertModelPickerSnapshot();
        }
        if (self.mode == .session_picker or self.mode == .provider_picker or self.mode == .model_picker) {
            try self.openCommandMenu();
            self.resumeClear();
            return true;
        }
        self.mode = .normal;
        self.clearInput();
        self.resumeClear();
        return true;
    }

    fn revertModelPickerSnapshot(self: *App) !void {
        self.model_reasoning.clearRetainingCapacity();
        try self.model_reasoning.appendSlice(self.gpa, self.model_reasoning_snapshot.items);
        self.model_selection = self.model_selection_snapshot;
    }

    fn submitMode(self: *App) !bool {
        const input = try self.peekInput();
        defer self.gpa.free(input);
        if (self.mode == .provider_picker) {
            switch (self.provider_picker.selectedAction()) {
                .connect_codex => self.connectCodex() catch |err| try self.reportConnectionError(err),
                .sign_out_codex => {
                    if (self.isCodexSignedIn()) {
                        self.signOutCodex() catch |err| try self.reportConnectionError(err);
                    } else {
                        self.connectCodex() catch |err| try self.reportConnectionError(err);
                    }
                },
            }
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
                .model => self.openModelPicker() catch |err| try self.reportConnectionError(err),
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
        self.provider_picker.reset();
        self.clearInput();
    }

    fn openModelPicker(self: *App) !void {
        self.mode = .model_picker;
        self.model_column = .model;
        self.model_selection = 0;
        self.model_scope = self.defaultModelScope();
        self.clearInput();

        if (self.models_cached and self.codex_models.items.len > 0) {
            try self.finishModelCatalogReload();
            try self.snapshotModelPickerState();
            return;
        }

        // Cold path — clear stale state, kick off the async load.
        self.codexModelsClear();
        self.model_reasoning.clearRetainingCapacity();
        self.model_reasoning_snapshot.clearRetainingCapacity();
        self.model_selection_snapshot = 0;
        try self.startModelLoad(.connected_provider);
    }

    fn snapshotModelPickerState(self: *App) !void {
        self.model_reasoning_snapshot.clearRetainingCapacity();
        try self.model_reasoning_snapshot.appendSlice(self.gpa, self.model_reasoning.items);
        self.model_selection_snapshot = self.model_selection;
    }

    fn startModelLoad(self: *App, catalog: ModelCatalog) !void {
        self.cancelModelLoad();
        if (self.model_load_error) |message| {
            self.gpa.free(message);
            self.model_load_error = null;
        }

        const job = try self.gpa.create(model_loader.Job);
        errdefer self.gpa.destroy(job);

        var configured: ?model_loader.Configured = null;
        errdefer if (configured) |c| {
            self.gpa.free(c.base_url);
            self.gpa.free(c.api_key);
        };
        if (catalog == .connected_provider and self.shouldLoadConfiguredCompatibleCatalog()) {
            const base_url = try self.gpa.dupe(u8, self.cached_config.base_url.?);
            errdefer self.gpa.free(base_url);
            const api_key = try self.gpa.dupe(u8, self.cached_config.api_key.?);
            const provider = self.cached_config.provider orelse tui_provider.compatibleProviderFromBaseUrl(base_url);
            configured = .{ .provider = provider, .base_url = base_url, .api_key = api_key };
        }

        job.* = .{
            .gpa = self.gpa,
            .io = self.io,
            .catalog = switch (catalog) {
                .connected_provider => .connected_provider,
                .openai_codex => .openai_codex,
            },
            .configured = configured,
            .codex_signed_in = self.isCodexSignedIn(),
            .done = &self.model_load_done,
        };

        self.model_load_done.store(false, .release);
        self.model_load_future = try self.io.concurrent(model_loader.run, .{job});
    }

    fn cancelModelLoad(self: *App) void {
        if (self.model_load_future) |*future| {
            var outcome = future.cancel(self.io);
            outcome.deinit(self.gpa);
            self.model_load_future = null;
        }
        self.model_load_done.store(false, .release);
    }

    /// Called from the tick handler. Polls the non-blocking `done` flag, and
    /// only `await`s once the worker has signalled completion. Returns true
    /// if a redraw is needed.
    fn drainModelLoad(self: *App) !bool {
        if (self.model_load_future == null) return false;
        if (!self.model_load_done.load(.acquire)) return false;

        var outcome = self.model_load_future.?.await(self.io);
        self.model_load_future = null;
        self.model_load_done.store(false, .release);
        defer outcome.deinit(self.gpa);

        switch (outcome) {
            .ready => |*result| try self.installModelLoadResult(result),
            .failed => |message| {
                if (self.model_load_error) |old| self.gpa.free(old);
                self.model_load_error = try self.gpa.dupe(u8, message);
            },
        }
        return true;
    }

    fn installModelLoadResult(self: *App, result: *model_loader.Result) !void {
        self.codexModelsClear();
        for (result.models.items) |*model| {
            try self.codex_models.append(self.gpa, model.*);
        }
        result.models.clearRetainingCapacity();
        for (result.sources.items) |source| {
            try self.model_sources.append(self.gpa, source);
        }
        result.sources.clearRetainingCapacity();
        try self.finishModelCatalogReload();
        try self.snapshotModelPickerState();
        self.models_cached = true;
    }

    fn defaultModelScope(self: *App) ModelScope {
        const runtime = self.runtime orelse return .global;
        if (config_mod.projectConfigExists(self.gpa, self.io, runtime.cwd)) return .project;
        return .global;
    }

    fn connectCodex(self: *App) !void {
        if (self.in_flight) return error.InFlightTurn;
        var credentials = try codex.login(self.gpa, self.io, self.runtime.?.home_dir);
        defer credentials.deinit(self.gpa);
        self.models_cached = false;
        try self.reloadModelCatalog(.openai_codex);
        const model = self.selectedCodexModel() orelse return error.NoModels;
        const effort = self.selectedReasoningEffort();
        try self.connectCodexClient(credentials, model.id, effort);
        self.codex_signed_in = true;
        try self.persistModelSelection(.openai, model.id, effort, .global);
        self.mode = .normal;
        self.clearInput();
        _ = try self.thread.append(self.gpa, .agent, "agent", "Connected to OpenAI Codex.");
    }

    fn signOutCodex(self: *App) !void {
        if (self.in_flight) return error.InFlightTurn;
        try codex.signOut(self.gpa, self.io, self.runtime.?.home_dir);
        self.runtime.?.disconnectCodexClient();
        self.codex_signed_in = false;
        self.agent.client = self.runtime.?.client;
        self.codexModelsClear();
        self.models_cached = false;
        self.mode = .normal;
        self.clearInput();
        _ = try self.thread.append(self.gpa, .agent, "agent", "Signed out from OpenAI Codex.");
    }

    fn applySelectedModel(self: *App) !void {
        if (self.in_flight) return error.InFlightTurn;
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
                    try self.persistModelSelection(.openai, model.id, effort, self.model_scope);
                } else {
                    return error.NotConnected;
                }
            },
            .openai_compatible => |provider| {
                const base_url = self.compatibleBaseUrl(provider) orelse return error.NotConnected;
                const api_key = if (self.cached_config.api_key) |key| key else providerLocalApiKey(provider);
                try self.attachOpenAiCompatibleClient(base_url, api_key, model.id, effort);
                try self.persistModelSelection(provider, model.id, effort, self.model_scope);
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
        scope: ModelScope,
    ) !void {
        try self.updateCachedModelSelection(provider, model_id, effort);
        if (scope == .session) return;

        var updates = try self.modelSelectionUpdates(provider, model_id, effort);
        defer updates.deinit(self.gpa);
        switch (scope) {
            .global => config_mod.mergeAndWriteGlobal(self.gpa, self.io, self.runtime.?.home_dir, updates) catch |err| {
                std.log.warn("config.write.failed err={s}", .{@errorName(err)});
            },
            .project => config_mod.mergeAndWriteProject(self.gpa, self.io, self.runtime.?.cwd, updates) catch |err| {
                std.log.warn("project.config.write.failed err={s}", .{@errorName(err)});
            },
            .session => unreachable,
        }
    }

    fn updateCachedModelSelection(
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
    }

    fn modelSelectionUpdates(
        self: *App,
        provider: config_mod.Provider,
        model_id: []const u8,
        effort: ai.ReasoningEffort,
    ) !config_mod.Config {
        const model_id_copy = try self.gpa.dupe(u8, model_id);
        errdefer self.gpa.free(model_id_copy);
        var provider_model_id_moved = false;
        const provider_model_id = try self.gpa.dupe(u8, model_id);
        errdefer if (!provider_model_id_moved) self.gpa.free(provider_model_id);
        var models_moved = false;
        var models = try self.gpa.alloc(config_mod.ProviderModel, 1);
        errdefer if (!models_moved) self.gpa.free(models);
        models[0] = .{ .id = provider_model_id, .reasoning_effort = effort };
        provider_model_id_moved = true;
        var providers = try self.gpa.alloc(config_mod.ProviderConfig, 1);
        errdefer {
            for (providers) |*entry| entry.deinit(self.gpa);
            self.gpa.free(providers);
        }
        providers[0] = .{ .provider = provider, .models = models };
        models_moved = true;
        if (provider != .openai) {
            if (self.compatibleBaseUrl(provider)) |base_url| providers[0].base_url = try self.gpa.dupe(u8, base_url);
        }
        return .{
            .provider = provider,
            .base_url = if (providers[0].base_url) |base_url| try self.gpa.dupe(u8, base_url) else null,
            .model = .{ .id = model_id_copy, .reasoning_effort = effort },
            .providers = providers,
        };
    }

    fn reloadModelCatalog(self: *App, catalog: ModelCatalog) !void {
        self.codexModelsClear();
        switch (catalog) {
            .connected_provider => {
                if (self.shouldLoadConfiguredCompatibleCatalog()) {
                    self.loadCompatibleCatalog() catch |err| {
                        if (!self.isCodexSignedIn()) return err;
                        std.log.warn("compatible.models.failed err={s}", .{@errorName(err)});
                    };
                }
                try self.loadLocalCompatibleCatalogs();
                if (self.isCodexSignedIn()) try self.loadCodexStaticCatalog();
            },
            .openai_codex => try self.loadCodexStaticCatalog(),
        }
        try self.finishModelCatalogReload();
    }

    fn finishModelCatalogReload(self: *App) !void {
        self.model_reasoning.clearRetainingCapacity();
        try self.model_reasoning.appendNTimes(self.gpa, 0, self.codex_models.items.len);
        if (self.model_selection >= self.codex_models.items.len) self.model_selection = 0;
    }

    fn activeModelId(self: *const App) ?[]const u8 {
        const status = tui_status.modelStatus(self.runtime, self.cached_config) orelse return null;
        return status.model;
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
        const provider = tui_provider.compatibleProviderFromBaseUrl(self.cached_config.base_url.?);
        for (self.compatible_models.items) |model| {
            const id = try self.gpa.dupe(u8, model.id);
            errdefer self.gpa.free(id);
            const label = try self.gpa.dupe(u8, model.label);
            errdefer self.gpa.free(label);
            try self.codex_models.append(self.gpa, .{ .id = id, .label = label });
            try self.model_sources.append(self.gpa, .{ .openai_compatible = provider });
        }
    }

    fn loadLocalCompatibleCatalogs(self: *App) !void {
        self.loadLocalCompatibleCatalog(.ollama) catch {};
        self.loadLocalCompatibleCatalog(.llama_cpp) catch {};
    }

    fn loadLocalCompatibleCatalog(self: *App, provider: config_mod.Provider) !void {
        const base_url = provider.defaultBaseUrl() orelse return;
        const api_key = providerLocalApiKey(provider);
        const fetched = try openai_compatible_mod.listModels(self.gpa, self.io, base_url, api_key);
        defer {
            for (fetched) |*entry| entry.deinit(self.gpa);
            self.gpa.free(fetched);
        }
        for (fetched) |entry| {
            if (!includeLocalModel(provider, entry.id)) continue;
            const id = try self.gpa.dupe(u8, entry.id);
            errdefer self.gpa.free(id);
            const label = try localModelLabel(self.gpa, provider, entry.id);
            errdefer self.gpa.free(label);
            try self.codex_models.append(self.gpa, .{ .id = id, .label = label });
            try self.model_sources.append(self.gpa, .{ .openai_compatible = provider });
        }
    }

    fn fetchCompatibleCatalog(self: *App) !void {
        std.debug.assert(!self.compatible_models_fetched);
        const base_url = self.cached_config.base_url.?;
        const api_key = self.cached_config.api_key.?;
        const provider = self.cached_config.provider orelse tui_provider.compatibleProviderFromBaseUrl(base_url);
        const fetched = try openai_compatible_mod.listModels(self.gpa, self.io, base_url, api_key);
        defer {
            for (fetched) |*entry| entry.deinit(self.gpa);
            self.gpa.free(fetched);
        }
        errdefer self.compatibleModelsCacheClear();
        for (fetched) |entry| {
            if (!includeLocalModel(provider, entry.id)) continue;
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
        return tui_provider.hasOpenAICompatibleCredentials(self.cached_config);
    }

    fn shouldLoadConfiguredCompatibleCatalog(self: *const App) bool {
        if (!self.hasOpenAICompatibleCredentials()) return false;
        const base_url = self.cached_config.base_url orelse return false;
        const provider = self.cached_config.provider orelse tui_provider.compatibleProviderFromBaseUrl(base_url);
        if (provider == .ollama) return false;
        if (provider == .llama_cpp) return false;
        return true;
    }

    fn compatibleBaseUrl(self: *const App, provider: config_mod.Provider) ?[]const u8 {
        if (self.cached_config.base_url) |base_url| {
            const cached_provider = self.cached_config.provider orelse tui_provider.compatibleProviderFromBaseUrl(base_url);
            if (cached_provider == provider) return base_url;
        }
        return provider.defaultBaseUrl();
    }

    fn providerLocalApiKey(provider: config_mod.Provider) []const u8 {
        return switch (provider) {
            .ollama => "ollama",
            .llama_cpp => "llama.cpp",
            else => "",
        };
    }

    fn providerModelLabel(provider: config_mod.Provider) []const u8 {
        return switch (provider) {
            .ollama => "Ollama",
            .llama_cpp => "llama.cpp",
            else => provider.label(),
        };
    }

    fn localModelLabel(gpa: std.mem.Allocator, provider: config_mod.Provider, model_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s} · {s}", .{ providerModelLabel(provider), model_id });
    }

    fn includeLocalModel(provider: config_mod.Provider, model_id: []const u8) bool {
        if (provider == .ollama) {
            if (std.mem.endsWith(u8, model_id, "-cloud")) return false;
        }
        return true;
    }

    fn selectedReasoningIndex(self: *const App) u32 {
        if (self.model_selection >= self.model_reasoning.items.len) return 0;
        return self.model_reasoning.items[self.model_selection];
    }

    fn selectedReasoningEffort(self: *const App) ai.ReasoningEffort {
        return reasoningOptions()[self.selectedReasoningIndex()].effort;
    }

    fn cycleModelScope(self: *App) void {
        self.model_scope = switch (self.model_scope) {
            .global => .project,
            .project => .session,
            .session => .global,
        };
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
        const active_storage_idx = model_picker.findActiveStorageIdx(self.codex_models.items, self.activeModelId());
        const idx = model_picker.displayToStorage(active_storage_idx, self.model_selection);
        return self.codex_models.items[idx];
    }

    fn selectedModelSource(self: *const App) ?ModelSource {
        if (self.model_selection >= self.model_sources.items.len) return null;
        const active_storage_idx = model_picker.findActiveStorageIdx(self.codex_models.items, self.activeModelId());
        const idx = model_picker.displayToStorage(active_storage_idx, self.model_selection);
        if (idx >= self.model_sources.items.len) return null;
        return self.model_sources.items[idx];
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
        effort: ai.ReasoningEffort,
    ) !void {
        try self.runtime.?.attachOpenAiCompatibleClient(base_url, api_key, model_id, effort);
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
            if (!resume_picker.matches(summary, filter)) continue;
            if (visible_index == self.resume_selection) return summary;
            visible_index += 1;
        }
        return null;
    }

    fn visibleResumeCount(self: *App) !u32 {
        const filter = try self.peekInput();
        defer self.gpa.free(filter);
        return resume_picker.visibleCount(self.resume_summaries.items, filter);
    }

    fn resumeClear(self: *App) void {
        for (self.resume_summaries.items) |*summary| summary.deinit(self.gpa);
        self.resume_summaries.clearRetainingCapacity();
    }

    fn syncResumeListCursor(self: *App) void {
        self.resume_list.cursor = self.resume_selection;
        self.resume_list.ensureScroll();
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
                const title = try self.resumedToolTitle(message);
                defer self.gpa.free(title);
                _ = try self.thread.append(self.gpa, .tool, title, text);
            }
        }
        if (self.thread.messages.items.len > 0) self.thread.selected = @intCast(self.thread.messages.items.len - 1);
    }

    fn resumedToolTitle(self: *App, message: ai.ChatMessage) ![]u8 {
        if (message.tool_display_label) |label| return self.gpa.dupe(u8, label);
        const id = message.call_id orelse return self.gpa.dupe(u8, "tool");
        for (self.agent.messages.items) |candidate| {
            for (candidate.content) |block| {
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

    fn jumpThreadToBottom(self: *App) void {
        self.thread.selectLast();
        self.thread_auto_scroll = true;
        self.thread_list.scroll.pending_lines = 0;
        self.thread_list.scroll.wants_cursor = false;
    }

    fn updateMouseAutoScroll(self: *App) void {
        self.thread_auto_scroll = !self.thread_list.scroll.has_more and
            self.selectionIsLastMessage() and
            !self.selectedMessageIsLong();
    }

    fn navigateThread(self: *App, direction: ThreadNavigation) bool {
        self.thread_auto_scroll = false;
        if (self.scrollSelectedLongMessage(direction)) return true;
        switch (direction) {
            .previous => self.thread.moveSelection(.previous),
            .next => self.thread.moveSelection(.next),
        }
        self.anchorSelectedLongMessage(direction);
        return false;
    }

    fn scrollSelectedLongMessage(self: *App, direction: ThreadNavigation) bool {
        const selected = self.thread.selected orelse return false;
        if (selected >= self.thread.messages.items.len) return false;
        const rows = messageRows(self.thread.messages.items[selected], ConversationLayout.contentWidth(self.thread_view_width));
        const height = self.thread_view_height;
        if (rows <= height) return false;
        const rows_hidden = rows - height;
        const step = scrollStepRows(height);

        switch (direction) {
            .next => {
                const offset = self.selectedMessageOffset(selected);
                if (offset >= rows_hidden) return false;
                self.setSelectedMessageOffset(selected, @min(rows_hidden, offset + step));
                return true;
            },
            .previous => {
                const offset = self.selectedMessageOffset(selected);
                if (offset == 0) return false;
                self.setSelectedMessageOffset(selected, offset - @min(offset, step));
                return true;
            },
        }
    }

    fn selectedMessageIsLong(self: *const App) bool {
        const selected = self.thread.selected orelse return false;
        if (selected >= self.thread.messages.items.len) return false;
        const rows = messageRows(self.thread.messages.items[selected], ConversationLayout.contentWidth(self.thread_view_width));
        return rows > self.thread_view_height;
    }

    fn anchorSelectedLongMessage(self: *App, direction: ThreadNavigation) void {
        const selected = self.thread.selected orelse return;
        if (selected >= self.thread.messages.items.len) return;
        const rows = messageRows(self.thread.messages.items[selected], ConversationLayout.contentWidth(self.thread_view_width));
        const height = self.thread_view_height;
        if (rows <= height) return;
        const offset = switch (direction) {
            .next => 0,
            .previous => rows - height,
        };
        self.setSelectedMessageOffset(selected, offset);
    }

    fn selectedMessageOffset(self: *const App, selected: u32) u16 {
        if (self.thread_list.scroll.top == selected) return @intCast(@max(self.thread_list.scroll.offset, 0));
        return 0;
    }

    fn setSelectedMessageOffset(self: *App, selected: u32, offset: u16) void {
        self.thread_list.cursor = selected;
        self.thread_list.scroll.top = selected;
        self.thread_list.scroll.offset = @intCast(offset);
        self.thread_list.scroll.pending_lines = 0;
        self.thread_list.scroll.wants_cursor = false;
    }
};

fn scrollStepRows(height: u16) u16 {
    if (height == 0) return 1;
    return @min(height, long_message_scroll_step_rows);
}

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

const RootLayout = struct {
    input_height: u16,
    panel_height: u16,
    thread_height: u16,
    panel_row: u16,
    input_row: u16,
};

fn rootLayout(max_height: u16, panel_visible: bool) RootLayout {
    const input_height: u16 = @min(max_height, 6);
    const thread_height: u16 = max_height - input_height;
    const panel_height: u16 = if (panel_visible) @min(thread_height, 7) else 0;
    return .{
        .input_height = input_height,
        .panel_height = panel_height,
        .thread_height = thread_height,
        .panel_row = thread_height - panel_height,
        .input_row = thread_height,
    };
}

pub fn run(
    init: std.process.Init,
    runtime: *runtime_mod.AgentRuntime,
    config: config_mod.Config,
) !void {
    const gpa = init.arena.allocator();
    var tty_buffer: [8192]u8 = undefined;
    var fw_app = try tui_app.init(init.io, gpa, init.environ_map, &tty_buffer);
    defer fw_app.deinit();

    var app = App.initRuntime(init.io, gpa, runtime, config);
    app.bindInputCallbacks();
    defer app.deinit();

    const logo = try loadStartupLogo(gpa);
    defer gpa.free(logo);
    _ = try app.thread.append(gpa, .logo, "logo", logo);

    app.git_branch = loadGitBranch(gpa, init.io, runtime.cwd) catch "";

    var root: RootWidget = .{ .app = &app };
    try fw_app.run(root.widget(), .{});
}

fn loadStartupLogo(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8, @embedFile("assets/logo.txt"));
}

fn loadGitBranch(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]const u8 {
    const command = "branch=$(git branch --show-current 2>/dev/null); if [ -n \"$branch\" ]; then printf %s \"$branch\"; else git rev-parse --short HEAD 2>/dev/null; fi";
    var result = try bash_mod.runWithOptions(gpa, io, .{
        .cwd = cwd,
        .command = command,
        .timeout = bash_mod.timeoutFromSeconds(2),
    });
    defer result.deinit(gpa);
    if (result.code != 0) return "";
    const branch = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (branch.len == 0) return "";
    return try std.fmt.allocPrint(gpa, "⌥ {s}", .{branch});
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
                if (mouse.button == .wheel_down) self.app.updateMouseAutoScroll();
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
        if (try self.app.drainModelLoad()) visible_change = true;

        if (self.app.thread_projection.loading_index) |_| {
            self.spinner_tick_accum += drain_tick_ms;
            if (self.spinner_tick_accum >= spinner_tick_threshold_ms) {
                self.spinner_tick_accum = 0;
                self.app.advanceLoadingFrame();
                visible_change = true;
            }
        } else {
            self.spinner_tick_accum = 0;
        }

        const model_loading = self.app.model_load_future != null;
        const should_tick = self.app.in_flight or self.app.thread_projection.loading_index != null or model_loading;
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
            if (self.app.model_load_future != null) try self.startLoadingTick(ctx);
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

            if (self.app.thread_projection.loading_index != null) try self.startLoadingTick(ctx);
            if (try self.app.applyAgentEvent(event_ptr.*)) visible_change = true;
            if (self.app.thread_projection.loading_index != null) try self.startLoadingTick(ctx);
        }
        return visible_change;
    }

    fn drawRoot(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        const layout = rootLayout(max_height, self.app.mode != .normal);

        var thread_view: ThreadWidget = .{ .app = self.app };
        var panel_view: PanelWidget = .{ .app = self.app };
        var input_view: InputWidget = .{ .app = self.app };

        const thread_ctx = ctx.withConstraints(
            .{ .width = max_width, .height = layout.thread_height },
            .{ .width = max_width, .height = layout.thread_height },
        );
        const panel_ctx = ctx.withConstraints(
            .{ .width = max_width, .height = layout.panel_height },
            .{ .width = max_width, .height = layout.panel_height },
        );
        const input_ctx = ctx.withConstraints(
            .{ .width = max_width, .height = layout.input_height },
            .{ .width = max_width, .height = layout.input_height },
        );

        const child_count: usize = if (layout.panel_height == 0) 2 else 3;
        const children = try ctx.arena.alloc(vxfw.SubSurface, child_count);
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try thread_view.widget().draw(thread_ctx),
            .z_index = 0,
        };
        if (layout.panel_height > 0) {
            children[1] = .{
                .origin = .{ .row = layout.panel_row, .col = 0 },
                .surface = try panel_view.widget().draw(panel_ctx),
                .z_index = 1,
            };
            children[2] = .{
                .origin = .{ .row = layout.input_row, .col = 0 },
                .surface = try input_view.widget().draw(input_ctx),
                .z_index = 0,
            };
        } else {
            children[1] = .{
                .origin = .{ .row = layout.input_row, .col = 0 },
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
        self.syncViewport(ctx);
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

    fn syncViewport(self: *ThreadWidget, ctx: vxfw.DrawContext) void {
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        self.app.thread_view_width = max_width;
        self.app.thread_view_height = max_height -| ConversationLayout.top -| ConversationLayout.bottom;
        if (self.app.thread_view_height == 0) self.app.thread_view_height = 1;
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
        const messages = self.app.thread.messages.items;
        if (messages.len == 0) return;
        if (self.app.thread_auto_scroll) {
            const tail_index: u32 = @intCast(messages.len - 1);
            const cursor = self.app.thread_projection.loading_index orelse tail_index;
            self.app.thread_list.cursor = cursor;
            self.scrollCursorToTail(ctx, cursor);
            return;
        }
        const cursor = self.app.thread.selected orelse self.app.thread_projection.loading_index orelse 0;
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

const Command = enum { connect, model, new, resume_session };
const CommandEntry = struct { name: []const u8, command: Command };
const commands = [_]CommandEntry{
    .{ .name = "Connect", .command = .connect },
    .{ .name = "Models", .command = .model },
    .{ .name = "New", .command = .new },
    .{ .name = "Resume", .command = .resume_session },
};
const command_panel_entries = [_]command_panel.Entry{
    .{ .name = "Connect" },
    .{ .name = "Models" },
    .{ .name = "New" },
    .{ .name = "Resume" },
};

fn inputLabel(app: *const App) []const u8 {
    return switch (app.mode) {
        .normal => "Build",
        .command => "Command",
        .session_picker => "Search for Sessions",
        .provider_picker => "Connect to Provider",
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

fn pickerSecondaryColumn(width: u16) u16 {
    return @min(picker_secondary_column, width / 2);
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
            const input = try self.app.peekInput();
            defer self.app.gpa.free(input);
            const filter = if (input.len > 0 and input[0] == command_prefix) input[1..] else "";
            var content: command_panel.Content = .{
                .entries = &command_panel_entries,
                .filter = filter,
                .selection = self.app.command_selection,
            };
            var shell: panel_widget.Shell = .{ .child = content.widget() };
            return shell.widget().draw(ctx);
        }
        if (self.app.mode == .session_picker) {
            const filter = try self.app.peekInput();
            defer self.app.gpa.free(filter);
            var content: resume_picker.Content = .{
                .io = self.app.io,
                .list = &self.app.resume_list,
                .summaries = self.app.resume_summaries.items,
                .selection = self.app.resume_selection,
                .global = self.app.resume_global,
                .filter = filter,
            };
            var shell: panel_widget.Shell = .{ .child = content.widget() };
            return shell.widget().draw(ctx);
        }
        if (self.app.mode == .provider_picker) {
            var content: provider_picker.Content = .{
                .state = self.app.provider_picker,
                .codex_signed_in = self.app.isCodexSignedIn(),
            };
            var shell: panel_widget.Shell = .{ .child = content.widget() };
            return shell.widget().draw(ctx);
        }
        if (self.app.mode == .model_picker) {
            const status = tui_status.modelStatus(self.app.runtime, self.app.cached_config);
            var content: model_picker.Content = .{
                .models = self.app.codex_models.items,
                .list = &self.app.model_list,
                .selection = self.app.model_selection,
                .column = self.app.model_column,
                .active_model = if (status) |value| value.model else null,
                .reasoning_options = modelReasoningOptions(),
                .reasoning_indexes = self.app.model_reasoning.items,
                .scope = modelPickerScope(self.app.model_scope),
                .loading = self.app.model_load_future != null,
                .error_message = self.app.model_load_error,
            };
            var shell: panel_widget.Shell = .{ .child = content.widget() };
            return shell.widget().draw(ctx);
        }

        return vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
    }
};

fn modelPickerScope(scope: App.ModelScope) model_picker.Scope {
    return switch (scope) {
        .global => .global,
        .project => .project,
        .session => .session,
    };
}

const reasoning_options = [_]model_picker.ReasoningOption{
    .{ .label = "medium (Default)", .effort = .medium },
    .{ .label = "high", .effort = .high },
    .{ .label = "xhigh", .effort = .xhigh },
    .{ .label = "low", .effort = .low },
    .{ .label = "nothink", .effort = .none },
};

fn modelReasoningOptions() []const model_picker.ReasoningOption {
    return &reasoning_options;
}

fn reasoningOptions() []const model_picker.ReasoningOption {
    return &reasoning_options;
}

fn inputHintText(mode: App.Mode) []const u8 {
    return switch (mode) {
        .command => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Select" ++ symbols.separator_dot_padded ++ "[ESC] Back",
        .session_picker => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[TAB] Toggle" ++ symbols.separator_dot_padded ++ "[ENTER] Select" ++ symbols.separator_dot_padded ++ "[g] All sessions" ++ symbols.separator_dot_padded ++ "[ESC] Back",
        .provider_picker => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "←→ Actions" ++ symbols.separator_dot_padded ++ "[ENTER] Select" ++ symbols.separator_dot_padded ++ "[ESC] Back",
        .model_picker => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "←→ Column" ++ symbols.separator_dot_padded ++ "[TAB] Toggle Effort/Scope" ++ symbols.separator_dot_padded ++ "[ENTER] Select" ++ symbols.separator_dot_padded ++ "[ESC] Back",
        .normal => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[SHIFT] ↓ Jump to Bottom" ++ symbols.separator_dot_padded ++ "[TAB] Expand",
    };
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

        if (height <= 3) return try self.drawInputBorder(ctx, max_width, height);

        const show_branch = height > 4;
        const show_hint = height > 5;
        const children_count: usize = 3 + @as(usize, if (show_branch) 1 else 0) + @as(usize, if (show_hint) 1 else 0);
        const children = try ctx.arena.alloc(vxfw.SubSurface, children_count);
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try self.drawInputBorder(ctx, max_width, 3),
            .z_index = 0,
        };
        try self.drawInputStatus(ctx, children, max_width, .{ .branch = show_branch, .hint = show_hint });
        return .{
            .size = .{ .width = max_width, .height = height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn drawInputBorder(self: *InputWidget, ctx: vxfw.DrawContext, max_width: u16, height: u16) std.mem.Allocator.Error!vxfw.Surface {
        var prompt: vxfw.Text = .{ .text = ">", .softwrap = false, .width_basis = .parent };
        var prompt_box: vxfw.SizedBox = .{ .child = prompt.widget(), .size = .{ .width = 2, .height = 1 } };
        var command_input: CommandInputText = .{ .app = self.app };
        var input_box: vxfw.SizedBox = .{ .child = command_input.widget(), .size = .{ .width = max_width -| 2, .height = 1 } };
        var row: vxfw.FlexRow = .{
            .children = &.{
                .{ .widget = prompt_box.widget(), .flex = 0 },
                .{ .widget = input_box.widget(), .flex = 1 },
            },
        };
        var row_box: vxfw.SizedBox = .{ .child = row.widget(), .size = .{ .width = max_width -| 2, .height = 1 } };
        var border: vxfw.Border = .{
            .child = row_box.widget(),
            .style = StylePalette.thinking_body,
            .labels = &.{.{ .text = inputLabel(self.app), .alignment = .top_left }},
        };
        var box: vxfw.SizedBox = .{ .child = border.widget(), .size = .{ .width = max_width, .height = height } };
        return box.widget().draw(ctx.withConstraints(.{ .width = max_width, .height = height }, .{ .width = max_width, .height = height }));
    }

    const StatusRows = struct { branch: bool, hint: bool };

    fn drawInputStatus(self: *InputWidget, ctx: vxfw.DrawContext, children: []vxfw.SubSurface, max_width: u16, rows: StatusRows) std.mem.Allocator.Error!void {
        const cwd_raw = if (self.app.runtime) |runtime| runtime.cwd else self.app.agent.cwd;
        const home_dir = if (self.app.runtime) |runtime| runtime.home_dir else "";
        const cwd = try tui_status.formatCwdRelative(ctx.arena, cwd_raw, home_dir);
        const status_text = if (tui_status.modelStatus(self.app.runtime, self.app.cached_config)) |status|
            tui_status.formatModelStatus(ctx.arena, status) catch ""
        else
            "";
        const status_padding_x: u16 = @min(@as(u16, 1), max_width);
        const status_inner_width = max_width -| (status_padding_x * 2);
        const status_gap: u16 = if (cwd.len > 0 and status_text.len > 0) 1 else 0;
        const model_width: u16 = @intCast(@min(ctx.stringWidth(status_text), @as(usize, status_inner_width)));
        const cwd_width: u16 = status_inner_width -| model_width -| status_gap;
        try self.drawInputStatusRow(ctx, children, cwd, status_text, .{
            .padding_x = status_padding_x,
            .inner_width = status_inner_width,
            .cwd_width = cwd_width,
            .model_width = model_width,
            .show_branch = rows.branch,
            .show_hint = rows.hint,
        });
    }

    const StatusLayout = struct {
        padding_x: u16,
        inner_width: u16,
        cwd_width: u16,
        model_width: u16,
        show_branch: bool,
        show_hint: bool,
    };

    fn drawInputStatusRow(self: *InputWidget, ctx: vxfw.DrawContext, children: []vxfw.SubSurface, cwd: []const u8, status_text: []const u8, layout: StatusLayout) std.mem.Allocator.Error!void {
        var cwd_text: vxfw.Text = .{ .text = cwd, .style = StylePalette.cwd, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent };
        var model_text: vxfw.Text = .{ .text = status_text, .style = StylePalette.model_status, .text_align = .right, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent };
        const status_row = @as(u16, 3);
        var child_index: usize = 1;
        children[child_index] = .{
            .origin = .{ .row = status_row, .col = layout.padding_x },
            .surface = try cwd_text.widget().draw(ctx.withConstraints(.{ .width = layout.cwd_width, .height = 1 }, .{ .width = layout.cwd_width, .height = 1 })),
            .z_index = 0,
        };
        child_index += 1;
        children[child_index] = .{
            .origin = .{ .row = status_row, .col = layout.padding_x + layout.inner_width -| layout.model_width },
            .surface = try model_text.widget().draw(ctx.withConstraints(.{ .width = layout.model_width, .height = 1 }, .{ .width = layout.model_width, .height = 1 })),
            .z_index = 0,
        };
        child_index += 1;
        if (layout.show_branch) {
            try self.drawInputGitBranch(ctx, children, child_index, status_row + 1, layout.padding_x, layout.inner_width);
            child_index += 1;
        }
        if (layout.show_hint) try self.drawInputHint(ctx, children, child_index, status_row + 2, layout.padding_x, layout.inner_width);
    }

    fn drawInputGitBranch(self: *InputWidget, ctx: vxfw.DrawContext, children: []vxfw.SubSurface, child_index: usize, row: u16, col: u16, width: u16) std.mem.Allocator.Error!void {
        var branch_text: vxfw.Text = .{ .text = self.app.git_branch, .style = StylePalette.git_branch, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent };
        children[child_index] = .{
            .origin = .{ .row = row, .col = col },
            .surface = try branch_text.widget().draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 })),
            .z_index = 0,
        };
    }

    fn drawInputHint(self: *InputWidget, ctx: vxfw.DrawContext, children: []vxfw.SubSurface, child_index: usize, row: u16, col: u16, width: u16) std.mem.Allocator.Error!void {
        var hint_text: vxfw.Text = .{ .text = inputHintText(self.app.mode), .style = StylePalette.thinking_body, .text_align = .center, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent };
        children[child_index] = .{
            .origin = .{ .row = row, .col = col },
            .surface = try hint_text.widget().draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 })),
            .z_index = 0,
        };
    }
};

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

test "root layout keeps input fixed when panel opens" {
    const normal = rootLayout(30, false);
    const picker = rootLayout(30, true);

    try std.testing.expectEqual(normal.input_row, picker.input_row);
    try std.testing.expectEqual(normal.thread_height, picker.thread_height);
    try std.testing.expectEqual(@as(u16, 17), picker.panel_row);
    try std.testing.expectEqual(@as(u16, 7), picker.panel_height);
}

test "root layout clamps panel above input on short screens" {
    const layout = rootLayout(8, true);

    try std.testing.expectEqual(@as(u16, 6), layout.input_height);
    try std.testing.expectEqual(@as(u16, 2), layout.thread_height);
    try std.testing.expectEqual(@as(u16, 2), layout.panel_height);
    try std.testing.expectEqual(@as(u16, 0), layout.panel_row);
    try std.testing.expectEqual(@as(u16, 2), layout.input_row);
}

test "mouse bottom does not enable auto-scroll when older message is selected" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.append(gpa, .agent, "agent", "one");
    _ = try app.thread.append(gpa, .agent, "agent", "two");
    app.thread.selected = 0;
    app.thread_auto_scroll = false;
    app.thread_list.scroll.has_more = false;

    app.updateMouseAutoScroll();

    try std.testing.expect(!app.thread_auto_scroll);
}

test "shift down jumps to conversation bottom" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.append(gpa, .agent, "agent", "one");
    _ = try app.thread.append(gpa, .agent, "agent", "two");
    _ = try app.thread.append(gpa, .status, "status", "loading");
    app.thread.selected = 0;
    app.thread_auto_scroll = false;

    try std.testing.expect(try app.handleThreadKey(.{ .codepoint = vaxis.Key.down, .mods = .{ .shift = true } }));

    try std.testing.expectEqual(@as(?u32, 1), app.thread.selected);
    try std.testing.expect(app.thread_auto_scroll);
}

test "down scrolls through selected long message before moving selection" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.append(gpa, .agent, "agent", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    _ = try app.thread.append(gpa, .agent, "agent", "next");
    app.thread.selected = 0;
    app.thread_view_width = 80;
    app.thread_view_height = 4;

    const scrolled = app.navigateThread(.next);

    try std.testing.expect(scrolled);
    try std.testing.expectEqual(@as(?u32, 0), app.thread.selected);
    try std.testing.expectEqual(@as(u32, 0), app.thread_list.scroll.top);
    try std.testing.expect(app.thread_list.scroll.offset > 0);
}

test "long message scroll uses a small fixed step" {
    try std.testing.expectEqual(@as(u16, 1), scrollStepRows(1));
    try std.testing.expectEqual(@as(u16, 2), scrollStepRows(2));
    try std.testing.expectEqual(@as(u16, 3), scrollStepRows(20));
}

test "down moves after selected long message bottom is visible" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.append(gpa, .agent, "agent", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    _ = try app.thread.append(gpa, .agent, "agent", "next");
    app.thread.selected = 0;
    app.thread_view_width = 80;
    app.thread_view_height = 4;
    app.setSelectedMessageOffset(0, messageRows(app.thread.messages.items[0], ConversationLayout.contentWidth(app.thread_view_width)) - app.thread_view_height);

    const scrolled = app.navigateThread(.next);

    try std.testing.expect(!scrolled);
    try std.testing.expectEqual(@as(?u32, 1), app.thread.selected);
}

test "up enters selected long message at bottom" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.append(gpa, .agent, "agent", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    _ = try app.thread.append(gpa, .agent, "agent", "next");
    app.thread.selected = 1;
    app.thread_view_width = 80;
    app.thread_view_height = 4;

    const scrolled = app.navigateThread(.previous);

    try std.testing.expect(!scrolled);
    try std.testing.expectEqual(@as(?u32, 0), app.thread.selected);
    try std.testing.expect(app.thread_list.scroll.offset > 0);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var thread_widget: ThreadWidget = .{ .app = &app };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 6 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    _ = try thread_widget.widget().draw(ctx);

    try std.testing.expect(app.thread_list.scroll.offset > 0);
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

    var row: model_picker.Row = .{
        .model = &app.codex_models.items[0],
        .selected = true,
        .column = app.model_column,
        .active_model = null,
        .reasoning_label = modelReasoningOptions()[app.selectedReasoningIndex()].label,
        .scope_label = "Global",
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
    try std.testing.expectEqual(model_picker.Column.model, app.model_column);
}

test "provider picker has no custom connection row" {
    var state: provider_picker.State = .{};
    try std.testing.expect(state.handleKey(.{ .codepoint = vaxis.Key.down }, false));
    try std.testing.expectEqual(@as(u32, 0), state.selection);
    try std.testing.expectEqual(provider_picker.Action.connect_codex, state.selectedAction());
}

test "local provider model labels use correct separator" {
    const label = try App.localModelLabel(std.testing.allocator, .ollama, "llama3");
    defer std.testing.allocator.free(label);

    try std.testing.expectEqualStrings("Ollama · llama3", label);
}

test "ollama cloud models are not listed as local models" {
    try std.testing.expect(App.includeLocalModel(.ollama, "llama3"));
    try std.testing.expect(!App.includeLocalModel(.ollama, "gpt-oss-cloud"));
    try std.testing.expect(!App.includeLocalModel(.ollama, "gpt-oss:120b-cloud"));
    try std.testing.expect(App.includeLocalModel(.llama_cpp, "gpt-oss-cloud"));
}

test "local providers are not loaded twice through configured compatible catalog" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.cached_config.provider = .ollama;
    app.cached_config.base_url = @constCast("http://localhost:11434");
    app.cached_config.api_key = @constCast("ollama");

    try std.testing.expect(!app.shouldLoadConfiguredCompatibleCatalog());
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
    app.provider_picker.column = .provider;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.right }));
    try std.testing.expectEqual(provider_picker.Column.sign_out, app.provider_picker.column);
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(provider_picker.Column.provider, app.provider_picker.column);
}

test "codex sign-in survives selecting local compatible provider" {
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
    runtime.owned_client = null;
    var app = App.init(std.testing.io, gpa, &runtime.agent);
    app.runtime = &runtime;
    defer app.deinit();
    defer runtime.disconnectClient();

    app.codex_signed_in = true;
    try app.codex_models.append(gpa, .{ .id = try gpa.dupe(u8, "llama3"), .label = try gpa.dupe(u8, "llama3") });
    try app.model_sources.append(gpa, .{ .openai_compatible = .ollama });
    try app.model_reasoning.append(gpa, 0);
    app.model_selection = 0;
    app.cached_config_owned = true;
    app.cached_config.base_url = try gpa.dupe(u8, "http://localhost:11434/v1");
    app.cached_config.api_key = try gpa.dupe(u8, "ollama");

    try app.applySelectedModel();

    try std.testing.expect(app.isCodexSignedIn());
    try std.testing.expectEqual(config_mod.Provider.ollama, app.cached_config.provider.?);
}

test "active model appears at display position 0 without mutating storage" {
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

    const active_storage_idx = model_picker.findActiveStorageIdx(app.codex_models.items, "gpt-5.4-mini");
    const storage_idx = model_picker.displayToStorage(active_storage_idx, 0);
    try std.testing.expectEqualStrings("gpt-5.4-mini", app.codex_models.items[storage_idx].id);
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
    const thinking_index = app.thread_projection.thinking_index.?;
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
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);

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

test "structured tool after batch replaces loading status" {
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
    try std.testing.expectEqual(.status, app.thread.messages.items[2].kind);

    _ = try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "write_file",
        .arguments = "{\"path\":\"main.zig\",\"content\":\"const std = @import(\\\"std\\\");",
    } });

    try std.testing.expectEqual(@as(usize, 3), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[2].kind);
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
    try std.testing.expectEqualStrings("I will check.", app.thread.messages.items[1].body);
    try std.testing.expectEqualStrings("$ pwd", app.thread.messages.items[2].title);
    try std.testing.expectEqualStrings(" Still checking.", app.thread.messages.items[3].body);
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

test "expanded tool surface height cannot overflow vxfw buffer size" {
    const gpa = std.testing.allocator;
    const body = try gpa.alloc(u8, 80_000);
    defer gpa.free(body);
    @memset(body, 'x');

    const message: thread_mod.Message = .{
        .kind = .tool,
        .title = try gpa.dupe(u8, "$ yes"),
        .body = body,
        .expanded = true,
    };
    defer gpa.free(message.title);

    var widget: MessageWidget = .{
        .message = message,
        .selected = true,
        .loading_frame = 0,
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 120, .height = null },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try widget.widget().draw(ctx);
    try std.testing.expect(surface.size.width * surface.size.height <= std.math.maxInt(u16));
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
