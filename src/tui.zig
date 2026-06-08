const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
const at_mention = @import("at_mention.zig");
const bash_mod = @import("bash.zig");
const search_mod = @import("search.zig");
const codex = @import("codex.zig");
const config_mod = @import("config.zig");
const openai_compatible_mod = @import("ai/openai_compatible.zig");
const runtime_mod = @import("runtime.zig");
const session_mod = @import("session.zig");
const skill_mod = @import("skill.zig");
const symbols = @import("symbols.zig");
const thread_mod = @import("thread.zig");
const agent_worker = @import("tui/agent_worker.zig");
const Turn = @import("tui/turn.zig");
const model_catalogue = @import("tui/model_catalogue.zig");
const tui_turn_view = @import("tui/turn_view.zig");
const tui_metrics = @import("tui/metrics.zig");
const tui_message = @import("tui/widgets/message.zig");
const blackhole = @import("tui/blackhole.zig");
const at_search = @import("tui/widgets/at_search.zig");
const command_panel = @import("tui/widgets/command_panel.zig");
const model_loader = @import("tui/model_loader.zig");
const model_cache = @import("tui/model_cache.zig");
const model_picker = @import("tui/widgets/model_picker.zig");
const provider_picker = @import("tui/widgets/provider_picker.zig");
const resume_picker = @import("tui/widgets/resume_picker.zig");
const tree_selector = @import("tui/widgets/tree_selector.zig");
const panel = @import("tui/widgets/panel.zig");
const tui_provider = @import("tui/provider_controller.zig");
const tui_status = @import("tui/status.zig");
const tui_style = @import("tui/style.zig");
const logger = @import("logger");

const ConversationLayout = tui_message.ConversationLayout;
const MessageWidget = tui_message.MessageWidget;
const StylePalette = tui_style.Palette;
const mergedSelectedStyle = tui_style.mergedSelectedStyle;
const messageRowsCached = tui_metrics.messageRowsCached;

const loading_spinners = tui_turn_view.loading_spinners;
const loading_frame_ms = tui_message.loading_frame_ms;
const command_prefix: u8 = '/';
const long_message_scroll_step_rows: u16 = 3;
const ThreadNavigation = enum { previous, next };
const MentionSearchKind = enum { file, skill };

const DiffCounts = struct {
    additions: u32 = 0,
    deletions: u32 = 0,
};

const DiffRefreshJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []u8,
    done: *std.atomic.Value(bool),

    fn deinit(self: *DiffRefreshJob) void {
        self.gpa.free(self.cwd);
        self.* = undefined;
    }
};

const DiffRefreshOutcome = union(enum) {
    ready: DiffCounts,
    failed,

    pub fn deinit(self: *DiffRefreshOutcome) void {
        self.* = undefined;
    }
};

fn runDiffRefresh(job: *DiffRefreshJob) DiffRefreshOutcome {
    const gpa = job.gpa;
    const done = job.done;
    defer {
        job.deinit();
        gpa.destroy(job);
        done.store(true, .release);
    }

    var result = bash_mod.runWithOptions(gpa, job.io, .{
        .cwd = job.cwd,
        .command = diffCountCommand,
        .timeout = bash_mod.timeoutFromSeconds(1),
    }) catch return .failed;
    defer result.deinit(gpa);

    if (result.code != 0) return .failed;
    return .{ .ready = parseDiffCounts(result.stdout) };
}

