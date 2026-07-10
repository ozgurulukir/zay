//! Lanes picker — the list body for the `/lanes` management window and the
//! `/merge` destination chooser (both share `Mode.lanes`). Purely
//! presentational: the caller (`App`) builds `entries` from either the parked
//! worktrees or the candidate destination lanes and owns all the strings; this
//! widget just renders a selectable list (title on the left, subtitle on the
//! right) inside the overlay panel, mirroring `resume_picker`'s structure.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const message = @import("message.zig");
const panel = @import("panel.zig");
const tui_style = @import("../style.zig");

/// One row: a primary `title` (branch or lane name) and a right-aligned
/// `subtitle` (worktree path or branch). Both borrowed from the caller.
pub const Entry = struct {
    title: []const u8,
    subtitle: []const u8,
};

pub const Content = struct {
    list: *vxfw.ListView,
    entries: []const Entry,
    selection: u32,
    /// Shown when `entries` is empty (e.g. "No parked lanes.").
    empty_message: []const u8,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        if (self.entries.len == 0) {
            const widgets = try ctx.arena.alloc(vxfw.Widget, 1);
            const empty = try ctx.arena.create(EmptyRow);
            empty.* = .{ .text = self.empty_message };
            widgets[0] = empty.widget();
            self.list.children = .{ .slice = widgets };
            self.list.item_count = 1;
            self.list.cursor = 0;
            self.list.ensureScroll();
            return panel.listSurface(ctx, self.widget(), self.list.widget());
        }

        const widgets = try ctx.arena.alloc(vxfw.Widget, self.entries.len);
        const rows = try ctx.arena.alloc(Row, self.entries.len);
        for (self.entries, 0..) |entry, i| {
            rows[i] = .{ .entry = entry, .selected = i == self.selection };
            widgets[i] = rows[i].widget();
        }
        self.list.children = .{ .slice = widgets };
        self.list.item_count = @intCast(widgets.len);
        self.list.cursor = self.selection;
        self.list.ensureScroll();
        return panel.listSurface(ctx, self.widget(), self.list.widget());
    }
};

const Row = struct {
    entry: Entry,
    selected: bool,

    fn widget(self: *Row) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Row = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = 1 }, &.{});
        try panel.commandLine(&surface, 0, self.entry.title, ctx, self.selected);
        if (self.entry.subtitle.len > 0) try panel.right(&surface, 0, self.entry.subtitle, ctx, self.selected);
        return surface;
    }
};

const EmptyRow = struct {
    text: []const u8,

    fn widget(self: *EmptyRow) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *EmptyRow = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = 1 }, &.{});
        try panel.lineStyledAt(&surface, 0, self.text, ctx, message.ConversationLayout.left -| 1, tui_style.Palette.thinking_body);
        return surface;
    }
};
