//! Diff lifecycle: async diff refresh pipeline and diff-count display.
//! Free functions taking `*App` — extracted from `tui.zig` (Phase 2 of
//! `_pm/Projects/tui-domain-extract`).

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const bash_mod = @import("../bash.zig");
const diff_utils = @import("diff_utils.zig");
const diff_viewer = @import("diff_viewer.zig");

const App = tui.App;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const DiffCounts = struct {
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

pub const DiffRefreshOutcome = union(enum) {
    ready: []u8,
    failed,

    pub fn deinit(self: *DiffRefreshOutcome, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |raw| gpa.free(raw),
            .failed => {},
        }
        self.* = undefined;
    }
};

const diffCountCommand =
    \\if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    \\  git diff --numstat HEAD -- 2>/dev/null
    \\  git ls-files --others --exclude-standard -z 2>/dev/null | while IFS= read -r -d '' file; do
    \\    lines=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    \\    if [ -n "$lines" ]; then printf '%s\t0\t%s\n' "$lines" "$file"; fi
    \\  done
    \\fi
;

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
        .command = diff_viewer.diff_command,
        .timeout = bash_mod.timeoutFromSeconds(5),
    }) catch return .failed;
    defer result.deinit(gpa);

    const raw = gpa.dupe(u8, result.stdout) catch return .failed;
    return .{ .ready = raw };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn diffCountsVisible(app: *const App) bool {
    if (app.metrics.diff_counts.additions > 0) return true;
    return app.metrics.diff_counts.deletions > 0;
}

pub fn refreshDiffCounts(app: *App) !bool {
    const cwd = if (app.liveRuntime()) |runtime| runtime.cwd else ".";
    var result = try bash_mod.runWithOptions(app.gpa, app.io, .{
        .cwd = cwd,
        .command = diffCountCommand,
        .timeout = bash_mod.timeoutFromSeconds(1),
    });
    defer result.deinit(app.gpa);
    if (result.code != 0) return false;

    return installDiffCounts(app, diff_utils.parseDiffCounts(result.stdout));
}

fn installDiffCounts(app: *App, next: DiffCounts) bool {
    if (next.additions == app.metrics.diff_counts.additions) {
        if (next.deletions == app.metrics.diff_counts.deletions) return false;
    }
    app.metrics.diff_counts = next;
    return true;
}

pub fn scheduleDiffRefresh(app: *App) !void {
    switch (app.metrics.diff) {
        .loading, .refreshing => return, // already in flight
        .ready => |r| {
            // Already cached — transition to refreshing, keeping the old cache.
            app.metrics.diff = .{ .refreshing = .{
                .future = undefined,
                .done = .init(false),
                .cache = r.cache,
            } };
        },
        .idle => {
            const cwd_source = if (app.liveRuntime()) |runtime| runtime.cwd else ".";
            const cwd = try app.gpa.dupe(u8, cwd_source);
            errdefer app.gpa.free(cwd);

            const job = try app.gpa.create(DiffRefreshJob);
            errdefer app.gpa.destroy(job);
            app.metrics.diff = .{ .loading = .{
                .future = undefined,
                .done = .init(false),
            } };
            job.* = .{
                .gpa = app.gpa,
                .io = app.io,
                .cwd = cwd,
                .done = &app.metrics.diff.loading.done,
            };
            errdefer job.deinit();
            app.metrics.diff.loading.future = try app.io.concurrent(runDiffRefresh, .{job});
            return;
        },
    }

    // refreshing path — fire off the new future.
    const cwd_source = if (app.liveRuntime()) |runtime| runtime.cwd else ".";
    const cwd = try app.gpa.dupe(u8, cwd_source);
    errdefer app.gpa.free(cwd);

    const job = try app.gpa.create(DiffRefreshJob);
    errdefer app.gpa.destroy(job);
    job.* = .{
        .gpa = app.gpa,
        .io = app.io,
        .cwd = cwd,
        .done = &app.metrics.diff.refreshing.done,
    };
    errdefer job.deinit();
    app.metrics.diff.refreshing.future = try app.io.concurrent(runDiffRefresh, .{job});
}

pub fn cancelDiffRefresh(app: *App) void {
    switch (app.metrics.diff) {
        .loading => |*l| {
            var future = l.future;
            var outcome = future.cancel(app.io);
            outcome.deinit(app.gpa);
            app.metrics.diff = .idle;
        },
        .refreshing => |*r| {
            var future = r.future;
            var outcome = future.cancel(app.io);
            outcome.deinit(app.gpa);
            // Keep the old cache — promote back to ready.
            app.metrics.diff = .{ .ready = .{ .cache = r.cache } };
        },
        else => {},
    }
}

pub fn drainDiffRefresh(app: *App) !bool {
    // Only loading/refreshing states can drain.
    switch (app.metrics.diff) {
        .loading => |*l| if (!l.done.load(.acquire)) return false,
        .refreshing => |*r| if (!r.done.load(.acquire)) return false,
        else => return false,
    }

    var outcome = switch (app.metrics.diff) {
        .loading => |*l| l.future.await(app.io),
        .refreshing => |*r| r.future.await(app.io),
        else => unreachable,
    };
    defer outcome.deinit(app.gpa);

    var visible_change = false;
    switch (outcome) {
        .ready => |raw| {
            // Free any previous cache, then store the new one in .ready.
            switch (app.metrics.diff) {
                .loading => app.metrics.diff = .{ .ready = .{ .cache = raw } },
                .refreshing => |r| {
                    app.gpa.free(r.cache);
                    app.metrics.diff = .{ .ready = .{ .cache = raw } };
                },
                else => app.metrics.diff = .{ .ready = .{ .cache = raw } },
            }
            outcome = .failed;
            if (installDiffCounts(app, diff_utils.countDiff(app.metrics.diff_cache().?))) visible_change = true;
            // Diff viewer was waiting for the cache to populate.
            if (app.metrics.diff_loading()) {
                try populateDiffFromCache(app);
                visible_change = true;
            }
        },
        .failed => {
            // Drop the loading state; keep the old cache if refreshing.
            switch (app.metrics.diff) {
                .loading => app.metrics.diff = .idle,
                .refreshing => |r| app.metrics.diff = .{ .ready = .{ .cache = r.cache } },
                else => {},
            }
            if (app.metrics.diff_loading()) {
                app.mode = .normal;
                _ = try app.thread.transcript.append(app.gpa, .agent, "agent", "Couldn't load diff.");
                visible_change = true;
            }
        },
    }
    return visible_change;
}

/// Build the viewer's state from the cached diff (parse only — no git).
fn populateDiffFromCache(app: *App) !void {
    const raw = app.metrics.diff_cache() orelse return;
    var state = try diff_viewer.fromRaw(app.gpa, raw);
    if (state.isEmpty()) {
        state.deinit(app.gpa);
        app.mode = .normal;
        app.clearInput();
        _ = try app.thread.transcript.append(app.gpa, .agent, "agent", "No changes to review.");
        return;
    }
    app.diff.deinit(app.gpa);
    app.diff = state;
}