pub const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    agent: *agent_mod.Agent,
    runtime: ?*runtime_mod.AgentRuntime = null,
    thread: thread_mod.Thread = .{},
    input: vxfw.TextField,
    palette_input: vxfw.TextField,
    worker_context: agent_worker.Context,
    turn_future: ?std.Io.Future(void) = null,
    owns_runtime: bool = false,
    mode: Mode = .normal,
    command_selection: u32 = 0,
    resume_selection: u32 = 0,
    resume_global: bool = false,
    resume_summaries: std.ArrayList(session_mod.SessionSummary) = .empty,
    resume_folded_projects: std.ArrayList([]u8) = .empty,
    tree_state: tree_selector.TreeState,
    /// All model/provider/selection state for the model picker — fetched
    /// lists, selection cursor/column/scope, and the async-load handle.
    models: model_catalogue.ModelCatalogue = .{},
    provider_picker: provider_picker.State = .{},
    codex_signed_in: bool = false,
    /// Stored API keys for catalogue providers (label -> key), mirrored from
    /// `~/.nova/auth.json`. Drives the picker's [CONNECTED] badges and supplies
    /// keys when (re)building the model catalogue. Owned; freed in `deinit`.
    provider_api_keys: codex.ApiKeyMap = .empty,
    /// Inline edit buffer for the provider setup form's API-key field. Owned;
    /// freed in `deinit`.
    provider_key_input: std.ArrayList(u8) = .empty,
    cached_config: config_mod.Config = .{},
    cached_config_owned: bool = false,
    retired_threads: std.ArrayList(thread_mod.Thread) = .empty,
    /// Lifecycle state for the in-progress agent turn (idle / active /
    /// interrupting). Collapses what used to be the `in_flight` and
    /// `turn_discarded` booleans plus the scattered discard logic.
    turn: Turn = .{},
    turn_view: tui_turn_view.TurnView = .{},
    loading_frame: u8 = 0,
    loading_tick_active: bool = false,
    // Black-hole intro animation. `blackhole_visible` is recomputed each draw
    // (true only while the startup logo sits at the top of the viewport) and
    // gates the animation tick so it stops costing anything once the logo
    // scrolls away.
    blackhole_frame: u16 = 0,
    blackhole_visible: bool = true,
    thread_auto_scroll: bool = true,
    git_label: []const u8 = "",
    diff_counts: DiffCounts = .{},
    diff_refresh_future: ?std.Io.Future(DiffRefreshOutcome) = null,
    diff_refresh_done: std.atomic.Value(bool) = .init(false),
    diff_refresh_again: bool = false,
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
    tree_list: vxfw.ListView = .{
        .children = .{ .slice = &.{} },
        .draw_cursor = false,
        .wheel_scroll = 3,
    },
    model_list: vxfw.ListView = .{
        .children = .{ .slice = &.{} },
        .draw_cursor = false,
        .wheel_scroll = 3,
    },
    pending_quit_at: ?std.Io.Timestamp = null,
    queued_user_messages: std.ArrayList([]const u8) = .empty,
    /// Raw prompt for a turn that `beginSubmit` accepted but `startTurn` has
    /// not yet handed to the worker. Owned by `gpa`; the worker frees it once
    /// the turn starts.
    pending_prompt: ?[]u8 = null,
    /// When true, arrow keys navigate conversation blocks; when false they move
    /// the cursor within the (multiline) input. Set when the cursor leaves the
    /// top of the input, cleared when it re-enters from the last block or on any
    /// edit/submit. See `RootWidget.captureEvent`.
    block_nav: bool = false,
    at_active: bool = false,
    at_query: []u8 = "",
    at_results: std.ArrayList([]const u8) = .empty,
    at_selection: u32 = 0,
    at_indexing: bool = false,
    at_kind: MentionSearchKind = .file,

    pub const ctrl_c_double_press_ms: u32 = 1500;

    const Mode = enum { normal, command, session_picker, provider_picker, model_picker, tree_picker };
    const ModelCatalog = enum { connected_provider, openai_codex };
    const ModelSource = model_loader.ModelSource;
    const ModelScope = model_catalogue.ModelScope;

    pub fn init(io: std.Io, gpa: std.mem.Allocator, agent: *agent_mod.Agent) App {
        return .{
            .io = io,
            .gpa = gpa,
            .agent = agent,
            .input = .init(gpa),
            .palette_input = .init(gpa),
            .tree_state = .init(gpa),
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
        app.codex_signed_in = !runtime.codex_connection_expired and
            (runtime.hasCodexClient() or tui_provider.detectCodexSignIn(gpa, io, runtime.home_dir));
        app.cached_config = config;
        app.cached_config_owned = true;
        return app;
    }

    pub fn bindInputCallbacks(self: *App) void {
        self.input.userdata = self;
        self.input.onChange = inputChanged;
        self.palette_input.userdata = self;
        self.palette_input.onChange = paletteInputChanged;
    }

    pub fn deinit(self: *App) void {
        if (self.turn.state == .interrupting) {
            self.discardAbandonedTurn();
        } else {
            self.awaitTurn();
        }
        // Cancel the in-flight load first (it needs `io`), then free the
        // catalogue's owned lists + error in one pass.
        self.cancelModelLoad();
        for (self.retired_threads.items) |*thread| thread.deinit(self.gpa);
        self.retired_threads.deinit(self.gpa);
        self.resumeClear();
        self.resumeClearFolds();
        self.resume_folded_projects.deinit(self.gpa);
        self.tree_state.deinit();
        self.cancelDiffRefresh();
        self.models.deinit(self.gpa);
        codex.freeApiKeyMap(self.gpa, &self.provider_api_keys);
        self.provider_key_input.deinit(self.gpa);
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
        self.clearQueuedUserMessages();
        self.queued_user_messages.deinit(self.gpa);
        if (self.pending_prompt) |prompt| self.worker_context.gpa.free(prompt);
        self.closeAtSearch();
        self.at_results.deinit(self.gpa);
        self.turn_view.deinit(self.gpa);
        self.thread.deinit(self.gpa);
        self.input.deinit();
        self.palette_input.deinit();
        self.* = undefined;
    }

    fn awaitTurn(self: *App) void {
        if (self.turn_future) |*future| {
            future.await(self.io);
            self.turn_future = null;
        }
    }

    pub fn handleInterrupt(self: *App) !void {
        if (self.turn.state != .active) return;
        self.worker_context.requestCancel();
        // Show the cancellation notice immediately; the worker's own
        // `turn_failed`/`turn_finished` are then swallowed while interrupting.
        const message = try self.gpa.dupe(u8, agent_worker.cancel_message);
        var event: agent_mod.Agent.Event = .{ .turn_failed = message };
        defer event.deinit(self.gpa);
        _ = try self.turn_view.apply(self.gpa, &self.thread, event);
        self.turn.interrupt();
    }

    fn discardAbandonedTurn(self: *App) void {
        if (self.turn.state != .interrupting and self.turn_future == null) return;
        if (self.turn_future) |*future| {
            // `cancel` blocks until the task hits its next cancellation point
            // (typically the network read) and unwinds. On a healthy stream
            // this is near-instant; on a hung connection it forces the OS
            // read to abort.
            _ = future.cancel(self.io);
            self.turn_future = null;
        }
        var batch: std.ArrayList(*agent_mod.Agent.Event) = .empty;
        defer batch.deinit(self.worker_context.gpa);
        self.worker_context.queue.drainInto(
            self.worker_context.io,
            self.worker_context.gpa,
            &batch,
        ) catch {};
        for (batch.items) |event_ptr| {
            event_ptr.deinit(self.worker_context.gpa);
            self.worker_context.gpa.destroy(event_ptr);
        }
        if (self.turn.state == .interrupting) self.turn.reset();
    }

    /// Start a turn from the current input. Returns true when a turn was
    /// started (the caller should then call `startTurn`); false when the
    /// prompt was empty, had no provider, or was queued behind a running turn.
    pub fn beginSubmit(self: *App) !bool {
        self.closeAtSearch();
        self.block_nav = false;
        // If a previous turn was Esc-interrupted, force-cancel its worker
        // before starting a new one. Two concurrent workers would race on
        // the shared agent message history.
        if (self.turn.state == .interrupting) self.discardAbandonedTurn();
        if (self.turn.isActive()) return try self.enqueueSubmit();
        const prompt = try self.input.toOwnedSlice();
        defer self.gpa.free(prompt);
        if (prompt.len == 0) return false;

        if (self.runtime != null and self.runtime.?.client == .none) {
            _ = try self.thread.append(self.gpa, .user, "you", prompt);
            const message = try self.formatNoProviderMessage();
            defer self.gpa.free(message);
            _ = try self.thread.append(self.gpa, .agent, "agent", message);
            return false;
        }

        self.resetTurnState();
        self.worker_context.resetCancel();
        _ = try self.thread.append(self.gpa, .user, "you", prompt);
        try self.appendSkillInvocationsToThread(prompt);
        self.turn_view.awaitModel();
        // The worker expands `@`-mentions (reading files / images) off the UI
        // thread; stash the raw text for `startTurn` to hand over. Owned by
        // `worker_context.gpa` — the worker frees it with that allocator, which
        // differs from `self.gpa` (an arena), so allocating it here with the
        // wrong allocator would crash on free.
        self.pending_prompt = try self.worker_context.gpa.dupe(u8, prompt);
        self.turn.submit();
        return true;
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
                if (self.runtime) |rt| {
                    if (rt.codex_connection_expired) return self.gpa.dupe(u8, runtime_mod.codex_connection_expired_message);
                }
                return self.gpa.dupe(u8, "No OpenAI Codex session — type /connect to sign in.");
            }
        }
        return self.gpa.dupe(
            u8,
            "No provider connected. Type /connect to pick one, or set OPENAI_MODEL=<provider>/<model>.",
        );
    }

    fn resetTurnState(self: *App) void {
        self.turn_view.reset(self.io);
        self.loading_frame = 0;
        // Leave `thread_auto_scroll` alone — if the user has scrolled away
        // from the tail to read older context, submitting another message
        // should not yank them back. They can scroll down (or arrow-down)
        // to opt back into auto-follow.
    }

    pub fn startTurn(self: *App) !void {
        const prompt = self.pending_prompt;
        self.pending_prompt = null;
        errdefer if (prompt) |p| self.worker_context.gpa.free(p);
        self.turn_future = try self.io.concurrent(agent_worker.runAgentTurn, .{
            self.agent,
            &self.worker_context,
            prompt,
        });
    }

    fn advanceLoadingFrame(self: *App) void {
        std.debug.assert(tui_message.loading_frames.len > 0);
        self.loading_frame +%= 1;
        if (self.loading_frame >= tui_message.loading_frames.len) self.loading_frame = 0;
    }

    fn advanceBlackholeFrame(self: *App) void {
        self.blackhole_frame += 1;
        if (self.blackhole_frame >= blackhole.frame_count) self.blackhole_frame = 0;
    }

    pub fn applyAgentEvent(self: *App, event: agent_mod.Agent.Event) !bool {
        const outcome = self.turn.apply(event);
        if (!outcome.project) {
            // Interrupting: a discarded turn's output must not mutate the
            // thread. Join the worker once it posts its terminal event.
            if (outcome.finished) self.awaitTurn();
            return false;
        }
        var visible_change = try self.turn_view.apply(self.gpa, &self.thread, event);
        switch (event) {
            .queued_messages_flushed => |count| {
                if (count > 0 and self.queued_user_messages.items.len > 0) {
                    try self.flushQueuedUserMessagesToThread(count);
                    visible_change = true;
                }
            },
            else => {},
        }
        if (outcome.finished) {
            self.awaitTurn();
            if (self.queued_user_messages.items.len > 0) {
                self.clearQueuedUserMessages();
                visible_change = true;
            }
        }
        return visible_change;
    }

    pub fn handleCommandKey(self: *App, key: vaxis.Key) !bool {
        return switch (self.mode) {
            .provider_picker => self.handleProviderPickerKey(key),
            .model_picker => self.handleModelPickerKey(key),
            .session_picker => self.handleSessionPickerKey(key),
            .tree_picker => self.handleTreePickerKey(key),
            .command => self.handleCommandMenuKey(key),
            .normal => self.handleThreadKey(key),
        };
    }

    fn handleTreePickerKey(self: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.up, .{})) {
            self.tree_state.moveUp();
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            self.tree_state.moveDown();
            return true;
        }
        if (key.matches(vaxis.Key.left, .{})) {
            const filter = try self.peekPaletteInput();
            defer self.gpa.free(filter);
            try self.tree_state.cycleFilter(filter, false);
            return true;
        }
        if (key.matches(vaxis.Key.right, .{})) {
            const filter = try self.peekPaletteInput();
            defer self.gpa.free(filter);
            try self.tree_state.cycleFilter(filter, true);
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            const filter = try self.peekPaletteInput();
            defer self.gpa.free(filter);
            try self.tree_state.toggleFoldSelected(filter);
            return true;
        }
        return false;
    }

    fn handleProviderPickerKey(self: *App, key: vaxis.Key) !bool {
        // The setup form hosts its own inline API-key editor: capture typed text
        // and backspace here so nothing leaks to the (unused) overlay search row.
        if (self.provider_picker.stage == .form) {
            if (key.matches(vaxis.Key.backspace, .{})) {
                self.popProviderKeyInput();
                return true;
            }
            if (key.text) |text| {
                try self.provider_key_input.appendSlice(self.gpa, text);
                return true;
            }
            // Swallow everything else (arrows, tab) — Enter/Esc are handled upstream.
            return true;
        }
        return self.provider_picker.handleKey(key, self.isCodexSignedIn());
    }

    /// Remove the last UTF-8 scalar from the inline API-key buffer.
    fn popProviderKeyInput(self: *App) void {
        const items = self.provider_key_input.items;
        if (items.len == 0) return;
        var cut = items.len - 1;
        while (cut > 0 and (items[cut] & 0xC0) == 0x80) cut -= 1;
        self.provider_key_input.shrinkRetainingCapacity(cut);
    }

    fn handleModelPickerKey(self: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.left, .{})) {
            self.models.model_column = self.models.model_column.previous();
            return true;
        }
        if (key.matches(vaxis.Key.right, .{})) {
            if (self.models.len() > 0) self.models.model_column = self.models.model_column.next();
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            switch (self.models.model_column) {
                .model => self.models.model_column = self.models.model_column.next(),
                .reasoning => try self.cycleSelectedReasoning(),
                .scope => self.cycleModelScope(),
            }
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            try self.stepModelSelection(false);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            try self.stepModelSelection(true);
            return true;
        }
        return false;
    }

    fn handleSessionPickerKey(self: *App, key: vaxis.Key) !bool {
        if (key.matches('a', .{ .ctrl = true })) {
            self.resume_global = !self.resume_global;
            self.resume_selection = 0;
            self.resumeClearFolds();
            try self.reloadResumeSessions();
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            if (self.resume_global) try self.toggleSelectedResumeProject();
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
        if (self.at_active and self.at_results.items.len > 0) {
            if (key.matches(vaxis.Key.up, .{})) {
                self.at_selection = previousIndex(self.at_selection, @intCast(self.at_results.items.len));
                return true;
            }
            if (key.matches(vaxis.Key.down, .{})) {
                self.at_selection = nextIndex(self.at_selection, @intCast(self.at_results.items.len));
                return true;
            }
        }
        if (key.matches(vaxis.Key.down, .{ .shift = true })) {
            self.jumpThreadToBottom();
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            _ = self.navigateThread(.previous);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            // Stepping down past the last block (when it can't scroll further)
            // re-enters the input and traps the cursor there again.
            if (self.block_nav and self.selectionIsLastMessage() and !self.selectedMessageCanScrollDown()) {
                self.block_nav = false;
                self.thread_auto_scroll = true;
                _ = try self.moveInputCursorVertical(.down);
                return true;
            }
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
        // While typing an API key in the provider form, the input is the key —
        // never reinterpret a leading '/' as a command.
        if (self.mode == .provider_picker and self.provider_picker.stage == .form) return;
        if (self.mode == .session_picker or self.mode == .provider_picker or self.mode == .model_picker or self.mode == .tree_picker) {
            if (value.len > 0 and value[0] == command_prefix) {
                self.mode = .command;
                self.command_selection = 0;
                return;
            }
            if (self.mode == .session_picker) {
                if (self.resume_selection >= try self.visibleResumeCount()) self.resume_selection = 0;
            }
            return;
        }
        if (value.len > 0 and value[0] == command_prefix) {
            self.mode = .command;
            self.command_selection = 0;
            return;
        }
        self.mode = .normal;
        self.command_selection = 0;
    }

    fn cancelMode(self: *App) !bool {
        if (self.mode == .normal) return false;
        // Esc inside the provider setup form returns to the provider list.
        if (self.mode == .provider_picker and self.provider_picker.stage == .form) {
            self.provider_picker.stage = .list;
            self.provider_picker.form_provider = null;
            self.provider_key_input.clearRetainingCapacity();
            return true;
        }
        if (self.mode == .model_picker) {
            self.cancelModelLoad();
            try self.revertModelPickerSnapshot();
        }
        if (self.mode == .session_picker or self.mode == .provider_picker or self.mode == .model_picker or self.mode == .tree_picker) {
            try self.openCommandMenu();
            self.resumeClear();
            return true;
        }
        self.mode = .normal;
        self.clearInput();
        self.clearPaletteInput();
        self.resumeClear();
        return true;
    }

    fn revertModelPickerSnapshot(self: *App) !void {
        self.models.restore();
    }

    fn submitMode(self: *App) !bool {
        if (self.mode == .provider_picker) {
            if (self.provider_picker.stage == .form) {
                const provider = self.provider_picker.form_provider orelse return true;
                self.submitProviderSetup(provider) catch |err| try self.reportConnectionError(err);
                return true;
            }
            switch (self.provider_picker.selectedAction()) {
                .connect_codex => self.connectCodex() catch |err| try self.reportConnectionError(err),
                .sign_out_codex => {
                    if (self.isCodexSignedIn()) {
                        self.signOutCodex() catch |err| try self.reportConnectionError(err);
                    } else {
                        self.connectCodex() catch |err| try self.reportConnectionError(err);
                    }
                },
                .open_form => |provider| self.openProviderForm(provider),
            }
            return true;
        }
        if (self.mode == .model_picker) {
            if (self.models.len() == 0) return true;
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
        if (self.mode == .tree_picker) {
            if (self.tree_state.selectedId()) |id| {
                // Switching to the current leaf is a no-op; just close.
                if (!self.tree_state.selectedIsLeaf()) {
                    var buffer: [session_mod.entry_id_len]u8 = undefined;
                    @memcpy(buffer[0..], id);
                    self.navigateToEntry(buffer[0..]) catch |err| {
                        try self.reportSessionSwitchError(err);
                        return true;
                    };
                }
            }
            self.mode = .normal;
            self.clearInput();
            self.clearPaletteInput();
            return true;
        }
        if (self.mode == .command) {
            const filter = try self.peekPaletteInput();
            defer self.gpa.free(filter);
            if (resolveCommand(self, filter)) |command| {
                self.clearPaletteInput();
                self.clearInput();
                switch (command) {
                    .new => self.switchToNewSession() catch |err| try self.reportSessionSwitchError(err),
                    .resume_session => try self.openResumePicker(),
                    .timeline => self.openTimelineSelector() catch |err| try self.reportSessionSwitchError(err),
                    .connect => try self.openProviderPicker(),
                    .model => self.openModelPicker() catch |err| try self.reportConnectionError(err),
                }
            }
            return true;
        }
        return false;
    }

    fn openCommandMenu(self: *App) !void {
        self.mode = .command;
        self.clearInput();
        self.clearPaletteInput();
        self.command_selection = 0;
    }

    fn openResumePicker(self: *App) !void {
        self.mode = .session_picker;
        self.resume_global = false;
        self.resume_selection = 0;
        self.resumeClearFolds();
        self.clearInput();
        try self.reloadResumeSessions();
    }

    fn openProviderPicker(self: *App) !void {
        self.mode = .provider_picker;
        self.provider_picker.reset();
        self.clearInput();
        self.clearPaletteInput();
        try self.refreshProviderApiKeys();
    }

    /// Reload the cached provider API keys from `~/.nova/auth.json`. Drives the
    /// picker badges and the multi-provider model catalogue.
    fn refreshProviderApiKeys(self: *App) !void {
        const home = self.runtime.?.home_dir;
        if (home.len == 0) return;
        var fresh = try codex.loadAllProviderApiKeys(self.gpa, self.io, home);
        codex.freeApiKeyMap(self.gpa, &self.provider_api_keys);
        self.provider_api_keys = fresh;
        fresh = .empty;
    }

    fn openProviderForm(self: *App, provider: config_mod.Provider) void {
        self.provider_picker.stage = .form;
        self.provider_picker.form_provider = provider;
        self.provider_key_input.clearRetainingCapacity();
    }

    fn openTimelineSelector(self: *App) !void {
        if (self.turn.isActive()) return error.InFlightTurn;
        self.mode = .tree_picker;
        self.clearInput();
        try self.reloadTreeNodes();
    }

    fn openModelPicker(self: *App) !void {
        self.mode = .model_picker;
        self.models.model_column = .model;
        self.models.model_selection = 0;
        self.models.model_scope = self.defaultModelScope();
        self.clearInput();

        if (self.models.models_cached and self.models.len() > 0) {
            try self.finishModelCatalogReload();
            try self.snapshotModelPickerState();
            return;
        }

        if (try self.restoreModelCache()) return;

        // Cold path — clear stale state, kick off the async load.
        self.codexModelsClear();
        self.models.reasoning_snapshot.clearRetainingCapacity();
        self.models.model_selection_snapshot = 0;
        try self.startModelLoad(.connected_provider);
    }

    fn snapshotModelPickerState(self: *App) !void {
        try self.models.snapshot(self.gpa);
    }

    fn startModelLoad(self: *App, catalog: ModelCatalog) !void {
        self.cancelModelLoad();
        if (self.models.model_load_error) |message| {
            self.gpa.free(message);
            self.models.model_load_error = null;
        }

        const job = try self.gpa.create(model_loader.Job);
        errdefer self.gpa.destroy(job);

        const configured = try self.collectConfiguredProviders(catalog);
        errdefer {
            for (configured) |c| {
                self.gpa.free(c.base_url);
                self.gpa.free(c.api_key);
            }
            if (configured.len > 0) self.gpa.free(configured);
        }

        job.* = .{
            .gpa = self.gpa,
            .io = self.io,
            .catalog = switch (catalog) {
                .connected_provider => .connected_provider,
                .openai_codex => .openai_codex,
            },
            .configured = configured,
            .include_locals = catalog == .connected_provider,
            .codex_signed_in = self.isCodexSignedIn(),
            .done = &self.models.model_load_done,
        };

        self.models.model_load_merge = false;
        self.models.model_load_done.store(false, .release);
        self.models.model_load_future = try self.io.concurrent(model_loader.run, .{job});
    }

    /// Every OpenAI-compatible provider to fetch for a full catalogue reload:
    /// each catalogue provider with a stored key (or an anonymous tier), plus a
    /// non-catalogue env/config provider when one is configured. Caller owns the slice.
    fn collectConfiguredProviders(self: *App, catalog: ModelCatalog) ![]model_loader.Configured {
        var list: std.ArrayList(model_loader.Configured) = .empty;
        errdefer {
            for (list.items) |c| {
                self.gpa.free(c.base_url);
                self.gpa.free(c.api_key);
            }
            list.deinit(self.gpa);
        }
        if (catalog == .connected_provider) {
            for (config_mod.catalogueProviders()) |provider| {
                const base_url = provider.defaultBaseUrl() orelse continue;
                // Stored key wins; otherwise an anonymous-tier provider (OpenCode
                // Zen) still loads via its `public` sentinel (free models only).
                const key = self.provider_api_keys.get(provider.label()) orelse anon: {
                    break :anon provider.anonymousApiKey() orelse continue;
                };
                try self.appendConfigured(&list, provider, base_url, key);
            }
            if (self.shouldLoadConfiguredCompatibleCatalog()) {
                const base_url = self.cached_config.base_url.?;
                const provider = self.cached_config.provider orelse tui_provider.compatibleProviderFromBaseUrl(base_url);
                // Catalogue providers are already covered by the auth.json keys above.
                if (!provider.isCatalogue()) {
                    try self.appendConfigured(&list, provider, base_url, self.cached_config.api_key.?);
                }
            }
        }
        return list.toOwnedSlice(self.gpa);
    }

    fn appendConfigured(
        self: *App,
        list: *std.ArrayList(model_loader.Configured),
        provider: config_mod.Provider,
        base_url: []const u8,
        api_key: []const u8,
    ) !void {
        const url = try self.gpa.dupe(u8, base_url);
        errdefer self.gpa.free(url);
        const key = try self.gpa.dupe(u8, api_key);
        errdefer self.gpa.free(key);
        try list.append(self.gpa, .{ .provider = provider, .base_url = url, .api_key = key });
    }

    fn cancelModelLoad(self: *App) void {
        if (self.models.model_load_future) |*future| {
            var outcome = future.cancel(self.io);
            outcome.deinit(self.gpa);
            self.models.model_load_future = null;
        }
        self.models.model_load_done.store(false, .release);
    }

    /// Called from the tick handler. Polls the non-blocking `done` flag, and
    /// only `await`s once the worker has signalled completion. Returns true
    /// if a redraw is needed.
    fn drainModelLoad(self: *App) !bool {
        if (self.models.model_load_future == null) return false;
        if (!self.models.model_load_done.load(.acquire)) return false;

        var outcome = self.models.model_load_future.?.await(self.io);
        self.models.model_load_future = null;
        self.models.model_load_done.store(false, .release);
        defer outcome.deinit(self.gpa);

        switch (outcome) {
            .ready => |*result| try self.installModelLoadResult(result),
            .failed => |message| {
                if (self.models.model_load_error) |old| self.gpa.free(old);
                self.models.model_load_error = try self.gpa.dupe(u8, message);
            },
        }
        return true;
    }

    fn installModelLoadResult(self: *App, result: *model_loader.Result) !void {
        if (self.models.model_load_merge) {
            // Incremental load: replace only the freshly-fetched providers'
            // models, leaving previously-cached providers untouched.
            var refreshed = std.EnumSet(config_mod.Provider).initEmpty();
            for (result.sources.items) |source| switch (source) {
                .openai_compatible => |provider| {
                    if (!refreshed.contains(provider)) {
                        self.dropModelsForProvider(provider);
                        refreshed.insert(provider);
                    }
                },
                .openai_codex => {},
            };
        } else {
            self.codexModelsClear();
        }
        // Move models in (the struct copies own their id/label); clearing the
        // result without freeing avoids a double-free. `models` and `sources`
        // are built in lockstep, so they zip into one entry each.
        std.debug.assert(result.models.items.len == result.sources.items.len);
        for (result.models.items, result.sources.items) |*model, source| {
            try self.models.append(self.gpa, model.*, source);
        }
        result.models.clearRetainingCapacity();
        result.sources.clearRetainingCapacity();
        self.models.model_load_merge = false;
        try self.finishModelCatalogReload();
        try self.snapshotModelPickerState();
        self.models.models_cached = true;
        self.saveModelCache() catch |err| std.log.warn("models.cache.save.failed err={s}", .{@errorName(err)});
    }

    /// Remove every cached model that came from `provider`.
    fn dropModelsForProvider(self: *App, provider: config_mod.Provider) void {
        self.models.dropProvider(self.gpa, provider);
    }

    fn restoreModelCache(self: *App) !bool {
        const runtime = self.runtime orelse return false;
        if (runtime.home_dir.len == 0) return false;

        var configured = try self.collectModelCacheConfigured();
        defer configured.deinit(self.gpa);

        var cached = model_cache.load(self.gpa, self.io, runtime.home_dir, configured.items) catch return false;
        defer cached.deinit(self.gpa);

        self.codexModelsClear();
        for (cached.items.items) |*record| {
            try self.models.append(self.gpa, record.model, record.source);
            record.model = .{ .id = &.{}, .label = &.{} };
        }
        if (self.isCodexSignedIn()) try self.loadCodexStaticCatalog();
        if (self.models.len() == 0) return false;

        try self.finishModelCatalogReload();
        try self.snapshotModelPickerState();
        self.models.models_cached = true;
        return true;
    }

    fn saveModelCache(self: *App) !void {
        const runtime = self.runtime orelse return;
        if (runtime.home_dir.len == 0) return;

        var configured = try self.collectModelCacheConfigured();
        defer configured.deinit(self.gpa);
        if (configured.items.len == 0) return;

        const records = try self.gpa.alloc(model_cache.Record, self.models.entries.items.len);
        defer self.gpa.free(records);
        for (self.models.entries.items, 0..) |entry, index| {
            records[index] = .{ .model = entry.model, .source = entry.source };
        }
        try model_cache.save(self.gpa, self.io, runtime.home_dir, records, configured.items);
    }

    fn collectModelCacheConfigured(self: *App) !std.ArrayList(model_cache.Configured) {
        var list: std.ArrayList(model_cache.Configured) = .empty;
        errdefer list.deinit(self.gpa);

        for (config_mod.catalogueProviders()) |provider| {
            const base_url = provider.defaultBaseUrl() orelse continue;
            const auth_mode: model_cache.AuthMode = if (self.provider_api_keys.get(provider.label())) |_|
                .keyed
            else if (provider.anonymousApiKey() != null)
                .anonymous
            else
                continue;
            try list.append(self.gpa, .{ .provider = provider, .base_url = base_url, .auth_mode = auth_mode });
        }

        if (self.shouldLoadConfiguredCompatibleCatalog()) {
            const base_url = self.cached_config.base_url.?;
            const provider = self.cached_config.provider orelse tui_provider.compatibleProviderFromBaseUrl(base_url);
            if (!provider.isCatalogue()) {
                try list.append(self.gpa, .{ .provider = provider, .base_url = base_url, .auth_mode = .keyed });
            }
        }

        if (config_mod.Provider.ollama.defaultBaseUrl()) |base_url| {
            try list.append(self.gpa, .{ .provider = .ollama, .base_url = base_url, .auth_mode = .local });
        }
        if (config_mod.Provider.llama_cpp.defaultBaseUrl()) |base_url| {
            try list.append(self.gpa, .{ .provider = .llama_cpp, .base_url = base_url, .auth_mode = .local });
        }
        return list;
    }

    fn defaultModelScope(self: *App) ModelScope {
        const runtime = self.runtime orelse return .global;
        if (config_mod.projectConfigExists(self.gpa, self.io, runtime.cwd)) return .project;
        return .global;
    }

    fn connectCodex(self: *App) !void {
        if (self.turn.isActive()) return error.InFlightTurn;
        var credentials = try codex.login(self.gpa, self.io, self.runtime.?.home_dir);
        defer credentials.deinit(self.gpa);
        self.models.models_cached = false;
        try self.reloadModelCatalog(.openai_codex);
        const model = self.selectedCodexModel() orelse return error.NoModels;
        const effort = self.selectedReasoningEffort();
        try self.connectCodexClient(credentials, model.id, effort);
        self.codex_signed_in = true;
        self.runtime.?.codex_connection_expired = false;
        try self.persistModelSelection(.openai, model.id, effort, .global);
        self.mode = .normal;
        self.clearInput();
        _ = try self.thread.append(self.gpa, .agent, "agent", "Connected to OpenAI Codex.");
    }

    fn signOutCodex(self: *App) !void {
        if (self.turn.isActive()) return error.InFlightTurn;
        try codex.signOut(self.gpa, self.io, self.runtime.?.home_dir);
        self.runtime.?.disconnectCodexClient();
        self.codex_signed_in = false;
        self.runtime.?.codex_connection_expired = false;
        self.agent.client = self.runtime.?.client;
        self.codexModelsClear();
        self.models.models_cached = false;
        self.mode = .normal;
        self.clearInput();
        _ = try self.thread.append(self.gpa, .agent, "agent", "Signed out from OpenAI Codex.");
    }

    /// Save the entered API key for a catalogue provider, then fetch just that
    /// provider's models and merge them into the catalogue before handing off to
    /// the model picker. A blank key is allowed only for providers that don't
    /// require one (`requiresApiKey() == false`); all current ones do.
    fn submitProviderSetup(self: *App, provider: config_mod.Provider) !void {
        if (self.turn.isActive()) return error.InFlightTurn;
        const key = std.mem.trim(u8, self.provider_key_input.items, " \t\r\n");

        // A required key cannot be blank — keep the form open so the user can type.
        if (key.len == 0 and provider.requiresApiKey()) return;

        const home = self.runtime.?.home_dir;
        if (key.len > 0) {
            try codex.saveProviderApiKey(self.gpa, self.io, home, provider.label(), key);
        } else {
            // Anonymous free tier: drop any stale key so we connect without one.
            codex.removeProviderApiKey(self.gpa, self.io, home, provider.label()) catch {};
        }
        try self.refreshProviderApiKeys();

        // With no key, connect via the provider's anonymous sentinel (e.g.
        // OpenCode Zen's `public`, which the gateway limits to free models).
        const connect_key = if (key.len > 0) key else (provider.anonymousApiKey() orelse key);
        // `connect_key` may alias the input buffer — fetch (which dupes it) first.
        try self.startProviderModelLoad(provider, connect_key);

        self.provider_picker.stage = .list;
        self.provider_picker.form_provider = null;
        self.provider_key_input.clearRetainingCapacity();

        self.mode = .model_picker;
        self.models.model_column = .model;
        self.models.model_selection = 0;
        self.models.model_scope = self.defaultModelScope();
        self.models.reasoning_snapshot.clearRetainingCapacity();
        self.models.model_selection_snapshot = 0;
        self.clearInput();
        self.clearPaletteInput();
    }

    /// Incremental, merge-on-arrival load of a single provider's `/models`.
    fn startProviderModelLoad(self: *App, provider: config_mod.Provider, key: []const u8) !void {
        self.cancelModelLoad();
        if (self.models.model_load_error) |message| {
            self.gpa.free(message);
            self.models.model_load_error = null;
        }

        const base_url_default = provider.defaultBaseUrl() orelse return error.NotConnected;

        const job = try self.gpa.create(model_loader.Job);
        errdefer self.gpa.destroy(job);

        const configured = try self.gpa.alloc(model_loader.Configured, 1);
        errdefer self.gpa.free(configured);
        const base_url = try self.gpa.dupe(u8, base_url_default);
        errdefer self.gpa.free(base_url);
        const api_key = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(api_key);
        configured[0] = .{ .provider = provider, .base_url = base_url, .api_key = api_key };

        job.* = .{
            .gpa = self.gpa,
            .io = self.io,
            .catalog = .single_provider,
            .configured = configured,
            .include_locals = false,
            .codex_signed_in = self.isCodexSignedIn(),
            .done = &self.models.model_load_done,
        };

        self.models.model_load_merge = true;
        self.models.model_load_done.store(false, .release);
        self.models.model_load_future = try self.io.concurrent(model_loader.run, .{job});
    }

    fn applySelectedModel(self: *App) !void {
        if (self.turn.state == .interrupting) self.discardAbandonedTurn();
        if (self.turn.isActive()) return error.InFlightTurn;
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
                    try self.persistModelSelection(.openai, model.id, effort, self.models.model_scope);
                } else {
                    return error.NotConnected;
                }
            },
            .openai_compatible => |provider| {
                const base_url = self.compatibleBaseUrl(provider) orelse return error.NotConnected;
                const api_key = self.compatibleApiKey(provider);
                if (api_key.len == 0 and provider.requiresApiKey()) return error.NotConnected;
                try self.attachOpenAiCompatibleClient(base_url, api_key, model.id, effort);
                try self.persistModelSelection(provider, model.id, effort, self.models.model_scope);
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
            try self.updateCachedProviderConnection(provider);
        } else {
            self.gpa.free(new_id);
        }
    }

    fn updateCachedProviderConnection(self: *App, provider: config_mod.Provider) !void {
        if (provider == .openai_compatible) return;
        if (provider.defaultBaseUrl()) |base_url| try self.replaceCachedBaseUrl(base_url);
        self.clearCachedApiKey();
    }

    fn replaceCachedBaseUrl(self: *App, base_url: []const u8) !void {
        const owned = try self.gpa.dupe(u8, base_url);
        errdefer self.gpa.free(owned);
        if (self.cached_config.base_url) |old| self.gpa.free(old);
        self.cached_config.base_url = owned;
    }

    fn clearCachedApiKey(self: *App) void {
        if (self.cached_config.api_key) |old| self.gpa.free(old);
        self.cached_config.api_key = null;
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
        self.models.resetReasoning();
    }

    fn activeModelId(self: *const App) ?[]const u8 {
        const status = tui_status.modelStatus(self.runtime, self.cached_config) orelse return null;
        return status.model;
    }

    fn loadCodexStaticCatalog(self: *App) !void {
        const models = try codex.loadStaticModels(self.gpa);
        defer self.gpa.free(models);
        for (models) |*model| {
            try self.models.append(self.gpa, model.*, .openai_codex);
            model.* = .{ .id = &.{}, .label = &.{} };
        }
        for (models) |*model| {
            if (model.id.len == 0) continue;
            model.deinit(self.gpa);
        }
    }

    fn loadCompatibleCatalog(self: *App) !void {
        if (!self.models.compatible_models_fetched) try self.fetchCompatibleCatalog();
        const provider = tui_provider.compatibleProviderFromBaseUrl(self.cached_config.base_url.?);
        for (self.models.compatible_models.items) |model| {
            const id = try self.gpa.dupe(u8, model.id);
            errdefer self.gpa.free(id);
            const label = try self.gpa.dupe(u8, model.label);
            errdefer self.gpa.free(label);
            try self.models.append(self.gpa, .{ .id = id, .label = label }, .{ .openai_compatible = provider });
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
            try self.models.append(self.gpa, .{ .id = id, .label = label }, .{ .openai_compatible = provider });
        }
    }

    fn fetchCompatibleCatalog(self: *App) !void {
        std.debug.assert(!self.models.compatible_models_fetched);
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
            try self.models.compatible_models.append(self.gpa, .{ .id = id, .label = label });
        }
        self.models.compatible_models_fetched = true;
    }

    fn compatibleModelsCacheClear(self: *App) void {
        for (self.models.compatible_models.items) |*model| model.deinit(self.gpa);
        self.models.compatible_models.clearRetainingCapacity();
        self.models.compatible_models_fetched = false;
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
            const url_provider = tui_provider.compatibleProviderFromBaseUrl(base_url);
            if (url_provider == provider) return base_url;
        }
        return provider.defaultBaseUrl();
    }

    /// Resolve the API key for an OpenAI-compatible provider: a key stored in
    /// auth.json wins, then the env/config key, then the provider's anonymous
    /// sentinel (e.g. OpenCode Zen's `public`), then the local-daemon sentinel.
    fn compatibleApiKey(self: *const App, provider: config_mod.Provider) []const u8 {
        if (self.provider_api_keys.get(provider.label())) |key| return key;
        if (self.cached_config.api_key) |key| return key;
        if (provider.anonymousApiKey()) |anon| return anon;
        return providerLocalApiKey(provider);
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
        if (self.models.model_selection >= self.models.len()) return 0;
        return self.models.entries.items[self.models.model_selection].reasoning_index;
    }

    fn selectedReasoningEffort(self: *const App) ai.ReasoningEffort {
        return reasoningOptions()[self.selectedReasoningIndex()].effort;
    }

    fn cycleModelScope(self: *App) void {
        self.models.model_scope = switch (self.models.model_scope) {
            .global => .project,
            .project => .session,
            .session => .global,
        };
    }

    fn cycleSelectedReasoning(self: *App) !void {
        if (self.models.model_selection >= self.models.len()) return;
        const entry = &self.models.entries.items[self.models.model_selection];
        entry.reasoning_index = nextIndex(entry.reasoning_index, @intCast(reasoningOptions().len));
    }

    fn selectedCodexModel(self: *App) ?codex.Model {
        if (self.models.model_selection >= self.models.len()) return null;
        const active_storage_idx = self.models.activeStorageIdx(self.activeModelId());
        const idx = model_picker.displayToStorage(active_storage_idx, self.models.model_selection);
        return self.models.entries.items[idx].model;
    }

    fn modelDisplayMatches(self: *const App, display_pos: u32, filter: []const u8) bool {
        const count: u32 = self.models.len();
        if (display_pos >= count) return false;
        const active = self.models.activeStorageIdx(self.activeModelId());
        const storage = model_picker.displayToStorage(active, display_pos);
        if (storage >= count) return false;
        return model_picker.matches(self.models.entries.items[storage].model, filter);
    }

    fn firstMatchingModelDisplay(self: *const App, filter: []const u8) ?u32 {
        const count: u32 = self.models.len();
        var d: u32 = 0;
        while (d < count) : (d += 1) {
            if (self.modelDisplayMatches(d, filter)) return d;
        }
        return null;
    }

    fn stepModelSelection(self: *App, forward: bool) !void {
        const count: u32 = self.models.len();
        if (count == 0) return;
        const filter = try self.peekPaletteInput();
        defer self.gpa.free(filter);
        var next = self.models.model_selection;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            next = if (forward) nextIndex(next, count) else previousIndex(next, count);
            if (self.modelDisplayMatches(next, filter)) {
                self.models.model_selection = next;
                return;
            }
        }
    }

    fn selectedModelSource(self: *const App) ?ModelSource {
        if (self.models.model_selection >= self.models.len()) return null;
        const active_storage_idx = self.models.activeStorageIdx(self.activeModelId());
        const idx = model_picker.displayToStorage(active_storage_idx, self.models.model_selection);
        if (idx >= self.models.len()) return null;
        return self.models.entries.items[idx].source;
    }

    fn codexModelsClear(self: *App) void {
        self.models.clearEntries(self.gpa);
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
        if (self.resume_global) std.mem.sort(
            session_mod.SessionSummary,
            self.resume_summaries.items,
            self.resume_summaries.items,
            resumeSummaryLessThan,
        );
        if (self.resume_selection >= try self.visibleResumeCount()) self.resume_selection = 0;
        self.syncResumeListCursor();
    }

    fn selectedResumeSummary(self: *App) !?*session_mod.SessionSummary {
        const filter = try self.peekPaletteInput();
        defer self.gpa.free(filter);
        return @constCast(resume_picker.selectedSummary(self.resume_summaries.items, filter, self.resume_folded_projects.items, self.resume_selection, self.resume_global));
    }

    fn visibleResumeCount(self: *App) !u32 {
        const filter = try self.peekPaletteInput();
        defer self.gpa.free(filter);
        return resume_picker.visibleCount(self.resume_summaries.items, filter, self.resume_folded_projects.items, self.resume_global);
    }

    fn toggleSelectedResumeProject(self: *App) !void {
        const filter = try self.peekPaletteInput();
        defer self.gpa.free(filter);
        const cwd = resume_picker.selectedProject(self.resume_summaries.items, filter, self.resume_folded_projects.items, self.resume_selection) orelse return;
        if (self.resumeFoldIndex(cwd)) |index| {
            self.gpa.free(self.resume_folded_projects.items[index]);
            _ = self.resume_folded_projects.orderedRemove(index);
        } else {
            try self.resume_folded_projects.append(self.gpa, try self.gpa.dupe(u8, cwd));
        }
        if (self.resume_selection >= try self.visibleResumeCount()) self.resume_selection = 0;
        self.syncResumeListCursor();
    }

    fn resumeFoldIndex(self: *const App, cwd: []const u8) ?usize {
        for (self.resume_folded_projects.items, 0..) |folded, index| {
            if (std.mem.eql(u8, folded, cwd)) return index;
        }
        return null;
    }

    fn resumeClearFolds(self: *App) void {
        for (self.resume_folded_projects.items) |folded| self.gpa.free(folded);
        self.resume_folded_projects.clearRetainingCapacity();
    }

    fn resumeClear(self: *App) void {
        for (self.resume_summaries.items) |*summary| summary.deinit(self.gpa);
        self.resume_summaries.clearRetainingCapacity();
    }

    fn syncResumeListCursor(self: *App) void {
        self.resume_list.cursor = self.resume_selection;
        self.resume_list.ensureScroll();
    }

    fn reloadTreeNodes(self: *App) !void {
        const writer = &self.runtime.?.session_writer;
        const records = try writer.entries(self.gpa);
        defer {
            for (records) |*record| record.deinit(self.gpa);
            self.gpa.free(records);
        }
        try self.tree_state.load(records, writer.leaf());
    }

    /// Switch the session leaf to `entry_id`, then rehydrate the agent's
    /// conversation and the display thread from the new branch. Refused mid-turn.
    fn navigateToEntry(self: *App, entry_id: []const u8) !void {
        if (self.turn.isActive()) return error.InFlightTurn;
        try self.runtime.?.session_writer.navigate(entry_id);
        try self.runtime.?.reloadMessages();
        try self.rebuildThreadFromAgent();
    }

    fn clearInput(self: *App) void {
        self.input.clearRetainingCapacity();
    }

    /// Recompute the mention popup from the text before the cursor. Called on
    /// every edit while in normal mode. `@` searches files; `$` searches skills.
    fn updateAtSearch(self: *App) !void {
        const before = self.input.buf.firstHalf();
        if (at_mention.activeQuery(before)) |active| {
            try self.setMentionSearch(.file, active.query);
            return;
        }
        if (skill_mod.activeQuery(before)) |active| {
            try self.setMentionSearch(.skill, active.query);
            return;
        }
        self.closeAtSearch();
    }

    fn setMentionSearch(self: *App, kind: MentionSearchKind, query: []const u8) !void {
        if (kind == .file) self.startAtSearchBackend();
        self.at_active = true;
        if (kind != self.at_kind or !std.mem.eql(u8, query, self.at_query)) {
            const owned: []u8 = if (query.len > 0) try self.gpa.dupe(u8, query) else "";
            if (self.at_query.len > 0) self.gpa.free(self.at_query);
            self.at_kind = kind;
            self.at_query = owned;
            self.at_selection = 0;
            try self.refreshAtResults();
        }
    }

    fn startAtSearchBackend(self: *App) void {
        const cwd = if (self.runtime) |runtime| runtime.cwd else ".";
        search_mod.start(std.heap.smp_allocator, self.io, cwd);
    }

    fn refreshAtResults(self: *App) !void {
        self.clearAtResults();
        self.at_indexing = false;
        switch (self.at_kind) {
            .file => try self.refreshFileResults(),
            .skill => try self.refreshSkillResults(),
        }
    }

    fn refreshFileResults(self: *App) !void {
        if (self.at_query.len == 0) return;
        var result = (try search_mod.runIfReady(self.gpa, self.io, .{
            .op = .find,
            .query = self.at_query,
        })) orelse {
            self.at_indexing = true;
            return;
        };
        defer result.deinit(self.gpa);
        try self.parseAtResults(result.stdout);
    }

    fn refreshSkillResults(self: *App) !void {
        const runtime = self.runtime orelse return;
        const names = try skill_mod.filterNames(self.gpa, runtime.skills, self.at_query);
        errdefer {
            for (names) |name| self.gpa.free(name);
            self.gpa.free(names);
        }
        for (names) |name| try self.at_results.append(self.gpa, name);
        self.gpa.free(names);
        if (self.at_selection >= self.at_results.items.len) self.at_selection = 0;
    }

    fn parseAtResults(self: *App, stdout: []const u8) !void {
        const max_results = 50;
        var iter = std.mem.splitScalar(u8, stdout, '\n');
        while (iter.next()) |line| {
            if (self.at_results.items.len >= max_results) break;
            if (line.len == 0) continue;
            if (isSearchFooter(line)) continue;
            if (line[line.len - 1] == '/') continue; // directory: `@` loads files
            const owned = try self.gpa.dupe(u8, line);
            errdefer self.gpa.free(owned);
            try self.at_results.append(self.gpa, owned);
        }
        if (self.at_selection >= self.at_results.items.len) self.at_selection = 0;
    }

    /// Replace the active mention token with the selected path or skill name.
    fn acceptAtSelection(self: *App) !void {
        if (self.at_selection >= self.at_results.items.len) return;
        const before = self.input.buf.firstHalf();
        const active_start = switch (self.at_kind) {
            .file => if (at_mention.activeQuery(before)) |active| active.start else return,
            .skill => if (skill_mod.activeQuery(before)) |active| active.start else return,
        };
        const value = self.at_results.items[self.at_selection];
        const sigil: u8 = if (self.at_kind == .file) '@' else '$';
        const insert = try std.fmt.allocPrint(self.gpa, "{c}{s} ", .{ sigil, value });
        defer self.gpa.free(insert);
        self.input.buf.growGapLeft(before.len - active_start);
        try self.input.insertSliceAtCursor(insert);
        self.closeAtSearch();
    }

    fn clearAtResults(self: *App) void {
        for (self.at_results.items) |path| self.gpa.free(path);
        self.at_results.clearRetainingCapacity();
    }

    fn closeAtSearch(self: *App) void {
        self.at_active = false;
        self.at_indexing = false;
        self.at_selection = 0;
        self.at_kind = .file;
        self.clearAtResults();
        if (self.at_query.len > 0) {
            self.gpa.free(self.at_query);
            self.at_query = "";
        }
    }

    /// Stash a prompt submitted while a turn is already running. Returns false
    /// — no new turn starts; the message rides the steering queue instead.
    fn enqueueSubmit(self: *App) !bool {
        const prompt = try self.input.buf.dupe();
        errdefer self.gpa.free(prompt);
        if (prompt.len == 0) {
            self.gpa.free(prompt);
            return false;
        }
        // Enqueue the raw text; the worker expands `@`-mentions when it drains
        // the queue, keeping file I/O off the UI thread.
        self.agent.enqueueUser(prompt) catch |err| switch (err) {
            error.QueueFull => {
                self.gpa.free(prompt);
                try self.appendMessageQueueFullNotice();
                return false;
            },
            else => return err,
        };
        try self.queued_user_messages.append(self.gpa, prompt);
        self.clearInput();
        return false;
    }

    fn appendMessageQueueFullNotice(self: *App) !void {
        // The spinner is derived from the turn view and drawn at the tail,
        // so appending below it needs no remove/re-append dance.
        _ = try self.thread.append(self.gpa, .notice, "notice", "MessageQueueFull");
    }

    fn appendSkillInvocationsToThread(self: *App, prompt: []const u8) !void {
        const runtime = self.runtime orelse return;
        const names = try skill_mod.collectInvocations(self.gpa, runtime.skills, prompt);
        defer self.gpa.free(names);
        for (names) |name| {
            const title = try std.fmt.allocPrint(self.gpa, "[SKILL] {s}", .{name});
            defer self.gpa.free(title);
            _ = try self.thread.append(self.gpa, .skill, title, "");
        }
    }

    fn flushQueuedUserMessagesToThread(self: *App, count: u32) !void {
        const flush_count: usize = @min(count, self.queued_user_messages.items.len);
        for (self.queued_user_messages.items[0..flush_count]) |message| {
            _ = try self.thread.append(self.gpa, .user, "you", message);
            try self.appendSkillInvocationsToThread(message);
            self.gpa.free(message);
        }
        std.mem.copyForwards([]const u8, self.queued_user_messages.items[0 .. self.queued_user_messages.items.len - flush_count], self.queued_user_messages.items[flush_count..]);
        self.queued_user_messages.shrinkRetainingCapacity(self.queued_user_messages.items.len - flush_count);
    }

    fn clearQueuedUserMessages(self: *App) void {
        for (self.queued_user_messages.items) |message| self.gpa.free(message);
        self.queued_user_messages.clearRetainingCapacity();
    }

    fn clearPaletteInput(self: *App) void {
        self.palette_input.clearRetainingCapacity();
    }

    fn peekPaletteInput(self: *App) ![]u8 {
        const left = self.palette_input.buf.firstHalf();
        const right = self.palette_input.buf.secondHalf();
        const out = try self.gpa.alloc(u8, left.len + right.len);
        @memcpy(out[0..left.len], left);
        @memcpy(out[left.len..], right);
        return out;
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
        if (self.turn.isActive()) return error.InFlightTurn;
        const runtime = try self.createRuntime(null);
        errdefer {
            runtime.deinit();
            self.gpa.destroy(runtime);
        }
        try self.installRuntime(runtime);
        try self.clearConversation();
    }

    fn switchToSession(self: *App, session_id: []const u8) !void {
        if (self.turn.isActive()) return error.InFlightTurn;
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
                current.base_system_prompt,
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
                current.base_system_prompt,
                self.cached_config,
                diagnostics,
            );
        }
        return runtime;
    }

    fn installRuntime(self: *App, runtime: *runtime_mod.AgentRuntime) !void {
        if (self.turn.isActive()) return error.InFlightTurn;
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
                const index = try self.thread.append(self.gpa, .tool, title, text);
                self.thread.messages.items[index].failed = message.tool_failed;
            }
        }
        if (self.thread.messages.items.len > 0) self.thread.selected = @intCast(self.thread.messages.items.len - 1);
    }

    fn resumedToolTitle(self: *App, message: ai.ChatMessage) ![]u8 {
        if (message.tool_display_label) |label| return thread_mod.toolTitle(self.gpa, label);
        const id = message.call_id orelse return thread_mod.toolTitle(self.gpa, "tool");
        for (self.agent.messages.items) |candidate| {
            for (candidate.content) |block| {
                if (block != .tool_call) continue;
                if (!std.mem.eql(u8, block.tool_call.call_id, id)) continue;
                var display = try agent_mod.formatToolDisplay(self.gpa, block.tool_call.name, block.tool_call.arguments);
                defer display.deinit(self.gpa);
                return thread_mod.toolTitle(self.gpa, display.label);
            }
        }
        return thread_mod.toolTitle(self.gpa, id);
    }

    fn peekInput(self: *App) ![]u8 {
        const left = self.input.buf.firstHalf();
        const right = self.input.buf.secondHalf();
        const out = try self.gpa.alloc(u8, left.len + right.len);
        @memcpy(out[0..left.len], left);
        @memcpy(out[left.len..], right);
        return out;
    }

    fn inputTextRows(self: *App, ctx: vxfw.DrawContext, width: u16) !u16 {
        const text = try self.peekInput();
        defer self.gpa.free(text);
        return wrappedTextRows(ctx, text, width);
    }

    fn insertInputNewline(self: *App) !void {
        try self.input.insertSliceAtCursor("\n");
        try self.updateAtSearch();
    }

    fn moveInputCursorVertical(self: *App, move: VerticalMove) !bool {
        const text = try self.peekInput();
        defer self.gpa.free(text);
        const cur = self.input.buf.firstHalf().len;
        const cur_line_start = lineStartBefore(text, cur);
        const col = cellColumn(text[cur_line_start..cur]);

        const target = switch (move) {
            .up => blk: {
                if (cur_line_start == 0) return false;
                const prev_start = lineStartBefore(text, cur_line_start - 1);
                break :blk byteAtColumn(text, prev_start, cur_line_start - 1, col);
            },
            .down => blk: {
                const nl = std.mem.indexOfScalarPos(u8, text, cur, '\n') orelse return false;
                const next_start = nl + 1;
                const next_end = std.mem.indexOfScalarPos(u8, text, next_start, '\n') orelse text.len;
                break :blk byteAtColumn(text, next_start, next_end, col);
            },
        };

        if (target < cur) {
            self.input.buf.moveGapLeft(cur - target);
        } else if (target > cur) {
            self.input.buf.moveGapRight(target - cur);
        }
        return true;
    }

    fn selectionIsLastMessage(self: *const App) bool {
        const selected = self.thread.selected orelse return false;
        if (self.thread.messages.items.len == 0) return false;
        return selected == self.thread.messages.items.len - 1;
    }

    fn diffCountsVisible(self: *const App) bool {
        if (self.diff_counts.additions > 0) return true;
        return self.diff_counts.deletions > 0;
    }

    fn refreshDiffCounts(self: *App) !bool {
        const cwd = if (self.runtime) |runtime| runtime.cwd else ".";
        var result = try bash_mod.runWithOptions(self.gpa, self.io, .{
            .cwd = cwd,
            .command = diffCountCommand,
            .timeout = bash_mod.timeoutFromSeconds(1),
        });
        defer result.deinit(self.gpa);
        if (result.code != 0) return false;

        return self.installDiffCounts(parseDiffCounts(result.stdout));
    }

    fn installDiffCounts(self: *App, next: DiffCounts) bool {
        if (next.additions == self.diff_counts.additions) {
            if (next.deletions == self.diff_counts.deletions) return false;
        }
        self.diff_counts = next;
        return true;
    }

    fn scheduleDiffRefresh(self: *App) !void {
        if (self.diff_refresh_future != null) {
            self.diff_refresh_again = true;
            return;
        }

        const cwd_source = if (self.runtime) |runtime| runtime.cwd else ".";
        const cwd = try self.gpa.dupe(u8, cwd_source);
        errdefer self.gpa.free(cwd);

        const job = try self.gpa.create(DiffRefreshJob);
        errdefer self.gpa.destroy(job);
        job.* = .{
            .gpa = self.gpa,
            .io = self.io,
            .cwd = cwd,
            .done = &self.diff_refresh_done,
        };
        errdefer job.deinit();

        self.diff_refresh_again = false;
        self.diff_refresh_done.store(false, .release);
        self.diff_refresh_future = try self.io.concurrent(runDiffRefresh, .{job});
    }

    fn cancelDiffRefresh(self: *App) void {
        if (self.diff_refresh_future) |*future| {
            var outcome = future.cancel(self.io);
            outcome.deinit();
            self.diff_refresh_future = null;
        }
        self.diff_refresh_again = false;
        self.diff_refresh_done.store(false, .release);
    }

    fn drainDiffRefresh(self: *App) !bool {
        if (self.diff_refresh_future == null) return false;
        if (!self.diff_refresh_done.load(.acquire)) return false;

        var outcome = self.diff_refresh_future.?.await(self.io);
        self.diff_refresh_future = null;
        self.diff_refresh_done.store(false, .release);
        defer outcome.deinit();

        var visible_change = false;
        switch (outcome) {
            .ready => |counts| visible_change = self.installDiffCounts(counts),
            .failed => {},
        }
        if (self.diff_refresh_again) try self.scheduleDiffRefresh();
        return visible_change;
    }

    fn jumpThreadToBottom(self: *App) void {
        self.block_nav = false;
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

        const selected_before = self.thread.selected;
        switch (direction) {
            .previous => self.thread.moveSelection(.previous),
            .next => self.thread.moveSelection(.next),
        }
        if (self.thread.selected != selected_before) self.anchorSelectedLongMessage(direction);
        return false;
    }

    fn scrollSelectedLongMessage(self: *App, direction: ThreadNavigation) bool {
        const selected = self.thread.selected orelse return false;
        if (selected >= self.thread.messages.items.len) return false;
        const rows = messageRowsCached(&self.thread.messages.items[selected], ConversationLayout.contentWidth(self.thread_view_width));
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
        const rows = messageRowsCached(&self.thread.messages.items[selected], ConversationLayout.contentWidth(self.thread_view_width));
        return rows > self.thread_view_height;
    }

    /// True when the selected message is taller than the viewport and still has
    /// rows hidden below the current scroll offset (mirrors the `.next` branch of
    /// `scrollSelectedLongMessage`).
    fn selectedMessageCanScrollDown(self: *const App) bool {
        const selected = self.thread.selected orelse return false;
        if (selected >= self.thread.messages.items.len) return false;
        const rows = messageRowsCached(&self.thread.messages.items[selected], ConversationLayout.contentWidth(self.thread_view_width));
        const height = self.thread_view_height;
        if (rows <= height) return false;
        return self.selectedMessageOffset(selected) < rows - height;
    }

    fn anchorSelectedLongMessage(self: *App, direction: ThreadNavigation) void {
        const selected = self.thread.selected orelse return;
        if (selected >= self.thread.messages.items.len) return;
        const rows = messageRowsCached(&self.thread.messages.items[selected], ConversationLayout.contentWidth(self.thread_view_width));
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

fn resumeSummaryLessThan(summaries: []const session_mod.SessionSummary, left: session_mod.SessionSummary, right: session_mod.SessionSummary) bool {
    if (std.mem.eql(u8, left.cwd, right.cwd)) return left.updated_at_ms > right.updated_at_ms;

    const left_project_updated_at_ms = resumeProjectUpdatedAtMax(summaries, left.cwd);
    const right_project_updated_at_ms = resumeProjectUpdatedAtMax(summaries, right.cwd);
    if (left_project_updated_at_ms != right_project_updated_at_ms) {
        return left_project_updated_at_ms > right_project_updated_at_ms;
    }

    return std.mem.lessThan(u8, left.cwd, right.cwd);
}

fn resumeProjectUpdatedAtMax(summaries: []const session_mod.SessionSummary, cwd: []const u8) i64 {
    var updated_at_ms: i64 = std.math.minInt(i64);
    for (summaries) |summary| {
        if (!std.mem.eql(u8, summary.cwd, cwd)) continue;
        updated_at_ms = @max(updated_at_ms, summary.updated_at_ms);
    }
    return updated_at_ms;
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

fn rootLayout(max_height: u16, panel_visible: bool, input_text_rows: u16) RootLayout {
    const desired: u16 = 3 + input_text_rows;
    const max_allowed: u16 = @max(@as(u16, 6), max_height -| 3);
    const input_height: u16 = @min(max_height, @min(desired, max_allowed));
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
    var fw_app = try vxfw.App.init(init.io, gpa, init.environ_map, &tty_buffer);
    defer fw_app.deinit();

    var app = App.initRuntime(init.io, gpa, runtime, config);
    app.bindInputCallbacks();
    defer app.deinit();

    // Load stored catalogue-provider keys from auth.json up front so the first
    // model-catalogue build includes every connected provider. Without this the
    // keys only loaded when the provider picker was opened, so a cold model
    // picker silently skipped (and then cached) every keyed provider.
    app.refreshProviderApiKeys() catch {};

    // The logo message is a marker: the black-hole animation renders its frames
    // directly (see tui/blackhole.zig), so the body is intentionally empty.
    _ = try app.thread.append(gpa, .logo, "logo", "");

    app.git_label = loadGitLabel(gpa, init.io, runtime.cwd) catch "";
    _ = app.refreshDiffCounts() catch false;

    var root: RootWidget = .{ .app = &app };
    try fw_app.run(root.widget(), .{});
}

const diffCountCommand =
    \\if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    \\  git diff --numstat HEAD -- 2>/dev/null
    \\  git ls-files --others --exclude-standard -z 2>/dev/null | while IFS= read -r -d '' file; do
    \\    lines=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    \\    if [ -n "$lines" ]; then printf '%s\t0\t%s\n' "$lines" "$file"; fi
    \\  done
    \\fi
;

fn parseDiffCounts(output: []const u8) DiffCounts {
    var counts: DiffCounts = .{};
    var line_start: usize = 0;
    while (line_start <= output.len) {
        const line_end = std.mem.findScalarPos(u8, output, line_start, '\n') orelse output.len;
        parseDiffCountLine(&counts, output[line_start..line_end]);
        if (line_end == output.len) break;
        line_start = line_end + 1;
    }
    return counts;
}

fn parseDiffCountLine(counts: *DiffCounts, line: []const u8) void {
    if (line.len == 0) return;
    const first_tab = std.mem.indexOfScalar(u8, line, '\t') orelse return;
    const rest = line[first_tab + 1 ..];
    const second_tab = std.mem.indexOfScalar(u8, rest, '\t') orelse return;
    counts.additions = saturatingAdd(counts.additions, parseNumstatField(line[0..first_tab]));
    counts.deletions = saturatingAdd(counts.deletions, parseNumstatField(rest[0..second_tab]));
}

fn parseNumstatField(field: []const u8) u32 {
    if (field.len == 0) return 0;
    if (std.mem.eql(u8, field, "-")) return 0;
    const value = std.fmt.parseUnsigned(u64, field, 10) catch return 0;
    return @intCast(@min(value, std.math.maxInt(u32)));
}

fn saturatingAdd(a: u32, b: u32) u32 {
    const sum: u64 = @as(u64, a) + @as(u64, b);
    return @intCast(@min(sum, std.math.maxInt(u32)));
}

fn loadGitLabel(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]const u8 {
    const command =
        \\root=$(git rev-parse --show-toplevel 2>/dev/null)
        \\if [ -n "$root" ]; then repo=$(basename "$root"); else repo=$(basename "$PWD"); fi
        \\branch=$(git branch --show-current 2>/dev/null)
        \\if [ -z "$branch" ]; then branch=$(git rev-parse --short HEAD 2>/dev/null); fi
        \\if [ -n "$branch" ]; then printf '%s\t%s' "$repo" "$branch"; else printf '%s' "$repo"; fi
    ;
    var result = try bash_mod.runWithOptions(gpa, io, .{
        .cwd = cwd,
        .command = command,
        .timeout = bash_mod.timeoutFromSeconds(2),
    });
    defer result.deinit(gpa);
    if (result.code != 0) return "";
    const out = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (out.len == 0) return "";
    if (std.mem.indexOfScalar(u8, out, '\t')) |tab| {
        return std.fmt.allocPrint(gpa, "{s} ⌥ {s}", .{ out[0..tab], out[tab + 1 ..] });
    }
    return gpa.dupe(u8, out);
}

const RootWidget = struct {
    app: *App,
    spinner_tick_accum: u32 = 0,
    blackhole_tick_accum: u32 = 0,
    diff_tick_accum: u32 = 0,
    diff_refresh_pending: bool = false,

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
                try self.ensureTick(ctx);
                ctx.consumeAndRedraw();
            },
            .mouse => |mouse| {
                // Scrolling may bring the logo back into view; the tick stops
                // itself again on the next frame if it didn't.
                try self.ensureTick(ctx);
                if (mouse.button == .wheel_up) self.app.thread_auto_scroll = false;
                if (mouse.button == .wheel_down) self.app.updateMouseAutoScroll();
            },
            .key_press => |key| {
                try self.ensureTick(ctx);
                if (key.matches(vaxis.Key.escape, .{})) {
                    if (self.app.at_active) {
                        self.app.closeAtSearch();
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (try self.app.cancelMode()) {
                        try self.syncFocus(ctx);
                        ctx.consumeAndRedraw();
                        return;
                    }
                    if (self.app.turn.state == .active) {
                        try self.app.handleInterrupt();
                        ctx.consumeAndRedraw();
                        return;
                    }
                    // No in-flight turn and no overlay to close — swallow the
                    // key so the user doesn't accidentally exit the TUI.
                    self.app.pending_quit_at = null;
                    ctx.consume_event = true;
                    return;
                }
                if (key.matches('c', .{ .ctrl = true })) {
                    if (self.app.mode == .normal and self.app.input.buf.realLength() > 0) {
                        self.app.clearInput();
                        self.app.closeAtSearch();
                        self.app.block_nav = false;
                        self.app.pending_quit_at = null;
                        ctx.consumeAndRedraw();
                        return;
                    }
                    const now = std.Io.Timestamp.now(self.app.io, .awake);
                    if (self.app.pending_quit_at) |first_press| {
                        const elapsed_ns = first_press.durationTo(now).nanoseconds;
                        const threshold_ns: i128 = @as(i128, App.ctrl_c_double_press_ms) * std.time.ns_per_ms;
                        if (elapsed_ns >= 0 and elapsed_ns <= threshold_ns) {
                            ctx.quit = true;
                            ctx.consume_event = true;
                            return;
                        }
                    }
                    self.app.pending_quit_at = now;
                    ctx.consume_event = true;
                    return;
                }
                // Any other key cancels the pending-quit prompt.
                self.app.pending_quit_at = null;
                if (shouldOpenCommandMenuForSlash(self.app, key)) {
                    try self.app.openCommandMenu();
                    try self.syncFocus(ctx);
                    ctx.consumeAndRedraw();
                    return;
                }
                if (self.app.mode == .normal and key.matches(vaxis.Key.enter, .{ .shift = true })) {
                    try self.app.insertInputNewline();
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.app.at_active and self.app.at_results.items.len > 0) {
                        try self.app.acceptAtSelection();
                        ctx.consumeAndRedraw();
                        return;
                    }
                    try self.submit(ctx);
                    return;
                }
                // Arrow keys are owned by the input until the cursor leaves the
                // top of it. While the input owns them (`!block_nav`) up/down
                // move the cursor between lines; going up past the first line
                // hands control to block navigation, and down stays trapped in
                // the input. Once in block navigation the arrows fall through to
                // `handleThreadKey`, which walks blocks and re-enters the input
                // when you press down past the last block. The @-mention popup
                // keeps the arrows for itself.
                if (self.app.mode == .normal and !self.app.at_active) {
                    if (key.matches(vaxis.Key.up, .{})) {
                        if (!self.app.block_nav) {
                            if (try self.app.moveInputCursorVertical(.up)) {
                                ctx.consumeAndRedraw();
                                return;
                            }
                            // Top line: leave the input and start walking blocks.
                            self.app.block_nav = true;
                        }
                    } else if (key.matches(vaxis.Key.down, .{})) {
                        if (self.app.block_nav) {
                            if (self.app.thread.selected == null) {
                                if (try self.app.moveInputCursorVertical(.down)) {
                                    self.app.block_nav = false;
                                    ctx.consumeAndRedraw();
                                    return;
                                }
                            }
                        } else {
                            _ = try self.app.moveInputCursorVertical(.down);
                            ctx.consumeAndRedraw();
                            return;
                        }
                    }
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
    const diff_tick_threshold_ms: u32 = 300;

    fn handleTick(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        var visible_change = try self.drainAgentEvents(ctx);
        if (try self.app.drainModelLoad()) visible_change = true;
        if (try self.app.drainDiffRefresh()) visible_change = true;

        if (self.app.turn_view.awaitingOutput() or self.app.thread.hasRunningTool()) {
            self.spinner_tick_accum += drain_tick_ms;
            if (self.spinner_tick_accum >= spinner_tick_threshold_ms) {
                self.spinner_tick_accum = 0;
                self.app.advanceLoadingFrame();
                visible_change = true;
            }
        } else {
            self.spinner_tick_accum = 0;
        }

        if (self.diff_refresh_pending) {
            self.diff_tick_accum += drain_tick_ms;
            if (self.diff_tick_accum >= diff_tick_threshold_ms) {
                self.diff_tick_accum = 0;
                self.diff_refresh_pending = false;
                try self.app.scheduleDiffRefresh();
            }
        } else {
            self.diff_tick_accum = 0;
        }

        if (self.app.blackhole_visible) {
            // Carry the remainder so the average interval tracks ~24 fps even
            // though the host tick (30 ms) is coarser than the frame interval.
            self.blackhole_tick_accum += drain_tick_ms;
            while (self.blackhole_tick_accum >= blackhole.frame_interval_ms) {
                self.blackhole_tick_accum -= blackhole.frame_interval_ms;
                self.app.advanceBlackholeFrame();
                visible_change = true;
            }
        } else {
            self.blackhole_tick_accum = 0;
        }

        const model_loading = self.app.models.model_load_future != null;
        const diff_loading = self.app.diff_refresh_future != null;
        // Keep ticking while a turn is active OR interrupting, so the worker's
        // remaining events (and its terminal `turn_finished`) get drained.
        const should_tick = self.app.turn.state != .idle or
            model_loading or
            diff_loading or
            self.app.blackhole_visible or
            self.diff_refresh_pending;
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

    // Schedule the shared animation/drain tick if one isn't already pending.
    // Drives the spinner, agent-event draining, and the black-hole intro.
    fn ensureTick(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        if (self.app.loading_tick_active) return;
        self.app.loading_tick_active = true;
        self.spinner_tick_accum = 0;
        try ctx.tick(drain_tick_ms, self.widget());
    }

    fn submit(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        if (try self.app.submitMode()) {
            try self.syncFocus(ctx);
            if (self.app.models.model_load_future != null) try self.ensureTick(ctx);
            ctx.consumeAndRedraw();
            return;
        }
        if (!try self.app.beginSubmit()) return;
        try self.app.startTurn();
        try self.ensureTick(ctx);
        ctx.consumeAndRedraw();
    }

    fn syncFocus(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        // The provider setup form draws its own inline editor and intentionally
        // omits the overlay search field. Focusing the (undrawn) palette input
        // would leave the focus path empty and panic on the next event, so keep
        // focus on the root widget — it owns key handling via captureEvent anyway.
        if (self.app.mode == .provider_picker and self.app.provider_picker.stage == .form) {
            try ctx.requestFocus(self.widget());
            return;
        }
        const target = switch (self.app.mode) {
            .command, .session_picker, .provider_picker, .model_picker, .tree_picker => self.app.palette_input.widget(),
            .normal => self.app.input.widget(),
        };
        try ctx.requestFocus(target);
    }

    fn drainAgentEvents(self: *RootWidget, ctx: *vxfw.EventContext) !bool {
        const worker_io = self.app.worker_context.io;
        const worker_gpa = self.app.worker_context.gpa;
        var batch: std.ArrayList(*agent_mod.Agent.Event) = .empty;
        defer batch.deinit(worker_gpa);
        try self.app.worker_context.queue.drainInto(worker_io, worker_gpa, &batch);

        var visible_change = false;
        var refresh_diff = false;
        for (batch.items) |event_ptr| {
            defer worker_gpa.destroy(event_ptr);
            defer event_ptr.deinit(worker_gpa);

            // A discarded (interrupted) turn's events are swallowed inside
            // applyAgentEvent — the Turn machine refuses to project them — so
            // draining stays a single uniform path.
            if (self.app.turn_view.awaitingOutput()) try self.ensureTick(ctx);
            switch (event_ptr.*) {
                .tool_call_finished => refresh_diff = true,
                else => {},
            }
            if (try self.app.applyAgentEvent(event_ptr.*)) visible_change = true;
            if (self.app.turn_view.awaitingOutput()) try self.ensureTick(ctx);
        }
        if (refresh_diff) {
            self.diff_refresh_pending = true;
            self.diff_tick_accum = 0;
            try self.ensureTick(ctx);
        }
        return visible_change;
    }

    fn drawRoot(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        const layout = rootLayout(max_height, false, try self.app.inputTextRows(ctx, max_width -| 4));

        var thread_view: ThreadWidget = .{ .app = self.app };
        var input_view: InputWidget = .{ .app = self.app };
        var overlay_view: OverlayWidget = .{ .app = self.app };

        const thread_ctx = ctx.withConstraints(
            .{ .width = max_width, .height = layout.thread_height },
            .{ .width = max_width, .height = layout.thread_height },
        );
        const input_ctx = ctx.withConstraints(
            .{ .width = max_width, .height = layout.input_height },
            .{ .width = max_width, .height = layout.input_height },
        );

        const overlay_visible = self.app.mode != .normal;
        const at_visible = self.app.at_active and !overlay_visible;

        var child_count: usize = 2;
        if (overlay_visible) child_count += 1;
        if (at_visible) child_count += 1;
        const children = try ctx.arena.alloc(vxfw.SubSurface, child_count);
        var idx: usize = 0;
        children[idx] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try thread_view.widget().draw(thread_ctx),
            .z_index = 0,
        };
        idx += 1;
        children[idx] = .{
            .origin = .{ .row = layout.input_row, .col = 0 },
            .surface = try input_view.widget().draw(input_ctx),
            .z_index = 0,
        };
        idx += 1;
        if (overlay_visible) {
            var centered_overlay: vxfw.Center = .{ .child = overlay_view.widget() };
            children[idx] = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try centered_overlay.widget().draw(ctx.withConstraints(
                    .{ .width = max_width, .height = layout.thread_height },
                    .{ .width = max_width, .height = layout.thread_height },
                )),
                .z_index = 2,
            };
            idx += 1;
        }
        if (at_visible) {
            var at_view: AtSearchWidget = .{ .app = self.app };
            const panel_height = at_search.panelHeight(self.app.at_results.items.len);
            const panel_width = @min(@as(u16, 72), max_width);
            children[idx] = .{
                .origin = .{ .row = layout.input_row -| panel_height, .col = 0 },
                .surface = try at_view.widget().draw(ctx.withConstraints(
                    .{ .width = panel_width, .height = panel_height },
                    .{ .width = panel_width, .height = panel_height },
                )),
                .z_index = 1,
            };
            idx += 1;
        }

        return .{
            .size = .{ .width = max_width, .height = max_height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

fn shouldOpenCommandMenuForSlash(app: *const App, key: vaxis.Key) bool {
    if (!key.matches('/', .{})) return false;
    return switch (app.mode) {
        .normal => app.input.buf.realLength() == 0,
        .session_picker, .model_picker, .tree_picker => app.palette_input.buf.realLength() == 0,
        .provider_picker => app.provider_picker.stage == .list and app.palette_input.buf.realLength() == 0,
        .command => false,
    };
}

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
        const surface = try list_padding.widget().draw(ctx);
        self.updateBlackholeVisibility();
        return surface;
    }

    // The intro animation only runs while the startup logo (message 0) is the
    // first item the list view is rendering. Once a turn pushes it off the top,
    // `scroll.top` advances and the animation tick is allowed to stop.
    fn updateBlackholeVisibility(self: *ThreadWidget) void {
        const messages = self.app.thread.messages.items;
        self.app.blackhole_visible = messages.len > 0 and
            messages[0].kind == .logo and
            self.app.thread_list.scroll.top == 0;
    }

    fn syncViewport(self: *ThreadWidget, ctx: vxfw.DrawContext) void {
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        self.app.thread_view_width = max_width;
        self.app.thread_view_height = max_height -| ConversationLayout.top -| ConversationLayout.bottom;
        if (self.app.thread_view_height == 0) self.app.thread_view_height = 1;
    }

    // Status-row height (content row + the one-row separator metrics adds);
    // see `messageContentRows` for `.status` in tui/metrics.zig.
    const spinner_rows: u16 = 2;

    fn messageWidgets(self: *ThreadWidget, ctx: vxfw.DrawContext) ![]vxfw.Widget {
        const messages = self.app.thread.messages.items;
        const awaiting = self.app.turn_view.awaitingOutput();
        const total = messages.len + @intFromBool(awaiting);
        const widgets = try ctx.arena.alloc(vxfw.Widget, total);
        const bodies = try ctx.arena.alloc(MessageWidget, total);
        for (messages, 0..) |*message, index| {
            const selected = if (self.app.thread.selected) |selected_index| selected_index == index else false;
            bodies[index] = .{ .message = message, .selected = selected, .loading_frame = self.app.loading_frame, .blackhole_frame = self.app.blackhole_frame, .gpa = self.app.gpa };
            widgets[index] = bodies[index].widget();
        }
        if (awaiting) {
            // The loading spinner is derived UI, not a thread message: a
            // synthetic status row drawn at the tail while the turn waits for
            // the next chunk of model output.
            const word = loading_spinners[self.app.turn_view.loading_word_index];
            const spinner = try ctx.arena.create(thread_mod.Message);
            spinner.* = .{ .kind = .status, .title = try ctx.arena.dupe(u8, word), .body = try ctx.arena.dupe(u8, "") };
            bodies[messages.len] = .{ .message = spinner, .selected = false, .loading_frame = self.app.loading_frame, .blackhole_frame = self.app.blackhole_frame, .gpa = self.app.gpa };
            widgets[messages.len] = bodies[messages.len].widget();
        }
        return widgets;
    }

    fn syncCursor(self: *ThreadWidget, ctx: vxfw.DrawContext) void {
        const messages = self.app.thread.messages.items;
        const awaiting = self.app.turn_view.awaitingOutput();
        const total: u32 = @intCast(messages.len + @intFromBool(awaiting));
        if (total == 0) return;
        if (self.app.thread_auto_scroll) {
            // The tail is the synthetic spinner row when awaiting, else the
            // last real message.
            const cursor = total - 1;
            self.app.thread_list.cursor = cursor;
            self.scrollCursorToTail(ctx, cursor);
            return;
        }
        const fallback: u32 = if (awaiting) total - 1 else 0;
        const cursor = self.app.thread.selected orelse fallback;
        const cursor_changed = self.app.thread_list.cursor != cursor;
        self.app.thread_list.cursor = cursor;
        if (cursor_changed) self.app.thread_list.ensureScroll();
    }

    fn scrollCursorToTail(self: *ThreadWidget, ctx: vxfw.DrawContext, cursor: u32) void {
        const message_count: u32 = @intCast(self.app.thread.messages.items.len);
        if (cursor > message_count) return;
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        const list_height = max_height -| ConversationLayout.top -| ConversationLayout.bottom;
        // `cursor == message_count` targets the synthetic spinner row, which is
        // not in `thread.messages`; use its fixed status-row height.
        const message_height = if (cursor == message_count)
            spinner_rows
        else
            messageRowsCached(&self.app.thread.messages.items[cursor], ConversationLayout.contentWidth(max_width));
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

const Command = enum { connect, model, new, resume_session, timeline };
const CommandEntry = struct { name: []const u8, command: Command };
const commands = [_]CommandEntry{
    .{ .name = "Connect", .command = .connect },
    .{ .name = "Models", .command = .model },
    .{ .name = "New", .command = .new },
    .{ .name = "Resume", .command = .resume_session },
    .{ .name = "Timeline", .command = .timeline },
};
const command_panel_entries = [_]command_panel.Entry{
    .{ .name = "Connect" },
    .{ .name = "Models" },
    .{ .name = "New" },
    .{ .name = "Resume" },
    .{ .name = "Timeline" },
};

fn overlayLabel(mode: App.Mode) []const u8 {
    return switch (mode) {
        .normal => "",
        .command => "Command",
        .session_picker => "Search for Sessions",
        .provider_picker => "Connect to Provider",
        .model_picker => "Select Model",
        .tree_picker => "Session Timeline",
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
    const filter = app.peekPaletteInput() catch return 0;
    defer app.gpa.free(filter);
    return commandMatchesCountForFilter(filter);
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

/// Non-path trailer lines in `search_mod` path output: the `+N more results`
/// pagination footer and the empty-result marker. The ready backend never emits
/// content-search footers or shell-fallback banners on this path.
fn isSearchFooter(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "+") or
        std.mem.eql(u8, line, "0 results.");
}

fn inputChanged(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(userdata.?));
    app.block_nav = false;
    const was_command = app.mode == .command;
    try app.syncModeWithInput(value);
    if (!was_command and app.mode == .command) {
        app.clearInput();
        app.clearPaletteInput();
        try ctx.requestFocus(app.palette_input.widget());
    }
    if (app.mode == .normal) {
        try app.updateAtSearch();
    } else {
        app.closeAtSearch();
    }
    ctx.consumeAndRedraw();
}

fn paletteInputChanged(userdata: ?*anyopaque, ctx: *vxfw.EventContext, value: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(userdata.?));
    switch (app.mode) {
        .command => {
            const count = commandMatchesCountForFilter(value);
            if (app.command_selection >= count) app.command_selection = 0;
        },
        .session_picker => {
            const count = resume_picker.visibleCount(app.resume_summaries.items, value, app.resume_folded_projects.items, app.resume_global);
            if (app.resume_selection >= count) app.resume_selection = 0;
            app.syncResumeListCursor();
        },
        .tree_picker => {
            try app.tree_state.reflattenKeepingSelection(value);
        },
        .model_picker => {
            if (!app.modelDisplayMatches(app.models.model_selection, value)) {
                app.models.model_selection = app.firstMatchingModelDisplay(value) orelse 0;
            }
        },
        .provider_picker, .normal => {},
    }
    ctx.consumeAndRedraw();
}

const OverlaySize = struct { width: u16, height: u16 };

fn overlaySize(mode: App.Mode) OverlaySize {
    return switch (mode) {
        .normal => .{ .width = 0, .height = 0 },
        .command => .{ .width = 40, .height = 16 },
        .provider_picker => .{ .width = 72, .height = 16 },
        .session_picker => .{ .width = 80, .height = 16 },
        .model_picker => .{ .width = 90, .height = 16 },
        .tree_picker => .{ .width = 90, .height = 20 },
    };
}

/// Builds the floating `@`-results panel from app state. Presentational only;
/// the main input keeps focus.
const AtSearchWidget = struct {
    app: *App,

    fn widget(self: *AtSearchWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawAtSearch };
    }

    fn drawAtSearch(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *AtSearchWidget = @ptrCast(@alignCast(ptr));
        var content: at_search.Content = .{
            .results = self.app.at_results.items,
            .selection = self.app.at_selection,
            .query = self.app.at_query,
            .indexing = self.app.at_indexing,
            .sigil = if (self.app.at_kind == .file) '@' else '$',
            .title = if (self.app.at_kind == .file) "Files" else "Skills",
        };
        return content.widget().draw(ctx);
    }
};

const OverlayWidget = struct {
    app: *App,

    fn widget(self: *OverlayWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawOverlay };
    }

    fn drawOverlay(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *OverlayWidget = @ptrCast(@alignCast(ptr));
        const size = if (self.app.mode == .provider_picker and self.app.provider_picker.stage == .form)
            OverlaySize{ .width = 64, .height = 6 }
        else
            overlaySize(self.app.mode);
        const max_w: u16 = ctx.max.width orelse size.width;
        const max_h: u16 = ctx.max.height orelse size.height;
        const total_w: u16 = @min(size.width, max_w);
        const total_h: u16 = @min(size.height, max_h);
        var inner: OverlayInner = .{ .app = self.app };
        var border: vxfw.Border = .{
            .child = inner.widget(),
            .style = StylePalette.thinking_body,
        };
        var surface = try border.widget().draw(ctx.withConstraints(
            .{ .width = total_w, .height = total_h },
            .{ .width = total_w, .height = total_h },
        ));
        writeBorderLabel(&surface, ctx, overlayLabel(self.app.mode));
        return surface;
    }
};

fn writeDiffCounts(surface: *vxfw.Surface, ctx: vxfw.DrawContext, counts: DiffCounts) void {
    const additions = std.fmt.allocPrint(ctx.arena, "+{d}", .{@min(counts.additions, 99999)}) catch return;
    const deletions = std.fmt.allocPrint(ctx.arena, "-{d}", .{@min(counts.deletions, 99999)}) catch return;
    const total_width = additions.len + 1 + deletions.len;
    const start_col: u16 = if (total_width >= surface.size.width)
        0
    else
        @intCast(surface.size.width - total_width);
    writeAscii(surface, additions, StylePalette.tool, start_col);
    writeAscii(surface, deletions, StylePalette.tool_failed, start_col + @as(u16, @intCast(additions.len + 1)));
}

fn writeAscii(surface: *vxfw.Surface, text: []const u8, style: vaxis.Style, col_start: u16) void {
    var col = col_start;
    for (text, 0..) |_, index| {
        if (col >= surface.size.width) return;
        surface.writeCell(col, 0, .{
            .char = .{ .grapheme = text[index .. index + 1], .width = 1 },
            .style = style,
        });
        col += 1;
    }
}

fn writeBorderLabel(surface: *vxfw.Surface, ctx: vxfw.DrawContext, text: []const u8) void {
    writeBorderLabelLeft(surface, ctx, 0, text, StylePalette.border_label);
}

fn writeBorderLabelLeft(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, text: []const u8, style: vaxis.Style) void {
    if (text.len == 0 or row >= surface.size.height) return;
    var col: u16 = 1;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const width: u16 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        if (col + width >= surface.size.width) break;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = bytes, .width = @intCast(width) },
            .style = style,
        });
        col += width;
    }
}

