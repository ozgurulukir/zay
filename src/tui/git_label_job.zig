//! Background worker for the status-bar git repository/branch label.
//!
//! Git is intentionally kept out of the UI tick. The worker owns its cwd copy
//! and publishes the completed label through a release/acquire flag; the UI
//! adopts or discards that result during a later tick.

const std = @import("std");
const diff_utils = @import("diff_utils.zig");

pub const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []u8,
    generation: u64,
    done: std.atomic.Value(bool) = .init(false),
    label: ?[]const u8 = null,
    thread: ?std.Thread = null,

    pub fn start(
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        generation: u64,
    ) !*Job {
        std.debug.assert(cwd.len > 0);

        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        const owned_cwd = try gpa.dupe(u8, cwd);
        errdefer gpa.free(owned_cwd);

        job.* = .{
            .gpa = gpa,
            .io = io,
            .cwd = owned_cwd,
            .generation = generation,
        };
        job.thread = try std.Thread.spawn(.{}, runWorker, .{job});
        return job;
    }

    fn runWorker(job: *Job) void {
        const label = diff_utils.loadGitLabel(job.gpa, job.io, job.cwd) catch "";
        if (label.len > 0) {
            job.label = label;
        }
        job.done.store(true, .release);
    }

    pub fn isDone(self: *const Job) bool {
        return self.done.load(.acquire);
    }

    pub fn takeLabel(self: *Job) ?[]const u8 {
        std.debug.assert(self.done.load(.acquire));
        const label = self.label;
        self.label = null;
        return label;
    }

    pub fn deinit(self: *Job) void {
        if (self.thread) |thread| thread.join();
        if (self.label) |label| self.gpa.free(label);
        self.gpa.free(self.cwd);
        self.gpa.destroy(self);
    }
};
