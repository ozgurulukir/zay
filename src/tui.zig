const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
const at_mention = @import("at_mention.zig");
pub const background_mod = @import("background.zig");
pub const BackgroundDelivery = app_state.BackgroundModalState.BackgroundDelivery;
pub const Agent = agent_mod.Agent;
const pytools = @import("pytools.zig");
const bash_mod = @import("bash.zig");
const search_mod = @import("search.zig");
const codex = @import("codex.zig");
const config_mod = @import("config.zig");
const mcp_mod = @import("mcp/manager.zig");
const openai_compatible_mod = @import("ai/openai_compatible.zig");
const runtime_mod = @import("runtime.zig");
const session_mod = @import("session.zig");
const vcs = @import("vcs.zig");
const skill_mod = @import("skill.zig");
const symbols = @import("symbols.zig");
pub const transcript_mod = @import("transcript.zig");
const CountingAllocator = @import("counting_allocator").CountingAllocator;
pub const agent_worker = @import("tui/agent_worker.zig");
const naming_mod = @import("tui/naming.zig");
const Turn = @import("tui/turn.zig");
const model_catalogue = @import("tui/model_catalogue.zig");
const tui_turn_view = @import("tui/turn_view.zig");
const event_router = @import("tui/event_router.zig");
const command_router = @import("tui/command_router.zig");
const session_switcher = @import("tui/session_switcher.zig");
const app_state = @import("tui/app_state.zig");
const background_delivery = @import("tui/background_delivery.zig");
const turn_lifecycle = @import("tui/turn_lifecycle.zig");
const checkpoint_mod = @import("tui/checkpoint.zig");
const mode_lifecycle = @import("tui/mode_lifecycle.zig");
const input_lifecycle = @import("tui/input_lifecycle.zig");
const transcript_lifecycle = @import("tui/transcript_lifecycle.zig");
pub const Thread = @import("tui/thread.zig");
const tui_metrics = @import("tui/metrics.zig");
const lane_column = @import("tui/lane_column.zig");
const provider_model = @import("tui/provider_model.zig");
const diff_viewer_overlay = @import("tui/diff_viewer_overlay.zig");
const diff_lifecycle = @import("tui/diff_lifecycle.zig");
pub const DiffCounts = diff_lifecycle.DiffCounts;
pub const DiffRefreshOutcome = diff_lifecycle.DiffRefreshOutcome;
const diff_utils = @import("tui/diff_utils.zig");
const lane_lifecycle = @import("tui/lane_lifecycle.zig");
const lanes_util = @import("tui/lanes.zig");
const lifecycle = @import("tui/lifecycle.zig");
const settings_lifecycle = @import("tui/settings_lifecycle.zig");
const settings_widget = @import("tui/widgets/settings.zig");
const overlay = @import("tui/widgets/overlay.zig");
const root_layout = @import("tui/layout.zig");
const root_layout_widget = @import("tui/root_layout.zig");
const input_mod = @import("tui/widgets/input.zig");
const tui_message = @import("tui/widgets/message.zig");
const blackhole = @import("tui/blackhole.zig");
const at_search = @import("tui/widgets/at_search.zig");
const background_jobs = @import("tui/widgets/background_jobs.zig");
const command_panel = @import("tui/widgets/command_panel.zig");
const diff = @import("tui/widgets/diff.zig");
const loading = @import("tui/widgets/loading.zig");
const permission = @import("tui/widgets/permission.zig");
const tx_widget = @import("tui/widgets/transcript.zig");
const diff_viewer = @import("tui/diff_viewer.zig");
const model_loader = @import("tui/model_loader.zig");
const model_cache = @import("tui/model_cache.zig");
const model_picker = @import("tui/widgets/model_picker.zig");
const provider_picker = @import("tui/widgets/provider_picker.zig");
const resume_picker = @import("tui/widgets/resume_picker.zig");
const tree_selector = @import("tui/widgets/tree_selector.zig");
const lanes_picker = @import("tui/widgets/lanes_picker.zig");
const panel = @import("tui/widgets/panel.zig");
const tui_provider = @import("tui/provider_controller.zig");
const tui_status = @import("tui/status.zig");
const tui_style = @import("tui/style.zig");
const logger = @import("logger");
pub const modelsdev = @import("modelsdev.zig");

const ConversationLayout = tui_message.ConversationLayout;
const MessageWidget = tui_message.MessageWidget;
const StylePalette = tui_style.Palette;
const mergedSelectedStyle = tui_style.mergedSelectedStyle;
const messageRowsCached = tui_metrics.messageRowsCached;

const loading_spinners = tui_turn_view.loading_spinners;
const loading_frame_ms = tui_message.loading_frame_ms;
const command_prefix: u8 = '/';
const long_message_scroll_step_rows: u16 = 3;
/// How many recent parent-lane messages ride along as branch-naming context
/// when a lane is forked with `/parallel`.
pub const lane_naming_context_max: usize = 3;
const transcript_nav = @import("tui/transcript_nav.zig");
pub const TranscriptNavigation = transcript_nav.TranscriptNavigation;
const at_search_mod = @import("tui/at_search.zig");
const permission_mod = @import("tui/permission.zig");
const event_callbacks = @import("tui/event_callbacks.zig");
const queue_mod = @import("tui/queue.zig");
pub const MentionSearchKind = at_search_mod.MentionSearchKind;

/// A single-row clickable region on screen (absolute coordinates). Used to
/// hit-test mouse clicks against the pink lanes chip.
pub const ChipRect = struct {
    row: u16,
    col: u16,
    width: u16,

    pub fn contains(self: ChipRect, row: i16, col: i16) bool {
        if (row < 0 or col < 0) return false;
        const r: u16 = @intCast(row);
        const c: u16 = @intCast(col);
        return r == self.row and c >= self.col and c < self.col + self.width;
    }
};

const CheckpointState = enum { unknown, ready, unavailable };
const catalogue_provider_count = config_mod.catalogueProviders().len;

