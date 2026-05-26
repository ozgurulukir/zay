const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const session_mod = @import("../../session.zig");
const symbols = @import("../../symbols.zig");
const message = @import("message.zig");
const panel = @import("panel.zig");
const tui_status = @import("../status.zig");

pub const Content = struct {
    io: std.Io,
    list: *vxfw.ListView,
    summaries: []const session_mod.SessionSummary,
    selection: u32,
    global: bool,
    filter: []const u8,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const widgets = try self.resumeWidgets(ctx);
        self.list.children = .{ .slice = widgets };
        self.list.item_count = @intCast(widgets.len);
        self.list.cursor = self.selection;
        self.list.ensureScroll();
        return panel.listSurface(ctx, self.widget(), self.list.widget());
    }

    fn resumeWidgets(self: *Content, ctx: vxfw.DrawContext) ![]vxfw.Widget {
        const count = visibleCount(self.summaries, self.filter);
        const widgets = try ctx.arena.alloc(vxfw.Widget, count);
        const rows = try ctx.arena.alloc(Row, count);
        var index: u32 = 0;
        for (self.summaries) |*summary| {
            if (!matches(summary, self.filter)) continue;
            rows[index] = .{
                .io = self.io,
                .summary = summary,
                .selected = index == self.selection,
                .global = self.global,
            };
            widgets[index] = rows[index].widget();
            index += 1;
        }
        return widgets;
    }
};

const Row = struct {
    io: std.Io,
    summary: *const session_mod.SessionSummary,
    selected: bool,
    global: bool,

    fn widget(self: *Row) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Row = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = 1 }, &.{});
        var buffer: [128]u8 = undefined;
        const modified = tui_status.modifiedTime(self.io, buffer[0..], self.summary.updated_at_ms);
        const left = try self.leftText(ctx, width, modified);
        try panel.commandLine(&surface, 0, left, ctx, self.selected);
        try panel.right(&surface, 0, modified, ctx, self.selected);
        return surface;
    }

    fn leftText(self: *const Row, ctx: vxfw.DrawContext, width: u16, modified: []const u8) ![]const u8 {
        const marker = if (self.selected) "‣ " else "  ";
        const available = resumeLeftWidth(ctx, width, modified);
        const marker_width = ctx.stringWidth(marker);
        if (available <= marker_width) return ctx.arena.dupe(u8, marker);

        const name = self.summary.title orelse "Untitled";
        if (!self.global) {
            const title = try truncateText(ctx, name, available - marker_width);
            return std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ marker, title });
        }

        const separator = symbols.separator_dot_padded;
        const separator_width = ctx.stringWidth(separator);
        if (available <= marker_width + separator_width + 4) {
            const title = try truncateText(ctx, name, available - marker_width);
            return std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ marker, title });
        }

        const content_width = available - marker_width - separator_width;
        const title_width = @max(@as(usize, 8), content_width / 2);
        const path_width = content_width - @min(title_width, content_width);
        const title = try truncateText(ctx, name, @min(title_width, content_width));
        const path = try truncateText(ctx, self.summary.cwd, path_width);
        return std.fmt.allocPrint(ctx.arena, "{s}{s}{s}{s}", .{ marker, title, separator, path });
    }
};

pub fn visibleCount(summaries: []const session_mod.SessionSummary, filter: []const u8) u32 {
    var count: u32 = 0;
    for (summaries) |*summary| {
        if (matches(summary, filter)) count += 1;
    }
    return count;
}

pub fn matches(summary: *const session_mod.SessionSummary, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (summary.title) |title| {
        if (std.mem.indexOf(u8, title, filter) != null) return true;
    }
    if (std.mem.indexOf(u8, summary.cwd, filter) != null) return true;
    if (std.mem.indexOf(u8, summary.id, filter) != null) return true;
    return false;
}

fn resumeLeftWidth(ctx: vxfw.DrawContext, row_width: u16, modified: []const u8) usize {
    const start_col = message.ConversationLayout.left -| 1;
    const end_col = row_width -| message.ConversationLayout.right;
    const date_width = ctx.stringWidth(modified);
    if (end_col <= start_col) return 0;
    if (date_width + 1 >= end_col - start_col) return 0;
    return end_col - start_col - date_width - 1;
}

fn truncateText(ctx: vxfw.DrawContext, text: []const u8, width: usize) ![]const u8 {
    if (width == 0) return ctx.arena.dupe(u8, "");
    if (ctx.stringWidth(text) <= width) return ctx.arena.dupe(u8, text);
    if (width <= 3) return ctx.arena.dupe(u8, "...");

    var out: std.ArrayList(u8) = .empty;
    var used: usize = 0;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const grapheme_width = ctx.stringWidth(bytes);
        if (used + grapheme_width + 3 > width) break;
        try out.appendSlice(ctx.arena, bytes);
        used += grapheme_width;
    }
    try out.appendSlice(ctx.arena, "...");
    return out.toOwnedSlice(ctx.arena);
}
