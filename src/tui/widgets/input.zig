//! The command input box and its word-wrapping math.
//!
//! Pulled out of `tui.zig` (R6.1 of `_pm/Projects/tui-split`) — the
//! `InputWidget` (bordered input field, queued-message preview, hint line,
//! lanes/background badges, diff counts), `CommandInputText` (the prompt
//! renderer inside the input border — the single owned draw path for
//! one-row and multi-row text, #512), the `WrappedInputDraw` /
//! `WrappedTextPosition` / `VerticalMove` types, and the 13 free functions
//! that compute word-wrapped cursor positions and draw wrapped text.
//!
//! Symbols a caller outside this file reaches:
//! - `InputWidget` — instantiated by `drawRoot`.
//! - `VerticalMove`, `wrappedPosition`, `visualRowStart`, `byteAtVisualColumn`,
//!   `wrappedTextRows`, `WrappedTextPosition` — used by
//!   `App.moveInputCursorVertical`.
//! - `writeDiffCounts`, `inputHintText` — used by inline tests in `tui.zig`.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui_style = @import("../style.zig");
const status_bar = @import("status_bar.zig");
const symbols = @import("../../symbols.zig");
const app_state = @import("../app_state.zig");
const thread_mod = @import("../thread.zig");
const provider_picker = @import("provider_picker.zig");

const DiffCounts = app_state.DiffCounts;
const StatusBarWidget = status_bar.StatusBarWidget;

/// Everything the hint line selects on, gathered by the frame build. Pure —
/// the returned text depends only on these fields.
pub const HintInputs = struct {
    pending_quit: bool = false,
    mode: app_state.Mode,
    session_action: app_state.NavState.SessionAction = .browsing,
    provider_stage: provider_picker.Stage = .list,
    lanes_purpose: app_state.NavState.LanesPurpose = .manage,
};

/// The mode-dependent hint line under the input box. Pure: a function of
/// `HintInputs` only, so the `hintText pins every mode's text` test in this
/// file pins every mode without an App.
pub fn hintText(hint: HintInputs) []const u8 {
    if (hint.pending_quit) return "Press Ctrl+C or Ctrl+D again to exit";
    return switch (hint.mode) {
        .command => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Execute" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
        .session_picker => switch (hint.session_action) {
            .browsing => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Resume" ++ symbols.separator_dot_padded ++ "[D] Delete" ++ symbols.separator_dot_padded ++ "[R] Rename" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
            .renaming => "[ENTER] Save" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
            .deleting => "[Y] Delete" ++ symbols.separator_dot_padded ++ "[N/ESC] Cancel",
            .blocked => "[Any key] Dismiss",
            .locating_project => "[ENTER] Bind & Resume" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
        },
        .provider_picker => switch (hint.provider_stage) {
            .list => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Select" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
            .form => "[ENTER] Save API Key" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
        },
        .model_picker => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "←/→ Effort" ++ symbols.separator_dot_padded ++ "[ENTER] Select" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
        .theme_picker => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Select" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
        .link_picker => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER/Y] Copy" ++ symbols.separator_dot_padded ++ "[O] Open" ++ symbols.separator_dot_padded ++ "[ESC] Close",
        .tree_picker => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Jump to branch" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
        .save_message => "[ENTER] Save" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
        .lanes => switch (hint.lanes_purpose) {
            .manage => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[M] Merge into current" ++ symbols.separator_dot_padded ++ "[X] Delete" ++ symbols.separator_dot_padded ++ "[ESC] Back",
            .merge_dest => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Merge into" ++ symbols.separator_dot_padded ++ "[ESC] Back",
        },
        .diff_viewer => "[ / ] Hunks" ++ symbols.separator_dot_padded ++ "Ctrl+W Comment" ++ symbols.separator_dot_padded ++ "Ctrl+P Files" ++ symbols.separator_dot_padded ++ "Ctrl+S Send" ++ symbols.separator_dot_padded ++ "[ESC] Close",
        .help => "[ESC] / [ENTER] Close Help",
        .settings => "Tab Section" ++ symbols.separator_dot_padded ++ "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Toggle/Edit" ++ symbols.separator_dot_padded ++ "Ctrl+S Save" ++ symbols.separator_dot_padded ++ "[ESC] Close",
        .mcp => "[Space] Toggle" ++ symbols.separator_dot_padded ++ "Ctrl+R Reconnect" ++ symbols.separator_dot_padded ++ "[ESC] Close",
        .plugins => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ESC] Close",
        .search => "↑↓ Navigate" ++ symbols.separator_dot_padded ++ "[ENTER] Jump to message" ++ symbols.separator_dot_padded ++ "[ESC] Cancel",
        .normal => "Type prompt, @file, $skill or / for menu" ++ symbols.separator_dot_padded ++ "Ctrl+K Menu" ++ symbols.separator_dot_padded ++ "Ctrl+O Background" ++ symbols.separator_dot_padded ++ "Shift+Tab Lanes" ++ symbols.separator_dot_padded ++ "Ctrl+F Search",
    };
}