pub const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// All lanes the developer has open, heap-allocated so their addresses stay
    /// stable while live runtimes and (later) worker threads hold references.
    /// Owns the `Thread`s; freed in `deinit`.
    threads: std.ArrayList(*Thread) = .empty,
    /// The lane currently on screen — always one of `threads`. A pointer (not an
    /// index) so every `self.thread.X` site reads/mutates the active lane through
    /// auto-deref, even from a `*const App`.
    thread: *Thread,
    /// When true and there's more than one lane, the transcript area tiles all
    /// lanes as columns; otherwise only the active lane shows full-width
    /// ("fullscreen"). Set true on opening a parallel lane and toggled by
    /// `toggleLaneFullscreen` (Ctrl+L) / clicking the pink lanes chip.
    split: bool = false,
    /// Root-relative row where the input surface is drawn this frame; lets the
    /// input widget translate its local chip position into absolute coordinates
    /// for `lanes_chip_rect`.
    input_surface_row: u16 = 0,
    inputs: app_state.InputState,
    /// Cross-pane navigation cursors and the lane-chip hit-test rect.
    nav: app_state.NavState = .{},
    /// Parsed state for the `/diff` viewer. Populated by `openDiffViewer`, reset
    /// to `.{}` on exit. Only meaningful while `mode == .diff_viewer`.
    diff: diff_viewer.State = .{},
    /// Lazily-resolved readiness of git-shadow snapshotting: `.unknown` until the
    /// first boundary probes git + that the cwd is a repo, then cached.
    /// `.unavailable` keeps the feature inert when git isn't available.
    checkpoint_state: CheckpointState = .unknown,
    /// True once a snapshot has failed and we've told the user. Stops the
    /// per-turn failure notice from repeating every turn while git is wedged.
    checkpoint_warned: bool = false,
    mode: Mode = .normal,
    resume_summaries: std.ArrayList(session_mod.SessionSummary) = .empty,
    resume_folded_projects: std.ArrayList([]u8) = .empty,
    pickers: app_state.PickerStates,
    codex_signed_in: bool = false,
    /// Stored API keys for catalogue providers (label -> key), mirrored from
    /// `~/.config/nova/auth.json`. Drives the picker's [CONNECTED] badges and supplies
    /// keys when (re)building the model catalogue. Owned; freed in `deinit`.
    provider_api_keys: codex.ApiKeyMap = .empty,
    /// Merged models.dev provider registry (builtins + cached/fetched). Owned; freed in `deinit`.
    modelsdev_registry: ?modelsdev.Registry = null,
    /// Backing slice for provider picker's dynamic provider list. Owned; freed in `deinit`.
    dynamics_slice: ?[]const modelsdev.Provider = null,
    /// Inline edit buffer for the provider setup form's API-key field. Owned;
    /// freed in `deinit`.
    provider_key_input: std.ArrayList(u8) = .empty,
    /// Inline edit buffer for the settings panel text fields (system_prompt,
    /// bash_classifier_url). Shared across all edit targets because only one
    /// can be active at a time. Owned; freed in `deinit`.
    settings_text_input: std.ArrayList(u8) = .empty,
    /// Live connectivity per catalogue provider, indexed by `catalogueProviders()`
    /// order. Derived from the model load's per-provider outcome (a key existing
    /// only proves it was entered, not that it works), so the picker badge and
    /// the model picker read the same source and can't disagree. Only
    /// `.connected` shows [CONNECTED]; `.failed` shows [DISCONNECTED].
    conn_status: [catalogue_provider_count]provider_picker.Status = @splat(.unknown),
    /// True while the in-flight model load is a full connected-provider sweep,
    /// so its result recomputes every badge (providers absent from the result
    /// reset to `.unknown`). False for single-provider loads, which touch only
    /// the provider they fetched.
    conn_recompute: bool = false,
    cached_config: config_mod.Config = .{},
    cached_config_owned: bool = false,
    retired_transcripts: std.ArrayList(transcript_mod.Transcript) = .empty,
    /// Visual feedback state (loading spinner, black-hole intro, diff
    /// cache, git label) lives in MetricsState.
    metrics: app_state.MetricsState = .{},
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
    /// Scroll state for the `/lanes` overlay (shared by the `/merge` destination
    /// picker — both use `Mode.lanes`).
    lanes_list: vxfw.ListView = .{
        .children = .{ .slice = &.{} },
        .draw_cursor = false,
        .wheel_scroll = 3,
    },
    /// What the `Mode.lanes` overlay is doing: managing parked worktrees
    /// (`/lanes`, M/X) or choosing a merge destination (`/merge`, Enter).
    parked_lanes: []vcs.WorktreeEntry = &.{},
    /// `.merge_dest`: the source lane (current) whose work is being merged, and
    /// the candidate destination lane indices into `threads`. Owned.
    merge_source_index: usize = 0,
    merge_dest_indices: []usize = &.{},
    input_wrap_width: u16 = 0,
    at_search: app_state.AtSearchState = .closed,
    /// Shared manager for `run_in_background` bash commands. Heap-allocated (so
    /// its address is stable for the agents that borrow it) and owned here; null
    /// on the headless/test path. See `background.zig`.
    background: ?*background_mod.BackgroundManager = null,
    /// `Ctrl+O` background-jobs modal: open flag, selected row, the
    /// `[CANCEL]` button focus hint, and the pending-delivery queue.
    /// Mirrors the permission overlay's lightweight, mode-less state.
    background_modal_state: app_state.BackgroundModalState = .{},
    mcp_manager: mcp_mod.McpManager = undefined,
    /// Completed background jobs awaiting delivery. Held here (not pushed into a
    /// busy transcript) so the notice + model message land only when the owning
    /// lane is idle — "auto-start if idle, queue if in-flight". Owned; freed in
    /// `deinit`.
    pub const ctrl_c_double_press_ms: u32 = 1500;
    pub const Mode = enum { normal, command, session_picker, provider_picker, model_picker, tree_picker, diff_viewer, save_message, lanes, help, settings, mcp };
    pub const LanesPurpose = app_state.NavState.LanesPurpose;
    pub const ModelCatalog = enum { connected_provider, openai_codex };
    pub const ModelScope = model_catalogue.ModelScope;

    pub fn init(io: std.Io, gpa: std.mem.Allocator, agent: *agent_mod.Agent) !App {
        const primary = try gpa.create(Thread);
        errdefer gpa.destroy(primary);
        primary.* = .{ .agent = agent, .worker_context = .{ .io = io, .gpa = agent.gpa } };
        var threads: std.ArrayList(*Thread) = .empty;
        errdefer threads.deinit(gpa);
        try threads.append(gpa, primary);
        return .{
            .io = io,
            .gpa = gpa,
            .threads = threads,
            .thread = primary,
            .inputs = .{ .input = .init(gpa), .palette = .init(gpa), .comment = .init(gpa) },
            .pickers = .{ .tree = .init(gpa) },
            .mcp_manager = mcp_mod.McpManager.init(gpa),
        };
    }

    pub fn initRuntime(
        io: std.Io,
        gpa: std.mem.Allocator,
        runtime: *runtime_mod.AgentRuntime,
        config: config_mod.Config,
    ) !App {
        var app = try init(io, gpa, &runtime.agent);
        app.cached_config = config;
        app.mcp_manager.syncFromConfig(io, &app.cached_config) catch {};
        search_mod.start(gpa, io, runtime.cwd);
        // One shared background manager for the whole session. Heap-allocated so
        // its address stays put as agents (primary + lanes) borrow it.
        const manager = try gpa.create(background_mod.BackgroundManager);
        errdefer gpa.destroy(manager);
        manager.* = .init(io, gpa);
        app.background = manager;
        runtime.agent.background_manager = manager;
        // mcp_manager pointer is set by the caller after `app` settles in its
        // final stack frame — setting it here would dangle when `app` is
        // returned by value.
        // Materialize the project-scoped Python helper package (`.nova/`) so the
        // model's `uv run --project .nova` invocations find it. Best-effort —
        // a failure only degrades the python workflow, never blocks startup.
        pytools.ensureInstalled(gpa, io, runtime.agent.cwd) catch {};
        app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = runtime, .owns = true } };
        app.thread.id = runtime.session_writer.session.id;
        app.codex_signed_in = !runtime.codex_connection_expired and
            (runtime.hasCodexClient() or tui_provider.detectCodexSignIn(gpa, io, runtime.home_dir));
        app.cached_config = config;
        app.cached_config_owned = true;
        return app;
    }

    /// The live lane's runtime, or null when no engine is attached (idle/test).
    /// Engine ownership lives in `thread.engine`; this read accessor replaced the
    /// former `App.runtime` field.
    pub fn liveRuntime(self: *const App) ?*runtime_mod.AgentRuntime {
        return switch (self.thread.engine) {
            .live => |live| live.runtime,
            .idle => null,
        };
    }

    /// The runtime whose allocator, home dir, and prompt/skills template seed
    /// new lanes: the first live lane (the primary, in practice). Null only in
    /// headless/test setups.
    pub fn templateRuntime(self: *const App) ?*runtime_mod.AgentRuntime {
        for (self.threads.items) |lane| {
            switch (lane.engine) {
                .live => |live| return live.runtime,
                else => {},
            }
        }
        return null;
    }

    pub fn bindInputCallbacks(self: *App) void {
        self.inputs.input.userdata = self;
        self.inputs.input.onChange = event_callbacks.inputChanged;
        self.inputs.palette.userdata = self;
        self.inputs.palette.onChange = event_callbacks.paletteInputChanged;
    }

    // --- Accessors for cross-module access (R1: event_router needs these
    // because Zig 0.16 forbids `pub` on struct fields). Pure read/write
    // forwarding — prefer existing semantic methods when one fits. ----------

    pub fn getIo(self: *const App) std.Io {
        return self.io;
    }

    pub fn inputWidget(self: *App) vxfw.Widget {
        return self.inputs.input.widget();
    }

    pub fn inputRealLength(self: *const App) usize {
        return self.inputs.input.buf.realLength();
    }

    pub fn isNormalMode(self: *const App) bool {
        return self.mode == .normal;
    }

    pub fn isDiffViewerMode(self: *const App) bool {
        return self.mode == .diff_viewer;
    }

    pub fn getMode(self: *const App) Mode {
        return self.mode;
    }

    pub fn getTreeState(self: *App) *tree_selector.TreeState {
        return &self.pickers.tree;
    }

    pub fn getProviderPicker(self: *App) *provider_picker.State {
        return &self.pickers.provider;
    }

    pub fn getProviderKeyInput(self: *App) *std.ArrayList(u8) {
        return &self.provider_key_input;
    }

    pub fn getModels(self: *App) *model_catalogue.ModelCatalogue {
        return &self.pickers.models;
    }

    pub fn toggleResumeGlobal(self: *App) void {
        self.nav.resume_global = !self.nav.resume_global;
    }

    pub fn getResumeGlobal(self: *const App) bool {
        return self.nav.resume_global;
    }

    pub fn getResumeSelection(self: *const App) u32 {
        return self.nav.resume_selection;
    }

    pub fn setResumeSelection(self: *App, v: u32) void {
        self.nav.resume_selection = v;
    }

    pub fn getLanesSelection(self: *App) u32 {
        return self.nav.lanes_selection;
    }

    pub fn setLanesSelection(self: *App, v: u32) void {
        self.nav.lanes_selection = v;
    }

    pub fn getLanesPurpose(self: *const App) LanesPurpose {
        return self.nav.lanes_purpose;
    }

    pub fn getCommandSelection(self: *App) u32 {
        return self.nav.command_selection;
    }

    pub fn setCommandSelection(self: *App, v: u32) void {
        self.nav.command_selection = v;
    }

    pub fn popProviderKeyInput(self: *App) void {
        const items = self.provider_key_input.items;
        if (items.len == 0) return;
        var cut = items.len - 1;
        while (cut > 0 and (items[cut] & 0xC0) == 0x80) cut -= 1;
        self.provider_key_input.shrinkRetainingCapacity(cut);
    }

    pub fn isCodexSignedIn(self: *const App) bool {
        return self.codex_signed_in;
    }

    pub fn peekPaletteInput(self: *App) ![]u8 {
        const left = self.inputs.palette.buf.firstHalf();
        const right = self.inputs.palette.buf.secondHalf();
        const out = try self.gpa.alloc(u8, left.len + right.len);
        @memcpy(out[0..left.len], left);
        @memcpy(out[left.len..], right);
        return out;
    }

    pub fn getBackgroundModal(self: *const App) bool {
        return self.background_modal_state.modal;
    }

    pub fn setBackgroundModal(self: *App, v: bool) void {
        self.background_modal_state.modal = v;
    }

    pub fn isAtSearchActive(self: *const App) bool {
        return self.at_search != .closed;
    }

    pub fn atSearchHasResults(self: *const App) bool {
        return self.at_search.results().len > 0;
    }

    pub fn getAtSelection(self: *const App) u32 {
        return switch (self.at_search) {
            .open => |o| o.selection,
            else => 0,
        };
    }

    pub fn setAtSelection(self: *App, v: u32) void {
        if (self.at_search == .open) self.at_search.open.selection = v;
    }

    pub fn atResultsLen(self: *const App) usize {
        return self.at_search.results().len;
    }

    pub fn threadsCount(self: *const App) usize {
        return self.threads.items.len;
    }

    pub fn toggleSelectedTranscriptBlock(self: *App) void {
        self.thread.transcript.toggleSelected();
    }

    pub fn getBlockNav(self: *const App) bool {
        return self.nav.block_nav;
    }

    pub fn setBlockNav(self: *App, v: bool) void {
        self.nav.block_nav = v;
    }

    pub fn getPendingQuitAt(self: *const App) ?std.Io.Timestamp {
        return switch (self.nav.quit) {
            .pending => |ts| ts,
            else => null,
        };
    }

    pub fn setPendingQuitAt(self: *App, v: ?std.Io.Timestamp) void {
        self.nav.quit = if (v) |ts| .{ .pending = ts } else .none;
    }

    pub fn clearPendingQuitAt(self: *App) void {
        if (self.nav.quit == .pending) self.nav.quit = .none;
    }

    pub fn getSplit(self: *const App) bool {
        return self.split;
    }

    pub fn setSplit(self: *App, v: bool) void {
        self.split = v;
    }

    pub fn getLanesChipRect(self: *const App) ?ChipRect {
        return self.nav.lanes_chip_rect;
    }

    pub fn turnStateIsActive(self: *const App) bool {
        return self.thread.turn.state == .active;
    }

    pub fn queuedCount(self: *const App) usize {
        return self.thread.queued.items.len;
    }

    pub fn transcriptHasSelection(self: *const App) bool {
        return self.thread.transcript.selected != null;
    }

    pub fn setThreadAutoScroll(self: *App, v: bool) void {
        self.thread.auto_scroll = v;
    }

    pub fn deinit(self: *App) void {
        lifecycle.deinitApp(self);
    }

    pub fn awaitTurn(self: *App) void {
        if (self.thread.turn_future) |*future| {
            future.await(self.io);
            self.thread.turn_future = null;
        }
    }

    pub fn handleInterrupt(self: *App) !void {
        return turn_lifecycle.handleInterrupt(self);
    }

    pub fn discardAbandonedTurn(self: *App) void {
        turn_lifecycle.discardAbandonedTurn(self);
    }

    pub fn beginSubmit(self: *App) !bool {
        return turn_lifecycle.beginSubmit(self);
    }

    pub fn setLaneTitleIfUnset(self: *App, prompt: []const u8) !void {
        return turn_lifecycle.setLaneTitleIfUnset(self, prompt);
    }

    pub fn formatNoProviderMessage(self: *App) ![]u8 {
        return turn_lifecycle.formatNoProviderMessage(self);
    }

    pub fn resetTurnState(self: *App) void {
        turn_lifecycle.resetTurnState(self);
    }

    pub fn startTurn(self: *App) !void {
        return turn_lifecycle.startTurn(self);
    }

    pub fn restartTurnForQueuedMessages(self: *App) !bool {
        return turn_lifecycle.restartTurnForQueuedMessages(self);
    }

    pub fn laneForAgent(self: *App, agent_ptr: *agent_mod.Agent) ?*Thread {
        for (self.threads.items) |lane| {
            if (lane.agent) |a| {
                if (a == agent_ptr) return lane;
            }
        }
        return null;
    }

    pub fn freeDelivery(self: *App, delivery: *BackgroundDelivery) void {
        return background_delivery.freeDelivery(self, delivery);
    }

    pub fn backgroundActive(self: *App) bool {
        return background_delivery.backgroundActive(self);
    }

    pub fn pollBackgroundJobs(self: *App) !bool {
        return background_delivery.pollBackgroundJobs(self);
    }

    pub fn formatBackgroundNotice(self: *App, job: *const background_mod.BackgroundManager.Finished) ![]u8 {
        return background_delivery.formatBackgroundNotice(self, job);
    }

    pub fn deliverPendingBackground(self: *App) !bool {
        return background_delivery.deliverPendingBackground(self);
    }

    pub fn startDeliveryTurnOnCurrentThread(self: *App) !void {
        return turn_lifecycle.startDeliveryTurnOnCurrentThread(self);
    }

    pub fn runningBackgroundCount(self: *App) usize {
        return background_delivery.runningBackgroundCount(self);
    }

    pub fn toggleBackgroundModal(self: *App) void {
        background_delivery.toggleBackgroundModal(self);
    }

    pub fn handleBackgroundModalKey(self: *App, key: vaxis.Key) bool {
        return background_delivery.handleBackgroundModalKey(self, key);
    }

    pub fn cancelSelectedBackgroundJob(self: *App) void {
        background_delivery.cancelSelectedBackgroundJob(self);
    }

    pub fn advanceLoadingFrame(self: *App) void {
        std.debug.assert(tui_message.loading_frames.len > 0);
        self.metrics.loading_frame +%= 1;
        if (self.metrics.loading_frame >= tui_message.loading_frames.len) self.metrics.loading_frame = 0;
    }

    pub fn advanceBlackholeFrame(self: *App) void {
        self.metrics.blackhole_frame += 1;
        if (self.metrics.blackhole_frame >= blackhole.frame_count) self.metrics.blackhole_frame = 0;
    }

    pub fn permissionPending(self: *App) bool {
        return permission_mod.permissionPending(self);
    }

    pub fn handlePermissionKey(self: *App, key: vaxis.Key) !bool {
        return permission_mod.handlePermissionKey(self, key);
    }

    pub fn resolvePermission(self: *App, decision: agent_worker.ApprovalDecision) !void {
        return permission_mod.resolvePermission(self, decision);
    }

    pub fn applyAgentEvent(self: *App, event: agent_mod.Agent.Event) !bool {
        return turn_lifecycle.applyAgentEvent(self, event);
    }

    pub fn sealCheckpoint(self: *App) checkpoint_mod.SealOutcome {
        return checkpoint_mod.sealCheckpoint(self);
    }

    pub fn noteCheckpointFailure(self: *App) void {
        checkpoint_mod.noteCheckpointFailure(self);
    }

    pub fn noteCheckpointSucceeded(self: *App) void {
        checkpoint_mod.noteCheckpointSucceeded(self);
    }

    pub fn checkpointBoundary(self: *App) void {
        checkpoint_mod.checkpointBoundary(self);
    }

    pub fn checkpointFinishedTurn(self: *App) void {
        checkpoint_mod.checkpointFinishedTurn(self);
    }

    pub fn beginSave(self: *App) !void {
        return checkpoint_mod.beginSave(self);
    }

    pub fn saveActiveLane(self: *App, message: []const u8) !void {
        return checkpoint_mod.saveActiveLane(self, message);
    }

    pub fn ensureCheckpointReady(self: *App) bool {
        return checkpoint_mod.ensureCheckpointReady(self);
    }

    pub fn handleCommandKey(self: *App, key: vaxis.Key) !bool {
        return command_router.handleCommandKey(self, key);
    }

    pub fn handleModelPickerKey(self: *App, key: vaxis.Key) !bool {
        return command_router.ModelPicker.handle(self, key);
    }

    pub fn handleSessionPickerKey(self: *App, key: vaxis.Key) !bool {
        return command_router.SessionPicker.handle(self, key);
    }

    pub fn handleCommandMenuKey(self: *App, key: vaxis.Key) !bool {
        return command_router.CommandMenu.handle(self, key);
    }

    pub fn handleTranscriptKey(self: *App, key: vaxis.Key) !bool {
        return command_router.Transcript.handle(self, key);
    }

    pub fn syncModeWithInput(self: *App, value: []const u8) !void {
        return mode_lifecycle.syncModeWithInput(self, value);
    }

    pub fn cancelMode(self: *App) !bool {
        return mode_lifecycle.cancelMode(self);
    }

    pub fn submitMode(self: *App) !bool {
        return mode_lifecycle.submitMode(self);
    }

    pub fn openCommandMenu(self: *App) !void {
        return mode_lifecycle.openCommandMenu(self);
    }

    pub fn openResumePicker(self: *App) !void {
        return session_switcher.openResumePicker(self);
    }

    pub fn reloadResumeSessions(self: *App) !void {
        return session_switcher.reloadResumeSessions(self);
    }

    pub fn selectedResumeSummary(self: *App) !?*session_mod.SessionSummary {
        return session_switcher.selectedResumeSummary(self);
    }

    pub fn visibleResumeCount(self: *App) !u32 {
        return session_switcher.visibleResumeCount(self);
    }

    pub fn toggleSelectedResumeProject(self: *App) !void {
        return session_switcher.toggleSelectedResumeProject(self);
    }

    pub fn resumeClearFolds(self: *App) void {
        session_switcher.resumeClearFolds(self);
    }

    pub fn resumeClear(self: *App) void {
        session_switcher.resumeClear(self);
    }

    pub fn syncResumeListCursor(self: *App) void {
        session_switcher.syncResumeListCursor(self);
    }

    pub fn reloadTreeNodes(self: *App) !void {
        return session_switcher.reloadTreeNodes(self);
    }

    pub fn navigateToEntry(self: *App, entry_id: []const u8) !void {
        return session_switcher.navigateToEntry(self, entry_id);
    }

    pub fn reportSessionSwitchError(self: *App, err: anyerror) !void {
        return session_switcher.reportSessionSwitchError(self, err);
    }

    pub fn reportConnectionError(self: *App, err: anyerror) !void {
        self.mode = .normal;
        self.clearInput();
        var buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "Could not connect to provider: {s}", .{@errorName(err)}) catch "Could not connect to provider.";
        _ = try self.thread.transcript.append(self.gpa, .agent, "agent", message);
    }

    pub fn switchToNewSession(self: *App) !void {
        return session_switcher.switchToNewSession(self);
    }

    pub fn switchToSession(self: *App, session_id: []const u8) !void {
        return session_switcher.switchToSession(self, session_id);
    }

    pub fn createRuntime(self: *App, cwd: []const u8, session_dir: []const u8, session_id: ?[]const u8) !*runtime_mod.AgentRuntime {
        return session_switcher.createRuntime(self, cwd, session_dir, session_id);
    }

    pub fn clearInput(self: *App) void {
        input_lifecycle.clearInput(self);
    }

    pub fn clearPaletteInput(self: *App) void {
        input_lifecycle.clearPaletteInput(self);
    }

    pub fn peekCommentInput(self: *App) ![]u8 {
        return input_lifecycle.peekCommentInput(self);
    }

    // --- At-search (mention popup) ---------------------------------------

    pub fn updateAtSearch(self: *App) !void {
        return at_search_mod.updateAtSearch(self);
    }

    pub fn acceptAtSelection(self: *App) !void {
        return at_search_mod.acceptAtSelection(self);
    }

    pub fn closeAtSearch(self: *App) void {
        at_search_mod.closeAtSearch(self);
    }

    /// Repo root = the primary lane's working directory (it was launched there).
    /// Null only if the primary somehow has no runtime (headless/test).
    pub fn repoRoot(self: *const App) ?[]const u8 {
        return switch (self.threads.items[0].engine) {
            .live => |live| live.runtime.cwd,
            .idle => null,
        };
    }

    // --- Queue management ------------------------------------------------

    pub fn enqueueSubmit(self: *App) !bool {
        return queue_mod.enqueueSubmit(self);
    }

    pub fn selectPrevQueued(self: *App) void {
        queue_mod.selectPrevQueued(self);
    }

    pub fn selectNextQueued(self: *App) void {
        queue_mod.selectNextQueued(self);
    }

    pub fn steerSelectedQueued(self: *App) void {
        queue_mod.steerSelectedQueued(self);
    }

    pub fn flushQueuedUserMessagesToTranscript(self: *App, count: u32) !void {
        return queue_mod.flushQueuedUserMessagesToTranscript(self, count);
    }

    pub fn appendSkillInvocationsToTranscript(self: *App, prompt: []const u8) !void {
        return queue_mod.appendSkillInvocationsToTranscript(self, prompt);
    }

    pub fn clearQueuedUserMessages(self: *App) void {
        queue_mod.clearQueuedUserMessages(self);
    }

    pub fn createParallelLane(self: *App) !void {
        try lifecycle.createParallelLane(self);
    }

    pub fn captureLaneContext(self: *App, max: usize) ![][]u8 {
        return lane_lifecycle.captureLaneContext(self, max);
    }

    pub fn scheduleLaneNaming(self: *App, lane: *Thread, first_message: []const u8) !void {
        return lane_lifecycle.scheduleLaneNaming(self, lane, first_message);
    }

    pub fn drainLaneNaming(self: *App) !bool {
        return lane_lifecycle.drainLaneNaming(self);
    }

    pub fn cancelLaneNaming(self: *App, lane: *Thread) void {
        lane_lifecycle.cancelLaneNaming(self, lane);
    }

    pub fn namingActive(self: *const App) bool {
        return lane_lifecycle.namingActive(self);
    }

    pub fn reportLaneError(self: *App, err: anyerror) !void {
        return lane_lifecycle.reportLaneError(self, err);
    }

    pub fn anyTurnActive(self: *const App) bool {
        return lane_lifecycle.anyTurnActive(self);
    }

    pub fn activeIndex(self: *const App) usize {
        return lane_lifecycle.activeIndex(self);
    }

    pub fn cycleLane(self: *App, delta: i32) void {
        lane_lifecycle.cycleLane(self, delta);
    }

    pub fn switchToNextLane(self: *App) void {
        lane_lifecycle.switchToNextLane(self);
    }

    pub fn toggleLaneFullscreen(self: *App) void {
        lane_lifecycle.toggleLaneFullscreen(self);
    }

    pub fn closeActiveLane(self: *App) !void {
        return lane_lifecycle.closeActiveLane(self);
    }

    pub fn createMergePicker(self: *App) !void {
        return lane_lifecycle.createMergePicker(self);
    }

    pub fn confirmMergeDest(self: *App) !void {
        return lane_lifecycle.confirmMergeDest(self);
    }

    pub fn openLanesPicker(self: *App) !void {
        return lane_lifecycle.openLanesPicker(self);
    }

    pub fn mergeSelectedParked(self: *App) !void {
        return lane_lifecycle.mergeSelectedParked(self);
    }

    pub fn deleteSelectedParked(self: *App) !void {
        return lane_lifecycle.deleteSelectedParked(self);
    }

    pub fn laneEntryCount(self: *const App) u32 {
        return lane_lifecycle.laneEntryCount(self);
    }

    pub fn clearLanesState(self: *App) void {
        lane_lifecycle.clearLanesState(self);
    }

    pub fn buildLaneEntries(self: *App, arena: std.mem.Allocator) ![]lanes_picker.Entry {
        return lane_lifecycle.buildLaneEntries(self, arena);
    }

    pub fn handleLanesKey(self: *App, key: vaxis.Key) !bool {
        return lane_lifecycle.handleLanesKey(self, key);
    }

    pub fn installRuntime(self: *App, runtime: *runtime_mod.AgentRuntime) !void {
        return transcript_lifecycle.installRuntime(self, runtime);
    }

    pub fn clearConversation(self: *App) !void {
        return transcript_lifecycle.clearConversation(self);
    }

    pub fn rebuildTranscriptFromAgent(self: *App) !void {
        return transcript_lifecycle.rebuildTranscriptFromAgent(self);
    }

    pub fn resumedToolTitle(self: *App, message: ai.ChatMessage) ![]u8 {
        return transcript_lifecycle.resumedToolTitle(self, message);
    }

    pub fn peekInput(self: *App) ![]u8 {
        return input_lifecycle.peekInput(self);
    }

    pub fn inputTextRows(self: *App, ctx: vxfw.DrawContext, width: u16) !u16 {
        return input_lifecycle.inputTextRows(self, ctx, width);
    }

    pub fn insertInputNewline(self: *App) !void {
        return input_lifecycle.insertInputNewline(self);
    }

    pub fn moveInputCursorVertical(self: *App, move: input_mod.VerticalMove) !bool {
        return input_lifecycle.moveInputCursorVertical(self, move);
    }

    pub const HistoryDirection = Thread.HistoryDirection;

    pub fn navigatePromptHistory(self: *App, direction: HistoryDirection) !bool {
        return input_lifecycle.navigatePromptHistory(self, direction);
    }

    pub fn selectionIsLastMessage(self: *const App) bool {
        return transcript_nav.selectionIsLastMessage(self);
    }

    pub fn diffCountsVisible(self: *const App) bool {
        return diff_lifecycle.diffCountsVisible(self);
    }

    pub fn refreshDiffCounts(self: *App) !bool {
        return diff_lifecycle.refreshDiffCounts(self);
    }

    pub fn scheduleDiffRefresh(self: *App) !void {
        return diff_lifecycle.scheduleDiffRefresh(self);
    }

    pub fn cancelDiffRefresh(self: *App) void {
        diff_lifecycle.cancelDiffRefresh(self);
    }

    pub fn drainDiffRefresh(self: *App) !bool {
        return diff_lifecycle.drainDiffRefresh(self);
    }

    pub fn jumpTranscriptToBottom(self: *App) void {
        transcript_nav.jumpTranscriptToBottom(self);
    }

    pub fn updateMouseAutoScroll(self: *App) void {
        transcript_nav.updateMouseAutoScroll(self);
    }

    pub fn navigateTranscript(self: *App, direction: transcript_nav.TranscriptNavigation) bool {
        return transcript_nav.navigateTranscript(self, direction);
    }

    pub fn selectedMessageIsLong(self: *const App) bool {
        return transcript_nav.selectedMessageIsLong(self);
    }

    pub fn selectedMessageCanScrollDown(self: *const App) bool {
        return transcript_nav.selectedMessageCanScrollDown(self);
    }
};

