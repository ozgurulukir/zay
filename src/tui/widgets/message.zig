const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const terminal_markdown = @import("terminal_markdown");
const thread_mod = @import("../../thread.zig");
const tui_metrics = @import("../metrics.zig");
const tui_style = @import("../style.zig");
const blackhole = @import("../blackhole.zig");

const logo_text = @embedFile("../../assets/logo/logo.txt");
const logo_connect_text = "/connect to begin building";
const intro_x_padding: u16 = 7;
const logo_gap: u16 = 8;
const logo_row_offset: u16 = 7;

const StylePalette = tui_style.Palette;
const mergedSelectedStyle = tui_style.mergedSelectedStyle;
const messageRowsCached = tui_metrics.messageRowsCached;

pub const loading_frames = [8][]const u8{ "⣼", "⣹", "⢻", "⠿", "⡟", "⣏", "⣧", "⣶" };
pub const loading_frame_ms = 40;

/// Agent bodies at or below this size keep their fully rendered markdown cached
/// across frames (see `thread_mod.RenderCache`). Larger bodies fall back to a
/// per-frame, viewport-bounded render so a giant message never materializes its
/// whole row list into a long-lived cache — preserving the draw-time OOM guard.
const render_cache_max_bytes: usize = 64 * 1024;

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
    message: *thread_mod.Message,
    selected: bool,
    loading_frame: u8,
    blackhole_frame: u16,
    /// Long-lived allocator for the per-message rendered-markdown cache. The
    /// frame arena (`ctx.arena`) is reset every draw, so the cache that must
    /// survive between frames is allocated from here instead.
    gpa: std.mem.Allocator,

    pub fn widget(self: *MessageWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = draw,
        };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *MessageWidget = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse ctx.min.width;
        const requested_height = messageRowsCached(self.message, ConversationLayout.contentWidth(width));
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
        const styled_as_selected = self.selected or !self.message.kind.dimmable();
        var row: u16 = 1;
        switch (self.message.kind) {
            .user => drawWrapped(surface, self.message.body, StylePalette.user, styled_as_selected, &row, ctx, 2, StylePalette.user),
            .agent => drawMarkdown(self, surface, styled_as_selected, &row, ctx),
            .notice => drawWrapped(surface, self.message.body, StylePalette.tool_failed, styled_as_selected, &row, ctx, 2, StylePalette.tool_failed),
            .logo => drawIntro(surface, self.blackhole_frame, &row, ctx),
            .tool => {
                const title_style = if (self.message.failed) StylePalette.tool_failed else StylePalette.tool;
                drawWrapped(surface, self.message.title, title_style, styled_as_selected, &row, ctx, 0, null);
                if (self.message.expanded) drawToolBody(surface, self.message.*, styled_as_selected, &row, ctx);
            },
            .thinking => {
                drawLine(surface, self.message.title, StylePalette.thinking_label, styled_as_selected, &row, ctx, 2, StylePalette.thinking_bar);
                if (self.message.expanded) drawWrapped(surface, self.message.body, StylePalette.thinking_body, styled_as_selected, &row, ctx, 2, StylePalette.thinking_bar);
            },
            .status => drawLoading(surface, self.message.title, self.loading_frame, &row, ctx),
        }
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
        writeText(surface, loading_frames[loading_frame], StylePalette.thinking_label, true, row.*, ctx, 0);
        writeText(surface, text, StylePalette.thinking_body, true, row.*, ctx, 2);
        row.* += 1;
    }

    fn drawIntro(surface: *vxfw.Surface, frame_index: u16, row: *u16, ctx: vxfw.DrawContext) void {
        const row_start = row.*;
        drawBlackhole(surface, frame_index, row_start);
        drawLogo(surface, row_start + logo_row_offset, ctx);
        row.* = row_start + blackhole.rows;
    }

    fn drawBlackhole(surface: *vxfw.Surface, frame_index: u16, row_start: u16) void {
        const data = blackhole.frame(frame_index);
        var row = row_start;
        var line_start: usize = 0;
        while (line_start <= data.len) {
            const line_end = std.mem.findScalarPos(u8, data, line_start, '\n') orelse data.len;
            writeBlackholeLine(surface, data[line_start..line_end], row);
            row += 1;
            if (line_end == data.len) break;
            line_start = line_end + 1;
        }
    }

    fn drawLogo(surface: *vxfw.Surface, row_start: u16, ctx: vxfw.DrawContext) void {
        const col_start = ConversationLayout.left + intro_x_padding + blackhole.cols + logo_gap;
        if (col_start >= surface.size.width -| ConversationLayout.right) return;

        var row = row_start;
        var line_start: usize = 0;
        while (line_start <= logo_text.len) {
            const line_end = std.mem.findScalarPos(u8, logo_text, line_start, '\n') orelse logo_text.len;
            writeLogoLine(surface, logo_text[line_start..line_end], row, col_start, ctx);
            row += 1;
            if (line_end == logo_text.len) break;
            line_start = line_end + 1;
        }

        writeLogoLine(surface, logo_connect_text, row + 1, col_start, ctx);
    }

    // Frames are single-width ASCII, so we walk bytes directly (no grapheme
    // segmentation) and slice glyph bytes out of the static frame data — those
    // slices outlive the render, so the cells need no allocation. Void bytes
    // are skipped entirely, leaving the terminal background as empty space.
    fn writeBlackholeLine(surface: *vxfw.Surface, line: []const u8, row: u16) void {
        if (row >= surface.size.height) return;
        var col = ConversationLayout.left + intro_x_padding;
        const col_limit = surface.size.width -| ConversationLayout.right;
        for (line, 0..) |byte, i| {
            if (col >= col_limit) return;
            if (blackhole.colorAt(byte)) |rgb| {
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = line[i .. i + 1], .width = 1 },
                    .style = .{ .fg = .{ .rgb = rgb } },
                });
            }
            col += 1;
        }
    }

    fn writeLogoLine(surface: *vxfw.Surface, line: []const u8, row: u16, col_start: u16, ctx: vxfw.DrawContext) void {
        if (row >= surface.size.height) return;
        var col = col_start;
        const col_limit = surface.size.width -| ConversationLayout.right;
        var iter = ctx.graphemeIterator(line);
        while (iter.next()) |grapheme| {
            if (col >= col_limit) return;
            const bytes = grapheme.bytes(line);
            const width: u16 = @intCast(ctx.stringWidth(bytes));
            if (width == 0) continue;
            if (col + width > col_limit) return;
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = bytes, .width = @intCast(width) },
                .style = .{ .fg = .{ .rgb = blackhole.orange } },
            });
            col += width;
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
        const width = @max(content_width -| indent, 1);
        if (text.len == 0) {
            drawLine(surface, "", style, selected, row, ctx, indent, bar_style);
            return;
        }

        var line_start: usize = 0;
        while (line_start <= text.len) {
            const line_end = std.mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
            drawWrappedHardLine(surface, text[line_start..line_end], style, selected, row, ctx, indent, bar_style, width);
            if (line_end == text.len) break;
            line_start = line_end + 1;
        }
    }

    fn drawWrappedHardLine(
        surface: *vxfw.Surface,
        line: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: *u16,
        ctx: vxfw.DrawContext,
        indent: u16,
        bar_style: ?vaxis.Style,
        width: u16,
    ) void {
        if (line.len == 0) {
            drawLine(surface, "", style, selected, row, ctx, indent, bar_style);
            return;
        }
        var start: usize = 0;
        while (start < line.len) {
            const end = wrappedLineEnd(line, start, width, ctx);
            drawLine(surface, line[start..end], style, selected, row, ctx, indent, bar_style);
            start = skipLinearWhitespace(line, end);
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
        if (bar_style) |active_bar_style| writeText(surface, "┃", active_bar_style, selected, row.*, ctx, 0);
        writeText(surface, text, style, selected, row.*, ctx, indent);
        row.* += 1;
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
};

fn drawMarkdown(
    self: *MessageWidget,
    surface: *vxfw.Surface,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
) void {
    const text = self.message.body;
    const content_width = @max(ConversationLayout.contentWidth(surface.size.width), 1);

    // Markdown rendering is the dominant per-frame cost, and a visible message
    // is otherwise re-parsed on every animation tick even when nothing about it
    // changed. Cache the rendered rows on the message (keyed by width, dropped
    // by `Thread` mutators) so only the message whose body actually changed is
    // re-rendered.
    const rows: []const terminal_markdown.Row = rows: {
        // Very large bodies stay uncached: holding (and re-rendering) their whole
        // row list is the unbounded-allocation case the draw guard exists for.
        // Render only the rows that land inside the surface, into the frame arena
        // (reset next frame), and drop any cache left over from when the body was
        // smaller. The loop below stops at `surface.size.height`, which is itself
        // capped (see `clippedSurfaceHeight`), so this stays bounded.
        if (text.len > render_cache_max_bytes) {
            if (self.message.render_cache.rendered) |*stale| {
                stale.deinit(self.gpa);
                self.message.render_cache = .{};
            }
            break :rows (terminal_markdown.renderLimited(ctx.arena, text, content_width, surface.size.height) catch {
                MessageWidget.drawWrapped(surface, text, .{}, selected, row, ctx, 0, null);
                return;
            }).rows;
        }

        const cache = &self.message.render_cache;
        if (!cache.valid or cache.width != content_width) {
            if (cache.rendered) |*stale| stale.deinit(self.gpa);
            cache.rendered = terminal_markdown.render(self.gpa, text, content_width) catch {
                cache.* = .{};
                MessageWidget.drawWrapped(surface, text, .{}, selected, row, ctx, 0, null);
                return;
            };
            cache.valid = true;
            cache.width = content_width;
        }
        break :rows cache.rendered.?.rows;
    };

    for (rows) |markdown_row| {
        if (row.* >= surface.size.height) return;
        var start_col = markdown_row.indent;
        for (markdown_row.spans) |span| {
            MessageWidget.writeText(surface, span.text, markdownStyle(span.style), selected, row.*, ctx, start_col);
            start_col += @intCast(@min(ctx.stringWidth(span.text), std.math.maxInt(u16)));
        }
        row.* += 1;
    }
}

fn markdownStyle(style: terminal_markdown.Style) vaxis.Style {
    return switch (style) {
        .normal => .{},
        .heading => .{ .bold = true, .fg = .{ .rgb = .{ 252, 211, 77 } } },
        .quote => StylePalette.thinking_body,
        .list_marker => .{},
        .table_border => StylePalette.thinking_body,
        .code => StylePalette.markdown_code,
        .strong => .{ .bold = true },
        .emphasis => .{ .italic = true },
    };
}

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
    const width = @max(content_width, 1);
    if (text.len == 0) {
        MessageWidget.drawLine(surface, "", StylePalette.thinking_body, selected, row, ctx, 0, null);
        return;
    }

    var line_start: usize = 0;
    while (line_start <= text.len) {
        const line_end = std.mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        const style = diffLineStyle(line);
        MessageWidget.drawWrappedHardLine(surface, line, style, selected, row, ctx, 0, null, width);
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

fn wrappedLineEnd(line: []const u8, start: usize, width: u16, ctx: vxfw.DrawContext) usize {
    std.debug.assert(start < line.len);
    std.debug.assert(width > 0);
    var iter = ctx.graphemeIterator(line[start..]);
    var col: u16 = 0;
    var index = start;
    var last_break: ?usize = null;
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(line[start..]);
        const grapheme_start = index;
        const grapheme_width = @min(ctx.stringWidth(bytes), std.math.maxInt(u16));
        if (col + grapheme_width > width) {
            return last_break orelse if (grapheme_start > start) grapheme_start else grapheme_start + bytes.len;
        }
        index += bytes.len;
        if (isLinearWhitespace(bytes)) last_break = grapheme_start;
        col += @intCast(grapheme_width);
    }
    return line.len;
}

fn skipLinearWhitespace(line: []const u8, start: usize) usize {
    var index = start;
    while (index < line.len) {
        const len = std.unicode.utf8ByteSequenceLength(line[index]) catch return index;
        if (!isLinearWhitespace(line[index .. index + len])) return index;
        index += len;
    }
    return index;
}

fn isLinearWhitespace(bytes: []const u8) bool {
    return std.mem.eql(u8, bytes, " ") or std.mem.eql(u8, bytes, "\t");
}

test "wrappedLineEnd wraps before overflowing word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 8, .height = 3 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const text = "hello world";
    try std.testing.expectEqual(@as(usize, 5), wrappedLineEnd(text, 0, 8, ctx));
    try std.testing.expectEqual(@as(usize, 6), skipLinearWhitespace(text, 5));
}
