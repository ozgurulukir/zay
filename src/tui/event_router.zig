//! Event router for the TUI root widget.
//!
//! Pulled out of `tui.zig` (R1 of `_pm/Projects/tui-split`) — the original
//! `captureEvent` was ~200 lines, dispatching three event kinds with deeply
//! nested mode/key checks. Centralising the switch here makes the routes
//! visible at a glance and gives us a place to grow a per-event table later
//! without re-threading the giant struct methods.
//!
//! Behavioural identity is preserved: every key combo, every side effect
//! matches the pre-refactor implementation. Only the location changed.
//!
//! Note: Zig 0.16 forbids `pub` on struct fields, so this module reads and
//! writes `App` state through dedicated `pub fn` accessors on `App` (added
//! alongside the extraction; see `tui.zig`). R3 will move those accessors
//! into proper sub-structs.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../tui.zig");

const App = tui.App;
const RootWidget = tui.RootWidget;
const provider_model = @import("provider_model.zig");
const clipboard_helper = @import("clipboard_helper.zig");

const command_router = @import("command_router.zig");

/// Top-level event entry, called by vxfw for every event the root receives.
///
/// Forwards to the per-event-kind handlers below.
pub fn captureEvent(
    app: *App,
    root: *RootWidget,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
) anyerror!void {
    switch (event) {
        .init => try routeInit(app, root, ctx),
        .mouse => |mouse| try routeMouse(app, root, ctx, mouse),
        .key_press => |key| try routeKey(app, root, ctx, key),
        .paste => |text| {
            try clipboard_helper.pasteToFocusedInput(app, text);
            ctx.consumeAndRedraw();
        },
        else => {},
    }
}

fn routeInit(app: *App, root: *RootWidget, ctx: *vxfw.EventContext) !void {
    try ctx.requestFocus(app.inputWidget());
    try root.ensureTick(ctx);
    // Warm the diff cache in the background so the first `/diff` opens
    // instantly instead of cold-loading.
    app.scheduleDiffRefresh() catch {};
    // Warm the model catalogue in the background: this one fetch both
    // populates the model picker and drives the provider [CONNECTED] badges
    // (via per-provider outcomes), so an expired key shows DISCONNECTED
    // without a separate probe.
    provider_model.startModelLoad(app, .connected_provider, false) catch {};
    ctx.consumeAndRedraw();
}

fn routeMouse(
    app: *App,
    root: *RootWidget,
    ctx: *vxfw.EventContext,
    mouse: vaxis.Mouse,
) !void {
    // Scrolling may bring the logo back into view; the tick stops itself
    // again on the next frame if it didn't.
    try root.ensureTick(ctx);
    if (app.getMode() == .help) {
        if (mouse.button == .wheel_up) {
            app.pickers.help.scrollUp(2);
            ctx.consumeAndRedraw();
            return;
        }
        if (mouse.button == .wheel_down) {
            app.pickers.help.scrollDown(2, 21);
            ctx.consumeAndRedraw();
            return;
        }
    }
    if (mouse.button == .wheel_up) app.setThreadAutoScroll(false);
    if (mouse.button == .wheel_down) app.updateMouseAutoScroll();
    if (mouse.type == .press and mouse.button == .left) {
        if (app.getLanesChipRect()) |rect| {
            if (rect.contains(mouse.row, mouse.col)) {
                app.setSplit(true);
                ctx.consumeAndRedraw();
                return;
            }
        }
    }
}

