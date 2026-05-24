const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const thread_mod = @import("../../thread.zig");
const tui_metrics = @import("../metrics.zig");
const tui_style = @import("../style.zig");

const StylePalette = tui_style.Palette;
const gradientStyle = tui_style.gradientStyle;
const mergedSelectedStyle = tui_style.mergedSelectedStyle;
const messageRows = tui_metrics.messageRows;

pub const loading_frames = [8][]const u8{ "⣼", "⣹", "⢻", "⠿", "⡟", "⣏", "⣧", "⣶" };
pub const loading_frame_ms = 40;

pub const ConversationLayout = struct {
    pub const left: u16 = 2;
    pub const right: u16 = 2;
    pub const top: u16 = 1;
    pub const bottom: u16 = 1;

    pub fn verticalPadding() @TypeOf(vxfw.Padding.vertical(0)) {
        return .{
            .top = top,
            .bottom = bottom,
        };
    }

    pub fn contentWidth(width: u16) u16 {
        return width -| left -| right;
    }
};

pub const MessageWidget = struct {
    message: thread_mod.Message,
    selected: bool,
    loading_frame: u8,

    pub fn widget(self: *MessageWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = draw,
        };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *MessageWidget = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse ctx.min.width;
        const requested_height = messageRows(self.message, ConversationLayout.contentWidth(width));
        const height = clippedSurfaceHeight(width, requested_height);
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = width,
            .height = height,
        });
        self.drawBody(&surface, ctx);
        return surface;
    }

    fn clippedSurfaceHeight(width: u16, requested_height: u16) u16 {
        if (width == 0) return 0;
        const max_height = std.math.maxInt(u16) / width;
        return @min(requested_height, max_height);
    }

    fn drawBody(self: *MessageWidget, surface: *vxfw.Surface, ctx: vxfw.DrawContext) void {
        var row: u16 = 0;
        fillRow(surface, row, self.selected);
        row += 1;
        switch (self.message.kind) {
            .user => drawWrapped(surface, self.message.body, StylePalette.user, self.selected, &row, ctx, 2, StylePalette.user),
            .agent => drawWrapped(surface, self.message.body, .{}, self.selected, &row, ctx, 0, null),
            .logo => drawLogo(surface, self.message.body, &row, ctx),
            .tool => {
                drawWrapped(surface, self.message.title, StylePalette.tool, self.selected, &row, ctx, 0, null);
                if (self.message.expanded) drawToolBody(surface, self.message, self.selected, &row, ctx);
            },
            .thinking => {
                drawLine(surface, self.message.title, StylePalette.thinking_label, self.selected, &row, ctx, 2, StylePalette.thinking_bar);
                if (self.message.expanded) drawWrapped(surface, self.message.body, StylePalette.thinking_body, self.selected, &row, ctx, 2, StylePalette.thinking_bar);
            },
            .status => drawLoading(surface, self.message.title, self.loading_frame, &row, ctx),
        }
        fillRow(surface, row, self.selected);
    }

    fn drawLoading(
        surface: *vxfw.Surface,
        text: []const u8,
        loading_frame: u8,
        row: *u16,
        ctx: vxfw.DrawContext,
    ) void {
        std.debug.assert(loading_frame < loading_frames.len);
        if (row.* >= surface.size.height) return;
        fillRow(surface, row.*, false);
        writeText(surface, loading_frames[loading_frame], StylePalette.thinking_label, false, row.*, ctx, 0);
        writeText(surface, text, StylePalette.thinking_body, false, row.*, ctx, 2);
        row.* += 1;
    }

    fn drawLogo(surface: *vxfw.Surface, text: []const u8, row: *u16, ctx: vxfw.DrawContext) void {
        var line_start: usize = 0;
        while (line_start <= text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            writeGradient(surface, text[line_start..line_end], row.*, ctx);
            row.* += 1;
            if (line_end == text.len) break;
            line_start = line_end + 1;
        }
    }

    fn drawWrapped(
        surface: *vxfw.Surface,
        text: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: *u16,
        ctx: vxfw.DrawContext,
        indent: u16,
        bar_style: ?vaxis.Style,
    ) void {
        const content_width = ConversationLayout.contentWidth(surface.size.width);
        const width = @max(@as(usize, content_width -| indent), 1);
        if (text.len == 0) {
            drawLine(surface, "", style, selected, row, ctx, indent, bar_style);
            return;
        }

        var line_start: usize = 0;
        while (line_start <= text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            if (line_start == line_end) {
                drawLine(surface, "", style, selected, row, ctx, indent, bar_style);
            } else {
                var chunk_start = line_start;
                while (chunk_start < line_end) {
                    const chunk_end = @min(chunk_start + width, line_end);
                    drawLine(surface, text[chunk_start..chunk_end], style, selected, row, ctx, indent, bar_style);
                    chunk_start = chunk_end;
                }
            }
            if (line_end == text.len) break;
            line_start = line_end + 1;
        }
    }

    fn drawLine(
        surface: *vxfw.Surface,
        text: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: *u16,
        ctx: vxfw.DrawContext,
        indent: u16,
        bar_style: ?vaxis.Style,
    ) void {
        if (row.* >= surface.size.height) return;
        fillRow(surface, row.*, selected);
        if (bar_style) |active_bar_style| writeText(surface, "┃", active_bar_style, selected, row.*, ctx, 0);
        writeText(surface, text, style, selected, row.*, ctx, indent);
        row.* += 1;
    }

    fn fillRow(surface: *vxfw.Surface, row: u16, selected: bool) void {
        if (!selected) return;
        var col: u16 = 0;
        while (col < surface.size.width) : (col += 1) {
            surface.writeCell(col, row, .{ .style = StylePalette.selected });
        }
    }

    fn writeText(
        surface: *vxfw.Surface,
        text: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: u16,
        ctx: vxfw.DrawContext,
        start_col: u16,
    ) void {
        var col = ConversationLayout.left + start_col;
        const col_limit = surface.size.width -| ConversationLayout.right;
        var iter = ctx.graphemeIterator(text);
        while (iter.next()) |grapheme| {
            if (col >= col_limit) return;
            const bytes = grapheme.bytes(text);
            const width: u8 = @intCast(ctx.stringWidth(bytes));
            if (width == 0) continue;
            if (col + width > col_limit) return;
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = bytes, .width = width },
                .style = mergedSelectedStyle(style, selected),
            });
            col += width;
        }
    }

    fn writeGradient(surface: *vxfw.Surface, text: []const u8, row: u16, ctx: vxfw.DrawContext) void {
        const gradient_width: u16 = @max(@min(ctx.stringWidth(text), std.math.maxInt(u16)), 1);
        var col: u16 = ConversationLayout.left;
        const col_limit = surface.size.width -| ConversationLayout.right;
        var iter = ctx.graphemeIterator(text);
        while (iter.next()) |grapheme| {
            if (col >= col_limit) return;
            const bytes = grapheme.bytes(text);
            const width: u8 = @intCast(ctx.stringWidth(bytes));
            if (width == 0) continue;
            if (col + width > col_limit) return;
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = bytes, .width = width },
                .style = gradientStyle(col - ConversationLayout.left, gradient_width, false),
            });
            col += width;
        }
    }
};

