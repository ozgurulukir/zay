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
//! Note: this module reads and writes `App` state through dedicated `pub fn`
//! accessors on `App` (added alongside the extraction; see `tui.zig`). That
//! is a convention, not a language requirement — Zig puts no visibility on
//! struct fields and direct access is widely used (#298). R3 will move
//! those accessors into proper sub-structs.

const std = @import("std");
const os = @import("../os.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../tui.zig");

const App = tui.App;
const RootWidget = tui.RootWidget;
const app_state_mod = @import("app_state.zig");
const provider_model = @import("provider_model.zig");
const clipboard_helper = @import("clipboard_helper.zig");
const lifecycle = @import("lifecycle.zig");

const command_router = @import("command_router.zig");
const help_picker = @import("widgets/help_picker.zig");
const panel = @import("widgets/panel.zig");
const root_layout = @import("root_layout.zig");
const theme_lifecycle = @import("theme_lifecycle.zig");
const theme_picker = @import("widgets/theme_picker.zig");
const tui_style = @import("style.zig");
const toast = @import("toast.zig");

/// Map a mouse click inside `overlay_panel_rect` to the corresponding list row
/// and update the active overlay's selection before submission. Returns true
/// only when a valid list row was hit.
fn selectOverlayRowAt(app: *App, rect: app_state_mod.ChipRect, mouse_row: i16) bool {
    if (mouse_row < 0) return false;
    const m_row: u16 = @intCast(mouse_row);
    const mode = app.getMode();
    const full_panel = (mode == .provider_picker and app.pickers.provider.stage == .form) or
        mode == .settings or mode == .help or mode == .mcp or
        mode == .plugins or mode == .lanes or mode == .link_picker;
    // `rect` is the Border surface: row +0 is the top border, and height-1 is
    // the bottom border. Searchable overlays have `>` at +1 and `─` at +2,
    // so list rows start at +3 (chrome_rows = 4); `full_panel` overlays start
    // list rows directly at +1 (chrome_rows = 2).
    const header_offset: u16 = if (full_panel) 1 else 3;
    const chrome_rows: u16 = if (full_panel) 2 else 4;
    if (rect.height < chrome_rows + 1) return false;
    if (m_row < rect.row + header_offset or m_row >= rect.row + rect.height - 1) return false;
    const clicked_row: u32 = m_row - (rect.row + header_offset);
    const content_h: u16 = rect.height - chrome_rows;

    switch (mode) {
        .command => {
            const total = tui.commandMatchesCount(app);
            const vp = panel.ViewportWindow.computeWithScroll(app.nav.command_selection, total, content_h, app.nav.command_scroll.scroll_top);
            const target = vp.start_index + clicked_row;
            if (target >= total) return false;
            app.nav.command_selection = target;
            return true;
        },
        .theme_picker => {
            const filter = app.peekPaletteInput() catch return false;
            defer app.gpa.free(filter);
            const total = theme_picker.countMatching(app.theme_registry.slice(), filter);
            const vp = panel.ViewportWindow.computeWithScroll(app.pickers.theme.selection, total, content_h, app.pickers.theme.scroll.scroll_top);
            const target = vp.start_index + clicked_row;
            if (target >= total) return false;
            app.pickers.theme.selection = target;
            return true;
        },
        .search => {
            const total: u32 = @intCast(app.pickers.search.matches.items.len);
            const vp = panel.ViewportWindow.computeWithScroll(app.pickers.search.selection, total, content_h, app.pickers.search.scroll.scroll_top);
            const target = vp.start_index + clicked_row;
            if (target >= total) return false;
            app.pickers.search.selection = target;
            return true;
        },
        .link_picker => {
            const list_h: u16 = if (content_h > 1) content_h - 1 else content_h;
            if (clicked_row >= list_h) return false;
            const total: u32 = @intCast(app.pickers.links.items.items.len);
            const vp = panel.ViewportWindow.computeWithScroll(app.pickers.links.selection, total, list_h, app.pickers.links.scroll.scroll_top);
            const target = vp.start_index + clicked_row;
            if (target >= total) return false;
            app.pickers.links.selection = target;
            return true;
        },
        .provider_picker => {
            if (app.pickers.provider.stage != .list) return false;
            const total: u32 = @intCast(app.pickers.provider.entries.len);
            const vp = panel.ViewportWindow.computeWithScroll(app.pickers.provider.selection, total, content_h, app.pickers.provider.scroll.scroll_top);
            const target = vp.start_index + clicked_row;
            if (target >= total) return false;
            app.pickers.provider.selection = target;
            return true;
        },
        .model_picker => {
            // `model_picker` prepends a 1-row `Header` widget at widgets[0].
            const widget_idx = app.list_widgets.model_list.scroll.top + clicked_row;
            if (widget_idx == 0) return false;
            const target = widget_idx - 1;
            if (app.list_widgets.model_list.item_count) |c| if (widget_idx >= c) return false;
            app.pickers.models.model_selection = target;
            return true;
        },
        .session_picker => {
            if (app.nav.session_action != .browsing) return false;
            const target = app.list_widgets.resume_list.scroll.top + clicked_row;
            if (app.list_widgets.resume_list.item_count) |c| if (target >= c) return false;
            app.nav.resume_selection = target;
            return true;
        },
        .tree_picker => {
            // `tree_selector` draws a 2-row "Filter: ..." header above the ListView.
            if (clicked_row < 2) return false;
            const target = app.list_widgets.tree_list.scroll.top + (clicked_row - 2);
            if (app.list_widgets.tree_list.item_count) |c| if (target >= c) return false;
            app.pickers.tree.selection = target;
            return true;
        },
        .lanes => {
            const target = app.list_widgets.lanes_list.scroll.top + clicked_row;
            if (app.list_widgets.lanes_list.item_count) |c| if (target >= c) return false;
            app.nav.lanes_selection = target;
            return true;
        },
        .help, .settings, .mcp, .plugins, .save_message, .normal, .diff_viewer => return false,
    }
}

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
            if (isPendingQuitKeyRelease(key)) app.quit_gate.markKeyReleased();
        },
        .paste => |text| {
            app.quit_gate.cancelPending();
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
        .color_scheme => |scheme| {
            theme_lifecycle.handleColorSchemeChange(app, scheme);
            ctx.consumeAndRedraw();
        },
        .color_report => |report| {
            if (report.kind == .bg) {
                const lum = tui_style.relativeLuminance(report.value);
                const scheme: vaxis.Color.Scheme = if (lum > 0.5) .light else .dark;
                theme_lifecycle.handleColorSchemeChange(app, scheme);
                ctx.consumeAndRedraw();
            }
        },
        .focus_in => {
            app.is_focused = true;
            ctx.consumeEvent();
        },
        .focus_out => {
            app.is_focused = false;
            app.nav.mouse_drag_active = false;
            ctx.consumeEvent();
        },
        else => {},
    }
}

