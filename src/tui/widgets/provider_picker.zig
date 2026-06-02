const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");
const message = @import("message.zig");
const tui_style = @import("../style.zig");

const StylePalette = tui_style.Palette;

const assert = std.debug.assert;

pub const Column = enum { provider, sign_out };
pub const Action = enum { connect_codex, sign_out_codex };

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
        if (self.column == .sign_out) return .sign_out_codex;
        return .connect_codex;
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
        return surface;
    }

    fn drawCodex(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const focused = self.state.selection == 0 and self.state.column == .provider;
        const prefix = if (focused) "‣ " else "  ";
        const base = try std.fmt.allocPrint(ctx.arena, "{s}OpenAI Codex", .{prefix});
        try panel.commandLine(surface, 0, base, ctx, focused);
        if (self.codex_signed_in) {
            const badge_col: u16 = (message.ConversationLayout.left -| 1) +
                @as(u16, @intCast(@min(ctx.stringWidth(base), @as(usize, std.math.maxInt(u16)))));
            try panel.lineStyledAt(surface, 0, " [CONNECTED]", ctx, badge_col, tui_style.onSelectionBg(StylePalette.success, focused));
            try self.drawSignOut(surface, ctx);
        }
    }

    fn drawSignOut(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const focused = self.state.selection == 0 and self.state.column == .sign_out;
        const prefix = if (focused) "‣ " else "  ";
        const text = try std.fmt.allocPrint(ctx.arena, "{s}Sign out", .{prefix});
        try panel.lineAt(surface, 0, text, ctx, focused, panel.secondaryColumn(surface.size.width));
    }
};

pub fn optionCount() u32 {
    return 1;
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
}
