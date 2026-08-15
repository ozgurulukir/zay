const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const terminal_markdown = @import("terminal_markdown");
const transcript_mod = @import("../../transcript.zig");
const parts_mod = @import("../../tools/parts.zig");
const tui_metrics = @import("../metrics.zig");
const tui_style = @import("../style.zig");
const blackhole = @import("../blackhole.zig");

const tui_status = @import("../status.zig");
const App = @import("../../tui.zig").App;

const logo_text = "N.O.V.A";
const logo_connect_text = "/connect to begin building";
const intro_x_padding: u16 = 7;
const logo_gap: u16 = 8;
const logo_row_offset: u16 = 7;

const mergedSelectedStyle = tui_style.mergedSelectedStyle;
const messageRowsCached = tui_metrics.messageRowsCached;

pub const loading_frames = [8][]const u8{ "⣼", "⣹", "⢻", "⠿", "⡟", "⣏", "⣧", "⣶" };
pub const loading_frame_ms = 40;

/// Agent bodies at or below this size keep their fully rendered markdown cached
/// across frames (see `transcript_mod.RenderCache`). Larger bodies fall back to a
/// per-frame, viewport-bounded render so a giant message never materializes its
/// whole row list into a long-lived cache — preserving the draw-time OOM guard.
/// Defined in `tui_metrics` (SSOT) so the row-counting path gates on the same
/// threshold as the render path here.
const render_cache_max_bytes = tui_metrics.render_cache_max_bytes;

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
    message: *transcript_mod.Message,
    selected: bool,
    loading_frame: u8,
    blackhole_frame: u16,
    /// Long-lived allocator for the per-message rendered-markdown cache. The
    /// frame arena (`ctx.arena`) is reset every draw, so the cache that must
    /// survive between frames is allocated from here instead.
    gpa: std.mem.Allocator,
    app: ?*const App = null,

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
        MessageWidget.fillCardBackground(&surface);
        try self.drawBody(&surface, ctx);
        return surface;
    }

    fn clippedSurfaceHeight(width: u16, requested_height: u16) u16 {
        if (width == 0) return 0;
        const max_height = std.math.maxInt(u16) / width;
        return @min(requested_height, max_height);
    }

    fn drawBody(self: *MessageWidget, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const p = tui_style.activePalette();
        const styled_as_selected = self.selected or !self.message.kind().dimmable();
        var row: u16 = ConversationLayout.top;
        switch (self.message.*) {
            .user => |m| drawWrapped(surface, m.body, p.user, styled_as_selected, &row, ctx, 2, p.user),
            .agent => drawMarkdown(self, surface, styled_as_selected, &row, ctx),
            .skill => |m| {
                drawWrapped(surface, m.title, p.skill, styled_as_selected, &row, ctx, 2, p.skill);
                if (m.expanded and m.body.len > 0) {
                    drawWrapped(surface, m.body, p.thinking_body, styled_as_selected, &row, ctx, 0, null);
                }
            },
            .notice => |m| drawWrapped(surface, m.body, p.notice, styled_as_selected, &row, ctx, 2, p.notice),
            .success => |m| drawWrapped(surface, m.body, p.tool, styled_as_selected, &row, ctx, 2, p.tool),
            .info => |m| drawWrapped(surface, m.body, p.info, styled_as_selected, &row, ctx, 2, p.info),
            .logo => self.drawIntro(surface, self.blackhole_frame, &row, ctx),
            .tool => |m| {
                const title_style = if (m.failed) p.tool_failed else p.tool;
                try drawToolTitle(surface, m, title_style, styled_as_selected, self.loading_frame, &row, ctx);
                if (m.expanded) try drawToolBody(surface, m, styled_as_selected, &row, ctx);
            },
            .thinking => |m| {
                drawLine(surface, m.title, p.thinking_label, styled_as_selected, &row, ctx, 2, p.thinking_bar);
                if (m.expanded) drawWrapped(surface, m.body, p.thinking_body, styled_as_selected, &row, ctx, 2, p.thinking_bar);
            },
            .status => |m| drawLoading(surface, m.title, self.loading_frame, &row, ctx),
        }
    }

    pub fn drawLoading(
        surface: *vxfw.Surface,
        text: []const u8,
        loading_frame: u8,
        row: *u16,
        ctx: vxfw.DrawContext,
    ) void {
        std.debug.assert(loading_frame < loading_frames.len);
        if (row.* >= surface.size.height) return;
        const p = tui_style.activePalette();
        writeText(surface, loading_frames[loading_frame % loading_frames.len], p.thinking_label, true, row.*, ctx, 0);
        writeText(surface, text, p.thinking_body, true, row.*, ctx, 2);
        row.* += 1;
    }

    fn drawToolTitle(
        surface: *vxfw.Surface,
        message: transcript_mod.ToolView,
        style: vaxis.Style,
        selected: bool,
        loading_frame: u8,
        row: *u16,
        ctx: vxfw.DrawContext,
    ) !void {
        std.debug.assert(loading_frame < loading_frames.len);
        // m6: prefer the precomputed formatted expanded title; fall back to the
        // raw expanded title, then the plain title, when it isn't set.
        const chosen = if (message.expanded)
            message.expanded_title_formatted orelse message.expanded_title orelse message.title
        else
            message.title;
        const command = toolCommandTitle(chosen);
        const prefix = if (message.running) loading_frames[loading_frame % loading_frames.len] else toolIcon(command);
        const failed = !message.running and message.failed;
        const has_formatted = message.expanded and message.expanded_title_formatted != null;

        if (has_formatted) {
            const indent: u16 = 3;
            // name = first whitespace-delimited word; the rest is dimmed args.
            // A failed tool gets the "✗ " marker prepended (m5); its byte length
            // shifts the name/args spans so the accent mapping stays aligned.
            const marker_len: usize = if (failed) markerByteLen() else 0;
            const display_text = if (failed)
                try std.fmt.allocPrint(ctx.arena, "✗ {s}", .{command})
            else
                command;
            try drawStyledCommandTitle(surface, command, display_text, marker_len, prefix, style, selected, row, ctx, indent);
            return;
        }

        if (failed) {
            const marked = try std.fmt.allocPrint(ctx.arena, "✗ {s}", .{command});
            drawToolTitleWrapped(surface, prefix, marked, style, selected, row, ctx);
            return;
        }
        drawToolTitleWrapped(surface, prefix, command, style, selected, row, ctx);
    }

    /// Render a formatted command title with an accent name + dimmed args
    /// (and an optional failed marker) through the shared styled wrapper.
    fn drawStyledCommandTitle(
        surface: *vxfw.Surface,
        command: []const u8,
        display_text: []const u8,
        marker_len: usize,
        prefix: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: *u16,
        ctx: vxfw.DrawContext,
        indent: u16,
    ) !void {
        const p = tui_style.activePalette();
        const name_end = std.mem.indexOfScalar(u8, command, ' ') orelse command.len;
        const base = marker_len;
        var spans: [3]StyleSpan = undefined;
        var n: usize = 0;
        if (marker_len > 0) {
            // The marker is byte `[0, marker_len)` in `display_text`.
            spans[n] = .{ .start = 0, .end = marker_len, .style = p.tool_failed };
            n += 1;
        }
        spans[n] = .{ .start = base, .end = base + name_end, .style = p.border_label };
        n += 1;
        if (name_end < command.len) {
            spans[n] = .{ .start = base + name_end, .end = base + command.len, .style = p.thinking_body };
            n += 1;
        }
        drawWrappedStyled(surface, display_text, spans[0..n], style, prefix, selected, row, ctx, indent);
    }

    /// Byte length of the `✗ ` failure marker ("✗" is 3 UTF-8 bytes + 1 space).
    fn markerByteLen() usize {
        return 4;
    }

    fn drawToolTitleWrapped(
        surface: *vxfw.Surface,
        prefix: []const u8,
        command: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: *u16,
        ctx: vxfw.DrawContext,
    ) void {
        std.debug.assert(prefix.len > 0);
        const indent: u16 = 3;
        const content_width = ConversationLayout.contentWidth(surface.size.width);
        const width = @max(content_width -| indent, 1);
        if (command.len == 0) {
            drawToolTitleLine(surface, prefix, "", style, selected, row, ctx);
            return;
        }

        var start: usize = 0;
        while (start < command.len) {
            const end = wrappedLineEnd(command, start, width, ctx);
            const line_prefix = if (start == 0) prefix else "";
            drawToolTitleLine(surface, line_prefix, command[start..end], style, selected, row, ctx);
            start = skipLinearWhitespace(command, end);
        }
    }

    fn drawToolTitleLine(
        surface: *vxfw.Surface,
        prefix: []const u8,
        command: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: *u16,
        ctx: vxfw.DrawContext,
    ) void {
        if (row.* >= surface.size.height) return;
        const p = tui_style.activePalette();
        if (prefix.len > 0) writeText(surface, prefix, p.thinking_label, selected, row.*, ctx, 0);
        writeText(surface, command, style, selected, row.*, ctx, 3);
        row.* += 1;
    }

    fn toolCommandTitle(title: []const u8) []const u8 {
        const prefix = "🛠  ";
        if (std.mem.startsWith(u8, title, prefix)) return title[prefix.len..];
        return title;
    }

    fn toolIcon(command: []const u8) []const u8 {
        if (containsWord(command, "write") or containsWord(command, "edit") or containsWord(command, "replace")) return "📝";
        if (containsWord(command, "read") or containsWord(command, "view")) return "👁";
        if (containsWord(command, "search") or containsWord(command, "grep") or containsWord(command, "find")) return "🔍";
        if (containsWord(command, "bash") or containsWord(command, "run") or containsWord(command, "exec")) return "⚡";
        return "🛠";
    }

    /// Case-insensitive whole-word search: the match must be bounded by
    /// non-alphanumeric characters (or string edges) on both sides.
    fn containsWord(haystack: []const u8, word: []const u8) bool {
        if (word.len > haystack.len) return false;
        var i: usize = 0;
        while (i <= haystack.len - word.len) : (i += 1) {
            if (!std.ascii.eqlIgnoreCase(haystack[i .. i + word.len], word)) continue;
            if (i > 0 and std.ascii.isAlphanumeric(haystack[i - 1])) continue;
            const end = i + word.len;
            if (end < haystack.len and std.ascii.isAlphanumeric(haystack[end])) continue;
            return true;
        }
        return false;
    }

    fn drawIntro(self: *MessageWidget, surface: *vxfw.Surface, frame_index: u16, row: *u16, ctx: vxfw.DrawContext) void {
        const row_start = row.*;
        drawBlackhole(surface, frame_index, row_start);
        self.drawLogo(surface, row_start + logo_row_offset, ctx);
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

    fn drawLogo(self: *MessageWidget, surface: *vxfw.Surface, row_start: u16, ctx: vxfw.DrawContext) void {
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

        if (self.app) |app| {
            if (tui_status.modelStatus(app.liveRuntime(), app.cached_config) != null) return;
        }
        writeLogoLine(surface, logo_connect_text, row + 1, col_start, ctx);
    }

    // Frames are single-width ASCII, so we walk bytes directly (no grapheme
    // segmentation) and slice glyph bytes out of the static frame data — those
    // slices outlive the render, so the cells need no allocation. Void bytes
    // are skipped entirely, leaving the terminal background as empty space.
    fn writeBlackholeLine(surface: *vxfw.Surface, line: []const u8, row: u16) void {
        if (row >= surface.size.height) return;
        const p = tui_style.activePalette();
        var col = ConversationLayout.left + intro_x_padding;
        const col_limit = surface.size.width -| ConversationLayout.right;
        for (line, 0..) |byte, i| {
            if (col >= col_limit) return;
            // The hot `*` accent follows the theme; the rest of the brightness
            // ramp stays artistically fixed so the accretion-disk shape is kept.
            const rgb: ?blackhole.Rgb = if (byte == '*') p.intro_accent.fg.rgb else blackhole.colorAt(byte);
            if (rgb) |rgb_val| {
                MessageWidget.writeCellOnCard(surface, col, row, .{
                    .char = .{ .grapheme = line[i .. i + 1], .width = 1 },
                    .style = .{ .fg = .{ .rgb = rgb_val } },
                });
            }
            col += 1;
        }
    }

    fn writeLogoLine(surface: *vxfw.Surface, line: []const u8, row: u16, col_start: u16, ctx: vxfw.DrawContext) void {
        if (row >= surface.size.height) return;
        const p = tui_style.activePalette();
        var col = col_start;
        const col_limit = surface.size.width -| ConversationLayout.right;
        var iter = ctx.graphemeIterator(line);
        while (iter.next()) |grapheme| {
            if (col >= col_limit) return;
            const bytes = grapheme.bytes(line);
            const width: u16 = @intCast(ctx.stringWidth(bytes));
            if (width == 0) continue;
            if (col + width > col_limit) return;
            MessageWidget.writeCellOnCard(surface, col, row, .{
                .char = .{ .grapheme = bytes, .width = @intCast(width) },
                .style = .{ .fg = .{ .rgb = p.intro_accent.fg.rgb } },
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
            const width: u16 = @intCast(ctx.stringWidth(bytes));
            if (width == 0) continue;
            if (col + width > col_limit) return;
            writeCellOnCard(surface, col, row, .{
                .char = .{ .grapheme = bytes, .width = @intCast(width) },
                .style = mergedSelectedStyle(style, selected),
            });
            col += width;
        }
    }

    /// Pre-fill the message surface so cells no text path writes (ConversationLayout
    /// margins, blank lines, black-hole void) carry the themed card background. An
    /// explicit (non-`.default`) cell is required — `.default` composites as
    /// terminal-default. `writeCellOnCard` then preserves this on text cells.
    pub fn fillCardBackground(surface: *vxfw.Surface) void {
        const bg: vaxis.Style = tui_style.activePalette().background;
        const fill_cell = vaxis.Cell{
            .char = .{}, // default space grapheme
            .style = .{ .bg = bg.bg },
        };
        for (surface.buffer) |*cell| cell.* = fill_cell; // buffer.len == w*h (from Surface.init)
    }

    /// Write a cell onto the card surface, preserving the pre-filled themed bg when
    /// `cell.style.bg` is `.default`. This is the C1 fix: text styles are bg-less by
    /// design (shared styles must not carry a bg — MA-1), so full-cell-replacement
    /// `Surface.writeCell` would otherwise reset text cells to terminal-default.
    fn writeCellOnCard(surface: *vxfw.Surface, col: u16, row: u16, cell: vaxis.Cell) void {
        var written = cell;
        if (written.style.bg == .default) {
            const idx = (@as(usize, row) * surface.size.width) + col;
            const prev_bg = surface.buffer[idx].style.bg; // the fillCardBackground bg
            written.style.bg = prev_bg;
        }
        surface.writeCell(col, row, written);
    }
};

fn drawMarkdown(
    self: *MessageWidget,
    surface: *vxfw.Surface,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
) void {
    const p = tui_style.activePalette();
    const text = self.message.agent.body;
    const content_width = @max(ConversationLayout.contentWidth(surface.size.width), 1);

    const rows: []const terminal_markdown.Row = rows: {
        if (text.len > render_cache_max_bytes) {
            self.message.renderIncPtr().deinit(self.gpa);
            self.message.renderIncPtr().* = .{};
            break :rows (terminal_markdown.renderLimited(ctx.arena, text, content_width, surface.size.height) catch {
                MessageWidget.drawWrapped(surface, text, p.body, selected, row, ctx, 0, null);
                return;
            }).rows;
        }

        break :rows self.message.renderIncPtr().rows(self.gpa, ctx.arena, text, content_width) catch {
            MessageWidget.drawWrapped(surface, text, p.body, selected, row, ctx, 0, null);
            return;
        };
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
    const p = tui_style.activePalette();
    return switch (style) {
        .normal => p.body,
        .heading => p.markdown_heading,
        .quote => p.thinking_body,
        .list_marker => p.body,
        .table_border => p.thinking_body,
        .code => p.markdown_code,
        // Copy body fg, keep the attribute. No `.bg` is set: like every palette
        // style it stays bg-less, and `writeCellOnCard` supplies the card bg at
        // write time. A bare `.bold`/`.italic` would otherwise drop
        // `.normal ==> p.body`'s fg and read as terminal-default.
        .strong => .{ .bold = true, .fg = p.body.fg },
        .emphasis => .{ .italic = true, .fg = p.body.fg },
    };
}

fn drawToolBody(
    surface: *vxfw.Surface,
    message: transcript_mod.ToolView,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
) !void {
    const p = tui_style.activePalette();
    // Prefer the structured parts; fall back to body + render only when there
    // are no parts (tests, direct ToolView construction).
    if (message.parts.len > 0) {
        for (message.parts) |part| {
            switch (part.kind) {
                .text => MessageWidget.drawWrapped(surface, part.text, p.thinking_body, selected, row, ctx, 0, null),
                .diff => try drawWrappedDiff(surface, part.text, selected, row, ctx),
                .json => drawJson(surface, part, selected, row, ctx),
            }
        }
    } else if (message.body.len > 0) {
        switch (message.render) {
            .plain => MessageWidget.drawWrapped(surface, message.body, p.thinking_body, selected, row, ctx, 0, null),
            .diff => try drawWrappedDiff(surface, message.body, selected, row, ctx),
        }
    }
    if (message.stderr) |stderr| {
        MessageWidget.drawWrapped(surface, stderr, p.tool_failed, selected, row, ctx, 0, null);
    }
}

/// A byte-span into some text plus the vaxis style to draw those bytes with.
/// Draw helpers map `parts_mod.JsonSpan` tokens to these before rendering.
const StyleSpan = struct {
    start: usize,
    end: usize,
    style: vaxis.Style,
};

/// Map a JSON token kind to a vaxis style using the existing palette.
fn jsonTokenStyle(kind: parts_mod.JsonTokenKind) vaxis.Style {
    const p = tui_style.activePalette();
    return switch (kind) {
        .key => p.border_label,
        .string => p.markdown_code,
        .number => p.user,
        .boolean => p.skill,
        .null => p.thinking_label,
        .punctuation => p.thinking_body,
    };
}

/// Render a `.json` part with per-token syntax highlighting through the shared
/// styled wrapper. Non-token bytes (whitespace, indentation) read as the muted
/// default body style.
fn drawJson(
    surface: *vxfw.Surface,
    part: parts_mod.Part,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
) void {
    const p = tui_style.activePalette();
    const styles = ctx.arena.alloc(StyleSpan, part.spans.len) catch return;
    for (part.spans, 0..) |span, i| {
        styles[i] = .{ .start = span.start, .end = span.end, .style = jsonTokenStyle(span.kind) };
    }
    drawWrappedStyled(surface, part.text, styles, p.thinking_body, "", selected, row, ctx, 0);
}

/// Wrapped, styled rendering of `text`. Splits on `\n` into hard lines, wraps
/// each with the grapheme-based `wrappedLineEnd`, and colours each grapheme by
/// the `StyleSpan` covering its byte offset (falling back to `default_style`).
/// `prefix` (a loading frame / tool icon) is written at column 0 on the first
/// line only, mirroring `drawToolTitleWrapped`'s symmetry.
fn drawWrappedStyled(
    surface: *vxfw.Surface,
    text: []const u8,
    spans: []const StyleSpan,
    default_style: vaxis.Style,
    prefix: []const u8,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
    indent: u16,
) void {
    const content_width = ConversationLayout.contentWidth(surface.size.width);
    const width = @max(content_width -| indent, 1);
    if (text.len == 0) {
        if (row.* >= surface.size.height) return;
        const p = tui_style.activePalette();
        if (prefix.len > 0) MessageWidget.writeText(surface, prefix, p.thinking_label, selected, row.*, ctx, 0);
        row.* += 1;
        return;
    }

    var line_start: usize = 0;
    var first_line = true;
    while (line_start <= text.len) {
        const line_end = std.mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line_prefix = if (first_line) prefix else "";
        drawStyledHardLine(surface, text[line_start..line_end], line_start, spans, default_style, line_prefix, selected, row, ctx, indent, width);
        if (line_end == text.len) break;
        line_start = line_end + 1;
        first_line = false;
    }
}

/// Word-wrap one hard line of `text` and render each wrapped segment with its
/// per-grapheme style. `text_abs` is `line`'s byte offset within the full text,
/// so segment spans stay aligned with `spans`.
fn drawStyledHardLine(
    surface: *vxfw.Surface,
    line: []const u8,
    text_abs: usize,
    spans: []const StyleSpan,
    default_style: vaxis.Style,
    prefix: []const u8,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
    indent: u16,
    width: u16,
) void {
    if (row.* >= surface.size.height) return;
    if (line.len == 0) {
        const p = tui_style.activePalette();
        if (prefix.len > 0) MessageWidget.writeText(surface, prefix, p.thinking_label, selected, row.*, ctx, 0);
        row.* += 1;
        return;
    }
    var segment_offset: usize = 0;
    var first_segment = true;
    while (segment_offset < line.len) {
        const line_end = wrappedLineEnd(line, segment_offset, width, ctx);
        const segment_prefix = if (first_segment) prefix else "";
        drawStyledSegment(surface, line[segment_offset..line_end], text_abs + segment_offset, spans, default_style, segment_prefix, selected, row, ctx, indent);
        segment_offset = skipLinearWhitespace(line, line_end);
        first_segment = false;
    }
}

/// Draw one wrapped segment (a visual row) of a styled text. Each grapheme
/// picks the `StyleSpan` covering its absolute byte offset.
fn drawStyledSegment(
    surface: *vxfw.Surface,
    segment: []const u8,
    text_abs: usize,
    spans: []const StyleSpan,
    default_style: vaxis.Style,
    prefix: []const u8,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
    indent: u16,
) void {
    if (row.* >= surface.size.height) return;
    const p = tui_style.activePalette();
    if (prefix.len > 0) MessageWidget.writeText(surface, prefix, p.thinking_label, selected, row.*, ctx, 0);
    var col = ConversationLayout.left + indent;
    const col_limit = surface.size.width -| ConversationLayout.right;
    var iter = ctx.graphemeIterator(segment);
    var byte_pos: usize = 0;
    while (iter.next()) |grapheme| {
        if (col >= col_limit) return;
        const bytes = grapheme.bytes(segment);
        const width: u16 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) {
            byte_pos += bytes.len;
            continue;
        }
        if (col + width > col_limit) return;
        const style = styleAt(text_abs + byte_pos, text_abs + byte_pos + bytes.len, spans, default_style);
        MessageWidget.writeCellOnCard(surface, col, row.*, .{
            .char = .{ .grapheme = bytes, .width = @intCast(width) },
            .style = mergedSelectedStyle(style, selected),
        });
        col += width;
        byte_pos += bytes.len;
    }
    row.* += 1;
}

/// The style for a `[text_start, text_end)` byte range: the first `StyleSpan`
/// that overlaps it, else `default_style`.
fn styleAt(text_start: usize, text_end: usize, spans: []const StyleSpan, default_style: vaxis.Style) vaxis.Style {
    var i: usize = 0;
    while (i < spans.len) : (i += 1) {
        const span = spans[i];
        if (text_start >= span.end) continue;
        if (text_end <= span.start) continue;
        return span.style;
    }
    return default_style;
}

fn drawWrappedDiff(
    surface: *vxfw.Surface,
    text: []const u8,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
) !void {
    const content_width = ConversationLayout.contentWidth(surface.size.width);
    const width = @max(content_width, 1);
    if (text.len == 0) {
        const p = tui_style.activePalette();
        MessageWidget.drawLine(surface, "", p.thinking_body, selected, row, ctx, 0, null);
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
    const p = tui_style.activePalette();
    if (line.len == 0) return p.thinking_body;
    return switch (line[0]) {
        '+' => p.tool,
        '-' => p.tool_failed,
        else => p.thinking_body,
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

test "failed tool title renders a non-color ✗ marker" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "pwd");
    try transcript.finishTool(gpa, index, "", null, true, .plain);
    transcript.messages.items[index].tool.expanded = false;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var message_widget: MessageWidget = .{
        .message = &transcript.messages.items[index],
        .selected = true,
        .loading_frame = 0,
        .blackhole_frame = 0,
        .gpa = gpa,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);

    // The marker is part of the title text (col 3, after the icon), so it is
    // independent of the red/green style entirely.
    try std.testing.expectEqualStrings("✗", surface.readCell(ConversationLayout.left + 3, 1).char.grapheme);
    // And the command follows on the same row.
    try std.testing.expectEqualStrings("p", surface.readCell(ConversationLayout.left + 5, 1).char.grapheme);
}

test "expanded tool title uses expanded command" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "List files");
    try transcript.updateToolExpanded(gpa, index, "List files", "pwd");
    transcript.messages.items[index].tool.expanded = true;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var message_widget: MessageWidget = .{
        .message = &transcript.messages.items[index],
        .selected = true,
        .loading_frame = 0,
        .blackhole_frame = 0,
        .gpa = gpa,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);

    try std.testing.expectEqualStrings("p", surface.readCell(ConversationLayout.left + 3, 1).char.grapheme);
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

test "expanded formatted tool title blends accent name with dimmed args" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "List files");
    try transcript.updateToolExpanded(gpa, index, "List files", "List files --all");
    transcript.messages.items[index].tool.expanded = true;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var message_widget: MessageWidget = .{
        .message = &transcript.messages.items[index],
        .selected = false,
        .loading_frame = 0,
        .blackhole_frame = 0,
        .gpa = gpa,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);

    // "List" (offsets 0..4) carries the accent orange; "files --all" (offset 5+)
    // carries the dimmed gray.
    const name_style = surface.readCell(ConversationLayout.left + 3, 1).style;
    const arg_style = surface.readCell(ConversationLayout.left + 3 + 5, 1).style;
    try std.testing.expectEqual(@as([3]u8, .{ 249, 115, 22 }), name_style.fg.rgb);
    try std.testing.expectEqual(@as([3]u8, .{ 138, 138, 138 }), arg_style.fg.rgb);
}

