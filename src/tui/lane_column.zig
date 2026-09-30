//! Per-lane column widget: a bordered transcript pane, one per open lane.
//!
//! Pulled out of `tui.zig` (R5.2a of `_pm/Projects/tui-split`) — wraps the
//! per-lane `TranscriptWidget` in a border whose label shows the lane title
//! prefixed with an active (●) / inactive (○) marker. Used by `drawRoot`
//! when tiling multiple lanes side-by-side.
//!
//! Pure presentation per INV-WIDGET-1: `LaneColumnWidget` takes precomputed
//! `LaneColumnProps` built by `root_layout.buildLaneColumnProps` — no `*App`
//! dependency, no service access.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const tx_widget = @import("widgets/transcript.zig");

const Thread = tui.Thread;

/// Everything a lane column renders, computed once per frame by
/// `root_layout.buildLaneColumnProps` so the widget never reaches into
/// application state.
pub const LaneColumnProps = struct {
    lane: *Thread,
    width: u16,
    height: u16,
    /// ● (active) vs ○ (inactive) border marker.
    active: bool,
    gpa: std.mem.Allocator,
    has_model_configured: bool,
    loading_frame: u8,
    blackhole_frame: u16,
    blackhole_visible: *bool,
    splash_suppressed: bool,
    title: []const u8,
    state_glyph: []const u8,
    ws_marker: []const u8,
    border_style: vaxis.Style,
};

/// The border label: active marker + turn-state glyph + title + workspace
/// marker, e.g. `● ▶ lane-2 ⇄`.
pub fn laneLabel(arena: std.mem.Allocator, active: bool, state_glyph: []const u8, title: []const u8, ws_marker: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "{s}{s} {s}{s}", .{
        if (active) "● " else "○ ",
        state_glyph,
        title,
        ws_marker,
    });
}

pub fn drawLaneColumn(ctx: vxfw.DrawContext, props: *const LaneColumnProps) std.mem.Allocator.Error!vxfw.Surface {
    var transcript_view: tx_widget.TranscriptWidget = .{
        .thread = props.lane,
        .gpa = props.gpa,
        .has_model_configured = props.has_model_configured,
        .loading_frame = props.loading_frame,
        .blackhole_frame = props.blackhole_frame,
        .blackhole_visible = props.blackhole_visible,
        .splash_suppressed = props.splash_suppressed,
    };
    const label_text = try laneLabel(ctx.arena, props.active, props.state_glyph, props.title, props.ws_marker);
    var border: vxfw.Border = .{
        .child = transcript_view.widget(),
        .labels = &.{.{ .text = label_text, .alignment = .top_left }},
        .style = props.border_style,
    };
    return border.widget().draw(ctx.withConstraints(
        .{ .width = props.width, .height = props.height },
        .{ .width = props.width, .height = props.height },
    ));
}

pub const LaneColumnWidget = struct {
    props: LaneColumnProps,

    pub fn widget(self: *LaneColumnWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = draw,
        };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *LaneColumnWidget = @ptrCast(@alignCast(ptr));
        return drawLaneColumn(ctx, &self.props);
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────

test "laneLabel preserves active/inactive markers, glyph, title, and workspace marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const active = try laneLabel(a, true, "▶", "lane-2", " ⇄");
    try std.testing.expectEqualStrings("● ▶ lane-2 ⇄", active);

    const idle = try laneLabel(a, false, "·", "untitled", "");
    try std.testing.expectEqualStrings("○ · untitled", idle);

    // The stop glyph and an empty title still render a sane label.
    const stopping = try laneLabel(a, true, "■", "", "");
    try std.testing.expectEqualStrings("● ■ ", stopping);
}