fn routeInit(app: *App, root: *RootWidget, ctx: *vxfw.EventContext) !void {
    try ctx.requestFocus(app.inputWidget());
    try ctx.addCmd(.{ .query_color = .bg });
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
    if (lifecycle.decideShouldTick(root)) try root.ensureTick(ctx);
    const layer = root_layout.activeModalLayer(app);
    if (mouse.button == .wheel_up or mouse.button == .wheel_down) {
        if (app.getMode() == .help) {
            if (mouse.button == .wheel_up) {
                app.pickers.help.scrollUp(2);
                ctx.consumeAndRedraw();
                return;
            }
            if (mouse.button == .wheel_down) {
                app.pickers.help.scrollDown(2, help_picker.bodyRows(app.drawnOverlayHeight()));
                ctx.consumeAndRedraw();
                return;
            }
        }
        if (layer == .permission) {
            if (mouse.button == .wheel_up) {
                if (app.thread.permission_scroll > 0) app.thread.permission_scroll -= 1;
            } else {
                app.thread.permission_scroll += 1;
            }
            ctx.consumeAndRedraw();
            return;
        }
        if (app.isDiffViewerMode()) {
            if (app.diff.sub == .browse) {
                app.diff.moveCursor(if (mouse.button == .wheel_up) -3 else 3);
                ctx.consumeAndRedraw();
            } else {
                ctx.consumeEvent();
            }
            return;
        }
        if (layer == .overlay) {
            if (mouse.button == .wheel_up) {
                _ = try command_router.handleCommandKey(app, .{ .codepoint = vaxis.Key.up });
            } else {
                _ = try command_router.handleCommandKey(app, .{ .codepoint = vaxis.Key.down });
            }
            ctx.consumeAndRedraw();
            return;
        }
        if (layer == .background) {
            const key: vaxis.Key = .{ .codepoint = if (mouse.button == .wheel_up) vaxis.Key.up else vaxis.Key.down };
            if (app.handleBackgroundModalKey(key)) ctx.consumeAndRedraw() else ctx.consumeEvent();
            return;
        }
        if (layer == .at_search) {
            const key: vaxis.Key = .{ .codepoint = if (mouse.button == .wheel_up) vaxis.Key.up else vaxis.Key.down };
            if (try command_router.MentionPopup.handle(app, key)) ctx.consumeAndRedraw() else ctx.consumeEvent();
            return;
        }
        if (mouse.button == .wheel_up) app.setThreadAutoScroll(false);
        if (mouse.button == .wheel_down) app.updateMouseAutoScroll();
    }

    if (mouse.type == .press and mouse.button == .left) {
        // 1. Permission modal owns all clicks while active.
        if (layer == .permission) {
            if (app.frame_geometry.permission_buttons) |buttons| {
                for (buttons) |btn| {
                    if (btn.contains(mouse.row, mouse.col)) {
                        switch (btn.choice) {
                            .approve => try app.resolvePermission(.approve),
                            .approve_session => try app.resolvePermission(.approve_session),
                            .reject => try app.resolvePermission(.reject),
                            .reject_with_reason => try app.resolvePermission(.{ .reject_with_reason = "Rejected by user: command refused" }),
                        }
                        ctx.consumeAndRedraw();
                        return;
                    }
                }
            }
            ctx.consumeEvent();
            return;
        }

        // 2. Modal overlay dismiss (click outside) or row activation; clicks
        // inside non-row chrome are consumed so they never leak to panes behind.
        if (layer == .overlay) {
            if (app.frame_geometry.overlay_panel_rect) |rect| {
                if (!rect.contains(mouse.row, mouse.col)) {
                    // Cancel repeatedly until returning to .normal (some pickers
                    // step back to .command on a single cancel) and sync focus (#292).
                    var guard: u8 = 0;
                    while (app.getMode() != .normal and guard < 4) : (guard += 1) {
                        if (!try lifecycle.transitionMode(root, ctx, .cancel)) break;
                    }
                    if (app.getMode() != .normal) {
                        app.setMode(.normal);
                        try root.syncFocus(ctx);
                    }
                    ctx.consumeAndRedraw();
                    return;
                } else if (selectOverlayRowAt(app, rect, mouse.row)) {
                    try root.submit(ctx);
                    return;
                }
            }
            ctx.consumeEvent();
            return;
        }

        // 3. Background jobs modal and @-search popup block clicks from leaking
        // into the transcript or split panes beneath them.
        if (layer == .background or layer == .at_search) {
            ctx.consumeEvent();
            return;
        }

        if (app.isDiffViewerMode()) return;

        // 4. "↓ new output" pill click
        if (app.frame_geometry.new_output_rect) |rect| {
            if (rect.contains(mouse.row, mouse.col)) {
                app.jumpTranscriptToBottom();
                ctx.consumeAndRedraw();
                return;
            }
        }

        // 5. Lanes chip click
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
            const cols = app.frame_geometry.split_rects[0..app.frame_geometry.split_rect_count];
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
        // 6. Transcript mouse selection (single-click anchor, double-click word, triple-click line).
        if (app.getMode() == .normal and mouse.row >= 0 and mouse.col >= 0) {
            const mouse_sel = @import("mouse_selection.zig");
            const r: u16 = @intCast(mouse.row);
            const c: u16 = @intCast(mouse.col);
            const now_ms = std.Io.Clock.now(.awake, app.getIo()).toMilliseconds();
            const same_spot = @abs(@as(i32, r) - @as(i32, app.nav.mouse_last_click_row)) <= 1 and
                @abs(@as(i32, c) - @as(i32, app.nav.mouse_last_click_col)) <= 1;
            if (same_spot and (now_ms - app.nav.mouse_last_click_ms) <= 400) {
                app.nav.mouse_click_count = if (app.nav.mouse_click_count >= 3) 1 else app.nav.mouse_click_count + 1;
            } else {
                app.nav.mouse_click_count = 1;
            }
            app.nav.mouse_last_click_ms = now_ms;
            app.nav.mouse_last_click_row = r;
            app.nav.mouse_last_click_col = c;

            if (mouse_sel.hitTestTranscript(app, r, c)) |hit| {
                const body = app.thread.transcript.messages.items[hit.message_index].mirror().body;
                app.thread.transcript.selected = hit.message_index;
                // Sync the ListView cursor so `TranscriptWidget.syncCursor` does not
                // trigger `ensureScroll()` and jump the viewport mid-click/drag.
                app.thread.transcript_list.cursor = hit.message_index;
                if (app.nav.mouse_click_count == 2) {
                    const wr = mouse_sel.wordRange(body, hit.byte_offset);
                    app.thread.transcript.body_selection = .{ .message_index = hit.message_index, .anchor = wr[0], .focus = wr[1] };
                    app.nav.mouse_drag_active = false;
                } else if (app.nav.mouse_click_count == 3) {
                    const lr = mouse_sel.lineRange(body, hit.byte_offset);
                    app.thread.transcript.body_selection = .{ .message_index = hit.message_index, .anchor = lr[0], .focus = lr[1] };
                    app.nav.mouse_drag_active = false;
                } else {
                    app.thread.transcript.body_selection = .{ .message_index = hit.message_index, .anchor = hit.byte_offset, .focus = hit.byte_offset };
                    app.nav.mouse_drag_active = true;
                }
                ctx.consumeAndRedraw();
                return;
            } else {
                app.thread.transcript.body_selection = null;
                app.nav.mouse_drag_active = false;
            }
        }
    }

    if ((mouse.type == .drag or mouse.type == .motion) and app.nav.mouse_drag_active) {
        if (app.getMode() != .normal or layer != .none) {
            app.nav.mouse_drag_active = false;
            return;
        }
        if (app.thread.transcript.body_selection) |*sel| {
            const mouse_sel = @import("mouse_selection.zig");
            if (mouse.row >= 0 and mouse.col >= 0) {
                if (mouse_sel.hitTestTranscript(app, @intCast(mouse.row), @intCast(mouse.col))) |hit| {
                    if (hit.message_index == sel.message_index) {
                        sel.focus = hit.byte_offset;
                    } else if (hit.message_index > sel.message_index) {
                        sel.focus = app.thread.transcript.messages.items[sel.message_index].mirror().body.len;
                    } else {
                        sel.focus = 0;
                    }
                    ctx.consumeAndRedraw();
                    return;
                }
            }
            // Clamp selection to the message start/end when dragging above or below
            // the transcript viewport so the selection does not freeze at the edge.
            if (mouse_sel.transcriptViewport(app)) |vp| {
                const top_screen_row: i32 = @as(i32, vp.view_row) + @as(i32, vp.list_top_pad);
                const bottom_screen_row: i32 = @as(i32, vp.view_row) + @as(i32, vp.list_bottom);
                if (mouse.row < top_screen_row) {
                    sel.focus = 0;
                    ctx.consumeAndRedraw();
                    return;
                }
                if (mouse.row >= bottom_screen_row) {
                    sel.focus = app.thread.transcript.messages.items[sel.message_index].mirror().body.len;
                    ctx.consumeAndRedraw();
                    return;
                }
            }
        }
    }

    if (mouse.type == .release and app.nav.mouse_drag_active) {
        app.nav.mouse_drag_active = false;
        if (app.thread.transcript.body_selection) |sel| {
            if (sel.anchor == sel.focus) {
                app.thread.transcript.body_selection = null;
            }
        }
        ctx.consumeAndRedraw();
        return;
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

/// True when a key release proves the physical Ctrl+C/Ctrl+D chord ended.
/// The chord key may arrive without Ctrl when the user lifts Ctrl first, and
/// some terminals report either Control modifier as a separate release.
fn isPendingQuitKeyRelease(key: vaxis.Key) bool {
    return key.codepoint == 'c' or
        key.codepoint == 'd' or
        key.codepoint == vaxis.Key.left_control or
        key.codepoint == vaxis.Key.right_control;
}

/// True when the pressed key is a quit chord for the current state. Ctrl+D
/// only quits when it would not be typed as EOF into a non-empty prompt.
fn isQuitPress(app: *const App, key: vaxis.Key) bool {
    const is_ctrl_c = key.matches('c', .{ .ctrl = true });
    const is_ctrl_d = key.matches('d', .{ .ctrl = true });
    const prompt_has_text = app.isNormalMode() and app.inputRealLength() > 0;
    return is_ctrl_c or (is_ctrl_d and !prompt_has_text);
}

/// True when the key is one of the global clipboard-paste chords. Pure —
/// no side effects, no clipboard access — so the chord set is unit-testable
/// without an OS clipboard (mirrors the `fileNameMatches` extract-pure-helper
/// pattern from AGENTS.md).
fn isClipboardPasteChord(key: vaxis.Key) bool {
    return key.matches('v', .{ .ctrl = true }) or
        key.matches(vaxis.Key.insert, .{ .shift = true }) or
        // Alt+V: Windows fallback — Windows Terminal intercepts Ctrl+V and
        // Shift+Insert as its own paste bindings and re-injects the text as
        // key records (each newline arrives as Enter → submit), and the
        // console INPUT_RECORD path never sees bracketed-paste markers, so
        // the paste-window guard can't save multiline pastes. Alt+V reaches
        // zay untouched and routes through the OS clipboard read, whose
        // newline-preserving insert works multiline on Windows.
        key.matches('v', .{ .alt = true });
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

    routeKeySyncPasteStash(app);

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
    if (lifecycle.decideShouldTick(root)) try root.ensureTick(ctx);
    // The diff viewer is a self-contained full-screen mode: it owns every
    // key (including Esc) so it can manage its own sub-states.
    if (app.isDiffViewerMode()) {
        try root.handleDiffViewerEvent(ctx, key);
        return;
    }
    // Any key that is not a quit chord is activity: it dismisses an armed
    // quit prompt. This one rule replaces the per-handler clears that used to
    // drift apart as new key routes were added.
    if (!isQuitPress(app, key)) app.quit_gate.cancelPending();
    // Global Ctrl+V / Shift+Insert / Alt+V clipboard paste into active input.
    if (isClipboardPasteChord(key)) {
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
        app.toggleBackgroundModal();
        ctx.consumeAndRedraw();
        return;
    }
    if (try routeKeyPromptEditing(app, ctx, key)) return;
    if (try routeKeyViewChords(app, root, ctx, key)) return;
    if (app.quit_gate.isConfirmed()) {
        ctx.quit = true;
        ctx.consume_event = true;
        return;
    }
    if (try handleQuitSequence(app, root, ctx, key)) return;
    const modal_layer = root_layout.activeModalLayer(app);
    // While the jobs modal is top-most it owns navigation/cancel keys.
    if (modal_layer == .background) {
        if (app.handleBackgroundModalKey(key)) ctx.consumeAndRedraw() else ctx.consumeEvent();
        return;
    }
    if (modal_layer == .permission) {
        if (try app.handlePermissionKey(key)) {
            ctx.consumeAndRedraw();
        } else {
            ctx.consumeEvent();
        }
        return;
    }
    if (try routeKeyPastingContent(app, ctx, key)) return;
    if (try routeKeyCommandMenuEntry(app, root, ctx, key)) return;
    if (try routeKeySubmit(app, root, ctx, key)) return;
    if (try routeKeyQueuedNav(app, ctx, key)) return;
    if (try routeKeyWorkerShift(app, ctx, key)) return;
    if (try routeKeyPromptCursorNav(app, ctx, key)) return;
    if (try handlePerModeKey(app, root, ctx, key)) {
        ctx.consumeAndRedraw();
    }
}

/// Mirror prompt edits into the paste stash before any key can remove or
/// edit a pasted placeholder span, so stale text never desyncs the stash.
fn routeKeySyncPasteStash(app: *App) void {
    if (app.inputs.paste_stash.entries.items.len > 0) {
        if (app.inputs.input.buf.dupe() catch null) |cur_text| {
            defer app.gpa.free(cur_text);
            app.inputs.paste_stash.syncWithText(app.gpa, cur_text);
        }
    }
}

/// Normal-mode prompt editing chords, in routeKey's order: pending Ctrl+X →
/// external editor, Ctrl+X arm, backspace over a pasted placeholder, and the
/// Ctrl+Z / Ctrl+Y undo/redo pair (#486, #555). Returns true when the key was
/// fully routed (consumed or deliberately swallowed); false falls through.
fn routeKeyPromptEditing(app: *App, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    // Prompt undo/redo (issue #486): only when the prompt is focused, i.e.
    // normal mode — overlays have their own text fields with no undo history.
    if (app.getMode() == .normal and app.nav.pending_ctrl_x) {
        app.nav.pending_ctrl_x = false;
        if (key.matches('e', .{ .ctrl = true }) or key.matches('e', .{})) {
            try @import("external_editor.zig").editPromptInExternalEditor(app);
            ctx.consumeAndRedraw();
            return true;
        }
    }
    if (app.getMode() == .normal and !app.nav.block_nav and key.matches('x', .{ .ctrl = true })) {
        app.nav.pending_ctrl_x = true;
        ctx.consumeEvent();
        return true;
    }
    if (try routeKeyPastePlaceholderBackspace(app, ctx, key)) return true;
    if (app.getMode() == .normal and key.matches('z', .{ .ctrl = true })) {
        if (app.input_undo.undo(app)) ctx.consumeAndRedraw();
        return true;
    }
    if (app.getMode() == .normal and key.matches('y', .{ .ctrl = true })) {
        if (app.input_undo.redoStep(app)) ctx.consumeAndRedraw();
        return true;
    }
    return false;
}

/// Backspace over a pasted-placeholder span in normal mode: splices the
/// placeholder out of the buffer and re-syncs the stash with the shortened
/// text.
fn routeKeyPastePlaceholderBackspace(app: *App, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    if (app.getMode() == .normal and !app.nav.block_nav and app.inputs.paste_stash.entries.items.len > 0 and key.matches(vaxis.Key.backspace, .{})) {
        const text = app.inputs.input.buf.dupe() catch null;
        if (text) |owned| {
            defer app.gpa.free(owned);
            const cursor = app.inputs.input.buf.cursor;
            if (app.inputs.paste_stash.placeholderSpanAtBackspace(owned, cursor)) |span| {
                const updated = std.fmt.allocPrint(app.gpa, "{s}{s}", .{ owned[0..span.start], owned[span.end..] }) catch null;
                if (updated) |u| {
                    defer app.gpa.free(u);
                    app.clearInput();
                    try app.inputs.input.insertSliceAtCursor(u);
                    app.inputs.paste_stash.syncWithText(app.gpa, u);
                    const cur = app.inputs.input.buf.cursor;
                    if (span.start < cur) app.inputs.input.buf.moveGapLeft(cur - span.start);
                    ctx.consumeAndRedraw();
                    return true;
                }
            }
        }
    }
    return false;
}

/// Cross-mode layout and navigation chords (#555): Ctrl+L cycles the focused
/// worker lane (falling back to the split-mode cycle outside `.dual`), Ctrl+W
/// cycles the split layout, Ctrl+F opens transcript search.
fn routeKeyViewChords(app: *App, root: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    if (key.matches('l', .{ .ctrl = true }) or key.matches('l', .{ .super = true })) {
        // Ctrl+L cycles the focused worker lane in `.dual`; in `.grid`/`.tab`
        // it falls back to the mode cycle (the same cycle as Ctrl+W).
        if (app.split_mode == .dual and app.threads.len() > 1) {
            app.cycleFocusedWorker();
        } else {
            app.cycleSplitMode();
        }
        ctx.consumeAndRedraw();
        return true;
    }
    // Ctrl+W cycles the split layout (dual → grid → tab → dual). Free in
    // normal mode — the diff viewer (which also binds Ctrl+W) short-circuits
    // `routeKey` before reaching here.
    if (key.matches('w', .{ .ctrl = true }) and app.isNormalMode()) {
        app.cycleSplitMode();
        ctx.consumeAndRedraw();
        return true;
    }
    // Transcript search: the universal "find" affordance. `/search` is the
    // guaranteed, terminal-agnostic path; Ctrl+F works when the terminal lets
    // it through (verified free across all modes — nothing else binds it).
    if (key.matches('f', .{ .ctrl = true }) and app.isNormalMode()) {
        _ = try lifecycle.transitionMode(root, ctx, .open_search);
        ctx.consumeAndRedraw();
        return true;
    }
    return false;
}

/// While a bracketed paste is in flight, its bytes are CONTENT, not
/// commands (#555). Newlines in the paste become prompt newlines (the same
/// mechanism as Shift+Enter) instead of submitting, and a leading '/'
/// must not open the command menu. Everything inside the paste window is
/// reported handled; non-newline bytes stay unconsumed on purpose: vxfw
/// only forwards a key to the focused input when the root capture did not
/// consume it, which is how typed characters reach the buffer today.
fn routeKeyPastingContent(app: *App, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    if (app.isPasting() and app.isNormalMode()) {
        if (key.matches('j', .{ .ctrl = true }) or
            key.matches(vaxis.Key.enter, .{ .shift = true }) or
            command_router.isEnterKey(key))
        {
            try app.insertInputNewline();
            ctx.consumeAndRedraw();
        }
        return true;
    }
    return false;
}

/// Slash and Ctrl+K open the command menu (#555). Keep the slash entry point
/// for existing command workflows. Ctrl+K is an additional binding; removing
/// slash here would send `/connect` and other commands to the model because
/// normal submit has no command parser.
fn routeKeyCommandMenuEntry(app: *App, root: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    if (tui.shouldOpenCommandMenuForSlash(app, key)) {
        _ = try lifecycle.transitionMode(root, ctx, .open_command_menu);
        ctx.consumeAndRedraw();
        return true;
    }
    if (app.isNormalMode() and key.matches('k', .{ .ctrl = true })) {
        _ = try lifecycle.transitionMode(root, ctx, .open_command_menu);
        ctx.consumeAndRedraw();
        return true;
    }
    return false;
}

/// Enter-family routing (#555): Shift+Enter inserts a prompt newline; Enter
/// accepts an @-mention search selection when one is active, else hands the
/// key to `root.submit` — every mode's Enter disposition is owned by
/// submitMode (the single wiring site — overlay forms included); the generic
/// chat submit only fires when no mode arm claimed the key.
fn routeKeySubmit(app: *App, root: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    if (app.isNormalMode() and key.matches(vaxis.Key.enter, .{ .shift = true })) {
        try app.insertInputNewline();
        ctx.consumeAndRedraw();
        return true;
    }
    if (command_router.isEnterKey(key)) {
        if (app.isAtSearchActive() and app.atSearchHasResults()) {
            try app.acceptAtSelection();
            ctx.consumeAndRedraw();
            return true;
        }
        try root.submit(ctx);
        return true;
    }
    return false;
}

/// ALT+←/→ navigate queued messages; CTRL+→ steers the selected one (#555).
/// Gated on a non-empty queue so the keys fall through to normal cursor/word
/// movement otherwise.
fn routeKeyQueuedNav(app: *App, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    if (app.isNormalMode() and !app.isAtSearchActive() and app.queuedCount() > 0) {
        if (key.matches(vaxis.Key.left, .{ .alt = true })) {
            app.selectPrevQueued();
            ctx.consumeAndRedraw();
            return true;
        } else if (key.matches(vaxis.Key.right, .{ .alt = true })) {
            app.selectNextQueued();
            ctx.consumeAndRedraw();
            return true;
        } else if (key.matches(vaxis.Key.right, .{ .ctrl = true })) {
            app.steerSelectedQueued();
            ctx.consumeAndRedraw();
            return true;
        }
    }
    return false;
}

/// In `.dual` split with no queued messages, Alt+Left/Alt+Right shift the
/// focused worker lane (the right pane) (#555). Alt+Right = next worker,
/// Alt+Left = previous worker, wrapping within `[1, lane_count - 1]` — the
/// only representable pane-focus bit under Resolved Decision 3. This never
/// swaps `app.thread`; input routing stays with the driver (lane 0, the left
/// pane).
fn routeKeyWorkerShift(app: *App, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    if (app.isNormalMode() and !app.isAtSearchActive() and app.queuedCount() == 0 and app.split_mode == .dual and app.threads.len() > 1) {
        if (key.matches(vaxis.Key.right, .{ .alt = true })) {
            app.shiftFocusedWorker(1);
            ctx.consumeAndRedraw();
            return true;
        } else if (key.matches(vaxis.Key.left, .{ .alt = true })) {
            app.shiftFocusedWorker(-1);
            ctx.consumeAndRedraw();
            return true;
        }
    }
    return false;
}

/// Arrow keys are owned by the input until the cursor leaves the top of it
/// (#555). While the input owns them (`!block_nav`) up/down move the cursor
/// between lines; going up past the first line hands control to block
/// navigation, and down stays trapped in the input. Once in block
/// navigation the arrows fall through to `handleTranscriptKey`, which
/// walks blocks and re-enters the input when you press down past the
/// last block. The @-mention popup keeps the arrows for itself. Returns
/// false on those fall-throughs so `handlePerModeKey` still sees the key.
fn routeKeyPromptCursorNav(app: *App, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    if (app.isNormalMode() and !app.isAtSearchActive()) {
        if (key.matches(vaxis.Key.up, .{})) {
            if (!app.getBlockNav()) {
                if (try app.moveInputCursorVertical(.up)) {
                    ctx.consumeAndRedraw();
                    return true;
                }
                // Top line: leave the input and start walking blocks.
                app.setBlockNav(true);
            }
        } else if (key.matches(vaxis.Key.down, .{})) {
            if (app.getBlockNav()) {
                if (!app.transcriptHasSelection()) {
                    if (try app.moveInputCursorVertical(.down)) {
                        app.clearBlockNav();
                        ctx.consumeAndRedraw();
                        return true;
                    }
                }
            } else {
                _ = try app.moveInputCursorVertical(.down);
                ctx.consumeAndRedraw();
                return true;
            }
        }
    }
    return false;
}

/// Wrapper duty for the per-mode key dispatch (#292): a per-mode handler can
/// only flip `App.mode` through `App.setMode` — it has no `EventContext`, so
/// when the dispatch CHANGED the mode (help's `q` close), the wrapper
/// re-routes focus here. Skipping this leaves the focus path on the old
/// mode's widget and typed input dead until another key re-syncs (#313
/// class; the ConPTY smoke's help scenario pins it end to end).
fn handlePerModeKey(app: *App, root: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    const mode_before = app.getMode();
    if (!try app.handleCommandKey(key)) return false;
    if (app.getMode() != mode_before) try root.syncFocus(ctx);
    return true;
}

/// Handle Escape key: close modals, overlays, cancel modes, clear input,
/// or interrupt active turn. Returns after consuming the key.
fn handleEscapeSequence(
    app: *App,
    root: *RootWidget,
    ctx: *vxfw.EventContext,
) !void {
    switch (root_layout.activeModalLayer(app)) {
        .background => {
            app.closeBackgroundModal();
            ctx.consumeAndRedraw();
            return;
        },
        .permission => {
            try app.resolvePermission(.reject);
            ctx.consumeAndRedraw();
            return;
        },
        .at_search => {
            app.closeAtSearch();
            ctx.consumeAndRedraw();
            return;
        },
        .overlay, .none => {},
    }
    if (try lifecycle.transitionMode(root, ctx, .cancel)) {
        ctx.consumeAndRedraw();
        return;
    }
    if (app.getBlockNav() or app.thread.transcript.selected != null) {
        app.clearBlockNav();
        app.thread.transcript.selected = null;
        app.setThreadAutoScroll(true);
        try root.syncFocus(ctx);
        ctx.consumeAndRedraw();
        return;
    }
    if (toast.global.hasToasts()) {
        toast.global.dismiss();
        ctx.consumeAndRedraw();
        return;
    }
    if (app.inputRealLength() > 0) {
        app.clearInput();
        app.inputs.paste_stash.clear(app.gpa);
        app.closeAtSearch();
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
    ctx.consume_event = true;
}

/// Handle Ctrl+C / Ctrl+D quit sequence. Returns true if the key was handled
/// (either cleared input, armed quit, or confirmed quit).
fn handleQuitSequence(
    app: *App,
    root: *RootWidget,
    ctx: *vxfw.EventContext,
    key: vaxis.Key,
) !bool {
    // Ctrl+D is the EOF-style quit chord. The main prompt is only focused in
    // normal mode, so an off-mode draft must not block the exit the pending
    // hint advertises in every mode.
    if (!isQuitPress(app, key)) return false;

    const is_ctrl_c = key.matches('c', .{ .ctrl = true });
    if (is_ctrl_c and app.isNormalMode() and app.inputRealLength() > 0) {
        app.clearInput();
        app.inputs.paste_stash.clear(app.gpa);
        app.closeAtSearch();
        app.clearBlockNav();
        app.quit_gate.cancelPending();
        ctx.consumeAndRedraw();
        return true;
    }
    const now = std.Io.Timestamp.now(app.getIo(), .awake);
    switch (app.quit_gate.onPress(now)) {
        .swallowed => {
            ctx.consumeEvent();
            return true;
        },
        .confirmed => {
            log.info("shutdown.request source=keyboard", .{});
            ctx.quit = true;
            ctx.consume_event = true;
            return true;
        },
        .armed => {},
    }
    // Keep the tick alive even on an otherwise idle screen so handleTick
    // runs to expire the prompt once the double-press window elapses.
    if (lifecycle.decideShouldTick(root)) try root.ensureTick(ctx);
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

test "plugin overlay routes Enter to its add form handler" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.mode = .plugins;
    app.pickers.plugins.view = .store;
    app.pickers.plugins.adding = true;
    try app.input_buffers.plugin_store_url.appendSlice(gpa, "https://example.com/store.json");

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });

    try std.testing.expect(!app.pickers.plugins.adding);
    try std.testing.expectEqualStrings("Could not add store: no active runtime.", app.plugin_store.notice.?);
}

test "plugin overlay reports an install request before the catalog is ready" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.mode = .plugins;
    app.pickers.plugins.view = .store;

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });

    try std.testing.expectEqualStrings("Plugin catalog is not ready yet. Press r to refresh.", app.plugin_store.notice.?);
}