test "failed formatted tool title shifts name/args spans after the marker" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "List files");
    try transcript.updateToolExpanded(gpa, index, "List files", "List files --all");
    try transcript.finishTool(gpa, index, "", null, true, .plain);
    transcript.messages.items[index].tool.expanded = true;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var message_widget: MessageWidget = .{
        .message = &transcript.messages.items[index],
        .selected = true,
        .loading_frame = 0,
        .blackhole_frame = 0,
        .gpa = gpa,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);

    // Prefix "🛠" sits at column 2; the display text starts at column 5. The ✗
    // marker is 3 bytes but 1 column wide, so the accent name ("List") starts
    // at column 7 and the dimmed args' "f" lands at column 12.
    try std.testing.expectEqualStrings("✗", surface.readCell(ConversationLayout.left + 3, 1).char.grapheme);
    try std.testing.expectEqualStrings("L", surface.readCell(ConversationLayout.left + 5, 1).char.grapheme);
    try std.testing.expectEqualStrings("f", surface.readCell(ConversationLayout.left + 10, 1).char.grapheme);
}

test "drawJson highlights a key with the accent style" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "curl");
    try transcript.finishTool(gpa, index, "{\"a\":1}", null, false, .plain);
    transcript.messages.items[index].tool.expanded = true;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var message_widget: MessageWidget = .{
        .message = &transcript.messages.items[index],
        .selected = false,
        .loading_frame = 0,
        .blackhole_frame = 0,
        .gpa = gpa,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 8 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);

    // Pretty-printed JSON body starts on row 2 (`{`); row 3 is the indented
    // key line `  "a": 1`, so the key's opening quote sits at column 4.
    try std.testing.expectEqualStrings("\"", surface.readCell(ConversationLayout.left + 4, 3).char.grapheme);
    const key_style = surface.readCell(ConversationLayout.left + 4, 3).style;
    try std.testing.expectEqual(@as([3]u8, .{ 249, 115, 22 }), key_style.fg.rgb);
}