pub fn nextIndex(current: u32, count: u32) u32 {
    if (count == 0) return 0;
    if (current + 1 >= count) return 0;
    return current + 1;
}

pub fn previousIndex(current: u32, count: u32) u32 {
    if (count == 0) return 0;
    if (current == 0) return count - 1;
    return current - 1;
}

pub fn run(
    init: std.process.Init,
    runtime: *runtime_mod.AgentRuntime,
    config: config_mod.Config,
    gpa: std.mem.Allocator,
) !void {
    // Allocator is provided by root.zig as `PageAllocator`. Thread-safe and
    // correct, but each allocation maps a whole page — traded off to avoid
    // `SmpAllocator`'s multi-threaded free-list corruption panic in Zig 0.16.
    // Must match `tui_gpa` in root.zig since `runtime`/`cached_config` cross
    // the seam and are freed in `App.deinit`.
    var tty_buffer: [8192]u8 = undefined;
    var fw_app = try vxfw.App.init(init.io, gpa, init.environ_map, &tty_buffer);
    defer fw_app.deinit();

    var app = try App.initRuntime(init.io, gpa, runtime, config);
    // Set the MCP manager pointer now that `app` is in its final stack frame.
    // Inside initRuntime, &app.mcp_manager would dangle after return-by-value.
    runtime.agent.mcp_manager = &app.mcp_manager;
    app.bindInputCallbacks();
    defer app.deinit();

    // Load stored catalogue-provider keys from auth.json up front so the first
    // model-catalogue build includes every connected provider. Without this the
    // keys only loaded when the provider picker was opened, so a cold model
    // picker silently skipped (and then cached) every keyed provider.
    provider_model.refreshProviderApiKeys(&app) catch {};

    // Rebuild transcript from agent when resuming a session (the agent was
    // rehydrated with messages in runtime.zig initSession). For a new session
    // the rebuild is a no-op — agent only has system messages, which are
    // skipped — so we fall through to the logo.
    try app.rebuildTranscriptFromAgent();
    if (app.thread.transcript.messages.items.len == 0) {
        // The logo message is a marker: the black-hole animation renders its
        // frames directly (see tui/blackhole.zig), so the body is intentionally
        // empty.
        _ = try app.thread.transcript.append(gpa, .logo, "logo", "");
    }

    app.metrics.git_label = diff_utils.loadGitLabel(gpa, init.io, runtime.cwd) catch "";
    _ = app.refreshDiffCounts() catch false;

    var root: RootWidget = .{ .app = &app };
    try fw_app.run(root.widget(), .{});
}

