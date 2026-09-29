//! The Ctrl+O background-jobs modal widget and its inner row layout.
//!
//! Renders background job snapshots with vxfw.Border labels, elapsed timers,
//! focused cancel action buttons, and — when expanded with Space — a live
//! log-tail panel for the selected job (#37). Scalarized per INV-WIDGET-1:
//! the widget takes per-frame props built by `root_layout`, never an `App`.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui_style = @import("../style.zig");
const panel = @import("panel.zig");
const background_mod = @import("../../background.zig");
pub const background_tool = @import("../../tools/background.zig");

/// Lines kept in the expanded log panel.
pub const log_tail_max_lines: usize = 50;
/// Visible cap for the log panel inside the modal (it shares vertical space
/// with the input area). Rendering always shows the LAST lines, so a live
/// log auto-scrolls.
pub const log_panel_visible_rows: usize = 12;

/// Outer border widget. Shows a snapshot of running background jobs.
pub const BackgroundJobsWidget = struct {
    props: Props = .{},

    pub const Props = struct {
        manager: ?*background_mod.BackgroundManager = null,
        selection: usize = 0,
        cancel_focus: bool = false,
        /// Space-toggled log panel for the selected job (#37).
        log_expanded: bool = false,
        /// Tail text for the selected job's log, read by `root_layout` each
        /// frame via `background_tool.readLogTailBounded` (arena-owned, so
        /// the widget only renders it). Empty when collapsed.
        log_text: []const u8 = "",
        /// Log panel header: the log path.
        log_note: []const u8 = "",
    };

    pub fn widget(self: *BackgroundJobsWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *BackgroundJobsWidget = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        const empty = vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = ctx.max.width orelse 0,
            .height = ctx.max.height orelse 0,
        });
        const manager = self.props.manager orelse return empty;
        const views = manager.snapshot(ctx.arena) catch return empty;
        const inner = try ctx.arena.create(BackgroundJobsInner);
        inner.* = .{
            .views = views,
            .selection = if (views.len == 0) 0 else @min(self.props.selection, views.len - 1),
            .cancel_focus = self.props.cancel_focus,
            .log_expanded = self.props.log_expanded,
            .log_text = self.props.log_text,
            .log_note = self.props.log_note,
        };
        var border: vxfw.Border = .{
            .child = inner.widget(),
            .labels = &.{.{ .text = "Background Jobs", .alignment = .top_left }},
            .style = p.border_label,
        };
        return border.widget().draw(ctx);
    }
};

/// Inner row layout for the background-jobs list. Receives a frozen
/// snapshot of `JobView`s and the current selection/cancel-focus so the
/// outer widget doesn't have to re-fetch state each draw.
const BackgroundJobsInner = struct {
    views: []background_mod.BackgroundManager.JobView,
    selection: usize,
    cancel_focus: bool,
    log_expanded: bool = false,
    log_text: []const u8 = "",
    log_note: []const u8 = "",

    pub fn widget(self: *BackgroundJobsInner) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *BackgroundJobsInner = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
        if (width == 0 or height == 0) return surface;

        if (self.views.len == 0) {
            panel.lineStyledAt(&surface, 0, "No background jobs running.", ctx, 1, p.thinking_body) catch {};
            return surface;
        }

        panel.lineStyledAt(&surface, 0, " ↑/↓ Navigate · → Cancel Job · Space Log · Esc Close ", ctx, 1, p.panel_header) catch {};
        const body_rows = height -| 1;
        var row: u16 = 0;
        while (row < self.views.len and row < body_rows) : (row += 1) {
            const view = self.views[row];
            const selected = row == self.selection;
            var elapsed_buf: [32]u8 = undefined;
            const state = if (view.terminating) "TERMINATING" else "RUNNING";
            const line = std.fmt.allocPrint(ctx.arena, "  {s}  [{s}]  [{s}]  {s}", .{
                view.label,
                formatJobElapsed(&elapsed_buf, view.elapsed_seconds),
                state,
                view.command,
            }) catch view.command;
            panel.lineAt(&surface, 1 + row, line, ctx, selected, 1) catch {};
            // The cancel button sits at the right; highlighted only when the
            // selected row has cancel focus (right-arrow).
            const focused = selected and self.cancel_focus;
            const button = if (focused) " [CANCEL] " else " CANCEL ";
            const style = if (focused) p.tool_failed else p.thinking_body;
            panel.rightStyled(&surface, 1 + row, button, ctx, style) catch {};
        }

        // Expanded log panel for the selected job (#37): a separator naming
        // the log, then the tail — clipped to the LAST visible rows so a
        // growing log always shows its newest output.
        if (self.log_expanded) {
            const sep_row = 1 + @as(u16, @intCast(@min(self.views.len, body_rows)));
            if (sep_row >= height) return surface;
            const sep = std.fmt.allocPrint(ctx.arena, "── log: {s} ──", .{self.log_note}) catch "── log ──";
            panel.lineStyledAt(&surface, sep_row, sep, ctx, 1, p.panel_header) catch {};

            const avail: usize = height -| (sep_row + 1);
            const lines = visibleLogLines(ctx.arena, self.log_text, @max(avail, 1)) catch &.{};
            var log_row: u16 = 0;
            for (lines) |line| {
                if (log_row >= avail) break;
                panel.lineStyledAt(&surface, sep_row + 1 + log_row, line, ctx, 1, p.thinking_body) catch {};
                log_row += 1;
            }
        }
        return surface;
    }
};

