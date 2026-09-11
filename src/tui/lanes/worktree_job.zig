//! Asynchronous background worker for heavy `git worktree add` operations.
//! Extracted from `lane_lifecycle.zig`.

const std = @import("std");
const vcs = @import("../../vcs.zig");
const tui = @import("../../tui.zig");

const App = tui.App;

pub fn terminateLaneProcesses(app: *App, worktree_path: []const u8) void {
    if (app.background) |bg| {
        bg.terminateJobsInCwd(worktree_path);
    }
}

pub fn cleanupLaneWorktreeAndBranch(app: *App, repo: []const u8, path: ?[]const u8, branch: ?[]const u8) void {
    if (path) |p| {
        terminateLaneProcesses(app, p);
        if (vcs.worktreeRemove(app.gpa, app.io, repo, p)) |_| {} else |_| {
            // Fallback: prune git worktree metadata if file removal was partially blocked
            vcs.worktreePrune(app.gpa, app.io, repo) catch {};
        }
    }
    if (branch) |b| {
        vcs.deleteBranch(app.gpa, app.io, repo, b) catch {};
    }
}

pub fn anyAsyncWorktreeActive(app: *const App) bool {
    if (app.async_worktree_job) |job| {
        return !job.done.load(.acquire);
    }
    return false;
}

/// Asynchronous background worker for heavy `git worktree add` operations.
/// Prevents freezing the TUI event loop during lane provisioning in large repositories.
pub const WorktreeJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    repo: []u8,
    dest: []u8,
    branch: []u8,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err: ?anyerror = null,

    pub fn start(gpa: std.mem.Allocator, io: std.Io, repo: []const u8, dest: []const u8, branch: []const u8) !*WorktreeJob {
        const job = try gpa.create(WorktreeJob);
        errdefer gpa.destroy(job);
        job.* = .{
            .gpa = gpa,
            .io = io,
            .repo = try gpa.dupe(u8, repo),
            .dest = try gpa.dupe(u8, dest),
            .branch = try gpa.dupe(u8, branch),
        };
        errdefer {
            gpa.free(job.repo);
            gpa.free(job.dest);
            gpa.free(job.branch);
        }
        job.thread = try std.Thread.spawn(.{}, runWorker, .{job});
        return job;
    }

    fn runWorker(job: *WorktreeJob) void {
        vcs.worktreeAdd(job.gpa, job.io, job.repo, job.dest, job.branch) catch |err| {
            job.err = err;
        };
        job.done.store(true, .release);
    }

    pub fn deinit(self: *WorktreeJob) void {
        if (self.thread) |t| t.join();
        self.gpa.free(self.repo);
        self.gpa.free(self.dest);
        self.gpa.free(self.branch);
        self.gpa.destroy(self);
    }
};
