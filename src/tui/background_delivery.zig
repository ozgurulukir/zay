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

const App = tui.App;
const BackgroundDelivery = tui.BackgroundDelivery;

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
        // Layer crossing: `background.BackgroundManager.Finished.owner` is
        // `*anyopaque` (the manager is layer-agnostic about which agent
        // owns a job). The TUI, which knows the agent, types the owner
        // here — one explicit cast at the boundary, none at the use site.
        const owner: *tui.Agent = @ptrCast(@alignCast(job.owner));
        app.background_modal_state.pending.append(app.gpa, .{
            .owner = owner,
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
    const active = app.thread;
    defer app.thread = active;
    var i: usize = 0;
    while (i < app.background_modal_state.pending.items.len) {
        const delivery = &app.background_modal_state.pending.items[i];
        const lane = app.laneForAgent(delivery.owner) orelse {
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
        if (delivery.message) |message| lane.agent.?.enqueueRaw(message) catch {};
        freeDelivery(app, delivery);
        _ = app.background_modal_state.pending.orderedRemove(i);
        if (start_turn) {
            app.thread = lane;
            app.startDeliveryTurnOnCurrentThread() catch {};
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

pub fn toggleBackgroundModal(app: *App) void {
    if (!app.background_modal_state.modal and runningBackgroundCount(app) == 0) return;
    app.background_modal_state.modal = !app.background_modal_state.modal;
    app.background_modal_state.selection = 0;
    app.background_modal_state.cancel_focus = false;
}

pub fn handleBackgroundModalKey(app: *App, key: vaxis.Key) bool {
    const count = runningBackgroundCount(app);
    if (count == 0) return false;
    if (app.background_modal_state.selection >= count) app.background_modal_state.selection = count - 1;
    if (key.matches(vaxis.Key.up, .{})) {
        if (app.background_modal_state.selection > 0) app.background_modal_state.selection -= 1;
        app.background_modal_state.cancel_focus = false;
        return true;
    }
    if (key.matches(vaxis.Key.down, .{})) {
        if (app.background_modal_state.selection + 1 < count) app.background_modal_state.selection += 1;
        app.background_modal_state.cancel_focus = false;
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
    if (app.background_modal_state.cancel_focus and key.matches(vaxis.Key.enter, .{})) {
        cancelSelectedBackgroundJob(app);
        return true;
    }
    return false;
}

pub fn cancelSelectedBackgroundJob(app: *App) void {
    const manager = app.background orelse return;
    const views = manager.snapshot(app.gpa) catch return;
    defer tui.background_mod.BackgroundManager.freeViews(app.gpa, views);
    if (views.len == 0) return;
    const sel = @min(app.background_modal_state.selection, views.len - 1);
    _ = manager.cancel(views[sel].id);
    app.background_modal_state.cancel_focus = false;
}