fn writeBorderLabelRight(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, text: []const u8, style: vaxis.Style) void {
    if (text.len == 0 or row >= surface.size.height) return;
    const w = surface.size.width;
    if (w < 4) return;
    const max_w: u16 = w -| 3;
    const text_w: u16 = @intCast(@min(ctx.stringWidth(text), @as(usize, max_w)));
    if (text_w == 0) return;
    var col: u16 = w -| 2 -| text_w;
    var used: u16 = 0;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const width: u16 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        if (used + width > text_w) break;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = bytes, .width = @intCast(width) },
            .style = style,
        });
        col += width;
        used += width;
    }
}

const OverlayInner = struct {
    app: *App,

    fn widget(self: *OverlayInner) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawInner };
    }

    fn drawInner(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *OverlayInner = @ptrCast(@alignCast(ptr));
        const iw: u16 = ctx.max.width orelse 0;
        const ih: u16 = ctx.max.height orelse 0;

        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = iw, .height = ih });

        // The provider setup form hosts its own inline editor, so it skips the
        // shared search row entirely and fills the panel from the top.
        if (self.app.mode == .provider_picker and self.app.provider_picker.stage == .form) {
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{
                .origin = .{ .row = 0, .col = 0 },
                .z_index = 0,
                .surface = try drawContent(self.app, ctx.withConstraints(
                    .{ .width = iw, .height = ih },
                    .{ .width = iw, .height = ih },
                )),
            };
            surface.children = children;
            return surface;
        }

        // Horizontal separator under the search row.
        var sep_col: u16 = 0;
        while (sep_col < iw) : (sep_col += 1) {
            surface.writeCell(sep_col, 1, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = StylePalette.thinking_body,
            });
        }

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);

        // Row 0: prompt + shared overlay search input.
        var prompt_text: vxfw.Text = .{ .text = ">", .softwrap = false, .width_basis = .parent };
        var prompt_box: vxfw.SizedBox = .{ .child = prompt_text.widget(), .size = .{ .width = 2, .height = 1 } };
        var input_box: vxfw.SizedBox = .{ .child = self.app.palette_input.widget(), .size = .{ .width = iw -| 2, .height = 1 } };
        var search_row: vxfw.FlexRow = .{ .children = &.{
            .{ .widget = prompt_box.widget(), .flex = 0 },
            .{ .widget = input_box.widget(), .flex = 1 },
        } };
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .z_index = 0,
            .surface = try search_row.widget().draw(ctx.withConstraints(
                .{ .width = iw, .height = 1 },
                .{ .width = iw, .height = 1 },
            )),
        };

        // Rows 2..: mode-specific content area.
        const content_h: u16 = ih -| 2;
        const content_ctx = ctx.withConstraints(
            .{ .width = iw, .height = content_h },
            .{ .width = iw, .height = content_h },
        );
        children[1] = .{
            .origin = .{ .row = 2, .col = 0 },
            .z_index = 0,
            .surface = try drawContent(self.app, content_ctx),
        };

        surface.children = children;
        return surface;
    }

    fn drawContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        return switch (app.mode) {
            .command => drawCommandContent(app, ctx),
            .session_picker => drawSessionContent(app, ctx),
            .provider_picker => drawProviderContent(app, ctx),
            .model_picker => drawModelContent(app, ctx),
            .tree_picker => drawTreeContent(app, ctx),
            .normal => unreachable,
        };
    }

    fn drawTreeContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var content: tree_selector.Content = .{
            .state = &app.tree_state,
            .list = &app.tree_list,
        };
        return content.widget().draw(ctx);
    }

    fn drawCommandContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const filter = try app.peekPaletteInput();
        defer app.gpa.free(filter);
        var content: command_panel.Content = .{
            .entries = &command_panel_entries,
            .filter = filter,
            .selection = app.command_selection,
        };
        return content.widget().draw(ctx);
    }

    fn drawSessionContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const filter = try app.peekPaletteInput();
        defer app.gpa.free(filter);
        var content: resume_picker.Content = .{
            .io = app.io,
            .list = &app.resume_list,
            .summaries = app.resume_summaries.items,
            .selection = app.resume_selection,
            .folded_projects = app.resume_folded_projects.items,
            .filter = filter,
            .tree_mode = app.resume_global,
        };
        return content.widget().draw(ctx);
    }

    fn drawProviderContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const providers = config_mod.catalogueProviders();
        const connected = try ctx.arena.alloc(bool, providers.len);
        for (providers, 0..) |provider, i| {
            connected[i] = app.provider_api_keys.get(provider.label()) != null;
        }
        var content: provider_picker.Content = .{
            .state = app.provider_picker,
            .codex_signed_in = app.isCodexSignedIn(),
            .connected = connected,
            .key_input = app.provider_key_input.items,
        };
        return content.widget().draw(ctx);
    }

    fn drawModelContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const filter = try app.peekPaletteInput();
        defer app.gpa.free(filter);
        const status = tui_status.modelStatus(app.runtime, app.cached_config);
        // Project the consolidated entries into the parallel slices the picker
        // widget consumes. Arena-allocated, rebuilt each draw — cheap, and it
        // keeps the picker decoupled from the catalogue's internal layout.
        const entries = app.models.entries.items;
        const picker_models = try ctx.arena.alloc(codex.Model, entries.len);
        const picker_reasoning = try ctx.arena.alloc(u32, entries.len);
        for (entries, 0..) |entry, i| {
            picker_models[i] = entry.model;
            picker_reasoning[i] = entry.reasoning_index;
        }
        var content: model_picker.Content = .{
            .models = picker_models,
            .list = &app.model_list,
            .selection = app.models.model_selection,
            .column = app.models.model_column,
            .active_model = if (status) |value| value.model else null,
            .reasoning_options = reasoningOptions(),
            .reasoning_indexes = picker_reasoning,
            .scope = modelPickerScope(app.models.model_scope),
            .filter = filter,
            .loading = app.models.model_load_future != null,
            .error_message = app.models.model_load_error,
        };
        return content.widget().draw(ctx);
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

