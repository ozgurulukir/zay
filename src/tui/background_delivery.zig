//! Background-job delivery plumbing.
//!
//! Pulled out of `tui.zig` (R4 of `_pm/Projects/tui-split`) — the
//! poll/format/deliver triplet was a focused 90-line cluster that only
//! read `background_modal_state.pending` and the global `background`
//! manager, so it earns its own module. App methods remain as
//! 1-line delegates so existing call sites compile unchanged.

const std = @import("std");
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");
const queue_mod = @import("queue.zig");
const app_state = @import("app_state.zig");
const background_jobs_widget = @import("widgets/background_jobs.zig");
const background_tool = @import("../tools/background.zig");

const App = tui.App;
const BackgroundDelivery = tui.BackgroundDelivery;
const Cache = app_state.BackgroundModalState.Cache;

const log = std.log.scoped(.background_delivery);

/// Cadence for refreshing the modal cache while it idles open (manager
/// snapshot + bounded log-tail read). Key-driven changes refresh
/// immediately; this only bounds the follow-the-log redraw rate.
const modal_refresh_ms: u64 = 250;

/// Free the owned notice + message buffers on a BackgroundDelivery and
/// poison the slot so a use-after-free is a deterministic crash.
pub fn freeDelivery(app: *App, delivery: *BackgroundDelivery) void {
    app.gpa.free(delivery.notice);
    if (delivery.message) |message| app.gpa.free(message);
    delivery.* = undefined;
}

/// Whether the drain/animation tick must stay alive for background work:
/// jobs still running, or completions waiting to be delivered.
pub fn backgroundActive(app: *App) bool {
    if (app.background_modal_state.pending.items.len > 0) return true;
    const manager = app.background orelse return false;
    return manager.activeCount() > 0;
}

/// Drain finished jobs from the manager into `background_pending`. Called
/// each tick; the actual delivery (notice + turn) happens in
/// `deliverPendingBackground` once the owning lane is idle.
pub fn pollBackgroundJobs(app: *App) !bool {
    const manager = app.background orelse return false;
    const finished = manager.takeFinished(app.gpa) catch return false;
    defer app.gpa.free(finished);
    for (finished) |*job| {
        const notice = formatBackgroundNotice(app, job) catch {
            job.deinit(app.gpa);
            continue;
        };
        // Take the model-facing message out of the job so its deinit only
        // frees the metadata.
        const message = job.completion_message;
        job.completion_message = null;
        app.background_modal_state.pending.append(app.gpa, .{
            .owner_generation = job.owner_generation,
            .notice = notice,
            .message = message,
        }) catch {
            app.gpa.free(notice);
            if (message) |m| app.gpa.free(m);
        };
        job.deinit(app.gpa);
    }
    if (finished.len > 0) ringBell();
    return finished.len > 0;
}

pub fn ringBell() void {
    std.debug.print("\x07", .{});
}

/// Format the human-readable notice for a finished job.
pub fn formatBackgroundNotice(app: *App, job: *const tui.background_mod.BackgroundManager.Finished) ![]u8 {
    if (job.killed) {
        return std.fmt.allocPrint(app.gpa, "{s} ({s}) was cancelled", .{ job.label, job.command });
    }
    return std.fmt.allocPrint(app.gpa, "{s} ({s}) finished — exit {d}", .{ job.label, job.command, job.exit_code });
}

/// Deliver buffered background completions to idle lanes: append the
/// notice to the lane's transcript and, for non-killed jobs, enqueue
/// the model message and start a turn to answer it. A lane mid-turn is
/// left alone (the completion waits); the visible lane is also left
/// alone while the user is typing, so a finishing job never yanks them
/// mid-compose.
pub fn deliverPendingBackground(app: *App) !bool {
    var changed = false;
    // The focused lane — used only to decide visibility ("don't yank the
    // lane the user is typing into"); never reassigned.
    const active = app.thread;
    var i: usize = 0;
    while (i < app.background_modal_state.pending.items.len) {
        const delivery = &app.background_modal_state.pending.items[i];
        const lane = app.laneByGeneration(delivery.owner_generation) orelse {
            freeDelivery(app, delivery);
            _ = app.background_modal_state.pending.orderedRemove(i);
            continue;
        };
        const composing = lane == active and app.inputs.input.buf.realLength() > 0;
        if (lane.turn.state != .idle or composing) {
            i += 1;
            continue;
        }
        _ = lane.transcript.append(app.gpa, .notice, "background", delivery.notice) catch {};
        if (lane == active) changed = true;
        const start_turn = delivery.message != null;
        if (delivery.message) |message| {
            // Atomic enqueue + mirror: a QueueFull drop writes nothing on
            // either side, so the mirror stays 1:1 with the agent queue and
            // `steerSelectedQueued` indices stay aligned.
            _ = queue_mod.enqueueRawMirrored(app, lane, message);
        }
        freeDelivery(app, delivery);
        _ = app.background_modal_state.pending.orderedRemove(i);
        if (start_turn) {
            _ = app.startQueuedTurnOn(lane) catch {};
            return true;
        }
        changed = true;
        // Removed in place — re-check the same index next iteration.
    }
    return changed;
}