test "captureEvent delivers settings edit Enter to the editor, not the row re-entry" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    // The routing-level proof of the settings Enter fix: routeKey consumes
    // every Enter before per-mode handlers, so the disposition is decided by
    // submitSettings' edit-aware guard, not by handleTextEditKey (whose
    // direct-call tests cannot see the routing).
    tui.openSettings(&app);
    try std.testing.expectEqual(App.Mode.settings, app.getMode());
    app.pickers.settings.tab = .prompt;
    app.pickers.settings.edit_target = .system_prompt;
    try app.input_buffers.settings_text.appendSlice(gpa, "draft");

    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = '\r' } });
    try std.testing.expectEqualStrings("draft\n", app.input_buffers.settings_text.items);
    try std.testing.expect(app.pickers.settings.edit_target == .system_prompt);

    // Single-line URL field: Enter commits without saving, exactly like the
    // editor's own documented semantics.
    app.pickers.settings.tab = .advanced;
    app.pickers.settings.edit_target = .bash_classifier_url;
    app.input_buffers.settings_text.clearRetainingCapacity();
    try app.input_buffers.settings_text.appendSlice(gpa, "https://example.com/a");

    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = '\r' } });
    try std.testing.expectEqualStrings("https://example.com/a", app.pickers.settings.pending_bash_classifier_url.?);
    try std.testing.expect(app.pickers.settings.edit_target == .none);
    gpa.free(app.pickers.settings.pending_bash_classifier_url.?);
}