test "hintText pins every mode's text" {
    const dot = symbols.separator_dot_padded;
    // The pending-quit prompt wins over every mode.
    try std.testing.expectEqualStrings("Press Ctrl+C or Ctrl+D again to exit", hintText(.{ .pending_quit = true, .mode = .normal }));
    try std.testing.expectEqualStrings("↑↓ Navigate" ++ dot ++ "[ENTER] Execute" ++ dot ++ "[ESC] Cancel", hintText(.{ .mode = .command }));
    try std.testing.expectEqualStrings("↑↓ Navigate" ++ dot ++ "[ENTER] Resume" ++ dot ++ "[D] Delete" ++ dot ++ "[R] Rename" ++ dot ++ "[ESC] Cancel", hintText(.{ .mode = .session_picker, .session_action = .browsing }));
    try std.testing.expectEqualStrings("[ENTER] Save" ++ dot ++ "[ESC] Cancel", hintText(.{ .mode = .session_picker, .session_action = .renaming }));
    try std.testing.expectEqualStrings("[Y] Delete" ++ dot ++ "[N/ESC] Cancel", hintText(.{ .mode = .session_picker, .session_action = .deleting }));
    try std.testing.expectEqualStrings("[Any key] Dismiss", hintText(.{ .mode = .session_picker, .session_action = .blocked }));
    try std.testing.expectEqualStrings("↑↓ Navigate" ++ dot ++ "[ENTER] Select" ++ dot ++ "[ESC] Cancel", hintText(.{ .mode = .provider_picker, .provider_stage = .list }));
    try std.testing.expectEqualStrings("[ENTER] Save API Key" ++ dot ++ "[ESC] Cancel", hintText(.{ .mode = .provider_picker, .provider_stage = .form }));
    try std.testing.expectEqualStrings("↑↓ Navigate" ++ dot ++ "←/→ Effort" ++ dot ++ "[ENTER] Select" ++ dot ++ "[ESC] Cancel", hintText(.{ .mode = .model_picker }));
    try std.testing.expectEqualStrings("↑↓ Navigate" ++ dot ++ "[ENTER] Select" ++ dot ++ "[ESC] Cancel", hintText(.{ .mode = .theme_picker }));
    try std.testing.expectEqualStrings("↑↓ Navigate" ++ dot ++ "[ENTER/Y] Copy" ++ dot ++ "[O] Open" ++ dot ++ "[ESC] Close", hintText(.{ .mode = .link_picker }));
    try std.testing.expectEqualStrings("↑↓ Navigate" ++ dot ++ "[ENTER] Jump to branch" ++ dot ++ "[ESC] Cancel", hintText(.{ .mode = .tree_picker }));
    try std.testing.expectEqualStrings("[ENTER] Save" ++ dot ++ "[ESC] Cancel", hintText(.{ .mode = .save_message }));
    try std.testing.expectEqualStrings("↑↓ Navigate" ++ dot ++ "[M] Merge into current" ++ dot ++ "[X] Delete" ++ dot ++ "[ESC] Back", hintText(.{ .mode = .lanes, .lanes_purpose = .manage }));
    try std.testing.expectEqualStrings("↑↓ Navigate" ++ dot ++ "[ENTER] Merge into" ++ dot ++ "[ESC] Back", hintText(.{ .mode = .lanes, .lanes_purpose = .merge_dest }));
    try std.testing.expectEqualStrings("[ / ] Hunks" ++ dot ++ "Ctrl+W Comment" ++ dot ++ "Ctrl+P Files" ++ dot ++ "Ctrl+S Send" ++ dot ++ "[ESC] Close", hintText(.{ .mode = .diff_viewer }));
    try std.testing.expectEqualStrings("[ESC] / [ENTER] Close Help", hintText(.{ .mode = .help }));
    try std.testing.expectEqualStrings("Tab Section" ++ dot ++ "↑↓ Navigate" ++ dot ++ "[ENTER] Toggle/Edit" ++ dot ++ "Ctrl+S Save" ++ dot ++ "[ESC] Close", hintText(.{ .mode = .settings }));
    try std.testing.expectEqualStrings("[Space] Toggle" ++ dot ++ "Ctrl+R Reconnect" ++ dot ++ "[ESC] Close", hintText(.{ .mode = .mcp }));
    try std.testing.expectEqualStrings("↑↓ Navigate" ++ dot ++ "[ESC] Close", hintText(.{ .mode = .plugins }));
    try std.testing.expectEqualStrings("↑↓ Navigate" ++ dot ++ "[ENTER] Jump to message" ++ dot ++ "[ESC] Cancel", hintText(.{ .mode = .search }));
    try std.testing.expectEqualStrings("Type prompt, @file, $skill or / for menu" ++ dot ++ "Ctrl+K Menu" ++ dot ++ "Ctrl+O Background" ++ dot ++ "Shift+Tab Lanes" ++ dot ++ "Ctrl+F Search", hintText(.{ .mode = .normal }));
}