fn reasoningOptions() []const model_picker.ReasoningOption {
    return &reasoning_options;
}

fn inputHintText(app: *const App) []const u8 {
    return switch (app.mode) {
        .command => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Select" ++ symbols.separator_dot_padded ++ "[ESC] Back",
        .session_picker => if (app.resume_global)
            "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[CTRL+A] Current project" ++ symbols.separator_dot_padded ++ "[TAB] Fold" ++ symbols.separator_dot_padded ++ "[ENTER] Select" ++ symbols.separator_dot_padded ++ "[ESC] Back"
        else
            "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[CTRL+A] All projects" ++ symbols.separator_dot_padded ++ "[ENTER] Select" ++ symbols.separator_dot_padded ++ "[ESC] Back",
        .provider_picker => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "←→ Actions" ++ symbols.separator_dot_padded ++ "[ENTER] Select" ++ symbols.separator_dot_padded ++ "[ESC] Back",
        .model_picker => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "←→ Column" ++ symbols.separator_dot_padded ++ "[TAB] Toggle Effort/Scope" ++ symbols.separator_dot_padded ++ "[ENTER] Select" ++ symbols.separator_dot_padded ++ "[ESC] Back",
        .tree_picker => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "←→ Filter" ++ symbols.separator_dot_padded ++ "[TAB] Fold" ++ symbols.separator_dot_padded ++ "[ENTER] Switch" ++ symbols.separator_dot_padded ++ "[ESC] Back",
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
        const width = ctx.max.width orelse 0;
        const rows = try self.app.inputTextRows(ctx, width);
        if (rows <= 1) return self.app.input.draw(ctx);
        return self.drawMultiline(ctx);
    }

    fn drawMultiline(self: *CommandInputText, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 0;
        const height: u16 = @max(ctx.max.height orelse 1, 1);
        var surface = try vxfw.Surface.init(ctx.arena, self.app.input.widget(), .{ .width = width, .height = height });
        if (width == 0) return surface;

        const first = self.app.input.buf.firstHalf();
        const second = self.app.input.buf.secondHalf();

        const combined = try ctx.arena.alloc(u8, first.len + second.len);
        @memcpy(combined[0..first.len], first);
        @memcpy(combined[first.len..], second);

        const cursor_pos = wrappedTextPositionAt(ctx, combined, first.len, width);
        const total_lines = wrappedTextRows(ctx, combined, width);
        const first_visible = firstVisibleLine(cursor_pos.row, total_lines, height);

        drawInputWrapped(&surface, ctx, combined, .{
            .first_visible = first_visible,
            .height = height,
            .width = width,
        });

        surface.cursor = .{ .row = cursor_pos.row -| first_visible, .col = cursor_pos.col };
        return surface;
    }
};

