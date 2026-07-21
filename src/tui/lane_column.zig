//! Per-lane column widget: a bordered transcript pane, one per open lane.
//!
//! Pulled out of `tui.zig` (R5.2a of `_pm/Projects/tui-split`) — `drawLaneColumn`
//! is a 14-line wrapper that wraps the per-lane `TranscriptWidget` in a border
//! whose label shows the lane title prefixed with an active (●) / inactive (○)
//! marker. Used by `drawRoot` when tiling multiple lanes side-by-side.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const tx_widget = @import("widgets/transcript.zig");

const App = tui.App;
const Thread = tui.Thread;

pub fn drawLaneColumn(app: *App, ctx: vxfw.DrawContext, lane: *Thread, width: u16, height: u16, active: bool) std.mem.Allocator.Error!vxfw.Surface {
    var transcript_view: tx_widget.TranscriptWidget = .{ .app = app, .thread = lane };
    const title = if (lane.title) |t| t else "untitled";
    const label_text = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ if (active) "● " else "○ ", title });
    var border: vxfw.Border = .{
        .child = transcript_view.widget(),
        .labels = &.{.{ .text = label_text, .alignment = .top_left }},
        .style = if (active) .{} else .{ .dim = true },
    };
    return border.widget().draw(ctx.withConstraints(
        .{ .width = width, .height = height },
        .{ .width = width, .height = height },
    ));
}
