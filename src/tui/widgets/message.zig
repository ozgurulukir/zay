const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const terminal_markdown = @import("terminal_markdown");
const transcript_mod = @import("../../transcript.zig");
const parts_mod = @import("../../tools/parts.zig");
const tui_metrics = @import("../metrics.zig");
const tui_style = @import("../style.zig");
const token_scan = @import("../token_scan.zig");
const blackhole = @import("../blackhole.zig");

const log = std.log.scoped(.message_widget);

const logo_connect_text = "/connect to begin building";

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

    pub fn verticalPadding(pres: tui_metrics.PresentationConfig) @TypeOf(vxfw.Padding.vertical(0)) {
        const pad = tui_metrics.topSpacingRows(pres);
        return .{
            .top = pad,
            .bottom = pad,
        };
    }

    pub fn messageTop(pres: tui_metrics.PresentationConfig) u16 {
        return tui_metrics.topSpacingRows(pres);
    }

    pub fn contentWidth(width: u16, max_content_width: u16) u16 {
        return tui_metrics.effectiveContentWidth(width, max_content_width);
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
    has_model_configured: bool = false,
    /// Splash-only state (the logo is the sole transcript message): the intro
    /// block centers vertically in the viewport instead of hugging the top.
    splash_fills_viewport: bool = false,
    /// Viewport height for the fills mode. vxfw's ListView draws children with
    /// `max.height = null`, so the real viewport height must be passed in
    /// (TranscriptWidget.syncViewport already stores it on the Thread).
    splash_viewport_height: u16 = 0,
    /// The user started typing — the splash yields its rows as a blank card.
    /// Same height, so ListView scroll math never shifts mid-typing.
    splash_suppressed: bool = false,
    /// Active transcript-search query, highlighted at draw time (issue #484).
    /// Null outside a search and after closing one; INV-WIDGET-1 keeps it a
    /// borrowed slice built at props time.
    search_query: ?[]const u8 = null,
    /// Active search hit `[start, end)` when this message holds the currently
    /// cycled match (#502), rendered more prominently than passive hits.
    active_search_range: ?[2]usize = null,
    /// Monotonic timestamp (ms) for running-tool elapsed display (#503).
    now_ms: i64 = 0,
    /// Shift-arrow body selection (issue #487), resolved per message by the
    /// list builder; `[min, max)` byte range into this message's body.
    selection_range: ?[2]usize = null,
    palette: *const tui_style.Palette = &tui_style.default_palette,
    presentation: tui_metrics.PresentationConfig = .{},

    pub fn widget(self: *MessageWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = draw,
        };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *MessageWidget = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse ctx.min.width;
        const requested_height = messageRowsCached(self.message, ConversationLayout.contentWidth(width, self.presentation.max_content_width), self.presentation);
        var height = clippedSurfaceHeight(width, requested_height);
        if (self.message.* == .logo and self.splash_fills_viewport and self.splash_viewport_height > 0) {
            // Splash-only state: fill the viewport so the intro block can
            // center vertically (see drawIntro).
            height = @max(height, self.splash_viewport_height);
        }
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = width,
            .height = height,
        });
        MessageWidget.fillCardBackground(&surface, self.palette);
        try self.drawBody(&surface, ctx);
        return surface;
    }

    fn clippedSurfaceHeight(width: u16, requested_height: u16) u16 {
        if (width == 0) return 0;
        const max_height = std.math.maxInt(u16) / width;
        return @min(requested_height, max_height);
    }

    /// Maximum highlighted matches per body (a long body stops highlighting
    /// after this many hits).
    const max_search_spans: usize = 32;

    /// All case-insensitive `query` hits in `text` as byte-offset style spans
    /// (the same overlay model `drawWrappedStyled` already renders), or null
    /// when there is no query or no hit. Arena-owned.
    fn findMatchSpans(arena: std.mem.Allocator, text: []const u8, query: ?[]const u8, p: *const tui_style.Palette) ?[]StyleSpan {
        const q = query orelse return null;
        if (q.len == 0 or q.len > text.len) return null;
        var spans: std.ArrayList(StyleSpan) = .empty;
        var i: usize = 0;
        while (i + q.len <= text.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(text[i .. i + q.len], q)) {
                spans.append(arena, .{ .start = i, .end = i + q.len, .style = searchMatchStyle(p) }) catch return null;
                i += q.len - 1;
            }
            if (spans.items.len >= max_search_spans) break;
        }
        if (spans.items.len == 0) return null;
        return spans.toOwnedSlice(arena) catch null;
    }

    /// The search-hit overlay: bold body text over the selection background
    /// (or reverse video in no-color mode).
    fn searchMatchStyle(p: *const tui_style.Palette) vaxis.Style {
        return tui_style.onSelectionBg(.{ .bold = true }, true, p);
    }

    fn activeSearchMatchStyle(p: *const tui_style.Palette) vaxis.Style {
        return tui_style.onSelectionBg(.{ .bold = true, .reverse = true }, true, p);
    }

    /// Combined byte-offset overlays for a body: search hits (issue #484),
    /// active cycled hit (#502), Shift-arrow/mouse selection (#487/#513), and
    /// `path[:line[:col]]` token underlines (#514).
    fn overlaySpans(
        arena: std.mem.Allocator,
        text: []const u8,
        query: ?[]const u8,
        active_range: ?[2]usize,
        selection: ?[2]usize,
        cached_path_tokens: []const token_scan.PathLineToken,
        p: *const tui_style.Palette,
    ) ?[]StyleSpan {
        var spans: std.ArrayList(StyleSpan) = .empty;
        if (active_range) |range| {
            if (range[1] > range[0] and range[1] <= text.len) {
                spans.append(arena, .{ .start = range[0], .end = range[1], .style = activeSearchMatchStyle(p) }) catch {};
            }
        }
        if (findMatchSpans(arena, text, query, p)) |matches| {
            spans.appendSlice(arena, matches) catch {};
        }
        if (selection) |range| {
            if (range[1] > range[0] and range[1] <= text.len) {
                spans.append(arena, .{ .start = range[0], .end = range[1], .style = searchMatchStyle(p) }) catch {};
            }
        }
        if (cached_path_tokens.len > 0) {
            var token_style = p.tool;
            token_style.ul_style = .single;
            for (cached_path_tokens) |tok| {
                spans.append(arena, .{ .start = tok.start, .end = tok.end, .style = token_style }) catch {};
            }
        }
        if (spans.items.len == 0) return null;
        return spans.toOwnedSlice(arena) catch null;
    }

    /// Draw a plain body, overlaying search-hit and selection styles when
    /// active (issues #484/#487). Falls back to plain `drawWrapped`
    /// otherwise — including the left bar, which the highlighted path omits
    /// (transient modes).
    fn drawBodyText(
        surface: *vxfw.Surface,
        text: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: *u16,
        ctx: vxfw.DrawContext,
        indent: u16,
        bar_style: ?vaxis.Style,
        query: ?[]const u8,
        active_range: ?[2]usize,
        selection: ?[2]usize,
        cached_path_tokens: []const token_scan.PathLineToken,
        p: *const tui_style.Palette,
        max_content_width: u16,
    ) void {
        if (overlaySpans(ctx.arena, text, query, active_range, selection, cached_path_tokens, p)) |spans| {
            drawWrappedStyled(surface, text, spans, style, "", bar_style, selected, row, ctx, indent, p, max_content_width);
            return;
        }
        drawWrapped(surface, text, style, selected, row, ctx, indent, bar_style, p, max_content_width);
    }

    fn formatTurnAnchor(arena: std.mem.Allocator, ts_s: i64) []const u8 {
        if (ts_s <= 0) return "────────────────";
        const epoch_secs: u64 = @intCast(ts_s);
        const day_secs = @mod(epoch_secs, 86400);
        const hour = day_secs / 3600;
        const min = (day_secs % 3600) / 60;
        return std.fmt.allocPrint(arena, "─── {d:0>2}:{d:0>2} UTC ───", .{ hour, min }) catch "────────────────";
    }

    fn drawBody(self: *MessageWidget, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const p = self.palette;
        const styled_as_selected = self.selected or !self.message.kind().dimmable();
        var row: u16 = ConversationLayout.messageTop(self.presentation);
        switch (self.message.*) {
            .user => |m| {
                if (self.presentation.show_turn_timestamps) {
                    const anchor = formatTurnAnchor(ctx.arena, m.timestamp_s);
                    var anchor_style = p.thinking_body;
                    anchor_style.dim = true;
                    drawLine(surface, anchor, anchor_style, styled_as_selected, &row, ctx, 2, null, p);
                }
                drawBodyText(surface, m.body, p.user, styled_as_selected, &row, ctx, 2, p.user, self.search_query, self.active_search_range, self.selection_range, self.message.scanCachePtr().ensurePathTokens(self.gpa, m.body), p, self.presentation.max_content_width);
            },
            .agent => drawMarkdown(self, surface, styled_as_selected, &row, ctx),
            .skill => |m| {
                drawBodyText(surface, m.title, p.skill, styled_as_selected, &row, ctx, 2, p.skill, self.search_query, null, self.selection_range, &.{}, p, self.presentation.max_content_width);
                if (m.expanded and m.body.len > 0) {
                    drawBodyText(surface, m.body, p.thinking_body, styled_as_selected, &row, ctx, 0, null, self.search_query, self.active_search_range, self.selection_range, self.message.scanCachePtr().ensurePathTokens(self.gpa, m.body), p, self.presentation.max_content_width);
                }
            },
            .notice => |m| {
                const prefix: []const u8 = if (std.mem.startsWith(u8, m.body, "! ") or std.mem.startsWith(u8, m.body, "⚠ ")) "" else "! ";
                const marked = if (prefix.len > 0) std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, m.body }) catch m.body else m.body;
                drawBodyText(surface, marked, p.notice, styled_as_selected, &row, ctx, 2, p.notice, self.search_query, self.active_search_range, self.selection_range, token_scan.scanPathLineTokens(ctx.arena, marked, 64) catch &.{}, p, self.presentation.max_content_width);
            },
            .success => |m| {
                const prefix: []const u8 = if (std.mem.startsWith(u8, m.body, "✓ ")) "" else "✓ ";
                const marked = if (prefix.len > 0) std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, m.body }) catch m.body else m.body;
                drawBodyText(surface, marked, p.tool, styled_as_selected, &row, ctx, 2, p.tool, self.search_query, self.active_search_range, self.selection_range, token_scan.scanPathLineTokens(ctx.arena, marked, 64) catch &.{}, p, self.presentation.max_content_width);
            },
            .info => |m| drawBodyText(surface, m.body, p.info, styled_as_selected, &row, ctx, 2, p.info, self.search_query, self.active_search_range, self.selection_range, self.message.scanCachePtr().ensurePathTokens(self.gpa, m.body), p, self.presentation.max_content_width),
            .logo => self.drawIntro(surface, self.blackhole_frame, &row, ctx),
            .tool => |m| {
                const title_style = if (m.failed) p.tool_failed else p.tool;
                try drawToolTitle(surface, m, title_style, styled_as_selected, self.loading_frame, self.now_ms, &row, ctx, p, self.presentation.max_content_width);
                if (m.expanded) try drawToolBody(surface, m, self.message.scanCachePtr(), self.gpa, styled_as_selected, &row, ctx, self.search_query, self.selection_range, p, self.presentation.max_content_width);
            },
            .thinking => |m| {
                drawLine(surface, m.title, p.thinking_label, styled_as_selected, &row, ctx, 2, p.thinking_bar, p);
                if (m.expanded) drawBodyText(surface, m.body, p.thinking_body, styled_as_selected, &row, ctx, 2, p.thinking_bar, self.search_query, self.active_search_range, self.selection_range, self.message.scanCachePtr().ensurePathTokens(self.gpa, m.body), p, self.presentation.max_content_width);
            },
            .status => |m| drawLoading(surface, m.title, self.loading_frame, &row, ctx, p),
        }
    }

    pub fn drawLoading(
        surface: *vxfw.Surface,
        text: []const u8,
        loading_frame: u8,
        row: *u16,
        ctx: vxfw.DrawContext,
        p: *const tui_style.Palette,
    ) void {
        std.debug.assert(loading_frame < loading_frames.len);
        if (row.* >= surface.size.height) return;
        writeText(surface, loading_frames[loading_frame % loading_frames.len], p.thinking_label, true, row.*, ctx, 0, p);
        writeText(surface, text, p.thinking_body, true, row.*, ctx, 2, p);
        row.* += 1;
    }

    fn drawToolTitle(
        surface: *vxfw.Surface,
        message: transcript_mod.ToolView,
        style: vaxis.Style,
        selected: bool,
        loading_frame: u8,
        now_ms: i64,
        row: *u16,
        ctx: vxfw.DrawContext,
        p: *const tui_style.Palette,
        max_content_width: u16,
    ) !void {
        std.debug.assert(loading_frame < loading_frames.len);
        // m6: prefer the precomputed formatted expanded title; fall back to the
        // raw expanded title, then the plain title, when it isn't set.
        const chosen = if (message.expanded)
            message.expanded_title_formatted orelse message.expanded_title orelse message.title
        else
            message.title;
        // Duration/exit suffix (issue #488): appended identically in the row
        // counter (metrics.toolTitleRowsForView) so wrap math matches.
        // Arena-allocated because `surface` cells borrow slices from `command`
        // until `vx.render` finishes after `drawToolTitle` returns.
        const suffix_buf = try ctx.arena.alloc(u8, 256);
        const command = message.titledWithSuffixAt(suffix_buf, toolCommandTitle(chosen), now_ms);
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
            try drawStyledCommandTitle(surface, command, display_text, marker_len, prefix, style, selected, row, ctx, indent, p, max_content_width);
            return;
        }

        if (failed) {
            const marked = try std.fmt.allocPrint(ctx.arena, "✗ {s}", .{command});
            drawToolTitleWrapped(surface, prefix, marked, style, selected, row, ctx, p, max_content_width);
            return;
        }
        drawToolTitleWrapped(surface, prefix, command, style, selected, row, ctx, p, max_content_width);
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
        p: *const tui_style.Palette,
        max_content_width: u16,
    ) !void {
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
        drawWrappedStyled(surface, display_text, spans[0..n], style, prefix, null, selected, row, ctx, indent, p, max_content_width);
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
        p: *const tui_style.Palette,
        max_content_width: u16,
    ) void {
        std.debug.assert(prefix.len > 0);
        const indent: u16 = 3;
        const content_width = ConversationLayout.contentWidth(surface.size.width, max_content_width);
        const width = @max(content_width -| indent, 1);
        if (command.len == 0) {
            drawToolTitleLine(surface, prefix, "", style, selected, row, ctx, p);
            return;
        }

        var start: usize = 0;
        while (start < command.len) {
            const end = wrappedLineEnd(command, start, width, ctx);
            const line_prefix = if (start == 0) prefix else "";
            drawToolTitleLine(surface, line_prefix, command[start..end], style, selected, row, ctx, p);
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
        p: *const tui_style.Palette,
    ) void {
        if (row.* >= surface.size.height) return;
        if (prefix.len > 0) writeText(surface, prefix, p.thinking_label, selected, row.*, ctx, 0, p);
        writeText(surface, command, style, selected, row.*, ctx, 3, p);
        row.* += 1;
    }

    fn toolCommandTitle(title: []const u8) []const u8 {
        const prefix = "🛠  ";
        if (std.mem.startsWith(u8, title, prefix)) return title[prefix.len..];
        return title;
    }

    fn toolIcon(command: []const u8) []const u8 {
        if (containsWord(command, "write") or containsWord(command, "edit") or containsWord(command, "replace")) return "📝";
        if (containsWord(command, "read") or containsWord(command, "view")) return "👀";
        if (containsWord(command, "search") or containsWord(command, "grep") or containsWord(command, "find")) return "🔍";
        if (containsWord(command, "bash") or containsWord(command, "run") or containsWord(command, "exec")) return "⚡";
        return "🔧";
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
        if (self.splash_suppressed) {
            // Typing yields the splash: same row budget, blank card.
            row.* = row_start + blackhole.intro_block_rows;
            return;
        }
        // Splash-only state centers the block in the viewport; otherwise it
        // hugs the top like every other message.
        const block_row = if (self.splash_fills_viewport)
            (surface.size.height -| blackhole.intro_block_rows) / 2
        else
            row_start;
        self.drawBlackhole(surface, frame_index, block_row);
        self.drawConnectHint(surface, block_row + blackhole.rows, ctx);
        row.* = row_start + blackhole.intro_block_rows;
    }

    fn drawBlackhole(self: *MessageWidget, surface: *vxfw.Surface, frame_index: u16, row_start: u16) void {
        const data = blackhole.frame(frame_index);
        var row = row_start;
        var iter = std.mem.splitScalar(u8, data, '\n');
        while (iter.next()) |line| : (row += 1) {
            self.writeBlackholeLine(surface, line, row);
        }
    }

    fn drawConnectHint(self: *MessageWidget, surface: *vxfw.Surface, row: u16, ctx: vxfw.DrawContext) void {
        if (self.has_model_configured) return;
        const hint_width: u16 = @intCast(ctx.stringWidth(logo_connect_text));
        const content_width = ConversationLayout.contentWidth(surface.size.width, self.presentation.max_content_width);
        const col_start = ConversationLayout.left + (content_width -| hint_width) / 2;
        if (col_start >= surface.size.width -| ConversationLayout.right) return;
        self.writeLogoLine(surface, logo_connect_text, row, col_start, ctx);
    }

    // Frames are single-width ASCII, so we walk bytes directly (no grapheme
    // segmentation) and slice glyph bytes out of the static frame data — those
    // slices outlive the render, so the cells need no allocation. Void bytes
    // are skipped entirely, leaving the terminal background as empty space.
    fn writeBlackholeLine(self: *MessageWidget, surface: *vxfw.Surface, line: []const u8, row: u16) void {
        if (row >= surface.size.height) return;
        const p = self.palette;
        var col = ConversationLayout.left + (ConversationLayout.contentWidth(surface.size.width, self.presentation.max_content_width) -| blackhole.cols) / 2;
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

    fn writeLogoLine(self: *MessageWidget, surface: *vxfw.Surface, line: []const u8, row: u16, col_start: u16, ctx: vxfw.DrawContext) void {
        if (row >= surface.size.height) return;
        const p = self.palette;
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
        p: *const tui_style.Palette,
        max_content_width: u16,
    ) void {
        const content_width = ConversationLayout.contentWidth(surface.size.width, max_content_width);
        const width = @max(content_width -| indent, 1);
        if (text.len == 0) {
            drawLine(surface, "", style, selected, row, ctx, indent, bar_style, p);
            return;
        }

        var line_start: usize = 0;
        while (line_start <= text.len) {
            const line_end = std.mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
            drawWrappedHardLine(surface, text[line_start..line_end], style, selected, row, ctx, indent, bar_style, width, p);
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
        p: *const tui_style.Palette,
    ) void {
        if (line.len == 0) {
            drawLine(surface, "", style, selected, row, ctx, indent, bar_style, p);
            return;
        }
        var start: usize = 0;
        while (start < line.len) {
            const end = wrappedLineEnd(line, start, width, ctx);
            drawLine(surface, line[start..end], style, selected, row, ctx, indent, bar_style, p);
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
        p: *const tui_style.Palette,
    ) void {
        if (row.* >= surface.size.height) return;
        if (bar_style) |active_bar_style| writeText(surface, "┃", active_bar_style, selected, row.*, ctx, 0, p);
        writeText(surface, text, style, selected, row.*, ctx, indent, p);
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
        p: *const tui_style.Palette,
    ) void {
        writeTextWithLink(surface, text, style, selected, row, ctx, start_col, "", &.{}, p);
    }

    fn writeTextWithLink(
        surface: *vxfw.Surface,
        text: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: u16,
        ctx: vxfw.DrawContext,
        start_col: u16,
        link_url: []const u8,
        hls: []const StyleSpan,
        p: *const tui_style.Palette,
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
            var cell: vaxis.Cell = .{
                .char = .{ .grapheme = bytes, .width = @intCast(width) },
                .style = mergedSelectedStyle(style, selected),
            };
            // Search-hit / selection overlay (issues #484/#487/#519): `hls` are
            // byte ranges relative to `text`; graphemes inside any range draw
            // with the match style.
            if (hls.len > 0) {
                const offset = @intFromPtr(bytes.ptr) - @intFromPtr(text.ptr);
                for (hls) |range| {
                    if (offset >= range.start and offset < range.end) {
                        cell.style = tui_style.onSelectionBg(.{ .bold = true, .fg = cell.style.fg, .reverse = range.style.reverse }, selected, p);
                        break;
                    }
                }
            }
            if (link_url.len > 0) {
                // A stable per-URI OSC 8 `id` lets terminals treat fragments of
                // one link wrapped across rows (or split by style spans) as a
                // single hover/click region. Arena-owned: cells are written
                // within the frame, same lifetime as the span texts above.
                const link_id = std.fmt.allocPrint(ctx.arena, "id={x}", .{std.hash.Wyhash.hash(0, link_url)}) catch "";
                cell.link = .{ .uri = link_url, .params = link_id };
            }
            writeCellOnCard(surface, col, row, cell);
            col += width;
        }
    }

    /// Pre-fill the message surface so cells no text path writes (ConversationLayout
    /// margins, blank lines, black-hole void) carry the themed card background. An
    /// explicit (non-`.default`) cell is required — `.default` composites as
    /// terminal-default. `writeCellOnCard` then preserves this on text cells.
    pub fn fillCardBackground(surface: *vxfw.Surface, p: *const tui_style.Palette) void {
        const bg: vaxis.Style = p.background;
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
        // Streaming deltas are not display-normalized (an escape can split
        // across deltas), so a raw control byte may reach here. Written to the
        // terminal it moves the cursor (tab/CR/ESC) and desyncs vaxis's diff
        // state until the next full repaint.
        if (isControlGrapheme(written.char.grapheme)) {
            written.char = .{ .grapheme = " ", .width = 1 };
        }
        if (written.style.bg == .default) {
            const idx = (@as(usize, row) * surface.size.width) + col;
            const prev_bg = surface.buffer[idx].style.bg; // the fillCardBackground bg
            written.style.bg = prev_bg;
        }
        surface.writeCell(col, row, written);
    }
};

fn isControlGrapheme(grapheme: []const u8) bool {
    if (grapheme.len == 0) return false;
    return grapheme[0] < 0x20 or grapheme[0] == 0x7f;
}

test "isControlGrapheme flags tab, CR, ESC and DEL but not text" {
    try std.testing.expect(isControlGrapheme("\t"));
    try std.testing.expect(isControlGrapheme("\r"));
    try std.testing.expect(isControlGrapheme("\x1b"));
    try std.testing.expect(isControlGrapheme("\x7f"));
    try std.testing.expect(!isControlGrapheme("a"));
    try std.testing.expect(!isControlGrapheme(" "));
    try std.testing.expect(!isControlGrapheme("é"));
}

fn drawMarkdown(
    self: *MessageWidget,
    surface: *vxfw.Surface,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
) void {
    const p = self.palette;
    const text = self.message.agent.body;
    const content_width = @max(ConversationLayout.contentWidth(surface.size.width, self.presentation.max_content_width), 1);

    const rows: []const terminal_markdown.Row = rows: {
        if (text.len > render_cache_max_bytes) {
            self.message.renderIncPtr().deinit(self.gpa);
            self.message.renderIncPtr().* = .{};
            break :rows (terminal_markdown.renderLimited(ctx.arena, text, content_width, surface.size.height) catch |err| {
                log.debug("large markdown render failed; using plain text fallback error={s} body_bytes={d} width={d}", .{
                    @errorName(err),
                    text.len,
                    content_width,
                });
                MessageWidget.drawWrapped(surface, text, p.body, selected, row, ctx, 0, null, p, self.presentation.max_content_width);
                return;
            }).rows;
        }

        break :rows self.message.renderIncPtr().rows(self.gpa, ctx.arena, text, content_width) catch |err| {
            log.debug("incremental markdown render failed; using plain text fallback error={s} body_bytes={d} width={d}", .{
                @errorName(err),
                text.len,
                content_width,
            });
            MessageWidget.drawWrapped(surface, text, p.body, selected, row, ctx, 0, null, p, self.presentation.max_content_width);
            return;
        };
    };

    // Search-hit ranges over the body (issue #484). Markdown spans borrow the
    // body bytes, so a span's absolute offset is `span.text.ptr - body.ptr`;
    // owned-text spans (stacked table keys) fall outside the body bounds and
    // simply never highlight.
    const match_spans: ?[]StyleSpan = MessageWidget.overlaySpans(ctx.arena, text, self.search_query, self.active_search_range, self.selection_range, self.message.scanCachePtr().ensurePathTokens(self.gpa, text), p);
    for (rows) |markdown_row| {
        if (row.* >= surface.size.height) return;
        var start_col = markdown_row.indent;
        for (markdown_row.spans) |span| {
            const span_addr = @intFromPtr(span.text.ptr);
            const text_addr = @intFromPtr(text.ptr);
            const span_offset = span_addr -| text_addr;
            const borrowed = span_addr >= text_addr and span_offset < text.len and span_offset + span.text.len <= text.len;
            var rel_buf: [MessageWidget.max_search_spans + 1]StyleSpan = undefined;
            var rel_count: usize = 0;
            if (match_spans) |all| {
                if (borrowed) {
                    for (all) |range| {
                        const lo = @max(range.start, span_offset);
                        const hi = @min(range.end, span_offset + span.text.len);
                        if (lo < hi and rel_count < rel_buf.len) {
                            rel_buf[rel_count] = .{ .start = lo - span_offset, .end = hi - span_offset, .style = range.style };
                            rel_count += 1;
                        }
                    }
                }
            }
            MessageWidget.writeTextWithLink(surface, span.text, markdownStyle(span.style, p), selected, row.*, ctx, start_col, span.link_url, rel_buf[0..rel_count], p);
            start_col += @intCast(@min(ctx.stringWidth(span.text), std.math.maxInt(u16)));
        }
        row.* += 1;
    }
}

fn markdownStyle(style: terminal_markdown.Style, p: *const tui_style.Palette) vaxis.Style {
    return switch (style) {
        .normal => p.body,
        .heading => p.markdown_heading,
        .heading_h2 => p.markdown_heading_h2,
        .heading_h3 => p.markdown_heading_h3,
        .quote => p.thinking_body,
        .list_marker => p.body,
        .task_marker => p.markdown_task_marker,
        .rule => p.markdown_rule,
        .table_border => p.thinking_body,
        .code_border => p.markdown_code_border,
        .code => p.markdown_code,
        // Copy body fg, keep the attribute. No `.bg` is set: like every palette
        // style it stays bg-less, and `writeCellOnCard` supplies the card bg at
        // write time. A bare `.bold`/`.italic` would otherwise drop
        // `.normal ==> p.body`'s fg and read as terminal-default.
        .strong => .{ .bold = true, .fg = p.body.fg },
        .emphasis => .{ .italic = true, .fg = p.body.fg },
        .strong_emphasis => .{ .bold = true, .italic = true, .fg = p.body.fg },
        .strikethrough => .{ .strikethrough = true, .fg = p.body.fg },
        .link => .{ .fg = p.model_status.fg, .ul_style = .single },
        .code_keyword => .{ .fg = p.skill.fg, .bold = true },
        .code_string => .{ .fg = p.tool.fg },
        .code_comment => .{ .fg = p.thinking_body.fg, .italic = true },
        .code_number => .{ .fg = p.user.fg },
        .code_type => p.markdown_code_type,
        .code_function => p.markdown_code_function,
        .code_constant => p.markdown_code_constant,
        .code_added => p.tool,
        .code_removed => p.tool_failed,
    };
}

fn drawToolBody(
    surface: *vxfw.Surface,
    message: transcript_mod.ToolView,
    scan_cache: *transcript_mod.ScanCache,
    gpa: std.mem.Allocator,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
    query: ?[]const u8,
    selection: ?[2]usize,
    p: *const tui_style.Palette,
    max_content_width: u16,
) !void {
    if (message.group_items.len > 0) {
        var buf: [256]u8 = undefined;
        for (message.group_items) |item| {
            const item_text = try ctx.arena.dupe(u8, tui_metrics.formatGroupItemRow(&buf, item));
            const item_style = if (item.failed) p.tool_failed else p.thinking_body;
            MessageWidget.drawBodyText(surface, item_text, item_style, selected, row, ctx, 0, null, query, null, selection, &.{}, p, max_content_width);
        }
        return;
    }
    if (message.parts.len > 0) {
        for (message.parts) |part| {
            switch (part.kind) {
                .text => drawToolTextSegment(surface, part.text, null, gpa, message.render, message.body_expanded_in_place, selected, row, ctx, query, selection, p, max_content_width),
                .diff => try drawWrappedDiff(surface, part.text, selected, row, ctx, p, max_content_width),
                .json => drawJson(surface, part, selected, row, ctx, p, max_content_width),
            }
        }
    } else if (message.body.len > 0) {
        switch (message.render) {
            .plain, .shell => drawToolTextSegment(surface, message.body, scan_cache, gpa, message.render, message.body_expanded_in_place, selected, row, ctx, query, selection, p, max_content_width),
            .diff => try drawWrappedDiff(surface, message.body, selected, row, ctx, p, max_content_width),
        }
    }
    if (message.stderr) |stderr| {
        MessageWidget.drawBodyText(surface, stderr, p.tool_failed, selected, row, ctx, 0, null, query, null, selection, &.{}, p, max_content_width);
    }
}

fn drawToolTextSegment(
    surface: *vxfw.Surface,
    text: []const u8,
    scan_cache: ?*transcript_mod.ScanCache,
    gpa: std.mem.Allocator,
    render: transcript_mod.Render,
    expanded_in_place: bool,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
    query: ?[]const u8,
    selection: ?[2]usize,
    p: *const tui_style.Palette,
    max_content_width: u16,
) void {
    if (tui_metrics.splitToolBodyHeadTail(text, expanded_in_place)) |ht| {
        var fbuf: [96]u8 = undefined;
        const formatted_footer = tui_metrics.formatTruncationFooter(&fbuf, ht.omitted_lines);
        const footer = ctx.arena.dupe(u8, formatted_footer) catch "… more lines · Enter to expand in place";
        drawToolStyledText(surface, ht.head, null, gpa, render, selected, row, ctx, query, selection, p, max_content_width);
        MessageWidget.drawWrapped(surface, footer, .{ .fg = p.thinking_body.fg, .dim = true }, selected, row, ctx, 0, null, p, max_content_width);
        drawToolStyledText(surface, ht.tail, null, gpa, render, selected, row, ctx, query, selection, p, max_content_width);
        return;
    }
    drawToolStyledText(surface, text, scan_cache, gpa, render, selected, row, ctx, query, selection, p, max_content_width);
}

fn drawToolStyledText(
    surface: *vxfw.Surface,
    text: []const u8,
    scan_cache: ?*transcript_mod.ScanCache,
    gpa: std.mem.Allocator,
    render: transcript_mod.Render,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
    query: ?[]const u8,
    selection: ?[2]usize,
    p: *const tui_style.Palette,
    max_content_width: u16,
) void {
    const path_tokens = if (scan_cache) |sc| sc.ensurePathTokens(gpa, text) else (token_scan.scanPathLineTokens(ctx.arena, text, 64) catch &.{});
    if (render != .shell) {
        MessageWidget.drawBodyText(surface, text, p.thinking_body, selected, row, ctx, 0, null, query, null, selection, path_tokens, p, max_content_width);
        return;
    }
    const tokens = if (scan_cache) |sc| sc.ensureShellDiagnostics(gpa, text) else (token_scan.scanShellDiagnostics(ctx.arena, text, 64) catch &.{});
    const overlays = MessageWidget.overlaySpans(ctx.arena, text, query, null, selection, path_tokens, p) orelse &.{};
    if (tokens.len == 0 and overlays.len == 0) {
        MessageWidget.drawWrapped(surface, text, p.thinking_body, selected, row, ctx, 0, null, p, max_content_width);
        return;
    }
    const spans = ctx.arena.alloc(StyleSpan, tokens.len + overlays.len) catch {
        MessageWidget.drawWrapped(surface, text, p.thinking_body, selected, row, ctx, 0, null, p, max_content_width);
        return;
    };
    var idx: usize = 0;
    for (tokens) |tok| {
        const tok_style: vaxis.Style = switch (tok.kind) {
            .err => .{ .fg = p.tool_failed.fg, .bold = true },
            .warn => .{ .fg = p.notice.fg, .bold = true },
            .path_line => .{ .fg = p.model_status.fg, .bold = true, .ul_style = .single },
        };
        spans[idx] = .{ .start = tok.start, .end = tok.end, .style = tok_style };
        idx += 1;
    }
    for (overlays) |ov| {
        spans[idx] = ov;
        idx += 1;
    }
    drawWrappedStyled(surface, text, spans[0..idx], p.thinking_body, "", null, selected, row, ctx, 0, p, max_content_width);
}

/// A byte-span into some text plus the vaxis style to draw those bytes with.
/// Draw helpers map `parts_mod.JsonSpan` tokens to these before rendering.
const StyleSpan = struct {
    start: usize,
    end: usize,
    style: vaxis.Style,
};

/// Map a JSON token kind to a vaxis style using the existing palette.
fn jsonTokenStyle(kind: parts_mod.JsonTokenKind, p: *const tui_style.Palette) vaxis.Style {
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
    p: *const tui_style.Palette,
    max_content_width: u16,
) void {
    const styles = ctx.arena.alloc(StyleSpan, part.spans.len) catch return;
    for (part.spans, 0..) |span, i| {
        styles[i] = .{ .start = span.start, .end = span.end, .style = jsonTokenStyle(span.kind, p) };
    }
    drawWrappedStyled(surface, part.text, styles, p.thinking_body, "", null, selected, row, ctx, 0, p, max_content_width);
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
    bar_style: ?vaxis.Style,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
    indent: u16,
    p: *const tui_style.Palette,
    max_content_width: u16,
) void {
    const content_width = ConversationLayout.contentWidth(surface.size.width, max_content_width);
    const width = @max(content_width -| indent, 1);
    if (text.len == 0) {
        if (row.* >= surface.size.height) return;
        if (bar_style) |active_bar| MessageWidget.writeText(surface, "┃", active_bar, selected, row.*, ctx, 0, p);
        if (prefix.len > 0) MessageWidget.writeText(surface, prefix, p.thinking_label, selected, row.*, ctx, 0, p);
        row.* += 1;
        return;
    }

    var line_start: usize = 0;
    var first_line = true;
    while (line_start <= text.len) {
        const line_end = std.mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line_prefix = if (first_line) prefix else "";
        drawStyledHardLine(surface, text[line_start..line_end], line_start, spans, default_style, line_prefix, bar_style, selected, row, ctx, indent, width, p);
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
    bar_style: ?vaxis.Style,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
    indent: u16,
    width: u16,
    p: *const tui_style.Palette,
) void {
    if (row.* >= surface.size.height) return;
    if (line.len == 0) {
        if (bar_style) |active_bar| MessageWidget.writeText(surface, "┃", active_bar, selected, row.*, ctx, 0, p);
        if (prefix.len > 0) MessageWidget.writeText(surface, prefix, p.thinking_label, selected, row.*, ctx, 0, p);
        row.* += 1;
        return;
    }
    var segment_offset: usize = 0;
    var first_segment = true;
    while (segment_offset < line.len) {
        const line_end = wrappedLineEnd(line, segment_offset, width, ctx);
        const segment_prefix = if (first_segment) prefix else "";
        drawStyledSegment(surface, line[segment_offset..line_end], text_abs + segment_offset, spans, default_style, segment_prefix, bar_style, selected, row, ctx, indent, p);
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
    bar_style: ?vaxis.Style,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
    indent: u16,
    p: *const tui_style.Palette,
) void {
    if (row.* >= surface.size.height) return;
    if (bar_style) |active_bar| MessageWidget.writeText(surface, "┃", active_bar, selected, row.*, ctx, 0, p);
    if (prefix.len > 0) MessageWidget.writeText(surface, prefix, p.thinking_label, selected, row.*, ctx, 0, p);
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
    p: *const tui_style.Palette,
    max_content_width: u16,
) !void {
    const content_width = ConversationLayout.contentWidth(surface.size.width, max_content_width);
    const width = @max(content_width, 1);
    if (text.len == 0) {
        MessageWidget.drawLine(surface, "", p.thinking_body, selected, row, ctx, 0, null, p);
        return;
    }

    var line_start: usize = 0;
    while (line_start <= text.len) {
        const line_end = std.mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        const style = diffLineStyle(line, p);
        const expanded = expandDiffTabs(ctx.arena, line) catch line;
        MessageWidget.drawWrappedHardLine(surface, expanded, style, selected, row, ctx, 0, null, width, p);
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
}

fn expandDiffTabs(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, line, '\t') == null) return line;
    return std.mem.replaceOwned(u8, arena, line, "\t", "    ");
}

fn diffLineStyle(line: []const u8, p: *const tui_style.Palette) vaxis.Style {
    if (line.len == 0) return p.thinking_body;
    if (std.mem.startsWith(u8, line, "@@")) return p.diff_hunk;
    if (std.mem.startsWith(u8, line, "diff --git ") or std.mem.startsWith(u8, line, "--- ") or std.mem.startsWith(u8, line, "+++ ")) {
        return p.diff_file_header;
    }
    return switch (line[0]) {
        '+' => p.tool,
        '-' => p.tool_failed,
        else => p.thinking_body,
    };
}

const text_fit = @import("../text_fit.zig");

fn wrappedLineEnd(line: []const u8, start: usize, width: u16, ctx: vxfw.DrawContext) usize {
    _ = ctx;
    return text_fit.wrappedLineEnd(line, start, width);
}

fn skipLinearWhitespace(line: []const u8, start: usize) usize {
    return text_fit.skipLinearWhitespace(line, start);
}

test "failed tool title renders a non-color ✗ marker" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "pwd");
    try transcript.finishTool(gpa, index, "", null, true, .plain, 0, 0);
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
    try transcript.finishTool(gpa, index, "", null, true, .plain, 0, 0);
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
    try transcript.finishTool(gpa, index, "{\"a\":1}", null, false, .plain, 0, 0);
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
    const nord_palette = tui_style.buildPalette(tui_style.nord);

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
        .palette = &nord_palette,
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
    const nord_palette = tui_style.buildPalette(tui_style.nord);

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
        .palette = &nord_palette,
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
    const nord_palette = tui_style.buildPalette(tui_style.nord);

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
        .palette = &nord_palette,
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
    const nord_palette = tui_style.buildPalette(tui_style.nord);

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
        .palette = &nord_palette,
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

test "intro * accent uses intro_accent" {
    const dracula_palette = tui_style.buildPalette(tui_style.dracula);

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
        .palette = &dracula_palette,
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
}

// Helpers so the render asserts don't reach into the active palette order.
fn expectNordBody() tui_style.Palette {
    return tui_style.buildPalette(tui_style.nord);
}
fn expectDraculaIntro() tui_style.Palette {
    return tui_style.buildPalette(tui_style.dracula);
}

test "drawConnectHint renders connect hint when has_model_configured is false" {
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
        .has_model_configured = false,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 120, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);

    // Centered under the art: col = left + (content - hint_w)/2, row =
    // art_top + blackhole.rows (the block hugs the top when the splash
    // shares the transcript with other messages).
    const hint_col = hintCol(120);
    const connect_cell = surface.readCell(hint_col, ConversationLayout.top + blackhole.rows);
    try std.testing.expectEqualStrings("/", connect_cell.char.grapheme);
}

test "drawConnectHint omits connect hint when has_model_configured is true" {
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
        .has_model_configured = true,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 120, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);

    const hint_col = hintCol(120);
    const connect_cell = surface.readCell(hint_col, ConversationLayout.top + blackhole.rows);
    try std.testing.expectEqualStrings(" ", connect_cell.char.grapheme);
}

