//! Git-shadow snapshotter: after each tool batch, snapshot the working tree
//! and bind the commit to the batch's last conversation entry, giving
//! per-tool-batch timeline granularity.
//!
//! Extracted from Agent so the turn loop stays a sequencer; the snapshot
//! policy (index-path caching, tree dedup, the disable latch) lives here.

const std = @import("std");

const session_mod = @import("../session.zig");
const vcs = @import("../vcs.zig");

pub const Snapshotter = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Dedicated shadow index path, resolved once and cached.
    index_path: ?[]u8 = null,
    /// Last snapshot's content-addressed tree id, for unchanged-tree dedup.
    last_tree: ?vcs.ObjectId = null,
    /// Latched off when git/the repo is absent — snapshots stay off for the
    /// session rather than failing every turn.
    disabled: bool = false,

    pub fn deinit(self: *Snapshotter) void {
        if (self.index_path) |path| self.gpa.free(path);
        self.index_path = null;
    }

    /// Snapshot the working tree (git-shadow) and bind it to the batch's last
    /// conversation entry. Runs on the worker thread — the only thread that
    /// writes session entries during a turn — so binding via `setLeafSnapshot`
    /// (which flushes the writer) can't race a concurrent append.
    ///
    /// Authoritative change-detection without trusting tool output: the
    /// content-addressed tree id is compared to the last snapshot's; an
    /// unchanged tree (a read-only batch, or a build that only touched
    /// gitignored files) is skipped, creating no object and no binding.
    /// Best-effort — any failure latches snapshots off for the session rather
    /// than failing the turn.
    pub fn afterBatch(self: *Snapshotter, cwd: []const u8, session_writer: ?*session_mod.SessionWriter) void {
        if (self.disabled) return;
        const writer = session_writer orelse return;
        const index = self.index_path orelse blk: {
            if (!vcs.isAvailable(self.gpa, self.io) or !vcs.isRepo(self.gpa, self.io, cwd)) {
                self.disabled = true;
                return;
            }
            const path = vcs.indexPath(self.gpa, self.io, cwd) catch {
                self.disabled = true;
                return;
            };
            self.index_path = path;
            break :blk path;
        };
        const tree = vcs.workingTreeId(self.gpa, self.io, cwd, index) catch return;
        if (self.last_tree) |last| {
            if (tree.eql(last)) return; // batch changed nothing tracked — no node
        }
        const commit = vcs.commitTree(self.gpa, self.io, cwd, tree) catch return;
        writer.setLeafSnapshot(commit.slice()) catch return;
        if (writer.leaf()) |leaf_id| vcs.keepRef(self.gpa, self.io, cwd, leaf_id, commit) catch {};
        self.last_tree = tree;
    }
};