pub const RootWidget = struct {
    app: *App,
    spinner_tick_accum: u32 = 0,
    blackhole_tick_accum: u32 = 0,
    diff_tick_accum: u32 = 0,
    diff_refresh_pending: bool = false,

    pub fn widget(self: *RootWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .captureHandler = captureEvent,
            .eventHandler = handleEvent,
            .drawFn = drawRoot,
        };
    }

    fn captureEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        try event_router.captureEvent(self.app, self, ctx, event);
    }

    fn handleEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        switch (event) {
            .tick => try lifecycle.handleTick(self, ctx),
            else => {},
        }
    }

    pub const drain_tick_ms: u32 = 30;
    pub const spinner_tick_threshold_ms: u32 = loading_frame_ms;
    pub const diff_tick_threshold_ms: u32 = 300;

    fn handleTick(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        try lifecycle.handleTick(self, ctx);
    }

    pub fn ensureTick(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        try lifecycle.ensureTick(self, ctx);
    }

    pub fn submit(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        try lifecycle.submit(self, ctx);
    }

    pub fn syncFocus(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        try lifecycle.syncFocus(self, ctx);
    }

    fn drainAgentEvents(self: *RootWidget, ctx: *vxfw.EventContext) !bool {
        return lifecycle.drainAgentEvents(self, ctx);
    }

    fn drawRoot(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        return root_layout_widget.drawRoot(self.app, self.widget(), ctx);
    }

    /// Draw one lane's transcript as a bordered column for split view. The
    /// border label marks the lane (● active / ○ background) and the active
    /// column's border is undimmed.
    // --- Diff viewer ------------------------------------------------------

    pub fn handleDiffViewerEvent(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        try lifecycle.handleDiffViewerEvent(self, ctx, key);
    }

    fn handleDiffBrowseKey(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        try lifecycle.handleDiffBrowseKey(self, ctx, key);
    }

    fn handleDiffSearchKey(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        try lifecycle.handleDiffSearchKey(self, ctx, key);
    }

    fn handleDiffCommentKey(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        try lifecycle.handleDiffCommentKey(self, ctx, key);
    }

    fn closeDiff(self: *RootWidget, ctx: *vxfw.EventContext, send: bool) !void {
        try lifecycle.closeDiff(self, ctx, send);
    }
};

pub fn shouldOpenCommandMenuForSlash(app: *const App, key: vaxis.Key) bool {
    return mode_lifecycle.shouldOpenCommandMenuForSlash(app, key);
}

pub const Command = enum { connect, model, mcp, new, resume_session, timeline, diff, parallel, save, close, merge, lanes, clear, compact, status, help, export_session, settings, copy, paste, exit_cmd };
/// `multi_lane` commands act on another lane, so they're hidden from the palette
/// (and unresolvable) until more than one lane exists.
pub const CommandEntry = struct { name: []const u8, command: Command, description: []const u8 = "", category: []const u8 = "", multi_lane: bool = false };
pub const commands = [_]CommandEntry{
    .{ .name = "Connect", .command = .connect, .description = "Configure AI provider & API key", .category = "AI & MODELS" },
    .{ .name = "Models", .command = .model, .description = "Select model & reasoning effort", .category = "AI & MODELS" },
    .{ .name = "Mcp", .command = .mcp, .description = "Model Context Protocol status & servers", .category = "AI & MODELS" },
    .{ .name = "Settings", .command = .settings, .description = "View and edit configuration settings", .category = "AI & MODELS" },
    .{ .name = "New", .command = .new, .description = "Start a fresh session", .category = "SESSION" },
    .{ .name = "Resume", .command = .resume_session, .description = "Resume a past session", .category = "SESSION" },
    .{ .name = "Timeline", .command = .timeline, .description = "Browse session tree history", .category = "SESSION" },
    .{ .name = "Clear", .command = .clear, .description = "Clear current transcript view", .category = "SESSION" },
    .{ .name = "Compact", .command = .compact, .description = "Compact session context history", .category = "SESSION" },
    .{ .name = "Export", .command = .export_session, .description = "Save conversation transcript as Markdown", .category = "SESSION" },
    .{ .name = "Copy", .command = .copy, .description = "Copy selected transcript message to clipboard", .category = "SESSION" },
    .{ .name = "Paste", .command = .paste, .description = "Paste text from clipboard into prompt", .category = "SESSION" },
    .{ .name = "Diff", .command = .diff, .description = "View git diff & add comments", .category = "GIT & WORKTREE" },
    .{ .name = "Parallel", .command = .parallel, .description = "Fork worktree into parallel lane", .category = "GIT & WORKTREE" },
    .{ .name = "Save", .command = .save, .description = "Save working copy snapshot", .category = "GIT & WORKTREE" },
    .{ .name = "Merge", .command = .merge, .description = "Merge lane into target", .category = "GIT & WORKTREE", .multi_lane = true },
    .{ .name = "Close", .command = .close, .description = "Park and close active lane", .category = "GIT & WORKTREE", .multi_lane = true },
    .{ .name = "Lanes", .command = .lanes, .description = "Manage parked worktree lanes", .category = "GIT & WORKTREE" },
    .{ .name = "Status", .command = .status, .description = "Show agent runtime & git state", .category = "SYSTEM" },
    .{ .name = "Help", .command = .help, .description = "Show keyboard shortcuts & guide", .category = "SYSTEM" },
    .{ .name = "Exit", .command = .exit_cmd, .description = "Quit Nova agent", .category = "SYSTEM" },
    .{ .name = "Quit", .command = .exit_cmd, .description = "Quit Nova agent", .category = "SYSTEM" },
};

pub fn openMcp(app: *App) void {
    app.mode = .mcp;
    app.pickers.mcp.reset();
    if (app.liveRuntime()) |runtime| {
        app.mcp_manager.syncFromConfigEx(app.gpa, app.io, &app.cached_config, runtime.home_dir, runtime.cwd);
    } else {
        app.mcp_manager.syncFromConfig(app.io, &app.cached_config) catch {};
    }
    app.clearInput();
    app.clearPaletteInput();
}

pub fn closeMcp(app: *App) void {
    app.mode = .normal;
    app.clearInput();
    app.clearPaletteInput();
}

/// Whether `entry` should appear in the palette given the current lane count.
pub fn commandVisible(app: *const App, entry: CommandEntry) bool {
    if (entry.multi_lane and app.threads.items.len < 2) return false;
    return true;
}

fn resolveCommand(app: *App, filter: []const u8) ?Command {
    return mode_lifecycle.resolveCommand(app, filter);
}

pub fn commandMatchesCount(app: *App) u32 {
    return mode_lifecycle.commandMatchesCount(app);
}

pub fn commandMatchesCountForFilter(app: *const App, filter: []const u8) u32 {
    return mode_lifecycle.commandMatchesCountForFilter(app, filter);
}

/// Builds the floating `@`-results panel from app state. Presentational only;
/// the main input keeps focus.
pub const AtSearchWidget = struct {
    app: *App,

    pub fn widget(self: *AtSearchWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawAtSearch };
    }

    fn drawAtSearch(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *AtSearchWidget = @ptrCast(@alignCast(ptr));
        const kind = self.app.at_search.kind();
        const indexing = self.app.at_search == .indexing;
        const sel = self.app.getAtSelection();
        const query: []const u8 = switch (self.app.at_search) {
            .open => |o| o.query,
            else => "",
        };
        var content: at_search.Content = .{
            .results = self.app.at_search.results(),
            .selection = sel,
            .query = query,
            .indexing = indexing,
            .sigil = if (kind == .file) '@' else '$',
            .title = if (kind == .file) "Files" else "Skills",
        };
        return content.widget().draw(ctx);
    }
};

pub fn writeBorderTextEndingAt(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, end_col: u16, text: []const u8, style: vaxis.Style) u16 {
    return panel.writeBorderTextEndingAt(surface, ctx, row, end_col, text, style);
}

pub fn writeBorderLabelRight(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, text: []const u8, style: vaxis.Style) void {
    panel.writeBorderLabelRight(surface, ctx, row, text, style);
}

