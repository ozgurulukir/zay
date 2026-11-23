//! The diff viewer widget family: body (per-line rendering), comment editor
//! (bordered input box), and file-search popup.
//!
//! Pulled out of `tui.zig` (R5.1b of `_pm/Projects/tui-split`) — these three
//! widgets plus the seven row/segment helpers formed a 340-line block that
//! only read `App.diff` / `App.inputs.palette` / `App.inputs.comment` and
//! the panel/style helpers, so they earn their own file.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui_style = @import("../style.zig");
const overlay = @import("overlay.zig");
const panel = @import("panel.zig");
const diff_viewer = @import("../diff_viewer.zig");

// Left-margin columns: [0..3] line number, [4] diff sign, [5] comment bracket,
// [6..] content.
const diff_content_col: u16 = 6;
const diff_bracket_col: u16 = 5;

pub const DiffBodyWidget = struct {
    state: *diff_viewer.State,
    palette: *const tui_style.Palette = &tui_style.default_palette,

    pub fn widget(self: *DiffBodyWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *DiffBodyWidget = @ptrCast(@alignCast(ptr));
        const state = self.state;
        const w = ctx.max.width orelse 0;
        const h = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = w, .height = h });
        if (w == 0 or h == 0) return surface;

        const lines = state.lines.items;
        const comments = state.comments.items;

        // Display rows = diff lines interleaved with one preview row per comment
        // (inserted after the comment's last line). We never materialize the full
        // list: only on-screen rows allocate, so a huge diff stays bounded.
        var total: usize = comments.len;
        var cursor_display: usize = 0;
        for (lines, 0..) |line, li| {
            const rows_for_line = lineDisplayRows(ctx.arena, line, w, state.wrap);
            if (li < state.cursor) cursor_display += rows_for_line;
            total += rows_for_line;
        }
        for (comments) |comment| {
            if (comment.row_end < state.cursor) cursor_display += 1;
        }

        var scroll = state.scroll;
        if (cursor_display < scroll) scroll = cursor_display;
        if (cursor_display >= scroll + h) scroll = cursor_display + 1 - h;
        if (total > h) {
            if (scroll > total - h) scroll = total - h;
        } else {
            scroll = 0;
        }

        const sel = state.selection();
        const active = state.activeComment();

        // Walk display rows, drawing only those inside [scroll, scroll + h).
        var display: usize = 0;
        var li: usize = 0;
        while (li < lines.len and display < scroll + h) : (li += 1) {
            const line_rows = lineDisplayRows(ctx.arena, lines[li], w, state.wrap);
            if (display + line_rows > scroll) {
                const start_sub: usize = if (scroll > display) scroll - display else 0;
                drawDiffLine(&surface, ctx, state, li, display, start_sub, scroll, h, li >= sel.start and li <= sel.end, active, self.palette);
            }
            display += line_rows;
            for (comments, 0..) |comment, ci| {
                if (comment.row_end != li) continue;
                if (display >= scroll and display < scroll + h) {
                    drawCommentPreview(&surface, ctx, state, ci, @intCast(display - scroll), ci == active, self.palette);
                }
                display += 1;
            }
        }
        return surface;
    }
};

fn lineWrapWidth(kind: diff_viewer.LineKind, surface_width: u16) u16 {
    return switch (kind) {
        .file_header => @max(surface_width, 1),
        .hunk_header => @max(surface_width -| 1, 1),
        else => @max(surface_width -| diff_content_col, 1),
    };
}

fn lineDisplayRows(arena: std.mem.Allocator, line: diff_viewer.Line, surface_width: u16, wrap: bool) usize {
    if (!wrap) return 1;
    const width = lineWrapWidth(line.kind, surface_width);
    if (line.kind == .modified) {
        const d = diff_viewer.inlineDiff(line.old_text, line.new_text);
        const total_cols = expandedWidth(arena, d.prefix) + expandedWidth(arena, d.old_mid) + expandedWidth(arena, d.new_mid) + expandedWidth(arena, d.suffix);
        return @max((total_cols + width - 1) / width, 1);
    }
    const expanded = expandTabs(arena, line.text) catch line.text;
    const cols = displayWidth(expanded);
    return @max((cols + width - 1) / width, 1);
}

fn expandedWidth(arena: std.mem.Allocator, text: []const u8) usize {
    const expanded = expandTabs(arena, text) catch text;
    return displayWidth(expanded);
}

fn displayWidth(text: []const u8) usize {
    var cols: usize = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        cols += vaxis.gwidth.gwidth(g.bytes(text), .unicode);
    }
    return cols;
}

