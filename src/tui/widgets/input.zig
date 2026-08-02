//! The command input box and its word-wrapping math.
//!
//! Pulled out of `tui.zig` (R6.1 of `_pm/Projects/tui-split`) — the
//! `InputWidget` (bordered input field, queued-message preview, hint line,
//! lanes/background badges, diff counts), `CommandInputText` (the multi-line
//! renderer inside the input border), the `WrappedInputDraw` /
//! `WrappedTextPosition` / `VerticalMove` types, and the 13 free functions
//! that compute word-wrapped cursor positions and draw wrapped text.
//!
//! Symbols a caller outside this file reaches:
//! - `InputWidget` — instantiated by `drawRoot`.
//! - `VerticalMove`, `wrappedPosition`, `visualRowStart`, `byteAtVisualColumn`,
//!   `wrappedTextRows`, `WrappedTextPosition` — used by
//!   `App.moveInputCursorVertical` and `App.inputTextRows`.
//! - `writeDiffCounts`, `inputHintText` — used by inline tests in `tui.zig`.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../../tui.zig");
const tui_style = @import("../style.zig");
const tui_status = @import("../status.zig");
const symbols = @import("../../symbols.zig");
const panel = @import("panel.zig");

const App = tui.App;
const StylePalette = tui_style.Palette;
const DiffCounts = tui.DiffCounts;

pub fn writeDiffCounts(surface: *vxfw.Surface, ctx: vxfw.DrawContext, counts: DiffCounts) void {
    const additions = std.fmt.allocPrint(ctx.arena, "+{d}", .{@min(counts.additions, 99999)}) catch return;
    const deletions = std.fmt.allocPrint(ctx.arena, "-{d}", .{@min(counts.deletions, 99999)}) catch return;
    const total_width = additions.len + 1 + deletions.len;
    const start_col: u16 = if (total_width >= surface.size.width)
        0
    else
        @intCast(surface.size.width - total_width);
    writeAscii(surface, additions, StylePalette.tool, start_col);
    writeAscii(surface, deletions, StylePalette.tool_failed, start_col + @as(u16, @intCast(additions.len + 1)));
}

fn writeAscii(surface: *vxfw.Surface, text: []const u8, style: vaxis.Style, col_start: u16) void {
    var col = col_start;
    for (text, 0..) |_, index| {
        if (col >= surface.size.width) return;
        surface.writeCell(col, 0, .{
            .char = .{ .grapheme = text[index .. index + 1], .width = 1 },
            .style = style,
        });
        col += 1;
    }
}

fn inputHintText(app: *const App) []const u8 {
    if (app.getPendingQuitAt() != null) return "Press Ctrl+C or Ctrl+D again to exit";
    return switch (app.mode) {
        .command => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Execute" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
        .session_picker => switch (app.nav.session_action) {
            .browsing => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Resume" ++ symbols.separator_dot_padded ++ "[D] Delete" ++ symbols.separator_dot_padded ++ "[R] Rename" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
            .renaming => "[ENTER] Save" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
            .deleting => "[Y] Delete" ++ symbols.separator_dot_padded ++ "[N/ESC] Cancel",
            .blocked => "[Any key] Dismiss",
        },
        .provider_picker => switch (app.pickers.provider.stage) {
            .list => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Select" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
            .form => "[ENTER] Save API Key" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
        },
        .model_picker => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "←/→ Effort" ++ symbols.separator_dot_padded ++ "[ENTER] Select" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
        .tree_picker => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Jump to branch" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
        .save_message => "[ENTER] Save" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
        .lanes => switch (app.nav.lanes_purpose) {
            .manage => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[M] Merge into current" ++ symbols.separator_dot_padded ++ "[X] Delete" ++ symbols.separator_dot_padded ++ "[ESC] Back",
            .merge_dest => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Merge into" ++ symbols.separator_dot_padded ++ "[ESC] Back",
        },
        .diff_viewer => "",
        .help => "[ESC] / [ENTER] Close Help",
        .settings => "Tab Section" ++ symbols.separator_dot_padded ++ "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Toggle/Edit" ++ symbols.separator_dot_padded ++ "Ctrl+S Save" ++ symbols.separator_dot_padded ++ "[ESC] Close",
        .mcp => "[Space] Toggle" ++ symbols.separator_dot_padded ++ "Ctrl+R Reconnect" ++ symbols.separator_dot_padded ++ "[ESC] Close",
        .plugins => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ESC] Close",
        .normal => "Type prompt, @file, $skill or / for menu" ++ symbols.separator_dot_padded ++ "Ctrl+O Background" ++ symbols.separator_dot_padded ++ "Ctrl+N Lanes",
    };
}

