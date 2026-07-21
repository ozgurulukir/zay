//! Lane merge-source helpers — extracted from `tui.zig` (R7.4 of tui-split).
//!
//! Types and pure helpers for the parallel-lane merge workflow: identifying
//! the worktree backing a lane (`workingLaneOf`), trimming worktree paths
//! (`lastPathSegment`), and formatting merge errors for the model-status bar
//! (`laneErrorText`).

const vcs = @import("../vcs.zig");

const Thread = @import("../tui.zig").Thread;

/// A lane being merged away. `branch`/`path` identify its `nova/<id>` worktree;
/// `active_index` is its `threads` slot when it's an open lane (torn down via
/// `abandonLane` after a successful merge), or null for a parked worktree
/// (removed directly). Strings are borrowed for the duration of the merge.
pub const MergeSource = struct {
    branch: []const u8,
    path: []const u8,
    active_index: ?usize,
};

/// The `nova/<id>` worktree of `lane` if it's a working lane, else null (the
/// primary lane carries no dedicated branch/worktree).
pub fn workingLaneOf(lane: *Thread) ?vcs.Lane.Working {
    const lane_ref: *const vcs.Lane = switch (lane.engine) {
        .live => |*live| &live.lane,
        .idle => |*l| l,
    };
    return switch (lane_ref.*) {
        .working => |w| w,
        .primary => null,
    };
}

/// Final path segment, tolerant of both `/` and `\` separators and trailing
/// slashes. Used to match worktree paths across git's forward-slash reporting
/// and the platform-native paths Nova stores.
pub fn lastPathSegment(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    var start = end;
    while (start > 0 and path[start - 1] != '/' and path[start - 1] != '\\') start -= 1;
    return path[start..end];
}

/// Friendly text for the lane-operation errors surfaced by `reportLaneError`.
pub fn laneErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.InFlightTurn => "a turn is still running — wait for it to finish",
        error.MergeConflict => "merge conflict — the lanes changed the same lines (rolled back, nothing lost)",
        error.CannotMergePrimaryLane => "can't merge the primary lane; switch to a working lane first",
        error.CannotClosePrimaryLane => "can't close the primary lane",
        error.NoMergeDestination => "no other lane to merge into",
        error.TooManyLanes => "too many lanes (max 4)",
        else => @errorName(err),
    };
}
