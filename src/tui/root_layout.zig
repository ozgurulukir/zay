//! Top-level `drawRoot` layout.
//!
//! Pulled out of `tui.zig` (R6.2 of `_pm/Projects/tui-split`) — the RootWidget's
//! `draw` callback. Decides, per frame, what the screen shows: a single transcript
//! column or a 2-wide tiled grid, the loading spinner strip when a turn is
//! running, the bordered input box, and (stacked above the input by descending
//! priority) the centered mode overlay, the permission prompt, the background-jobs
//! modal, and the at-mention search popup.
//!
//! The diff viewer short-circuits this layout entirely via `drawDiffViewer`.
//!
//! Free function taking `*App` and the outer `vxfw.Widget` handle, matching the
//! pattern R5.2b established for `drawDiffViewer`.

const std = @import("std");
const vaxis = @import("vaxis");
const tui_style = @import("style.zig");
const telemetry = @import("telemetry.zig");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const agent_mod = @import("../agent.zig");
const root_layout = @import("layout.zig");
const lane_column = @import("lane_column.zig");
const diff_viewer_overlay = @import("diff_viewer_overlay.zig");
const tui_status = @import("status.zig");
const tx_widget = @import("widgets/transcript.zig");
const loading = @import("widgets/loading.zig");
const turn_view_mod = @import("turn_view.zig");
const input_mod = @import("widgets/input.zig");
const permission = @import("widgets/permission.zig");
const background_jobs = @import("widgets/background_jobs.zig");
const at_search = @import("widgets/at_search.zig");
const overlay = @import("widgets/overlay.zig");
const toast = @import("toast.zig");
const permission_mod = @import("permission.zig");
const lanes_util = @import("lanes.zig");
const tui_message = @import("widgets/message.zig");

const App = tui.App;

/// Build the input widget's per-frame view model (INV-WIDGET-1): every fact
/// the widget renders, computed HERE from the App, so the widget stays a pure
/// function of its props. `combined_text` is the frame-arena concatenation of
/// the input buffer halves (also reused for the layout row count).
fn buildInputProps(app: *App, arena: std.mem.Allocator, combined_text: []const u8) input_mod.InputProps {
    const rt = app.liveRuntime();
    var status_text: []const u8 = if (tui_status.modelStatus(rt, app.cached_config)) |status|
        tui_status.formatModelStatus(arena, status) catch "no model"
    else
        "no model";
    var hit_buf: [32]u8 = undefined;
    if (app.pickers.search.hitCounterText(&hit_buf)) |counter| {
        status_text = std.fmt.allocPrint(arena, "{s} · search {s}", .{ status_text, counter }) catch status_text;
    }

    const tui_cfg = app.cached_config.tui;
    const p = tui_style.activePalette();
    var meter_text: []const u8 = "";
    var meter_style: vaxis.Style = p.model_status;
    if (tui_cfg.show_context_meter) {
        const live_max: u32 = if (rt) |r|
            r.agent.context_window_tokens
        else if (app.metrics.context_tokens_max > 0)
            app.metrics.context_tokens_max
        else
            128000;
        const live_used: u32 = if (rt) |r|
            agent_mod.currentContextTokens(&r.agent)
        else if (app.metrics.context_tokens_used > 0)
            app.metrics.context_tokens_used
        else
            0;
        var meter_buf: [64]u8 = undefined;
        const meter = telemetry.TelemetryTracker.formatContextBar(
            @intCast(live_used),
            @intCast(live_max),
            tui_cfg.context_threshold_warn,
            tui_cfg.context_threshold_alert,
            &meter_buf,
        );
        meter_text = arena.dupe(u8, meter.text) catch "";
        meter_style = switch (meter.level) {
            .normal => p.success,
            .warn => p.notice,
            .alert => p.error_style,
        };
    }

    var velocity_text: []const u8 = "";
    if (tui_cfg.show_token_velocity) {
        const is_streaming = switch (app.thread.turn_view.activity) {
            .writing_response, .thinking => true,
            else => false,
        };
        var velocity_buf: [32]u8 = undefined;
        const vel = telemetry.TelemetryTracker.formatVelocity(app.metrics.telemetry.current_tokens_per_sec, is_streaming, &velocity_buf);
        if (vel.len > 0) velocity_text = arena.dupe(u8, vel) catch "";
    }

    const counts = app.metrics.diff_counts;
    return .{
        .input_field = &app.inputs.input,
        .input_text = combined_text,
        .input_cursor = app.inputs.input.buf.firstHalf().len,
        .input_wrap_width = &app.input_wrap_width,
        .input_surface_row = app.input_surface_row,
        .chip_rect_out = &app.nav.lanes_chip_rect,
        .queued = app.thread.queued.items,
        .queued_selection = app.nav.queued_selection,
        .prompt_text = if (app.mode == .normal) ">" else " ",
        .hint_text = input_mod.hintText(.{
            .pending_quit = app.getPendingQuitAt() != null,
            .mode = app.mode,
            .session_action = app.nav.session_action,
            .provider_stage = app.pickers.provider.stage,
            .lanes_purpose = app.nav.lanes_purpose,
        }),
        .pending_quit = app.getPendingQuitAt() != null,
        .diff_counts = if (counts.additions > 0 or counts.deletions > 0) counts else null,
        .background_jobs = app.runningBackgroundCount(),
        .show_lanes_chip = app.split_mode == .tab and app.threads.len() > 1,
        .lanes_count = app.threads.len(),
        .status_text = status_text,
        .meter_text = meter_text,
        .meter_style = meter_style,
        .velocity_text = velocity_text,
        .git_label = app.metrics.git_label,
        .skill_inventory = if (tui_cfg.show_skill_inventory) app.thread.skill_inventory.items else &.{},
    };
}