test "agent body renders Palette.body (not default)" {
    tui_style.setActive(tui_style.nord);
    defer tui_style.setActive(tui_style.default_theme);

    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.append(gpa, .agent, "agent", "hello world");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var message_widget: MessageWidget = .{
        .message = &transcript.messages.items[index],
        .selected = false,
        .loading_frame = 0,
        .blackhole_frame = 0,
        .gpa = gpa,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);

    // A `.normal` body text cell carries the themed body fg, not terminal-default.
    const text_style = surface.readCell(ConversationLayout.left, 1).style;
    try std.testing.expectEqual(expectNordBody().body.fg.rgb, text_style.fg.rgb);
}

test "text cells carry the card background (C1 regression)" {
    tui_style.setActive(tui_style.nord);
    defer tui_style.setActive(tui_style.default_theme);

    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.append(gpa, .agent, "agent", "hello world");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var message_widget: MessageWidget = .{
        .message = &transcript.messages.items[index],
        .selected = false,
        .loading_frame = 0,
        .blackhole_frame = 0,
        .gpa = gpa,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);

    // A written text cell must keep the card bg (its style `.bg` is `.default`,
    // so a plain fill-only implementation would regress to terminal-default here).
    const text_cell = surface.readCell(ConversationLayout.left, 1);
    try std.testing.expect(text_cell.style.bg != .default);
    try std.testing.expectEqual(tui_style.nord.background, text_cell.style.bg.rgb);
}