test "Enter disposition sweep: every overlay consumes Enter per its submitMode arm" {
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

    // Every mode's Enter goes through submitMode (routeKey → root.submit);
    // the sweep pins each documented disposition plus the global invariant
    // that nothing leaks into the chat submit. Per-mode setup via a plain
    // switch — the repo avoids fn-pointer tables.
    //
    // The fixture lane is idle, so a leaked Enter (a deleted or hollow
    // submitMode arm) cannot start a turn: beginSubmit refuses on the null
    // worker_context — but that refusal appends an idle-lane notice to the
    // transcript. The overlay rows below therefore also pin the transcript
    // notice count: an arm that stops claiming Enter flips this test red.
    for (std.enums.values(App.Mode)) |m| {
        app.mode = m;
        switch (m) {
            .search => {}, // empty matches: acceptSearchSelection no-ops
            .command => {}, // empty filter resolves /connect; the idle-lane refusal is the disposition
            .settings => {}, // no edit, browsing: row toggles on the current tab
            .provider_picker => {}, // idle-lane refusal: consumed
            .model_picker => {}, // idle-lane refusal: consumed
            // tree_picker: submitTreePicker closes the empty picker to .normal.
            // theme_picker: submitThemePicker applies the first registry theme and closes.
            .tree_picker, .theme_picker => {},
            .session_picker => {}, // browsing, empty list: consumed
            .save_message => {}, // empty title: consumed by the mode arm
            .lanes, .help => {}, // consumed no-op arms
            // diff_viewer: the diff-viewer Enter handler swallows the key
            // before routeKey's submit branch is reached.
            .diff_viewer, .normal => {},
            .mcp => {}, // list view, no selection change: consumed no-op
            .plugins => {}, // installed view: consumed no-op (space owns toggle)
            .link_picker => {}, // empty links list: closes to normal
        }
        // Modes whose disposition is "act quietly": a leaked Enter (a
        // deleted or hollow submitMode arm) would fall through to
        // beginSubmit, whose idle-lane refusal appends a transcript notice
        // — so this count MUST stay flat for exactly these modes. The
        // refusal-noticing modes (.command, the runtime-bound pickers,
        // .help, .normal) legitimately append the shared-gate notice, and
        // .theme_picker posts its own apply notice, so none of those may
        // be listed here.
        const expect_quiet = switch (m) {
            .search, .settings, .tree_picker, .save_message, .lanes, .diff_viewer, .mcp, .plugins, .link_picker => true,
            .command, .provider_picker, .model_picker, .session_picker, .theme_picker, .help, .normal => false,
        };
        const notices_before = app.thread.transcript.messages.items.len;
        try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = '\r' } });
        if (expect_quiet) {
            try std.testing.expectEqual(notices_before, app.thread.transcript.messages.items.len);
        }

        // Sub-state dispositions that the bare mode sweep cannot see:
        switch (m) {
            .settings => {
                // Active edit: Enter belongs to the editor, not the rows.
                app.pickers.settings.tab = .prompt;
                app.pickers.settings.edit_target = .system_prompt;
                try app.input_buffers.settings_text.appendSlice(gpa, "d");
                try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = '\r' } });
                try std.testing.expectEqualStrings("d\n", app.input_buffers.settings_text.items);
                app.pickers.settings.edit_target = .none;
                app.input_buffers.settings_text.clearRetainingCapacity();
            },
            .mcp => {
                // Add form: Enter submits the form, overlay stays open.
                app.pickers.mcp.adding = true;
                try app.input_buffers.mcp_url.appendSlice(gpa, "https://example.com/mcp.json");
                try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = '\r' } });
                try std.testing.expect(!app.pickers.mcp.adding);
                try std.testing.expectEqual(@as(usize, 0), app.input_buffers.mcp_url.items.len);
                try std.testing.expectEqual(App.Mode.mcp, app.getMode());
            },
            .plugins => {
                // Add form: Enter submits the form, overlay stays open.
                app.pickers.plugins.adding = true;
                try app.input_buffers.plugin_store_url.appendSlice(gpa, "https://example.com/store.json");
                try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = '\r' } });
                try std.testing.expect(!app.pickers.plugins.adding);
                try std.testing.expectEqual(@as(usize, 0), app.input_buffers.plugin_store_url.items.len);
                try std.testing.expectEqual(App.Mode.plugins, app.getMode());
            },
            .session_picker => {
                // Rename sub-state: the idle-lane refusal leaves the
                // sub-state and its draft untouched (the confirm path
                // itself needs a live lane; it is pinned at the
                // submitSessionPicker level). Disposition: consumed, no
                // mutation.
                app.nav.session_action = .renaming;
                try app.input_buffers.session_rename_text.appendSlice(gpa, "New Name");
                try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = '\r' } });
                try std.testing.expectEqual(.renaming, app.nav.session_action);
                try std.testing.expectEqualStrings("New Name", app.input_buffers.session_rename_text.items);
                app.nav.session_action = .browsing;
                app.input_buffers.session_rename_text.clearRetainingCapacity();
            },
            else => {},
        }
        app.mode = .normal;
    }
}

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
    try std.testing.expect(app.quit_gate.isPending());
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
    try std.testing.expect(app.quit_gate.isPending());
    try std.testing.expect(!ctx.quit);
    app.quit_gate.cancelPending();

    // cp=0x04 with a stray alt bit (the exact mangled form from the log) —
    // also arms.
    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = 0x04, .mods = .{ .alt = true } } });
    try std.testing.expect(app.quit_gate.isPending());
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

    try std.testing.expect(app.quit_gate.isPending());
    try std.testing.expect(!ctx.quit);

    try captureEvent(&app, &root, &ctx, .{ .key_release = .{ .codepoint = 0x04, .mods = .{} } });
    try captureEvent(&app, &root, &ctx, bare_ctrl_d);
    try std.testing.expect(ctx.quit);
}