/// The driver's workspace borrow, if any — the lane whose worktree path the
/// driver (threads[0]) entered. Only the driver enters lanes, so its agent is
/// the only one that can hold a workspace.
fn driverWorkspacePath(app: *const App) ?[]const u8 {
    if (app.threads.len() == 0) return null;
    const agent = app.threads.at(0).agent orelse return null;
    return agent.workspaceBorrow();
}

/// Modal layer priority shared by rendering (`drawRoot`) and input routing
/// (`event_router`) so visual z-order and input capture order never diverge.
pub const ModalLayer = enum {
    overlay,
    permission,
    background,
    at_search,
    none,
};

pub fn activeModalLayer(app: *App) ModalLayer {
    if (app.mode != .normal and app.mode != .diff_viewer) return .overlay;
    if (app.permissionPending()) return .permission;
    if (app.background_modal_state.modal) return .background;
    if (app.at_search != .closed) return .at_search;
    return .none;
}

/// Build `TranscriptProps` for any lane (single-pane or split-pane) so both
/// `drawRoot` and `buildLaneColumnProps` pass the exact same props.
pub fn buildTranscriptProps(app: *App, lane: *tui.Thread, now_ms: i64) tx_widget.TranscriptProps {
    const has_model = tui_status.modelStatus(app.liveRuntime(), app.cached_config) != null;
    const active_hit = app.pickers.search.activeHit();
    return .{
        .thread = lane,
        .gpa = app.gpa,
        .has_model_configured = has_model,
        .loading_frame = app.metrics.loading_frame,
        .blackhole_frame = if (app.cached_config.tui.animations == .full) app.metrics.blackhole_frame else 0,
        .blackhole_visible = &app.metrics.blackhole_visible,
        // Only the pane whose lane owns the shared input yields its splash;
        // sibling lanes keep theirs until their own first prompt.
        .splash_suppressed = (lane == app.thread) and app.inputs.input.buf.realLength() > 0,
        .search_query = app.pickers.search.query,
        .active_search_hit = if (active_hit) |h| .{ .message_index = h.message_index, .start = h.start, .end = h.end } else null,
        .now_ms = now_ms,
        .body_selection = lane.transcript.body_selection,
        .new_output_rect_out = if (lane == app.thread) &app.nav.new_output_rect else null,
    };
}

