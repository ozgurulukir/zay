const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const codex = @import("../../codex.zig");
const message = @import("message.zig");
const panel = @import("panel.zig");
const tui_style = @import("../style.zig");

const StylePalette = tui_style.Palette;

fn scopeColumn(width: u16) u16 {
    const secondary = panel.secondaryColumn(width);
    return secondary +| 24;
}

fn scopeLabel(scope: Scope) []const u8 {
    return switch (scope) {
        .global => "Global",
        .project => "Project",
        .session => "Session",
    };
}

pub const Column = enum {
    model,
    reasoning,
    scope,

    pub fn next(self: Column) Column {
        return switch (self) {
            .model => .reasoning,
            .reasoning => .scope,
            .scope => .model,
        };
    }

    pub fn previous(self: Column) Column {
        return switch (self) {
            .model => .scope,
            .reasoning => .model,
            .scope => .reasoning,
        };
    }
};

pub const ReasoningOption = struct { label: []const u8 };
pub const Scope = enum { global, project, session };

pub const Content = struct {
    models: []const codex.Model,
    list: *vxfw.ListView,
    selection: u32,
    column: Column,
    active_model: ?[]const u8,
    reasoning_options: []const ReasoningOption,
    reasoning_indexes: []const u32,
    scope: Scope,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        if (self.models.len == 0) return self.drawEmpty(ctx);
        const widgets = try self.modelWidgets(ctx);
        self.list.children = .{ .slice = widgets };
        self.list.item_count = @intCast(widgets.len);
        self.list.cursor = self.selection + 1;
        self.list.ensureScroll();
        return panel.listSurface(ctx, self.widget(), self.list.widget());
    }

    fn drawEmpty(self: *Content, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        try panel.lineAt(&surface, 0, "No provider models available. Run /connect first.", ctx, false, message.ConversationLayout.left -| 1);
        return surface;
    }

    fn modelWidgets(self: *Content, ctx: vxfw.DrawContext) ![]vxfw.Widget {
        const widgets = try ctx.arena.alloc(vxfw.Widget, self.models.len + 1);
        const header = try ctx.arena.create(Header);
        header.* = .{};
        widgets[0] = header.widget();
        const rows = try ctx.arena.alloc(Row, self.models.len);
        for (self.models, 0..) |*model, index| {
            rows[index] = .{
                .model = model,
                .selected = self.selection == index,
                .column = self.column,
                .active_model = self.active_model,
                .reasoning_label = self.reasoningLabel(@intCast(index)),
                .scope_label = scopeLabel(self.scope),
            };
            widgets[index + 1] = rows[index].widget();
        }
        return widgets;
    }

    fn reasoningLabel(self: *const Content, index: u32) []const u8 {
        if (index >= self.reasoning_indexes.len) return "medium (Default)";
        const reasoning_index = self.reasoning_indexes[index];
        if (reasoning_index >= self.reasoning_options.len) return "medium (Default)";
        return self.reasoning_options[reasoning_index].label;
    }
};

const Header = struct {
    fn widget(self: *Header) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Header = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = 1 }, &.{});
        try panel.lineStyledAt(&surface, 0, "NAME", ctx, message.ConversationLayout.left + 1, StylePalette.panel_header);
        try panel.lineStyledAt(&surface, 0, "REASONING EFFORT", ctx, panel.secondaryColumn(surface.size.width) + 2, StylePalette.panel_header);
        try panel.lineStyledAt(&surface, 0, "SCOPE", ctx, scopeColumn(surface.size.width), StylePalette.panel_header);
        return surface;
    }
};

pub const Row = struct {
    model: *const codex.Model,
    selected: bool,
    column: Column,
    active_model: ?[]const u8,
    reasoning_label: []const u8,
    scope_label: []const u8,

    pub fn widget(self: *Row) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Row = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = 1 }, &.{});
        const model_focused = self.selected and self.column == .model;
        const prefix = if (model_focused) "‣ " else "  ";
        const text = if (self.activeModel())
            try std.fmt.allocPrint(ctx.arena, "{s}{s} [ACTIVE]", .{ prefix, self.model.label })
        else
            try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, self.model.label });
        try panel.lineAt(&surface, 0, text, ctx, model_focused, message.ConversationLayout.left -| 1);
        if (self.selected) {
            try self.drawReasoning(&surface, ctx);
            try self.drawScope(&surface, ctx);
        }
        return surface;
    }

    fn activeModel(self: *const Row) bool {
        const active_model = self.active_model orelse return false;
        return std.mem.eql(u8, active_model, self.model.id);
    }

    fn drawReasoning(self: *const Row, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const focused = self.column == .reasoning;
        const prefix = if (focused) "‣ " else "  ";
        const text = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, self.reasoning_label });
        try panel.lineAt(surface, 0, text, ctx, focused, panel.secondaryColumn(surface.size.width));
    }

    fn drawScope(self: *const Row, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const focused = self.column == .scope;
        const prefix = if (focused) "‣ " else "  ";
        const text = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, self.scope_label });
        try panel.lineAt(surface, 0, text, ctx, focused, scopeColumn(surface.size.width));
    }
};
