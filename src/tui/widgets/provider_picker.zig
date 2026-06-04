const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");
const message = @import("message.zig");
const tui_style = @import("../style.zig");
const config_mod = @import("../../config.zig");

const StylePalette = tui_style.Palette;

const assert = std.debug.assert;

pub const Stage = enum { list, form };
pub const Column = enum { provider, sign_out };

pub const Action = union(enum) {
    connect_codex,
    sign_out_codex,
    open_form: config_mod.Provider,
};

pub const State = struct {
    stage: Stage = .list,
    selection: u32 = 0,
    column: Column = .provider,
    form_provider: ?config_mod.Provider = null,

    pub fn reset(self: *State) void {
        self.* = .{};
    }

    pub fn handleKey(self: *State, key: vaxis.Key, codex_signed_in: bool) bool {
        if (self.stage == .form) return false;

        const count = rowCount();
        assert(self.selection < count);
        if (key.matches(vaxis.Key.left, .{})) {
            self.column = .provider;
            return true;
        }
        if (key.matches(vaxis.Key.right, .{})) {
            if (self.selection == 0 and codex_signed_in) self.column = .sign_out;
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            if (self.selection == 0 and codex_signed_in) self.column = nextColumn(self.column);
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            self.selection = previousIndex(self.selection, count);
            self.column = .provider;
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            self.selection = nextIndex(self.selection, count);
            self.column = .provider;
            return true;
        }
        return false;
    }

    pub fn selectedAction(self: *const State) Action {
        assert(self.selection < rowCount());
        if (self.selection == 0) {
            if (self.column == .sign_out) return .sign_out_codex;
            return .connect_codex;
        }
        return .{ .open_form = config_mod.catalogueProviders()[self.selection - 1] };
    }

    pub fn selectedProvider(self: *const State) ?config_mod.Provider {
        if (self.selection == 0) return null;
        return config_mod.catalogueProviders()[self.selection - 1];
    }
};

pub const Content = struct {
    state: State,
    codex_signed_in: bool,
    connected: []const bool,
    key_input: []const u8 = "",

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        if (self.state.stage == .form) {
            try self.drawForm(&surface, ctx);
        } else {
            try self.drawList(&surface, ctx);
        }
        return surface;
    }

    fn drawList(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        try self.drawCodex(surface, ctx);
        const providers = config_mod.catalogueProviders();
        for (providers, 0..) |provider, index| {
            const row: u16 = @intCast(index + 1);
            const focused = self.state.selection == row and self.state.column == .provider;
            const prefix = if (focused) "‣ " else "  ";
            const base = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, provider.displayName() });
            try panel.commandLine(surface, row, base, ctx, focused);
            if (index < self.connected.len and self.connected[index]) {
                const badge_col: u16 = (message.ConversationLayout.left -| 1) +
                    @as(u16, @intCast(@min(ctx.stringWidth(base), @as(usize, std.math.maxInt(u16)))));
                try panel.lineStyledAt(surface, row, " [CONNECTED]", ctx, badge_col, tui_style.onSelectionBg(StylePalette.success, focused));
            }
        }
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

    fn drawForm(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const provider = self.state.form_provider orelse return;
        const start_col = message.ConversationLayout.left -| 1;
        try panel.lineStyledAt(surface, 1, provider.displayName(), ctx, start_col, StylePalette.model_status);

        const label = if (provider.requiresApiKey()) "Api Key: " else "Api Key (optional): ";
        try panel.lineStyledAt(surface, 3, label, ctx, start_col, StylePalette.panel_header);
        const key_col = start_col + @as(u16, @intCast(@min(ctx.stringWidth(label), @as(usize, std.math.maxInt(u16)))));
        const shown = try std.fmt.allocPrint(ctx.arena, "{s}\u{2588}", .{self.key_input});
        try panel.lineStyledAt(surface, 3, shown, ctx, key_col, StylePalette.panel_header);
    }
};

pub fn rowCount() u32 {
    return 1 + @as(u32, @intCast(config_mod.catalogueProviders().len));
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

test "provider picker selecting a catalogue row opens its form" {
    var state: State = .{};
    try std.testing.expectEqual(Action.connect_codex, state.selectedAction());
    try std.testing.expect(state.handleKey(.{ .codepoint = vaxis.Key.down }, false));
    const action = state.selectedAction();
    try std.testing.expect(action == .open_form);
    try std.testing.expectEqual(config_mod.catalogueProviders()[0], action.open_form);
    try std.testing.expectEqual(config_mod.catalogueProviders()[0], state.selectedProvider().?);
}

test "provider picker form stage defers keys to the input field" {
    var state: State = .{ .stage = .form };
    try std.testing.expect(!state.handleKey(.{ .codepoint = 'a' }, false));
    try std.testing.expect(!state.handleKey(.{ .codepoint = vaxis.Key.down }, true));
}
