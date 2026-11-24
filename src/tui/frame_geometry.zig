//! Pre-draw frame geometry and hit-test map (`FrameGeometry`).
//!
//! Computed once at the top of `drawRoot` (and on resize) before constructing
//! widgets, replacing `*_out` write-back pointers and draw-time mutations to
//! `App`, `NavState`, and picker scroll fields (#568).

const std = @import("std");
const vxfw = @import("vaxis").vxfw;

const tui = @import("../tui.zig");
const app_state = @import("app_state.zig");
const layout_mod = @import("layout.zig");
const input_mod = @import("widgets/input.zig");
const overlay_mod = @import("widgets/overlay.zig");
const agent_worker = @import("agent_worker.zig");

const App = tui.App;

pub const FrameGeometry = struct {
    terminal_width: u16 = 0,
    terminal_height: u16 = 0,
    input_surface_row: u16 = 0,
    input_wrap_width: u16 = 0,
    lanes_chip_rect: ?app_state.ChipRect = null,
    new_output_rect: ?app_state.ChipRect = null,
    permission_panel_rect: ?app_state.ChipRect = null,
    permission_buttons: ?[4]app_state.PermissionButton = null,
    overlay_panel_rect: ?app_state.ChipRect = null,
    drawn_overlay_width: u16 = 0,
    drawn_overlay_height: u16 = 0,
    split_rects: [4]layout_mod.ColumnRect = undefined,
    split_rect_count: usize = 0,
    blackhole_visible: bool = true,
    diff_viewport_rows: u16 = 0,
    layout: layout_mod.RootLayout = .{
        .input_height = 0,
        .loading_height = 0,
        .transcript_height = 0,
        .loading_row = 0,
        .input_row = 0,
    },

    /// Return the live transcript viewport dimensions for `focused_lane_index`
    /// (the matching split column when split, or the single-pane transcript
    /// surface otherwise). Returns 0x0 if `computeFrameGeometry` has not run yet.
    pub fn focusedTranscriptViewport(self: FrameGeometry, focused_lane_index: usize) struct { width: u16, height: u16 } {
        if (self.split_rect_count > 0) {
            for (self.split_rects[0..self.split_rect_count]) |rect| {
                if (rect.lane_index == focused_lane_index) {
                    return .{ .width = rect.width, .height = rect.height };
                }
            }
        }
        return .{ .width = self.terminal_width, .height = self.layout.transcript_height };
    }
};

pub fn computeFrameGeometry(
    app: *App,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
    input_combined: []const u8,
) FrameGeometry {
    var geom: FrameGeometry = .{
        .terminal_width = width,
        .terminal_height = height,
    };

    if (app.mode == .diff_viewer) {
        const editing = app.diff.sub == .commenting;
        const footer_h: u16 = if (editing) @min(height -| 1, @as(u16, 3)) else @min(height -| 1, @as(u16, 2));
        geom.diff_viewport_rows = height -| footer_h;
        geom.blackhole_visible = false;
        if (app.permissionPending()) {
            const panel_height: u16 = @min(@as(u16, 12), @max(@as(u16, 5), height));
            const panel_row = height -| panel_height;
            geom.permission_panel_rect = .{
                .row = panel_row,
                .col = 0,
                .width = width,
                .height = panel_height,
            };
            geom.permission_buttons = computePermissionButtons(panel_row, panel_height, width);
        }
        return geom;
    }

    if (width < layout_mod.min_usable_width or height < layout_mod.min_usable_height) {
        return geom;
    }

    const loading_visible = app.thread.turn_view.awaitingOutput();
    const split = app.split_mode != .tab and app.threads.len() > 1;
    const raw_text_rows = input_mod.wrappedTextRows(ctx, input_combined, width -| 4);
    const root_lay = layout_mod.rootLayout(
        height,
        raw_text_rows,
        loading_visible or split,
        app.thread.queued.items.len > 0,
    );
    geom.layout = root_lay;
    geom.input_surface_row = root_lay.input_row;
    geom.input_wrap_width = width -| 4;

    if (split) {
        const cols = layout_mod.computeSplitLayout(
            width,
            root_lay.transcript_height,
            app.split_mode,
            app.threads.len(),
            app.focused_worker_index,
            app.cached_config.tui.min_split_width,
            &geom.split_rects,
        );
        geom.split_rect_count = cols.len;
    }

    const show_lanes_chip = app.split_mode == .tab and app.threads.len() > 1;
    if (show_lanes_chip) {
        const base_row: u16 = root_lay.input_height -| 1;
        var buf: [32]u8 = undefined;
        const pill = std.fmt.bufPrint(&buf, " {d} Lanes ", .{app.threads.len()}) catch "";
        const lanes_width: u16 = @min(@as(u16, @intCast(pill.len)), width -| 2);
        geom.lanes_chip_rect = .{
            .row = root_lay.input_row + base_row,
            .col = 1,
            .width = lanes_width,
        };
    }

    const overlay_visible = app.mode != .normal;
    if (overlay_visible) {
        const size = overlay_mod.overlaySizeFor(
            app.mode,
            app.pickers.provider.stage == .form,
            width,
            root_lay.transcript_height,
        );
        const total_w: u16 = @min(size.width, width);
        const total_h: u16 = @min(size.height, root_lay.transcript_height);
        geom.drawn_overlay_width = total_w;
        geom.drawn_overlay_height = total_h;
        geom.overlay_panel_rect = .{
            .row = (root_lay.transcript_height -| total_h) / 2,
            .col = (width -| total_w) / 2,
            .width = total_w,
            .height = total_h,
        };
    }

    const permission_visible = app.permissionPending() and !overlay_visible;
    if (permission_visible) {
        const panel_height: u16 = @min(@as(u16, 12), @max(@as(u16, 5), root_lay.input_row));
        const panel_row = root_lay.input_row -| panel_height;
        geom.permission_panel_rect = .{
            .row = panel_row,
            .col = 0,
            .width = width,
            .height = panel_height,
        };
        geom.permission_buttons = computePermissionButtons(panel_row, panel_height, width);
    }

    const messages = app.thread.transcript.messages.items;
    const is_last = if (app.thread.transcript.selected) |sel| sel + 1 >= messages.len else true;
    const pill_len: u16 = @intCast(" ↓ new output ".len);
    const needs_pill = !split and
        !app.thread.auto_scroll and
        (app.thread.transcript_list.scroll.has_more or !is_last) and
        width > pill_len + 4 and
        root_lay.transcript_height > 2;
    if (needs_pill) {
        geom.new_output_rect = .{
            .row = root_lay.transcript_height -| 2,
            .col = width -| pill_len -| 2,
            .width = pill_len,
        };
    }

    geom.blackhole_visible = isBlackholeVisible(app);

    return geom;
}

