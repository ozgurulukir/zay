//! The permission overlay widget and its inner command/actions layout.
//!
//! Pulled out of `tui.zig` (R5.1a of `_pm/Projects/tui-split`) — the
//! widget was a self-contained 95-line struct that read the active
//! thread's approval snapshot, so it earns its own file under `widgets/`.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../../tui.zig");
const tui_style = @import("../style.zig");
const panel = @import("panel.zig");

const App = tui.App;
const StylePalette = tui_style.Palette;

/// Outer border widget. Shows the current approval snapshot (the
/// command the agent is about to run + Approve/Reject actions).
pub const PermissionWidget = struct {
    app: *App,

    pub fn widget(self: *PermissionWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *PermissionWidget = @ptrCast(@alignCast(ptr));
        const app = self.app;
        const worker = if (app.thread.worker_context) |*context| context else {
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

        const inner = try ctx.arena.create(PermissionInner);
        inner.* = .{ .snapshot = snapshot, .scroll = app.thread.permission_scroll };
        var border: vxfw.Border = .{
            .child = inner.widget(),
            .labels = &.{.{ .text = "Unsafe bash command", .alignment = .top_left }},
            .style = StylePalette.border_label,
        };
        return border.widget().draw(ctx);
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
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        if (width == 0 or height == 0) return surface;

        panel.lineStyledAt(&surface, 0, "Review before running", ctx, 1, StylePalette.panel_header) catch {};
        const body_rows = height -| 3;
        drawPermissionCommand(&surface, ctx, self.snapshot.command, self.scroll, body_rows);
        drawPermissionActions(&surface, ctx, height -| 1, self.snapshot.selected);
        return surface;
    }
};

fn drawPermissionCommand(surface: *vxfw.Surface, ctx: vxfw.DrawContext, command: []const u8, scroll: u32, rows: u16) void {
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
        panel.lineStyledAt(surface, 1 + drawn, line, ctx, 1, StylePalette.thinking_body) catch {};
        drawn += 1;
        line_index += 1;
    }
}

fn drawPermissionActions(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, selected: tui.agent_worker.ApprovalDecision) void {
    if (row >= surface.size.height) return;
    const approve_selected = selected == .approve;
    const reject_selected = selected == .reject;
    panel.lineStyledAt(surface, row, actionLabel(ctx, "Approve", approve_selected), ctx, 1, permissionActionStyle(approve_selected)) catch {};
    panel.lineStyledAt(surface, row, actionLabel(ctx, "Reject", reject_selected), ctx, 13, permissionActionStyle(reject_selected)) catch {};
}

fn actionLabel(ctx: vxfw.DrawContext, text: []const u8, selected: bool) []const u8 {
    if (selected) return std.fmt.allocPrint(ctx.arena, "[ {s} ]", .{text}) catch text;
    return std.fmt.allocPrint(ctx.arena, "  {s}  ", .{text}) catch text;
}

fn permissionActionStyle(selected: bool) vaxis.Style {
    if (selected) return StylePalette.selected_item;
    return StylePalette.thinking_body;
}