fn drawDiffLine(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    state: *diff_viewer.State,
    idx: usize,
    display_base: usize,
    start_sub: usize,
    scroll: usize,
    viewport_h: u16,
    highlighted: bool,
    active: ?usize,
    p: *const tui_style.Palette,
) void {
    if (!state.wrap) {
        drawDiffRow(surface, ctx, state, idx, @intCast(display_base - scroll), highlighted, active, p);
        return;
    }
    const line = state.lines.items[idx];
    const wrap_w = lineWrapWidth(line.kind, surface.size.width);
    const total_rows = lineDisplayRows(ctx.arena, line, surface.size.width, true);

    var sub: usize = start_sub;
    while (sub < total_rows and display_base + sub < scroll + viewport_h) : (sub += 1) {
        const row: u16 = @intCast(display_base + sub - scroll);
        const skip_cols: u16 = @intCast(@min(sub * wrap_w, std.math.maxInt(u16)));
        if (sub == 0) {
            drawDiffRow(surface, ctx, state, idx, row, highlighted, active, p);
            continue;
        }
        // Continuation rows keep the row background wash without repeating the line number/sign.
        const row_bg: ?vaxis.Style = if (highlighted)
            p.selected
        else switch (line.kind) {
            .added => p.diff_added_row,
            .removed => p.diff_removed_row,
            else => null,
        };
        if (row_bg) |bg| panel.fillRow(surface, row, bg);
        switch (line.kind) {
            .file_header => {
                const content = sliceFromDisplayCol(line.text, skip_cols);
                panel.lineStyledAt(surface, row, content, ctx, 0, mergedDiffStyle(p.diff_file_header, highlighted, p)) catch {};
            },
            .hunk_header => {
                const content = sliceFromDisplayCol(line.text, skip_cols);
                panel.lineStyledAt(surface, row, content, ctx, 1, mergedDiffStyle(p.diff_hunk, highlighted, p)) catch {};
            },
            .meta => {
                const content = sliceFromDisplayCol(line.text, skip_cols);
                panel.lineStyledAt(surface, row, content, ctx, diff_content_col, mergedDiffStyle(p.diff_hunk, highlighted, p)) catch {};
            },
            .modified => {
                const d = diff_viewer.inlineDiff(line.old_text, line.new_text);
                const neutral = bgMerged(p.thinking_body, row_bg);
                var remaining = skip_cols;
                var col = diff_content_col;
                col = writeDiffSegmentScrolled(surface, ctx, row, col, d.prefix, neutral, &remaining);
                col = writeDiffSegmentScrolled(surface, ctx, row, col, d.old_mid, p.diff_inline_del, &remaining);
                col = writeDiffSegmentScrolled(surface, ctx, row, col, d.new_mid, p.diff_inline_add, &remaining);
                _ = writeDiffSegmentScrolled(surface, ctx, row, col, d.suffix, neutral, &remaining);
            },
            .added, .removed, .context => {
                const fg = switch (line.kind) {
                    .added => p.tool,
                    .removed => p.tool_failed,
                    else => p.thinking_body,
                };
                const expanded = expandTabs(ctx.arena, line.text) catch line.text;
                const content = sliceFromDisplayCol(expanded, skip_cols);
                panel.lineStyledAt(surface, row, content, ctx, diff_content_col, bgMerged(fg, row_bg)) catch {};
            },
        }
    }
}

