const vaxis = @import("vaxis");

pub const Palette = struct {
    const thinking_blue = .{ 96, 165, 250 };
    const user_yellow = .{ 212, 175, 55 };
    const success_green = .{ 34, 197, 94 };
    const failure_red = .{ 239, 68, 68 };
    const accent_orange = .{ 249, 115, 22 };
    const skill_purple = .{ 168, 85, 247 };
    const muted_gray = .{ 138, 138, 138 };
    const selection_bg = .{ 38, 38, 38 };

    pub const selected: vaxis.Style = .{ .bg = .{ .rgb = selection_bg } };
    pub const selected_item: vaxis.Style = .{ .fg = .{ .rgb = accent_orange }, .bg = .{ .rgb = selection_bg } };

    pub const user: vaxis.Style = .{ .fg = .{ .rgb = user_yellow }, .italic = true };
    pub const skill: vaxis.Style = .{ .fg = .{ .rgb = skill_purple }, .bold = true };
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

    // Diff viewer: light-blue file section headers, a dim gutter for line
    // numbers, and white comment brackets/previews. Hunk markers stay dim gray
    // (blue read too loud). Line bodies reuse tool/tool_failed/thinking_body.
    const white = .{ 255, 255, 255 };
    const code_blue = .{ 147, 197, 253 };
    pub const diff_file_header: vaxis.Style = .{ .fg = .{ .rgb = code_blue }, .bold = true };
    pub const diff_hunk: vaxis.Style = .{ .fg = .{ .rgb = muted_gray }, .dim = true };
    pub const diff_gutter: vaxis.Style = .{ .fg = .{ .rgb = muted_gray }, .dim = true };
    pub const diff_bracket: vaxis.Style = .{ .fg = .{ .rgb = white } };
    pub const diff_comment: vaxis.Style = .{ .fg = .{ .rgb = white }, .italic = true };
    // The cursor-selected ("active") comment: yellow gutter + preview, so it's
    // obvious which comment Ctrl+E / Ctrl+D will act on.
    pub const diff_bracket_active: vaxis.Style = .{ .fg = .{ .rgb = user_yellow }, .bold = true };
    pub const diff_comment_active: vaxis.Style = .{ .fg = .{ .rgb = user_yellow }, .bold = true };
    // Faint full-line backgrounds for additions / deletions, and the matching
    // intra-line (word) highlight for the changed middles of a merged
    // modification (green for inserted, red for deleted).
    const faint_add_bg = .{ 22, 43, 30 };
    const faint_del_bg = .{ 52, 27, 27 };
    pub const diff_added_row: vaxis.Style = .{ .bg = .{ .rgb = faint_add_bg } };
    pub const diff_removed_row: vaxis.Style = .{ .bg = .{ .rgb = faint_del_bg } };
    pub const diff_inline_del: vaxis.Style = .{ .fg = .{ .rgb = failure_red }, .bg = .{ .rgb = faint_del_bg } };
    pub const diff_inline_add: vaxis.Style = .{ .fg = .{ .rgb = success_green }, .bg = .{ .rgb = faint_add_bg } };
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
