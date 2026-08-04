//! Manual `/compact` — the non-blocking command dispatch and the per-tick
//! poll that drives it to completion.
//!
//! The old handler ran `agent.forceCompact()` synchronously on the UI thread,
//! blocking the event loop for the whole summarizer request (up to the
//! request timeout) — the app froze with no repaint, no input, no cancel.
//! The manual compact is now two-phase: `requestManualCompact` snapshots the
//! prefix and spawns the summarizer thread (fast, never blocks), and the UI
//! tick loop polls `agent.pollManualCompact` until the summary lands, keeping
//! the UI live. The agent owns the pending flags and the summarizer thread;
//! this module owns the command dispatch, the per-lane poll, and the notice
//! text.

const std = @import("std");

const tui = @import("../tui.zig");

const App = tui.App;

/// Error → user-facing notice text for the manual compact path. `@errorName`
/// covers anything the switch doesn't name (provider errors, etc.).
pub fn compactErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.NoCompactionClient => "No compaction client configured — compaction unavailable",
        error.UnknownContextWindow => "Context window unknown — compaction unavailable",
        error.NoSessionWriter => "No active session — compaction unavailable",
        error.CompactionInProgress => "Compaction is already in progress",
        error.CompactionNotReady => "Compaction did not produce a result",
        error.CompactionFailed => "Background compaction failed",
        error.NothingToCompact => "Nothing to compact — the recent history already fits the retention budget",
        else => @errorName(err),
    };
}

/// Whether any lane's agent has a manual compact in flight. Feeds the tick
/// loop's `should_tick` and the submit-time `ensureTick`, so the poll keeps
/// running (and the first tick gets scheduled) while a compact is pending.
pub fn manualCompactActive(app: *const App) bool {
    for (app.threads.items) |lane| {
        if (lane.agent) |agent| {
            if (agent.manual_compact_pending) return true;
        }
    }
    return false;
}

/// Dispatch the `/compact` command on the active lane. Never blocks — the
/// heavy summarizer request runs on the agent's own thread. Returns true when
/// the compact was accepted (the UI should keep ticking); false when a notice
/// was appended instead (turn in progress, no engine, guard error).
pub fn requestManualCompact(app: *App) !bool {
    if (app.thread.turn.isActive()) {
        _ = try app.thread.transcript.append(app.gpa, .notice, "compaction", "Cannot compact while a turn is in progress. Wait for it to finish.");
        return false;
    }
    const agent = app.thread.agent orelse {
        _ = try app.thread.transcript.append(app.gpa, .notice, "compaction", "No active session — compaction unavailable");
        return false;
    };
    agent.requestManualCompact() catch |err| {
        _ = try app.thread.transcript.append(app.gpa, .notice, "compaction", compactErrorText(err));
        return false;
    };
    // An animated status row (spinner + text) so the user sees the compact is
    // in flight, not a frozen transcript. The glyph advances with the shared
    // loading frame; the row freezes once the summary lands.
    _ = try app.thread.transcript.append(app.gpa, .status, "waiting for background summary…", "");
    return true;
}

/// Poll every lane's in-flight manual compact from the UI tick loop. Appends
/// the completion or error notice to the lane that owns the compact, and
/// returns true when any visible state changed. Lane scoping mirrors
/// `lifecycle.drainAgentEvents`: `app.thread` is a `*Thread` into
/// `threads.items`, so the notice lands on the right transcript.
pub fn drainManualCompactions(app: *App) !bool {
    var visible_change = false;
    const active = app.thread;
    for (app.threads.items) |lane| {
        const agent = lane.agent orelse continue;
        if (!agent.manual_compact_pending) continue;

        app.thread = lane;
        defer app.thread = active;

        const result = agent.pollManualCompact() catch |err| {
            _ = try app.thread.transcript.append(app.gpa, .notice, "compaction", compactErrorText(err));
            visible_change = true;
            continue;
        };
        if (result) |info| {
            var buffer: [128]u8 = undefined;
            const text = std.fmt.bufPrint(
                &buffer,
                "compacted context ~{d} -> ~{d} tokens",
                .{ info.tokens_before, info.tokens_after },
            ) catch "compacted context";
            _ = try app.thread.transcript.append(app.gpa, .info, "notice", text);
            visible_change = true;
        }
        // Null while the summarizer is still producing — the tick loop keeps
        // going because `manualCompactActive` stays true.
    }
    return visible_change;
}
