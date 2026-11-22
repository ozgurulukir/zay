//! Prompt-input undo/redo (issue #486).
//!
//! Snapshots are taken by DIFFING the prompt buffer on the UI tick, so no
//! edit path (typed characters go straight to the vendored TextField) needs
//! interception: when the buffer changes, the previous (text, cursor) pair
//! is pushed onto the undo stack unless the change lands inside the
//! coalescing window of the previous one (typing bursts stay one entry).
//! Restore uses the established clearInput + insertSliceAtCursor pair with a
//! gap move to the snapshot cursor.

const std = @import("std");
const tui = @import("../tui.zig");

const App = tui.App;
const agent_mod = @import("../agent.zig");

const max_undo_entries: usize = 100;
/// Edits within this window of the previous one coalesce into a single undo
/// entry (typing "hello" is one step, not five).
const coalesce_window_ms: i64 = 250;

const Snapshot = struct {
    text: []u8,
    cursor: usize,
};

pub const InputUndo = struct {
    stack: std.ArrayList(Snapshot) = .empty,
    redo: std.ArrayList(Snapshot) = .empty,
    last_seen: ?Snapshot = null,
    last_seen_ms: i64 = 0,

    pub fn deinit(self: *InputUndo, gpa: std.mem.Allocator) void {
        for (self.stack.items) |entry| gpa.free(entry.text);
        self.stack.deinit(gpa);
        for (self.redoable()) |entry| gpa.free(entry.text);
        self.redo.deinit(gpa);
        if (self.last_seen) |seen| gpa.free(seen.text);
        self.* = undefined;
    }

    /// Per-tick observation: snapshot a changed prompt buffer. `now_ms` is a
    /// monotonic millisecond clock. Returns true when the prompt changed
    /// (the caller folds it into the tick's visible_change).
    pub fn observe(self: *InputUndo, app: *App, now_ms: i64) bool {
        const buf = &app.inputs.input.buf;
        const current = concatText(app) orelse return false;
        defer app.gpa.free(current);

        if (self.last_seen) |seen| {
            if (seen.text.len == current.len and std.mem.eql(u8, seen.text, current)) {
                // Cursor-only moves refresh the recorded cursor without a
                // snapshot: undo restores text AND cursor, and a pure cursor
                // move is not an edit.
                self.last_seen.?.cursor = buf.cursor;
                return false;
            }
        }
        if (app.inputs.paste_stash.entries.items.len > 0) {
            app.inputs.paste_stash.syncWithText(app.gpa, current);
        }
        // The buffer changed since the last tick. Push the PREVIOUS state
        // (the pre-edit text) unless this edit coalesces with the last one.
        if (self.last_seen) |seen| {
            if (self.stack.items.len == 0 or (now_ms - self.last_seen_ms) > coalesce_window_ms) {
                self.stack.append(app.gpa, seen) catch return false;
                if (self.stack.items.len > max_undo_entries) {
                    const oldest = self.stack.orderedRemove(0);
                    app.gpa.free(oldest.text);
                }
            } else {
                app.gpa.free(seen.text);
                // The previous entry on the stack (if any) is extended by
                // dropping its separate record: the stack top still holds the
                // pre-burst text, which is the state undo should restore.
            }
        } else {
            // First observation: record the initial state so the FIRST edit
            // can undo back to the empty prompt.
            const initial_text = app.gpa.dupe(u8, current) catch return false;
            self.last_seen = .{ .text = initial_text, .cursor = buf.cursor };
            self.last_seen_ms = now_ms;
            return false;
        }
        // Record the new state.
        const copy = app.gpa.dupe(u8, current) catch return false;
        self.last_seen = .{ .text = copy, .cursor = buf.cursor };
        self.last_seen_ms = now_ms;
        // A new edit invalidates the redo branch (standard editor semantics).
        for (self.redo.items) |entry| app.gpa.free(entry.text);
        self.redo.clearRetainingCapacity();
        return true;
    }

    /// Undo one coalesced edit group. Returns true when the prompt changed.
    pub fn undo(self: *InputUndo, app: *App) bool {
        const entry = self.stack.pop() orelse return false;
        // The current state (last_seen) becomes the redo target — its bytes
        // MOVE into the redo list, so detach last_seen before restore runs.
        if (self.last_seen) |seen| {
            self.redo.append(app.gpa, seen) catch {
                self.stack.append(app.gpa, entry) catch {};
                return false;
            };
        }
        self.last_seen = null;
        self.restore(app, entry);
        if (app.inputs.paste_stash.entries.items.len > 0) {
            app.inputs.paste_stash.syncWithText(app.gpa, entry.text);
        }
        // The popped snapshot's text was consumed by restore; its allocation
        // ends here.
        app.gpa.free(entry.text);
        return true;
    }

    /// Redo one coalesced edit group. Returns true when the prompt changed.
    pub fn redoStep(self: *InputUndo, app: *App) bool {
        const entry = self.redo.pop() orelse return false;
        if (self.last_seen) |seen| {
            self.stack.append(app.gpa, seen) catch {
                self.redo.append(app.gpa, entry) catch {};
                return false;
            };
        }
        self.last_seen = null;
        self.restore(app, entry);
        if (app.inputs.paste_stash.entries.items.len > 0) {
            app.inputs.paste_stash.syncWithText(app.gpa, entry.text);
        }
        app.gpa.free(entry.text);
        return true;
    }

    fn redoable(self: *InputUndo) []Snapshot {
        return self.redo.items;
    }

    fn restore(self: *InputUndo, app: *App, snapshot: Snapshot) void {
        app.clearInput();
        app.inputs.input.insertSliceAtCursor(snapshot.text) catch return;
        // Cursor to the snapshot position: move the gap by the delta (the
        // same pattern Ctrl+A/Home uses).
        const cursor_target = @min(snapshot.cursor, snapshot.text.len);
        const current_cursor = app.inputs.input.buf.cursor;
        if (cursor_target < current_cursor) {
            app.inputs.input.buf.moveGapRight(current_cursor - cursor_target);
        } else if (cursor_target > current_cursor) {
            app.inputs.input.buf.moveGapLeft(cursor_target - current_cursor);
        }
        // The restored state becomes the observed state immediately, so the
        // next tick does not re-snapshot the restore itself.
        const copy = app.gpa.dupe(u8, snapshot.text) catch return;
        if (self.last_seen) |seen| app.gpa.free(seen.text);
        self.last_seen = .{ .text = copy, .cursor = cursor_target };
        self.last_seen_ms = nowMs(app);
    }

    fn nowMs(app: *App) i64 {
        return std.Io.Clock.now(.awake, app.getIo()).toMilliseconds();
    }
};

