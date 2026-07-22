//! Input buffer and vertical cursor movement logic.
//! Free functions taking `*App` — extracted from `tui.zig`.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../tui.zig");
const input_mod = @import("widgets/input.zig");

const App = tui.App;

pub fn clearInput(app: *App) void {
    app.inputs.input.clearRetainingCapacity();
}

pub fn clearPaletteInput(app: *App) void {
    app.inputs.palette.clearRetainingCapacity();
}

pub fn peekInput(app: *App) ![]u8 {
    const left = app.inputs.input.buf.firstHalf();
    const right = app.inputs.input.buf.secondHalf();
    const out = try app.gpa.alloc(u8, left.len + right.len);
    @memcpy(out[0..left.len], left);
    @memcpy(out[left.len..], right);
    return out;
}

pub fn peekCommentInput(app: *App) ![]u8 {
    const left = app.inputs.comment.buf.firstHalf();
    const right = app.inputs.comment.buf.secondHalf();
    const out = try app.gpa.alloc(u8, left.len + right.len);
    @memcpy(out[0..left.len], left);
    @memcpy(out[left.len..], right);
    return out;
}

pub fn inputTextRows(app: *App, ctx: vxfw.DrawContext, width: u16) !u16 {
    const text = try peekInput(app);
    defer app.gpa.free(text);
    return input_mod.wrappedTextRows(ctx, text, width);
}

pub fn insertInputNewline(app: *App) !void {
    try app.inputs.input.insertSliceAtCursor("\n");
    try app.updateAtSearch();
}

/// Moves the input cursor up or down by one *visual* row, so navigation
/// follows the wrapped layout the user actually sees — a long line with no
/// manual breaks behaves like a multi-row text area, not a single logical
/// line. Returns false when there is no row to move to (top/bottom), so the
/// caller can hand control to block navigation.
pub fn moveInputCursorVertical(app: *App, move: input_mod.VerticalMove) !bool {
    const text = try peekInput(app);
    defer app.gpa.free(text);
    const cur = app.inputs.input.buf.firstHalf().len;
    // Before the first draw (only in tests) the width is unknown; a wide
    // sentinel keeps every logical line on one visual row.
    const width: u16 = if (app.input_wrap_width == 0) 4096 else app.input_wrap_width;

    const pos = input_mod.wrappedPosition(text, cur, width);
    const target_row: u16 = switch (move) {
        .up => if (pos.row == 0) return false else pos.row - 1,
        .down => blk: {
            const last_row = input_mod.wrappedPosition(text, text.len, width).row;
            if (pos.row >= last_row) return false;
            break :blk pos.row + 1;
        },
    };

    const row_start = input_mod.visualRowStart(text, target_row, width);
    var row_end = input_mod.visualRowStart(text, target_row + 1, width);
    // A row that ends at a hard break owns the text up to, but not
    // including, the newline.
    if (row_end > row_start and text[row_end - 1] == '\n') row_end -= 1;
    const target = input_mod.byteAtVisualColumn(text, row_start, row_end, pos.col);

    if (target < cur) {
        app.inputs.input.buf.moveGapLeft(cur - target);
    } else if (target > cur) {
        app.inputs.input.buf.moveGapRight(target - cur);
    }
    return true;
}

pub const HistoryDirection = tui.Thread.HistoryDirection;

pub fn navigatePromptHistory(app: *App, direction: HistoryDirection) !bool {
    if (app.thread.navigatePromptHistory(direction)) |prompt| {
        clearInput(app);
        try app.inputs.input.insertSliceAtCursor(prompt);
        return true;
    }
    return false;
}