fn drawToolBody(
    surface: *vxfw.Surface,
    message: thread_mod.Message,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
) void {
    if (message.body.len > 0) {
        switch (message.tool_render) {
            .plain => MessageWidget.drawWrapped(surface, message.body, StylePalette.thinking_body, selected, row, ctx, 0, null),
            .diff => drawWrappedDiff(surface, message.body, selected, row, ctx),
        }
    }
    if (message.stderr_body) |stderr| {
        MessageWidget.drawWrapped(surface, stderr, StylePalette.tool_failed, selected, row, ctx, 0, null);
    }
}

fn drawWrappedDiff(
    surface: *vxfw.Surface,
    text: []const u8,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
) void {
    const content_width = ConversationLayout.contentWidth(surface.size.width);
    const width = @max(@as(usize, content_width), 1);
    if (text.len == 0) {
        MessageWidget.drawLine(surface, "", StylePalette.thinking_body, selected, row, ctx, 0, null);
        return;
    }

    var line_start: usize = 0;
    while (line_start <= text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        const style = diffLineStyle(line);
        if (line.len == 0) {
            MessageWidget.drawLine(surface, "", style, selected, row, ctx, 0, null);
        } else {
            var chunk_start: usize = 0;
            while (chunk_start < line.len) {
                const chunk_end = @min(chunk_start + width, line.len);
                MessageWidget.drawLine(surface, line[chunk_start..chunk_end], style, selected, row, ctx, 0, null);
                chunk_start = chunk_end;
            }
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
}

fn diffLineStyle(line: []const u8) vaxis.Style {
    if (line.len == 0) return StylePalette.thinking_body;
    return switch (line[0]) {
        '+' => StylePalette.tool,
        '-' => StylePalette.tool_failed,
        else => StylePalette.thinking_body,
    };
}
