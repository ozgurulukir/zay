const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const ai = @import("../../ai.zig");
const codex = @import("../../auth/codex.zig");
const message = @import("message.zig");
const panel = @import("panel.zig");
const tui_style = @import("../style.zig");
const config_mod = @import("../../config/config.zig");
const command_panel = @import("command_panel.zig");
const model_loader = @import("../model_loader.zig");

fn columnStyle(focused: bool, selected: bool) vaxis.Style {
    const p = tui_style.activePalette();
    if (focused) return p.selected_item;
    return tui_style.onSelectionBg(p.thinking_body, selected);
}

pub const Column = enum {
    model,
    reasoning,

    pub fn next(self: Column) Column {
        return switch (self) {
            .model => .reasoning,
            .reasoning => .model,
        };
    }

    pub fn previous(self: Column) Column {
        return switch (self) {
            .model => .reasoning,
            .reasoning => .model,
        };
    }
};

pub const ReasoningOption = struct { label: []const u8, effort: ai.ReasoningEffort };

pub fn matches(model: codex.Model, filter: []const u8) bool {
    if (filter.len == 0) return true;
    return command_panel.containsIgnoreCase(model.label, filter) or command_panel.containsIgnoreCase(model.id, filter);
}

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

/// ClinePass subscription-tier convention: `~`-prefixed ids are Cline Pro/Max
/// subscription models and `cline-pass/` ids are ClinePass subscription
/// models. Other ClinePass models are pay-as-you-go.
pub fn isSubscriptionModel(id: []const u8) bool {
    return std.mem.startsWith(u8, id, "~") or std.mem.startsWith(u8, id, "cline-pass/");
}

/// Tier tags are meaningful only for the ClinePass catalogue.
pub fn tierTag(source: model_loader.ModelSource, id: []const u8) ?[]const u8 {
    const conn = switch (source) {
        .openai_codex => return null,
        .openai_compatible => |conn| conn,
    };
    if (!std.mem.eql(u8, conn.auth_key_id, "cline-pass")) return null;
    return if (isSubscriptionModel(id)) "SUB" else "PAYG";
}