pub fn writeDiffCounts(surface: *vxfw.Surface, ctx: vxfw.DrawContext, counts: DiffCounts, p: *const tui_style.Palette) void {
    const additions = std.fmt.allocPrint(ctx.arena, "+{d}", .{@min(counts.additions, 99999)}) catch return;
    const deletions = std.fmt.allocPrint(ctx.arena, "-{d}", .{@min(counts.deletions, 99999)}) catch return;
    const total_width = additions.len + 1 + deletions.len;
    const start_col: u16 = if (total_width >= surface.size.width)
        0
    else
        @intCast(surface.size.width - total_width);
    writeAscii(surface, additions, p.tool, start_col);
    writeAscii(surface, deletions, p.tool_failed, start_col + @as(u16, @intCast(additions.len + 1)));
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

/// Per-frame view model for `InputWidget` (INV-WIDGET-1): render-ready facts
/// computed by the frame build (`root_layout.buildInputProps`), so the widget
/// is a pure function of its props and never references the App. Strings are
/// arena-owned by the frame; the two pointer fields are write-backs whose
/// targets (App fields) outlive the draw.
pub const InputProps = struct {
    /// The live text field — the prompt's gap buffer. Its widget is the
    /// drawn surface's owner (the focus handoff target); its own draw is
    /// not called anymore (#512).
    input_field: *vxfw.TextField,
    /// Combined buffer halves (arena-owned), plus the cursor's byte offset.
    input_text: []const u8,
    input_cursor: usize,
    /// Queued (steer) messages and the selected index.
    queued: []const thread_mod.Thread.QueuedMessage = &.{},
    queued_selection: usize = 0,
    /// Prompt glyph: `>` in normal mode, blank otherwise.
    prompt_text: []const u8 = ">",
    hint_text: []const u8 = "",
    /// Arms the red "press again to exit" hint styling.
    pending_quit: bool = false,
    /// Non-null renders the +/- diff-count overlay.
    diff_counts: ?DiffCounts = null,
    /// Running background-job count (drives the blue badge).
    background_jobs: usize = 0,
    /// Pink lanes chip: fullscreen (`.tab`) with other lanes open.
    show_lanes_chip: bool = false,
    lanes_count: usize = 0,
    /// Active durable skill names shown in the status area, never as chat rows.
    skill_inventory: []const []const u8 = &.{},
    // Render-ready status-line strings (precomputed by the frame build).
    status_text: []const u8 = "no model",
    meter_text: []const u8 = "",
    meter_style: vaxis.Style = .{},
    velocity_text: []const u8 = "",
    git_label: []const u8 = "",
    palette: *const tui_style.Palette = &tui_style.default_palette,
};

pub const CommandInputText = struct {
    props: *const InputProps,

    fn widget(self: *CommandInputText) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawInputText,
        };
    }

    fn drawInputText(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *CommandInputText = @ptrCast(@alignCast(ptr));
        // One owned draw path for one-row and multi-row prompts alike
        // (#512): the wrapped renderer handles a single row identically, so
        // the two wrap/cursor models can no longer drift. The vendored
        // TextField stays the gap buffer; its draw is no longer called, and
        // its surface identity (the focus handoff target) is kept.
        return self.drawMultiline(ctx);
    }

    fn drawMultiline(self: *CommandInputText, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 0;
        const height: u16 = @max(ctx.max.height orelse 1, 1);
        var surface = try vxfw.Surface.init(ctx.arena, self.props.input_field.widget(), .{ .width = width, .height = height });
        if (width == 0) return surface;

        const combined = self.props.input_text;
        const cursor_pos = wrappedTextPositionAt(ctx, combined, self.props.input_cursor, width);
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
            if (col +| spaces_width +| word_width > width) {
                row +|= 1;
                col = 0;
                if (row == target_row) return word_start;
            } else {
                col = @min(width, col +| spaces_width);
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
        if (col.* +| cell_width > width) {
            row.* +|= 1;
            col.* = 0;
            if (row.* == target_row) return base + local;
        }
        col.* = @min(width, col.* +| cell_width);
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
    return @intCast(@min(vaxis.gwidth.gwidth(s, .unicode), std.math.maxInt(u16)));
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
            row +|= 1;
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
            if (col +| spaces_width +| word_width > width) {
                row +|= 1;
                col = 0;
            } else {
                col = @min(width, col +| spaces_width);
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
        if (col +| cell_width > width) {
            row +|= 1;
            col = 0;
        }
        col = @min(width, col +| cell_width);
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
            row +|= 1;
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

        const spaces_width: u16 = @intCast(@min(ctx.stringWidth(spaces), std.math.maxInt(u16)));
        const word_width: u16 = @intCast(@min(ctx.stringWidth(word), std.math.maxInt(u16)));
        if (col > 0) {
            if (col +| spaces_width +| word_width > draw.width) {
                row +|= 1;
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
        const cell_width: u16 = @intCast(@min(ctx.stringWidth(bytes), std.math.maxInt(u16)));
        if (cell_width == 0) continue;
        if (col.* +| cell_width > draw.width) {
            row.* +|= 1;
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
    props: InputProps,

    pub fn widget(self: *InputWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawInput,
        };
    }

    const InputLayout = struct {
        max_width: u16,
        height: u16,
        input_row: u16,
        text_rows: u16,
        border_height: u16,
        base_row: u16,
        queued_visible: bool,
        show_hint: bool,
        show_diff: bool,
        show_badge: bool,
        show_lanes: bool,
        children_count: usize,
    };

    fn computeInputLayout(self: *InputWidget, ctx: vxfw.DrawContext) InputLayout {
        const max_width = ctx.max.width orelse 0;
        const height: u16 = ctx.max.height orelse 4;

        const queued_visible = self.props.queued.len > 0;
        const input_row: u16 = if (queued_visible) 1 else 0;
        const avail: u16 = height -| input_row;
        const input_width = max_width -| 4;
        const text_rows: u16 = @min(wrappedTextRows(ctx, self.props.input_text, input_width), @max(@as(u16, 1), avail -| 2));
        const border_height: u16 = text_rows + 2;
        const base_row: u16 = input_row + border_height;

        const show_hint = height >= base_row + 1;
        const show_diff = show_hint and self.props.diff_counts != null;
        const show_badge = show_hint and self.props.background_jobs > 0;
        // The pink lanes chip only makes sense while fullscreened (`.tab`,
        // not split) with other lanes hidden behind the active one.
        const show_lanes = show_hint and self.props.show_lanes_chip;

        const children_count: usize = 1 +
            @as(usize, if (show_hint) 1 else 0) +
            @as(usize, if (show_diff) 1 else 0) +
            @as(usize, if (show_badge) 1 else 0) +
            @as(usize, if (show_lanes) 1 else 0) +
            @as(usize, if (queued_visible) 1 else 0);

        return .{
            .max_width = max_width,
            .height = height,
            .input_row = input_row,
            .text_rows = text_rows,
            .border_height = border_height,
            .base_row = base_row,
            .queued_visible = queued_visible,
            .show_hint = show_hint,
            .show_diff = show_diff,
            .show_badge = show_badge,
            .show_lanes = show_lanes,
            .children_count = children_count,
        };
    }

    fn assembleInputChildren(
        self: *InputWidget,
        ctx: vxfw.DrawContext,
        layout: InputLayout,
    ) std.mem.Allocator.Error![]vxfw.SubSurface {
        const children = try ctx.arena.alloc(vxfw.SubSurface, layout.children_count);
        var child_index: usize = 0;

        if (layout.queued_visible) {
            children[child_index] = .{
                .origin = .{ .row = 0, .col = 1 },
                .surface = try self.drawQueuedMessage(ctx, layout.max_width -| 2),
                .z_index = 0,
            };
            child_index += 1;
        }

        children[child_index] = .{
            .origin = .{ .row = layout.input_row, .col = 0 },
            .surface = try self.drawInputBorder(ctx, layout.max_width, layout.border_height, layout.text_rows),
            .z_index = 0,
        };
        child_index += 1;

        // Lay the two bottom-left pills out left-to-right: pink lanes chip first,
        // then the blue background-jobs badge shifted past it when both show.
        // Measure them before placing the hint so the hint shifts right and
        // shrinks to the remaining budget without overlapping either pill or diff counts.
        var left_reserved: u16 = 0;
        if (layout.show_lanes) {
            const lanes_surface = try self.drawLanesBadge(ctx, layout.max_width -| 2);
            const lanes_width = lanes_surface.size.width;
            children[child_index] = .{
                .origin = .{ .row = layout.base_row, .col = 1 },
                .surface = lanes_surface,
                .z_index = 2,
            };
            child_index += 1;
            left_reserved +|= lanes_width + 1;
        }

        if (layout.show_badge) {
            const badge_col: u16 = 1 + left_reserved;
            const badge_surface = try self.drawBackgroundBadge(ctx, layout.max_width -| badge_col -| 1);
            children[child_index] = .{
                .origin = .{ .row = layout.base_row, .col = badge_col },
                .surface = badge_surface,
                .z_index = 2,
            };
            child_index += 1;
            left_reserved +|= badge_surface.size.width + 1;
        }

        var right_reserved: u16 = 0;
        if (layout.show_diff) {
            try self.drawDiffCounts(ctx, children, child_index, layout.base_row, layout.max_width);
            right_reserved = children[child_index].surface.size.width +| 2;
            child_index += 1;
        }

        if (layout.show_hint) {
            const padding_x: u16 = @min(@as(u16, 1), layout.max_width);
            const hint_col: u16 = @max(padding_x, 1 + left_reserved);
            const right_limit: u16 = (layout.max_width -| padding_x) -| right_reserved;
            const hint_width: u16 = right_limit -| hint_col;
            try self.drawInputHint(ctx, children, child_index, layout.base_row, hint_col, hint_width);
            child_index += 1;
        }

        return children;
    }

    fn drawInput(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *InputWidget = @ptrCast(@alignCast(ptr));
        const layout = self.computeInputLayout(ctx);

        if (layout.height < layout.input_row + layout.border_height) {
            return try self.drawInputBorder(ctx, layout.max_width, @min(layout.height, layout.border_height), layout.text_rows);
        }

        const children = try self.assembleInputChildren(ctx, layout);
        return .{
            .size = .{ .width = layout.max_width, .height = layout.height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn drawInputBorder(self: *InputWidget, ctx: vxfw.DrawContext, max_width: u16, border_height: u16, text_rows: u16) std.mem.Allocator.Error!vxfw.Surface {
        const p = self.props.palette;
        var prompt: vxfw.Text = .{ .text = self.props.prompt_text, .style = p.user, .softwrap = false, .width_basis = .parent };
        var prompt_box: vxfw.SizedBox = .{ .child = prompt.widget(), .size = .{ .width = 2, .height = 1 } };
        var command_input: CommandInputText = .{ .props = &self.props };
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
            .style = p.border,
        };
        var box: vxfw.SizedBox = .{ .child = border.widget(), .size = .{ .width = max_width, .height = border_height } };
        const border_surface = try box.widget().draw(ctx.withConstraints(.{ .width = max_width, .height = border_height }, .{ .width = max_width, .height = border_height }));

        var status_bar_w: StatusBarWidget = .{
            .status_text = self.props.status_text,
            .meter_text = self.props.meter_text,
            .meter_style = self.props.meter_style,
            .velocity_text = self.props.velocity_text,
            .skill_inventory = self.props.skill_inventory,
            .palette = self.props.palette,
        };
        var status_box: vxfw.SizedBox = .{ .child = status_bar_w.widget(), .size = .{ .width = max_width, .height = 1 } };
        const status_surface = try status_box.widget().draw(ctx.withConstraints(.{ .width = max_width, .height = 1 }, .{ .width = max_width, .height = 1 }));

        const bottom = border_height -| 1;
        const git_label = self.props.git_label;
        var git_surface: ?vxfw.Surface = null;
        var git_origin_col: u16 = 0;
        if (git_label.len > 0) {
            var git_text: vxfw.Text = .{
                .text = git_label,
                .softwrap = false,
                .overflow = .ellipsis,
                .width_basis = .longest_line,
                .style = p.thinking_body,
            };
            const surf = try git_text.widget().draw(ctx.withConstraints(.{ .width = 0, .height = 1 }, .{ .width = max_width -| 2, .height = 1 }));
            if (surf.size.width > 0) {
                git_surface = surf;
                git_origin_col = (max_width -| 2) -| surf.size.width;
            }
        }

        const input_width = max_width -| 4;
        const total_lines = wrappedTextRows(ctx, self.props.input_text, input_width);
        var overflow_surface: ?vxfw.Surface = null;
        if (total_lines > text_rows and max_width >= 8) {
            const cursor_pos = wrappedTextPositionAt(ctx, self.props.input_text, self.props.input_cursor, input_width);
            const first_visible = firstVisibleLine(cursor_pos.row, total_lines, text_rows);
            const above = first_visible;
            const below = total_lines -| (first_visible + text_rows);
            const ov_text = if (above > 0 and below > 0)
                try std.fmt.allocPrint(ctx.arena, " ↑{d} ↓{d} ", .{ above, below })
            else if (above > 0)
                try std.fmt.allocPrint(ctx.arena, " ↑{d} ", .{above})
            else
                try std.fmt.allocPrint(ctx.arena, " ↓{d} ", .{below});
            const max_ov_w = if (git_surface != null) git_origin_col -| 2 else max_width -| 4;
            if (max_ov_w > 0) {
                var ov_w: vxfw.Text = .{
                    .text = ov_text,
                    .softwrap = false,
                    .overflow = .ellipsis,
                    .width_basis = .longest_line,
                    .style = .{ .fg = p.thinking_body.fg, .dim = true },
                };
                const surf = try ov_w.widget().draw(ctx.withConstraints(.{ .width = 0, .height = 1 }, .{ .width = max_ov_w, .height = 1 }));
                if (surf.size.width > 0) overflow_surface = surf;
            }
        }

        const child_count: usize = 2 + @as(usize, @intFromBool(git_surface != null)) + @as(usize, @intFromBool(overflow_surface != null));
        const children = try ctx.arena.alloc(vxfw.SubSurface, child_count);
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = border_surface,
            .z_index = 0,
        };
        children[1] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = status_surface,
            .z_index = 1,
        };
        var idx: usize = 2;
        if (git_surface) |surf| {
            children[idx] = .{
                .origin = .{ .row = bottom, .col = git_origin_col },
                .surface = surf,
                .z_index = 1,
            };
            idx += 1;
        }
        if (overflow_surface) |surf| {
            children[idx] = .{
                .origin = .{ .row = bottom, .col = 2 },
                .surface = surf,
                .z_index = 1,
            };
        }

        return vxfw.Surface{
            .size = .{ .width = max_width, .height = border_height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn drawQueuedMessage(self: *InputWidget, ctx: vxfw.DrawContext, width: u16) std.mem.Allocator.Error!vxfw.Surface {
        const p = self.props.palette;
        const items = self.props.queued;
        const sel = @min(self.props.queued_selection, items.len - 1);
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
        var queued_text: vxfw.Text = .{ .text = text, .style = .{ .fg = p.thinking_body.fg, .dim = true }, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent };
        return queued_text.widget().draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
    }

    fn drawInputHint(self: *InputWidget, ctx: vxfw.DrawContext, children: []vxfw.SubSurface, child_index: usize, row: u16, col: u16, width: u16) std.mem.Allocator.Error!void {
        const p = self.props.palette;
        const is_pending_quit = self.props.pending_quit;
        const style = if (is_pending_quit) p.warning else p.thinking_body;
        const text_to_draw = formatWidthAwareHint(self.props.hint_text, width, ctx.arena);
        var hint_text: vxfw.Text = .{ .text = text_to_draw, .style = style, .text_align = .center, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent };
        children[child_index] = .{
            .origin = .{ .row = row, .col = col },
            .surface = try hint_text.widget().draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 })),
            .z_index = 0,
        };
    }

    /// Bottom-left pink pill: the count of open lanes, shown while the active
    /// lane is fullscreened (`.tab`). Black-on-pink so it reads as a control
    /// affordance; clicking it (mouse) or pressing Ctrl+W restores the split
    /// view.
    fn drawLanesBadge(self: *InputWidget, ctx: vxfw.DrawContext, max_width: u16) std.mem.Allocator.Error!vxfw.Surface {
        const p = self.props.palette;
        const text = try std.fmt.allocPrint(ctx.arena, " {d} Lanes ", .{self.props.lanes_count});
        var pill_text: vxfw.Text = .{
            .text = text,
            .style = p.lanes_badge,
            .softwrap = false,
            .overflow = .ellipsis,
            .width_basis = .longest_line,
        };
        return pill_text.widget().draw(ctx.withConstraints(.{ .width = 0, .height = 1 }, .{ .width = max_width, .height = 1 }));
    }

    /// Bottom-left status pill: live background-job count + the Ctrl+O hint, in
    /// black-on-blue so it reads as a control affordance.
    fn drawBackgroundBadge(self: *InputWidget, ctx: vxfw.DrawContext, max_width: u16) std.mem.Allocator.Error!vxfw.Surface {
        const p = self.props.palette;
        const count = self.props.background_jobs;
        const text = try std.fmt.allocPrint(ctx.arena, " {d} background job{s} · Ctrl+O ", .{ count, if (count == 1) "" else "s" });
        var pill_text: vxfw.Text = .{
            .text = text,
            .style = p.background_badge,
            .softwrap = false,
            .overflow = .ellipsis,
            .width_basis = .longest_line,
        };
        return pill_text.widget().draw(ctx.withConstraints(.{ .width = 0, .height = 1 }, .{ .width = max_width, .height = 1 }));
    }

    fn drawDiffCounts(self: *InputWidget, ctx: vxfw.DrawContext, children: []vxfw.SubSurface, child_index: usize, row: u16, width: u16) std.mem.Allocator.Error!void {
        const diff_width: u16 = 13;
        const surface_width = @min(diff_width, width);
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = surface_width, .height = 1 });
        if (surface_width > 0) writeDiffCounts(&surface, ctx, self.props.diff_counts.?, self.props.palette);
        children[child_index] = .{
            .origin = .{ .row = row, .col = width -| 2 -| surface_width },
            .surface = surface,
            .z_index = 1,
        };
    }
};

/// Format hint text for available width (in display cells). When the full hint fits, returns it verbatim.
/// When available width is constrained, retains the highest-priority action (such as
/// [ESC] Cancel / [ESC] Close) and adds additional segments from the left as space allows,
/// ensuring that critical cancel/escape affordances are never lost behind an ellipsis.
pub fn formatWidthAwareHint(full_hint: []const u8, available_width: u16, arena: std.mem.Allocator) []const u8 {
    if (full_hint.len == 0 or available_width == 0) return full_hint;
    const sep = symbols.separator_dot_padded;
    const sep_w = gw(sep);
    if (gw(full_hint) <= available_width) return full_hint;

    var seg_iter = std.mem.splitSequence(u8, full_hint, sep);
    var count: usize = 0;
    while (seg_iter.next()) |_| {
        count += 1;
    }
    if (count <= 1) return full_hint;

    var segs: [16][]const u8 = undefined;
    const num_segs = @min(count, 16);
    seg_iter = std.mem.splitSequence(u8, full_hint, sep);
    for (0..num_segs) |i| {
        segs[i] = seg_iter.next().?;
    }

    const esc_seg = segs[num_segs - 1];
    const esc_w = gw(esc_seg);
    if (esc_w >= available_width) return esc_seg;

    var chosen_count: usize = 0;
    var current_w: u16 = esc_w;
    for (0..num_segs - 1) |i| {
        const added_w = gw(segs[i]) +| sep_w;
        if (current_w +| added_w <= available_width) {
            current_w +|= added_w;
            chosen_count += 1;
        } else {
            break;
        }
    }

    if (chosen_count == 0) return esc_seg;

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(arena);
    for (0..chosen_count) |i| {
        result.appendSlice(arena, segs[i]) catch return full_hint;
        result.appendSlice(arena, sep) catch return full_hint;
    }
    result.appendSlice(arena, esc_seg) catch return full_hint;
    return result.toOwnedSlice(arena) catch full_hint;
}

test "formatWidthAwareHint prioritizes escape action when space is constrained" {
    const arena = std.testing.allocator;
    const dot = symbols.separator_dot_padded;
    const full = "↑↓ Navigate" ++ dot ++ "[ENTER] Execute" ++ dot ++ "[ESC] Cancel";

    // Fits completely (display cell width of full is 44 cells, though byte length is 52):
    try std.testing.expectEqualStrings(full, formatWidthAwareHint(full, 44, arena));

    // Constrained width: retains "[ESC] Cancel" and fits leading actions if possible
    const mid = formatWidthAwareHint(full, 30, arena);
    defer arena.free(mid);
    try std.testing.expect(std.mem.endsWith(u8, mid, "[ESC] Cancel"));
    try std.testing.expect(gw(mid) <= 30);

    // Very narrow width: keeps just "[ESC] Cancel"
    const narrow = formatWidthAwareHint(full, 15, arena);
    try std.testing.expectEqualStrings("[ESC] Cancel", narrow);
}

test "InputWidget shifts hint past left pills and reserves right diff counts" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var text_field: vxfw.TextField = .init(gpa);
    defer text_field.deinit();
    var widget: InputWidget = .{
        .props = .{
            .input_field = &text_field,
            .input_text = "",
            .input_cursor = 0,
            .hint_text = "Type prompt · [ESC] Cancel",
            .diff_counts = .{ .additions = 10, .deletions = 2 },
            .background_jobs = 2,
            .show_lanes_chip = true,
            .lanes_count = 3,
        },
    };

    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = 80, .height = 4 },
        .max = .{ .width = 80, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try widget.widget().draw(ctx);

    var lanes_end: u16 = 0;
    var badge_end: u16 = 0;
    var hint_start: u16 = 0;
    var hint_end: u16 = 0;
    var diff_start: u16 = 80;
    for (surface.children) |child| {
        if (child.origin.row != 3) continue;
        const col: u16 = @intCast(@max(0, child.origin.col));
        if (child.z_index == 2 and col == 1) {
            lanes_end = col + child.surface.size.width;
        } else if (child.z_index == 2 and col > 1) {
            badge_end = col + child.surface.size.width;
        } else if (child.z_index == 0) {
            hint_start = col;
            hint_end = col + child.surface.size.width;
        } else if (child.z_index == 1) {
            diff_start = col;
        }
    }
    try std.testing.expect(lanes_end > 1);
    try std.testing.expect(badge_end > lanes_end);
    try std.testing.expect(hint_start > badge_end);
    try std.testing.expect(hint_end < diff_start);
}

test "InputWidget draws overflow indicator when multi-line prompt exceeds viewport" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var text_field: vxfw.TextField = .init(gpa);
    defer text_field.deinit();
    const text = "line1\nline2\nline3\nline4\nline5";
    var widget: InputWidget = .{
        .props = .{
            .input_field = &text_field,
            .input_text = text,
            .input_cursor = 0,
        },
    };

    // Height 4 gives 2 visible text rows (4 - 2 border rows) for 5 lines of text.
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = 40, .height = 4 },
        .max = .{ .width = 40, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try widget.widget().draw(ctx);
    // Border surface is the child at origin (0, 0) with z_index 0; overflow indicator is on row 3, col 2.
    var found_overflow = false;
    for (surface.children) |child| {
        if (child.origin.row == 0 and child.origin.col == 0 and child.z_index == 0) {
            for (child.surface.children) |bc| {
                if (bc.origin.row == 3 and bc.origin.col == 2) {
                    found_overflow = true;
                }
            }
        }
    }
    try std.testing.expect(found_overflow);
}

