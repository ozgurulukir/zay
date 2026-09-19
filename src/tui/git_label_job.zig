//! Worker for the status-bar git repository/branch label.
//!
//! Git is intentionally kept out of the UI tick. The heap-allocated worker
//! owns its cwd copy; `Job(?[]const u8).spawn` arms it through
//! `lifecycle.zig`'s `GitLabelArm`, and the worker frees nothing — the
//! adopting tick frees the returned label and the worker afterwards.

const std = @import("std");
const diff_utils = @import("diff_utils.zig");
const job_mod = @import("job.zig");

/// Worker context, heap-allocated by the arming tick and freed by the
/// draining tick (after the label it produced has been adopted).
pub const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []u8,
};

/// Git failures degrade to "no label" — the status bar shows the bare lane.
pub fn run(worker: *Worker) ?[]const u8 {
    return diff_utils.loadGitLabel(worker.gpa, worker.io, worker.cwd) catch null;
}

/// The armed label job as an App field: the Job plus the generation tag the
/// drain checks so a result from a superseded lane/session is discarded.
pub const Arm = struct {
    job: job_mod.Job(?[]const u8),
    worker: *Worker,
    generation: u64,
};