pub const Content = struct {
    models: []const codex.Model,
    sources: []const model_loader.ModelSource,
    list: *vxfw.ListView,
    selection: u32,
    column: Column,
    active_model: ?[]const u8,
    reasoning_options: []const ReasoningOption,
    reasoning_indexes: []const u32,
    filter: []const u8 = "",
    /// Pre-rendered status footer (scope, wire parameter preview). Empty
    /// hides the footer row entirely. Built by the caller (overlay.zig),
    /// which knows the scope, provider, and wire dialect.
    footer: []const u8 = "",
    loading: bool = false,
    error_message: ?[]const u8 = null,
    highlight_enabled: bool = true,
    highlight_style: config_mod.FuzzyHighlightStyle = .accent,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        // Only mask the list when it is actually empty. The disk cache restores
        // instantly on open, so a populated list must remain visible while the
        // background revalidate runs — otherwise the cache is wasted behind a
        // full-screen "Loading…" overlay (regression from d745095).
        if (self.loading and self.models.len == 0) return self.drawStatus(ctx, "Loading models…", p.panel_header);
        if (self.error_message) |msg| return self.drawStatus(ctx, msg, p.tool_failed);
        if (self.models.len == 0) return self.drawEmpty(ctx);
        const built = try self.modelWidgets(ctx);
        if (built.widgets.len <= 1) return self.drawStatus(ctx, "No matching models", p.notice);
        self.list.children = .{ .slice = built.widgets };
        self.list.item_count = @intCast(built.widgets.len);
        self.list.cursor = built.cursor;
        self.syncListScroll();
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        // Reserve the bottom row for the status footer when one is set, so
        // the footer never overlaps the last visible model row.
        const list_height = if (self.footer.len > 0) height -| 1 else height;
        const list_surface = try self.list.widget().draw(ctx.withConstraints(
            .{ .width = width, .height = list_height },
            .{ .width = width, .height = list_height },
        ));
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = list_surface,
            .z_index = 0,
        };
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, children);
        if (self.footer.len > 0 and height > 0) {
            try panel.lineStyledAt(&surface, height -| 1, self.footer, ctx, 0, p.thinking_body);
        }
        return surface;
    }

    fn drawStatus(self: *Content, ctx: vxfw.DrawContext, text: []const u8, style: vaxis.Style) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        try panel.lineStyledAt(&surface, 0, text, ctx, message.ConversationLayout.left -| 1, style);
        return surface;
    }

    fn drawEmpty(self: *Content, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const p = tui_style.activePalette();
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        try panel.lineStyledAt(&surface, 0, "No provider models available. Run /connect first.", ctx, message.ConversationLayout.left -| 1, p.notice);
        return surface;
    }

    const Built = struct { widgets: []vxfw.Widget, cursor: u32 };

    fn modelWidgets(self: *Content, ctx: vxfw.DrawContext) !Built {
        std.debug.assert(self.models.len == self.sources.len);
        const active_storage_idx = findActiveStorageIdx(self.models, self.active_model);

        var match_count: usize = 0;
        var d: u32 = 0;
        while (d < self.models.len) : (d += 1) {
            if (matches(self.models[displayToStorage(active_storage_idx, d)], self.filter)) match_count += 1;
        }

        const widgets = try ctx.arena.alloc(vxfw.Widget, match_count + 1);
        const header = try ctx.arena.create(Header);
        header.* = .{};
        widgets[0] = header.widget();
        const rows = try ctx.arena.alloc(Row, match_count);

        var cursor: u32 = 1;
        var vis: usize = 0;
        d = 0;
        while (d < self.models.len) : (d += 1) {
            const storage_idx = displayToStorage(active_storage_idx, d);
            if (!matches(self.models[storage_idx], self.filter)) continue;
            rows[vis] = .{
                .model = &self.models[storage_idx],
                .source = self.sources[storage_idx],
                .selected = self.selection == d,
                .column = self.column,
                .active_model = self.active_model,
                .reasoning_label = self.reasoningLabel(d),
                .filter = self.filter,
                .highlight_enabled = self.highlight_enabled,
                .highlight_style = self.highlight_style,
            };
            widgets[vis + 1] = rows[vis].widget();
            if (self.selection == d) cursor = @intCast(vis + 1);
            vis += 1;
        }
        return .{ .widgets = widgets, .cursor = cursor };
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
        const p = tui_style.activePalette();
        const width = ctx.max.width orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = 1 }, &.{});
        try panel.lineStyledAt(&surface, 0, "NAME", ctx, message.ConversationLayout.left + 1, p.panel_header);
        try panel.lineStyledAt(&surface, 0, "REASONING EFFORT", ctx, panel.secondaryColumn(surface.size.width) + 2, p.panel_header);
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
    const sources = [_]model_loader.ModelSource{.openai_codex} ** models.len;
    const reasoning = [_]u32{0} ** models.len;
    const options = [_]ReasoningOption{.{ .label = "medium (Default)", .effort = .medium }};
    var list: vxfw.ListView = .{ .children = .{ .slice = &.{} }, .draw_cursor = false };
    var content: Content = .{
        .models = &models,
        .sources = &sources,
        .list = &list,
        .selection = @intCast(models.len - 1),
        .column = .model,
        .active_model = null,
        .reasoning_options = &options,
        .reasoning_indexes = &reasoning,
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

test "matches is a case-insensitive substring over label and id" {
    const m: codex.Model = .{ .id = @constCast("gpt-5-codex"), .label = @constCast("GPT-5 Codex") };
    try std.testing.expect(matches(m, ""));
    try std.testing.expect(matches(m, "codex"));
    try std.testing.expect(matches(m, "GPT"));
    try std.testing.expect(matches(m, "5-CO"));
    try std.testing.expect(!matches(m, "claude"));
}

test "filter limits the visible model rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const models = [_]codex.Model{
        .{ .id = @constCast("gpt-5"), .label = @constCast("GPT-5") },
        .{ .id = @constCast("o3-mini"), .label = @constCast("o3-mini") },
        .{ .id = @constCast("gpt-5-codex"), .label = @constCast("GPT-5 Codex") },
    };
    const sources = [_]model_loader.ModelSource{.openai_codex} ** models.len;
    const reasoning = [_]u32{0} ** models.len;
    const options = [_]ReasoningOption{.{ .label = "medium (Default)", .effort = .medium }};
    var list: vxfw.ListView = .{ .children = .{ .slice = &.{} }, .draw_cursor = false };
    var content: Content = .{
        .models = &models,
        .sources = &sources,
        .list = &list,
        .selection = 0,
        .column = .model,
        .active_model = null,
        .reasoning_options = &options,
        .reasoning_indexes = &reasoning,
        .filter = "gpt",
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 7 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    _ = try content.widget().draw(ctx);
    // Two models match "gpt", plus the header row.
    try std.testing.expectEqual(@as(?u32, 3), list.item_count);
}

test "tierTag classifies only ClinePass models" {
    const cline_source: model_loader.ModelSource = .{ .openai_compatible = .{
        .provider = .openai_compatible,
        .base_url = "https://proxy.example.com/cline/v1",
        .auth_key_id = "cline-pass",
    } };
    const unrelated_source: model_loader.ModelSource = .{ .openai_compatible = .{
        .provider = .ollama,
        .base_url = "http://localhost:11434/v1",
        .auth_key_id = "ollama",
    } };
    // Cline Pro/Max `~`-prefixed ids are subscription models.
    try std.testing.expect(isSubscriptionModel("~sonnet"));
    try std.testing.expectEqualStrings("SUB", tierTag(cline_source, "~sonnet").?);
    // ClinePass ids are subscription models.
    try std.testing.expect(isSubscriptionModel("cline-pass/qwen3.7-max"));
    try std.testing.expectEqualStrings("SUB", tierTag(cline_source, "cline-pass/qwen3.7-max").?);
    // Other ClinePass models are pay-as-you-go.
    try std.testing.expect(!isSubscriptionModel("deepseek/deepseek-v4-flash"));
    try std.testing.expectEqualStrings("PAYG", tierTag(cline_source, "deepseek/deepseek-v4-flash").?);
    // Model ids alone cannot assign billing semantics to other providers.
    try std.testing.expect(tierTag(unrelated_source, "cline-pass/qwen3.7-max") == null);
    try std.testing.expect(tierTag(.openai_codex, "~sonnet") == null);
    // Boundaries: exact "cline-pass" (no slash) is not subscription; the
    // prefix forms are.
    try std.testing.expect(!isSubscriptionModel("cline-pass"));
    try std.testing.expect(isSubscriptionModel("cline-pass/"));
    try std.testing.expect(isSubscriptionModel("~"));
}