fn drawDiffRow(surface: *vxfw.Surface, ctx: vxfw.DrawContext, state: *diff_viewer.State, idx: usize, row: u16, highlighted: bool, active: ?usize, p: *const tui_style.Palette) void {
    const line = state.lines.items[idx];
    switch (line.kind) {
        .file_header => {
            if (highlighted) panel.fillRow(surface, row, p.selected);
            panel.lineStyledAt(surface, row, line.text, ctx, 0, mergedDiffStyle(p.diff_file_header, highlighted, p)) catch {};
            return;
        },
        .hunk_header => {
            if (highlighted) panel.fillRow(surface, row, p.selected);
            drawHunkHeader(surface, ctx, line.text, row, highlighted, p);
            return;
        },
        .meta => {
            if (highlighted) panel.fillRow(surface, row, p.selected);
            panel.lineStyledAt(surface, row, line.text, ctx, diff_content_col, mergedDiffStyle(p.diff_hunk, highlighted, p)) catch {};
            return;
        },
        .added, .removed, .context, .modified => {},
    }

    // Faint green/red wash for whole added/removed lines; selection gray wins
    // while the line is in a comment selection.
    const row_bg: ?vaxis.Style = if (highlighted)
        p.selected
    else switch (line.kind) {
        .added => p.diff_added_row,
        .removed => p.diff_removed_row,
        else => null,
    };
    if (row_bg) |bg| panel.fillRow(surface, row, bg);

    const fg = switch (line.kind) {
        .added => p.tool,
        .removed => p.tool_failed,
        else => p.thinking_body,
    };
    const style = bgMerged(fg, row_bg);

    const number = if (line.kind == .removed) line.old_no else line.new_no;
    if (number) |value| {
        const num = std.fmt.allocPrint(ctx.arena, "{d: >4}", .{value}) catch "    ";
        panel.lineStyledAt(surface, row, num, ctx, 0, bgMerged(p.diff_gutter, row_bg)) catch {};
    }

    const sign: []const u8 = switch (line.kind) {
        .added => "+",
        .removed => "-",
        .modified => "~",
        else => " ",
    };
    panel.lineStyledAt(surface, row, sign, ctx, 4, style) catch {};

    if (state.bracketChar(idx)) |glyph| {
        // Yellow when the active (cursor-selected) comment covers this line, so
        // the user can see what Ctrl+E / Ctrl+D will act on; orange otherwise.
        const base_bracket = if (activeCovers(state, active, idx)) p.diff_bracket_active else p.diff_bracket;
        panel.lineStyledAt(surface, row, glyph, ctx, diff_bracket_col, bgMerged(base_bracket, row_bg)) catch {};
    }

    // A modification renders both sides on one line: common text neutral, the
    // deleted middle red and the inserted middle green (each with its own faint
    // wash) — computed lazily for visible rows only, so it stays cheap.
    if (line.kind == .modified) {
        const d = diff_viewer.inlineDiff(line.old_text, line.new_text);
        const neutral = bgMerged(p.thinking_body, row_bg);
        var remaining_skip = state.h_scroll;
        var col = diff_content_col;
        col = writeDiffSegmentScrolled(surface, ctx, row, col, d.prefix, neutral, &remaining_skip);
        col = writeDiffSegmentScrolled(surface, ctx, row, col, d.old_mid, p.diff_inline_del, &remaining_skip);
        col = writeDiffSegmentScrolled(surface, ctx, row, col, d.new_mid, p.diff_inline_add, &remaining_skip);
        _ = writeDiffSegmentScrolled(surface, ctx, row, col, d.suffix, neutral, &remaining_skip);
        return;
    }

    const expanded = expandTabs(ctx.arena, line.text) catch line.text;
    const content = sliceFromDisplayCol(expanded, state.h_scroll);
    panel.lineStyledAt(surface, row, content, ctx, diff_content_col, style) catch {};
}

fn sliceFromDisplayCol(text: []const u8, start_col: u16) []const u8 {
    if (start_col == 0 or text.len == 0) return text;
    var col: u16 = 0;
    var byte_idx: usize = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        if (col >= start_col) break;
        const bytes = grapheme.bytes(text);
        const w = vaxis.gwidth.gwidth(bytes, .unicode);
        col +|= w;
        byte_idx += bytes.len;
    }
    return text[byte_idx..];
}

/// Render a hunk header (`@@ -a,b +c,d @@`) with the `-` (deletion) range in red
/// and the `+` (addition) range in green; the `@@` markers stay dim. An empty
/// side (`-0,0` on a new file, `+0,0` on a deleted one) is dropped — a red
/// `-0,0` reads like a bug.
fn drawHunkHeader(surface: *vxfw.Surface, ctx: vxfw.DrawContext, text: []const u8, row: u16, highlighted: bool, p: *const tui_style.Palette) void {
    const bg: ?vaxis.Style = if (highlighted) p.selected else null;
    var col: u16 = 1;
    var wrote = false;
    var it = std.mem.splitScalar(u8, text, ' ');
    while (it.next()) |token| {
        if (token.len == 0) continue;
        if (std.mem.eql(u8, token, "-0,0") or std.mem.eql(u8, token, "+0,0")) continue;
        if (wrote) col = writeDiffSegment(surface, ctx, row, col, " ", bgMerged(p.diff_hunk, bg));
        wrote = true;
        const seg_style = switch (token[0]) {
            '-' => p.tool_failed,
            '+' => p.tool,
            else => p.diff_hunk,
        };
        col = writeDiffSegment(surface, ctx, row, col, token, bgMerged(seg_style, bg));
    }
}

/// Copy `style` with `source`'s background merged in (when present).
fn bgMerged(style: vaxis.Style, source: ?vaxis.Style) vaxis.Style {
    var merged = style;
    if (source) |s| merged.bg = s.bg;
    return merged;
}