pub const CommandInputText = struct {
    app: *App,

    fn widget(self: *CommandInputText) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawInputText,
        };
    }

    fn drawInputText(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *CommandInputText = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        self.app.input_wrap_width = width;
        const rows = try self.app.inputTextRows(ctx, width);
        if (rows <= 1) return self.app.inputs.input.draw(ctx);
        return self.drawMultiline(ctx);
    }

    fn drawMultiline(self: *CommandInputText, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 0;
        const height: u16 = @max(ctx.max.height orelse 1, 1);
        var surface = try vxfw.Surface.init(ctx.arena, self.app.inputs.input.widget(), .{ .width = width, .height = height });
        if (width == 0) return surface;

        const first = self.app.inputs.input.buf.firstHalf();
        const second = self.app.inputs.input.buf.secondHalf();

        const combined = try ctx.arena.alloc(u8, first.len + second.len);
        @memcpy(combined[0..first.len], first);
        @memcpy(combined[first.len..], second);

        const cursor_pos = wrappedTextPositionAt(ctx, combined, first.len, width);
        const total_lines = wrappedTextRows(ctx, combined, width);
        const first_visible = firstVisibleLine(cursor_pos.row, total_lines, height);

        drawInputWrapped(&surface, ctx, combined, .{
            .first_visible = first_visible,
            .height = height,
            .width = width,
        });

        surface.cursor = .{ .row = cursor_pos.row -| first_visible, .col = cursor_pos.col };
        return surface;
    }
};

pub const VerticalMove = enum { up, down };

/// Byte offset where the given visual (wrapped) row begins. Mirrors the
/// wrapping rules in `wrappedPosition`/`drawInputWrapped` so navigation lands
/// the cursor exactly where the text is drawn. Returns `text.len` when the row
/// is past the end.
pub fn visualRowStart(text: []const u8, target_row: u16, width: u16) usize {
    if (target_row == 0 or width == 0) return 0;
    var row: u16 = 0;
    var col: u16 = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\n') {
            row += 1;
            index += 1;
            if (row == target_row) return index;
            col = 0;
            continue;
        }

        const spaces_start = index;
        while (index < text.len and wrapSpace(text[index])) index += 1;
        const spaces = text[spaces_start..index];
        const word_start = index;
        while (index < text.len and text[index] != '\n' and !wrapSpace(text[index])) index += 1;
        const word = text[word_start..index];
        if (word.len == 0) {
            if (advanceRowStart(spaces, spaces_start, &row, &col, width, target_row)) |off| return off;
            continue;
        }

        const spaces_width = gw(spaces);
        const word_width = gw(word);
        if (col > 0) {
            if (col + spaces_width + word_width > width) {
                row += 1;
                col = 0;
                if (row == target_row) return word_start;
            } else {
                col = @min(width, col + spaces_width);
            }
        }
        if (advanceRowStart(word, word_start, &row, &col, width, target_row)) |off| return off;
    }
    return text.len;
}

/// Walks a run grapheme-by-grapheme, soft-wrapping like the renderer. Returns
/// the absolute byte offset of the grapheme that opens `target_row`, or null if
/// the run does not reach it. `base` is the run's offset within the full text.
fn advanceRowStart(text: []const u8, base: usize, row: *u16, col: *u16, width: u16, target_row: u16) ?usize {
    var iter = vaxis.unicode.graphemeIterator(text);
    var local: usize = 0;
    while (iter.next()) |grapheme| {
        const cell_width = gw(grapheme.bytes(text));
        if (cell_width == 0) {
            local += grapheme.len;
            continue;
        }
        if (col.* + cell_width > width) {
            row.* += 1;
            col.* = 0;
            if (row.* == target_row) return base + local;
        }
        col.* = @min(width, col.* + cell_width);
        local += grapheme.len;
    }
    return null;
}