// ── #512: one owned draw path for one-row and multi-row prompts ──────

fn expectGraphemesEqual(want: []const []const u8, surface: vxfw.Surface) !void {
    for (want, 0..) |grapheme, col| {
        const cell = surface.buffer[col];
        try std.testing.expectEqualStrings(grapheme, cell.char.grapheme);
        try std.testing.expectEqual(@as(u8, 1), cell.char.width);
    }
}

test "unified draw path renders a one-row prompt like the TextField did" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var text_field: vxfw.TextField = .init(gpa);
    defer text_field.deinit();
    try text_field.insertSliceAtCursor("hello");

    var props: InputProps = .{ .input_field = &text_field, .input_text = "hello", .input_cursor = 5 };
    var command_input: CommandInputText = .{ .props = &props };

    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = 10, .height = 1 },
        .max = .{ .width = 10, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    // The vendored draw, kept as the reference for the single-row contract
    // it used to own. The unified path must render the same cells and put
    // the cursor in the same column.
    const reference = try text_field.draw(ctx);
    const unified = try command_input.widget().draw(ctx);

    try std.testing.expectEqual(reference.size, unified.size);
    try std.testing.expectEqual(@as(vxfw.CursorState, .{ .row = 0, .col = 5 }), unified.cursor);
    try std.testing.expectEqual(@as(vxfw.CursorState, .{ .row = 0, .col = 5 }), reference.cursor);
    for (0..reference.size.width) |col| {
        const index: usize = @intCast(col);
        try std.testing.expectEqualStrings(reference.buffer[index].char.grapheme, unified.buffer[index].char.grapheme);
        try std.testing.expectEqual(reference.buffer[index].char.width, unified.buffer[index].char.width);
        try std.testing.expectEqual(reference.buffer[index].style, unified.buffer[index].style);
    }
    try expectGraphemesEqual(&.{ "h", "e", "l", "l", "o" }, unified);
}