test "segment-rendered cells carry the card background (drawStyledSegment bypass)" {
    tui_style.setActive(tui_style.nord);
    defer tui_style.setActive(tui_style.default_theme);

    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    // A formatted expanded tool title routes through drawStyledSegment (the 4th
    // write path); an argument cell must still carry the card background.
    const index = try transcript.startTool(gpa, "List files");
    try transcript.updateToolExpanded(gpa, index, "List files", "List files --all");
    transcript.messages.items[index].tool.expanded = true;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var message_widget: MessageWidget = .{
        .message = &transcript.messages.items[index],
        .selected = false,
        .loading_frame = 0,
        .blackhole_frame = 0,
        .gpa = gpa,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);

    // The dimmed-args cell on the title row (index 5+) comes from drawStyledSegment.
    const arg_cell = surface.readCell(ConversationLayout.left + 3 + 5, 1);
    try std.testing.expect(arg_cell.style.bg != .default);
    try std.testing.expectEqual(tui_style.nord.background, arg_cell.style.bg.rgb);
}

test "padding/void cells are filled with the card background" {
    tui_style.setActive(tui_style.nord);
    defer tui_style.setActive(tui_style.default_theme);

    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.append(gpa, .notice, "notice", "hi");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var message_widget: MessageWidget = .{
        .message = &transcript.messages.items[index],
        .selected = false,
        .loading_frame = 0,
        .blackhole_frame = 0,
        .gpa = gpa,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);

    // A trailing cell past the short "hi" text was never written by a text path,
    // so it must already carry the pre-filled card background.
    const pad_cell = surface.readCell(20, 1);
    try std.testing.expect(pad_cell.style.bg != .default);
    try std.testing.expectEqual(tui_style.nord.background, pad_cell.style.bg.rgb);
}

