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
const os = @import("../os.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../tui.zig");

const App = tui.App;
const RootWidget = tui.RootWidget;
const provider_model = @import("provider_model.zig");
const clipboard_helper = @import("clipboard_helper.zig");
const lifecycle = @import("lifecycle.zig");

const command_router = @import("command_router.zig");
const help_picker = @import("widgets/help_picker.zig");

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
        .key_release => |raw| {
            const key = normalizeControlKey(raw);
            if (key.matches('c', .{ .ctrl = true }) or key.matches('d', .{ .ctrl = true })) {
                app.markPendingQuitKeyReleased();
            }
        },
        .paste => |text| {
            try clipboard_helper.pasteToFocusedInput(app, text);
            ctx.consumeAndRedraw();
        },
        .paste_start => {
            // Bracketed paste window opens (ESC [200~). The pasted bytes arrive
            // as ordinary key presses; routeKey must treat their newlines as
            // content, not submit triggers, until paste_end.
            app.setPasting(true);
            ctx.consumeEvent();
        },
        .paste_end => {
            // Always clear: paste_end is the terminal state, and swallowing it
            // also recovers a stray window (e.g. the terminal dropped the end
            // marker mid-paste).
            app.setPasting(false);
            ctx.consumeEvent();
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
            app.pickers.help.scrollDown(2, help_picker.bodyRows(help_picker.help_overlay_height));
            ctx.consumeAndRedraw();
            return;
        }
    }
    if (mouse.button == .wheel_up) app.setThreadAutoScroll(false);
    if (mouse.button == .wheel_down) app.updateMouseAutoScroll();
    if (mouse.type == .press and mouse.button == .left) {
        if (app.getLanesChipRect()) |rect| {
            if (rect.contains(mouse.row, mouse.col)) {
                // Leave the fullscreen (`tab`) view. `.grid` opens the 2x2
                // tile; `.dual` (and the configured-`tab` fallback) enter dual
                // through `enterDual`, which re-roots `app.thread` to the
                // driver so the click always produces a coherent split.
                const configured = app.cached_config.tui.split_mode;
                if (configured == .grid) app.setSplitMode(.grid) else app.enterDual();
                ctx.consumeAndRedraw();
                return;
            }
        }
        // Click-to-focus a split pane by mapping (row, col) through the same
        // geometry the render path used this frame (`app.split_rects`, stored
        // by drawRoot). Only `.dual` worker columns can change focus, so a
        // click elsewhere (the driver pane, or any `.grid` column) is left
        // unconsumed rather than swallowing it.
        if (mouse.row >= 0 and mouse.col >= 0) {
            const r: u16 = @intCast(mouse.row);
            const c: u16 = @intCast(mouse.col);
            const cols = app.split_rects[0..app.split_rect_count];
            for (cols) |col| {
                if (r >= col.row and r < col.row + col.height and c >= col.col and c < col.col + col.width) {
                    if (app.split_mode == .dual and col.lane_index >= 1) {
                        app.focused_worker_index = col.lane_index;
                        ctx.consumeAndRedraw();
                        return;
                    }
                }
            }
        }
    }
}

fn normalizeControlKey(raw: vaxis.Key) vaxis.Key {
    var key = raw;
    if (key.codepoint >= 1 and key.codepoint <= 0x1a) {
        switch (key.codepoint) {
            0x08, 0x09, 0x0a, 0x0d => {},
            else => {
                key.mods = .{ .ctrl = true };
                key.codepoint = @as(u21, 'a') + (key.codepoint - 1);
            },
        }
    }
    return key;
}