test "held Ctrl+C auto-repeat does not confirm quit without a release" {
    // A held chord auto-repeats as rapid key_press records on every platform.
    // POSIX terminals never send key_release, so the release bit cannot be the
    // disambiguator there — the sub-threshold gap must suppress the repeat.
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
    try captureEvent(&app, &root, &ctx, ctrl_c); // auto-repeat, no release in between

    try std.testing.expect(app.quit_gate.isPending());
    try std.testing.expect(!ctx.quit);
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

    try std.testing.expect(app.quit_gate.isPending());
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
    try std.testing.expect(app.quit_gate.isPending());
    try captureEvent(&app, &root, &ctx, ctrl_modifier);
    try std.testing.expect(app.quit_gate.isPending());
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
    try std.testing.expect(app.quit_gate.isPending());
    try std.testing.expect(!ctx.quit);

    // A deliberate second press with a real time gap (simulating a genuine
    // double-press rather than a held-key auto-repeat) must confirm exit even
    // though Windows Terminal delivers no key_release event for the chord.
    app.getIo().sleep(std.Io.Duration.fromMilliseconds(App.ctrl_c_auto_repeat_gap_ms + 50), .awake) catch {};
    try captureEvent(&app, &root, &ctx, ctrl_c);
    try std.testing.expect(ctx.quit);
}

