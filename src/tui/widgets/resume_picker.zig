const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const session_mod = @import("../../session.zig");
const message = @import("message.zig");
const panel = @import("panel.zig");
const tui_style = @import("../style.zig");
const tui_status = @import("../status.zig");
const tree_art = @import("tree_art.zig");

pub const Content = struct {
    io: std.Io,
    list: *vxfw.ListView,
    summaries: []const session_mod.SessionSummary,
    selection: u32,
    folded_projects: []const []const u8,
    filter: []const u8,
    tree_mode: bool,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const widgets = try self.resumeWidgets(ctx);
        self.list.children = .{ .slice = widgets };
        self.list.item_count = @intCast(widgets.len);
        self.list.cursor = self.selection;
        self.list.ensureScroll();
        return panel.listSurface(ctx, self.widget(), self.list.widget());
    }

    fn resumeWidgets(self: *Content, ctx: vxfw.DrawContext) ![]vxfw.Widget {
        const count = visibleCount(self.summaries, self.filter, self.folded_projects, self.tree_mode);
        const widgets = try ctx.arena.alloc(vxfw.Widget, count);
        const rows = try ctx.arena.alloc(Row, count);
        var builder: RowBuilder = .{
            .io = self.io,
            .ctx = ctx,
            .summaries = self.summaries,
            .filter = self.filter,
            .folded_projects = self.folded_projects,
            .tree_mode = self.tree_mode,
            .rows = rows,
            .widgets = widgets,
            .selection = self.selection,
        };
        try builder.build();
        return widgets;
    }
};

const RowBuilder = struct {
    io: std.Io,
    ctx: vxfw.DrawContext,
    summaries: []const session_mod.SessionSummary,
    filter: []const u8,
    folded_projects: []const []const u8,
    tree_mode: bool,
    rows: []Row,
    widgets: []vxfw.Widget,
    selection: u32,
    index: u32 = 0,

    fn build(self: *RowBuilder) !void {
        if (!self.tree_mode) return self.buildFlat();

        var summary_index: usize = 0;
        while (summary_index < self.summaries.len) {
            const cwd = self.summaries[summary_index].cwd;
            const end = projectEnd(self.summaries, summary_index);
            if (projectMatches(self.summaries[summary_index..end], self.filter)) {
                const folded = projectFolded(self.folded_projects, cwd);
                const has_children = matchingChildCount(self.summaries[summary_index..end], self.filter) > 0;
                try self.appendProject(cwd, end - summary_index, folded, has_children);
                if (!folded) {
                    const last_child = lastMatchingChild(self.summaries[summary_index..end], self.filter) orelse summary_index;
                    var child_index = summary_index;
                    while (child_index < end) : (child_index += 1) {
                        const summary = &self.summaries[child_index];
                        if (!matches(summary, self.filter)) continue;
                        try self.appendSession(summary, child_index - summary_index == last_child, true);
                    }
                }
            }
            summary_index = end;
        }
    }

    fn buildFlat(self: *RowBuilder) !void {
        for (self.summaries) |*summary| {
            if (!matches(summary, self.filter)) continue;
            try self.appendSession(summary, false, false);
        }
    }

    fn appendProject(self: *RowBuilder, cwd: []const u8, count: usize, folded: bool, has_children: bool) !void {
        const prefix = try tree_art.buildPrefix(self.ctx.arena, 0, false, &.{}, folded, has_children, has_children);
        self.rows[self.index] = .{
            .io = self.io,
            .kind = .{ .project = .{ .cwd = cwd, .session_count = @intCast(@min(count, std.math.maxInt(u32))), .folded = folded, .prefix = prefix } },
            .selected = self.index == self.selection,
        };
        self.widgets[self.index] = self.rows[self.index].widget();
        self.index += 1;
    }

    fn appendSession(self: *RowBuilder, summary: *const session_mod.SessionSummary, last: bool, tree: bool) !void {
        var last_at_indent = [_]bool{false} ** (tree_art.max_levels + 2);
        const prefix = if (tree)
            try tree_art.buildPrefix(self.ctx.arena, 1, last, last_at_indent[0..], false, false, false)
        else
            "";
        self.rows[self.index] = .{
            .io = self.io,
            .kind = .{ .session = .{ .summary = summary, .prefix = prefix } },
            .selected = self.index == self.selection,
        };
        self.widgets[self.index] = self.rows[self.index].widget();
        self.index += 1;
    }
};