/// Byte offset within a single visual row `[row_start, row_end)` whose column is
/// the largest not exceeding `desired_col` — i.e. where a vertical move lands.
pub fn byteAtVisualColumn(text: []const u8, row_start: usize, row_end: usize, desired_col: u16) usize {
    const slice = text[row_start..row_end];
    var iter = vaxis.unicode.graphemeIterator(slice);
    var offset: usize = row_start;
    var col: u16 = 0;
    while (iter.next()) |grapheme| {
        const cell_width = gw(grapheme.bytes(slice));
        if (col + cell_width > desired_col) break;
        col += cell_width;
        offset += grapheme.len;
    }
    return offset;
}

pub fn firstVisibleLine(cursor_line: u16, total: u16, visible: u16) u16 {
    if (visible == 0 or total <= visible) return 0;
    if (cursor_line < visible) return 0;
    return @min(cursor_line - visible + 1, total - visible);
}

pub const WrappedTextPosition = struct {
    row: u16,
    col: u16,
};

const WrappedInputDraw = struct {
    first_visible: u16,
    height: u16,
    width: u16,
};

/// Cell width of a string under the unicode width method — the same metric the
/// renderer uses (`DrawContext.stringWidth` is a static wrapper over this).
fn gw(s: []const u8) u16 {
    return @intCast(vaxis.gwidth.gwidth(s, .unicode));
}

pub fn wrappedTextRows(ctx: vxfw.DrawContext, text: []const u8, width: u16) u16 {
    _ = ctx;
    return wrappedPosition(text, text.len, width).row + 1;
}

pub fn wrappedTextPositionAt(ctx: vxfw.DrawContext, text: []const u8, cursor: usize, width: u16) WrappedTextPosition {
    _ = ctx;
    return wrappedPosition(text, cursor, width);
}

/// Maps a byte offset to its visual (row, col) under word-wrapping at `width`.
/// Context-free so cursor navigation can reuse the renderer's exact layout.
pub fn wrappedPosition(text: []const u8, cursor: usize, width: u16) WrappedTextPosition {
    if (width == 0) return .{ .row = 0, .col = 0 };

    var row: u16 = 0;
    var col: u16 = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (cursor <= index) return .{ .row = row, .col = col };
        if (text[index] == '\n') {
            row += 1;
            col = 0;
            index += 1;
            continue;
        }

        const spaces_start = index;
        while (index < text.len and wrapSpace(text[index])) index += 1;
        if (cursor <= index) return advancePosition(text[spaces_start..cursor], row, col, width);

        const spaces = text[spaces_start..index];
        const word_start = index;
        while (index < text.len and text[index] != '\n' and !wrapSpace(text[index])) index += 1;
        const word = text[word_start..index];
        if (word.len == 0) {
            const pos = advancePosition(spaces, row, col, width);
            row = pos.row;
            col = pos.col;
            continue;
        }

        const spaces_width = gw(spaces);
        const word_width = gw(word);
        if (col > 0) {
            if (col + spaces_width + word_width > width) {
                row += 1;
                col = 0;
            } else {
                col = @min(width, col + spaces_width);
            }
        }
        if (cursor <= index) return advancePosition(text[word_start..cursor], row, col, width);

        const pos = advancePosition(word, row, col, width);
        row = pos.row;
        col = pos.col;
    }
    return .{ .row = row, .col = col };
}

fn advancePosition(text: []const u8, row_start: u16, col_start: u16, width: u16) WrappedTextPosition {
    var row = row_start;
    var col = col_start;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const cell_width = gw(grapheme.bytes(text));
        if (cell_width == 0) continue;
        if (col + cell_width > width) {
            row += 1;
            col = 0;
        }
        col = @min(width, col + cell_width);
    }
    return .{ .row = row, .col = col };
}