test "Ctrl+D confirms an armed quit in an overlay, matching the hint" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();
    app.mode = .help;

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    const ctrl_c: vxfw.Event = .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } };
    const ctrl_d: vxfw.Event = .{ .key_press = .{ .codepoint = 'd', .mods = .{ .ctrl = true } } };
    try captureEvent(&app, &root, &ctx, ctrl_c);
    try std.testing.expect(app.quit_gate.isPending());
    try captureEvent(&app, &root, &ctx, .{ .key_release = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } });
    try captureEvent(&app, &root, &ctx, ctrl_d);

    // The pending-quit hint says "Ctrl+C or Ctrl+D again" in every mode.
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
    try std.testing.expect(app.quit_gate.isPending());

    // Any ordinary key falls through handleQuitSequence (returns false) and
    // routeKey cancels the pending prompt.
    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = 'x', .mods = .{} } });
    try std.testing.expect(!app.quit_gate.isActive());
}

test "confirmed quit state exits the TUI on the next tick" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    // Simulate the `/exit` command having set the confirmed state.
    app.quit_gate.confirm();

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

test "expired pending quit is cleared on the next tick" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    // Start from a completely idle tick state so we prove arming pending quit
    // schedules the tick needed to expire it.
    toast.global.count = 0;
    toast.global.head = 0;
    app.git_label_thread = app.thread;
    app.git_label_dirty = false;
    app.frame_geometry.blackhole_visible = false;
    app.metrics.loading_tick_active = false;

    var root: RootWidget = .{ .app = &app, .mcp_connect_pending = false };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    const ctrl_c: vxfw.Event = .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } };
    try captureEvent(&app, &root, &ctx, ctrl_c);
    try std.testing.expect(app.quit_gate.isPending());
    try std.testing.expect(app.metrics.loading_tick_active);

    // The 1500ms double-press window has elapsed: the prompt must disappear
    // instead of lingering with a stale "press again to exit" hint, trigger a
    // redraw, and stop ticking once idle again.
    app.getIo().sleep(std.Io.Duration.fromMilliseconds(App.ctrl_c_double_press_ms + 100), .awake) catch {};
    ctx.redraw = false;
    try lifecycle.handleTick(&root, &ctx);
    try std.testing.expect(!app.quit_gate.isActive());
    try std.testing.expect(ctx.redraw);
    try std.testing.expect(!app.metrics.loading_tick_active);
    try std.testing.expect(!ctx.quit);
}

