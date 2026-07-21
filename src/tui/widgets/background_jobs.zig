//! The Ctrl+O background-jobs modal widget and its inner row layout.
//!
//! Pulled out of `tui.zig` (R5.1a of `_pm/Projects/tui-split`) — the
//! widget was a self-contained 75-line struct that only read
//! `App.background`, `App.background_modal_state`, and the panel/style
//! helpers, so it earns its own file under `widgets/`.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../../tui.zig");
const tui_style = @import("../style.zig");
const panel = @import("panel.zig");

const App = tui.App;
const StylePalette = tui_style.Palette;

/// Outer border widget. Shows a snapshot of running background jobs.
pub const BackgroundJobsWidget = struct {
    app: *App,

    pub fn widget(self: *BackgroundJobsWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *BackgroundJobsWidget = @ptrCast(@alignCast(ptr));
        const app = self.app;
        const empty = vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = ctx.max.width orelse 0,
            .height = ctx.max.height orelse 0,
        });
        const manager = app.background orelse return empty;
        const views = manager.snapshot(ctx.arena) catch return empty;
        const inner = try ctx.arena.create(BackgroundJobsInner);
        inner.* = .{
            .views = views,
            .selection = if (views.len == 0) 0 else @min(app.background_modal_state.selection, views.len - 1),
            .cancel_focus = app.background_modal_state.cancel_focus,
        };
        var border: vxfw.Border = .{
            .child = inner.widget(),
            .labels = &.{.{ .text = "Background jobs", .alignment = .top_left }},
            .style = StylePalette.border_label,
        };
        return border.widget().draw(ctx);
    }
};

/// Inner row layout for the background-jobs list. Receives a frozen
/// snapshot of `JobView`s and the current selection/cancel-focus so the
/// outer widget doesn't have to re-fetch state each draw.
const BackgroundJobsInner = struct {
    views: []tui.background_mod.BackgroundManager.JobView,
    selection: usize,
    cancel_focus: bool,

    pub fn widget(self: *BackgroundJobsInner) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *BackgroundJobsInner = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        if (width == 0 or height == 0) return surface;

        if (self.views.len == 0) {
            panel.lineStyledAt(&surface, 0, "No background jobs running.", ctx, 1, StylePalette.thinking_body) catch {};
            return surface;
        }

        panel.lineStyledAt(&surface, 0, "↑↓ select · → cancel · Esc close", ctx, 1, StylePalette.panel_header) catch {};
        const body_rows = height -| 1;
        var row: u16 = 0;
        while (row < self.views.len and row < body_rows) : (row += 1) {
            const view = self.views[row];
            const selected = row == self.selection;
            var elapsed_buf: [32]u8 = undefined;
            const line = std.fmt.allocPrint(ctx.arena, "{s}  {s}  {s}", .{
                view.label,
                formatJobElapsed(&elapsed_buf, view.elapsed_seconds),
                view.command,
            }) catch view.command;
            panel.lineAt(&surface, 1 + row, line, ctx, selected, 1) catch {};
            // The cancel button sits at the right; highlighted only when the
            // selected row has cancel focus (right-arrow).
            const focused = selected and self.cancel_focus;
            const button = if (focused) "[CANCEL]" else "CANCEL";
            const style = if (focused) StylePalette.tool_failed else StylePalette.thinking_body;
            panel.rightStyled(&surface, 1 + row, button, ctx, style) catch {};
        }
        return surface;
    }
};

/// Compact elapsed render for a modal row, e.g. `45s`, `12m03s`, `2h05m`.
fn formatJobElapsed(buf: []u8, total_seconds: u64) []const u8 {
    if (total_seconds < 60) return std.fmt.bufPrint(buf, "{d}s", .{total_seconds}) catch "?";
    const minutes = total_seconds / 60;
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ minutes, total_seconds % 60 }) catch "?";
    return std.fmt.bufPrint(buf, "{d}h{d:0>2}m", .{ minutes / 60, minutes % 60 }) catch "?";
}