/// Build a lane column's per-frame view model (INV-WIDGET-1): every fact
/// `LaneColumnWidget` renders, computed HERE from the App, so the widget
/// stays a pure function of its props.
pub fn buildLaneColumnProps(app: *App, lane: *tui.Thread, width: u16, height: u16, active: bool, focused: bool, now_ms: i64) lane_column.LaneColumnProps {
    const title: []const u8 = if (lane.title) |t| t else "untitled";
    // Turn-state marker (S14): a spinner frame while the lane's turn is
    // running, a stop glyph while interrupting, a quiet dot when idle. A
    // manual /compact on this lane spins the same frame — the "lane is
    // busy" signal the model watches for.
    const compacting = if (lane.agent) |agent| agent_mod.manualCompactPending(agent) else false;
    const state_glyph: []const u8 = if (compacting)
        tui_message.loading_frames[app.metrics.loading_frame % tui_message.loading_frames.len]
    else switch (lane.turn.state) {
        .active => tui_message.loading_frames[app.metrics.loading_frame % tui_message.loading_frames.len],
        .interrupting => "■",
        .idle => "·",
    };
    // Distinct marker on the lane the driver's workspace currently points at —
    // the "active lane tracking" the model needs to see at a glance.
    const ws_marker: []const u8 = if (driverWorkspacePath(app)) |ws| blk: {
        if (lanes_util.workingLaneOf(lane)) |w| {
            if (lanes_util.pathsEqual(ws, w.path)) break :blk " ⇄";
        }
        break :blk "";
    } else "";
    // `active` and `focused` are distinct: `active` marks the ●/dim state,
    // `focused` is the single column whose border is highlighted (when the
    // knob is enabled).
    const p = tui_style.activePalette();
    var border_style: vaxis.Style = if (active) p.body else p.border;
    if (focused and app.cached_config.tui.highlight_focused_border) {
        border_style = p.border_label;
    }
    return .{
        .transcript = buildTranscriptProps(app, lane, now_ms),
        .width = width,
        .height = height,
        .active = active,
        .title = title,
        .state_glyph = state_glyph,
        .ws_marker = ws_marker,
        .border_style = border_style,
    };
}

/// Turn vxfw's logical blank cells into physical spaces before vaxis renders
/// the frame. Vaxis deliberately skips `Cell.default` cells, so leaving them
/// in a reused terminal row preserves characters from the previous frame.
fn materializeBlankCells(arena: std.mem.Allocator, root: *vxfw.Surface) !void {
    var pending: std.ArrayList(*vxfw.Surface) = .empty;
    defer pending.deinit(arena);
    try pending.append(arena, root);

    while (pending.pop()) |surface| {
        for (surface.buffer) |*cell| {
            if (cell.default) {
                cell.char = .{};
                cell.default = false;
            }
        }
        for (surface.children) |*child| {
            try pending.append(arena, &child.surface);
        }
    }
}

/// Context container for constructing top widget storage buffers across split layout modes.
const TopWidgetBuffers = struct {
    transcript_box: vxfw.SizedBox = undefined,
    dual_lane_widgets: [2]lane_column.LaneColumnWidget = undefined,
    dual_lane_boxes: [2]vxfw.SizedBox = undefined,
    dual_flex_items: [2]vxfw.FlexItem = undefined,
    dual_row: vxfw.FlexRow = undefined,
    grid_lane_widgets: [4]lane_column.LaneColumnWidget = undefined,
    grid_lane_boxes: [4]vxfw.SizedBox = undefined,
    grid_row0_buf: [2]vxfw.FlexItem = undefined,
    grid_row1_buf: [2]vxfw.FlexItem = undefined,
    grid_row0_flex: vxfw.FlexRow = undefined,
    grid_row1_flex: vxfw.FlexRow = undefined,
    grid_rows_buf: [2]vxfw.FlexItem = undefined,
    grid_col: vxfw.FlexColumn = undefined,
    split_box: vxfw.SizedBox = undefined,
};