fn drawInputWrapped(surface: *vxfw.Surface, ctx: vxfw.DrawContext, text: []const u8, draw: WrappedInputDraw) void {
    if (draw.width == 0) return;

    var row: u16 = 0;
    var col: u16 = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\n') {
            row += 1;
            col = 0;
            index += 1;
            continue;
        }

        const spaces_start = index;
        while (index < text.len and wrapSpace(text[index])) index += 1;
        const spaces = text[spaces_start..index];

        const word_start = index;
        while (index < text.len and text[index] != '\n' and !wrapSpace(text[index])) index += 1;
        const word = text[word_start..index];
        if (word.len == 0) {
            drawRunWrapped(surface, ctx, spaces, draw, &row, &col);
            continue;
        }

        const spaces_width: u16 = @intCast(ctx.stringWidth(spaces));
        const word_width: u16 = @intCast(ctx.stringWidth(word));
        if (col > 0) {
            if (col + spaces_width + word_width > draw.width) {
                row += 1;
                col = 0;
            } else {
                drawRunWrapped(surface, ctx, spaces, draw, &row, &col);
            }
        }
        drawRunWrapped(surface, ctx, word, draw, &row, &col);
    }
}

fn drawRunWrapped(surface: *vxfw.Surface, ctx: vxfw.DrawContext, text: []const u8, draw: WrappedInputDraw, row: *u16, col: *u16) void {
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const cell_width: u16 = @intCast(ctx.stringWidth(bytes));
        if (cell_width == 0) continue;
        if (col.* + cell_width > draw.width) {
            row.* += 1;
            col.* = 0;
        }
        if (row.* >= draw.first_visible) {
            const visible_row = row.* - draw.first_visible;
            if (visible_row >= draw.height) break;
            surface.writeCell(col.*, visible_row, .{ .char = .{ .grapheme = bytes, .width = @intCast(cell_width) } });
        }
        col.* = @min(draw.width, col.* + cell_width);
    }
}

fn wrapSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