/// Split tail `text` into rendered lines, keeping the LAST `max` — the
/// auto-scroll-to-bottom window for the log panel.
fn visibleLogLines(arena: std.mem.Allocator, text: []const u8, max: usize) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(arena);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.rest().len == 0) break; // trailing newline
        try lines.append(arena, std.mem.trim(u8, line, "\r"));
    }
    const total = lines.items.len;
    const keep = @min(total, max);
    const out = try arena.alloc([]const u8, keep);
    @memcpy(out, lines.items[total - keep ..]);
    return out;
}

/// Modal panel height for `root_layout`: border (2) + help (1) + job rows,
/// plus separator + visible log rows when expanded — never over `max_height`.
pub fn panelHeight(job_rows: usize, log_expanded: bool, log_text: []const u8, max_height: u16) u16 {
    var needed: usize = job_rows + 3;
    if (log_expanded) {
        const line_count = std.mem.count(u8, log_text, "\n") + @intFromBool(log_text.len > 0 and log_text[log_text.len - 1] != '\n');
        needed += 1 + @min(line_count, log_panel_visible_rows);
    }
    return @intCast(@min(needed, max_height));
}

/// Compact elapsed render for a modal row, e.g. `45s`, `12m03s`, `2h05m`.
fn formatJobElapsed(buf: []u8, total_seconds: u64) []const u8 {
    if (total_seconds < 60) return std.fmt.bufPrint(buf, "{d}s", .{total_seconds}) catch "0s";
    const minutes = total_seconds / 60;
    const seconds = total_seconds % 60;
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ minutes, seconds }) catch "0m";
    const hours = minutes / 60;
    const rem_minutes = minutes % 60;
    return std.fmt.bufPrint(buf, "{d}h{d:0>2}m", .{ hours, rem_minutes }) catch "0h";
}

// ─── Tests ────────────────────────────────────────────────────────────────

test "visibleLogLines keeps the LAST max lines for auto-scroll" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const lines = try visibleLogLines(arena.allocator(), "a\r\nb\nc\nd\n", 3);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("b", lines[0]);
    try std.testing.expectEqualStrings("d", lines[2]);

    // Fewer lines than the window keeps everything; CRLF is trimmed.
    const few = try visibleLogLines(arena.allocator(), "x\r\ny\n", 10);
    try std.testing.expectEqual(@as(usize, 2), few.len);
    try std.testing.expectEqualStrings("x", few[0]);

    // A no-trailing-newline tail still yields its final line.
    const partial = try visibleLogLines(arena.allocator(), "p\nq", 5);
    try std.testing.expectEqual(@as(usize, 2), partial.len);
    try std.testing.expectEqualStrings("q", partial[1]);
}

test "panelHeight grows for the log panel and respects the cap" {
    const four_lines = "a\nb\nc\nd\n";
    try std.testing.expectEqual(@as(u16, 3 + 2), panelHeight(2, false, four_lines, 40));
    // Expanded: + separator + min(lines, visible cap).
    try std.testing.expectEqual(@as(u16, 5 + 1 + 4), panelHeight(2, true, four_lines, 40));

    var fifty: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fifty.deinit();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        fifty.writer.print("l{d}\n", .{i}) catch unreachable;
    }
    try std.testing.expectEqual(@as(u16, 5 + 1 + @as(u16, @intCast(log_panel_visible_rows))), panelHeight(2, true, fifty.written(), 40));
    // Never taller than the available column.
    try std.testing.expectEqual(@as(u16, 10), panelHeight(2, true, fifty.written(), 10));
}