/// Write one styled segment of an inline-diff line starting at `col`, expanding
/// tabs, and return the next free column. Stops at the surface edge.
fn writeDiffSegment(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, col: u16, text: []const u8, style: vaxis.Style) u16 {
    var zero: u16 = 0;
    return writeDiffSegmentScrolled(surface, ctx, row, col, text, style, &zero);
}

fn writeDiffSegmentScrolled(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    row: u16,
    col: u16,
    text: []const u8,
    style: vaxis.Style,
    remaining_skip: *u16,
) u16 {
    if (text.len == 0) return col;
    const expanded = expandTabs(ctx.arena, text) catch text;
    var c = col;
    var iter = ctx.graphemeIterator(expanded);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(expanded);
        const width: u8 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        if (remaining_skip.* > 0) {
            remaining_skip.* -|= width;
            continue;
        }
        if (c + width > surface.size.width) return c;
        surface.writeCell(c, row, .{ .char = .{ .grapheme = bytes, .width = width }, .style = style });
        c += width;
    }
    return c;
}

/// True when the active comment exists and covers `idx`.
fn activeCovers(state: *diff_viewer.State, active: ?usize, idx: usize) bool {
    const active_index = active orelse return false;
    const comment = state.comments.items[active_index];
    return idx >= comment.row_start and idx <= comment.row_end;
}

/// Inline preview row beneath a commented range: the bracket's `└` foot plus a
/// 💬 and the comment text. The active comment renders yellow with a 💬 marker.
fn drawCommentPreview(surface: *vxfw.Surface, ctx: vxfw.DrawContext, state: *diff_viewer.State, comment_index: usize, row: u16, active: bool, p: *const tui_style.Palette) void {
    const comment = state.comments.items[comment_index];
    const bracket_style = if (active) p.diff_bracket_active else p.diff_bracket;
    panel.lineStyledAt(surface, row, "└", ctx, diff_bracket_col, bracket_style) catch {};
    const marker: []const u8 = if (active) "  💬 " else "💬 ";
    const text = std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ marker, comment.text }) catch comment.text;
    const text_style = if (active) p.diff_comment_active else p.diff_comment;
    panel.lineStyledAt(surface, row, text, ctx, diff_content_col, text_style) catch {};
}

fn mergedDiffStyle(style: vaxis.Style, highlighted: bool, p: *const tui_style.Palette) vaxis.Style {
    return tui_style.onSelectionBg(style, highlighted, p);
}

/// Expand tabs to four spaces so diff content lines up in the fixed-width body.
/// Returns the input unchanged when it has no tabs.
fn expandTabs(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\t') == null) return text;
    var list: std.ArrayList(u8) = .empty;
    for (text) |c| {
        if (c == '\t') {
            try list.appendSlice(arena, "    ");
        } else {
            try list.append(arena, c);
        }
    }
    return list.items;
}