pub const InputWidget = struct {
    app: *App,

    pub fn widget(self: *InputWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawInput,
        };
    }

    fn drawInput(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *InputWidget = @ptrCast(@alignCast(ptr));
        const max_width = ctx.max.width orelse 0;
        const height: u16 = ctx.max.height orelse 4;

        const queued_visible = self.app.thread.queued.items.len > 0;
        const input_row: u16 = if (queued_visible) 1 else 0;
        const avail: u16 = height -| input_row;
        const input_width = max_width -| 4;
        const text_rows: u16 = @min(try self.app.inputTextRows(ctx, input_width), @max(@as(u16, 1), avail -| 2));
        const border_height: u16 = text_rows + 2;

        if (height < input_row + border_height) {
            return try self.drawInputBorder(ctx, max_width, @min(height, border_height), text_rows);
        }

        const base_row: u16 = input_row + border_height;
        const show_hint = height >= base_row + 1;
        const show_diff = show_hint and self.app.diffCountsVisible();
        const show_badge = show_hint and self.app.runningBackgroundCount() > 0;
        // The pink lanes chip only makes sense while fullscreened (not tiled)
        // with other lanes hidden behind the active one.
        const show_lanes = show_hint and !self.app.split and self.app.threads.items.len > 1;
        const children_count: usize = 1 +
            @as(usize, if (show_hint) 1 else 0) +
            @as(usize, if (show_diff) 1 else 0) +
            @as(usize, if (show_badge) 1 else 0) +
            @as(usize, if (show_lanes) 1 else 0) +
            @as(usize, if (queued_visible) 1 else 0);
        const children = try ctx.arena.alloc(vxfw.SubSurface, children_count);
        var child_index: usize = 0;
        if (queued_visible) {
            children[child_index] = .{
                .origin = .{ .row = 0, .col = 1 },
                .surface = try self.drawQueuedMessage(ctx, max_width -| 2),
                .z_index = 0,
            };
            child_index += 1;
        }
        children[child_index] = .{
            .origin = .{ .row = input_row, .col = 0 },
            .surface = try self.drawInputBorder(ctx, max_width, border_height, text_rows),
            .z_index = 0,
        };
        child_index += 1;
        if (show_hint) {
            const padding_x: u16 = @min(@as(u16, 1), max_width);
            const inner_width = max_width -| (padding_x * 2);
            try self.drawInputHint(ctx, children, child_index, base_row, padding_x, inner_width);
            child_index += 1;
        }
        if (show_diff) {
            try self.drawDiffCounts(ctx, children, child_index, base_row, max_width);
            child_index += 1;
        }
        // Lay the two bottom-left pills out left-to-right: pink lanes chip first,
        // then the blue background-jobs badge shifted past it when both show.
        var lanes_width: u16 = 0;
        if (show_lanes) {
            const lanes_surface = try self.drawLanesBadge(ctx, max_width -| 2);
            lanes_width = lanes_surface.size.width;
            children[child_index] = .{
                .origin = .{ .row = base_row, .col = 1 },
                .surface = lanes_surface,
                .z_index = 2,
            };
            child_index += 1;
            self.app.nav.lanes_chip_rect = .{
                .row = self.app.input_surface_row + base_row,
                .col = 1,
                .width = lanes_width,
            };
        }
        if (show_badge) {
            const badge_col: u16 = if (show_lanes) 1 + lanes_width + 1 else 1;
            children[child_index] = .{
                .origin = .{ .row = base_row, .col = badge_col },
                .surface = try self.drawBackgroundBadge(ctx, max_width -| badge_col -| 1),
                .z_index = 2,
            };
            child_index += 1;
        }
        return .{
            .size = .{ .width = max_width, .height = height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn drawInputBorder(self: *InputWidget, ctx: vxfw.DrawContext, max_width: u16, border_height: u16, text_rows: u16) std.mem.Allocator.Error!vxfw.Surface {
        const prompt_text: []const u8 = if (self.app.mode == .normal) ">" else " ";
        var prompt: vxfw.Text = .{ .text = prompt_text, .softwrap = false, .width_basis = .parent };
        var prompt_box: vxfw.SizedBox = .{ .child = prompt.widget(), .size = .{ .width = 2, .height = 1 } };
        var command_input: CommandInputText = .{ .app = self.app };
        var input_box: vxfw.SizedBox = .{ .child = command_input.widget(), .size = .{ .width = max_width -| 2, .height = text_rows } };
        var row: vxfw.FlexRow = .{
            .children = &.{
                .{ .widget = prompt_box.widget(), .flex = 0 },
                .{ .widget = input_box.widget(), .flex = 1 },
            },
        };
        var row_box: vxfw.SizedBox = .{ .child = row.widget(), .size = .{ .width = max_width -| 2, .height = text_rows } };
        var border: vxfw.Border = .{
            .child = row_box.widget(),
            .style = StylePalette.thinking_body,
        };
        var box: vxfw.SizedBox = .{ .child = border.widget(), .size = .{ .width = max_width, .height = border_height } };
        var surface = try box.widget().draw(ctx.withConstraints(.{ .width = max_width, .height = border_height }, .{ .width = max_width, .height = border_height }));

        const status_text = if (tui_status.modelStatus(self.app.liveRuntime(), self.app.cached_config)) |status|
            tui_status.formatModelStatus(ctx.arena, status) catch "no model"
        else
            "no model";
        const live_context_max: u32 = if (self.app.liveRuntime()) |rt|
            rt.agent.context_window_tokens
        else if (self.app.metrics.context_tokens_max > 0)
            self.app.metrics.context_tokens_max
        else
            128000;

        const live_context_used: u32 = if (self.app.liveRuntime()) |rt|
            rt.agent.currentContextTokens()
        else if (self.app.metrics.context_tokens_used > 0)
            self.app.metrics.context_tokens_used
        else
            0;

        const pct: u32 = if (live_context_max > 0 and live_context_used > 0)
            @min(100, (live_context_used * 100) / live_context_max)
        else
            0;
        const ctx_bar = formatContextBar(ctx.arena, pct) catch "";
        const label_text = if (ctx_bar.len > 0 and status_text.len > 0)
            std.fmt.allocPrint(ctx.arena, "{s}  {s}", .{ status_text, ctx_bar }) catch status_text
        else if (status_text.len > 0)
            status_text
        else
            ctx_bar;
        panel.writeBorderLabelRight(&surface, ctx, 0, label_text, StylePalette.model_status);
        // Bottom-right: git branch info at the edge.
        const bottom = border_height -| 1;
        const right_edge = max_width -| 3; // last interior cell before the corner margin
        _ = panel.writeBorderTextEndingAt(&surface, ctx, bottom, right_edge, self.app.metrics.git_label, StylePalette.thinking_body);
        return surface;
    }

    fn formatContextBar(arena: std.mem.Allocator, pct: u32) ![]const u8 {
        if (pct == 0) return "";
        const filled: usize = (pct * 5) / 100;
        var bar_buf = [5][]const u8{ "░", "░", "░", "░", "░" };
        var i: usize = 0;
        while (i < filled and i < 5) : (i += 1) bar_buf[i] = "▓";
        return std.fmt.allocPrint(arena, "[{s}{s}{s}{s}{s} {d}%]", .{
            bar_buf[0], bar_buf[1], bar_buf[2], bar_buf[3], bar_buf[4], pct,
        });
    }

    fn drawQueuedMessage(self: *InputWidget, ctx: vxfw.DrawContext, width: u16) std.mem.Allocator.Error!vxfw.Surface {
        const items = self.app.thread.queued.items;
        const sel = @min(self.app.nav.queued_selection, items.len - 1);
        const message = items[sel];
        // Position suffix only when there's more than one to navigate.
        const position = if (items.len > 1)
            try std.fmt.allocPrint(ctx.arena, " {d}/{d}", .{ sel + 1, items.len })
        else
            "";
        const text = if (message.steer)
            try std.fmt.allocPrint(ctx.arena, "↩ {s}{s}", .{ message.text, position })
        else
            try std.fmt.allocPrint(ctx.arena, "[...] {s} (CTRL → to steer){s}", .{ message.text, position });
        var queued_text: vxfw.Text = .{ .text = text, .style = .{ .fg = StylePalette.thinking_body.fg, .dim = true }, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent };
        return queued_text.widget().draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
    }

    fn drawInputHint(self: *InputWidget, ctx: vxfw.DrawContext, children: []vxfw.SubSurface, child_index: usize, row: u16, col: u16, width: u16) std.mem.Allocator.Error!void {
        const is_pending_quit = self.app.getPendingQuitAt() != null;
        const style = if (is_pending_quit) StylePalette.warning else StylePalette.thinking_body;
        var hint_text: vxfw.Text = .{ .text = inputHintText(self.app), .style = style, .text_align = .center, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent };
        children[child_index] = .{
            .origin = .{ .row = row, .col = col },
            .surface = try hint_text.widget().draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 })),
            .z_index = 0,
        };
    }

    /// Bottom-left pink pill: the count of open lanes, shown while the active
    /// lane is fullscreened. Black-on-pink so it reads as a control affordance;
    /// clicking it (mouse) or pressing Ctrl+L restores the split view.
    fn drawLanesBadge(self: *InputWidget, ctx: vxfw.DrawContext, max_width: u16) std.mem.Allocator.Error!vxfw.Surface {
        const text = try std.fmt.allocPrint(ctx.arena, " {d} Lanes ", .{self.app.threads.items.len});
        const text_width: u16 = @intCast(@min(ctx.stringWidth(text), max_width));
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = text_width, .height = 1 });
        if (text_width == 0) return surface;
        panel.fillRow(&surface, 0, StylePalette.lanes_badge);
        panel.lineStyledAt(&surface, 0, text, ctx, 0, StylePalette.lanes_badge) catch {};
        return surface;
    }

    /// Bottom-left status pill: live background-job count + the Ctrl+O hint, in
    /// black-on-blue so it reads as a control affordance.
    fn drawBackgroundBadge(self: *InputWidget, ctx: vxfw.DrawContext, max_width: u16) std.mem.Allocator.Error!vxfw.Surface {
        const count = self.app.runningBackgroundCount();
        const text = try std.fmt.allocPrint(ctx.arena, " {d} background job{s} · Ctrl+O ", .{ count, if (count == 1) "" else "s" });
        const text_width: u16 = @intCast(@min(ctx.stringWidth(text), max_width));
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = text_width, .height = 1 });
        if (text_width == 0) return surface;
        panel.fillRow(&surface, 0, StylePalette.background_badge);
        panel.lineStyledAt(&surface, 0, text, ctx, 0, StylePalette.background_badge) catch {};
        return surface;
    }

    fn drawDiffCounts(self: *InputWidget, ctx: vxfw.DrawContext, children: []vxfw.SubSurface, child_index: usize, row: u16, width: u16) std.mem.Allocator.Error!void {
        const diff_width: u16 = 13;
        const surface_width = @min(diff_width, width);
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = surface_width, .height = 1 });
        if (surface_width > 0) writeDiffCounts(&surface, ctx, self.app.metrics.diff_counts);
        children[child_index] = .{
            .origin = .{ .row = row, .col = width -| 2 -| surface_width },
            .surface = surface,
            .z_index = 1,
        };
    }
};
