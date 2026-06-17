const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");
const tui_style = @import("../style.zig");

const StylePalette = tui_style.Palette;

/// Layout policy shared with the floating-panel host (see `tui.zig`). The body
/// shows one row for the empty/status message or up to `max_visible_rows`
/// results, wrapped in a single-cell border on top and bottom.
pub const max_visible_rows = 8;
pub const border_rows = 2;

/// Total panel height, including the border, for the given result count.
pub fn panelHeight(result_count: usize) u16 {
    const rows: u16 = if (result_count == 0)
        1
    else
        @intCast(@min(result_count, max_visible_rows));
    return rows + border_rows;
}

/// Index of the first result to render so `selection` is within the `visible`
/// rows. Keeps the selection pinned to the bottom edge once it scrolls past
/// the fold; snaps back to the top while it still fits without scrolling.
fn firstVisible(selection: u32, count: u32, visible: u16) u32 {
    if (visible == 0 or count <= visible) return 0;
    if (selection < visible) return 0;
    return @min(selection - visible + 1, count - visible);
}

pub const Content = struct {
    results: []const []const u8,
    selection: u32,
    query: []const u8,
    indexing: bool = false,
    sigil: u8 = '@',
    title: []const u8 = "Files",

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn emptyMessage(self: *const Content) []const u8 {
        if (self.indexing) return "Indexing…";
        if (self.query.len == 0) {
            if (self.sigil == '$') return "Type a skill after $";
            return "Type a path after @";
        }
        return "No matches";
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        var body: Body = .{ .content = self };
        var border: vxfw.Border = .{
            .child = body.widget(),
            .style = StylePalette.thinking_body,
            .labels = &.{.{ .text = self.title, .alignment = .top_left }},
        };
        return border.widget().draw(ctx);
    }
};

const Body = struct {
    content: *Content,

    fn widget(self: *Body) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Body = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});

        const content = self.content;
        if (content.results.len == 0) {
            try panel.lineAt(&surface, 0, content.emptyMessage(), ctx, false, 0);
            return surface;
        }

        // Scroll the visible window so the selection stays on screen even when
        // there are more results than fit (height < results.len).
        const count: u32 = @intCast(content.results.len);
        const first = firstVisible(content.selection, count, surface.size.height);
        var row: u16 = 0;
        while (row < surface.size.height and first + row < count) : (row += 1) {
            const index = first + row;
            const selected = index == content.selection;
            const prefix = if (selected) "‣ " else "  ";
            const text = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, content.results[index] });
            try panel.lineAt(&surface, row, text, ctx, selected, 0);
        }
        return surface;
    }
};

test "at_search draws a selected result without overrunning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const results = [_][]const u8{ "src/agent.zig", "src/ai.zig", "src/tui.zig" };
    var content: Content = .{ .results = &results, .selection = 1, .query = "src" };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 6 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try content.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 40), surface.size.width);
}

test "firstVisible keeps the selection within the window" {
    // Everything fits: no scrolling.
    try std.testing.expectEqual(@as(u32, 0), firstVisible(0, 5, 8));
    try std.testing.expectEqual(@as(u32, 0), firstVisible(4, 5, 8));
    // Selection still above the fold.
    try std.testing.expectEqual(@as(u32, 0), firstVisible(7, 50, 8));
    // Selection past the fold pins to the bottom edge.
    try std.testing.expectEqual(@as(u32, 1), firstVisible(8, 50, 8));
    try std.testing.expectEqual(@as(u32, 12), firstVisible(19, 50, 8));
    // Selection near the end keeps it pinned to the bottom edge / last window.
    try std.testing.expectEqual(@as(u32, 38), firstVisible(45, 50, 8));
    try std.testing.expectEqual(@as(u32, 42), firstVisible(49, 50, 8));
}