const Row = struct {
    io: std.Io,
    kind: Kind,
    selected: bool,

    const Kind = union(enum) {
        project: Project,
        session: Session,
    };

    const Session = struct {
        summary: *const session_mod.SessionSummary,
        prefix: []const u8,
    };

    const Project = struct {
        cwd: []const u8,
        session_count: u32,
        folded: bool,
        prefix: []const u8,
    };

    fn widget(self: *Row) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Row = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = 1 }, &.{});
        switch (self.kind) {
            .project => |project| try self.drawProject(&surface, ctx, project),
            .session => |session| try self.drawSession(&surface, ctx, session),
        }
        return surface;
    }

    fn drawProject(self: *Row, surface: *vxfw.Surface, ctx: vxfw.DrawContext, project: Project) !void {
        if (self.selected) panel.fillRow(surface, 0, tui_style.Palette.selected);

        const marker = "  ";
        const start_col = message.ConversationLayout.left -| 1;
        const marker_style = if (self.selected)
            tui_style.Palette.selected_item
        else
            tui_style.Palette.thinking_body;
        try panel.lineStyledAt(surface, 0, marker, ctx, start_col, marker_style);

        var col: u16 = start_col + @as(u16, @intCast(ctx.stringWidth(marker)));
        const prefix_style = tui_style.onSelectionBg(tui_style.Palette.thinking_body, self.selected);
        try panel.lineStyledAt(surface, 0, project.prefix, ctx, col, prefix_style);
        col += @intCast(ctx.stringWidth(project.prefix));

        const name = baseName(project.cwd);
        try panel.lineStyledAt(surface, 0, name, ctx, col, tui_style.onSelectionBg(tui_style.Palette.markdown_code, self.selected));
        col += @intCast(ctx.stringWidth(name));

        const count = try std.fmt.allocPrint(ctx.arena, " ({d})", .{project.session_count});
        try panel.lineStyledAt(surface, 0, count, ctx, col, prefix_style);
    }

    fn drawSession(self: *Row, surface: *vxfw.Surface, ctx: vxfw.DrawContext, session: Session) !void {
        var buffer: [128]u8 = undefined;
        const modified = tui_status.modifiedTime(self.io, buffer[0..], session.summary.updated_at_ms);
        const left = try sessionLeftText(ctx, surface.size.width, modified, session);
        try panel.commandLine(surface, 0, left, ctx, self.selected);
        try panel.right(surface, 0, modified, ctx, self.selected);
    }

    fn sessionLeftText(ctx: vxfw.DrawContext, width: u16, modified: []const u8, session: Session) ![]const u8 {
        const marker = "  ";
        const available = resumeLeftWidth(ctx, width, modified);
        const prefix_width = ctx.stringWidth(marker) + ctx.stringWidth(session.prefix);
        if (available <= prefix_width) return ctx.arena.dupe(u8, marker);

        const name = session.summary.title orelse "Untitled";
        const title = try truncateText(ctx, name, available - prefix_width);
        return std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ marker, session.prefix, title });
    }
};

pub fn visibleCount(summaries: []const session_mod.SessionSummary, filter: []const u8, folded_projects: []const []const u8, tree_mode: bool) u32 {
    if (!tree_mode) return flatVisibleCount(summaries, filter);

    var count: u32 = 0;
    var index: usize = 0;
    while (index < summaries.len) {
        const cwd = summaries[index].cwd;
        const end = projectEnd(summaries, index);
        if (projectMatches(summaries[index..end], filter)) {
            count += 1;
            if (!projectFolded(folded_projects, cwd)) {
                var child_index = index;
                while (child_index < end) : (child_index += 1) {
                    if (matches(&summaries[child_index], filter)) count += 1;
                }
            }
        }
        index = end;
    }
    return count;
}

fn flatVisibleCount(summaries: []const session_mod.SessionSummary, filter: []const u8) u32 {
    var count: u32 = 0;
    for (summaries) |*summary| {
        if (matches(summary, filter)) count += 1;
    }
    return count;
}

pub fn selectedSummary(summaries: []const session_mod.SessionSummary, filter: []const u8, folded_projects: []const []const u8, selection: u32, tree_mode: bool) ?*const session_mod.SessionSummary {
    if (!tree_mode) return selectedFlatSummary(summaries, filter, selection);

    var row: u32 = 0;
    var index: usize = 0;
    while (index < summaries.len) {
        const cwd = summaries[index].cwd;
        const end = projectEnd(summaries, index);
        if (projectMatches(summaries[index..end], filter)) {
            if (row == selection) return null;
            row += 1;
            if (!projectFolded(folded_projects, cwd)) {
                var child_index = index;
                while (child_index < end) : (child_index += 1) {
                    const summary = &summaries[child_index];
                    if (!matches(summary, filter)) continue;
                    if (row == selection) return summary;
                    row += 1;
                }
            }
        }
        index = end;
    }
    return null;
}

fn selectedFlatSummary(summaries: []const session_mod.SessionSummary, filter: []const u8, selection: u32) ?*const session_mod.SessionSummary {
    var row: u32 = 0;
    for (summaries) |*summary| {
        if (!matches(summary, filter)) continue;
        if (row == selection) return summary;
        row += 1;
    }
    return null;
}