pub fn modelPickerScope(scope: App.ModelScope) model_picker.Scope {
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

pub fn reasoningOptions() []const model_picker.ReasoningOption {
    return &reasoning_options;
}

// --- Settings delegates (settings_lifecycle forwarding) -------------------

pub fn openSettings(app: *App) void {
    settings_lifecycle.openSettings(app);
}

pub fn closeSettings(app: *App) void {
    settings_lifecycle.closeSettings(app);
}

pub fn saveSettings(app: *App) !bool {
    return settings_lifecycle.saveSettings(app);
}

pub fn cancelSettings(app: *App) void {
    settings_lifecycle.cancelSettings(app);
}

pub fn submitSettings(app: *App) !void {
    try settings_lifecycle.submitSettings(app);
}

pub fn clearSettingsField(app: *App) void {
    settings_lifecycle.clearCurrentField(app);
}

pub fn handleSettingsTextEditKey(app: *App, key: vaxis.Key) !bool {
    return settings_lifecycle.handleTextEditKey(app, key);
}

test "parse diff counts sums numstat and skips binary" {
    const counts = diff_utils.parseDiffCounts(
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

    input_mod.writeDiffCounts(&surface, ctx, .{ .additions = 1, .deletions = 12 });

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
    const normal = root_layout.rootLayout(30, false, 1, false, false);
    const picker = root_layout.rootLayout(30, true, 1, false, false);

    try std.testing.expectEqual(normal.input_row, picker.input_row);
    try std.testing.expectEqual(normal.transcript_height, picker.transcript_height);
    try std.testing.expectEqual(@as(u16, 19), picker.panel_row);
    try std.testing.expectEqual(@as(u16, 7), picker.panel_height);
}

test "root layout clamps panel above input on short screens" {
    const layout = root_layout.rootLayout(8, true, 1, false, false);

    try std.testing.expectEqual(@as(u16, 4), layout.input_height);
    try std.testing.expectEqual(@as(u16, 4), layout.transcript_height);
    try std.testing.expectEqual(@as(u16, 4), layout.panel_height);
    try std.testing.expectEqual(@as(u16, 0), layout.panel_row);
    try std.testing.expectEqual(@as(u16, 4), layout.input_row);
}

test "root layout grows the input as text rows increase" {
    const one = root_layout.rootLayout(30, false, 1, false, false);
    try std.testing.expectEqual(@as(u16, 4), one.input_height);
    try std.testing.expectEqual(@as(u16, 26), one.transcript_height);

    const three = root_layout.rootLayout(30, false, 3, false, false);
    try std.testing.expectEqual(@as(u16, 6), three.input_height);
    try std.testing.expectEqual(@as(u16, 24), three.transcript_height);

    // A short screen still leaves the transcript some room.
    const tight = root_layout.rootLayout(10, false, 6, false, false);
    try std.testing.expectEqual(@as(u16, 7), tight.input_height);
    try std.testing.expectEqual(@as(u16, 3), tight.transcript_height);
}

test "root layout reserves a row for the queued-message line" {
    // A queued (steered) message draws an extra line above the input border, so
    // the input region must grow by one row — otherwise the hint + diff counts
    // get squeezed out (regression: they vanished after sending mid-generation).
    const plain = root_layout.rootLayout(30, false, 1, false, false);
    const queued = root_layout.rootLayout(30, false, 1, false, true);
    try std.testing.expectEqual(plain.input_height + 1, queued.input_height);
}

test "input text rows track the line count" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
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

    try app.inputs.input.insertSliceAtCursor("a\nb\nc");
    try std.testing.expectEqual(@as(u16, 3), try app.inputTextRows(ctx, 80));

    try app.inputs.input.insertSliceAtCursor("defgh");
    try std.testing.expectEqual(@as(u16, 4), try app.inputTextRows(ctx, 4));

    // The input keeps growing with the line count (no fixed cap).
    try app.inputs.input.insertSliceAtCursor("\n\n\n\n\n\n\n\n");
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
    try std.testing.expectEqual(@as(u16, 2), input_mod.wrappedTextRows(ctx, text, 10));

    const cursor = input_mod.wrappedTextPositionAt(ctx, text, "hello wo".len, 10);
    try std.testing.expectEqual(@as(u16, 1), cursor.row);
    try std.testing.expectEqual(@as(u16, 2), cursor.col);
}

test "down returns to multiline input after overshooting above top line" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    try app.inputs.input.insertSliceAtCursor("top\nmiddle\nbottom");

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try std.testing.expectEqualStrings("top", app.inputs.input.buf.firstHalf());

    // One more Up leaves the input for block navigation.
    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try std.testing.expect(app.nav.block_nav);

    // With no transcript block selected, Down must return to the multiline input.
    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expect(!app.nav.block_nav);
    try std.testing.expectEqualStrings("top\nmid", app.inputs.input.buf.firstHalf());

    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expectEqualStrings("top\nmiddle\nbot", app.inputs.input.buf.firstHalf());
}

test "arrow up and down move the input cursor between lines" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Cursor ends on the third line at column 2 ("ca|t").
    try app.inputs.input.insertSliceAtCursor("fox\nox\ncat");
    app.inputs.input.cursorLeft(); // between "ca" and "t"

    // Up keeps the column, clamped to the shorter middle line ("ox" -> end).
    try std.testing.expect(try app.moveInputCursorVertical(.up));
    try std.testing.expectEqualStrings("fox\nox", app.inputs.input.buf.firstHalf());

    // Up again lands at column 2 of the first line ("fo|x").
    try std.testing.expect(try app.moveInputCursorVertical(.up));
    try std.testing.expectEqualStrings("fo", app.inputs.input.buf.firstHalf());

    // Already on the first line: no move, caller falls back to transcript nav.
    try std.testing.expect(!(try app.moveInputCursorVertical(.up)));

    // Down returns to the middle line at the same column ("ox" -> end).
    try std.testing.expect(try app.moveInputCursorVertical(.down));
    try std.testing.expectEqualStrings("fox\nox", app.inputs.input.buf.firstHalf());

    // Down to the last line, then no further move.
    try std.testing.expect(try app.moveInputCursorVertical(.down));
    try std.testing.expectEqualStrings("fox\nox\nca", app.inputs.input.buf.firstHalf());
    try std.testing.expect(!(try app.moveInputCursorVertical(.down)));
}

test "vertical navigation follows soft-wrapped visual rows" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // A single long line with no manual breaks. Wrapped at width 10 it spans
    // two visual rows ("abcdefghij" / "klmnopqrst"), so the cursor must move by
    // visual row — the old '\n'-only logic was stuck on one logical line.
    try app.inputs.input.insertSliceAtCursor("abcdefghijklmnopqrst");
    app.input_wrap_width = 10;

    // Cursor sits at the end (second visual row). Up moves to the first row.
    try std.testing.expect(try app.moveInputCursorVertical(.up));
    try std.testing.expectEqualStrings("abcdefghij", app.inputs.input.buf.firstHalf());

    // Already on the first visual row: no move, hand off to block nav.
    try std.testing.expect(!(try app.moveInputCursorVertical(.up)));

    // Down returns to the second visual row at the same column.
    try std.testing.expect(try app.moveInputCursorVertical(.down));
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", app.inputs.input.buf.firstHalf());
    try std.testing.expect(!(try app.moveInputCursorVertical(.down)));
}

test "global resume sorting groups projects by latest session" {
    var summaries = [_]session_mod.SessionSummary{
        .{ .id = @constCast("old-b"), .title = null, .cwd = @constCast("/repo/b"), .created_at_ms = 0, .updated_at_ms = 10, .leaf_entry_id = null, .model_provider = null, .model_id = null },
        .{ .id = @constCast("new-a"), .title = null, .cwd = @constCast("/repo/a"), .created_at_ms = 0, .updated_at_ms = 30, .leaf_entry_id = null, .model_provider = null, .model_id = null },
        .{ .id = @constCast("new-b"), .title = null, .cwd = @constCast("/repo/b"), .created_at_ms = 0, .updated_at_ms = 40, .leaf_entry_id = null, .model_provider = null, .model_id = null },
        .{ .id = @constCast("old-a"), .title = null, .cwd = @constCast("/repo/a"), .created_at_ms = 0, .updated_at_ms = 20, .leaf_entry_id = null, .model_provider = null, .model_id = null },
    };

    const context: []const session_mod.SessionSummary = summaries[0..];
    std.mem.sort(session_mod.SessionSummary, summaries[0..], context, session_switcher.resumeSummaryLessThan);

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
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.thread.turn.submit();
    app.mode = .provider_picker;

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });

    try std.testing.expectEqual(App.Mode.command, app.mode);
    try std.testing.expectEqual(Turn.State.active, app.thread.turn.state);
}

test "ctrl-c clears a non-empty input instead of arming quit" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    try app.inputs.input.insertSliceAtCursor("draft message");

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    const ctrl_c: vxfw.Event = .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } };
    try RootWidget.captureEvent(&root, &ctx, ctrl_c);

    // The input is cleared and the quit sequence is not armed.
    try std.testing.expectEqual(@as(usize, 0), app.inputs.input.buf.realLength());
    try std.testing.expect(app.nav.quit == .none);
    try std.testing.expect(!ctx.quit);
}

test "down past the last block re-enters the input" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    // Tall viewport so the short messages never count as scrollable.
    app.thread.transcript_view_width = 80;
    app.thread.transcript_view_height = 100;

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "two");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "three");
    // Following the tail, the last block is selected.
    try std.testing.expectEqual(@as(?u32, 2), app.thread.transcript.selected);

    // In block navigation, up walks to an earlier block.
    app.nav.block_nav = true;
    _ = try app.handleTranscriptKey(.{ .codepoint = vaxis.Key.up });
    try std.testing.expectEqual(@as(?u32, 1), app.thread.transcript.selected);

    // Down walks back toward the last block, still navigating blocks.
    _ = try app.handleTranscriptKey(.{ .codepoint = vaxis.Key.down });
    try std.testing.expectEqual(@as(?u32, 2), app.thread.transcript.selected);
    try std.testing.expect(app.nav.block_nav);

    // Down again on the last block hands control back to the input.
    _ = try app.handleTranscriptKey(.{ .codepoint = vaxis.Key.down });
    try std.testing.expect(!app.nav.block_nav);
    try std.testing.expectEqual(@as(?u32, 2), app.thread.transcript.selected);
}

test "down past the last block moves into multiline input" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.thread.transcript_view_width = 80;
    app.thread.transcript_view_height = 100;

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one");
    try app.inputs.input.insertSliceAtCursor("top\nmiddle");
    // Put the cursor on the top line, just before the newline. Re-entering
    // from block navigation should step down into the input line below.
    app.inputs.input.buf.moveGapLeft("\nmiddle".len);
    app.nav.block_nav = true;

    try std.testing.expect(try app.handleTranscriptKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expect(!app.nav.block_nav);
    try std.testing.expectEqualStrings("top\nmid", app.inputs.input.buf.firstHalf());
}

test "shift enter inserts a newline instead of submitting" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    try app.inputs.input.insertSliceAtCursor("line one");
    try app.insertInputNewline();
    try app.inputs.input.insertSliceAtCursor("line two");

    const value = try app.peekInput();
    defer gpa.free(value);
    try std.testing.expectEqualStrings("line one\nline two", value);
}

test "firstVisibleLine keeps the cursor line within the window" {
    try std.testing.expectEqual(@as(u16, 0), input_mod.firstVisibleLine(0, 3, 4));
    try std.testing.expectEqual(@as(u16, 0), input_mod.firstVisibleLine(3, 4, 4));
    // Cursor past the fold pins to the bottom edge.
    try std.testing.expectEqual(@as(u16, 1), input_mod.firstVisibleLine(4, 10, 4));
    try std.testing.expectEqual(@as(u16, 6), input_mod.firstVisibleLine(9, 10, 4));
}

test "root overlay host does not paint outside panel" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
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
    try std.testing.expectEqual(@as(u16, 64), panel_surface.size.width);
    try std.testing.expectEqual(@as(u16, 16), panel_surface.size.height);
}

test "provider setup form renders for opencode zen without crashing" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .provider_picker;
    app.pickers.provider.stage = .form;
    app.pickers.provider.form_handle = .{ .builtin = .opencode_zen };

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
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "two");
    app.thread.transcript.selected = 0;
    app.thread.auto_scroll = false;
    app.thread.transcript_list.scroll.has_more = false;

    app.updateMouseAutoScroll();

    try std.testing.expect(!app.thread.auto_scroll);
}

test "shift down jumps to conversation bottom" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "two");
    _ = try app.thread.transcript.append(gpa, .status, "status", "loading");
    app.thread.transcript.selected = 0;
    app.thread.auto_scroll = false;

    try std.testing.expect(try app.handleTranscriptKey(.{ .codepoint = vaxis.Key.down, .mods = .{ .shift = true } }));

    try std.testing.expectEqual(@as(?u32, 1), app.thread.transcript.selected);
    try std.testing.expect(app.thread.auto_scroll);
}

test "down scrolls through selected long message before moving selection" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "next");
    app.thread.transcript.selected = 0;
    app.thread.transcript_view_width = 80;
    app.thread.transcript_view_height = 4;

    const scrolled = app.navigateTranscript(.next);

    try std.testing.expect(scrolled);
    try std.testing.expectEqual(@as(?u32, 0), app.thread.transcript.selected);
    try std.testing.expectEqual(@as(u32, 0), app.thread.transcript_list.scroll.top);
    try std.testing.expect(app.thread.transcript_list.scroll.offset > 0);
}

test "long message scroll uses a small fixed step" {
    try std.testing.expectEqual(@as(u16, 1), transcript_nav.scrollStepRows(1));
    try std.testing.expectEqual(@as(u16, 2), transcript_nav.scrollStepRows(2));
    try std.testing.expectEqual(@as(u16, 3), transcript_nav.scrollStepRows(20));
}