pub const DiffCommentEditor = struct {
    state: *diff_viewer.State,
    comment_input: *vxfw.TextField,
    palette: *const tui_style.Palette = &tui_style.default_palette,

    pub fn widget(self: *DiffCommentEditor) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *DiffCommentEditor = @ptrCast(@alignCast(ptr));
        const p = self.palette;
        const state = self.state;
        const comment_input = self.comment_input;
        const label = state.rangeLabel(ctx.arena, state.comment_anchor) catch "comment";
        const max_w = ctx.max.width orelse ctx.min.width;
        const inner_w: u16 = max_w -| 2;
        var input_box: vxfw.SizedBox = .{ .child = comment_input.widget(), .size = .{ .width = inner_w, .height = 1 } };
        var border: vxfw.Border = .{
            .child = input_box.widget(),
            .style = p.border_label,
            .labels = &.{.{ .text = label, .alignment = .top_left }},
        };
        const border_surface = try border.widget().draw(ctx);

        const hint_text_str = "^S save · Esc cancel";
        var hint_text: vxfw.Text = .{
            .text = hint_text_str,
            .softwrap = false,
            .overflow = .ellipsis,
            .width_basis = .longest_line,
            .style = p.thinking_body,
        };
        const hint_surf = try hint_text.widget().draw(ctx.withConstraints(.{ .width = 0, .height = 1 }, .{ .width = max_w -| 2, .height = 1 }));

        var child_count: usize = 1;
        if (hint_surf.size.width > 0) child_count += 1;
        const children = try ctx.arena.alloc(vxfw.SubSurface, child_count);
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = border_surface,
            .z_index = 0,
        };
        if (hint_surf.size.width > 0) {
            const hint_origin_col = (max_w -| 2) -| hint_surf.size.width;
            children[1] = .{
                .origin = .{ .row = 0, .col = hint_origin_col },
                .surface = hint_surf,
                .z_index = 1,
            };
        }

        return vxfw.Surface{
            .size = border_surface.size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

/// Centered file-search popup: a bordered box with a real search text field
/// (`palette_input`) on top and the filtered file list below — same shape as the
/// resume/command pickers, rather than stuffing the query into the border label.
pub const DiffSearchWidget = struct {
    state: *diff_viewer.State,
    palette_input: *vxfw.TextField,
    palette: *const tui_style.Palette = &tui_style.default_palette,

    pub fn widget(self: *DiffSearchWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *DiffSearchWidget = @ptrCast(@alignCast(ptr));
        var list: DiffSearchList = .{ .state = self.state, .palette = self.palette };
        var chrome: overlay.SearchableOverlayChrome = .{
            .label = "Jump to file",
            .width = ctx.max.width orelse 80,
            .height = ctx.max.height orelse 24,
            .full_panel = false,
            .palette_input = self.palette_input,
            .fill_background = false,
            .palette = self.palette,
            .content = list.widget(),
        };
        return chrome.widget().draw(ctx);
    }
};

const DiffSearchList = struct {
    state: *diff_viewer.State,
    palette: *const tui_style.Palette = &tui_style.default_palette,

    fn widget(self: *DiffSearchList) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *DiffSearchList = @ptrCast(@alignCast(ptr));
        const p = self.palette;
        const state = self.state;
        const iw: u16 = ctx.max.width orelse 0;
        const ih: u16 = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = iw, .height = ih });
        if (iw == 0 or ih == 0) return surface;

        // Filtered file list (drawn straight onto the base buffer).
        const matches = state.search_matches.items;
        const files = state.files.items;
        if (matches.len == 0) {
            panel.lineAt(&surface, 0, "No matching files", ctx, false, 0, p) catch {};
            return surface;
        }
        const count: u32 = @intCast(matches.len);
        const viewport = panel.ViewportWindow.compute(state.search_sel, count, ih);
        var r: u16 = 0;
        while (r < viewport.visible_height and viewport.start_index + r < count) : (r += 1) {
            const index = viewport.start_index + r;
            const selected = index == state.search_sel;
            const text = std.fmt.allocPrint(ctx.arena, "  {s}", .{files[matches[index]].path}) catch files[matches[index]].path;
            panel.lineAt(&surface, r, text, ctx, selected, 0, p) catch {};
        }
        return surface;
    }
};

test "expandTabs expands tabs to four spaces and passes plain text through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const plain = "no tabs here";
    try std.testing.expectEqualStrings(plain, try expandTabs(arena.allocator(), plain));

    const expanded = try expandTabs(arena.allocator(), "\tindented\ttail");
    try std.testing.expectEqualStrings("    indented    tail", expanded);
}

test "DiffBodyWidget wraps long lines when wrap is enabled and h_scrolls modified rows" {
    const gpa = std.testing.allocator;
    var state: diff_viewer.State = .{};
    defer state.deinit(gpa);

    try state.lines.append(gpa, .{
        .kind = .modified,
        .text = "abcdefghij1234567890",
        .old_text = "abcdefghijOLD",
        .new_text = "abcdefghijNEW",
    });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = 16, .height = 4 },
        .max = .{ .width = 16, .height = 4 },
        .cell_size = .{ .width = 1, .height = 1 },
    };

    // With wrap=false and h_scroll=10, .modified skips "abcdefghij" and renders "OLDNEW".
    state.h_scroll = 10;
    var body: DiffBodyWidget = .{ .state = &state };
    const surf_hscroll = try body.widget().draw(ctx);
    try std.testing.expectEqualStrings("O", surf_hscroll.readCell(diff_content_col, 0).char.grapheme);

    // With wrap=true, 16-col width (10 content cols) wraps 16 chars across 2 rows:
    // row 0 = "abcdefghij", row 1 = "OLDNEW".
    state.toggleWrap();
    try std.testing.expect(state.wrap);
    try std.testing.expectEqual(@as(u16, 0), state.h_scroll);
    const surf_wrap = try body.widget().draw(ctx);
    try std.testing.expectEqualStrings("a", surf_wrap.readCell(diff_content_col, 0).char.grapheme);
    try std.testing.expectEqualStrings("O", surf_wrap.readCell(diff_content_col, 1).char.grapheme);
    try std.testing.expectEqualStrings("N", surf_wrap.readCell(diff_content_col + 3, 1).char.grapheme);
}
