//! Full-screen diff viewer overlay.
//!
//! Pulled out of `tui.zig` (R5.2b of `_pm/Projects/tui-split`) — `drawDiffViewer`
//! replaces the normal transcript+input layout when the user opens `/diff`. It
//! tiles the diff body (or a loading placeholder), an optional comment editor
//! footer or two hint lines, and an optional centered file-search popup.
//!
//! The function takes the `vxfw.Widget` handle of the outer `RootWidget` so the
//! surface it returns carries the right widget tag — the same role `self.widget()`
//! played inside the original method.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const tui_style = @import("style.zig");
const panel = @import("widgets/panel.zig");
const diff = @import("widgets/diff.zig");
const symbols = @import("../symbols.zig");
const tui_status = @import("status.zig");

const App = tui.App;
const StylePalette = tui_style.Palette;

pub const diff_hint_line1: []const u8 = "↑↓ Move" ++ symbols.separator_dot_padded ++ "⇧↑↓ Select lines" ++ symbols.separator_dot_padded ++ "^↑↓ Jump file" ++ symbols.separator_dot_padded ++ "^P Find file";
pub const diff_hint_line2: []const u8 = "^W Comment" ++ symbols.separator_dot_padded ++ "^E Edit" ++ symbols.separator_dot_padded ++ "^D Delete" ++ symbols.separator_dot_padded ++ "^S Save & send" ++ symbols.separator_dot_padded ++ "Esc Exit";

pub fn drawDiffViewer(app: *App, root_widget: vxfw.Widget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const w = ctx.max.width orelse ctx.min.width;
    const h = ctx.max.height orelse ctx.min.height;
    var surface = try vxfw.Surface.init(ctx.arena, root_widget, .{ .width = w, .height = h });
    if (w == 0 or h == 0) return surface;

    const editing = app.diff.sub == .commenting;
    const footer_h: u16 = if (editing) @min(h -| 1, @as(u16, 3)) else @min(h -| 1, @as(u16, 2));
    const body_top: u16 = 0;
    const body_h: u16 = h -| body_top -| footer_h;
    app.diff.viewport_rows = body_h;

    var subs: [3]vxfw.SubSurface = undefined;
    var n: usize = 0;

    if (app.metrics.diff_loading()) {
        // Cold start: navigated in, diff still fetching in the background.
        panel.lineStyledAt(&surface, body_top + body_h / 2, "Loading diff…", ctx, 2, StylePalette.model_status) catch {};
    } else {
        var body: diff.DiffBodyWidget = .{ .app = app };
        subs[n] = .{
            .origin = .{ .row = body_top, .col = 0 },
            .z_index = 0,
            .surface = try body.widget().draw(ctx.withConstraints(
                .{ .width = w, .height = body_h },
                .{ .width = w, .height = body_h },
            )),
        };
        n += 1;
    }

    if (editing) {
        var editor: diff.DiffCommentEditor = .{ .app = app };
        subs[n] = .{
            .origin = .{ .row = h -| footer_h, .col = 0 },
            .z_index = 1,
            .surface = try editor.widget().draw(ctx.withConstraints(
                .{ .width = w, .height = footer_h },
                .{ .width = w, .height = footer_h },
            )),
        };
        n += 1;
    } else {
        panel.lineStyledAt(&surface, h -| 2, diff_hint_line1, ctx, 1, StylePalette.thinking_body) catch {};
        panel.lineStyledAt(&surface, h -| 1, diff_hint_line2, ctx, 1, StylePalette.thinking_body) catch {};
        const status_text = if (tui_status.modelStatus(app.liveRuntime(), app.cached_config)) |status|
            tui_status.formatModelStatus(ctx.arena, status) catch "no model"
        else
            "no model";
        if (status_text.len > 0 or app.metrics.git_label.len > 0) {
            const label = std.fmt.allocPrint(ctx.arena, " {s} · {s} ", .{ status_text, app.metrics.git_label }) catch "";
            _ = panel.writeBorderTextEndingAt(&surface, ctx, h -| 1, w -| 1, label, StylePalette.model_status);
        }
    }

    if (app.diff.sub == .file_search) {
        const pw: u16 = @min(@as(u16, 72), w);
        // Border (2) + search row (1) + separator (1) + up to 10 result rows.
        const result_rows: u16 = @intCast(@max(@as(usize, 1), @min(app.diff.search_matches.items.len, 10)));
        const ph: u16 = @min(h, result_rows + 4);
        // Center the search popup on screen.
        var search: diff.DiffSearchWidget = .{ .app = app };
        subs[n] = .{
            .origin = .{ .row = (h -| ph) / 2, .col = (w -| pw) / 2 },
            .z_index = 2,
            .surface = try search.widget().draw(ctx.withConstraints(
                .{ .width = pw, .height = ph },
                .{ .width = pw, .height = ph },
            )),
        };
        n += 1;
    }

    surface.children = try ctx.arena.dupe(vxfw.SubSurface, subs[0..n]);
    return surface;
}
