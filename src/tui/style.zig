const std = @import("std");
const vaxis = @import("vaxis");

pub const Palette = struct {
    const thinking_blue = .{ 96, 165, 250 };
    const user_yellow = .{ 212, 175, 55 };

    pub const selected: vaxis.Style = .{ .bg = .{ .rgb = .{ 38, 38, 38 } } };
    pub const user: vaxis.Style = .{ .fg = .{ .rgb = user_yellow }, .italic = true };
    pub const tool: vaxis.Style = .{ .fg = .{ .rgb = .{ 34, 197, 94 } } };
    pub const tool_failed: vaxis.Style = .{ .fg = .{ .rgb = .{ 239, 68, 68 } } };
    pub const cwd: vaxis.Style = .{ .fg = .{ .rgb = .{ 34, 197, 94 } } };
    pub const git_branch: vaxis.Style = .{ .fg = .{ .rgb = .{ 249, 115, 22 } } };
    pub const model_status: vaxis.Style = .{ .fg = .{ .rgb = thinking_blue } };
    pub const thinking_label: vaxis.Style = .{ .fg = .{ .rgb = thinking_blue } };
    pub const thinking_body: vaxis.Style = .{ .fg = .{ .rgb = .{ 138, 138, 138 } } };
    pub const thinking_bar: vaxis.Style = .{ .fg = .{ .rgb = thinking_blue } };
    pub const panel_header: vaxis.Style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } } };
};

pub fn mergedSelectedStyle(style: vaxis.Style, selected: bool) vaxis.Style {
    var merged = style;
    if (!selected) merged.dim = true;
    return merged;
}

pub fn gradientStyle(col: u16, width: u16, selected: bool) vaxis.Style {
    std.debug.assert(width > 0);
    const denominator: u32 = @max(@as(u32, width) - 1, 1);
    const numerator: u32 = @min(@as(u32, col), denominator);
    const yellow = .{ 252, 211, 77 };
    const orange = .{ 249, 115, 22 };
    return mergedSelectedStyle(.{ .fg = .{ .rgb = .{
        gradientChannel(yellow[0], orange[0], numerator, denominator),
        gradientChannel(yellow[1], orange[1], numerator, denominator),
        gradientChannel(yellow[2], orange[2], numerator, denominator),
    } } }, selected);
}

fn gradientChannel(start: u8, end: u8, numerator: u32, denominator: u32) u8 {
    std.debug.assert(denominator > 0);
    const start_value: u32 = start;
    const end_value: u32 = end;
    if (end_value >= start_value) {
        return @intCast(start_value + ((end_value - start_value) * numerator) / denominator);
    }
    return @intCast(start_value - ((start_value - end_value) * numerator) / denominator);
}
