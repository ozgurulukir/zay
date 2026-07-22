const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");
const tui_style = @import("../style.zig");

const StylePalette = tui_style.Palette;

pub const HelpLine = struct {
    key: []const u8,
    desc: []const u8,
    is_header: bool = false,
};

pub const help_lines = [_]HelpLine{
    .{ .key = "KEYBOARD SHORTCUTS & NAVIGATION", .desc = "", .is_header = true },
    .{ .key = "Ctrl+Up / Alt+Up", .desc = "Navigate to previous prompt in history" },
    .{ .key = "Ctrl+Down / Alt+Down", .desc = "Navigate to next prompt in history" },
    .{ .key = "Shift+Down", .desc = "Jump to bottom of conversation" },
    .{ .key = "Up / Down", .desc = "Scroll transcript messages" },
    .{ .key = "Tab", .desc = "Expand / collapse active message" },
    .{ .key = "Ctrl+O", .desc = "Toggle background jobs modal" },
    .{ .key = "Ctrl+N", .desc = "Cycle through open parallel lanes" },
    .{ .key = "Esc", .desc = "Cancel active turn / close modal" },

    .{ .key = "CONTEXT MENTIONS & SKILLS", .desc = "", .is_header = true },
    .{ .key = "@<file>", .desc = "Attach file contents to prompt" },
    .{ .key = "$<skill>", .desc = "Invoke a specialized agent skill" },
    .{ .key = "/<command>", .desc = "Open interactive slash command palette" },

    .{ .key = "SLASH COMMANDS", .desc = "", .is_header = true },
    .{ .key = "/connect", .desc = "Configure AI provider & API keys" },
    .{ .key = "/model", .desc = "Select LLM model & reasoning effort" },
    .{ .key = "/new", .desc = "Start a fresh session" },
    .{ .key = "/resume", .desc = "Resume past session from history" },
    .{ .key = "/timeline", .desc = "Interactive session tree browser" },
    .{ .key = "/diff", .desc = "Full-screen git diff viewer & comments" },
    .{ .key = "/parallel", .desc = "Fork worktree into a new parallel lane" },
    .{ .key = "/save", .desc = "Commit git-shadow working copy snapshot" },
    .{ .key = "/lanes", .desc = "Manage & merge parked worktree lanes" },
    .{ .key = "/export", .desc = "Export conversation thread as Markdown" },
    .{ .key = "/status", .desc = "Show system status & active model details" },
    .{ .key = "/clear", .desc = "Clear current transcript view" },
    .{ .key = "/help", .desc = "Open this quick reference guide" },
};

pub const Content = struct {
    scroll: u16 = 0,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        if (width == 0 or height == 0) return surface;

        var row: u16 = 0;
        var visible_row: u16 = 0;
        for (help_lines) |item| {
            if (visible_row < self.scroll) {
                visible_row += 1;
                continue;
            }
            if (row >= height) break;

            if (item.is_header) {
                panel.lineStyledAt(&surface, row, item.key, ctx, 1, StylePalette.border_label) catch {};
            } else {
                panel.lineStyledAt(&surface, row, item.key, ctx, 2, StylePalette.user) catch {};
                if (width > 30 and item.desc.len > 0) {
                    _ = panel.writeBorderTextEndingAt(&surface, ctx, row, width -| 2, item.desc, StylePalette.thinking_body);
                }
            }
            row += 1;
            visible_row += 1;
        }
        return surface;
    }
};