test "double Ctrl+C confirms quit while background modal is open" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();
    // toggleBackgroundModal() refuses to open without a live BackgroundManager,
    // but routing only reads this flag. Set it directly so the test exercises
    // the background-modal branch instead of the ordinary key path.
    app.background_modal_state.modal = true;
    try std.testing.expect(root_layout.activeModalLayer(&app) == .background);

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    const ctrl_c: vxfw.Event = .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } };
    try captureEvent(&app, &root, &ctx, ctrl_c);
    try std.testing.expect(app.quit_gate.isPending());
    try std.testing.expect(!ctx.quit);

    try captureEvent(&app, &root, &ctx, .{ .key_release = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } });
    try captureEvent(&app, &root, &ctx, ctrl_c);
    try std.testing.expect(app.quit_gate.isConfirmed());
    try std.testing.expect(ctx.quit);
}

test "Escape closing an overlay cancels an armed pending quit" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();
    app.setMode(.help);

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } });
    try std.testing.expect(app.quit_gate.isPending());

    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    try std.testing.expect(app.getMode() == .normal);
    try std.testing.expect(!app.quit_gate.isActive());
}

test "releasing Ctrl before C still marks pending quit released" {
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
    try std.testing.expect(app.quit_gate.isPending());
    try std.testing.expect(!app.quit_gate.pendingKeyReleased());

    // User lifts Ctrl first, so C's release arrives without the ctrl modifier.
    try captureEvent(&app, &root, &ctx, .{ .key_release = .{ .codepoint = 'c', .mods = .{} } });
    try std.testing.expect(app.quit_gate.pendingKeyReleased());

    try captureEvent(&app, &root, &ctx, ctrl_c);
    try std.testing.expect(app.quit_gate.isConfirmed());
    try std.testing.expect(ctx.quit);
}

test "releasing either Control modifier marks pending quit released" {
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
    for ([_]u21{ vaxis.Key.left_control, vaxis.Key.right_control }) |control| {
        try captureEvent(&app, &root, &ctx, ctrl_c);
        try std.testing.expect(app.quit_gate.isPending());
        try std.testing.expect(!app.quit_gate.pendingKeyReleased());

        // Windows can report the modifier release before the character's.
        try captureEvent(&app, &root, &ctx, .{ .key_release = .{ .codepoint = control, .mods = .{} } });
        try std.testing.expect(app.quit_gate.pendingKeyReleased());
        app.quit_gate.cancelPending();
    }
}

test "decideShouldTick stays active for confirmed quit on an idle screen" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    toast.global.count = 0;
    toast.global.head = 0;
    app.git_label_thread = app.thread;
    app.git_label_dirty = false;
    app.frame_geometry.blackhole_visible = false;

    var root: RootWidget = .{ .app = &app, .mcp_connect_pending = false };
    try std.testing.expect(!lifecycle.decideShouldTick(&root));

    app.quit_gate.confirm();
    try std.testing.expect(lifecycle.decideShouldTick(&root));
}

