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
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const root_layout = @import("layout.zig");
const lane_column = @import("lane_column.zig");
const diff_viewer_overlay = @import("diff_viewer_overlay.zig");
const tx_widget = @import("widgets/transcript.zig");
const loading = @import("widgets/loading.zig");
const input_mod = @import("widgets/input.zig");
const permission = @import("widgets/permission.zig");
const background_jobs = @import("widgets/background_jobs.zig");
const at_search = @import("widgets/at_search.zig");
const overlay = @import("widgets/overlay.zig");
const toast = @import("toast.zig");
const at_search_mod = @import("at_search.zig");
const search_mod = @import("../search.zig");

const App = tui.App;

const log = std.log.scoped(.root_layout);

pub fn drawRoot(app: *App, root_widget: vxfw.Widget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    // The diff viewer replaces the whole screen (transcript + input + overlay),
    // so it short-circuits the normal layout entirely. Zero the split-rect
    // stash here too — the normal path that clears it is skipped, so otherwise
    // `routeMouse` would keep hit-testing stale split geometry while the diff
    // viewer is up.
    if (app.mode == .diff_viewer) {
        app.split_rect_count = 0;
        return diff_viewer_overlay.drawDiffViewer(app, root_widget, ctx);
    }
    const max_width = ctx.max.width orelse ctx.min.width;
    const max_height = ctx.max.height orelse ctx.min.height;
    const loading_visible = app.thread.turn_view.awaitingOutput();
    const split = app.split_mode != .tab and app.threads.len() > 1;
    // In split view always reserve the loading row so each column keeps a
    // fixed height across turns — the spinner appearing must not reflow.
    const layout = root_layout.rootLayout(max_height, false, try app.inputTextRows(ctx, max_width -| 4), loading_visible or split, app.thread.queued.items.len > 0);
    // Compute the split geometry once and stash it for mouse click-to-focus
    // routing (event_router.routeMouse), so the render path and the mouse
    // handler share one source of truth. `split_rect_count` is set
    // unconditionally so leaving split mode (or the diff viewer early-return)
    // leaves it 0 and the mouse handler stops hit-testing stale geometry.
    var split_cols: []const root_layout.ColumnRect = &.{};
    var split_rects: [4]root_layout.ColumnRect = undefined;
    if (split) {
        split_cols = root_layout.computeSplitLayout(max_width, layout.transcript_height, app.split_mode, app.threads.len(), app.focused_worker_index, app.cached_config.tui.min_split_width, &split_rects);
        app.split_rects = split_rects;
    }
    app.split_rect_count = split_cols.len;
    app.input_surface_row = layout.input_row;
    app.nav.lanes_chip_rect = null;

    var transcript_view: tx_widget.TranscriptWidget = .{ .app = app, .thread = app.thread };
    var loading_view: loading.LoadingWidget = .{ .app = app };
    var input_view: input_mod.InputWidget = .{ .app = app };
    var overlay_view: overlay.OverlayWidget = .{ .app = app };

    const transcript_ctx = ctx.withConstraints(
        .{ .width = max_width, .height = layout.transcript_height },
        .{ .width = max_width, .height = layout.transcript_height },
    );
    const input_ctx = ctx.withConstraints(
        .{ .width = max_width, .height = layout.input_height },
        .{ .width = max_width, .height = layout.input_height },
    );

    const overlay_visible = app.mode != .normal;
    const permission_visible = app.permissionPending() and !overlay_visible;
    const background_visible = app.background_modal_state.modal and !overlay_visible and !permission_visible;
    const at_visible = (app.at_search != .closed) and !overlay_visible and !permission_visible and !background_visible;
    const toast_visible = toast.global.hasToasts();

    var child_count: usize = (if (split) split_cols.len else 1) + 1;
    if (loading_visible) child_count += 1;
    if (overlay_visible) child_count += 1;
    if (permission_visible) child_count += 1;
    if (background_visible) child_count += 1;
    if (at_visible) child_count += 1;
    if (toast_visible) child_count += 1;
    const children = try ctx.arena.alloc(vxfw.SubSurface, child_count);
    var idx: usize = 0;
    if (split) {
        // Render each split column from the shared geometry. `.dual` shows the
        // driver (lane 0) on the left and the focused worker on the right;
        // `.grid` tiles all lanes. The active flag derives from the focus state,
        // not just `app.thread`: in `.dual` the left column is active (the
        // driver is always the input-routing lane) and the right column is
        // active when it projects the focused worker.
        for (split_cols) |col| {
            const lane = app.threads.slice()[col.lane_index];
            // Clamp the focused worker so a momentarily out-of-range index
            // (e.g. right after a lane deletion) still highlights the clamped
            // right-pane column instead of leaving it dim/unhighlighted.
            // `split` guarantees `threads.len() > 1`, so `lane_max >= 1`.
            const worker_focus = @max(@min(app.focused_worker_index, app.threads.len() - 1), 1);
            // `active` marks the ●/dim state; `focused` selects the single
            // column whose border is highlighted. In `.dual` the driver (left)
            // and focused worker (right) are both active, but only the right
            // pane's worker is "focused"; in `.grid` the active lane is focused.
            const active = if (app.split_mode == .dual)
                (col.lane_index == 0) or (col.lane_index == worker_focus)
            else
                (col.lane_index == @as(usize, app.activeIndex()));
            const focused = if (app.split_mode == .dual)
                (col.lane_index == worker_focus)
            else
                (col.lane_index == @as(usize, app.activeIndex()));
            children[idx] = .{
                .origin = .{ .row = col.row, .col = col.col },
                .surface = try lane_column.drawLaneColumn(app, ctx, lane, col.width, col.height, active, focused),
                .z_index = 0,
            };
            idx += 1;
        }
    } else {
        children[idx] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try transcript_view.widget().draw(transcript_ctx),
            .z_index = 0,
        };
        idx += 1;
    }
    if (loading_visible) {
        const loading_ctx = ctx.withConstraints(
            .{ .width = max_width, .height = layout.loading_height },
            .{ .width = max_width, .height = layout.loading_height },
        );
        children[idx] = .{
            .origin = .{ .row = layout.loading_row, .col = 0 },
            .surface = try loading_view.widget().draw(loading_ctx),
            .z_index = 0,
        };
        idx += 1;
    }
    children[idx] = .{
        .origin = .{ .row = layout.input_row, .col = 0 },
        .surface = try input_view.widget().draw(input_ctx),
        .z_index = 0,
    };
    idx += 1;
    if (overlay_visible) {
        var centered_overlay: vxfw.Center = .{ .child = overlay_view.widget() };
        children[idx] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try centered_overlay.widget().draw(ctx.withConstraints(
                .{ .width = max_width, .height = layout.transcript_height },
                .{ .width = max_width, .height = layout.transcript_height },
            )),
            .z_index = 2,
        };
        idx += 1;
    }
    if (permission_visible) {
        var permission_view: permission.PermissionWidget = .{ .app = app };
        const panel_height: u16 = @min(@as(u16, 12), @max(@as(u16, 5), layout.input_row));
        children[idx] = .{
            .origin = .{ .row = layout.input_row -| panel_height, .col = 0 },
            .surface = try permission_view.widget().draw(ctx.withConstraints(
                .{ .width = max_width, .height = panel_height },
                .{ .width = max_width, .height = panel_height },
            )),
            .z_index = 3,
        };
        idx += 1;
    }
    if (background_visible) {
        var jobs_view: background_jobs.BackgroundJobsWidget = .{ .app = app };
        const rows: u16 = @intCast(@min(@as(usize, 8), app.runningBackgroundCount()));
        const panel_height: u16 = @min(layout.input_row, rows + 4);
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
    if (at_visible) {
        // Debounce: only start/poll searches once the deadline has expired.
        // updateAtSearch resets the deadline on every keystroke, so rapid
        // typing coalesces into a single query.
        const deadline_expired = app.at_search.debounceExpired(app.io);
        const pending_results = switch (app.at_search) {
            .open => |o| o.searching,
            else => false,
        };

        if (deadline_expired or pending_results) {
            // Poll async search results before drawing, so the popup updates
            // as soon as a background fuzzy search completes.
            at_search_mod.pollAtSearch(app) catch |err| {
                // Surface the failure in the popup footer so the user isn't
                // staring at stale/empty results with no hint.
                log.warn("at-search poll failed: {s}", .{@errorName(err)});

                at_search_mod.setSearchNotice(app, @errorName(err));
            };
            // Display any backend failure message when the index is in the failed
            // state but the popup is still open.
            if (app.at_search == .open and app.at_search.open.kind == .file) {
                if (search_mod.backend.lastFailure(app.gpa)) |msg| {
                    defer app.gpa.free(msg);
                    if (app.at_search.open.notice == null or app.at_search.open.notice.?.len == 0) {
                        at_search_mod.setSearchNotice(app, msg);
                    }
                }
            }
        }
        // Kick the indexer forward when still scanning.
        if (app.at_search == .indexing) {
            at_search_mod.updateAtSearch(app) catch {};
        }
        var at_view: tui.AtSearchWidget = .{ .app = app };
        const panel_height = at_search.panelHeight(app.at_search.results().len);
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
    if (toast_visible) {
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

    return .{
        .size = .{ .width = max_width, .height = max_height },
        .widget = root_widget,
        .buffer = &.{},
        .children = children,
    };
}