/// Build top area widget (single transcript column or tiled grid/dual split columns).
fn buildTopWidget(
    app: *App,
    split: bool,
    split_cols: []const root_layout.ColumnRect,
    max_width: u16,
    transcript_height: u16,
    now_ms: i64,
    transcript_view: *tx_widget.TranscriptWidget,
    bufs: *TopWidgetBuffers,
) vxfw.Widget {
    if (split) {
        if (app.split_mode == .dual) {
            for (split_cols, 0..) |col, i| {
                const lane = app.threads.slice()[col.lane_index];
                const worker_focus = @max(@min(app.focused_worker_index, app.threads.len() - 1), 1);
                const active = (col.lane_index == 0) or (col.lane_index == worker_focus);
                const focused = (col.lane_index == worker_focus);
                bufs.dual_lane_widgets[i] = .{
                    .props = buildLaneColumnProps(app, lane, col.width, col.height, active, focused, now_ms),
                };
                bufs.dual_lane_boxes[i] = .{
                    .child = bufs.dual_lane_widgets[i].widget(),
                    .size = .{ .width = col.width, .height = col.height },
                };
                bufs.dual_flex_items[i] = .{ .widget = bufs.dual_lane_boxes[i].widget(), .flex = 0 };
            }
            bufs.dual_row = .{ .children = bufs.dual_flex_items[0..split_cols.len] };
            bufs.split_box = .{
                .child = bufs.dual_row.widget(),
                .size = .{ .width = max_width, .height = transcript_height },
            };
            return bufs.split_box.widget();
        } else {
            var row0_count: usize = 0;
            var row1_count: usize = 0;
            for (split_cols, 0..) |col, i| {
                const lane = app.threads.slice()[col.lane_index];
                const active = (col.lane_index == @as(usize, app.activeIndex()));
                const focused = (col.lane_index == @as(usize, app.activeIndex()));
                bufs.grid_lane_widgets[i] = .{
                    .props = buildLaneColumnProps(app, lane, col.width, col.height, active, focused, now_ms),
                };
                bufs.grid_lane_boxes[i] = .{
                    .child = bufs.grid_lane_widgets[i].widget(),
                    .size = .{ .width = col.width, .height = col.height },
                };
                if (col.row == 0) {
                    bufs.grid_row0_buf[row0_count] = .{ .widget = bufs.grid_lane_boxes[i].widget(), .flex = 0 };
                    row0_count += 1;
                } else {
                    bufs.grid_row1_buf[row1_count] = .{ .widget = bufs.grid_lane_boxes[i].widget(), .flex = 0 };
                    row1_count += 1;
                }
            }
            bufs.grid_row0_flex = .{ .children = bufs.grid_row0_buf[0..row0_count] };
            bufs.grid_rows_buf[0] = .{ .widget = bufs.grid_row0_flex.widget(), .flex = 0 };
            var grid_rows_count: usize = 1;
            if (row1_count > 0) {
                bufs.grid_row1_flex = .{ .children = bufs.grid_row1_buf[0..row1_count] };
                bufs.grid_rows_buf[1] = .{ .widget = bufs.grid_row1_flex.widget(), .flex = 0 };
                grid_rows_count = 2;
            }
            bufs.grid_col = .{ .children = bufs.grid_rows_buf[0..grid_rows_count] };
            bufs.split_box = .{
                .child = bufs.grid_col.widget(),
                .size = .{ .width = max_width, .height = transcript_height },
            };
            return bufs.split_box.widget();
        }
    } else {
        bufs.transcript_box = .{
            .child = transcript_view.widget(),
            .size = .{ .width = max_width, .height = transcript_height },
        };
        return bufs.transcript_box.widget();
    }
}

/// Context options for `buildOverlayChildren`.
const OverlayFlags = struct {
    overlay_visible: bool,
    permission_visible: bool,
    background_visible: bool,
    at_visible: bool,
    toast_visible: bool,
};

