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

const tui = @import("../../tui.zig");
const tui_style = @import("../style.zig");
const panel = @import("panel.zig");
const diff_viewer = @import("../diff_viewer.zig");

const App = tui.App;

// Left-margin columns: [0..3] line number, [4] diff sign, [5] comment bracket,
// [6..] content.
const diff_content_col: u16 = 6;
const diff_bracket_col: u16 = 5;

pub const DiffBodyWidget = struct {
    app: *App,

    pub fn widget(self: *DiffBodyWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *DiffBodyWidget = @ptrCast(@alignCast(ptr));
        const app = self.app;
        const w = ctx.max.width orelse 0;
        const h = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = w, .height = h });
        if (w == 0 or h == 0) return surface;

        const lines = app.diff.lines.items;
        const comments = app.diff.comments.items;

        // Display rows = diff lines interleaved with one preview row per comment
        // (inserted after the comment's last line). We never materialize the full
        // list: only on-screen rows allocate, so a huge diff stays bounded.
        const total = lines.len + comments.len;
        var cursor_display = app.diff.cursor;
        for (comments) |comment| {
            if (comment.row_end < app.diff.cursor) cursor_display += 1;
        }

        var scroll = app.diff.scroll;
        if (cursor_display < scroll) scroll = cursor_display;
        if (cursor_display >= scroll + h) scroll = cursor_display + 1 - h;
        if (total > h) {
            if (scroll > total - h) scroll = total - h;
        } else {
            scroll = 0;
        }
        app.diff.scroll = scroll;

        const sel = app.diff.selection();
        const active = app.diff.activeComment();

        // Walk display rows, drawing only those inside [scroll, scroll + h).
        var display: usize = 0;
        var li: usize = 0;
        while (li < lines.len and display < scroll + h) : (li += 1) {
            if (display >= scroll) {
                drawDiffRow(&surface, ctx, app, li, @intCast(display - scroll), li >= sel.start and li <= sel.end, active);
            }
            display += 1;
            for (comments, 0..) |comment, ci| {
                if (comment.row_end != li) continue;
                if (display >= scroll and display < scroll + h) {
                    drawCommentPreview(&surface, ctx, app, ci, @intCast(display - scroll), ci == active);
                }
                display += 1;
            }
        }
        return surface;
    }
};

fn drawDiffRow(surface: *vxfw.Surface, ctx: vxfw.DrawContext, app: *App, idx: usize, row: u16, highlighted: bool, active: ?usize) void {
    const p = tui_style.activePalette();
    const line = app.diff.lines.items[idx];
    switch (line.kind) {
        .file_header => {
            if (highlighted) panel.fillRow(surface, row, p.selected);
            panel.lineStyledAt(surface, row, line.text, ctx, 0, mergedDiffStyle(p.diff_file_header, highlighted)) catch {};
            return;
        },
        .hunk_header => {
            if (highlighted) panel.fillRow(surface, row, p.selected);
            drawHunkHeader(surface, ctx, line.text, row, highlighted);
            return;
        },
        .meta => {
            if (highlighted) panel.fillRow(surface, row, p.selected);
            panel.lineStyledAt(surface, row, line.text, ctx, diff_content_col, mergedDiffStyle(p.diff_hunk, highlighted)) catch {};
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

    if (app.diff.bracketChar(idx)) |glyph| {
        // Yellow when the active (cursor-selected) comment covers this line, so
        // the user can see what Ctrl+E / Ctrl+D will act on; orange otherwise.
        const base_bracket = if (activeCovers(app, active, idx)) p.diff_bracket_active else p.diff_bracket;
        panel.lineStyledAt(surface, row, glyph, ctx, diff_bracket_col, bgMerged(base_bracket, row_bg)) catch {};
    }

    // A modification renders both sides on one line: common text neutral, the
    // deleted middle red and the inserted middle green (each with its own faint
    // wash) — computed lazily for visible rows only, so it stays cheap.
    if (line.kind == .modified) {
        const d = diff_viewer.inlineDiff(line.old_text, line.new_text);
        const neutral = bgMerged(p.thinking_body, row_bg);
        var col = diff_content_col;
        col = writeDiffSegment(surface, ctx, row, col, d.prefix, neutral);
        col = writeDiffSegment(surface, ctx, row, col, d.old_mid, p.diff_inline_del);
        col = writeDiffSegment(surface, ctx, row, col, d.new_mid, p.diff_inline_add);
        _ = writeDiffSegment(surface, ctx, row, col, d.suffix, neutral);
        return;
    }

    const content = expandTabs(ctx.arena, line.text) catch line.text;
    panel.lineStyledAt(surface, row, content, ctx, diff_content_col, style) catch {};
}

/// Render a hunk header (`@@ -a,b +c,d @@`) with the `-` (deletion) range in red
/// and the `+` (addition) range in green; the `@@` markers stay dim. An empty
/// side (`-0,0` on a new file, `+0,0` on a deleted one) is dropped — a red
/// `-0,0` reads like a bug.
fn drawHunkHeader(surface: *vxfw.Surface, ctx: vxfw.DrawContext, text: []const u8, row: u16, highlighted: bool) void {
    const p = tui_style.activePalette();
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
    if (text.len == 0) return col;
    const expanded = expandTabs(ctx.arena, text) catch text;
    var c = col;
    var iter = ctx.graphemeIterator(expanded);
    while (iter.next()) |grapheme| {
        if (c + 1 >= surface.size.width) return c;
        const bytes = grapheme.bytes(expanded);
        const width: u8 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        surface.writeCell(c, row, .{ .char = .{ .grapheme = bytes, .width = width }, .style = style });
        c += width;
    }
    return c;
}

/// True when the active comment exists and covers `idx`.
fn activeCovers(app: *App, active: ?usize, idx: usize) bool {
    const active_index = active orelse return false;
    const comment = app.diff.comments.items[active_index];
    return idx >= comment.row_start and idx <= comment.row_end;
}

/// Inline preview row beneath a commented range: the bracket's `└` foot plus a
/// 💬 and the comment text. The active comment renders yellow with a 💬 marker.
fn drawCommentPreview(surface: *vxfw.Surface, ctx: vxfw.DrawContext, app: *App, comment_index: usize, row: u16, active: bool) void {
    const p = tui_style.activePalette();
    const comment = app.diff.comments.items[comment_index];
    const bracket_style = if (active) p.diff_bracket_active else p.diff_bracket;
    panel.lineStyledAt(surface, row, "└", ctx, diff_bracket_col, bracket_style) catch {};
    const marker: []const u8 = if (active) "  💬 " else "💬 ";
    const text = std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ marker, comment.text }) catch comment.text;
    const text_style = if (active) p.diff_comment_active else p.diff_comment;
    panel.lineStyledAt(surface, row, text, ctx, diff_content_col, text_style) catch {};
}

