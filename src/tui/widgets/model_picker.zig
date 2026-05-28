const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const ai = @import("../../ai.zig");
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

pub const ReasoningOption = struct { label: []const u8, effort: ai.ReasoningEffort };
pub const Scope = enum { global, project, session };

pub fn findActiveStorageIdx(models: []const codex.Model, active_id: ?[]const u8) ?u32 {
    const id = active_id orelse return null;
    for (models, 0..) |m, i| {
        if (std.mem.eql(u8, m.id, id)) return @intCast(i);
    }
    return null;
}

pub fn displayToStorage(active_storage_idx: ?u32, display_pos: u32) u32 {
    const aidx = active_storage_idx orelse return display_pos;
    if (display_pos == 0) return aidx;
    const offset = display_pos - 1;
    return if (offset < aidx) offset else offset + 1;
}

pub const Content = struct {
    models: []const codex.Model,
    list: *vxfw.ListView,
    selection: u32,
    column: Column,
    active_model: ?[]const u8,
    reasoning_options: []const ReasoningOption,
    reasoning_indexes: []const u32,
    scope: Scope,
    loading: bool = false,
    error_message: ?[]const u8 = null,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        if (self.loading) return self.drawStatus(ctx, "Loading models…", StylePalette.tool);
        if (self.error_message) |msg| return self.drawStatus(ctx, msg, StylePalette.tool_failed);
        if (self.models.len == 0) return self.drawEmpty(ctx);
        const widgets = try self.modelWidgets(ctx);
        self.list.children = .{ .slice = widgets };
        self.list.item_count = @intCast(widgets.len);
        self.list.cursor = self.selection + 1;
        self.syncListScroll();
        return panel.listSurface(ctx, self.widget(), self.list.widget());
    }

    fn drawStatus(self: *Content, ctx: vxfw.DrawContext, text: []const u8, style: vaxis.Style) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        try panel.lineStyledAt(&surface, 0, text, ctx, message.ConversationLayout.left -| 1, style);
        return surface;
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
        const active_storage_idx = findActiveStorageIdx(self.models, self.active_model);
        var display_pos: u32 = 0;
        while (display_pos < self.models.len) : (display_pos += 1) {
            const storage_idx = displayToStorage(active_storage_idx, display_pos);
            rows[display_pos] = .{
                .model = &self.models[storage_idx],
                .selected = self.selection == display_pos,
                .column = self.column,
                .active_model = self.active_model,
                .reasoning_label = self.reasoningLabel(display_pos),
                .scope_label = scopeLabel(self.scope),
            };
            widgets[display_pos + 1] = rows[display_pos].widget();
        }
        return widgets;
    }

    fn reasoningLabel(self: *const Content, index: u32) []const u8 {
        if (index >= self.reasoning_indexes.len) return "medium (Default)";
        const reasoning_index = self.reasoning_indexes[index];
        if (reasoning_index >= self.reasoning_options.len) return "medium (Default)";
        return self.reasoning_options[reasoning_index].label;
    }

    fn syncListScroll(self: *Content) void {
        if (self.selection == 0) {
            self.list.scroll.top = 0;
            self.list.scroll.offset = 0;
            self.list.scroll.pending_lines = 0;
            self.list.scroll.wants_cursor = false;
            return;
        }
        self.list.ensureScroll();
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
        try panel.lineStyledAt(&surface, 0, "SCOPE", ctx, scopeColumn(surface.size.width) + 2, StylePalette.panel_header);
        return surface;
    }
};

test "selection wrap to first row restores header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const models = [_]codex.Model{
        .{ .id = @constCast("m0"), .label = @constCast("m0") },
        .{ .id = @constCast("m1"), .label = @constCast("m1") },
        .{ .id = @constCast("m2"), .label = @constCast("m2") },
        .{ .id = @constCast("m3"), .label = @constCast("m3") },
        .{ .id = @constCast("m4"), .label = @constCast("m4") },
        .{ .id = @constCast("m5"), .label = @constCast("m5") },
        .{ .id = @constCast("m6"), .label = @constCast("m6") },
        .{ .id = @constCast("m7"), .label = @constCast("m7") },
        .{ .id = @constCast("m8"), .label = @constCast("m8") },
        .{ .id = @constCast("m9"), .label = @constCast("m9") },
    };
    const reasoning = [_]u32{0} ** models.len;
    const options = [_]ReasoningOption{.{ .label = "medium (Default)", .effort = .medium }};
    var list: vxfw.ListView = .{ .children = .{ .slice = &.{} }, .draw_cursor = false };
    var content: Content = .{
        .models = &models,
        .list = &list,
        .selection = @intCast(models.len - 1),
        .column = .model,
        .active_model = null,
        .reasoning_options = &options,
        .reasoning_indexes = &reasoning,
        .scope = .global,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 7 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    _ = try content.widget().draw(ctx);
    try std.testing.expect(list.scroll.top > 0);

    content.selection = 0;
    _ = try content.widget().draw(ctx);

    try std.testing.expectEqual(@as(u32, 0), list.scroll.top);
    try std.testing.expectEqual(@as(i17, 0), list.scroll.offset);
}

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