/// True when the startup blackhole logo is visible in the transcript.
/// Pure function of App state so tick scheduling does not depend on last frame's draw.
pub fn isBlackholeVisible(app: *const App) bool {
    const messages = app.thread.transcript.messages.items;
    const splash_suppressed = app.inputs.input.buf.realLength() > 0;
    return app.mode == .normal and
        messages.len > 0 and
        messages[0] == .logo and
        app.thread.transcript_list.scroll.top == 0 and
        !splash_suppressed;
}

fn computePermissionButtons(
    panel_row: u16,
    panel_height: u16,
    width: u16,
) ?[4]app_state.PermissionButton {
    const inner_h = panel_height -| 2;
    const inner_w = width -| 2;
    if (inner_h == 0 or inner_w == 0) return null;
    const action_row = inner_h -| 1;
    const base_screen_row = panel_row + 1;

    const items = [_]struct { choice: agent_worker.ApprovalChoice, text_len: u16 }{
        .{ .choice = .approve, .text_len = "Approve [Y]".len },
        .{ .choice = .approve_session, .text_len = "Session [S]".len },
        .{ .choice = .reject, .text_len = "Reject [N]".len },
        .{ .choice = .reject_with_reason, .text_len = "Reason [R]".len },
    };

    var recorded: [4]app_state.PermissionButton = undefined;
    var col: u16 = 1;
    for (items, 0..) |item, i| {
        if (col >= inner_w) return null;
        // Selected: "▶ [ " (4) + text + " ]" (2) = text_len + 6.
        // Unselected: "    " (4) + text + "  " (2) = text_len + 6.
        const label_width = item.text_len + 6;
        recorded[i] = .{
            .choice = item.choice,
            .row = base_screen_row + action_row,
            .col = col + 1,
            .width = label_width,
        };
        col += label_width + 2;
    }
    return recorded;
}

test "computeFrameGeometry lanes_chip_rect.row matches input base_row across terminal heights and line counts" {
    const agent_mod = @import("../agent.zig");
    const test_helpers = @import("test_helpers.zig");
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Ensure at least 2 lanes in .tab mode so lanes_chip_rect is populated.
    try test_helpers.addIdleFocusedLane(gpa, &app, "2");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var lines_buf: [60]u8 = undefined;
    var h: u16 = 10;
    while (h <= 80) : (h += 10) {
        var r: usize = 1;
        while (r <= 30) : (r += 5) {
            const len = @min(lines_buf.len, (r - 1) * 2);
            for (0..len) |i| {
                lines_buf[i] = if (i % 2 == 0) 'a' else '\n';
            }
            const ctx: vxfw.DrawContext = .{
                .arena = arena.allocator(),
                .min = .{},
                .max = .{ .width = 80, .height = h },
                .cell_size = .{ .width = 10, .height = 20 },
            };
            const geom = computeFrameGeometry(&app, ctx, 80, h, lines_buf[0..len]);
            try std.testing.expect(geom.lanes_chip_rect != null);
            try std.testing.expectEqual(geom.layout.input_row + (geom.layout.input_height -| 1), geom.lanes_chip_rect.?.row);
        }
    }
}