test "down at latest long message bottom does not loop to top" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    app.thread.transcript.selected = 0;
    app.thread.transcript_view_width = 80;
    app.thread.transcript_view_height = 4;
    const offset = messageRowsCached(&app.thread.transcript.messages.items[0], ConversationLayout.contentWidth(app.thread.transcript_view_width)) - app.thread.transcript_view_height;
    transcript_nav.setSelectedMessageOffset(&app, 0, offset);

    const scrolled = app.navigateTranscript(.next);

    try std.testing.expect(!scrolled);
    try std.testing.expectEqual(@as(?u32, 0), app.thread.transcript.selected);
    try std.testing.expectEqual(@as(i17, @intCast(offset)), app.thread.transcript_list.scroll.offset);
}

test "down moves after selected long message bottom is visible" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "next");
    app.thread.transcript.selected = 0;
    app.thread.transcript_view_width = 80;
    app.thread.transcript_view_height = 4;
    transcript_nav.setSelectedMessageOffset(&app, 0, messageRowsCached(&app.thread.transcript.messages.items[0], ConversationLayout.contentWidth(app.thread.transcript_view_width)) - app.thread.transcript_view_height);

    const scrolled = app.navigateTranscript(.next);

    try std.testing.expect(!scrolled);
    try std.testing.expectEqual(@as(?u32, 1), app.thread.transcript.selected);
}

test "up enters selected long message at bottom" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "next");
    app.thread.transcript.selected = 1;
    app.thread.transcript_view_width = 80;
    app.thread.transcript_view_height = 4;

    const scrolled = app.navigateTranscript(.previous);

    try std.testing.expect(!scrolled);
    try std.testing.expectEqual(@as(?u32, 0), app.thread.transcript.selected);
    try std.testing.expect(app.thread.transcript_list.scroll.offset > 0);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var transcript_widget: tx_widget.TranscriptWidget = .{ .app = &app, .thread = app.thread };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 6 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    _ = try transcript_widget.widget().draw(ctx);

    try std.testing.expect(app.thread.transcript_list.scroll.offset > 0);
}

test "begin submit clears input and starts a turn awaiting output" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("hello");
    try std.testing.expect(try app.beginSubmit());

    try std.testing.expectEqual(@as(usize, 0), app.inputs.input.buf.firstHalf().len);
    try std.testing.expectEqual(@as(usize, 0), app.inputs.input.buf.secondHalf().len);
    // The user message is the only transcript entry; the loading spinner is never
    // stored as a message.
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqualStrings("hello", app.thread.transcript.messages.items[0].mirror().body);
    try std.testing.expect(app.thread.turn_view.awaitingOutput());
    try std.testing.expectEqual(Turn.State.active, app.thread.turn.state);
    try std.testing.expectEqual(@as(u32, 0), app.thread.transcript.selected.?);
}

test "awaiting turn draws loading outside the transcript list" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .user, "you", "hello");
    app.thread.turn_view.awaitModel();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var root_widget: RootWidget = .{ .app = &app };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 10 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try root_widget.widget().draw(ctx);

    try std.testing.expectEqual(@as(usize, 3), surface.children.len);
    try std.testing.expectEqual(@as(?u32, 1), app.thread.transcript_list.item_count);
    try std.testing.expectEqual(@as(u32, 0), app.thread.transcript_list.cursor);
    try std.testing.expectEqual(root_layout.rootLayout(10, false, 1, true, false).loading_row, surface.children[1].origin.row);
}

test "awaiting turn preserves selected long message inner scroll" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    app.thread.transcript.selected = 0;
    app.thread.auto_scroll = false;
    app.thread.turn_view.awaitModel();
    transcript_nav.setSelectedMessageOffset(&app, 0, 3);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var root_widget: RootWidget = .{ .app = &app };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 10 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    _ = try root_widget.widget().draw(ctx);

    try std.testing.expectEqual(@as(u32, 0), app.thread.transcript_list.cursor);
    try std.testing.expectEqual(@as(u32, 0), app.thread.transcript_list.scroll.top);
    try std.testing.expectEqual(@as(i17, 3), app.thread.transcript_list.scroll.offset);
}

test "begin submit queues while turn is in flight" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    // Simulate a turn already streaming and waiting on the next chunk.
    app.thread.turn.submit();
    app.thread.turn_view.awaitModel();

    try app.inputs.input.insertSliceAtCursor("later");
    try std.testing.expect(!try app.beginSubmit());

    try std.testing.expectEqual(@as(usize, 1), app.thread.queued.items.len);
    try std.testing.expectEqualStrings("later", app.thread.queued.items[0].text);
    try std.testing.expectEqual(@as(u32, 1), agent.message_queue.len());
    try std.testing.expectEqual(@as(usize, 0), app.inputs.input.buf.firstHalf().len);
    try std.testing.expect(try app.applyAgentEvent(.{ .queued_messages_flushed = 1 }));
    try std.testing.expectEqual(@as(usize, 0), app.thread.queued.items.len);
    // Just the flushed user message; the spinner stays derived UI.
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqualStrings("later", app.thread.transcript.messages.items[0].mirror().body);
    try std.testing.expect(app.thread.turn_view.awaitingOutput());
}

test "queued prompt draws above input at minimum input height" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.thread.turn.submit();
    app.thread.turn_view.awaitModel();

    try app.inputs.input.insertSliceAtCursor("later");
    try std.testing.expect(!try app.beginSubmit());

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var input_widget: input_mod.InputWidget = .{ .app = &app };
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

test "alt navigation and ctrl-steer drive the queued message line" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.thread.turn.submit();
    app.thread.turn_view.awaitModel();

    try app.inputs.input.insertSliceAtCursor("first");
    try std.testing.expect(!try app.beginSubmit());
    try app.inputs.input.insertSliceAtCursor("second");
    try std.testing.expect(!try app.beginSubmit());

    // Newest is selected after queueing.
    try std.testing.expectEqual(@as(usize, 1), app.nav.queued_selection);

    // ALT+← walks back to the older message; clamps at the front.
    app.selectPrevQueued();
    try std.testing.expectEqual(@as(usize, 0), app.nav.queued_selection);
    app.selectPrevQueued();
    try std.testing.expectEqual(@as(usize, 0), app.nav.queued_selection);

    // CTRL+→ steers the selected message in both the mirror and agent queue.
    app.steerSelectedQueued();
    try std.testing.expect(app.thread.queued.items[0].steer);
    try std.testing.expect(agent.message_queue.at(&agent.message_queue_storage, 0).?.steer);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var input_widget: input_mod.InputWidget = .{ .app = &app };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 60, .height = 6 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try input_widget.widget().draw(ctx);
    // Steered selection renders the ↩ form, not the "[...]" form.
    try std.testing.expectEqualStrings("↩", surface.children[0].surface.readCell(0, 0).char.grapheme);

    // ALT+→ moves to the newer, still-queued message: back to "[...]".
    app.selectNextQueued();
    try std.testing.expectEqual(@as(usize, 1), app.nav.queued_selection);
    const surface2 = try input_widget.widget().draw(ctx);
    try std.testing.expectEqualStrings("[", surface2.children[0].surface.readCell(0, 0).char.grapheme);
}

test "begin submit shows notice when queued message queue is full" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.thread.turn.submit();
    app.thread.turn_view.awaitModel();

    var queued_count: usize = 0;
    while (queued_count < agent.message_queue_storage.len) : (queued_count += 1) {
        try agent.enqueueUser("queued");
    }

    try app.inputs.input.insertSliceAtCursor("later");
    try std.testing.expect(!try app.beginSubmit());

    try std.testing.expectEqual(@as(usize, 0), app.thread.queued.items.len);
    try std.testing.expectEqual(@as(u32, @intCast(agent.message_queue_storage.len)), agent.message_queue.len());
    try std.testing.expectEqualStrings("later", app.inputs.input.buf.firstHalf());
    // The notice is the only transcript row; the spinner is not a status message.
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.notice, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqualStrings("MessageQueueFull", app.thread.transcript.messages.items[0].mirror().body);
    try std.testing.expect(app.thread.turn_view.awaitingOutput());
}

test "opening model picker starts at top" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.pickers.models.model_selection = 4;
    try provider_model.openModelPicker(&app);

    try std.testing.expectEqual(@as(u32, 0), app.pickers.models.model_selection);
}

test "model picker hides model arrow when reasoning column is focused" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .model_picker;
    app.pickers.models.model_column = .reasoning;
    app.pickers.models.model_selection = 0;
    const models = try codex.loadStaticModels(gpa);
    defer gpa.free(models);
    for (models) |model| try app.pickers.models.append(gpa, model, .openai_codex);

    var row: model_picker.Row = .{
        .model = &app.pickers.models.entries.items[0].model,
        .selected = true,
        .column = app.pickers.models.model_column,
        .active_model = null,
        .reasoning_label = reasoningOptions()[provider_model.selectedReasoningIndex(&app)].label,
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
    try std.testing.expectEqualStrings(" ", surface.readCell(panel.secondaryColumn(surface.size.width), 0).char.grapheme);
}

test "model picker without models stays on model column" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .model_picker;
    app.pickers.models.model_column = .model;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.right }));
    try std.testing.expectEqual(model_picker.Column.model, app.pickers.models.model_column);
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
    const label = try provider_model.localModelLabel(std.testing.allocator, .ollama, "llama3");
    defer std.testing.allocator.free(label);

    try std.testing.expectEqualStrings("Ollama · llama3", label);
}

test "ollama cloud models are not listed as local models" {
    try std.testing.expect(provider_model.includeLocalModel(.ollama, "llama3"));
    try std.testing.expect(!provider_model.includeLocalModel(.ollama, "gpt-oss-cloud"));
    try std.testing.expect(!provider_model.includeLocalModel(.ollama, "gpt-oss:120b-cloud"));
    try std.testing.expect(provider_model.includeLocalModel(.llama_cpp, "gpt-oss-cloud"));
}

test "local providers are not loaded twice through configured compatible catalog" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.cached_config.model_selection = .{
        .provider = .ollama,
        .provider_name = @constCast("ollama"),
        .base_url = @constCast("http://localhost:11434"),
        .api_key = @constCast("ollama"),
        .model = .{ .id = @constCast("test") },
    };

    try std.testing.expect(!provider_model.shouldLoadConfiguredCompatibleCatalog(&app));
}

test "provider picker selects sign out horizontally" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    var codex_client: ai.codex_responses.Client = undefined;
    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.client = .{ .codex_responses = &codex_client };
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    app.codex_signed_in = true;

    app.mode = .provider_picker;
    app.pickers.provider.column = .provider;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.right }));
    try std.testing.expectEqual(provider_picker.Column.sign_out, app.pickers.provider.column);
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(provider_picker.Column.provider, app.pickers.provider.column);
}