pub fn runningBackgroundCount(app: *App) usize {
    const manager = app.background orelse return 0;
    return manager.runningCount();
}

/// Whether two job snapshots render identically (identity, label, command,
/// log path, elapsed, terminating flag).
fn viewsEqual(a: []const tui.background_mod.BackgroundManager.JobView, b: []const tui.background_mod.BackgroundManager.JobView) bool {
    if (a.len != b.len) return false;
    for (a, b) |va, vb| {
        if (va.id != vb.id or va.elapsed_seconds != vb.elapsed_seconds or va.terminating != vb.terminating) return false;
        if (!std.mem.eql(u8, va.label, vb.label)) return false;
        if (!std.mem.eql(u8, va.command, vb.command)) return false;
        if (!std.mem.eql(u8, va.log_path, vb.log_path)) return false;
    }
    return true;
}

/// Replace `cache`'s log tail/note from the selected view: refresh from
/// `views[sel]` when expanded, drop the stale tail when collapsed or the
/// selected job disappeared. Returns true when the visible tail changed.
pub fn refreshModalLogTail(
    gpa: std.mem.Allocator,
    io: std.Io,
    cache: *Cache,
    expanded: bool,
    selection: usize,
    views: []const tui.background_mod.BackgroundManager.JobView,
) bool {
    if (!expanded or views.len == 0) {
        if (cache.log_text.len > 0 or cache.log_note.len > 0) {
            cache.deinitTail(gpa);
            return true;
        }
        return false;
    }
    const sel = @min(selection, views.len - 1);
    const tail = background_tool.readLogTailBounded(
        io,
        gpa,
        views[sel].log_path,
        background_jobs_widget.log_tail_max_lines,
    ) catch |err| {
        // Keep the previous labeled tail; the 250ms gate bounds the retry.
        // FileNotFound is already softened inside the reader, so reaching
        // here means AccessDenied/IO/OOM — worth an operational trail.
        log.warn("background modal log tail read failed: {s}", .{@errorName(err)});
        return false;
    };
    const text_same = std.mem.eql(u8, cache.log_text, tail);
    const note_same = std.mem.eql(u8, cache.log_note, views[sel].log_path);
    if (text_same and note_same) {
        gpa.free(tail);
        return false;
    }
    // Swap tail and note ATOMICALLY: the note names the tail's source, so a
    // failed note dupe keeps the previous consistent pair (retry next gate).
    const note = gpa.dupe(u8, views[sel].log_path) catch {
        gpa.free(tail);
        return false;
    };
    cache.deinitTail(gpa);
    cache.log_text = tail;
    cache.log_note = note;
    return true;
}

