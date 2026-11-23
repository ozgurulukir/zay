//! The permission overlay widget and its inner command/actions layout.
//!
//! Renders tool execution approval prompts with modern vxfw Border styling
//! and decision buttons (Approve / Reject).

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui_style = @import("../style.zig");
const panel = @import("panel.zig");
const app_state = @import("../app_state.zig");
const agent_worker = @import("../agent_worker.zig");

pub const ApprovalSnapshot = agent_worker.ApprovalSnapshot;
pub const ApprovalDecision = agent_worker.ApprovalDecision;
pub const ApprovalChoice = agent_worker.ApprovalChoice;

/// Outer border widget. Shows the current approval snapshot (the
/// command the agent is about to run + Approve/Reject actions).
pub const PermissionWidget = struct {
    snapshot: ?ApprovalSnapshot = null,
    scroll: u32 = 0,
    label: []const u8 = "Tool Approval Request",
    palette: *const tui_style.Palette = &tui_style.default_palette,

    pub fn widget(self: *PermissionWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *PermissionWidget = @ptrCast(@alignCast(ptr));
        const p = self.palette;
        const snapshot = self.snapshot orelse {
            return vxfw.Surface.init(ctx.arena, self.widget(), .{
                .width = ctx.max.width orelse 0,
                .height = ctx.max.height orelse 0,
            });
        };

        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        if (width == 0 or height == 0) return surface;

        const inner = try ctx.arena.create(PermissionInner);
        inner.* = .{
            .snapshot = snapshot,
            .scroll = self.scroll,
            .palette = p,
        };
        var border: vxfw.Border = .{
            .child = inner.widget(),
            .labels = &.{.{ .text = self.label, .alignment = .top_left }},
            .style = p.border_label,
        };
        return border.widget().draw(ctx);
    }
};

/// Inner command + actions layout for the permission overlay.
const PermissionInner = struct {
    snapshot: ApprovalSnapshot,
    scroll: u32,
    palette: *const tui_style.Palette = &tui_style.default_palette,

    pub fn widget(self: *PermissionInner) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *PermissionInner = @ptrCast(@alignCast(ptr));
        const p = self.palette;
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        if (width == 0 or height == 0) return surface;
        panel.fillBackground(&surface, p);

        const tool = self.snapshot.tool_name orelse "bash";
        const lane = self.snapshot.lane_id orelse "1";
        const cwd = self.snapshot.cwd orelse "";
        const header = if (cwd.len > 0)
            std.fmt.allocPrint(ctx.arena, "Review {s} (lane {s}) in {s}:", .{ tool, lane, cwd }) catch "Review before running:"
        else
            std.fmt.allocPrint(ctx.arena, "Review {s} (lane {s}):", .{ tool, lane }) catch "Review before running:";
        panel.lineStyledAt(&surface, 0, header, ctx, 1, p.panel_header) catch {};

        const body_rows = height -| 3;
        drawPermissionCommand(&surface, ctx, self.snapshot.command, self.scroll, body_rows, p);
        // TUX03: tell the user when a long command is scrollable and where
        // they are in it (Up/Down scroll, see handlePermissionKey).
        drawScrollHint(&surface, ctx, self.snapshot.command, self.scroll, body_rows, height, p);
        drawPermissionActions(&surface, ctx, height -| 1, self.snapshot.selected, p);
        return surface;
    }
};

fn drawPermissionCommand(surface: *vxfw.Surface, ctx: vxfw.DrawContext, command: []const u8, scroll: u32, rows: u16, p: *const tui_style.Palette) void {
    if (rows == 0) return;
    var line_index: u32 = 0;
    var drawn: u16 = 0;
    var iterator = std.mem.splitScalar(u8, command, '\n');
    while (iterator.next()) |line| {
        if (line_index < scroll) {
            line_index += 1;
            continue;
        }
        if (drawn >= rows) return;
        panel.lineStyledAt(surface, 1 + drawn, line, ctx, 1, p.markdown_code) catch {};
        drawn += 1;
        line_index += 1;
    }
}

fn drawScrollHint(surface: *vxfw.Surface, ctx: vxfw.DrawContext, command: []const u8, scroll: u32, body_rows: u16, height: u16, p: *const tui_style.Palette) void {
    if (body_rows == 0) return;
    const hint_row = height -| 2;
    if (hint_row == 0 or hint_row >= surface.size.height) return;
    const hint = scrollHintText(ctx.arena, command, scroll, body_rows) orelse return;
    panel.lineStyledAt(surface, hint_row, hint, ctx, 1, p.info) catch {};
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

fn drawPermissionActions(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, selected: ApprovalChoice, p: *const tui_style.Palette) void {
    if (row >= surface.size.height) return;
    const w = surface.size.width;

    const items = [_]struct {
        choice: ApprovalChoice,
        text: []const u8,
        style: vaxis.Style,
    }{
        .{ .choice = .approve, .text = "Approve [Y]", .style = p.permission_approve },
        .{ .choice = .approve_session, .text = "Session [S]", .style = p.info },
        .{ .choice = .reject, .text = "Reject [N]", .style = p.error_style },
        .{ .choice = .reject_with_reason, .text = "Reason [R]", .style = p.thinking_body },
    };

    var col: u16 = 1;
    for (items) |item| {
        if (col >= w) break;
        const is_sel = selected == item.choice;
        const style: vaxis.Style = if (is_sel) item.style else p.thinking_body;
        const label = actionLabel(ctx, item.text, is_sel);
        const label_width: u16 = @intCast(ctx.stringWidth(label));
        panel.lineStyledAt(surface, row, label, ctx, col, style) catch {};
        col += label_width + 2;
    }
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

test "PermissionWidget renders cleanly with null and non-null snapshot" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 10 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    // 1. Null snapshot renders empty surface
    var empty_view: PermissionWidget = .{};
    const empty_surface = try empty_view.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 80), empty_surface.size.width);
    try std.testing.expectEqual(@as(u16, 10), empty_surface.size.height);

    // 2. Active snapshot renders border with command and actions
    var cmd_buf = [_]u8{ 'g', 'i', 't', ' ', 's', 't', 'a', 't', 'u', 's' };
    var active_view: PermissionWidget = .{
        .snapshot = .{
            .command = &cmd_buf,
            .selected = .approve,
        },
        .scroll = 0,
        .label = "Lane 1 requests approval",
    };
    const active_surface = try active_view.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 80), active_surface.size.width);
    try std.testing.expectEqual(@as(u16, 10), active_surface.size.height);
}