test "unified draw path places a mid-text cursor by grapheme column" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var text_field: vxfw.TextField = .init(gpa);
    defer text_field.deinit();
    // "héllo" with the gap parked after 'é' (byte 3, display column 2):
    // insert the whole text — the gap lands at the end — then move it back.
    try text_field.insertSliceAtCursor("héllo");
    text_field.buf.moveGapLeft(3);

    var props: InputProps = .{
        .input_field = &text_field,
        .input_text = "héllo",
        .input_cursor = text_field.buf.firstHalf().len,
    };
    var command_input: CommandInputText = .{ .props = &props };

    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = 10, .height = 1 },
        .max = .{ .width = 10, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const reference = try text_field.draw(ctx);
    const unified = try command_input.widget().draw(ctx);

    try std.testing.expectEqual(reference.cursor, unified.cursor);
    try std.testing.expectEqual(@as(vxfw.CursorState, .{ .row = 0, .col = 2 }), unified.cursor);
    try expectGraphemesEqual(&.{ "h", "é", "l", "l", "o" }, unified);
}

test "a one-row prompt that exactly fills its row keeps its text and cursor" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var text_field: vxfw.TextField = .init(gpa);
    defer text_field.deinit();
    try text_field.insertSliceAtCursor("0123456789");

    var props: InputProps = .{ .input_field = &text_field, .input_text = "0123456789", .input_cursor = 10 };
    var command_input: CommandInputText = .{ .props = &props };

    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = 10, .height = 1 },
        .max = .{ .width = 10, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const unified = try command_input.widget().draw(ctx);

    // The vendored draw used to replace the last cell with an ellipsis and
    // park the cursor at column 0 the moment the text reached full width.
    // The owned path shows the text and rides the cursor to its end.
    try expectGraphemesEqual(&.{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }, unified);
    try std.testing.expectEqual(@as(vxfw.CursorState, .{ .row = 0, .col = 10 }), unified.cursor);
}