test "compatible base url falls back when cached local provider differs" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.cached_config.model_selection = .{
        .provider = .llama_cpp,
        .provider_name = @constCast("llama.cpp"),
        .base_url = @constCast("http://localhost:11434"),
        .api_key = @constCast(""),
        .model = .{ .id = @constCast("test") },
    };

    try std.testing.expectEqualStrings("http://localhost:8080", provider_model.compatibleBaseUrl(&app, .llama_cpp).?);
    try std.testing.expectEqualStrings("http://localhost:11434", provider_model.compatibleBaseUrl(&app, .ollama).?);
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
    runtime.owned_compaction_client = null;
    runtime.owned_naming_client = null;
    runtime.naming_client = .none;
    var app = try App.init(std.testing.io, gpa, &runtime.agent);
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    defer app.deinit();
    defer runtime.disconnectClient();

    app.codex_signed_in = true;
    try app.pickers.models.append(gpa, .{ .id = try gpa.dupe(u8, "llama3"), .label = try gpa.dupe(u8, "llama3") }, .{ .openai_compatible = .ollama });
    app.pickers.models.model_selection = 0;
    app.cached_config_owned = true;
    app.cached_config.model_selection = .{
        .provider = .openai_compatible,
        .provider_name = try gpa.dupe(u8, "openai_compatible"),
        .base_url = try gpa.dupe(u8, "http://localhost:11434/v1"),
        .api_key = try gpa.dupe(u8, "ollama"),
        .model = .{ .id = try gpa.dupe(u8, "placeholder") },
    };

    try provider_model.applySelectedModel(&app);

    try std.testing.expect(app.isCodexSignedIn());
    try std.testing.expectEqual(config_mod.Provider.ollama, app.cached_config.model_selection.?.provider);
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
    runtime.owned_compaction_client = null;
    runtime.owned_naming_client = null;
    runtime.naming_client = .none;
    defer runtime.disconnectClient();

    var app = try App.init(std.testing.io, gpa, &runtime.agent);
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    defer app.deinit();

    app.pickers.models.model_scope = .session;
    try app.pickers.models.append(gpa, .{ .id = try gpa.dupe(u8, "zen"), .label = try gpa.dupe(u8, "zen") }, .{ .openai_compatible = .opencode_zen });
    app.pickers.models.model_selection = 0;
    app.cached_config_owned = true;
    app.cached_config.model_selection = .{
        .provider = .openai,
        .provider_name = try gpa.dupe(u8, "openai"),
        .base_url = try gpa.dupe(u8, "https://chatgpt.com/backend-api"),
        .api_key = try gpa.dupe(u8, "stale-codex-key"),
        .model = .{ .id = try gpa.dupe(u8, "placeholder") },
    };

    try provider_model.applySelectedModel(&app);

    const ms = app.cached_config.model_selection.?;
    try std.testing.expectEqual(config_mod.Provider.opencode_zen, ms.provider);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1", ms.base_url);
    try std.testing.expectEqualStrings("", ms.api_key);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1/chat/completions", runtime.client.openai_compatible.url);
}

test "active model appears at display position 0 without mutating storage" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    const active_model_id = try gpa.dupe(u8, "gpt-5.4-mini");
    defer gpa.free(active_model_id);
    app.cached_config.model_selection = .{
        .provider = .openai,
        .provider_name = @constCast("openai"),
        .base_url = @constCast(""),
        .api_key = @constCast(""),
        .model = .{ .id = active_model_id },
    };

    try provider_model.reloadModelCatalog(&app, .openai_codex);

    const active_storage_idx = app.pickers.models.activeStorageIdx("gpt-5.4-mini");
    const storage_idx = model_picker.displayToStorage(active_storage_idx, 0);
    try std.testing.expectEqualStrings("gpt-5.4-mini", app.pickers.models.entries.items[storage_idx].model.id);
}

test "explicit codex catalog loads before runtime is connected" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try provider_model.reloadModelCatalog(&app, .openai_codex);

    try std.testing.expect(app.pickers.models.len() > 0);
    try std.testing.expect(provider_model.selectedCodexModel(&app) != null);
}

test "slash opens command menu before focused input handles it" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
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
    try std.testing.expectEqual(@as(usize, 0), app.inputs.input.buf.realLength());
}

test "slash opens command menu when text field previous value is stale" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    app.inputs.input.previous_val = try gpa.dupe(u8, "/");

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
    try std.testing.expectEqual(@as(usize, 0), app.inputs.input.buf.realLength());
}

test "expired codex connection reports reconnect message" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.codex_connection_expired = true;
    runtime.diagnostics = &.{};
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    app.cached_config = .{
        .model_selection = .{
            .provider = .openai,
            .provider_name = @constCast("openai"),
            .base_url = @constCast(""),
            .api_key = @constCast(""),
            .model = .{ .id = @constCast("test") },
        },
    };

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
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{
        .io = std.testing.io,
        .alloc = arena.allocator(),
        .cmds = .empty,
    };

    try app.inputs.input.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'x', .text = "x" } });
    app.inputs.input.clearRetainingCapacity();
    app.thread.turn.submit();
    defer app.thread.turn.reset();
    try app.inputs.input.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '/', .text = "/" } });

    try std.testing.expectEqual(App.Mode.command, app.mode);
}

test "reprompt after interrupt starts a fresh turn" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("first");
    try std.testing.expect(try app.beginSubmit());
    if (app.thread.pending_prompt) |prompt| app.thread.worker_context.?.gpa.free(prompt);
    app.thread.pending_prompt = null;
    try app.handleInterrupt();

    try app.inputs.input.insertSliceAtCursor("second");
    try std.testing.expect(try app.beginSubmit());
    defer app.thread.turn.reset();
    defer {
        if (app.thread.pending_prompt) |prompt| app.thread.worker_context.?.gpa.free(prompt);
        app.thread.pending_prompt = null;
    }

    try std.testing.expectEqual(Turn.State.active, app.thread.turn.state);
    try std.testing.expectEqual(@as(usize, 0), app.thread.queued.items.len);
}

test "interrupt drops the turn straight back to idle" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("first");
    try std.testing.expect(try app.beginSubmit());
    if (app.thread.pending_prompt) |prompt| app.thread.worker_context.?.gpa.free(prompt);
    app.thread.pending_prompt = null;
    try std.testing.expectEqual(Turn.State.active, app.thread.turn.state);

    // Interrupt must not leave the lane lingering in `interrupting` waiting for
    // a (possibly blocked) worker to reach its next cancellation point — the UI
    // would read as in-flight. The worker is torn down and the turn is idle.
    try app.handleInterrupt();
    try std.testing.expectEqual(Turn.State.idle, app.thread.turn.state);
    try std.testing.expect(!app.thread.turn.isActive());
}

test "lane commands stay hidden until a second lane exists" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Single lane: the multi-lane commands (/merge, /close) are filtered out of
    // the palette and can't be resolved; the twenty always-on commands remain.
    try std.testing.expectEqual(@as(u32, 20), commandMatchesCountForFilter(&app, ""));
    try std.testing.expect(resolveCommand(&app, "Close") == null);
    try std.testing.expect(resolveCommand(&app, "Merge") == null);
    // `/sync` was removed with the git-shadow pivot and never came back.
    try std.testing.expect(resolveCommand(&app, "Sync") == null);
    try std.testing.expect(resolveCommand(&app, "Parallel") == .parallel);
    try std.testing.expect(resolveCommand(&app, "Lanes") == .lanes);

    // A second lane unhides the multi-lane commands.
    const lane2 = try gpa.create(Thread);
    lane2.* = .{};
    try app.threads.append(gpa, lane2);
    try std.testing.expect(resolveCommand(&app, "Merge") == .merge);
    try std.testing.expect(resolveCommand(&app, "Close") == .close);
}

test "cycleLane wraps the active lane in both directions" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // With a single lane, cycling is a no-op.
    app.cycleLane(1);
    try std.testing.expectEqual(@as(usize, 0), app.activeIndex());

    const lane2 = try gpa.create(Thread);
    lane2.* = .{};
    try app.threads.append(gpa, lane2);
    const lane3 = try gpa.create(Thread);
    lane3.* = .{};
    try app.threads.append(gpa, lane3);

    try std.testing.expectEqual(@as(usize, 0), app.activeIndex());
    app.cycleLane(1);
    try std.testing.expectEqual(@as(usize, 1), app.activeIndex());
    app.cycleLane(1);
    try std.testing.expectEqual(@as(usize, 2), app.activeIndex());
    // Forward past the last lane wraps to the first.
    app.cycleLane(1);
    try std.testing.expectEqual(@as(usize, 0), app.activeIndex());
    // Backward past the first lane wraps to the last.
    app.cycleLane(-1);
    try std.testing.expectEqual(@as(usize, 2), app.activeIndex());
}

test "toggleLaneFullscreen flips split only when multiple lanes exist" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Single lane: nothing to tile, so the toggle leaves split untouched.
    try std.testing.expect(!app.split);
    app.toggleLaneFullscreen();
    try std.testing.expect(!app.split);

    const lane2 = try gpa.create(Thread);
    lane2.* = .{};
    try app.threads.append(gpa, lane2);
    app.split = true; // parallel lanes open tiled
    app.toggleLaneFullscreen();
    try std.testing.expect(!app.split); // now fullscreened
    app.toggleLaneFullscreen();
    try std.testing.expect(app.split); // back to split
}

test "lanes chip rect hit test covers its row span only" {
    const rect: ChipRect = .{ .row = 5, .col = 2, .width = 9 };
    try std.testing.expect(rect.contains(5, 2)); // left edge
    try std.testing.expect(rect.contains(5, 10)); // right edge (col + width - 1)
    try std.testing.expect(!rect.contains(5, 11)); // one past the right edge
    try std.testing.expect(!rect.contains(5, 1)); // one before the left edge
    try std.testing.expect(!rect.contains(4, 5)); // wrong row
    try std.testing.expect(!rect.contains(-1, -1)); // off-screen negatives
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
    runtime.owned_compaction_client = null;
    runtime.owned_naming_client = null;
    runtime.naming_client = .none;
    var app = try App.init(std.testing.io, gpa, &runtime.agent);
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    defer app.deinit();
    defer runtime.disconnectClient();

    try app.pickers.models.append(gpa, .{ .id = try gpa.dupe(u8, "llama3"), .label = try gpa.dupe(u8, "llama3") }, .{ .openai_compatible = .ollama });
    app.pickers.models.model_selection = 0;
    app.cached_config_owned = true;
    app.cached_config.model_selection = .{
        .provider = .openai_compatible,
        .provider_name = try gpa.dupe(u8, "openai_compatible"),
        .base_url = try gpa.dupe(u8, "http://localhost:11434/v1"),
        .api_key = try gpa.dupe(u8, "ollama"),
        .model = .{ .id = try gpa.dupe(u8, "placeholder") },
    };
    app.thread.turn.submit();
    app.thread.turn.interrupt();

    try provider_model.applySelectedModel(&app);

    try std.testing.expectEqual(Turn.State.idle, app.thread.turn.state);
    try std.testing.expectEqual(config_mod.Provider.ollama, app.cached_config.model_selection.?.provider);
}

test "interrupt restart flushes queued messages to the transcript when no provider" {
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
    runtime.owned_compaction_client = null;
    runtime.owned_naming_client = null;
    runtime.naming_client = .none;
    var app = try App.init(std.testing.io, gpa, &runtime.agent);
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    defer app.deinit();
    defer app.thread.turn.reset();

    // Queue two messages behind a running turn.
    app.thread.turn.submit();
    try app.inputs.input.insertSliceAtCursor("one");
    try std.testing.expect(!try app.beginSubmit());
    try app.inputs.input.insertSliceAtCursor("two");
    try std.testing.expect(!try app.beginSubmit());
    try std.testing.expectEqual(@as(usize, 2), app.thread.queued.items.len);

    // With no provider, the restart surfaces the queued text and drops the queue
    // rather than spinning up a doomed worker.
    try std.testing.expect(try app.restartTurnForQueuedMessages());
    try std.testing.expectEqual(@as(usize, 0), app.thread.queued.items.len);
    try std.testing.expectEqual(@as(u32, 0), runtime.agent.message_queue.len());
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqualStrings("one", app.thread.transcript.messages.items[0].mirror().body);
    try std.testing.expectEqualStrings("two", app.thread.transcript.messages.items[1].mirror().body);
}

test "canceling a picker returns to command menu" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
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
    var app = try App.init(std.testing.io, gpa, &agent);
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
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .command;
    app.nav.command_selection = commandMatchesCountForFilter(&app, "") - 1;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expectEqual(@as(u32, 0), app.nav.command_selection);

    const models = try codex.loadStaticModels(gpa);
    defer gpa.free(models);
    for (models) |model| try app.pickers.models.append(gpa, model, .openai_codex);
    app.mode = .model_picker;
    app.pickers.models.model_selection = @intCast(app.pickers.models.len() - 1);
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expectEqual(@as(u32, 0), app.pickers.models.model_selection);

    app.pickers.models.model_column = .reasoning;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(@as(u32, 1), app.pickers.models.entries.items[0].reasoning_index);
    try std.testing.expectEqual(@as(u32, 0), app.pickers.models.entries.items[1].reasoning_index);
}

test "empty text deltas do not create selectable messages" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("hello");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .response_delta = "" }));
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);

    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = "" }));
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
}

