//! Quit double-press state machine.
//!
//! Exiting on a second Ctrl+C/Ctrl+D press is subtle because terminals differ:
//! a held chord auto-repeats, Windows may deliver the modifier release
//! separately, and POSIX terminals send no release at all. Keep every
//! transition here, with the clock injected, so the rule is testable without
//! an App or real time.

const std = @import("std");

/// Maximum gap between two presses for the second to confirm exit.
pub const double_press_window_ms: u32 = 1500;

/// Gaps below this between two presses are treated as auto-repeat of one held
/// chord, not as a second physical press.
pub const auto_repeat_gap_ms: u32 = 100;

pub const State = enum { none, pending, confirmed };

pub const PressOutcome = enum {
    /// First press: the quit prompt is armed.
    armed,
    /// Auto-repeat of the same held chord: consume it and keep waiting.
    swallowed,
    /// A second real press inside the window: exit.
    confirmed,
};

pub const Gate = struct {
    state: State = .none,
    pending_at: std.Io.Timestamp = .zero,
    key_released: bool = false,

    pub fn isActive(self: *const Gate) bool {
        return self.state != .none;
    }

    pub fn isPending(self: *const Gate) bool {
        return self.state == .pending;
    }

    pub fn isConfirmed(self: *const Gate) bool {
        return self.state == .confirmed;
    }

    pub fn pendingAt(self: *const Gate) ?std.Io.Timestamp {
        return if (self.state == .pending) self.pending_at else null;
    }

    pub fn pendingKeyReleased(self: *const Gate) bool {
        return self.state == .pending and self.key_released;
    }

    /// A key release proved the chord ended. POSIX terminals never send one, so
    /// there the gap check carries the auto-repeat suppression instead.
    pub fn markKeyReleased(self: *Gate) void {
        if (self.state == .pending) self.key_released = true;
    }

    /// Dismiss an armed prompt without touching an already-confirmed exit.
    pub fn cancelPending(self: *Gate) void {
        if (self.state != .pending) return;
        self.state = .none;
        self.key_released = false;
    }

    /// Request exit from a command such as `/exit`; the next tick drains it.
    pub fn confirm(self: *Gate) void {
        self.state = .confirmed;
    }

    /// Clear a prompt whose double-press window has elapsed. Returns true when
    /// a stale prompt was cleared so the caller can redraw.
    pub fn expire(self: *Gate, now: std.Io.Timestamp) bool {
        if (self.state != .pending) return false;
        const elapsed_ns = self.pending_at.durationTo(now).nanoseconds;
        const window_ns: i128 = @as(i128, double_press_window_ms) * std.time.ns_per_ms;
        if (elapsed_ns > window_ns) {
            self.state = .none;
            self.key_released = false;
            return true;
        }
        return false;
    }

    /// Classify a quit-chord press. Auto-repeat is swallowed unless a release
    /// proved the previous press ended; a real second press inside the window
    /// confirms; anything else re-arms at `now`. Once confirmed, stays
    /// confirmed.
    pub fn onPress(self: *Gate, now: std.Io.Timestamp) PressOutcome {
        if (self.state == .confirmed) return .confirmed;
        if (self.state == .pending) {
            const gap_ns = self.pending_at.durationTo(now).nanoseconds;
            const auto_repeat_ns: i128 = @as(i128, auto_repeat_gap_ms) * std.time.ns_per_ms;
            const is_rapid_repeat = gap_ns >= 0 and gap_ns < auto_repeat_ns;
            if (!self.key_released and is_rapid_repeat) return .swallowed;
            const window_ns: i128 = @as(i128, double_press_window_ms) * std.time.ns_per_ms;
            if (gap_ns >= 0 and gap_ns <= window_ns) {
                self.state = .confirmed;
                return .confirmed;
            }
        }
        self.state = .pending;
        self.pending_at = now;
        self.key_released = false;
        return .armed;
    }
};

const ms = std.time.ns_per_ms;

fn ts(nanoseconds: i96) std.Io.Timestamp {
    return .{ .nanoseconds = nanoseconds };
}

test "first press arms and a released second press confirms" {
    var gate: Gate = .{};
    try std.testing.expectEqual(PressOutcome.armed, gate.onPress(ts(0)));
    try std.testing.expect(gate.isPending());
    try std.testing.expectEqual(ts(0), gate.pendingAt().?);
    try std.testing.expect(!gate.pendingKeyReleased());

    gate.markKeyReleased();
    try std.testing.expect(gate.pendingKeyReleased());
    try std.testing.expectEqual(PressOutcome.confirmed, gate.onPress(ts(500 * ms)));
    try std.testing.expect(gate.isConfirmed());
    try std.testing.expect(!gate.isPending());
}

test "rapid repeat without a release is swallowed" {
    var gate: Gate = .{};
    try std.testing.expectEqual(PressOutcome.armed, gate.onPress(ts(0)));
    try std.testing.expectEqual(PressOutcome.swallowed, gate.onPress(ts(auto_repeat_gap_ms * ms - 1)));
    try std.testing.expect(gate.isPending());
}

test "a deliberate second press inside the window confirms without a release" {
    var gate: Gate = .{};
    try std.testing.expectEqual(PressOutcome.armed, gate.onPress(ts(0)));
    try std.testing.expectEqual(PressOutcome.confirmed, gate.onPress(ts(auto_repeat_gap_ms * ms)));
}

test "a press after the window re-arms instead of exiting" {
    var gate: Gate = .{};
    try std.testing.expectEqual(PressOutcome.armed, gate.onPress(ts(0)));
    try std.testing.expectEqual(PressOutcome.armed, gate.onPress(ts((double_press_window_ms + 100) * ms)));
    try std.testing.expect(gate.isPending());
    try std.testing.expectEqual(ts((double_press_window_ms + 100) * ms), gate.pendingAt().?);
}

test "expire clears only after the window" {
    var gate: Gate = .{};
    try std.testing.expectEqual(PressOutcome.armed, gate.onPress(ts(0)));
    try std.testing.expect(!gate.expire(ts(double_press_window_ms * ms)));
    try std.testing.expect(gate.isPending());
    try std.testing.expect(gate.expire(ts(double_press_window_ms * ms + 1)));
    try std.testing.expect(!gate.isActive());
}

test "a backwards clock re-arms rather than confirming" {
    var gate: Gate = .{};
    try std.testing.expectEqual(PressOutcome.armed, gate.onPress(ts(1000 * ms)));
    try std.testing.expectEqual(PressOutcome.armed, gate.onPress(ts(0)));
}

test "cancelPending dismisses a prompt but not a confirmed exit" {
    var gate: Gate = .{};
    try std.testing.expectEqual(PressOutcome.armed, gate.onPress(ts(0)));
    gate.cancelPending();
    try std.testing.expect(!gate.isActive());

    gate.confirm();
    gate.cancelPending();
    try std.testing.expect(gate.isConfirmed());
}

test "onPress does not downgrade an already-confirmed exit" {
    var gate: Gate = .{};
    gate.confirm();
    try std.testing.expectEqual(PressOutcome.confirmed, gate.onPress(ts(0)));
    try std.testing.expect(gate.isConfirmed());
}
