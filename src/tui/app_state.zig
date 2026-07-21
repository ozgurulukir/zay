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
const tui = @import("../tui.zig");

const MentionSearchKind = tui.MentionSearchKind;

/// State for the @-mention search popup. Owns the active flag, the
/// indexing flag (a background scan is in flight), the result list, the
/// selected index, the kind (file vs skill), and the cached query.
pub const AtSearchState = struct {
    active: bool = false,
    indexing: bool = false,
    selection: u32 = 0,
    results: std.ArrayList([]const u8) = .empty,
    kind: MentionSearchKind = .file,
    query: []const u8 = "",
};

/// The three text-input widgets: the main prompt, the slash-palette
/// search, and the commit-message editor. Owns the vxfw.TextField
/// structs and their backing buffers.
pub const InputState = struct {
    input: vxfw.TextField,
    palette: vxfw.TextField,
    comment: vxfw.TextField,
};

const vxfw = @import("vaxis").vxfw;