test "agent app events update transcript on the ui side" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("hello");
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

    try std.testing.expectEqual(@as(usize, 3), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqual(.thinking, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[2].mirror().kind);
    try std.testing.expectEqual(@as(u32, 2), app.thread.transcript.selected.?);
    try std.testing.expectEqualStrings("checking files", app.thread.transcript.messages.items[1].mirror().body);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[2].mirror().title);
}

test "user can navigate away from a streaming thinking block" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("hello");
    _ = try app.beginSubmit();

    _ = try app.applyAgentEvent(.{ .thinking_delta = "first chunk" });
    try std.testing.expectEqual(.thinking, app.thread.transcript.messages.items[app.thread.transcript.selected.?].mirror().kind);

    app.thread.transcript.moveSelection(.previous);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[app.thread.transcript.selected.?].mirror().kind);

    _ = try app.applyAgentEvent(.{ .thinking_delta = " more" });
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[app.thread.transcript.selected.?].mirror().kind);
}

test "user can navigate away from a streaming agent message" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("hello");
    _ = try app.beginSubmit();

    _ = try app.applyAgentEvent(.{ .response_delta = "first chunk" });
    try std.testing.expectEqual(.agent, app.thread.transcript.messages.items[app.thread.transcript.selected.?].mirror().kind);

    app.thread.transcript.moveSelection(.previous);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[app.thread.transcript.selected.?].mirror().kind);

    _ = try app.applyAgentEvent(.{ .response_delta = " more" });
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[app.thread.transcript.selected.?].mirror().kind);
}

test "empty content delta does not finalize thinking" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("hello");
    _ = try app.beginSubmit();

    _ = try app.applyAgentEvent(.{ .thinking_delta = "thinking" });
    const thinking_index = app.thread.turn_view.thinking_index.?;
    try std.testing.expectEqualStrings("Thinking...", app.thread.transcript.messages.items[thinking_index].mirror().title);

    _ = try app.applyAgentEvent(.{ .response_delta = "" });
    try std.testing.expectEqualStrings("Thinking...", app.thread.transcript.messages.items[thinking_index].mirror().title);

    _ = try app.applyAgentEvent(.{ .thinking_delta = " more" });
    try std.testing.expectEqualStrings("Thinking...", app.thread.transcript.messages.items[thinking_index].mirror().title);

    _ = try app.applyAgentEvent(.{ .response_delta = "answer" });
    try std.testing.expectEqualStrings("Thoughts", app.thread.transcript.messages.items[thinking_index].mirror().title);
}

test "content deltas do not override user scroll state" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("hello");
    _ = try app.beginSubmit();

    _ = try app.applyAgentEvent(.{ .response_delta = "first" });
    try std.testing.expect(app.thread.auto_scroll);

    app.thread.auto_scroll = false;
    _ = try app.applyAgentEvent(.{ .response_delta = " second" });
    try std.testing.expect(!app.thread.auto_scroll);
}

test "loading does not appear during final answer after tool batch" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("inspect");
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
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expect(app.thread.turn_view.awaitingOutput());

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "Final answer" }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(usize, 3), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.agent, app.thread.transcript.messages.items[2].mirror().kind);
}

test "loading does not reappear between content chunks" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("implement dijkstra");
    _ = try app.beginSubmit();

    // Once a content delta has arrived we are committed to streaming. The gap
    // between chunks must NOT bring the spinner back — the streaming text is
    // its own progress indicator.
    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "Here's the implementation plan:" }));
    _ = try app.applyAgentEvent(.delta_end);
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqual(.agent, app.thread.transcript.messages.items[1].mirror().kind);
}

test "bash tool waits for complete arguments while streaming" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("list files");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"printf hello",
    } }));
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);

    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "Print hello",
        .display_expanded_label = "printf hello",
        .display_body = "hello",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
}

test "tool row persists through finish and turn completion" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("run ls");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\",\"reason\":\"List files\"}",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[1].mirror().title);
    try std.testing.expectEqualStrings("🛠  ls", app.thread.transcript.messages.items[1].mirror().tool_expanded_title.?);
    try std.testing.expect(app.thread.transcript.messages.items[1].mirror().tool_running);
    try std.testing.expect(app.thread.transcript.hasRunningTool());

    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[1].mirror().title);

    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "List files",
        .display_expanded_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expect(!app.thread.transcript.messages.items[1].mirror().tool_running);
    try std.testing.expect(!app.thread.transcript.hasRunningTool());
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[1].mirror().title);

    try std.testing.expect(try app.applyAgentEvent(.turn_finished));
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[1].mirror().title);
}

test "partial tool arguments do not create visible tool rows" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("run ls");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"",
    } }));
    // Partial arguments render nothing, so no tool row appears and the spinner
    // stays up (awaiting) over the lone user message.
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expect(app.thread.turn_view.awaitingOutput());

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\",\"reason\":\"List files\"}",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[1].mirror().title);
}

test "tool finish creates row if no complete streamed arguments appeared" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("run ls");
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

    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[1].mirror().title);
}

test "new tool response index creates a new transcript row" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("run tools");
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

    try std.testing.expectEqual(@as(usize, 3), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[2].mirror().kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[1].mirror().title);
    try std.testing.expectEqualStrings("🛠  Print working directory", app.thread.transcript.messages.items[2].mirror().title);
}

test "bash tool after batch creates a new tool row" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("run tools");
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
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expect(app.thread.turn_view.awaitingOutput());

    _ = try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"printf done\",\"reason\":\"Print done\"}",
    } });

    try std.testing.expectEqual(@as(usize, 3), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[2].mirror().kind);
}

test "late tool finish does not move selection upward" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("run tools");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\",\"reason\":\"List files\"}",
    } }));
    try std.testing.expectEqual(@as(u32, 1), app.thread.transcript.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 1,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\",\"reason\":\"Print working directory\"}",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.thread.transcript.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "List files",
        .display_expanded_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.thread.transcript.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "done" }));
    try std.testing.expectEqual(@as(u32, 3), app.thread.transcript.selected.?);
}

test "loading does not resume after post-tool thinking delta" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("inspect");
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

    try std.testing.expectEqual(@as(usize, 3), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqual(.thinking, app.thread.transcript.messages.items[2].mirror().kind);
    try std.testing.expectEqualStrings("Thinking...", app.thread.transcript.messages.items[2].mirror().title);
}

test "agent response after tool batch appears below tool rows" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("inspect");
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

    try std.testing.expectEqual(@as(usize, 4), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqual(.agent, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[2].mirror().kind);
    try std.testing.expectEqual(.agent, app.thread.transcript.messages.items[3].mirror().kind);
    try std.testing.expectEqualStrings("I will check.", app.thread.transcript.messages.items[1].mirror().body);
    try std.testing.expectEqualStrings("🛠  Print working directory", app.thread.transcript.messages.items[2].mirror().title);
    try std.testing.expectEqualStrings("The repo is in /tmp.", app.thread.transcript.messages.items[3].mirror().body);
    try std.testing.expectEqual(@as(u32, 3), app.thread.transcript.selected.?);
}

test "content delta after tool preview does not move selection away from tool row" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("inspect");
    _ = try app.beginSubmit();

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "I will check." }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(u32, 1), app.thread.transcript.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\",\"reason\":\"Print working directory\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(u32, 2), app.thread.transcript.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = " Still checking." }));
    _ = try app.applyAgentEvent(.delta_end);
    try std.testing.expectEqual(@as(u32, 2), app.thread.transcript.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "Print working directory",
        .display_expanded_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.thread.transcript.selected.?);
    try std.testing.expectEqualStrings("I will check.", app.thread.transcript.messages.items[1].mirror().body);
    try std.testing.expectEqualStrings("🛠  Print working directory", app.thread.transcript.messages.items[2].mirror().title);
    try std.testing.expectEqualStrings(" Still checking.", app.thread.transcript.messages.items[3].mirror().body);
}

test "collapsed thinking and tool rows have stable heights" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const thinking_index = try transcript.append(gpa, .thinking, "Thinking...", "short");
    try std.testing.expectEqual(@as(u16, 2), messageRowsCached(&transcript.messages.items[thinking_index], 80));

    try transcript.appendThinkingDelta(gpa, thinking_index, " ");
    try transcript.appendThinkingDelta(gpa, thinking_index, "this is a much longer thinking body that should not change the collapsed row height");
    try std.testing.expectEqual(@as(u16, 2), messageRowsCached(&transcript.messages.items[thinking_index], 80));

    const tool_index = try transcript.startTool(gpa, "pwd");
    try std.testing.expectEqual(@as(u16, 2), messageRowsCached(&transcript.messages.items[tool_index], 80));
}

test "collapsed tool title wraps to visible rows" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "python3 - <<'PY'\nprint('a very long patch document')\nPY");
    try std.testing.expect(!transcript.messages.items[index].mirror().expanded);
    try std.testing.expect(messageRowsCached(&transcript.messages.items[index], 12) > 3);
}

test "resumed tool messages keep the tool icon" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "done") } };
    try agent.takeMessage(.{
        .tool = .{
            .content = blocks,
            .call_id = .{ .value = try gpa.dupe(u8, "test_call") },
            .display_label = try gpa.dupe(u8, "zig build test"),
        },
    });

    try app.rebuildTranscriptFromAgent();

    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqualStrings("🛠  zig build test", app.thread.transcript.messages.items[0].mirror().title);
}

test "collapsed tool messages render no body text" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "printf hello");
    try transcript.finishTool(gpa, index, "hello", null, false);

    try std.testing.expect(!transcript.messages.items[index].mirror().expanded);
    try std.testing.expectEqual(@as(u16, 2), messageRowsCached(&transcript.messages.items[index], 80));
    transcript.toggleSelected();
    try std.testing.expect(transcript.messages.items[index].mirror().expanded);
    try std.testing.expectEqualStrings("hello", transcript.messages.items[index].mirror().body);
}

test "expanded tool surface height cannot overflow vxfw buffer size" {
    const gpa = std.testing.allocator;
    const body = try gpa.alloc(u8, 80_000);
    defer gpa.free(body);
    @memset(body, 'x');

    var message: transcript_mod.Message = .{
        .tool = .{
            .title = try gpa.dupe(u8, "$ yes"),
            .body = body,
            .expanded = true,
        },
    };
    defer gpa.free(message.tool.title);

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

test "switching lanes is a no-op with a single lane" {
    const gpa = std.testing.allocator;
    var client: openai_compatible_mod.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 1), app.threads.items.len);
    const before = app.thread;
    app.switchToNextLane();
    try std.testing.expectEqual(before, app.thread);
}

const BenchResult = struct { allocs: usize, bytes: usize };

fn benchTranscriptDraw(gpa: std.mem.Allocator, n: usize) !BenchResult {
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    const body = "This is a paragraph of agent markdown that wraps across the\nterminal a few times so the row counting and render caches do real work.\n";
    var i: usize = 0;
    while (i < n) : (i += 1) _ = try app.thread.transcript.append(gpa, .agent, "agent", body);
    app.thread.transcript_view_width = 100;
    app.thread.transcript_view_height = 40;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var counting: CountingAllocator = .{ .child = arena.allocator() };
    var transcript_widget: tx_widget.TranscriptWidget = .{ .app = &app, .thread = app.thread };

    const draw = struct {
        fn f(tw: *tx_widget.TranscriptWidget, ar: *std.heap.ArenaAllocator, c: *CountingAllocator) !void {
            _ = ar.reset(.retain_capacity);
            const ctx: vxfw.DrawContext = .{
                .arena = c.allocator(),
                .min = .{},
                .max = .{ .width = 100, .height = 40 },
                .cell_size = .{ .width = 10, .height = 20 },
            };
            _ = try tw.widget().draw(ctx);
        }
    }.f;

    // Warm frame: renders + caches markdown for the visible messages.
    try draw(&transcript_widget, &arena, &counting);

    // One measured warm frame for allocation accounting.
    counting.count = 0;
    counting.bytes = 0;
    try draw(&transcript_widget, &arena, &counting);
    return .{ .allocs = counting.count, .bytes = counting.bytes };
}

test "transcript draw allocation does not scale with history length" {
    const gpa = std.testing.allocator;
    const small = try benchTranscriptDraw(gpa, 50);
    const large = try benchTranscriptDraw(gpa, 800);
    try std.testing.expect(large.bytes <= small.bytes + 4096);
}