/// Refresh the modal's cached display data from the manager snapshot and
/// the selected job's bounded log tail. The ONLY writer of
/// `background_modal_state.cache`: runs from tick and key processing so the
/// draw path stays free of manager/file access. Returns true when visible
/// content changed. `force` bypasses the idle refresh gate (key-driven
/// changes must show immediately).
pub fn refreshBackgroundModalCache(app: *App, force: bool) bool {
    const st = &app.background_modal_state;
    if (!st.modal) {
        if (st.cache) |*c| c.deinit(app.gpa);
        st.cache = null;
        return false;
    }
    if (!force and !st.refreshDue(app.io)) return false;
    defer st.armRefresh(app.io, modal_refresh_ms);

    if (st.cache == null) st.cache = .{};
    const cache: *Cache = &st.cache.?;
    var changed = false;

    // Snapshot: swap in the fresh job views unless they render identically
    // (a quiet tick then neither reallocates nor reports a change). On a
    // transient snapshot error keep the previous snapshot — the 250ms gate
    // bounds the retry — but leave an operational trail: a silent failure
    // would render "No background jobs running." while jobs are alive.
    if (app.background) |manager| {
        if (manager.snapshot(app.gpa)) |fresh| {
            if (viewsEqual(cache.views, fresh)) {
                tui.background_mod.BackgroundManager.freeViews(app.gpa, fresh);
            } else {
                if (cache.views.len > 0) tui.background_mod.BackgroundManager.freeViews(app.gpa, cache.views);
                cache.views = fresh;
                changed = true;
            }
        } else |err| {
            log.warn("background modal snapshot failed: {s}", .{@errorName(err)});
        }
    } else if (cache.views.len > 0) {
        tui.background_mod.BackgroundManager.freeViews(app.gpa, cache.views);
        cache.views = &.{};
        changed = true;
    }

    if (refreshModalLogTail(app.gpa, app.io, cache, st.log_expanded, st.selection, cache.views)) changed = true;
    return changed;
}

/// Close the background modal and drop its cached display data (the
/// refresher would also free it on the next tick, but closing should not
/// leave a bounded log tail pinned until then).
pub fn closeBackgroundModal(app: *App) void {
    app.background_modal_state.modal = false;
    if (app.background_modal_state.cache) |*c| c.deinit(app.gpa);
    app.background_modal_state.cache = null;
}

pub fn toggleBackgroundModal(app: *App) void {
    if (!app.background_modal_state.modal and runningBackgroundCount(app) == 0) return;
    if (app.background_modal_state.modal) {
        closeBackgroundModal(app);
        return;
    }
    app.background_modal_state.modal = true;
    app.background_modal_state.selection = 0;
    app.background_modal_state.cancel_focus = false;
    app.background_modal_state.log_expanded = false;
    // Fill the cache before the first frame draws the modal.
    _ = refreshBackgroundModalCache(app, true);
}

pub fn handleBackgroundModalKey(app: *App, key: vaxis.Key) bool {
    // Keys steer against the LIVE job count while rows render from the cached
    // snapshot; a transient snapshot failure can briefly diverge the two, but
    // the widget clamps the selection and the next successful snapshot
    // reconciles them.
    const count = runningBackgroundCount(app);
    if (count == 0) return false;
    if (app.background_modal_state.selection >= count) app.background_modal_state.selection = count - 1;
    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        if (app.background_modal_state.selection > 0) app.background_modal_state.selection -= 1;
        app.background_modal_state.cancel_focus = false;
        _ = refreshBackgroundModalCache(app, true);
        return true;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        if (app.background_modal_state.selection + 1 < count) app.background_modal_state.selection += 1;
        app.background_modal_state.cancel_focus = false;
        _ = refreshBackgroundModalCache(app, true);
        return true;
    }
    if (key.matches(vaxis.Key.left, .{})) {
        app.background_modal_state.cancel_focus = false;
        return true;
    }
    if (key.matches(vaxis.Key.right, .{})) {
        app.background_modal_state.cancel_focus = true;
        return true;
    }
    // Space toggles the live log-tail panel for the selected job (#37).
    if (key.matches(' ', .{})) {
        app.background_modal_state.log_expanded = !app.background_modal_state.log_expanded;
        _ = refreshBackgroundModalCache(app, true);
        return true;
    }
    if (app.background_modal_state.cancel_focus and key.matches(vaxis.Key.enter, .{})) {
        cancelSelectedBackgroundJob(app);
        return true;
    }
    return false;
}

pub fn cancelSelectedBackgroundJob(app: *App) void {
    const manager = app.background orelse return;
    const views = manager.snapshot(app.gpa) catch |err| {
        log.warn("background cancel snapshot failed: {s}", .{@errorName(err)});
        return;
    };
    defer tui.background_mod.BackgroundManager.freeViews(app.gpa, views);
    if (views.len == 0) return;
    const sel = @min(app.background_modal_state.selection, views.len - 1);
    _ = manager.cancel(views[sel].id);
    app.background_modal_state.cancel_focus = false;
    // Surface the TERMINATING badge immediately instead of on the next tick.
    _ = refreshBackgroundModalCache(app, true);
}