const VerticalMove = enum { up, down };

fn lineStartBefore(text: []const u8, pos: usize) usize {
    if (std.mem.lastIndexOfScalar(u8, text[0..pos], '\n')) |idx| return idx + 1;
    return 0;
}

fn cellColumn(slice: []const u8) usize {
    return vaxis.gwidth.gwidth(slice, .unicode);
}

fn byteAtColumn(text: []const u8, line_start: usize, line_end: usize, col: usize) usize {
    var iter = vaxis.unicode.graphemeIterator(text[line_start..line_end]);
    var offset: usize = line_start;
    var cells: usize = 0;
    while (cells < col) {
        const grapheme = iter.next() orelse break;
        const bytes = grapheme.bytes(text[line_start..line_end]);
        const width = vaxis.gwidth.gwidth(bytes, .unicode);
        if (cells + width > col) break;
        cells += width;
        offset += grapheme.len;
    }
    return offset;
}

fn firstVisibleLine(cursor_line: u16, total: u16, visible: u16) u16 {
    if (visible == 0 or total <= visible) return 0;
    if (cursor_line < visible) return 0;
    return @min(cursor_line - visible + 1, total - visible);
}

const WrappedTextPosition = struct {
    row: u16,
    col: u16,
};

const WrappedInputDraw = struct {
    first_visible: u16,
    height: u16,
    width: u16,
};