fn routeKey(
    app: *App,
    root: *RootWidget,
    ctx: *vxfw.EventContext,
    raw: vaxis.Key,
) !void {
    // Input-pipeline breadcrumb: this line proves a key event reached the
    // app's router (reader thread -> queue -> focus dispatch all alive).
    // When keys "stop working", its presence/absence in zay.log splits the
    // search space in half — see AGENTS.md "vxfw Windows input-thread death".
    log.debug("key cp=0x{x:0>4} mods={any} mode={s} inlen={d} pallen={d}", .{ raw.codepoint, raw.mods, @tagName(app.mode), app.inputs.input.buf.realLength(), app.inputs.palette.buf.realLength() });

    // Some Windows Terminal input paths deliver control combos as BARE C0
    // codepoints with an empty — or noise-decorated (stray alt) — modifier
    // set. Observed in a user log (2026-09-15): Ctrl+C as `cp=0x03 mods={}`
    // and Ctrl+D as `cp=0x04 mods={alt=true}`, repeatedly — `matches('c',
    // .{ .ctrl = true })` can never hit those, so quit (and every other
    // ctrl binding) silently dies. Normalize C0 codes 0x01..0x1a to
    // ctrl+letter with a clean modifier set; backspace/tab/enter/newline
    // keep their own meaning (isEnterKey also matches a bare '\n').
    const key = normalizeControlKey(raw);
    // Windows Console can report the modifier key as a separate event before
    // the character it modifies (for example `left_control`, then `d`). It
    // is not an action by itself. Swallowing it here keeps the quit prompt's
    // double-press state intact so the modifier event cannot cancel the first
    // Ctrl+D/Ctrl+C while the following character is still in flight.
    if (key.isModifier()) {
        ctx.consumeEvent();
        return;
    }
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
    // Escape must close overlays even when the terminal decorates it with a
    // stray modifier. Windows Terminal's focus/decode paths have been
    // observed delivering a bare ESC press as `cp=0x1b mods={alt=true}`
    // (repro 2026-09-14); `matches` does exact-modifier comparison and would
    // miss it, leaving the user with an unclosable overlay. Match on the
    // codepoint, tolerating any modifiers.
    if (key.codepoint == vaxis.Key.escape) {
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
        // Ctrl+L cycles the focused worker lane in `.dual`; in `.grid`/`.tab`
        // it falls back to the mode cycle (the same cycle as Ctrl+W).
        if (app.split_mode == .dual and app.threads.len() > 1) {
            app.cycleFocusedWorker();
        } else {
            app.cycleSplitMode();
        }
        ctx.consumeAndRedraw();
        return;
    }
    // Ctrl+W cycles the split layout (dual → grid → tab → dual). Free in
    // normal mode — the diff viewer (which also binds Ctrl+W) short-circuits
    // `routeKey` before reaching here.
    if (key.matches('w', .{ .ctrl = true }) and app.isNormalMode()) {
        app.clearPendingQuitAt();
        app.cycleSplitMode();
        ctx.consumeAndRedraw();
        return;
    }
    // Transcript search: the universal "find" affordance. `/search` is the
    // guaranteed, terminal-agnostic path; Ctrl+F works when the terminal lets
    // it through (verified free across all modes — nothing else binds it).
    if (key.matches('f', .{ .ctrl = true }) and app.isNormalMode()) {
        app.clearPendingQuitAt();
        try app.openSearch();
        try root.syncFocus(ctx);
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
    // While a bracketed paste is in flight, its bytes are CONTENT, not
    // commands. Newlines in the paste become prompt newlines (the same
    // mechanism as Shift+Enter) instead of submitting, and a leading '/'
    // must not open the command menu. Non-newline bytes are left
    // unconsumed here on purpose: vxfw only forwards a key to the focused
    // input when the root capture did not consume it, which is how typed
    // characters reach the buffer today.
    if (app.isPasting() and app.isNormalMode()) {
        if (key.matches('j', .{ .ctrl = true }) or
            key.matches(vaxis.Key.enter, .{ .shift = true }) or
            command_router.isEnterKey(key))
        {
            try app.insertInputNewline();
            ctx.consumeAndRedraw();
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
    // In `.dual` split with no queued messages, Alt+Left/Alt+Right shift the
    // focused worker lane (the right pane). Alt+Right = next worker, Alt+Left
    // = previous worker, wrapping within `[1, lane_count - 1]` — the only
    // representable pane-focus bit under Resolved Decision 3. This never swaps
    // `app.thread`; input routing stays with the driver (lane 0, the left pane).
    if (app.isNormalMode() and !app.isAtSearchActive() and app.queuedCount() == 0 and app.split_mode == .dual and app.threads.len() > 1) {
        if (key.matches(vaxis.Key.right, .{ .alt = true })) {
            app.shiftFocusedWorker(1);
            ctx.consumeAndRedraw();
            return;
        } else if (key.matches(vaxis.Key.left, .{ .alt = true })) {
            app.shiftFocusedWorker(-1);
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
        const gap_ns: i128 = first_press.durationTo(now).nanoseconds;
        const auto_repeat_ns: i128 =
            @as(i128, App.ctrl_c_auto_repeat_gap_ms) * std.time.ns_per_ms;
        // A second record faster than the auto-repeat threshold is the same
        // chord held down (Windows auto-repeats a key as it is pressed) — a
        // genuine second press is slower than that. Suppress the rapid repeat
        // only when no release has been observed: a real key_release (delivered
        // by some terminals) or a genuine press with a real time gap past the
        // threshold both confirm exit without needing that release event.
        const is_rapid_repeat = gap_ns >= 0 and gap_ns < auto_repeat_ns;
        if (os.is_windows and !app.pendingQuitKeyReleased() and is_rapid_repeat) {
            ctx.consumeEvent();
            return true;
        }
        const elapsed_ns = gap_ns;
        const threshold_ns: i128 = @as(i128, App.ctrl_c_double_press_ms) * std.time.ns_per_ms;
        if (elapsed_ns >= 0 and elapsed_ns <= threshold_ns) {
            log.info("shutdown.request source=keyboard", .{});
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
// same path the tests in `src/tui/tests.zig` use. `agent` and `app` are
// declared as sibling locals so the `&agent` pointer App copies into its heap
// `Thread` stays valid for the test's lifetime.

const agent_mod = @import("../agent.zig");
const log = std.log.scoped(.tui);

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
    try captureEvent(&app, &root, &ctx, .{ .key_release = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } });
    try captureEvent(&app, &root, &ctx, ctrl_c);

    // Back-to-back presses land inside the double-press window.
    try std.testing.expect(ctx.quit);
}

test "bare C0 codepoints (mangled Ctrl+C/Ctrl+D) still drive quit" {
    // Regression (2026-09-15 user log): Windows Terminal delivered Ctrl+C
    // as `cp=0x03 mods={}` and Ctrl+D as `cp=0x04 mods={alt=true}` — with no
    // ctrl modifier, `matches('c', .{ .ctrl = true })` never matched and
    // quit was dead while the rest of the app kept working. routeKey now
    // normalizes bare C0 codes to ctrl+letter.
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

    // Bare cp=0x03, no modifiers at all — arms the pending prompt.
    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = 0x03, .mods = .{} } });
    try std.testing.expect(app.nav.quit == .pending);
    try std.testing.expect(!ctx.quit);
    app.clearPendingQuitAt();

    // cp=0x04 with a stray alt bit (the exact mangled form from the log) —
    // also arms.
    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = 0x04, .mods = .{ .alt = true } } });
    try std.testing.expect(app.nav.quit == .pending);
    try std.testing.expect(!ctx.quit);

    // Two bare cp=0x03 presses confirm quit, exactly like real Ctrl+C.
    var ctx2: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const mangled: vxfw.Event = .{ .key_press = .{ .codepoint = 0x03, .mods = .{} } };
    try captureEvent(&app, &root, &ctx2, mangled);
    try captureEvent(&app, &root, &ctx2, .{ .key_release = .{ .codepoint = 0x03, .mods = .{} } });
    try captureEvent(&app, &root, &ctx2, mangled);
    try std.testing.expect(ctx2.quit);
}