// ── Tests ──

const agent_mod = @import("../agent.zig");
const runtime_mod = @import("../runtime.zig");
const isolatedHome = @import("test_fixture.zig").isolatedHome;

/// A live primary runtime with no provider: delivery takes the
/// `startQueuedTurn` flush+clearQueue branch instead of
/// starting a real worker turn. Same field shape as GitFixture's runtime
/// (lane_lifecycle.zig), minus the git scaffolding.
fn createNoProviderRuntime(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !*runtime_mod.AgentRuntime {
    const runtime = try gpa.create(runtime_mod.AgentRuntime);
    errdefer gpa.destroy(runtime);
    runtime.gpa = gpa;
    runtime.io = io;
    runtime.cwd = ".";
    runtime.home_dir = home_dir;
    runtime.client = .none;
    runtime.base_system_prompt = "test";
    runtime.system_prompt = "test";
    runtime.session_writer = undefined;
    runtime.agent = agent_mod.Agent.init(gpa, io, ".", .none);
    runtime.diagnostics = &.{};
    runtime.owned_client = null;
    runtime.owned_compaction_client = null;
    runtime.owned_naming_client = null;
    runtime.naming_client = .none;
    runtime.skills = &.{};
    runtime.plugin_prompts = &.{};
    return runtime;
}

/// Seed one owned JobView (the shape `refreshBackgroundModalCache` stores).
fn dupSeedViews(gpa: std.mem.Allocator) ![]tui.background_mod.BackgroundManager.JobView {
    const views = try gpa.alloc(tui.background_mod.BackgroundManager.JobView, 1);
    views[0] = .{
        .id = 7,
        .label = try gpa.dupe(u8, "seed"),
        .command = try gpa.dupe(u8, "seed cmd"),
        .log_path = try gpa.dupe(u8, "seed.log"),
        .elapsed_seconds = 3,
        .terminating = false,
    };
    return views;
}

test "refreshModalLogTail follows the selected log and clears when collapsed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const log_path = try @import("../tools/bash_exec.zig").namedTempPath(gpa, "zay-test-modal-tail.log");
    defer gpa.free(log_path);
    defer std.Io.Dir.deleteFile(.cwd(), io, log_path) catch {};

    var file = try std.Io.Dir.createFileAbsolute(io, log_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "alpha\nbeta\ngamma\n");

    var cache: Cache = .{};
    defer cache.deinit(gpa);
    var views = [_]tui.background_mod.BackgroundManager.JobView{.{
        .id = 1,
        .label = try gpa.dupe(u8, "j1"),
        .command = try gpa.dupe(u8, "cmd"),
        .log_path = try gpa.dupe(u8, log_path),
        .elapsed_seconds = 1,
        .terminating = false,
    }};
    defer for (views) |v| {
        gpa.free(v.label);
        gpa.free(v.command);
        gpa.free(v.log_path);
    };

    // Expanded: the tail and the note fill from the selected view.
    try std.testing.expect(refreshModalLogTail(gpa, io, &cache, true, 0, &views));
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\n", cache.log_text);
    try std.testing.expectEqualStrings(log_path, cache.log_note);

    // An unchanged tail reports no visible change (no redraw churn).
    try std.testing.expect(!refreshModalLogTail(gpa, io, &cache, true, 0, &views));

    // A selection past the end clamps to the last view — same tail, no change.
    try std.testing.expect(!refreshModalLogTail(gpa, io, &cache, true, 7, &views));

    // Collapsed: the stale tail is dropped so no wrong job's log lingers.
    try std.testing.expect(refreshModalLogTail(gpa, io, &cache, false, 0, &views));
    try std.testing.expectEqual(@as(usize, 0), cache.log_text.len);
    try std.testing.expectEqual(@as(usize, 0), cache.log_note.len);
}

