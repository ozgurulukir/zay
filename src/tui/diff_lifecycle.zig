//! Diff lifecycle: async diff refresh pipeline and diff-count display.
//! Free functions taking `*App` — extracted from `tui.zig` (Phase 2 of
//! `_pm/Projects/tui-domain-extract`).

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const bash_mod = @import("../tools/bash_exec.zig");
const diff_utils = @import("diff_utils.zig");
const diff_viewer = @import("diff_viewer.zig");
const app_state = @import("app_state.zig");

const App = tui.App;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const DiffCounts = app_state.DiffCounts;

const DiffRefreshJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []u8,

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
    defer {
        job.deinit();
        gpa.destroy(job);
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
    // The cache a failed refresh must restore (null on a cold load).
    const prior_cache: ?[]u8 = switch (app.metrics.diff) {
        .ready => |r| r.cache,
        .refreshing => |r| r.cache,
        else => null,
    };
    switch (app.metrics.diff) {
        .loading, .refreshing => return, // already in flight
        .ready => |r| {
            // Already cached — transition to refreshing, keeping the old cache.
            app.metrics.diff = .{ .refreshing = .{
                .job = .{},
                .cache = r.cache,
            } };
        },
        .idle => {
            const cwd_source = if (app.liveRuntime()) |runtime| runtime.cwd else ".";
            const cwd = try app.gpa.dupe(u8, cwd_source);
            errdefer app.gpa.free(cwd);

            const job = try app.gpa.create(DiffRefreshJob);
            errdefer app.gpa.destroy(job);
            job.* = .{
                .gpa = app.gpa,
                .io = app.io,
                .cwd = cwd,
            };
            app.metrics.diff = .{ .loading = .{ .job = .{} } };
            // The errdefer chain frees cwd + job exactly once and disarms
            // the union on spawn failure.
            errdefer app.metrics.diff = .idle;
            try app.metrics.diff.loading.job.spawn(app.io, job, runDiffRefresh);
            return;
        },
    }

    // refreshing path — fire off the new worker. On spawn failure the
    // errdefer chain frees cwd + job exactly once and restores the prior
    // cache state.
    const cwd_source = if (app.liveRuntime()) |runtime| runtime.cwd else ".";
    const cwd = try app.gpa.dupe(u8, cwd_source);
    errdefer app.gpa.free(cwd);

    const job = try app.gpa.create(DiffRefreshJob);
    errdefer app.gpa.destroy(job);
    job.* = .{
        .gpa = app.gpa,
        .io = app.io,
        .cwd = cwd,
    };
    app.metrics.diff = .{ .refreshing = .{ .job = .{}, .cache = prior_cache.? } };
    errdefer app.metrics.diff = if (prior_cache) |cache|
        .{ .ready = .{ .cache = cache } }
    else
        .idle;
    try app.metrics.diff.refreshing.job.spawn(app.io, job, runDiffRefresh);
}

pub fn cancelDiffRefresh(app: *App) void {
    switch (app.metrics.diff) {
        .loading => |*l| {
            var outcome = l.job.cancel(app.io);
            outcome.deinit(app.gpa);
            app.metrics.diff = .idle;
        },
        .refreshing => |*r| {
            var outcome = r.job.cancel(app.io);
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
        .loading => |*l| if (!l.job.isDone()) return false,
        .refreshing => |*r| if (!r.job.isDone()) return false,
        else => return false,
    }

    var outcome = switch (app.metrics.diff) {
        .loading => |*l| l.job.adopt(app.io),
        .refreshing => |*r| r.job.adopt(app.io),
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

// ---------------------------------------------------------------------------
// Viewer navigation (moved from provider_model.zig)
// ---------------------------------------------------------------------------

pub fn openTimelineSelector(app: *App) !void {
    if (app.thread.turn.isActive()) return error.InFlightTurn;
    app.mode = .tree_picker;
    app.clearInput();
    try app.reloadTreeNodes();
}

/// Enter the full-screen diff viewer. Warm path: parse the cached diff
/// instantly. Cold path: navigate immediately and show "Loading diff…" while
/// a background refresh fetches it (never blocks on git).
pub fn openDiffViewer(app: *App) !void {
    if (app.liveRuntime() == null) return error.NoWorkingDirectory;
    enterDiffMode(app);

    if (app.metrics.diff_cache()) |raw| {
        var state = try diff_viewer.fromRaw(app.gpa, raw);
        if (state.isEmpty()) {
            state.deinit(app.gpa);
            app.mode = .normal;
            _ = try app.thread.transcript.append(app.gpa, .agent, "agent", "No changes to review.");
            return;
        }
        app.diff.deinit(app.gpa);
        app.diff = state;
        return;
    }

    // Cold start: show the loading state and kick (or ride) a refresh.
    app.diff.deinit(app.gpa);
    app.diff = .{};
    if (!app.metrics.diff_loading()) try scheduleDiffRefresh(app);
}

pub fn enterDiffMode(app: *App) void {
    app.mode = .diff_viewer;
    // The diff viewer never draws the transcript, so the black-hole visibility
    // (recomputed only there) would stay stuck true and drive a pointless
    // continuous redraw/tick loop. Park it off while in the viewer.
    app.metrics.blackhole_visible = false;
    app.clearInput();
    app.clearPaletteInput();
    app.inputs.comment.clearRetainingCapacity();
}

pub fn reportDiffError(app: *App, err: anyerror) !void {
    const message = try std.fmt.allocPrint(app.gpa, "Couldn't open diff: {s}", .{@errorName(err)});
    defer app.gpa.free(message);
    _ = try app.thread.transcript.append(app.gpa, .agent, "agent", message);
    app.mode = .normal;
    app.clearInput();
    app.clearPaletteInput();
}

/// Leave the diff viewer. When `send` is set, composed review comments (if
/// any) are stuffed into the main input so the caller can run them through
/// the normal submit path; an Esc-style exit discards them. Returns true when
/// there is text queued to submit.
pub fn closeDiffViewer(app: *App, send: bool) !bool {
    const composed = if (send) try app.diff.composeMessage(app.gpa) else null;
    app.diff.deinit(app.gpa);
    app.mode = .normal;
    app.clearInput();
    app.clearPaletteInput();
    app.inputs.comment.clearRetainingCapacity();
    if (composed) |message| {
        defer app.gpa.free(message);
        try app.inputs.input.insertSliceAtCursor(message);
        return true;
    }
    return false;
}