/// Construct subsurfaces for all visible modal overlays, prompts, popups, and toasts.
fn buildOverlayChildren(
    app: *App,
    ctx: vxfw.DrawContext,
    layout: root_layout.RootLayout,
    max_width: u16,
    max_height: u16,
    main_surface: vxfw.Surface,
    overlay_view: *overlay.OverlayWidget,
    flags: OverlayFlags,
) std.mem.Allocator.Error![]vxfw.SubSurface {
    var child_count: usize = 1;
    if (flags.overlay_visible) child_count += 1;
    if (flags.permission_visible) child_count += 1;
    if (flags.background_visible) child_count += 1;
    if (flags.at_visible) child_count += 1;
    if (flags.toast_visible) child_count += 1;

    const children = try ctx.arena.alloc(vxfw.SubSurface, child_count);
    children[0] = .{
        .origin = .{ .row = 0, .col = 0 },
        .surface = main_surface,
        .z_index = 0,
    };
    var idx: usize = 1;

    if (flags.overlay_visible) {
        var centered_overlay: vxfw.Center = .{ .child = overlay_view.widget() };
        const overlay_surface = try centered_overlay.widget().draw(ctx.withConstraints(
            .{ .width = max_width, .height = layout.transcript_height },
            .{ .width = max_width, .height = layout.transcript_height },
        ));
        children[idx] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = overlay_surface,
            .z_index = 2,
        };
        if (overlay_surface.children.len > 0) {
            const sub = overlay_surface.children[0];
            app.nav.overlay_panel_rect = .{
                .row = @intCast(@max(0, sub.origin.row)),
                .col = @intCast(@max(0, sub.origin.col)),
                .width = sub.surface.size.width,
                .height = sub.surface.size.height,
            };
        }
        idx += 1;
    } else {
        app.drawn_overlay_width = 0;
        app.drawn_overlay_height = 0;
        app.nav.overlay_panel_rect = null;
    }

    if (flags.permission_visible) {
        const lane = permission_mod.approvalLane(app);
        const worker = if (lane) |l| if (l.worker_context) |*wc| wc else null else null;
        const snapshot = if (worker) |w| try w.approval.snapshot(w.io, ctx.arena, app.thread.permission_selection) else null;
        const label: []const u8 = if (lane) |l| blk: {
            if (l != app.thread) {
                const hex_id = if (lanes_util.workingLaneOf(l)) |w| lanes_util.lastPathSegment(w.path) else null;
                break :blk std.fmt.allocPrint(ctx.arena, "Lane {s} requests approval", .{hex_id orelse "?"}) catch "Tool Approval Request";
            } else {
                break :blk "Tool Approval Request";
            }
        } else "Tool Approval Request";

        const panel_height: u16 = @min(@as(u16, 12), @max(@as(u16, 5), layout.input_row));
        const panel_row = layout.input_row -| panel_height;
        app.nav.permission_panel_rect = .{
            .row = panel_row,
            .col = 0,
            .width = max_width,
            .height = panel_height,
        };

        var permission_view: permission.PermissionWidget = .{
            .snapshot = snapshot,
            .scroll = app.thread.permission_scroll,
            .label = label,
            .base_screen_row = panel_row,
            .buttons_out = &app.nav.permission_buttons,
        };
        children[idx] = .{
            .origin = .{ .row = panel_row, .col = 0 },
            .surface = try permission_view.widget().draw(ctx.withConstraints(
                .{ .width = max_width, .height = panel_height },
                .{ .width = max_width, .height = panel_height },
            )),
            .z_index = 3,
        };
        idx += 1;
    } else {
        app.nav.permission_panel_rect = null;
        app.nav.permission_buttons = null;
    }

    if (flags.background_visible) {
        // The modal renders the display cache built by lifecycle processing
        // (`background_delivery.refreshBackgroundModalCache` — tick and key
        // handling). Draw performs no manager snapshot and no file read; a
        // missing cache (transient snapshot error at open) renders the
        // empty-state placeholder.
        const cache = app.background_modal_state.cache;
        const views: []const tui.background_mod.BackgroundManager.JobView = if (cache) |c| c.views else &.{};
        var jobs_view: background_jobs.BackgroundJobsWidget = .{ .props = .{
            .views = views,
            .selection = app.background_modal_state.selection,
            .cancel_focus = app.background_modal_state.cancel_focus,
            .log_expanded = app.background_modal_state.log_expanded,
            .log_text = if (cache) |c| c.log_text else "",
            .log_note = if (cache) |c| c.log_note else "",
        } };
        const rows: usize = @min(@as(usize, 8), views.len);
        const panel_height = background_jobs.panelHeight(
            rows,
            app.background_modal_state.log_expanded,
            if (cache) |c| c.log_text else "",
            layout.input_row,
        );
        children[idx] = .{
            .origin = .{ .row = layout.input_row -| panel_height, .col = 0 },
            .surface = try jobs_view.widget().draw(ctx.withConstraints(
                .{ .width = max_width, .height = panel_height },
                .{ .width = max_width, .height = panel_height },
            )),
            .z_index = 3,
        };
        idx += 1;
    }

    if (flags.at_visible) {
        // The popup renders state prepared by lifecycle processing
        // (`at_search.drainAtSearch` polls the async backend and promotes
        // failures into the notice on the tick). Draw builds the view from
        // prepared state only — no polling, no backend reads.
        const at_content = tui.buildAtSearchContent(app);
        var at_view: tui.AtSearchWidget = .{ .content = at_content };
        const panel_height = at_search.panelHeight(at_content.results.len, at_content.notice.len > 0);
        const panel_width = @min(@as(u16, 72), max_width);
        children[idx] = .{
            .origin = .{ .row = layout.input_row -| panel_height, .col = 0 },
            .surface = try at_view.widget().draw(ctx.withConstraints(
                .{ .width = panel_width, .height = panel_height },
                .{ .width = panel_width, .height = panel_height },
            )),
            .z_index = 1,
        };
        idx += 1;
    }

    if (flags.toast_visible) {
        // Top-right toast stack, above every other child (z_index 4).
        const toast_w: u16 = @min(max_width, 60);
        var toast_view: toast.Widget = .{ .bus = &toast.global };
        children[idx] = .{
            .origin = .{ .row = 0, .col = max_width -| toast_w },
            .surface = try toast_view.widget().draw(ctx.withConstraints(
                .{ .width = toast_w, .height = max_height },
                .{ .width = toast_w, .height = max_height },
            )),
            .z_index = 4,
        };
        idx += 1;
    }

    return children;
}