test "background modal cache lifecycle: stale data dropped when the job disappears, freed on close" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var home = try isolatedHome(gpa, io);
    defer home.deinit(gpa);
    const runtime = try createNoProviderRuntime(gpa, io, home.path);
    defer gpa.destroy(runtime);
    defer runtime.agent.deinit();
    var app = try tui.App.init(io, gpa, &runtime.agent);
    defer app.deinit();

    // Seed a cache as if a job had been displayed (owned copies, exactly
    // what the refresher stores).
    app.background_modal_state.modal = true;
    app.background_modal_state.cache = .{
        .views = try dupSeedViews(gpa),
        .log_text = try gpa.dupe(u8, "old tail\n"),
        .log_note = try gpa.dupe(u8, "old-path.log"),
    };

    // No manager: the selected job disappeared — the stale views AND the
    // log tail are dropped, and the refresh reports a visible change.
    try std.testing.expect(refreshBackgroundModalCache(&app, true));
    try std.testing.expectEqual(@as(usize, 0), app.background_modal_state.cache.?.views.len);
    try std.testing.expectEqual(@as(usize, 0), app.background_modal_state.cache.?.log_text.len);
    try std.testing.expectEqual(@as(usize, 0), app.background_modal_state.cache.?.log_note.len);

    // The idle gate blocks a follow-up refresh (no redraw churn).
    try std.testing.expect(!refreshBackgroundModalCache(&app, false));
    // And a forced refresh is idempotent on the empty cache.
    try std.testing.expect(!refreshBackgroundModalCache(&app, true));

    // Close frees the remaining cache (leak-checked by the allocator).
    closeBackgroundModal(&app);
    try std.testing.expect(app.background_modal_state.cache == null);

    // Refresh with the modal closed is a no-op that keeps it freed.
    try std.testing.expect(!refreshBackgroundModalCache(&app, true));
    try std.testing.expect(app.background_modal_state.cache == null);
}

test "viewsEqual compares every rendered field" {
    const gpa = std.testing.allocator;
    const mk = struct {
        fn view(id: u32, label: []const u8, elapsed: u64, term: bool) tui.background_mod.BackgroundManager.JobView {
            return .{
                .id = id,
                .label = @constCast(label),
                .command = @constCast("cmd"),
                .log_path = @constCast("a.log"),
                .elapsed_seconds = elapsed,
                .terminating = term,
            };
        }
    }.view;
    _ = gpa;

    try std.testing.expect(viewsEqual(&.{}, &.{}));
    try std.testing.expect(!viewsEqual(&.{mk(1, "a", 1, false)}, &.{}));
    try std.testing.expect(viewsEqual(&.{mk(1, "a", 1, false)}, &.{mk(1, "a", 1, false)}));
    // An elapsed-second tick is a visible change (row timer must redraw).
    try std.testing.expect(!viewsEqual(&.{mk(1, "a", 1, false)}, &.{mk(1, "a", 2, false)}));
    try std.testing.expect(!viewsEqual(&.{mk(1, "a", 1, false)}, &.{mk(1, "a", 1, true)}));
    try std.testing.expect(!viewsEqual(&.{mk(1, "a", 1, false)}, &.{mk(2, "a", 1, false)}));
    try std.testing.expect(!viewsEqual(&.{mk(1, "a", 1, false)}, &.{mk(1, "b", 1, false)}));
}

test "M2: a QueueFull background drop gains no mirror entry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var home = try isolatedHome(gpa, io);
    defer home.deinit(gpa);
    const runtime = try createNoProviderRuntime(gpa, io, home.path);
    defer gpa.destroy(runtime);
    defer runtime.agent.deinit();
    var app = try tui.App.init(io, gpa, &runtime.agent);
    defer app.deinit();
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = runtime, .owns = false } };

    // Fill the agent queue to capacity so the delivery's enqueue fails.
    for (0..runtime.agent.message_queue_storage.len) |_| try runtime.agent.enqueueRaw("filler");

    try app.background_modal_state.pending.append(app.gpa, .{
        .owner_generation = 1,
        .notice = try gpa.dupe(u8, "job (cmd) finished — exit 0"),
        .message = try gpa.dupe(u8, "job result"),
    });

    _ = try deliverPendingBackground(&app);

    // The message is dropped (QueueFull) and the mirror must NOT gain the
    // orphan entry — a mirror ahead of the agent queue shifts every
    // `steerSelectedQueued` index. The notice still lands, the delivery is
    // consumed, and the no-provider branch clears the stranded queue.
    try std.testing.expectEqual(@as(usize, 0), app.thread.queued.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.background_modal_state.pending.items.len);
    try std.testing.expectEqual(@as(u32, 0), runtime.agent.message_queue.len());
    try std.testing.expect(app.thread.transcript.containsText("finished — exit 0"));
}