fn wrappedTextRows(ctx: vxfw.DrawContext, text: []const u8, width: u16) u16 {
    return wrappedTextPositionAt(ctx, text, text.len, width).row + 1;
}

fn wrappedTextPositionAt(ctx: vxfw.DrawContext, text: []const u8, cursor: usize, width: u16) WrappedTextPosition {
    if (width == 0) return .{ .row = 0, .col = 0 };

    var row: u16 = 0;
    var col: u16 = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (cursor <= index) return .{ .row = row, .col = col };
        if (text[index] == '\n') {
            row += 1;
            col = 0;
            index += 1;
            continue;
        }

        const spaces_start = index;
        while (index < text.len and wrapSpace(text[index])) index += 1;
        if (cursor <= index) return advancePosition(ctx, text[spaces_start..cursor], row, col, width);

        const spaces = text[spaces_start..index];
        const word_start = index;
        while (index < text.len and text[index] != '\n' and !wrapSpace(text[index])) index += 1;
        const word = text[word_start..index];
        if (word.len == 0) {
            const pos = advancePosition(ctx, spaces, row, col, width);
            row = pos.row;
            col = pos.col;
            continue;
        }

        const spaces_width: u16 = @intCast(ctx.stringWidth(spaces));
        const word_width: u16 = @intCast(ctx.stringWidth(word));
        if (col > 0) {
            if (col + spaces_width + word_width > width) {
                row += 1;
                col = 0;
            } else {
                col = @min(width, col + spaces_width);
            }
        }
        if (cursor <= index) return advancePosition(ctx, text[word_start..cursor], row, col, width);

        const pos = advancePosition(ctx, word, row, col, width);
        row = pos.row;
        col = pos.col;
    }
    return .{ .row = row, .col = col };
}

fn advancePosition(ctx: vxfw.DrawContext, text: []const u8, row_start: u16, col_start: u16, width: u16) WrappedTextPosition {
    var row = row_start;
    var col = col_start;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const cell_width: u16 = @intCast(ctx.stringWidth(bytes));
        if (cell_width == 0) continue;
        if (col + cell_width > width) {
            row += 1;
            col = 0;
        }
        col = @min(width, col + cell_width);
    }
    return .{ .row = row, .col = col };
}

fn drawInputWrapped(surface: *vxfw.Surface, ctx: vxfw.DrawContext, text: []const u8, draw: WrappedInputDraw) void {
    if (draw.width == 0) return;

    var row: u16 = 0;
    var col: u16 = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\n') {
            row += 1;
            col = 0;
            index += 1;
            continue;
        }

        const spaces_start = index;
        while (index < text.len and wrapSpace(text[index])) index += 1;
        const spaces = text[spaces_start..index];

        const word_start = index;
        while (index < text.len and text[index] != '\n' and !wrapSpace(text[index])) index += 1;
        const word = text[word_start..index];
        if (word.len == 0) {
            drawRunWrapped(surface, ctx, spaces, draw, &row, &col);
            continue;
        }

        const spaces_width: u16 = @intCast(ctx.stringWidth(spaces));
        const word_width: u16 = @intCast(ctx.stringWidth(word));
        if (col > 0) {
            if (col + spaces_width + word_width > draw.width) {
                row += 1;
                col = 0;
            } else {
                drawRunWrapped(surface, ctx, spaces, draw, &row, &col);
            }
        }
        drawRunWrapped(surface, ctx, word, draw, &row, &col);
    }
}

fn drawRunWrapped(surface: *vxfw.Surface, ctx: vxfw.DrawContext, text: []const u8, draw: WrappedInputDraw, row: *u16, col: *u16) void {
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const cell_width: u16 = @intCast(ctx.stringWidth(bytes));
        if (cell_width == 0) continue;
        if (col.* + cell_width > draw.width) {
            row.* += 1;
            col.* = 0;
        }
        if (row.* >= draw.first_visible) {
            const visible_row = row.* - draw.first_visible;
            if (visible_row >= draw.height) break;
            surface.writeCell(col.*, visible_row, .{ .char = .{ .grapheme = bytes, .width = @intCast(cell_width) } });
        }
        col.* = @min(draw.width, col.* + cell_width);
    }
}

fn wrapSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
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
        const height: u16 = ctx.max.height orelse 4;

        const queued_visible = self.app.queued_user_messages.items.len > 0;
        const input_row: u16 = if (queued_visible) 1 else 0;
        const avail: u16 = height -| input_row;
        const input_width = max_width -| 4;
        const text_rows: u16 = @min(try self.app.inputTextRows(ctx, input_width), @max(@as(u16, 1), avail -| 2));
        const border_height: u16 = text_rows + 2;

        if (height < input_row + border_height) {
            return try self.drawInputBorder(ctx, max_width, @min(height, border_height), text_rows);
        }

        const base_row: u16 = input_row + border_height;
        const show_hint = height >= base_row + 1;
        const show_diff = show_hint and self.app.diffCountsVisible();
        const children_count: usize = 1 + @as(usize, if (show_hint) 1 else 0) + @as(usize, if (show_diff) 1 else 0) + @as(usize, if (queued_visible) 1 else 0);
        const children = try ctx.arena.alloc(vxfw.SubSurface, children_count);
        var child_index: usize = 0;
        if (queued_visible) {
            children[child_index] = .{
                .origin = .{ .row = 0, .col = 1 },
                .surface = try self.drawQueuedMessage(ctx, max_width -| 2),
                .z_index = 0,
            };
            child_index += 1;
        }
        children[child_index] = .{
            .origin = .{ .row = input_row, .col = 0 },
            .surface = try self.drawInputBorder(ctx, max_width, border_height, text_rows),
            .z_index = 0,
        };
        child_index += 1;
        if (show_hint) {
            const padding_x: u16 = @min(@as(u16, 1), max_width);
            const inner_width = max_width -| (padding_x * 2);
            try self.drawInputHint(ctx, children, child_index, base_row, padding_x, inner_width);
            child_index += 1;
        }
        if (show_diff) {
            try self.drawDiffCounts(ctx, children, child_index, base_row, max_width);
        }
        return .{
            .size = .{ .width = max_width, .height = height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn drawInputBorder(self: *InputWidget, ctx: vxfw.DrawContext, max_width: u16, border_height: u16, text_rows: u16) std.mem.Allocator.Error!vxfw.Surface {
        const prompt_text: []const u8 = if (self.app.mode == .normal) ">" else " ";
        var prompt: vxfw.Text = .{ .text = prompt_text, .softwrap = false, .width_basis = .parent };
        var prompt_box: vxfw.SizedBox = .{ .child = prompt.widget(), .size = .{ .width = 2, .height = 1 } };
        var command_input: CommandInputText = .{ .app = self.app };
        var input_box: vxfw.SizedBox = .{ .child = command_input.widget(), .size = .{ .width = max_width -| 2, .height = text_rows } };
        var row: vxfw.FlexRow = .{
            .children = &.{
                .{ .widget = prompt_box.widget(), .flex = 0 },
                .{ .widget = input_box.widget(), .flex = 1 },
            },
        };
        var row_box: vxfw.SizedBox = .{ .child = row.widget(), .size = .{ .width = max_width -| 2, .height = text_rows } };
        var border: vxfw.Border = .{
            .child = row_box.widget(),
            .style = StylePalette.thinking_body,
        };
        var box: vxfw.SizedBox = .{ .child = border.widget(), .size = .{ .width = max_width, .height = border_height } };
        var surface = try box.widget().draw(ctx.withConstraints(.{ .width = max_width, .height = border_height }, .{ .width = max_width, .height = border_height }));

        const status_text = if (tui_status.modelStatus(self.app.runtime, self.app.cached_config)) |status|
            tui_status.formatModelStatus(ctx.arena, status) catch ""
        else
            "";
        writeBorderLabelRight(&surface, ctx, 0, status_text, StylePalette.model_status);
        writeBorderLabelRight(&surface, ctx, border_height -| 1, self.app.git_label, StylePalette.thinking_body);
        return surface;
    }

    fn drawQueuedMessage(self: *InputWidget, ctx: vxfw.DrawContext, width: u16) std.mem.Allocator.Error!vxfw.Surface {
        const last = self.app.queued_user_messages.items[self.app.queued_user_messages.items.len - 1];
        const prefix = if (self.app.queued_user_messages.items.len == 1) "[...] " else "[...] + ";
        const text = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, last });
        var queued_text: vxfw.Text = .{ .text = text, .style = .{ .fg = StylePalette.thinking_body.fg, .dim = true }, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent };
        return queued_text.widget().draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
    }

    fn drawInputHint(self: *InputWidget, ctx: vxfw.DrawContext, children: []vxfw.SubSurface, child_index: usize, row: u16, col: u16, width: u16) std.mem.Allocator.Error!void {
        var hint_text: vxfw.Text = .{ .text = inputHintText(self.app), .style = StylePalette.thinking_body, .text_align = .center, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent };
        children[child_index] = .{
            .origin = .{ .row = row, .col = col },
            .surface = try hint_text.widget().draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 })),
            .z_index = 0,
        };
    }

    fn drawDiffCounts(self: *InputWidget, ctx: vxfw.DrawContext, children: []vxfw.SubSurface, child_index: usize, row: u16, width: u16) std.mem.Allocator.Error!void {
        const diff_width: u16 = 13;
        const surface_width = @min(diff_width, width);
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = surface_width, .height = 1 });
        if (surface_width > 0) writeDiffCounts(&surface, ctx, self.app.diff_counts);
        children[child_index] = .{
            .origin = .{ .row = row, .col = width -| 2 -| surface_width },
            .surface = surface,
            .z_index = 1,
        };
    }
};

