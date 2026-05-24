const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui_style = @import("../style.zig");

const assert = std.debug.assert;
const picker_secondary_column: u16 = 52;

const StylePalette = tui_style.Palette;
const mergedSelectedStyle = tui_style.mergedSelectedStyle;

pub const Column = enum { provider, sign_out };
pub const Action = enum { connect_codex, sign_out_codex, custom_connection };

pub const State = struct {
    selection: u32 = 0,
    column: Column = .provider,

    pub fn reset(self: *State) void {
        self.selection = 0;
        self.column = .provider;
    }

    pub fn handleKey(self: *State, key: vaxis.Key, codex_signed_in: bool) bool {
        assert(self.selection < optionCount());
        if (key.matches(vaxis.Key.left, .{})) {
            self.column = .provider;
            return true;
        }
        if (key.matches(vaxis.Key.right, .{})) {
            if (self.selection == 0) {
                if (codex_signed_in) self.column = .sign_out;
            }
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            if (self.selection == 0) {
                if (codex_signed_in) self.column = nextColumn(self.column);
            }
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            self.selection = previousIndex(self.selection, optionCount());
            self.column = .provider;
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            self.selection = nextIndex(self.selection, optionCount());
            self.column = .provider;
            return true;
        }
        return false;
    }

    pub fn selectedAction(self: *const State) Action {
        assert(self.selection < optionCount());
        if (self.selection == 0) {
            if (self.column == .sign_out) return .sign_out_codex;
            return .connect_codex;
        }
        return .custom_connection;
    }
};

pub const Content = struct {
    state: State,
    codex_signed_in: bool,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        try self.drawCodex(&surface, ctx);
        try self.drawCustom(&surface, ctx);
        return surface;
    }

    fn drawCodex(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const focused = self.state.selection == 0 and self.state.column == .provider;
        const prefix = if (focused) "‣ " else "  ";
        const label = if (self.codex_signed_in) "OpenAI Codex [CONNECTED]" else "OpenAI Codex";
        const text = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, label });
        writePanelLine(surface, 0, text, ctx, focused);
        if (self.codex_signed_in) try self.drawSignOut(surface, ctx);
    }

    fn drawSignOut(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const focused = self.state.selection == 0 and self.state.column == .sign_out;
        const prefix = if (focused) "‣ " else "  ";
        const text = try std.fmt.allocPrint(ctx.arena, "{s}Sign out", .{prefix});
        writePanelLineAt(surface, 0, text, ctx, focused, pickerSecondaryColumn(surface.size.width));
    }

    fn drawCustom(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const focused = self.state.selection == 1;
        const prefix = if (focused) "‣ " else "  ";
        const text = try std.fmt.allocPrint(ctx.arena, "{s}Custom", .{prefix});
        writePanelLine(surface, 1, text, ctx, focused);
    }
};

pub fn optionCount() u32 {
    return 2;
}

fn nextColumn(current: Column) Column {
    return switch (current) {
        .provider => .sign_out,
        .sign_out => .provider,
    };
}

fn nextIndex(current: u32, count: u32) u32 {
    assert(count > 0);
    assert(current < count);
    return if (current + 1 >= count) 0 else current + 1;
}

fn previousIndex(current: u32, count: u32) u32 {
    assert(count > 0);
    assert(current < count);
    return if (current == 0) count - 1 else current - 1;
}

fn pickerSecondaryColumn(width: u16) u16 {
    return @min(picker_secondary_column, width / 2);
}

fn writePanelLine(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, selected: bool) void {
    writePanelLineAt(surface, row, text, ctx, selected, 1);
}

fn writePanelLineAt(
    surface: *vxfw.Surface,
    row: u16,
    text: []const u8,
    ctx: vxfw.DrawContext,
    selected: bool,
    start_col: u16,
) void {
    if (row >= surface.size.height) return;
    var col = start_col;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        if (col >= surface.size.width) return;
        const bytes = grapheme.bytes(text);
        const width: u8 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        if (col + width > surface.size.width) return;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = bytes, .width = width },
            .style = mergedSelectedStyle(StylePalette.tool, selected),
        });
        col += width;
    }
}

test "provider picker navigation reaches sign out only when signed in" {
    var state: State = .{};
    try std.testing.expect(state.handleKey(.{ .codepoint = vaxis.Key.right }, false));
    try std.testing.expectEqual(Column.provider, state.column);
    try std.testing.expect(state.handleKey(.{ .codepoint = vaxis.Key.right }, true));
    try std.testing.expectEqual(Column.sign_out, state.column);
}

test "provider picker selected action follows selected row and column" {
    var state: State = .{};
    try std.testing.expectEqual(Action.connect_codex, state.selectedAction());
    state.column = .sign_out;
    try std.testing.expectEqual(Action.sign_out_codex, state.selectedAction());
    state.selection = 1;
    try std.testing.expectEqual(Action.custom_connection, state.selectedAction());
}