test "Cline tier tag and unrelated row render through the full draw path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const models = [_]codex.Model{
        .{ .id = @constCast("cline-pass/qwen3.7-max"), .label = @constCast("ClinePass · cline-pass/qwen3.7-max") },
        .{ .id = @constCast("deepseek/deepseek-v4-flash"), .label = @constCast("DeepSeek · deepseek/deepseek-v4-flash") },
    };
    const sources = [_]model_loader.ModelSource{
        .{ .openai_compatible = .{ .provider = .openai_compatible, .base_url = "https://api.cline.bot/api/v1", .auth_key_id = "cline-pass" } },
        .{ .openai_compatible = .{ .provider = .ollama, .base_url = "http://localhost:11434/v1", .auth_key_id = "ollama" } },
    };
    const reasoning = [_]u32{0} ** models.len;
    const options = [_]ReasoningOption{.{ .label = "medium (Default)", .effort = .medium }};
    var list: vxfw.ListView = .{ .children = .{ .slice = &.{} }, .draw_cursor = false };
    var content: Content = .{
        .models = &models,
        .sources = &sources,
        .list = &list,
        .selection = 0,
        .column = .model,
        .active_model = null,
        .reasoning_options = &options,
        .reasoning_indexes = &reasoning,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 7 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    _ = try content.widget().draw(ctx);
    // Header + 2 model rows — one tagged Cline row and one untagged Ollama row.
    try std.testing.expectEqual(@as(?u32, 3), list.item_count);
}

pub const Row = struct {
    model: *const codex.Model,
    source: model_loader.ModelSource,
    selected: bool,
    column: Column,
    active_model: ?[]const u8,
    reasoning_label: []const u8,
    filter: []const u8 = "",
    highlight_enabled: bool = true,
    highlight_style: config_mod.FuzzyHighlightStyle = .accent,

    pub fn widget(self: *Row) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Row = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        const width = ctx.max.width orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = 1 }, &.{});

        const model_focused = self.selected and self.column == .model;
        const prefix = "  ";
        const start_col = message.ConversationLayout.left -| 1;
        // The model-label line migrates to drawFuzzyListRow (base_style
        // preserves columnStyle's column-focus semantics, M6).
        try panel.drawFuzzyListRow(&surface, 0, ctx, .{
            .prefix = prefix,
            .text = self.model.label,
            .query = self.filter,
            .selected = self.selected,
            .base_style = columnStyle(model_focused, self.selected),
            .start_col = start_col,
            .highlight_enabled = self.highlight_enabled,
            .highlight_style = self.highlight_style,
        });
        // Keep the inline ✓ badge (m3) and the SUB/PAYG tier tag from
        // colliding with the reasoning column on selected rows.
        const label_end = start_col +
            @as(u16, @intCast(@min(
                ctx.stringWidth(prefix) + ctx.stringWidth(self.model.label),
                @as(usize, std.math.maxInt(u16)),
            )));
        if (self.activeModel()) {
            try panel.lineStyledAt(&surface, 0, " ✓", ctx, label_end, tui_style.onSelectionBg(p.success, self.selected));
        }
        if (tierTag(self.source, self.model.id)) |tag| {
            const tag_col = panel.secondaryColumn(surface.size.width) -| @as(u16, @intCast(tag.len)) -| 1;
            const tag_style = if (isSubscriptionModel(self.model.id)) p.notice else p.thinking_body;
            // Skip the tag when it would overwrite the label/✓ tail (narrow
            // terminals, long labels) — cosmetic, same class as the ✓ badge.
            if (tag_col > label_end + 1) {
                try panel.lineStyledAt(&surface, 0, tag, ctx, tag_col, tui_style.onSelectionBg(tag_style, self.selected));
            }
        }
        if (self.selected) try self.drawReasoning(&surface, ctx);
        return surface;
    }

    fn activeModel(self: *const Row) bool {
        const active_model = self.active_model orelse return false;
        return std.mem.eql(u8, active_model, self.model.id);
    }

    fn drawReasoning(self: *const Row, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const focused = self.column == .reasoning;
        const prefix = "  ";
        const text = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, self.reasoning_label });
        try panel.lineStyledAt(surface, 0, text, ctx, panel.secondaryColumn(surface.size.width), columnStyle(focused, self.selected));
    }
};
