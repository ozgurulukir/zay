const vaxis = @import("vaxis");

pub const Palette = struct {
    const thinking_blue = .{ 96, 165, 250 };
    const user_yellow = .{ 212, 175, 55 };
    const success_green = .{ 34, 197, 94 };
    const failure_red = .{ 239, 68, 68 };
    const accent_orange = .{ 249, 115, 22 };
    const muted_gray = .{ 138, 138, 138 };
    const selection_bg = .{ 38, 38, 38 };

    pub const selected: vaxis.Style = .{ .bg = .{ .rgb = selection_bg } };
    pub const selected_item: vaxis.Style = .{ .fg = .{ .rgb = accent_orange }, .bg = .{ .rgb = selection_bg } };

    pub const user: vaxis.Style = .{ .fg = .{ .rgb = user_yellow }, .italic = true };
    pub const tool: vaxis.Style = .{ .fg = .{ .rgb = success_green } };
    pub const tool_failed: vaxis.Style = .{ .fg = .{ .rgb = failure_red } };
    pub const success: vaxis.Style = .{ .fg = .{ .rgb = success_green } };
    pub const border_label: vaxis.Style = .{ .fg = .{ .rgb = accent_orange } };
    pub const model_status: vaxis.Style = .{ .fg = .{ .rgb = thinking_blue } };
    pub const thinking_label: vaxis.Style = .{ .fg = .{ .rgb = thinking_blue } };
    pub const thinking_body: vaxis.Style = .{ .fg = .{ .rgb = muted_gray } };
    pub const thinking_bar: vaxis.Style = .{ .fg = .{ .rgb = thinking_blue } };
    pub const markdown_code: vaxis.Style = .{ .fg = .{ .rgb = .{ 147, 197, 253 } } };
    pub const panel_header: vaxis.Style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } } };
};

pub fn onSelectionBg(style: vaxis.Style, selected: bool) vaxis.Style {
    var merged = style;
    if (selected) merged.bg = Palette.selected.bg;
    return merged;
}

pub fn mergedSelectedStyle(style: vaxis.Style, selected: bool) vaxis.Style {
    var merged = style;
    if (!selected) merged.dim = true;
    return merged;
}
