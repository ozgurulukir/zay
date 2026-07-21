//! Background-job delivery plumbing.
//!
//! Pulled out of `tui.zig` (R4 of `_pm/Projects/tui-split`) — the
//! poll/format/deliver triplet was a focused 90-line cluster that only
//! read `background_modal_state.pending` and the global `background`
//! manager, so it earns its own module. App methods remain as
//! 1-line delegates so existing call sites compile unchanged.

const std = @import("std");
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
        app.background_modal_state.pending.append(app.gpa, .{
            .owner = job.owner,
            .notice = notice,
            .message = message,
        }) catch {
            app.gpa.free(notice);
            if (message) |m| app.gpa.free(m);
        };
        job.deinit(app.gpa);
    }
    return finished.len > 0;
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
        const lane = app.laneForAgent(@ptrCast(@alignCast(delivery.owner))) orelse {
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