test "intro logo and * accent use intro_accent" {
    tui_style.setActive(tui_style.dracula);
    defer tui_style.setActive(tui_style.default_theme);

    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.append(gpa, .logo, "logo", "");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var message_widget: MessageWidget = .{
        .message = &transcript.messages.items[index],
        .selected = false,
        .loading_frame = 0,
        .blackhole_frame = 0,
        .gpa = gpa,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 120, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);

    // The black-hole `*` accent cells follow the theme (intro_accent), while the
    // hot-core `@` bytes keep their fixed table colour.
    const accent_color = expectDraculaIntro().intro_accent.fg.rgb;
    var found_star = false;
    var r: u16 = 0;
    while (r < surface.size.height) : (r += 1) {
        var c: u16 = 0;
        while (c < surface.size.width) : (c += 1) {
            const cell = surface.readCell(c, r);
            if (cell.style.fg == .rgb and std.mem.eql(u8, cell.char.grapheme, "*")) {
                try std.testing.expectEqual(accent_color, cell.style.fg.rgb);
                found_star = true;
            }
        }
    }
    try std.testing.expect(found_star);

    // The logo text (N.O.V.A) carries the themed intro accent.
    const logo_col = ConversationLayout.left + intro_x_padding + blackhole.cols + logo_gap;
    const logo_cell = surface.readCell(logo_col, ConversationLayout.top + logo_row_offset);
    try std.testing.expectEqual(accent_color, logo_cell.style.fg.rgb);
}

// Helpers so the render asserts don't reach into the active palette order.
fn expectNordBody() tui_style.Palette {
    return tui_style.buildPalette(tui_style.nord);
}
fn expectDraculaIntro() tui_style.Palette {
    return tui_style.buildPalette(tui_style.dracula);
}