fn mergedDiffStyle(style: vaxis.Style, highlighted: bool) vaxis.Style {
    return tui_style.onSelectionBg(style, highlighted);
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
    app: *App,

    pub fn widget(self: *DiffCommentEditor) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *DiffCommentEditor = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        const app = self.app;
        const label = app.diff.rangeLabel(ctx.arena, app.diff.comment_anchor) catch "comment";
        const max_w = ctx.max.width orelse ctx.min.width;
        const inner_w: u16 = max_w -| 2;
        var input_box: vxfw.SizedBox = .{ .child = app.inputs.comment.widget(), .size = .{ .width = inner_w, .height = 1 } };
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
    app: *App,

    pub fn widget(self: *DiffSearchWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *DiffSearchWidget = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        var inner: DiffSearchInner = .{ .app = self.app };
        var border: vxfw.Border = .{
            .child = inner.widget(),
            .style = p.thinking_body,
            .labels = &.{.{ .text = "Jump to file", .alignment = .top_left }},
        };
        return border.widget().draw(ctx);
    }
};

const DiffSearchInner = struct {
    app: *App,

    fn widget(self: *DiffSearchInner) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *DiffSearchInner = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        const app = self.app;
        const iw: u16 = ctx.max.width orelse 0;
        const ih: u16 = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = iw, .height = ih });
        if (iw == 0 or ih == 0) return surface;

        // Separator under the search row.
        var sep_col: u16 = 0;
        while (sep_col < iw) : (sep_col += 1) {
            surface.writeCell(sep_col, 1, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = p.thinking_body });
        }

        // Row 0: prompt + the search text field.
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        var prompt_text: vxfw.Text = .{ .text = ">", .softwrap = false, .width_basis = .parent };
        var prompt_box: vxfw.SizedBox = .{ .child = prompt_text.widget(), .size = .{ .width = 2, .height = 1 } };
        var input_box: vxfw.SizedBox = .{ .child = app.inputs.palette.widget(), .size = .{ .width = iw -| 2, .height = 1 } };
        var search_row: vxfw.FlexRow = .{ .children = &.{
            .{ .widget = prompt_box.widget(), .flex = 0 },
            .{ .widget = input_box.widget(), .flex = 1 },
        } };
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .z_index = 0,
            .surface = try search_row.widget().draw(ctx.withConstraints(
                .{ .width = iw, .height = 1 },
                .{ .width = iw, .height = 1 },
            )),
        };
        surface.children = children;

        // Rows 2..: filtered file list (drawn straight onto the base buffer).
        const matches = app.diff.search_matches.items;
        const files = app.diff.files.items;
        const visible: u16 = ih -| 2;
        if (matches.len == 0) {
            panel.lineAt(&surface, 2, "No matching files", ctx, false, 0) catch {};
            return surface;
        }
        const count: u32 = @intCast(matches.len);
        const first = firstVisibleWindow(app.diff.search_sel, count, visible);
        var r: u16 = 0;
        while (r < visible and first + r < count) : (r += 1) {
            const index = first + r;
            const selected = index == app.diff.search_sel;
            const prefix = if (selected) "  " else "  ";
            const text = std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, files[matches[index]].path }) catch files[matches[index]].path;
            panel.lineAt(&surface, 2 + r, text, ctx, selected, 0) catch {};
        }
        return surface;
    }
};

/// First visible index so `selection` stays on screen, pinned to the bottom edge
/// once it scrolls past the fold.
fn firstVisibleWindow(selection: u32, count: u32, visible: u16) u32 {
    const v: u32 = visible;
    if (v == 0 or count <= v) return 0;
    if (selection < v) return 0;
    return @min(selection - v + 1, count - v);
}