fn routeKey(
    app: *App,
    root: *RootWidget,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) !void {
    try root.ensureTick(ctx);
    // The diff viewer is a self-contained full-screen mode: it owns every
    // key (including Esc) so it can manage its own sub-states.
    if (app.isDiffViewerMode()) {
        try root.handleDiffViewerEvent(ctx, key);
        return;
    }
    // Global Ctrl+V / Shift+Insert clipboard paste into active input.
    if (key.matches('v', .{ .ctrl = true }) or key.matches(vaxis.Key.insert, .{ .shift = true })) {
        if (try clipboard_helper.pasteFromSystemClipboard(app)) {
            ctx.consumeAndRedraw();
            return;
        }
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        try handleEscapeSequence(app, root, ctx);
        return;
    }
    if (key.matches('o', .{ .ctrl = true })) {
        app.clearPendingQuitAt();
        app.toggleBackgroundModal();
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('l', .{ .ctrl = true }) or key.matches('l', .{ .super = true })) {
        app.clearPendingQuitAt();
        app.toggleLaneFullscreen();
        ctx.consumeAndRedraw();
        return;
    }
    // While the jobs modal is open it owns navigation/cancel keys.
    if (app.getBackgroundModal() and app.isNormalMode()) {
        app.clearPendingQuitAt();
        if (app.handleBackgroundModalKey(key)) ctx.consumeAndRedraw() else ctx.consumeEvent();
        return;
    }
    if (app.nav.quit == .confirmed) {
        ctx.quit = true;
        ctx.consume_event = true;
        return;
    }
    if (try handleQuitSequence(app, ctx, key)) return;
    // Any other key cancels the pending-quit prompt.
    app.clearPendingQuitAt();
    if (app.permissionPending()) {
        if (try app.handlePermissionKey(key)) {
            ctx.consumeAndRedraw();
        } else {
            ctx.consumeEvent();
        }
        return;
    }
    if (tui.shouldOpenCommandMenuForSlash(app, key)) {
        try app.openCommandMenu();
        try root.syncFocus(ctx);
        ctx.consumeAndRedraw();
        return;
    }
    if (app.isNormalMode() and key.matches(vaxis.Key.enter, .{ .shift = true })) {
        try app.insertInputNewline();
        ctx.consumeAndRedraw();
        return;
    }
    if (command_router.isEnterKey(key)) {
        if (app.isAtSearchActive() and app.atSearchHasResults()) {
            try app.acceptAtSelection();
            ctx.consumeAndRedraw();
            return;
        }
        try root.submit(ctx);
        return;
    }
    // Arrow keys are owned by the input until the cursor leaves the top of
    // it. While the input owns them (`!block_nav`) up/down move the cursor
    // between lines; going up past the first line hands control to block
    // navigation, and down stays trapped in the input. Once in block
    // navigation the arrows fall through to `handleTranscriptKey`, which
    // walks blocks and re-enters the input when you press down past the
    // last block. The @-mention popup keeps the arrows for itself.
    if (app.isNormalMode() and !app.isAtSearchActive() and app.queuedCount() > 0) {
        // ALT+←/→ navigate queued messages; CTRL+→ steers the selected
        // one. Gated on a non-empty queue so the keys fall through to
        // normal cursor/word movement otherwise.
        if (key.matches(vaxis.Key.left, .{ .alt = true })) {
            app.selectPrevQueued();
            ctx.consumeAndRedraw();
            return;
        } else if (key.matches(vaxis.Key.right, .{ .alt = true })) {
            app.selectNextQueued();
            ctx.consumeAndRedraw();
            return;
        } else if (key.matches(vaxis.Key.right, .{ .ctrl = true })) {
            app.steerSelectedQueued();
            ctx.consumeAndRedraw();
            return;
        }
    }
    if (app.isNormalMode() and !app.isAtSearchActive()) {
        if (key.matches(vaxis.Key.up, .{})) {
            if (!app.getBlockNav()) {
                if (try app.moveInputCursorVertical(.up)) {
                    ctx.consumeAndRedraw();
                    return;
                }
                // Top line: leave the input and start walking blocks.
                app.setBlockNav(true);
            }
        } else if (key.matches(vaxis.Key.down, .{})) {
            if (app.getBlockNav()) {
                if (!app.transcriptHasSelection()) {
                    if (try app.moveInputCursorVertical(.down)) {
                        app.setBlockNav(false);
                        ctx.consumeAndRedraw();
                        return;
                    }
                }
            } else {
                _ = try app.moveInputCursorVertical(.down);
                ctx.consumeAndRedraw();
                return;
            }
        }
    }
    if (try app.handleCommandKey(key)) {
        ctx.consumeAndRedraw();
    }
}