pub fn selectedProject(summaries: []const session_mod.SessionSummary, filter: []const u8, folded_projects: []const []const u8, selection: u32) ?[]const u8 {
    var row: u32 = 0;
    var index: usize = 0;
    while (index < summaries.len) {
        const cwd = summaries[index].cwd;
        const end = projectEnd(summaries, index);
        if (projectMatches(summaries[index..end], filter)) {
            if (row == selection) return cwd;
            row += 1;
            if (!projectFolded(folded_projects, cwd)) {
                var child_index = index;
                while (child_index < end) : (child_index += 1) {
                    if (matches(&summaries[child_index], filter)) row += 1;
                }
            }
        }
        index = end;
    }
    return null;
}

pub fn matches(summary: *const session_mod.SessionSummary, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (summary.title) |title| {
        if (std.mem.indexOf(u8, title, filter) != null) return true;
    }
    if (std.mem.indexOf(u8, summary.cwd, filter) != null) return true;
    if (std.mem.indexOf(u8, summary.id, filter) != null) return true;
    return false;
}

fn projectMatches(summaries: []const session_mod.SessionSummary, filter: []const u8) bool {
    if (filter.len == 0) return true;
    for (summaries) |*summary| {
        if (matches(summary, filter)) return true;
    }
    return false;
}

fn lastMatchingChild(summaries: []const session_mod.SessionSummary, filter: []const u8) ?usize {
    var last: ?usize = null;
    for (summaries, 0..) |*summary, index| {
        if (matches(summary, filter)) last = index;
    }
    return last;
}

fn matchingChildCount(summaries: []const session_mod.SessionSummary, filter: []const u8) u32 {
    var count: u32 = 0;
    for (summaries) |*summary| {
        if (matches(summary, filter)) count += 1;
    }
    return count;
}

fn projectEnd(summaries: []const session_mod.SessionSummary, start: usize) usize {
    const cwd = summaries[start].cwd;
    var index = start + 1;
    while (index < summaries.len) : (index += 1) {
        if (!std.mem.eql(u8, summaries[index].cwd, cwd)) break;
    }
    return index;
}

pub fn projectFolded(folded_projects: []const []const u8, cwd: []const u8) bool {
    for (folded_projects) |folded| {
        if (std.mem.eql(u8, folded, cwd)) return true;
    }
    return false;
}

fn baseName(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    if (std.mem.lastIndexOfScalar(u8, path[0..end], '/')) |index| return path[index + 1 .. end];
    return path[0..end];
}

fn resumeLeftWidth(ctx: vxfw.DrawContext, row_width: u16, modified: []const u8) usize {
    const start_col = message.ConversationLayout.left -| 1;
    const end_col = row_width -| message.ConversationLayout.right;
    const date_width = ctx.stringWidth(modified);
    if (end_col <= start_col) return 0;
    if (date_width + 1 >= end_col - start_col) return 0;
    return end_col - start_col - date_width - 1;
}

test "session tree counts project rows and folds children" {
    var summaries = [_]session_mod.SessionSummary{
        .{ .id = @constCast("1"), .title = @constCast("one"), .cwd = @constCast("/repo/a"), .created_at_ms = 0, .updated_at_ms = 2, .leaf_entry_id = null },
        .{ .id = @constCast("2"), .title = @constCast("two"), .cwd = @constCast("/repo/a"), .created_at_ms = 0, .updated_at_ms = 1, .leaf_entry_id = null },
        .{ .id = @constCast("3"), .title = @constCast("three"), .cwd = @constCast("/repo/b"), .created_at_ms = 0, .updated_at_ms = 3, .leaf_entry_id = null },
    };

    try std.testing.expectEqual(@as(u32, 3), visibleCount(&summaries, "", &.{}, false));
    try std.testing.expectEqual(@as(u32, 5), visibleCount(&summaries, "", &.{}, true));
    try std.testing.expectEqual(@as(u32, 3), visibleCount(&summaries, "", &.{"/repo/a"}, true));
    try std.testing.expect(selectedProject(&summaries, "", &.{}, 0) != null);
    try std.testing.expect(selectedSummary(&summaries, "", &.{}, 1, true) != null);
}

fn truncateText(ctx: vxfw.DrawContext, text: []const u8, width: usize) ![]const u8 {
    if (width == 0) return ctx.arena.dupe(u8, "");
    if (ctx.stringWidth(text) <= width) return ctx.arena.dupe(u8, text);
    if (width <= 3) return ctx.arena.dupe(u8, "...");

    var out: std.ArrayList(u8) = .empty;
    var used: usize = 0;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const grapheme_width = ctx.stringWidth(bytes);
        if (used + grapheme_width + 3 > width) break;
        try out.appendSlice(ctx.arena, bytes);
        used += grapheme_width;
    }
    try out.appendSlice(ctx.arena, "...");
    return out.toOwnedSlice(ctx.arena);
}