test "parse diff counts sums numstat and skips binary" {
    const counts = parseDiffCounts(
        "3\t1\tsrc/a.zig\n" ++
            "-\t-\timage.png\n" ++
            "8\t0\tsrc/new.zig\n",
    );

    try std.testing.expectEqual(@as(u32, 11), counts.additions);
    try std.testing.expectEqual(@as(u32, 1), counts.deletions);
}

test "diff count label is right aligned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 13, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    var surface = try vxfw.Surface.init(ctx.arena, .{ .userdata = undefined, .drawFn = undefined }, .{ .width = 13, .height = 1 });

    writeDiffCounts(&surface, ctx, .{ .additions = 1, .deletions = 12 });

    try std.testing.expectEqualStrings(" ", surface.readCell(6, 0).char.grapheme);
    try std.testing.expectEqualStrings("+", surface.readCell(7, 0).char.grapheme);
    try std.testing.expectEqualStrings("1", surface.readCell(8, 0).char.grapheme);
    try std.testing.expectEqualStrings(" ", surface.readCell(9, 0).char.grapheme);
    try std.testing.expectEqualStrings("-", surface.readCell(10, 0).char.grapheme);
    try std.testing.expectEqualStrings("1", surface.readCell(11, 0).char.grapheme);
    try std.testing.expectEqualStrings("2", surface.readCell(12, 0).char.grapheme);
}

test "diff count labels keep signs next to numbers" {
    var small_add: [8]u8 = undefined;
    var small_del: [8]u8 = undefined;
    const small = DiffCounts{ .additions = 1, .deletions = 12 };
    const small_additions = try std.fmt.bufPrint(&small_add, "+{d}", .{@min(small.additions, 99999)});
    const small_deletions = try std.fmt.bufPrint(&small_del, "-{d}", .{@min(small.deletions, 99999)});

    var large_add: [8]u8 = undefined;
    var large_del: [8]u8 = undefined;
    const large = DiffCounts{ .additions = 12345, .deletions = 999999 };
    const large_additions = try std.fmt.bufPrint(&large_add, "+{d}", .{@min(large.additions, 99999)});
    const large_deletions = try std.fmt.bufPrint(&large_del, "-{d}", .{@min(large.deletions, 99999)});

    try std.testing.expectEqualStrings("+1", small_additions);
    try std.testing.expectEqualStrings("-12", small_deletions);
    try std.testing.expectEqualStrings("+12345", large_additions);
    try std.testing.expectEqualStrings("-99999", large_deletions);
}

test "root layout keeps input fixed when panel opens" {
    const normal = rootLayout(30, false, 1);
    const picker = rootLayout(30, true, 1);

    try std.testing.expectEqual(normal.input_row, picker.input_row);
    try std.testing.expectEqual(normal.thread_height, picker.thread_height);
    try std.testing.expectEqual(@as(u16, 19), picker.panel_row);
    try std.testing.expectEqual(@as(u16, 7), picker.panel_height);
}

test "root layout clamps panel above input on short screens" {
    const layout = rootLayout(8, true, 1);

    try std.testing.expectEqual(@as(u16, 4), layout.input_height);
    try std.testing.expectEqual(@as(u16, 4), layout.thread_height);
    try std.testing.expectEqual(@as(u16, 4), layout.panel_height);
    try std.testing.expectEqual(@as(u16, 0), layout.panel_row);
    try std.testing.expectEqual(@as(u16, 4), layout.input_row);
}

test "root layout grows the input as text rows increase" {
    const one = rootLayout(30, false, 1);
    try std.testing.expectEqual(@as(u16, 4), one.input_height);
    try std.testing.expectEqual(@as(u16, 26), one.thread_height);

    const three = rootLayout(30, false, 3);
    try std.testing.expectEqual(@as(u16, 6), three.input_height);
    try std.testing.expectEqual(@as(u16, 24), three.thread_height);

    // A short screen still leaves the thread some room.
    const tight = rootLayout(10, false, 6);
    try std.testing.expectEqual(@as(u16, 7), tight.input_height);
    try std.testing.expectEqual(@as(u16, 3), tight.thread_height);
}

test "input text rows track the line count" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 100, .height = 30 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    try std.testing.expectEqual(@as(u16, 1), try app.inputTextRows(ctx, 80));

    try app.input.insertSliceAtCursor("a\nb\nc");
    try std.testing.expectEqual(@as(u16, 3), try app.inputTextRows(ctx, 80));

    try app.input.insertSliceAtCursor("defgh");
    try std.testing.expectEqual(@as(u16, 4), try app.inputTextRows(ctx, 4));

    // The input keeps growing with the line count (no fixed cap).
    try app.input.insertSliceAtCursor("\n\n\n\n\n\n\n\n");
    try std.testing.expectEqual(@as(u16, 12), try app.inputTextRows(ctx, 4));
}

test "input wrapping uses word breaks" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 100, .height = 30 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const text = "hello world";
    try std.testing.expectEqual(@as(u16, 2), wrappedTextRows(ctx, text, 10));

    const cursor = wrappedTextPositionAt(ctx, text, "hello wo".len, 10);
    try std.testing.expectEqual(@as(u16, 1), cursor.row);
    try std.testing.expectEqual(@as(u16, 2), cursor.col);
}

test "down returns to multiline input after overshooting above top line" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    try app.input.insertSliceAtCursor("top\nmiddle\nbottom");

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try std.testing.expectEqualStrings("top", app.input.buf.firstHalf());

    // One more Up leaves the input for block navigation.
    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try std.testing.expect(app.block_nav);

    // With no thread block selected, Down must return to the multiline input.
    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expect(!app.block_nav);
    try std.testing.expectEqualStrings("top\nmid", app.input.buf.firstHalf());

    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expectEqualStrings("top\nmiddle\nbot", app.input.buf.firstHalf());
}

test "arrow up and down move the input cursor between lines" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Cursor ends on the third line at column 2 ("ca|t").
    try app.input.insertSliceAtCursor("fox\nox\ncat");
    app.input.cursorLeft(); // between "ca" and "t"

    // Up keeps the column, clamped to the shorter middle line ("ox" -> end).
    try std.testing.expect(try app.moveInputCursorVertical(.up));
    try std.testing.expectEqualStrings("fox\nox", app.input.buf.firstHalf());

    // Up again lands at column 2 of the first line ("fo|x").
    try std.testing.expect(try app.moveInputCursorVertical(.up));
    try std.testing.expectEqualStrings("fo", app.input.buf.firstHalf());

    // Already on the first line: no move, caller falls back to thread nav.
    try std.testing.expect(!(try app.moveInputCursorVertical(.up)));

    // Down returns to the middle line at the same column ("ox" -> end).
    try std.testing.expect(try app.moveInputCursorVertical(.down));
    try std.testing.expectEqualStrings("fox\nox", app.input.buf.firstHalf());

    // Down to the last line, then no further move.
    try std.testing.expect(try app.moveInputCursorVertical(.down));
    try std.testing.expectEqualStrings("fox\nox\nca", app.input.buf.firstHalf());
    try std.testing.expect(!(try app.moveInputCursorVertical(.down)));
}

test "global resume sorting groups projects by latest session" {
    var summaries = [_]session_mod.SessionSummary{
        .{ .id = @constCast("old-b"), .title = null, .cwd = @constCast("/repo/b"), .created_at_ms = 0, .updated_at_ms = 10, .leaf_entry_id = null },
        .{ .id = @constCast("new-a"), .title = null, .cwd = @constCast("/repo/a"), .created_at_ms = 0, .updated_at_ms = 30, .leaf_entry_id = null },
        .{ .id = @constCast("new-b"), .title = null, .cwd = @constCast("/repo/b"), .created_at_ms = 0, .updated_at_ms = 40, .leaf_entry_id = null },
        .{ .id = @constCast("old-a"), .title = null, .cwd = @constCast("/repo/a"), .created_at_ms = 0, .updated_at_ms = 20, .leaf_entry_id = null },
    };

    const context: []const session_mod.SessionSummary = summaries[0..];
    std.mem.sort(session_mod.SessionSummary, summaries[0..], context, resumeSummaryLessThan);

    try std.testing.expectEqualStrings("/repo/b", summaries[0].cwd);
    try std.testing.expectEqualStrings("new-b", summaries[0].id);
    try std.testing.expectEqualStrings("/repo/b", summaries[1].cwd);
    try std.testing.expectEqualStrings("old-b", summaries[1].id);
    try std.testing.expectEqualStrings("/repo/a", summaries[2].cwd);
    try std.testing.expectEqualStrings("new-a", summaries[2].id);
    try std.testing.expectEqualStrings("/repo/a", summaries[3].cwd);
    try std.testing.expectEqualStrings("old-a", summaries[3].id);
}

test "esc backs out of command panels before interrupting active turn" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.turn.submit();
    app.mode = .provider_picker;

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });

    try std.testing.expectEqual(App.Mode.command, app.mode);
    try std.testing.expectEqual(Turn.State.active, app.turn.state);
}

test "ctrl-c clears a non-empty input instead of arming quit" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    try app.input.insertSliceAtCursor("draft message");

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    const ctrl_c: vxfw.Event = .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } };
    try RootWidget.captureEvent(&root, &ctx, ctrl_c);

    // The input is cleared and the quit sequence is not armed.
    try std.testing.expectEqual(@as(usize, 0), app.input.buf.realLength());
    try std.testing.expect(app.pending_quit_at == null);
    try std.testing.expect(!ctx.quit);
}

test "down past the last block re-enters the input" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    // Tall viewport so the short messages never count as scrollable.
    app.thread_view_width = 80;
    app.thread_view_height = 100;

    _ = try app.thread.append(gpa, .agent, "agent", "one");
    _ = try app.thread.append(gpa, .agent, "agent", "two");
    _ = try app.thread.append(gpa, .agent, "agent", "three");
    // Following the tail, the last block is selected.
    try std.testing.expectEqual(@as(?u32, 2), app.thread.selected);

    // In block navigation, up walks to an earlier block.
    app.block_nav = true;
    _ = try app.handleThreadKey(.{ .codepoint = vaxis.Key.up });
    try std.testing.expectEqual(@as(?u32, 1), app.thread.selected);

    // Down walks back toward the last block, still navigating blocks.
    _ = try app.handleThreadKey(.{ .codepoint = vaxis.Key.down });
    try std.testing.expectEqual(@as(?u32, 2), app.thread.selected);
    try std.testing.expect(app.block_nav);

    // Down again on the last block hands control back to the input.
    _ = try app.handleThreadKey(.{ .codepoint = vaxis.Key.down });
    try std.testing.expect(!app.block_nav);
    try std.testing.expectEqual(@as(?u32, 2), app.thread.selected);
}

test "down past the last block moves into multiline input" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.thread_view_width = 80;
    app.thread_view_height = 100;

    _ = try app.thread.append(gpa, .agent, "agent", "one");
    try app.input.insertSliceAtCursor("top\nmiddle");
    // Put the cursor on the top line, just before the newline. Re-entering
    // from block navigation should step down into the input line below.
    app.input.buf.moveGapLeft("\nmiddle".len);
    app.block_nav = true;

    try std.testing.expect(try app.handleThreadKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expect(!app.block_nav);
    try std.testing.expectEqualStrings("top\nmid", app.input.buf.firstHalf());
}

test "shift enter inserts a newline instead of submitting" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    try app.input.insertSliceAtCursor("line one");
    try app.insertInputNewline();
    try app.input.insertSliceAtCursor("line two");

    const value = try app.peekInput();
    defer gpa.free(value);
    try std.testing.expectEqualStrings("line one\nline two", value);
}

test "firstVisibleLine keeps the cursor line within the window" {
    try std.testing.expectEqual(@as(u16, 0), firstVisibleLine(0, 3, 4));
    try std.testing.expectEqual(@as(u16, 0), firstVisibleLine(3, 4, 4));
    // Cursor past the fold pins to the bottom edge.
    try std.testing.expectEqual(@as(u16, 1), firstVisibleLine(4, 10, 4));
    try std.testing.expectEqual(@as(u16, 6), firstVisibleLine(9, 10, 4));
}

test "root overlay host does not paint outside panel" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .command;

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 100, .height = 30 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try root.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 3), surface.children.len);

    const overlay_host = surface.children[2].surface;
    try std.testing.expectEqual(@as(usize, 0), overlay_host.buffer.len);
    try std.testing.expectEqual(@as(usize, 1), overlay_host.children.len);

    const panel_surface = overlay_host.children[0].surface;
    try std.testing.expectEqual(@as(u16, 40), panel_surface.size.width);
    try std.testing.expectEqual(@as(u16, 16), panel_surface.size.height);
}

test "provider setup form renders for opencode zen without crashing" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .provider_picker;
    app.provider_picker.stage = .form;
    app.provider_picker.form_provider = .opencode_zen;

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 100, .height = 30 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try root.widget().draw(ctx);
    try std.testing.expect(surface.children.len >= 1);
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

test "down at latest long message bottom does not loop to top" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.append(gpa, .agent, "agent", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    app.thread.selected = 0;
    app.thread_view_width = 80;
    app.thread_view_height = 4;
    const offset = messageRowsCached(&app.thread.messages.items[0], ConversationLayout.contentWidth(app.thread_view_width)) - app.thread_view_height;
    app.setSelectedMessageOffset(0, offset);

    const scrolled = app.navigateThread(.next);

    try std.testing.expect(!scrolled);
    try std.testing.expectEqual(@as(?u32, 0), app.thread.selected);
    try std.testing.expectEqual(@as(i17, @intCast(offset)), app.thread_list.scroll.offset);
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
    app.setSelectedMessageOffset(0, messageRowsCached(&app.thread.messages.items[0], ConversationLayout.contentWidth(app.thread_view_width)) - app.thread_view_height);

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

test "begin submit clears input and starts a turn awaiting output" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    try std.testing.expect(try app.beginSubmit());

    try std.testing.expectEqual(@as(usize, 0), app.input.buf.firstHalf().len);
    try std.testing.expectEqual(@as(usize, 0), app.input.buf.secondHalf().len);
    // The user message is the only thread entry; the spinner is derived from
    // The loading spinner is drawn at the tail, never stored as a message.
    try std.testing.expectEqual(@as(usize, 1), app.thread.messages.items.len);
    try std.testing.expectEqualStrings("hello", app.thread.messages.items[0].body);
    try std.testing.expect(app.turn_view.awaitingOutput());
    try std.testing.expectEqual(Turn.State.active, app.turn.state);
    try std.testing.expectEqual(@as(u32, 0), app.thread.selected.?);
}

test "awaiting turn draws a synthetic spinner row at the tail" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.append(gpa, .user, "you", "hello");
    app.turn_view.awaitModel();

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

    // One real message plus the derived spinner row, with auto-scroll parked on
    // the synthetic tail — exercises the synthetic-row index and scroll math.
    try std.testing.expectEqual(2, app.thread_list.item_count);
    try std.testing.expectEqual(1, app.thread_list.cursor);
}