/// Handle Escape key: close modals, overlays, cancel modes, clear input,
/// or interrupt active turn. Returns after consuming the key.
fn handleEscapeSequence(
    app: *App,
    root: *RootWidget,
    ctx: *vxfw.EventContext,
) !void {
    if (app.getBackgroundModal()) {
        app.setBackgroundModal(false);
        ctx.consumeAndRedraw();
        return;
    }
    if (app.permissionPending()) {
        try app.resolvePermission(.reject);
        ctx.consumeAndRedraw();
        return;
    }
    if (app.isAtSearchActive()) {
        app.closeAtSearch();
        ctx.consumeAndRedraw();
        return;
    }
    if (try app.cancelMode()) {
        try root.syncFocus(ctx);
        ctx.consumeAndRedraw();
        return;
    }
    if (app.getBlockNav() or app.thread.transcript.selected != null) {
        app.setBlockNav(false);
        app.thread.transcript.selected = null;
        app.setThreadAutoScroll(true);
        try root.syncFocus(ctx);
        ctx.consumeAndRedraw();
        return;
    }
    if (app.inputRealLength() > 0) {
        app.clearInput();
        app.closeAtSearch();
        app.clearPendingQuitAt();
        try root.syncFocus(ctx);
        ctx.consumeAndRedraw();
        return;
    }
    if (app.turnStateIsActive()) {
        try app.handleInterrupt();
        ctx.consumeAndRedraw();
        return;
    }
    // No in-flight turn and no overlay to close — swallow the key so
    // the user doesn't accidentally exit the TUI.
    app.clearPendingQuitAt();
    ctx.consume_event = true;
}

/// Handle Ctrl+C / Ctrl+D quit sequence. Returns true if the key was handled
/// (either cleared input, armed quit, or confirmed quit).
fn handleQuitSequence(
    app: *App,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) !bool {
    const is_ctrl_c = key.matches('c', .{ .ctrl = true });
    const is_ctrl_d_empty = key.matches('d', .{ .ctrl = true }) and app.isNormalMode() and app.inputRealLength() == 0;
    if (!is_ctrl_c and !is_ctrl_d_empty) return false;

    if (is_ctrl_c and app.isNormalMode() and app.inputRealLength() > 0) {
        app.clearInput();
        app.closeAtSearch();
        app.setBlockNav(false);
        app.clearPendingQuitAt();
        ctx.consumeAndRedraw();
        return true;
    }
    const now = std.Io.Timestamp.now(app.getIo(), .awake);
    if (app.getPendingQuitAt()) |first_press| {
        const elapsed_ns = first_press.durationTo(now).nanoseconds;
        const threshold_ns: i128 = @as(i128, App.ctrl_c_double_press_ms) * std.time.ns_per_ms;
        if (elapsed_ns >= 0 and elapsed_ns <= threshold_ns) {
            ctx.quit = true;
            ctx.consume_event = true;
            return true;
        }
    }
    app.setPendingQuitAt(now);
    ctx.consumeAndRedraw();
    return true;
}

// ---------------------------------------------------------------------------
// Tests
//
// The quit state machine (`none` → `pending` → `ctx.quit`) and the
// confirmed-quit exit live in the private `handleQuitSequence` / `routeKey`.
// They are reached through the public `RootWidget.captureEvent` surface, the
// same path the 88 tui.zig tests use. `agent` and `app` are declared as
// sibling locals so the `&agent` pointer App copies into its heap `Thread`
// stays valid for the test's lifetime.

const agent_mod = @import("../agent.zig");

test "single Ctrl-C with empty input arms pending quit" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } });

    // First press arms the pending prompt without exiting.
    try std.testing.expect(app.nav.quit == .pending);
    try std.testing.expect(!ctx.quit);
}

test "Ctrl-C pressed twice within the window confirms quit" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    const ctrl_c: vxfw.Event = .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } };
    try captureEvent(&app, &root, &ctx, ctrl_c);
    try captureEvent(&app, &root, &ctx, ctrl_c);

    // Back-to-back presses land inside the double-press window.
    try std.testing.expect(ctx.quit);
}

test "Ctrl-D with empty input arms pending quit like Ctrl-C" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = 'd', .mods = .{ .ctrl = true } } });

    try std.testing.expect(app.nav.quit == .pending);
    try std.testing.expect(!ctx.quit);
}

test "a non-quit key cancels an armed pending quit" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } });
    try std.testing.expect(app.nav.quit == .pending);

    // Any ordinary key falls through handleQuitSequence (returns false) and
    // routeKey cancels the pending prompt.
    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = 'x', .mods = .{} } });
    try std.testing.expect(app.nav.quit == .none);
}

test "confirmed quit state exits the TUI on the next key" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    // Simulate the `/exit` command having set the confirmed state.
    app.nav.quit = .confirmed;

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = 'a', .mods = .{} } });

    try std.testing.expect(ctx.quit);
}

test "Escape in normal mode with non-empty input clears the input" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    try app.inputs.input.insertSliceAtCursor("draft");
    try std.testing.expect(app.inputs.input.buf.realLength() > 0);

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });

    try std.testing.expectEqual(@as(usize, 0), app.inputs.input.buf.realLength());
    try std.testing.expect(app.nav.quit == .none);
}