test "paste event cancels an armed pending quit" {
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
    try std.testing.expect(app.quit_gate.isPending());

    try captureEvent(&app, &root, &ctx, .{ .paste = "hello" });
    try std.testing.expect(!app.quit_gate.isActive());
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
    try std.testing.expect(!app.quit_gate.isActive());
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
    // menu; during a paste it must stay in normal mode even when forwarded
    // to the TextField (which fires `event_callbacks.inputChanged`).
    const slash_key: vaxis.Key = .{ .codepoint = '/', .text = "/" };
    try captureEvent(&app, &root, &ctx, .{ .key_press = slash_key });
    try app.inputs.input.handleEvent(&ctx, .{ .key_press = slash_key });

    try std.testing.expect(app.getMode() == .normal);
    try std.testing.expect(app.isPasting());
    try std.testing.expectEqualStrings("/", app.inputs.input.buf.firstHalf());

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

test "MCP add-server form: Enter reaches the handler instead of the chat submit" {
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

    tui.openMcp(&app);
    try std.testing.expectEqual(App.Mode.mcp, app.getMode());

    // 'a' opens the add-server form.
    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = 'a' } });
    try std.testing.expect(app.pickers.mcp.adding);

    // Typed characters accumulate in the URL buffer via the form's own handler.
    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = 'x' } });
    try std.testing.expectEqualStrings("x", app.input_buffers.mcp_url.items);

    // Regression: Enter used to be swallowed by the generic chat submit —
    // submitMode had no `.mcp` arm, so the form stayed open forever until a
    // hand-written routeKey exception started routing the overlay's Enter
    // into handlePerModeKey. submitMode now owns the overlay (submitMcp →
    // addMcpFromForm): Enter closes the form and clears the buffer.
    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = '\r' } });
    try std.testing.expect(!app.pickers.mcp.adding);
    try std.testing.expectEqual(@as(usize, 0), app.input_buffers.mcp_url.items.len);
    // The overlay stays open — only the form closed.
    try std.testing.expectEqual(App.Mode.mcp, app.getMode());
}

test "isClipboardPasteChord recognizes all three paste chords and rejects lookalikes" {
    const Case = struct { key: vaxis.Key, expected: bool };
    const cases = [_]Case{
        // The three accepted paste routes (all call pasteFromSystemClipboard).
        .{ .key = .{ .codepoint = 'v', .mods = .{ .alt = true } }, .expected = true },
        .{ .key = .{ .codepoint = 'v', .mods = .{ .ctrl = true } }, .expected = true },
        .{ .key = .{ .codepoint = vaxis.Key.insert, .mods = .{ .shift = true } }, .expected = true },
        // Lookalikes that must fall through to normal key handling.
        .{ .key = .{ .codepoint = 'v', .mods = .{} }, .expected = false },
        .{ .key = .{ .codepoint = 'v', .mods = .{ .ctrl = true, .alt = true } }, .expected = false },
        .{ .key = .{ .codepoint = vaxis.Key.right, .mods = .{ .alt = true } }, .expected = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, isClipboardPasteChord(case.key));
    }
}

test "help overlay Enter closes help without submitting prompt input" {
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

    try app.inputs.input.insertSliceAtCursor("do not submit");
    app.mode = .help;

    try captureEvent(&app, &root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqual(App.Mode.normal, app.getMode());
    try std.testing.expectEqual(@as(usize, 0), app.thread.transcript.messages.items.len);
}

test "selectOverlayRowAt maps rendered screen row to item k across all selectable overlay modes" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    // Seed data for every selectable overlay mode so item k=2 exists.
    try app.pickers.search.matches.appendSlice(gpa, &.{
        .{ .message_index = 0, .role = "user", .start = 0, .end = 1, .snippet = try gpa.dupe(u8, "a") },
        .{ .message_index = 0, .role = "user", .start = 0, .end = 1, .snippet = try gpa.dupe(u8, "b") },
        .{ .message_index = 0, .role = "user", .start = 0, .end = 1, .snippet = try gpa.dupe(u8, "c") },
    });
    try app.pickers.links.items.appendSlice(gpa, &.{
        .{ .label = try gpa.dupe(u8, "l0"), .url = try gpa.dupe(u8, "https://0") },
        .{ .label = try gpa.dupe(u8, "l1"), .url = try gpa.dupe(u8, "https://1") },
        .{ .label = try gpa.dupe(u8, "l2"), .url = try gpa.dupe(u8, "https://2") },
    });
    const provider_picker = @import("widgets/provider_picker.zig");
    const provider_entries = [_]provider_picker.ProviderHandle{
        .{ .builtin = .openai },
        .{ .builtin = .anthropic },
        .{ .builtin = .ollama },
    };
    app.pickers.provider.entries = &provider_entries;
    app.list_widgets.model_list.item_count = 5; // Header + 4 models
    app.list_widgets.model_list.scroll.top = 0;
    app.list_widgets.resume_list.item_count = 4;
    app.list_widgets.resume_list.scroll.top = 0;
    app.list_widgets.tree_list.item_count = 4;
    app.list_widgets.tree_list.scroll.top = 0;
    app.list_widgets.lanes_list.item_count = 4;
    app.list_widgets.lanes_list.scroll.top = 0;

    const rect: app_state_mod.ChipRect = .{ .row = 5, .col = 10, .width = 60, .height = 15 };
    const k: u32 = 2;

    const Case = struct {
        mode: App.Mode,
        click_row: i16,
    };
    const cases = [_]Case{
        // Searchable overlays: border(+0), >(+1), ─(+2), list starts at rect.row + 3 = 8.
        .{ .mode = .command, .click_row = 8 + k },
        .{ .mode = .theme_picker, .click_row = 8 + k },
        .{ .mode = .provider_picker, .click_row = 8 + k },
        .{ .mode = .search, .click_row = 8 + k },
        .{ .mode = .session_picker, .click_row = 8 + k },
        // model_picker has 1-row Header at +0 inside list -> item k=2 is at 8 + 1 + 2 = 11.
        .{ .mode = .model_picker, .click_row = 8 + 1 + k },
        // tree_picker has 2-row "Filter: ..." header above list -> item k=2 is at 8 + 2 + 2 = 12.
        .{ .mode = .tree_picker, .click_row = 8 + 2 + k },
        // full_panel overlays: border(+0), list starts at rect.row + 1 = 6.
        .{ .mode = .lanes, .click_row = 6 + k },
        .{ .mode = .link_picker, .click_row = 6 + k },
    };

    for (cases) |c| {
        app.mode = c.mode;
        try std.testing.expect(selectOverlayRowAt(&app, rect, c.click_row));
        const actual: u32 = switch (c.mode) {
            .command => app.nav.command_selection,
            .theme_picker => app.pickers.theme.selection,
            .provider_picker => app.pickers.provider.selection,
            .search => app.pickers.search.selection,
            .session_picker => app.nav.resume_selection,
            .model_picker => app.pickers.models.model_selection,
            .tree_picker => app.pickers.tree.selection,
            .lanes => app.nav.lanes_selection,
            .link_picker => app.pickers.links.selection,
            else => unreachable,
        };
        try std.testing.expectEqual(k, actual);
    }

    // Header rows in model_picker and tree_picker must not select item 0.
    app.mode = .model_picker;
    try std.testing.expect(!selectOverlayRowAt(&app, rect, 8));
    app.mode = .tree_picker;
    try std.testing.expect(!selectOverlayRowAt(&app, rect, 8));
    try std.testing.expect(!selectOverlayRowAt(&app, rect, 9));
}
