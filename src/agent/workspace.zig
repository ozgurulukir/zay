//! Agent workspace scoping (S5): the borrowed lane-worktree path that tools
//! root at while the agent is inside a lane, plus the mutex guarding it.
//!
//! Ownership: the path is borrowed from the lane's `Thread` — never copied or
//! freed here — and every borrow is dropped before that `Thread` goes away,
//! either by the `lane leave` tool or by the UI's S17 teardown invariant.
//!
//! Cross-thread contract: the agent's worker thread writes the borrow
//! (`tools/lane.zig`, `lane enter`/`leave`, between tool batches), while the
//! UI thread reads it (`tui/root_layout.zig`, `tui/lane_lifecycle.zig`) and
//! clears it during lane teardown (`tui/lanes/merge_flow.zig`). A 16-byte
//! slice store can tear, so every access takes `mutex`; `setWorkspace`,
//! `workspaceBorrow`, and `effectiveCwd` are the only accessors. The lock is
//! never held across tool dispatch.

const std = @import("std");

pub const WorkspaceScope = struct {
    /// The borrowed lane-worktree path, or null when the agent is unscoped.
    path: ?[]const u8 = null,
    /// Guards `path`: the worker thread writes it, the UI thread reads and
    /// clears it.
    mutex: std.Io.Mutex = .init,

    /// The directory tools run in: the workspace root when scoped, else
    /// `fallback` (the caller's session cwd). On lock failure the fallback is
    /// returned — a torn read must never widen where tools run. The returned
    /// slice is borrowed (the backing path is Thread-owned and outlives it).
    pub fn effectiveCwd(self: *WorkspaceScope, io: std.Io, fallback: []const u8) []const u8 {
        self.mutex.lock(io) catch return fallback;
        defer self.mutex.unlock(io);
        return self.path orelse fallback;
    }

    /// Set the workspace borrow (worker thread, `lane enter`/`leave`). The
    /// path is borrowed from the lane's `Thread`, never copied or freed here.
    pub fn setWorkspace(self: *WorkspaceScope, io: std.Io, path: ?[]const u8) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        self.path = path;
    }

    /// Read the workspace borrow (UI thread). Returns a borrowed slice; the
    /// backing path is Thread-owned and outlives the borrow.
    pub fn workspaceBorrow(self: *WorkspaceScope, io: std.Io) ?[]const u8 {
        self.mutex.lock(io) catch return null;
        defer self.mutex.unlock(io);
        return self.path;
    }
};

test "workspace scope round-trips a borrow and falls back when unscoped" {
    const io = std.testing.io;
    var scope: WorkspaceScope = .{};

    // No borrow: the fallback (the session cwd) wins.
    try std.testing.expectEqualStrings("/repo", scope.effectiveCwd(io, "/repo"));
    try std.testing.expect(scope.workspaceBorrow(io) == null);

    // Enter: the borrowed lane worktree replaces the fallback.
    scope.setWorkspace(io, "/tmp/zay-lanes/abc123");
    try std.testing.expectEqualStrings("/tmp/zay-lanes/abc123", scope.effectiveCwd(io, "/repo"));
    try std.testing.expectEqualStrings("/tmp/zay-lanes/abc123", scope.workspaceBorrow(io).?);

    // Leave: back to the fallback, and the borrow reads null again.
    scope.setWorkspace(io, null);
    try std.testing.expectEqualStrings("/repo", scope.effectiveCwd(io, "/repo"));
    try std.testing.expect(scope.workspaceBorrow(io) == null);
}

test "workspace scope returns the borrowed path zero-copy" {
    // The no-copy contract: callers rely on comparing borrow against the
    // lane's own path slices (pathsEqual shortcuts), so the scope must hand
    // back the same slice it was given.
    const io = std.testing.io;
    var scope: WorkspaceScope = .{};
    const path: []const u8 = "/tmp/zay-lanes/abc123";

    scope.setWorkspace(io, path);
    defer scope.setWorkspace(io, null);

    const borrow = scope.workspaceBorrow(io).?;
    try std.testing.expectEqual(path.ptr, borrow.ptr);
    try std.testing.expectEqual(path.len, borrow.len);
}
