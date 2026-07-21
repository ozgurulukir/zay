//! Top-level transcript + loading + input layout math.
//!
//! Pulled out of `tui.zig` (R5.2c of `_pm/Projects/tui-split`) — the layout
//! arithmetic for `drawRoot`: given the terminal height, the wrapped input
//! row count, and three visibility flags, compute the row ranges for the
//! transcript pane, the loading spinner strip, the modal overlay panel, and
//! the input box.
//!
//! Pure: no I/O, no allocations, no app state — just arithmetic. Both
//! `drawRoot` and the four layout unit tests in `tui.zig` call into it.

pub const loading_status_rows: u16 = 2;

pub const RootLayout = struct {
    input_height: u16,
    loading_height: u16,
    panel_height: u16,
    transcript_height: u16,
    loading_row: u16,
    panel_row: u16,
    input_row: u16,
};

pub fn rootLayout(max_height: u16, panel_visible: bool, input_text_rows: u16, loading_visible: bool, queued_visible: bool) RootLayout {
    // Reserve: top border + bottom border + one hint/diff-counts row (the `3`),
    // the wrapped input text, and — when a steered message is queued — the extra
    // line the InputWidget draws above the border for it. Omitting the queued row
    // here starves the InputWidget so it silently drops the hint + diff counts.
    const desired: u16 = 3 + input_text_rows + @intFromBool(queued_visible);
    const max_allowed: u16 = @max(@as(u16, 6), max_height -| 3);
    const input_height: u16 = @min(max_height, @min(desired, max_allowed));
    const above_input_height: u16 = max_height - input_height;
    const loading_height: u16 = if (loading_visible) @min(loading_status_rows, above_input_height) else 0;
    const transcript_height: u16 = above_input_height - loading_height;
    const panel_height: u16 = if (panel_visible) @min(transcript_height, 7) else 0;
    return .{
        .input_height = input_height,
        .loading_height = loading_height,
        .panel_height = panel_height,
        .transcript_height = transcript_height,
        .loading_row = transcript_height,
        .panel_row = transcript_height - panel_height,
        .input_row = transcript_height + loading_height,
    };
}