pub fn drawRoot(app: *App, root_widget: vxfw.Widget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const max_width = ctx.max.width orelse ctx.min.width;
    const max_height = ctx.max.height orelse ctx.min.height;
    if (max_width < root_layout.min_usable_width or max_height < root_layout.min_usable_height) {
        app.split_rect_count = 0;
        app.drawn_overlay_width = 0;
        app.drawn_overlay_height = 0;
        var surface = try vxfw.Surface.init(ctx.arena, root_widget, .{ .width = max_width, .height = max_height });
        @memset(surface.buffer, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{} });
        const warning = "Terminal too small";
        const write_len = @min(max_width, @as(u16, @intCast(warning.len)));
        var col: u16 = 0;
        while (col < write_len) : (col += 1) {
            surface.writeCell(col, 0, .{
                .char = .{ .grapheme = warning[col .. col + 1], .width = 1 },
                .style = tui_style.activePalette().notice,
            });
        }
        try materializeBlankCells(ctx.arena, &surface);
        return surface;
    }

    const modal_layer = activeModalLayer(app);
    const toast_visible = toast.global.hasToasts();
    var overlay_view: overlay.OverlayWidget = .{ .app = app };

    if (app.mode == .diff_viewer) {
        app.split_rect_count = 0;
        app.nav.lanes_chip_rect = null;
        app.nav.new_output_rect = null;
        const diff_layout: root_layout.RootLayout = .{
            .input_height = 0,
            .loading_height = 0,
            .transcript_height = max_height,
            .loading_row = max_height,
            .input_row = max_height,
        };
        const main_surface = try diff_viewer_overlay.drawDiffViewer(app, root_widget, ctx);
        const children = try buildOverlayChildren(app, ctx, diff_layout, max_width, max_height, main_surface, &overlay_view, .{
            .overlay_visible = false,
            .permission_visible = modal_layer == .permission,
            .background_visible = modal_layer == .background,
            .at_visible = modal_layer == .at_search,
            .toast_visible = toast_visible,
        });
        var surface: vxfw.Surface = .{
            .size = .{ .width = max_width, .height = max_height },
            .widget = root_widget,
            .buffer = &.{},
            .children = children,
        };
        try materializeBlankCells(ctx.arena, &surface);
        return surface;
    }

    const loading_visible = app.thread.turn_view.awaitingOutput();
    const split = app.split_mode != .tab and app.threads.len() > 1;

    const input_combined = try std.mem.concat(ctx.arena, u8, &.{ app.inputs.input.buf.firstHalf(), app.inputs.input.buf.secondHalf() });
    const layout = root_layout.rootLayout(max_height, input_mod.wrappedTextRows(ctx, input_combined, max_width -| 4), loading_visible or split, app.thread.queued.items.len > 0);

    var split_cols: []const root_layout.ColumnRect = &.{};
    var split_rects: [4]root_layout.ColumnRect = undefined;
    if (split) {
        split_cols = root_layout.computeSplitLayout(max_width, layout.transcript_height, app.split_mode, app.threads.len(), app.focused_worker_index, app.cached_config.tui.min_split_width, &split_rects);
        app.split_rects = split_rects;
    }
    app.split_rect_count = split_cols.len;
    app.input_surface_row = layout.input_row;
    app.nav.lanes_chip_rect = null;
    app.nav.new_output_rect = null;

    const now_ms = std.Io.Clock.now(.awake, app.getIo()).toMilliseconds();
    var transcript_view = tx_widget.TranscriptWidget.fromProps(buildTranscriptProps(app, app.thread, now_ms));
    const stalled = app.thread.last_activity_ms > 0 and (now_ms - app.thread.last_activity_ms >= 15_000);
    var progress_buf: [128]u8 = undefined;
    const progress_label: []const u8 = try ctx.arena.dupe(u8, turn_view_mod.TurnView.formatProgressLabel(
        &progress_buf,
        app.thread.turn_view.activity,
        now_ms - app.thread.turn_view.started_ms,
        stalled,
    ));
    var loading_view: loading.LoadingWidget = .{
        .awaiting_output = app.thread.turn_view.awaitingOutput(),
        .label = progress_label,
        .loading_frame = app.metrics.loading_frame,
    };
    var input_view: input_mod.InputWidget = .{ .props = buildInputProps(app, ctx.arena, input_combined) };

    var top_bufs: TopWidgetBuffers = .{};
    const top_widget = buildTopWidget(app, split, split_cols, max_width, layout.transcript_height, now_ms, &transcript_view, &top_bufs);

    var main_flex_buf: [3]vxfw.FlexItem = undefined;
    var main_flex_count: usize = 0;

    main_flex_buf[main_flex_count] = .{ .widget = top_widget, .flex = 1 };
    main_flex_count += 1;

    const include_loading = split or loading_visible;
    var loading_box: vxfw.SizedBox = undefined;
    if (include_loading) {
        loading_box = .{
            .child = loading_view.widget(),
            .size = .{ .width = max_width, .height = layout.loading_height },
        };
        main_flex_buf[main_flex_count] = .{ .widget = loading_box.widget(), .flex = 0 };
        main_flex_count += 1;
    }

    var input_box: vxfw.SizedBox = .{
        .child = input_view.widget(),
        .size = .{ .width = max_width, .height = layout.input_height },
    };
    main_flex_buf[main_flex_count] = .{ .widget = input_box.widget(), .flex = 0 };
    main_flex_count += 1;

    var main_col: vxfw.FlexColumn = .{ .children = main_flex_buf[0..main_flex_count] };
    const main_surface = try main_col.widget().draw(ctx.withConstraints(
        .{ .width = max_width, .height = max_height },
        .{ .width = max_width, .height = max_height },
    ));

    const children = try buildOverlayChildren(app, ctx, layout, max_width, max_height, main_surface, &overlay_view, .{
        .overlay_visible = modal_layer == .overlay,
        .permission_visible = modal_layer == .permission,
        .background_visible = modal_layer == .background,
        .at_visible = modal_layer == .at_search,
        .toast_visible = toast_visible,
    });

    var surface: vxfw.Surface = .{
        .size = .{ .width = max_width, .height = max_height },
        .widget = root_widget,
        .buffer = &.{},
        .children = children,
    };
    try materializeBlankCells(ctx.arena, &surface);
    return surface;
}

test "materializeBlankCells makes nested blank cells drawable" {
    var child_buffer = [_]vaxis.Cell{.{
        .char = .{ .grapheme = "" },
        .default = true,
    }};
    const child: vxfw.Surface = .{
        .size = .{ .width = 1, .height = 1 },
        .widget = undefined,
        .buffer = &child_buffer,
        .children = &.{},
    };
    var child_subsurface = [_]vxfw.SubSurface{.{
        .origin = .{ .row = 0, .col = 0 },
        .surface = child,
        .z_index = 0,
    }};
    var root_buffer = [_]vaxis.Cell{.{
        .char = .{ .grapheme = "stale" },
        .default = true,
    }};
    var root: vxfw.Surface = .{
        .size = .{ .width = 1, .height = 1 },
        .widget = undefined,
        .buffer = &root_buffer,
        .children = &child_subsurface,
    };

    try materializeBlankCells(std.testing.allocator, &root);

    try std.testing.expect(!root.buffer[0].default);
    try std.testing.expectEqualStrings(" ", root.buffer[0].char.grapheme);
    try std.testing.expect(!root.children[0].surface.buffer[0].default);
    try std.testing.expectEqualStrings(" ", root.children[0].surface.buffer[0].char.grapheme);
}