test "M2: a no-provider delivery clears the mirror in lockstep with the agent queue" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var home = try isolatedHome(gpa, io);
    defer home.deinit(gpa);
    const runtime = try createNoProviderRuntime(gpa, io, home.path);
    defer gpa.destroy(runtime);
    defer runtime.agent.deinit();
    var app = try tui.App.init(io, gpa, &runtime.agent);
    defer app.deinit();
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = runtime, .owns = false } };

    try app.background_modal_state.pending.append(app.gpa, .{
        .owner_generation = 1,
        .notice = try gpa.dupe(u8, "job (cmd) finished — exit 0"),
        .message = try gpa.dupe(u8, "job result"),
    });

    _ = try deliverPendingBackground(&app);

    // The enqueue succeeded, then the no-provider branch dropped the message
    // instead of starting a doomed turn: the mirror must be flushed in
    // lockstep with the cleared agent queue (the raw entry is dropped
    // unrendered — the notice above is the only transcript record).
    try std.testing.expectEqual(@as(usize, 0), app.thread.queued.items.len);
    try std.testing.expectEqual(@as(u32, 0), runtime.agent.message_queue.len());
    try std.testing.expectEqual(@as(usize, 0), app.background_modal_state.pending.items.len);
    try std.testing.expect(app.thread.transcript.containsText("finished — exit 0"));
    try std.testing.expect(!app.thread.transcript.containsText("job result"));
}

test "no-provider delivery gates on the target lane, not the focused lane" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var home = try isolatedHome(gpa, io);
    defer home.deinit(gpa);
    const runtime = try createNoProviderRuntime(gpa, io, home.path);
    defer gpa.destroy(runtime);
    defer runtime.agent.deinit();
    var app = try tui.App.init(io, gpa, &runtime.agent);
    defer app.deinit();
    // Target lane (primary) is live but has no provider.
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = runtime, .owns = false } };

    // Focus an idle second lane so `app.thread` is NOT the delivery target.
    // The gate must read the target lane's runtime: keyed off `app.thread`
    // it drops the target's queued message (focused lane no-provider) or
    // starts a doomed turn (focused lane has a provider, target doesn't).
    const focused = try gpa.create(tui.Thread);
    focused.* = .{};
    try app.threads.append(focused);
    app.thread = focused;

    try app.background_modal_state.pending.append(app.gpa, .{
        .owner_generation = 1,
        .notice = try gpa.dupe(u8, "job (cmd) finished — exit 0"),
        .message = try gpa.dupe(u8, "job result"),
    });

    _ = try deliverPendingBackground(&app);

    // The target lane took the no-provider branch (queue flushed + cleared,
    // no doomed turn); the focused lane stayed untouched.
    const target = app.threads.slice()[0];
    try std.testing.expectEqual(@as(u32, 0), runtime.agent.message_queue.len());
    try std.testing.expectEqual(@as(usize, 0), target.queued.items.len);
    try std.testing.expect(!target.turn.isActive());
    try std.testing.expect(!focused.turn.isActive());
    try std.testing.expectEqual(@as(usize, 0), app.background_modal_state.pending.items.len);
    try std.testing.expect(target.transcript.containsText("finished — exit 0"));
    try std.testing.expect(!target.transcript.containsText("job result"));
}

test "INV-BG-OWNER-1: late background completion drops cleanly when owning lane is deleted" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var home = try isolatedHome(gpa, io);
    defer home.deinit(gpa);
    const runtime = try createNoProviderRuntime(gpa, io, home.path);
    defer gpa.destroy(runtime);
    defer runtime.agent.deinit();
    var app = try tui.App.init(io, gpa, &runtime.agent);
    defer app.deinit();

    // Enqueue delivery for a non-existent lane generation (e.g. 999).
    try app.background_modal_state.pending.append(app.gpa, .{
        .owner_generation = 999,
        .notice = try gpa.dupe(u8, "job (cmd) finished — exit 0"),
        .message = try gpa.dupe(u8, "job result"),
    });

    _ = try deliverPendingBackground(&app);

    // Must drop the delivery without crashing or dereferencing stale memory.
    try std.testing.expectEqual(@as(usize, 0), app.background_modal_state.pending.items.len);
}
