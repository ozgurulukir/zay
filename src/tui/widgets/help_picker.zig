//! Interactive, scrollable Help & Keyboard Shortcuts overlay widget.
//!
//! Displays grouped keyboard shortcuts, slash commands, context mentions,
//! and skill invocation syntax. Supports keyboard scrolling (Up/Down,
//! PgUp/PgDn, Home/End, j/k) and mouse wheel scrolling.

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
    .{ .key = "Shift + Mouse Drag", .desc = "Select text with mouse (terminal native)" },
    .{ .key = "Ctrl+V / Shift+Ins", .desc = "Paste text from system clipboard" },
    .{ .key = "c / y (in block nav)", .desc = "Copy selected message to clipboard" },
    .{ .key = "Up / Down", .desc = "Scroll transcript messages / select blocks" },
    .{ .key = "Tab", .desc = "Expand / collapse active message" },
    .{ .key = "Ctrl+O", .desc = "Toggle background jobs modal" },
    .{ .key = "Ctrl+N", .desc = "Cycle through open parallel lanes" },
    .{ .key = "Esc", .desc = "Cancel turn / unselect block / close modal" },

    .{ .key = "CONTEXT MENTIONS & SKILLS", .desc = "", .is_header = true },
    .{ .key = "@<file>", .desc = "Attach file contents to prompt" },
    .{ .key = "$<skill>", .desc = "Invoke a specialized agent skill" },
    .{ .key = "/<command>", .desc = "Open interactive slash command palette" },

    .{ .key = "SLASH COMMANDS", .desc = "", .is_header = true },
    .{ .key = "/connect", .desc = "Configure AI provider & API keys" },
    .{ .key = "/model", .desc = "Select LLM model & reasoning effort" },
    .{ .key = "/settings", .desc = "View and edit configuration settings" },
    .{ .key = "/new", .desc = "Start a fresh session" },
    .{ .key = "/resume", .desc = "Resume past session from history" },
    .{ .key = "/timeline", .desc = "Interactive session tree browser" },
    .{ .key = "/diff", .desc = "Full-screen git diff viewer & comments" },
    .{ .key = "/parallel", .desc = "Fork worktree into a new parallel lane" },
    .{ .key = "/save", .desc = "Commit git-shadow working copy snapshot" },
    .{ .key = "/lanes", .desc = "Manage & merge parked worktree lanes" },
    .{ .key = "/export", .desc = "Export conversation thread as Markdown" },
    .{ .key = "/copy", .desc = "Copy selected transcript message to clipboard" },
    .{ .key = "/paste", .desc = "Paste text from clipboard into prompt" },
    .{ .key = "/status", .desc = "Show system status & active model details" },
    .{ .key = "/clear", .desc = "Clear current transcript view" },
    .{ .key = "/help", .desc = "Open this quick reference guide" },
    .{ .key = "/exit", .desc = "Quit Nova agent" },
};

pub const State = struct {
    scroll: u16 = 0,

    pub fn reset(self: *State) void {
        self.scroll = 0;
    }

    pub fn maxScroll(available_rows: u16) u16 {
        const total: u16 = @intCast(help_lines.len);
        return total -| available_rows;
    }

    pub fn scrollUp(self: *State, count: u16) void {
        self.scroll = self.scroll -| count;
    }

    pub fn scrollDown(self: *State, count: u16, available_rows: u16) void {
        const max_s = maxScroll(available_rows);
        self.scroll = @min(self.scroll + count, max_s);
    }
};

pub const Content = struct {
    state: *State,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        if (width == 0 or height == 0) return surface;

        // Reserve last row for bottom hint bar.
        const body_height: u16 = height -| 1;
        const total_count: u16 = @intCast(help_lines.len);
        const max_s = State.maxScroll(body_height);
        if (self.state.scroll > max_s) self.state.scroll = max_s;

        var row: u16 = 0;
        var line_idx: u16 = self.state.scroll;
        while (line_idx < total_count and row < body_height) : (line_idx += 1) {
            const item = help_lines[line_idx];
            if (item.is_header) {
                if (row > 0) {
                    // Draw a subtle separator line before section headers.
                    panel.fillRow(&surface, row, StylePalette.thinking_body);
                }
                panel.lineStyledAt(&surface, row, item.key, ctx, 1, StylePalette.border_label) catch {};
            } else {
                panel.lineStyledAt(&surface, row, item.key, ctx, 2, StylePalette.user) catch {};
                if (width > 30 and item.desc.len > 0) {
                    _ = panel.writeBorderTextEndingAt(&surface, ctx, row, width -| 3, item.desc, StylePalette.thinking_body);
                }
            }
            row += 1;
        }

        // Draw scrollbar on rightmost column if content exceeds body height.
        if (total_count > body_height and body_height > 2) {
            drawScrollbar(&surface, body_height, self.state.scroll, total_count);
        }

        // Draw bottom hint bar.
        const hint_row = height - 1;
        const hint_text = " ↑/↓ Scroll · PgUp/PgDn Page · Esc/Enter/q Close ";
        panel.lineStyledAt(&surface, hint_row, hint_text, ctx, 1, StylePalette.thinking_body) catch {};

        return surface;
    }
};

fn drawScrollbar(surface: *vxfw.Surface, height: u16, scroll: u16, total: u16) void {
    const col = surface.size.width -| 1;
    const max_s = total -| height;
    if (max_s == 0) return;

    const bar_height: usize = @max(1, @as(usize, height) * @as(usize, height) / @as(usize, total));
    const max_top = height -| @as(u16, @intCast(bar_height));
    const top: u16 = @intCast(@as(usize, scroll) * @as(usize, max_top) / @as(usize, max_s));

    var r: u16 = 0;
    while (r < height) : (r += 1) {
        const is_thumb = r >= top and r < top + bar_height;
        const grapheme: []const u8 = if (r == 0) "▲" else if (r == height - 1) "▼" else if (is_thumb) "█" else "│";
        const style: vaxis.Style = if (is_thumb) StylePalette.border_label else StylePalette.thinking_body;
        surface.writeCell(col, r, .{
            .char = .{ .grapheme = grapheme, .width = 1 },
            .style = style,
        });
    }
}