/// Hint column for a 120-col draw: centered in the content area. Mirrors
/// `drawConnectHint`'s math so the assert stays readable.
fn hintCol(width: u16) u16 {
    const hint_w: u16 = @intCast(logo_connect_text.len);
    return ConversationLayout.left + (ConversationLayout.contentWidth(width, 0) -| hint_w) / 2;
}

test "splash fills and centers in the viewport when it is the sole message" {
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
        .has_model_configured = false,
        .splash_fills_viewport = true,
        .splash_viewport_height = 40,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 120, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);

    // The 25-row intro block centers vertically in the 40-row viewport.
    try std.testing.expectEqual(@as(u16, 40), surface.size.height);
    const block_row = (surface.size.height - blackhole.intro_block_rows) / 2;
    const connect_cell = surface.readCell(hintCol(120), block_row + blackhole.rows);
    try std.testing.expectEqualStrings("/", connect_cell.char.grapheme);
    // The row above the block is card-blank: centered, not top-hugging.
    const above = surface.readCell(hintCol(120), block_row - 1);
    try std.testing.expectEqualStrings(" ", above.char.grapheme);
}

test "splash suppression yields a blank card while typing" {
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
        .has_model_configured = false,
        .splash_suppressed = true,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 120, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);

    // No art, no hint — but the row budget is untouched so ListView scroll
    // math never shifts mid-typing.
    try std.testing.expectEqual(@as(u16, 26), surface.size.height);
    var found_star = false;
    var r: u16 = 0;
    while (r < surface.size.height) : (r += 1) {
        var c: u16 = 0;
        while (c < surface.size.width) : (c += 1) {
            const cell = surface.readCell(c, r);
            if (cell.style.fg == .rgb and std.mem.eql(u8, cell.char.grapheme, "*")) found_star = true;
        }
    }
    try std.testing.expect(!found_star);
    const hint_cell = surface.readCell(hintCol(120), ConversationLayout.top + blackhole.rows);
    try std.testing.expectEqualStrings(" ", hint_cell.char.grapheme);
}

