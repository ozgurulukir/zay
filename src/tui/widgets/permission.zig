//! The permission overlay widget and its inner command/actions layout.
//!
//! Renders tool execution approval prompts with modern vxfw Border styling
//! and decision buttons (Approve / Reject).

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../../tui.zig");
const tui_style = @import("../style.zig");
const panel = @import("panel.zig");
const permission_mod = @import("../permission.zig");
const lanes_util = @import("../lanes.zig");

const App = tui.App;

/// Outer border widget. Shows the current approval snapshot (the
/// command the agent is about to run + Approve/Reject actions).
pub const PermissionWidget = struct {
    app: *App,

    pub fn widget(self: *PermissionWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *PermissionWidget = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        const app = self.app;
        // The gate may belong to a background lane — a worker blocked on a
        // destructive-bash approval is invisible without this scan.
        const lane = permission_mod.approvalLane(app) orelse {
            return vxfw.Surface.init(ctx.arena, self.widget(), .{
                .width = ctx.max.width orelse 0,
                .height = ctx.max.height orelse 0,
            });
        };
        const worker = if (lane.worker_context) |*context| context else {
            return vxfw.Surface.init(ctx.arena, self.widget(), .{
                .width = ctx.max.width orelse 0,
                .height = ctx.max.height orelse 0,
            });
        };
        const snapshot = try worker.approval.snapshot(worker.io, ctx.arena, app.thread.permission_selection) orelse {
            return vxfw.Surface.init(ctx.arena, self.widget(), .{
                .width = ctx.max.width orelse 0,
                .height = ctx.max.height orelse 0,
            });
        };

        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        if (width == 0 or height == 0) return surface;

        // When the gate's owner is not the lane on screen, name it so the
        // user knows which pane is asking.
        const label: []const u8 = if (lane != app.thread)
            std.fmt.allocPrint(ctx.arena, "Lane {s} requests approval", .{laneLabel(lane) orelse "?"}) catch "Tool Approval Request"
        else
            "Tool Approval Request";

        const inner = try ctx.arena.create(PermissionInner);
        inner.* = .{ .snapshot = snapshot, .scroll = app.thread.permission_scroll };
        var border: vxfw.Border = .{
            .child = inner.widget(),
            .labels = &.{.{ .text = label, .alignment = .top_left }},
            .style = p.border_label,
        };
        return border.widget().draw(ctx);
    }

    /// The hex id of a working lane (its worktree's last path segment), or
    /// null for the primary lane.
    fn laneLabel(lane: *tui.Thread) ?[]const u8 {
        const working = lanes_util.workingLaneOf(lane) orelse return null;
        return lanes_util.lastPathSegment(working.path);
    }
};

/// Inner command + actions layout for the permission overlay.
const PermissionInner = struct {
    snapshot: tui.agent_worker.ApprovalSnapshot,
    scroll: u32,

    pub fn widget(self: *PermissionInner) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *PermissionInner = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        if (width == 0 or height == 0) return surface;

        panel.lineStyledAt(&surface, 0, "Review before running:", ctx, 1, p.panel_header) catch {};
        const body_rows = height -| 3;
        drawPermissionCommand(&surface, ctx, self.snapshot.command, self.scroll, body_rows);
        // TUX03: tell the user when a long command is scrollable and where
        // they are in it (Up/Down scroll, see handlePermissionKey).
        drawScrollHint(&surface, ctx, self.snapshot.command, self.scroll, body_rows, height);
        drawPermissionActions(&surface, ctx, height -| 1, self.snapshot.selected);
        return surface;
    }
};

fn drawPermissionCommand(surface: *vxfw.Surface, ctx: vxfw.DrawContext, command: []const u8, scroll: u32, rows: u16) void {
    if (rows == 0) return;
    const p = tui_style.activePalette();
    var line_index: u32 = 0;
    var drawn: u16 = 0;
    var iterator = std.mem.splitScalar(u8, command, '\n');
    while (iterator.next()) |line| {
        if (line_index < scroll) {
            line_index += 1;
            continue;
        }
        if (drawn >= rows) return;
        panel.lineStyledAt(surface, 1 + drawn, line, ctx, 1, p.thinking_body) catch {};
        drawn += 1;
        line_index += 1;
    }
}

fn drawScrollHint(surface: *vxfw.Surface, ctx: vxfw.DrawContext, command: []const u8, scroll: u32, body_rows: u16, height: u16) void {
    if (body_rows == 0) return;
    const hint_row = height -| 2;
    if (hint_row == 0 or hint_row >= surface.size.height) return;
    const p = tui_style.activePalette();
    const hint = scrollHintText(ctx.arena, command, scroll, body_rows) orelse return;
    panel.lineStyledAt(surface, hint_row, hint, ctx, 1, p.thinking_body) catch {};
}

/// Pure: build the scroll-affordance text, or null when the command fits the
/// body. Clamps over-scroll for display so the numbers stay sane.
fn scrollHintText(arena: std.mem.Allocator, command: []const u8, scroll: u32, body_rows: u16) ?[]const u8 {
    const total_lines: u32 = @intCast(std.mem.count(u8, command, "\n") + 1);
    if (total_lines <= body_rows) return null;
    const max_scroll = total_lines -| @as(u32, body_rows);
    const eff = @min(scroll, max_scroll);
    const first = eff + 1;
    const last = eff + @as(u32, body_rows);
    return std.fmt.allocPrint(arena, " {s} lines {d}-{d} of {d} {s} ", .{
        if (eff > 0) "↑" else " ",
        first,
        last,
        total_lines,
        if (last < total_lines) "↓" else " ",
    }) catch null;
}

fn drawPermissionActions(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, selected: tui.agent_worker.ApprovalDecision) void {
    if (row >= surface.size.height) return;
    const p = tui_style.activePalette();
    const approve_selected = selected == .approve;
    const reject_selected = selected == .reject;

    const approve_style: vaxis.Style = if (approve_selected) p.permission_approve else p.thinking_body;
    const reject_style: vaxis.Style = if (reject_selected) p.error_style else p.thinking_body;

    panel.lineStyledAt(surface, row, actionLabel(ctx, "Approve [Y]", approve_selected), ctx, 1, approve_style) catch {};
    panel.lineStyledAt(surface, row, actionLabel(ctx, "Reject [N]", reject_selected), ctx, 18, reject_style) catch {};
}

fn actionLabel(ctx: vxfw.DrawContext, text: []const u8, selected: bool) []const u8 {
    if (selected) return std.fmt.allocPrint(ctx.arena, "▶ [ {s} ]", .{text}) catch text;
    return std.fmt.allocPrint(ctx.arena, "    {s}  ", .{text}) catch text;
}

test "permission scroll hint reports the visible window of a long command" {
    const gpa = std.testing.allocator;
    const cmd = "a\nb\nc\nd\ne"; // 5 lines
    try std.testing.expect(scrollHintText(gpa, cmd, 0, 5) == null); // fits
    const top = (scrollHintText(gpa, cmd, 0, 2)).?;
    defer gpa.free(top);
    try std.testing.expect(std.mem.indexOf(u8, top, "of 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, top, "↓") != null);
}
