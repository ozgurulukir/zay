//! Grouped `App` state sub-structs.
//!
//! Pulled out of `tui.zig` (R3 of `_pm/Projects/tui-split`) — the central
//! `App` struct grew to 70+ fields and the per-concern state kept bleeding
//! into each other. R3 splits the state into focused sub-structs, each
//! owning one concern. R1/R2 already routed cross-module access through
//! `pub` accessors, so this refactor is internal to `tui.zig` — every
//! call site of `self.<field>` inside `tui.zig` becomes
//! `self.<sub>.<field>`.
//!
//! Behavioural identity is preserved: every field keeps its default and
//! every operation mutates the same memory, just one struct level deeper.

const std = @import("std");
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");
const agent_mod = @import("../agent.zig");
const tree_selector = @import("widgets/tree_selector.zig");
const model_catalogue = @import("model_catalogue.zig");
const provider_picker = @import("widgets/provider_picker.zig");
const settings_widget = @import("widgets/settings.zig");
const help_picker = @import("widgets/help_picker.zig");
const mcp_status = @import("widgets/mcp_status.zig");
const vxfw = vaxis.vxfw;

const MentionSearchKind = tui.MentionSearchKind;

/// State for the @-mention search popup. The logical state is a 3-arm
/// union: closed (no popup), indexing (a background scan is in flight),
/// open (a query is active with a result list). The previous flat
/// struct (active/indexing flags + always-on results/kind/query/
/// selection) allowed illegal combinations like `active = false` with
/// non-empty `results`, or `indexing = true` with no query set. The
/// new shape makes those unrepresentable.
///
/// `closed` is a tag-only variant. `indexing` carries kind + results
/// (the scan populates results as it finds matches). `open` carries
/// kind + query + results + selection. Callers switch on the variant
/// to access the payload; there's no flat-field fallback.
pub const AtSearchState = union(enum) {
    closed,
    indexing: IndexingPayload,
    open: OpenPayload,

    pub const IndexingPayload = struct {
        kind: MentionSearchKind,
        results: std.ArrayList([]const u8) = .empty,
    };

    pub const OpenPayload = struct {
        kind: MentionSearchKind,
        query: []const u8 = "",
        results: std.ArrayList([]const u8) = .empty,
        selection: u32 = 0,
    };

    /// Convenience: the kind of mention being searched, regardless of
    /// which variant is active. Returns `.file` for `closed` (the
    /// default the UI uses when no popup is open).
    pub fn kind(self: AtSearchState) MentionSearchKind {
        return switch (self) {
            .closed => .file,
            .indexing => |i| i.kind,
            .open => |o| o.kind,
        };
    }

    /// Convenience: the active result list, or an empty slice when
    /// closed. Returned slice is owned by the state.
    pub fn results(self: *const AtSearchState) []const []const u8 {
        return switch (self.*) {
            .closed => &.{},
            .indexing => |*i| i.results.items,
            .open => |*o| o.results.items,
        };
    }

    /// Convenience: the mutable result list pointer, or null when
    /// closed. Used by at_search.zig to populate the list.
    pub fn resultsPtr(self: *AtSearchState) ?*std.ArrayList([]const u8) {
        return switch (self.*) {
            .closed => null,
            .indexing => |*i| &i.results,
            .open => |*o| &o.results,
        };
    }

    /// Free every owned buffer in whichever payload is active and
    /// transition to `closed`. Safe to call multiple times.
    pub fn close(self: *AtSearchState, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .closed => {},
            .indexing => |*i| {
                for (i.results.items) |path| gpa.free(path);
                i.results.deinit(gpa);
            },
            .open => |*o| {
                if (o.query.len > 0) gpa.free(o.query);
                for (o.results.items) |path| gpa.free(path);
                o.results.deinit(gpa);
            },
        }
        self.* = .closed;
    }
};

/// The three text-input widgets: the main prompt, the slash-palette
/// search, and the commit-message editor. Owns the vxfw.TextField
/// structs and their backing buffers.
pub const InputState = struct {
    input: vxfw.TextField,
    palette: vxfw.TextField,
    comment: vxfw.TextField,
};

/// The four picker widgets: file tree (overlay), model catalogue,
/// provider list with API-key form, and the settings panel.
/// Owns the per-picker state structs.
pub const PickerStates = struct {
    tree: tree_selector.TreeState,
    models: model_catalogue.ModelCatalogue = .{},
    provider: provider_picker.State = .{},
    settings: settings_widget.State = .{},
    help: help_picker.State = .{},
    mcp: mcp_status.State = .{},
};

/// Navigation cursors and the cross-pane selection state. Owns the
/// current position in each picker/menu (command, resume, lanes,
/// transcript) plus the quit-double-tap timestamp and the lane-chip
/// hit-test rect.
pub const NavState = struct {
    pub const LanesPurpose = enum { manage, merge_dest };
    pub const QuitState = union(enum) {
        none,
        pending: std.Io.Timestamp,
        confirmed,
    };

    block_nav: bool = false,
    command_selection: u32 = 0,
    resume_selection: u32 = 0,
    resume_global: bool = false,
    lanes_selection: u32 = 0,
    lanes_purpose: LanesPurpose = .manage,
    queued_selection: usize = 0,
    /// Quit state machine: none -> pending (user pressed Ctrl+Q once,
    /// waiting for a confirm within the window) -> confirmed (a slash
    /// exit command was issued; the next event loop drains it).
    quit: QuitState = .none,
    lanes_chip_rect: ?tui.ChipRect = null,
};

/// State for the Ctrl+O background-jobs modal: the open flag, the
/// selected row, the cancel-button focus hint, and the pending-delivery
/// queue of background results to surface. The `owner` is the typed
/// `*Agent` that owns the job (so the delivery site can look up the
/// lane without an `@ptrCast`); the layer crossing from
/// `background_mod.BackgroundManager.Finished.owner: *anyopaque` to
/// this typed pointer happens in `pollBackgroundJobs` (one explicit
/// cast at the TUI boundary, where agents are known).
pub const BackgroundModalState = struct {
    pub const BackgroundDelivery = struct {
        owner: *agent_mod.Agent,
        notice: []u8,
        message: ?[]u8,
    };

    modal: bool = false,
    selection: usize = 0,
    cancel_focus: bool = false,
    pending: std.ArrayList(BackgroundDelivery) = .empty,
};

/// Visual feedback state: the loading spinner frame, the black-hole
/// intro animation frame, the cached git label, and the diff-cache
/// fields (counts, refresh future, cache buffer, loading flag). The
/// rendering code reads from here; the loader thread writes here.
pub const MetricsState = struct {
    loading_frame: u8 = 0,
    loading_tick_active: bool = false,
    blackhole_frame: u16 = 0,
    blackhole_visible: bool = true,
    git_label: []const u8 = "",
    context_tokens_used: u32 = 0,
    context_tokens_max: u32 = 128000,
    diff_counts: tui.DiffCounts = .{},
    diff_refresh_future: ?std.Io.Future(tui.DiffRefreshOutcome) = null,
    diff_refresh_done: std.atomic.Value(bool) = .init(false),
    diff_refresh_again: bool = false,
    diff_cache: ?[]u8 = null,
    diff_loading: bool = false,
};