test "MessageWidget preserves left gutter bar on user message when search is active" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.append(gpa, .user, "user", "find me in this message");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var message_widget: MessageWidget = .{
        .message = &transcript.messages.items[index],
        .selected = false,
        .loading_frame = 0,
        .blackhole_frame = 0,
        .gpa = gpa,
        .search_query = "find",
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 5 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);
    const bar_cell = surface.readCell(ConversationLayout.left, ConversationLayout.top);
    try std.testing.expectEqualStrings("┃", bar_cell.char.grapheme);
}

test "MessageWidget highlights multiple search matches within one markdown span" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.append(gpa, .agent, "agent", "foo_and_foo");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var message_widget: MessageWidget = .{
        .message = &transcript.messages.items[index],
        .selected = false,
        .loading_frame = 0,
        .blackhole_frame = 0,
        .gpa = gpa,
        .search_query = "foo",
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 5 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try message_widget.widget().draw(ctx);
    // Both occurrences of "foo" (col left+0 and col left+8) should be bolded by the search overlay.
    try std.testing.expect(surface.readCell(ConversationLayout.left + 0, ConversationLayout.top).style.bold);
    try std.testing.expect(surface.readCell(ConversationLayout.left + 8, ConversationLayout.top).style.bold);
    try std.testing.expect(!surface.readCell(ConversationLayout.left + 4, ConversationLayout.top).style.bold);
}