test "Windows Ctrl-D auto-repeat does not confirm quit before key release" {
    if (!os.is_windows) return error.SkipZigTest;

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

    const bare_ctrl_d: vxfw.Event = .{ .key_press = .{ .codepoint = 0x04, .mods = .{} } };
    try captureEvent(&app, &root, &ctx, bare_ctrl_d);
    try captureEvent(&app, &root, &ctx, bare_ctrl_d);

    try std.testing.expect(app.nav.quit == .pending);
    try std.testing.expect(!ctx.quit);

    try captureEvent(&app, &root, &ctx, .{ .key_release = .{ .codepoint = 0x04, .mods = .{} } });
    try captureEvent(&app, &root, &ctx, bare_ctrl_d);
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

test "Windows modifier-only Ctrl event preserves the pending quit" {
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

    const ctrl_d: vxfw.Event = .{ .key_press = .{ .codepoint = 'd', .mods = .{ .ctrl = true } } };
    const ctrl_modifier: vxfw.Event = .{ .key_press = .{ .codepoint = vaxis.Key.left_control, .mods = .{ .ctrl = true } } };

    // The first Ctrl+D arms the prompt. Windows may put the modifier event
    // between the two character events; it must not clear that pending state.
    try captureEvent(&app, &root, &ctx, ctrl_d);
    try std.testing.expect(app.nav.quit == .pending);
    try captureEvent(&app, &root, &ctx, ctrl_modifier);
    try std.testing.expect(app.nav.quit == .pending);
    try captureEvent(&app, &root, &ctx, .{ .key_release = .{ .codepoint = 'd', .mods = .{ .ctrl = true } } });
    try captureEvent(&app, &root, &ctx, ctrl_d);

    try std.testing.expect(ctx.quit);
}

test "Windows Ctrl-C confirms quit without a key_release event" {
    if (!os.is_windows) return error.SkipZigTest;

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
    try std.testing.expect(app.nav.quit == .pending);
    try std.testing.expect(!ctx.quit);

    // A deliberate second press with a real time gap (simulating a genuine
    // double-press rather than a held-key auto-repeat) must confirm exit even
    // though Windows Terminal delivers no key_release event for the chord.
    app.getIo().sleep(std.Io.Duration.fromMilliseconds(App.ctrl_c_auto_repeat_gap_ms + 50), .awake) catch {};
    try captureEvent(&app, &root, &ctx, ctrl_c);
    try std.testing.expect(ctx.quit);
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

test "confirmed quit state exits the TUI on the next tick" {
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

    // No keypress is delivered — the confirmed quit activates on the tick.
    // This is what makes `/exit` exit reliably on pty backends (e.g. Windows
    // Terminal) that don't send a trailing event after an exit command.
    try lifecycle.handleTick(&root, &ctx);

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

test "bracketed paste: multiline paste inserts newlines and does not submit" {
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

    // The paste window opens, and the terminal sends the first line's
    // characters as ordinary keys. Characters are left unconsumed by the
    // root so vxfw forwards them to the focused input — emulate that by
    // inserting them where the input would.
    try captureEvent(&app, &root, &ctx, .paste_start);
    try std.testing.expect(app.isPasting());
    try app.inputs.input.insertSliceAtCursor("line1");

    // CR (a CRLF paste's newline) must become a prompt newline, not a
    // submit: the input keeps its contents and gains a second line.
    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expect(app.isPasting());

    // LF pastes (bare-newline clipboards) arrive as a Ctrl+J key without
    // .text — that must also be a newline, not a submit.
    try app.inputs.input.insertSliceAtCursor("line2");
    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = 'j', .mods = .{ .ctrl = true } } });
    try std.testing.expect(app.isPasting());

    try app.inputs.input.insertSliceAtCursor("line3");
    try captureEvent(&app, &root, &ctx, .paste_end);
    try std.testing.expect(!app.isPasting());

    try std.testing.expectEqualStrings(
        "line1\nline2\nline3",
        app.inputs.input.buf.firstHalf(),
    );
    try std.testing.expectEqual(@as(usize, 0), app.inputs.input.buf.secondHalf().len);
}

test "bracketed paste: paste_start with a leading slash does not open the command menu" {
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

    try captureEvent(&app, &root, &ctx, .paste_start);
    try std.testing.expect(app.isPasting());

    // Outside a paste this exact key (input empty) switches to the command
    // menu; during a paste it must stay in normal mode.
    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = '/' } });

    try std.testing.expect(app.getMode() == .normal);
    try std.testing.expect(app.isPasting());

    try captureEvent(&app, &root, &ctx, .paste_end);
    try std.testing.expect(!app.isPasting());
}

test "bracketed paste: stray paste_end clears the flag" {
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

    try std.testing.expect(!app.isPasting());
    // Simulates a terminal dropping the end marker of an earlier paste: the
    // flag must never stay armed.
    try captureEvent(&app, &root, &ctx, .paste_end);
    try std.testing.expect(!app.isPasting());
}