test "begin submit queues while turn is in flight" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    // Simulate a turn already streaming and waiting on the next chunk.
    app.turn.submit();
    app.turn_view.awaitModel();

    try app.input.insertSliceAtCursor("later");
    try std.testing.expect(!try app.beginSubmit());

    try std.testing.expectEqual(@as(usize, 1), app.queued_user_messages.items.len);
    try std.testing.expectEqualStrings("later", app.queued_user_messages.items[0]);
    try std.testing.expectEqual(@as(u32, 1), agent.message_queue.len());
    try std.testing.expectEqual(@as(usize, 0), app.input.buf.firstHalf().len);
    try std.testing.expect(try app.applyAgentEvent(.{ .queued_messages_flushed = 1 }));
    try std.testing.expectEqual(@as(usize, 0), app.queued_user_messages.items.len);
    // Just the flushed user message; the spinner stays derived at the tail.
    try std.testing.expectEqual(@as(usize, 1), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqualStrings("later", app.thread.messages.items[0].body);
    try std.testing.expect(app.turn_view.awaitingOutput());
}

test "queued prompt draws above input at minimum input height" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.turn.submit();
    app.turn_view.awaitModel();

    try app.input.insertSliceAtCursor("later");
    try std.testing.expect(!try app.beginSubmit());

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var input_widget: InputWidget = .{ .app = &app };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try input_widget.widget().draw(ctx);

    try std.testing.expectEqual(@as(usize, 2), surface.children.len);
    try std.testing.expectEqual(@as(u16, 0), surface.children[0].origin.row);
    try std.testing.expectEqual(@as(u16, 1), surface.children[1].origin.row);
    try std.testing.expectEqualStrings("[", surface.children[0].surface.readCell(0, 0).char.grapheme);
}

test "begin submit shows notice when queued message queue is full" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.turn.submit();
    app.turn_view.awaitModel();

    var queued_count: usize = 0;
    while (queued_count < agent.message_queue_storage.len) : (queued_count += 1) {
        try agent.enqueueUser("queued");
    }

    try app.input.insertSliceAtCursor("later");
    try std.testing.expect(!try app.beginSubmit());

    try std.testing.expectEqual(@as(usize, 0), app.queued_user_messages.items.len);
    try std.testing.expectEqual(@as(u32, @intCast(agent.message_queue_storage.len)), agent.message_queue.len());
    try std.testing.expectEqualStrings("later", app.input.buf.firstHalf());
    // The notice is appended below the derived spinner; no status message.
    try std.testing.expectEqual(@as(usize, 1), app.thread.messages.items.len);
    try std.testing.expectEqual(.notice, app.thread.messages.items[0].kind);
    try std.testing.expectEqualStrings("MessageQueueFull", app.thread.messages.items[0].body);
    try std.testing.expect(app.turn_view.awaitingOutput());
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

    app.models.model_selection = 4;
    try app.openModelPicker();

    try std.testing.expectEqual(@as(u32, 0), app.models.model_selection);
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
    app.models.model_column = .reasoning;
    app.models.model_selection = 0;
    const models = try codex.loadStaticModels(gpa);
    defer gpa.free(models);
    for (models) |model| try app.models.append(gpa, model, .openai_codex);

    var row: model_picker.Row = .{
        .model = &app.models.entries.items[0].model,
        .selected = true,
        .column = app.models.model_column,
        .active_model = null,
        .reasoning_label = reasoningOptions()[app.selectedReasoningIndex()].label,
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
    try std.testing.expectEqualStrings("‣", surface.readCell(panel.secondaryColumn(surface.size.width), 0).char.grapheme);
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
    app.models.model_column = .model;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.right }));
    try std.testing.expectEqual(model_picker.Column.model, app.models.model_column);
}

test "provider picker navigates from codex to catalogue providers" {
    var state: provider_picker.State = .{};
    try std.testing.expectEqual(@as(u32, 0), state.selection);
    try std.testing.expectEqual(provider_picker.Action.connect_codex, state.selectedAction());
    // Below the Codex row sit the catalogue providers; selecting one opens its form.
    try std.testing.expect(state.handleKey(.{ .codepoint = vaxis.Key.down }, false));
    try std.testing.expectEqual(@as(u32, 1), state.selection);
    try std.testing.expect(state.selectedAction() == .open_form);
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

test "compatible base url falls back when cached local provider differs" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.cached_config.provider = .llama_cpp;
    app.cached_config.base_url = @constCast("http://localhost:11434");

    try std.testing.expectEqualStrings("http://localhost:8080", app.compatibleBaseUrl(.llama_cpp).?);
    try std.testing.expectEqualStrings("http://localhost:11434", app.compatibleBaseUrl(.ollama).?);
}

test "codex sign-in survives selecting local compatible provider" {
    const gpa = std.testing.allocator;
    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.gpa = gpa;
    runtime.io = std.testing.io;
    runtime.cwd = ".";
    runtime.home_dir = ".";
    runtime.client = .none;
    runtime.base_system_prompt = "test";
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
    try app.models.append(gpa, .{ .id = try gpa.dupe(u8, "llama3"), .label = try gpa.dupe(u8, "llama3") }, .{ .openai_compatible = .ollama });
    app.models.model_selection = 0;
    app.cached_config_owned = true;
    app.cached_config.base_url = try gpa.dupe(u8, "http://localhost:11434/v1");
    app.cached_config.api_key = try gpa.dupe(u8, "ollama");

    try app.applySelectedModel();

    try std.testing.expect(app.isCodexSignedIn());
    try std.testing.expectEqual(config_mod.Provider.ollama, app.cached_config.provider.?);
}

test "switching from codex to catalogue provider resets cached connection" {
    const gpa = std.testing.allocator;
    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.gpa = gpa;
    runtime.io = std.testing.io;
    runtime.cwd = ".";
    runtime.home_dir = ".";
    runtime.client = .none;
    runtime.base_system_prompt = "test";
    runtime.system_prompt = "test";
    runtime.session_writer = undefined;
    runtime.agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer runtime.agent.deinit();
    runtime.diagnostics = &.{};
    runtime.codex_connection_expired = false;
    runtime.owned_client = null;
    defer runtime.disconnectClient();

    var app = App.init(std.testing.io, gpa, &runtime.agent);
    app.runtime = &runtime;
    defer app.deinit();

    app.models.model_scope = .session;
    try app.models.append(gpa, .{ .id = try gpa.dupe(u8, "zen"), .label = try gpa.dupe(u8, "zen") }, .{ .openai_compatible = .opencode_zen });
    app.models.model_selection = 0;
    app.cached_config_owned = true;
    app.cached_config.provider = .openai;
    app.cached_config.base_url = try gpa.dupe(u8, "https://chatgpt.com/backend-api");
    app.cached_config.api_key = try gpa.dupe(u8, "stale-codex-key");

    try app.applySelectedModel();

    try std.testing.expectEqual(config_mod.Provider.opencode_zen, app.cached_config.provider.?);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1", app.cached_config.base_url.?);
    try std.testing.expectEqual(@as(?[]u8, null), app.cached_config.api_key);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1/chat/completions", runtime.client.openai_compatible.url);
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

    const active_storage_idx = app.models.activeStorageIdx("gpt-5.4-mini");
    const storage_idx = model_picker.displayToStorage(active_storage_idx, 0);
    try std.testing.expectEqualStrings("gpt-5.4-mini", app.models.entries.items[storage_idx].model.id);
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

    try std.testing.expect(app.models.len() > 0);
    try std.testing.expect(app.selectedCodexModel() != null);
}

test "slash opens command menu before focused input handles it" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{
        .io = std.testing.io,
        .alloc = arena.allocator(),
        .cmds = .empty,
    };

    var root: RootWidget = .{ .app = &app };
    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = '/', .text = "/" } });

    try std.testing.expectEqual(App.Mode.command, app.mode);
    try std.testing.expectEqual(@as(usize, 0), app.input.buf.realLength());
}

test "slash opens command menu when text field previous value is stale" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    app.input.previous_val = try gpa.dupe(u8, "/");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{
        .io = std.testing.io,
        .alloc = arena.allocator(),
        .cmds = .empty,
    };

    var root: RootWidget = .{ .app = &app };
    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = '/', .text = "/" } });

    try std.testing.expectEqual(App.Mode.command, app.mode);
    try std.testing.expectEqual(@as(usize, 0), app.input.buf.realLength());
}

test "expired codex connection reports reconnect message" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.codex_connection_expired = true;
    runtime.diagnostics = &.{};
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.runtime = &runtime;
    app.cached_config = .{ .provider = .openai };

    const message = try app.formatNoProviderMessage();
    defer gpa.free(message);

    try std.testing.expectEqualStrings(runtime_mod.codex_connection_expired_message, message);
}

test "typing slash can open command menu after input changed before" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{
        .io = std.testing.io,
        .alloc = arena.allocator(),
        .cmds = .empty,
    };

    try app.input.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'x', .text = "x" } });
    app.input.clearRetainingCapacity();
    app.turn.submit();
    defer app.turn.reset();
    try app.input.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '/', .text = "/" } });

    try std.testing.expectEqual(App.Mode.command, app.mode);
}

test "reprompt after interrupt starts a fresh turn" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("first");
    try std.testing.expect(try app.beginSubmit());
    if (app.pending_prompt) |prompt| app.worker_context.gpa.free(prompt);
    app.pending_prompt = null;
    try app.handleInterrupt();

    try app.input.insertSliceAtCursor("second");
    try std.testing.expect(try app.beginSubmit());
    defer app.turn.reset();
    defer {
        if (app.pending_prompt) |prompt| app.worker_context.gpa.free(prompt);
        app.pending_prompt = null;
    }

    try std.testing.expectEqual(Turn.State.active, app.turn.state);
    try std.testing.expectEqual(@as(usize, 0), app.queued_user_messages.items.len);
}

test "model selection is allowed after interrupt" {
    const gpa = std.testing.allocator;
    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.gpa = gpa;
    runtime.io = std.testing.io;
    runtime.cwd = ".";
    runtime.home_dir = ".";
    runtime.client = .none;
    runtime.base_system_prompt = "test";
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

    try app.models.append(gpa, .{ .id = try gpa.dupe(u8, "llama3"), .label = try gpa.dupe(u8, "llama3") }, .{ .openai_compatible = .ollama });
    app.models.model_selection = 0;
    app.cached_config_owned = true;
    app.cached_config.base_url = try gpa.dupe(u8, "http://localhost:11434/v1");
    app.cached_config.api_key = try gpa.dupe(u8, "ollama");
    app.turn.submit();
    app.turn.interrupt();

    try app.applySelectedModel();

    try std.testing.expectEqual(Turn.State.idle, app.turn.state);
    try std.testing.expectEqual(config_mod.Provider.ollama, app.cached_config.provider.?);
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
    const main_input = try app.peekInput();
    defer gpa.free(main_input);
    try std.testing.expectEqualStrings("", main_input);
    const palette_filter = try app.peekPaletteInput();
    defer gpa.free(palette_filter);
    try std.testing.expectEqualStrings("", palette_filter);
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
    for (models) |model| try app.models.append(gpa, model, .openai_codex);
    app.mode = .model_picker;
    app.models.model_selection = @intCast(app.models.len() - 1);
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expectEqual(@as(u32, 0), app.models.model_selection);

    app.models.model_column = .reasoning;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(@as(u32, 1), app.models.entries.items[0].reasoning_index);
    try std.testing.expectEqual(@as(u32, 0), app.models.entries.items[1].reasoning_index);
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
    _ = try app.beginSubmit();

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
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = "checking" }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\",\"reason\":\"List files\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = " files" }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "List files",
        .display_expanded_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\n\nstderr:\n",
    } }));

    try std.testing.expectEqual(@as(usize, 3), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.thinking, app.thread.messages.items[1].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[2].kind);
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);
    try std.testing.expectEqualStrings("checking files", app.thread.messages.items[1].body);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.messages.items[2].title);
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
    _ = try app.beginSubmit();

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
    _ = try app.beginSubmit();

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
    _ = try app.beginSubmit();

    _ = try app.applyAgentEvent(.{ .thinking_delta = "thinking" });
    const thinking_index = app.turn_view.thinking_index.?;
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
    _ = try app.beginSubmit();

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
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\",\"reason\":\"Print working directory\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "Print working directory",
        .display_expanded_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    // No status message — the spinner is derived; the batch leaves us awaiting
    // the next response over the user + tool rows.
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expect(app.turn_view.awaitingOutput());

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
    _ = try app.beginSubmit();

    // Once a content delta has arrived we are committed to streaming. The gap
    // between chunks must NOT bring the spinner back — the streaming text is
    // its own progress indicator.
    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "Here's the implementation plan:" }));
    _ = try app.applyAgentEvent(.delta_end);
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.agent, app.thread.messages.items[1].kind);
}

test "bash tool waits for complete arguments while streaming" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("list files");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"printf hello",
    } }));
    try std.testing.expectEqual(@as(usize, 1), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);

    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "Print hello",
        .display_expanded_label = "printf hello",
        .display_body = "hello",
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
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\",\"reason\":\"List files\"}",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.messages.items[1].title);
    try std.testing.expectEqualStrings("🛠  ls", app.thread.messages.items[1].tool_expanded_title.?);
    try std.testing.expect(app.thread.messages.items[1].tool_running);
    try std.testing.expect(app.thread.hasRunningTool());

    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.messages.items[1].title);

    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "List files",
        .display_expanded_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expect(!app.thread.messages.items[1].tool_running);
    try std.testing.expect(!app.thread.hasRunningTool());
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.messages.items[1].title);

    try std.testing.expect(try app.applyAgentEvent(.turn_finished));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.messages.items[1].title);
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
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"",
    } }));
    // Partial arguments render nothing, so no tool row appears and the spinner
    // stays up (awaiting) over the lone user message.
    try std.testing.expectEqual(@as(usize, 1), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expect(app.turn_view.awaitingOutput());

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\",\"reason\":\"List files\"}",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.messages.items[1].title);
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
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "List files",
        .display_expanded_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));

    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.messages.items[1].title);
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
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\",\"reason\":\"List files\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "List files",
        .display_expanded_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\",\"reason\":\"Print working directory\"}",
    } }));

    try std.testing.expectEqual(@as(usize, 3), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[2].kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.messages.items[1].title);
    try std.testing.expectEqualStrings("🛠  Print working directory", app.thread.messages.items[2].title);
}

test "bash tool after batch creates a new tool row" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run tools");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\",\"reason\":\"List files\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "List files",
        .display_expanded_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    // Awaiting the next segment over the user + tool rows; spinner is derived.
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expect(app.turn_view.awaitingOutput());

    _ = try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"printf done\",\"reason\":\"Print done\"}",
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
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\",\"reason\":\"List files\"}",
    } }));
    try std.testing.expectEqual(@as(u32, 1), app.thread.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 1,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\",\"reason\":\"Print working directory\"}",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "List files",
        .display_expanded_label = "ls",
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
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\",\"reason\":\"Print working directory\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "Print working directory",
        .display_expanded_label = "pwd",
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
    _ = try app.beginSubmit();

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "I will check." }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\",\"reason\":\"Print working directory\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "Print working directory",
        .display_expanded_label = "pwd",
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
    try std.testing.expectEqualStrings("🛠  Print working directory", app.thread.messages.items[2].title);
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
    _ = try app.beginSubmit();

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "I will check." }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(u32, 1), app.thread.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\",\"reason\":\"Print working directory\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = " Still checking." }));
    _ = try app.applyAgentEvent(.delta_end);
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "Print working directory",
        .display_expanded_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);
    try std.testing.expectEqualStrings("I will check.", app.thread.messages.items[1].body);
    try std.testing.expectEqualStrings("🛠  Print working directory", app.thread.messages.items[2].title);
    try std.testing.expectEqualStrings(" Still checking.", app.thread.messages.items[3].body);
}

test "collapsed thinking and tool rows have stable heights" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    const thinking_index = try thread.append(gpa, .thinking, "Thinking...", "short");
    try std.testing.expectEqual(@as(u16, 2), messageRowsCached(&thread.messages.items[thinking_index], 80));

    try thread.appendThinkingDelta(gpa, thinking_index, " ");
    try thread.appendThinkingDelta(gpa, thinking_index, "this is a much longer thinking body that should not change the collapsed row height");
    try std.testing.expectEqual(@as(u16, 2), messageRowsCached(&thread.messages.items[thinking_index], 80));

    const tool_index = try thread.startTool(gpa, "pwd");
    try std.testing.expectEqual(@as(u16, 2), messageRowsCached(&thread.messages.items[tool_index], 80));
}

test "collapsed tool title wraps to visible rows" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    const index = try thread.startTool(gpa, "python3 - <<'PY'\nprint('a very long patch document')\nPY");
    try std.testing.expect(!thread.messages.items[index].expanded);
    try std.testing.expect(messageRowsCached(&thread.messages.items[index], 12) > 3);
}

test "resumed tool messages keep the tool icon" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "done") } };
    try agent.takeMessage(.{
        .role = .tool,
        .content = blocks,
        .tool_display_label = try gpa.dupe(u8, "zig build test"),
    });

    try app.rebuildThreadFromAgent();

    try std.testing.expectEqual(@as(usize, 1), app.thread.messages.items.len);
    try std.testing.expectEqualStrings("🛠  zig build test", app.thread.messages.items[0].title);
}

test "collapsed tool messages render no body text" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    const index = try thread.startTool(gpa, "printf hello");
    try thread.finishTool(gpa, index, "hello", null, false);

    try std.testing.expect(!thread.messages.items[index].expanded);
    try std.testing.expectEqual(@as(u16, 2), messageRowsCached(&thread.messages.items[index], 80));
    thread.toggleSelected();
    try std.testing.expect(thread.messages.items[index].expanded);
    try std.testing.expectEqualStrings("hello", thread.messages.items[index].body);
}

test "expanded tool surface height cannot overflow vxfw buffer size" {
    const gpa = std.testing.allocator;
    const body = try gpa.alloc(u8, 80_000);
    defer gpa.free(body);
    @memset(body, 'x');

    var message: thread_mod.Message = .{
        .kind = .tool,
        .title = try gpa.dupe(u8, "$ yes"),
        .body = body,
        .expanded = true,
    };
    defer gpa.free(message.title);

    var widget: MessageWidget = .{
        .message = &message,
        .selected = true,
        .loading_frame = 0,
        .blackhole_frame = 0,
        .gpa = gpa,
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