/// The prompt text as one contiguous buffer, or null on OOM. Callers own the
/// result.
pub fn concatText(app: *App) ?[]u8 {
    const buf = &app.inputs.input.buf;
    const first = buf.firstHalf();
    const second = buf.secondHalf();
    const joined = app.gpa.alloc(u8, first.len + second.len) catch return null;
    @memcpy(joined[0..first.len], first);
    @memcpy(joined[first.len..], second);
    return joined;
}

test "observe snapshots the empty prompt once, then coalesces bursts" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    var undo_state: InputUndo = .{};
    defer undo_state.deinit(gpa);

    // First observation records the empty state without a snapshot push.
    try std.testing.expect(!undo_state.observe(&app, 0));
    try std.testing.expectEqual(@as(usize, 0), undo_state.stack.items.len);

    // The first edit burst pushes its pre-edit state (the empty prompt):
    // one burst is one undo entry.
    try app.inputs.input.insertSliceAtCursor("hello");
    try std.testing.expect(undo_state.observe(&app, 100));
    try std.testing.expectEqual(@as(usize, 1), undo_state.stack.items.len);
    try std.testing.expectEqualStrings("", undo_state.stack.items[0].text);

    // A later burst (outside the coalescing window) pushes "hello".
    try app.inputs.input.insertSliceAtCursor(" world");
    try std.testing.expect(undo_state.observe(&app, 1000));
    try std.testing.expectEqual(@as(usize, 2), undo_state.stack.items.len);
    try std.testing.expectEqualStrings("hello", undo_state.stack.items[1].text);

    // Undo restores "hello"; redo returns to "hello world".
    try std.testing.expect(undo_state.undo(&app));
    {
        const text = concatText(&app).?;
        defer app.gpa.free(text);
        try std.testing.expectEqualStrings("hello", text);
    }
    try std.testing.expect(undo_state.redoStep(&app));
    {
        const text = concatText(&app).?;
        defer app.gpa.free(text);
        try std.testing.expectEqualStrings("hello world", text);
    }
}
