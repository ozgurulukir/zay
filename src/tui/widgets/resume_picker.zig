const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const session_mod = @import("../../session.zig");
const app_state = @import("../app_state.zig");
const message = @import("message.zig");
const panel = @import("panel.zig");
const tui_style = @import("../style.zig");
const tui_status = @import("../status.zig");
const tree_art = @import("tree_art.zig");
const config_mod = @import("../../config/config.zig");

pub const Content = struct {
    io: std.Io,
    list: *vxfw.ListView,
    summaries: []const session_mod.SessionSummary,
    selection: u32,
    folded_projects: []const []const u8,
    filter: []const u8,
    /// How sessions are grouped: flat (current project only), project
    /// (grouped by project directory), or date (grouped by date bucket).
    group_by: app_state.NavState.ResumeGroupBy = .flat,
    /// Sub-state of the session picker: browsing, renaming, deleting, or
    /// showing a blocked-action popup.
    action: app_state.NavState.SessionAction = .browsing,
    /// Rename text buffer (borrowed from `app.input_buffers.session_rename_text`).
    /// Only rendered while `action == .renaming`.
    rename_text: []const u8 = "",
    highlight_enabled: bool = true,
    highlight_style: config_mod.FuzzyHighlightStyle = .accent,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        if (self.action != .browsing) return self.drawSubState(ctx);
        const widgets = try self.resumeWidgets(ctx);
        // TUX01: never render a blank overlay — show a first-run or
        // no-match empty state (mirrors model_picker.drawEmpty).
        if (widgets.len == 0) return self.drawEmpty(ctx);
        self.list.children = .{ .slice = widgets };
        self.list.item_count = @intCast(widgets.len);
        self.list.cursor = self.selection;
        self.list.ensureScroll();
        return panel.listSurface(ctx, self.widget(), self.list.widget());
    }

    /// Empty state: distinguish "no sessions exist yet" (first run) from
    /// "nothing matches the current search". Keeps the overlay informative
    /// instead of blank, with a concrete next step.
    fn drawEmpty(self: *Content, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const p = tui_style.activePalette();
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        const col = message.ConversationLayout.left -| 1;
        if (self.summaries.len == 0) {
            try panel.lineStyledAt(&surface, 0, "No sessions yet.", ctx, col, p.panel_header);
            try panel.lineStyledAt(&surface, 1, "Start a conversation and it will show up here.", ctx, col, p.thinking_body);
        } else if (self.filter.len > 0) {
            const text = try std.fmt.allocPrint(ctx.arena, "No sessions match \"{s}\".", .{self.filter});
            try panel.lineStyledAt(&surface, 0, text, ctx, col, p.panel_header);
            try panel.lineStyledAt(&surface, 1, "Adjust the search text above.", ctx, col, p.thinking_body);
        } else {
            try panel.lineStyledAt(&surface, 0, "No sessions to show.", ctx, col, p.panel_header);
            try panel.lineStyledAt(&surface, 1, "Try a different grouping (Ctrl+A) or unfold a project (Tab).", ctx, col, p.thinking_body);
        }
        return surface;
    }

    /// Draw the rename, delete-confirmation, or blocked-action prompt instead
    /// of the session list. The list stays behind (not redrawn) but the
    /// overlay border label changes to indicate the active sub-state.
    fn drawSubState(self: *Content, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const p = tui_style.activePalette();
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(
            ctx.arena,
            self.widget(),
            .{ .width = width, .height = height },
            &.{},
        );

        switch (self.action) {
            .renaming => {
                try panel.lineStyledAt(&surface, 0, "Rename Session", ctx, 2, p.panel_header);
                const prompt = try std.fmt.allocPrint(ctx.arena, "  > {s}_", .{self.rename_text});
                try panel.lineStyledAt(&surface, 2, prompt, ctx, 2, p.selected_item);
                try panel.lineStyledAt(&surface, height -| 2, "[Enter] Save  |  [Esc] Cancel", ctx, 2, p.thinking_body);
            },
            .deleting => {
                try panel.lineStyledAt(&surface, 0, "Delete Session", ctx, 2, p.panel_header);
                try panel.lineStyledAt(&surface, 2, "  Delete this session? This cannot be undone.", ctx, 2, p.tool_failed);
                try panel.lineStyledAt(&surface, height -| 2, "[Y] Delete  |  [N/Esc] Cancel", ctx, 2, p.thinking_body);
            },
            .blocked => {
                try panel.lineStyledAt(&surface, 0, "Cannot Delete Active Session", ctx, 2, p.panel_header);
                try panel.lineStyledAt(&surface, 2, "  Switch to another session first, then delete this one.", ctx, 2, p.tool_failed);
                try panel.lineStyledAt(&surface, height -| 2, "[Any key] Dismiss", ctx, 2, p.thinking_body);
            },
            .browsing => unreachable,
        }
        return surface;
    }

    fn resumeWidgets(self: *Content, ctx: vxfw.DrawContext) ![]vxfw.Widget {
        const count = visibleCount(self.io, self.summaries, self.filter, self.folded_projects, self.group_by);
        const widgets = try ctx.arena.alloc(vxfw.Widget, count);
        const rows = try ctx.arena.alloc(Row, count);
        var builder: RowBuilder = .{
            .io = self.io,
            .ctx = ctx,
            .summaries = self.summaries,
            .filter = self.filter,
            .folded_projects = self.folded_projects,
            .group_by = self.group_by,
            .rows = rows,
            .widgets = widgets,
            .selection = self.selection,
            .highlight_enabled = self.highlight_enabled,
            .highlight_style = self.highlight_style,
        };
        try builder.build();
        return widgets;
    }
};

/// Date bucket for grouping sessions by recency.
const DateBucket = enum(u3) { today, yesterday, this_week, this_month, this_year, older };

const RowBuilder = struct {
    io: std.Io,
    ctx: vxfw.DrawContext,
    summaries: []const session_mod.SessionSummary,
    filter: []const u8,
    folded_projects: []const []const u8,
    group_by: app_state.NavState.ResumeGroupBy,
    rows: []Row,
    widgets: []vxfw.Widget,
    selection: u32,
    highlight_enabled: bool,
    highlight_style: config_mod.FuzzyHighlightStyle,
    index: u32 = 0,

    fn build(self: *RowBuilder) !void {
        switch (self.group_by) {
            .flat => return self.buildFlat(),
            .project => return self.buildProject(),
            .date => return self.buildDate(),
        }
    }

    fn buildFlat(self: *RowBuilder) !void {
        for (self.summaries) |*summary| {
            if (!matches(summary, self.filter)) continue;
            try self.appendSession(summary, false, false);
        }
    }

    fn buildProject(self: *RowBuilder) !void {
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

    fn buildDate(self: *RowBuilder) !void {
        const now_ms = std.Io.Clock.now(.real, self.io).toMilliseconds();
        // Build date buckets: Today, Yesterday, This Week, This Month,
        // This Year, Older. Each bucket gets a header row.
        var buckets: [6]std.ArrayListUnmanaged(*const session_mod.SessionSummary) = .{
            .empty, .empty, .empty, .empty, .empty, .empty,
        };
        defer for (&buckets) |*b| b.deinit(self.ctx.arena);

        for (self.summaries) |*summary| {
            if (!matches(summary, self.filter)) continue;
            const bucket = dateBucket(now_ms, summary.updated_at_ms);
            try buckets[@intFromEnum(bucket)].append(self.ctx.arena, summary);
        }

        const labels = [_][]const u8{ "Today", "Yesterday", "This Week", "This Month", "This Year", "Older" };

        for (&buckets, 0..) |*bucket, i| {
            if (bucket.items.len == 0) continue;
            const label = labels[i];
            try self.appendDateHeader(label, bucket.items.len);
            // Sort within bucket by updated_at_ms descending.
            std.mem.sort(*const session_mod.SessionSummary, bucket.items, {}, struct {
                fn desc(_: void, a: *const session_mod.SessionSummary, b: *const session_mod.SessionSummary) bool {
                    return a.updated_at_ms > b.updated_at_ms;
                }
            }.desc);
            for (bucket.items, 0..) |summary, j| {
                try self.appendSession(summary, j == bucket.items.len - 1, false);
            }
        }
    }

    fn appendDateHeader(self: *RowBuilder, label: []const u8, count: usize) !void {
        self.rows[self.index] = .{
            .io = self.io,
            .kind = .{ .date_header = .{ .label = label, .count = @intCast(@min(count, std.math.maxInt(u32))) } },
            .selected = false,
        };
        self.widgets[self.index] = self.rows[self.index].widget();
        self.index += 1;
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
            .filter = self.filter,
            .highlight_enabled = self.highlight_enabled,
            .highlight_style = self.highlight_style,
        };
        self.widgets[self.index] = self.rows[self.index].widget();
        self.index += 1;
    }
};

/// Classify a timestamp into a date bucket for grouping.
fn dateBucket(now_ms: i64, updated_at_ms: i64) DateBucket {
    const diff_ms = now_ms - updated_at_ms;
    if (diff_ms < 0) return .today;
    const seconds = @divTrunc(diff_ms, 1000);
    const minutes = @divTrunc(seconds, 60);
    const hours = @divTrunc(minutes, 60);
    const days = @divTrunc(hours, 24);
    if (days < 1) return .today;
    if (days < 2) return .yesterday;
    if (days < 7) return .this_week;
    if (days < 30) return .this_month;
    if (days < 365) return .this_year;
    return .older;
}

const Row = struct {
    io: std.Io,
    kind: Kind,
    selected: bool,
    filter: []const u8 = "",
    highlight_enabled: bool = true,
    highlight_style: config_mod.FuzzyHighlightStyle = .accent,

    const Kind = union(enum) {
        project: Project,
        session: Session,
        date_header: DateHeader,
    };

    const DateHeader = struct {
        label: []const u8,
        count: u32,
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
            .date_header => |header| try self.drawDateHeader(&surface, ctx, header),
        }
        return surface;
    }

    fn drawDateHeader(self: *Row, surface: *vxfw.Surface, ctx: vxfw.DrawContext, header: DateHeader) !void {
        _ = self;
        const p = tui_style.activePalette();
        const text = try std.fmt.allocPrint(ctx.arena, "  {s} ({d})", .{ header.label, header.count });
        try panel.lineStyledAt(surface, 0, text, ctx, 2, p.panel_header);
    }

    fn drawProject(self: *Row, surface: *vxfw.Surface, ctx: vxfw.DrawContext, project: Project) !void {
        const p = tui_style.activePalette();
        if (self.selected) panel.fillRow(surface, 0, p.selected);

        const marker = "  ";
        const start_col = message.ConversationLayout.left -| 1;
        const marker_style = if (self.selected)
            p.selected_item
        else
            p.thinking_body;
        try panel.lineStyledAt(surface, 0, marker, ctx, start_col, marker_style);

        var col: u16 = start_col + @as(u16, @intCast(ctx.stringWidth(marker)));
        const prefix_style = tui_style.onSelectionBg(p.thinking_body, self.selected);
        try panel.lineStyledAt(surface, 0, project.prefix, ctx, col, prefix_style);
        col += @intCast(ctx.stringWidth(project.prefix));

        const name = baseName(project.cwd);
        try panel.lineStyledAt(surface, 0, name, ctx, col, tui_style.onSelectionBg(p.markdown_code, self.selected));
        col += @intCast(ctx.stringWidth(name));

        const count = try std.fmt.allocPrint(ctx.arena, " ({d})", .{project.session_count});
        try panel.lineStyledAt(surface, 0, count, ctx, col, prefix_style);
    }

    fn drawSession(self: *Row, surface: *vxfw.Surface, ctx: vxfw.DrawContext, session: Session) !void {
        var buffer: [128]u8 = undefined;
        const modified = tui_status.modifiedTime(self.io, buffer[0..], session.summary.updated_at_ms);
        const left_width = resumeLeftWidth(ctx, surface.size.width, modified);
        const marker = "  ";
        const prefix_width = ctx.stringWidth(marker) + ctx.stringWidth(session.prefix);
        // The title is pre-truncated to account for the right-aligned time
        // column (m2); drawFuzzyListRow must not re-truncate it.
        const title = if (left_width <= prefix_width)
            ""
        else
            try truncateText(ctx, session.summary.title orelse "Untitled", left_width - prefix_width);
        // At extreme narrow widths draw only the marker (the tree prefix is
        // dropped entirely), matching the pre-migration behavior.
        const prefix = if (left_width > prefix_width and session.prefix.len > 0)
            try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ marker, session.prefix })
        else
            marker;
        try panel.drawFuzzyListRow(surface, 0, ctx, .{
            .prefix = prefix,
            .text = title,
            .query = self.filter,
            .selected = self.selected,
            .start_col = message.ConversationLayout.left -| 1,
            .highlight_enabled = self.highlight_enabled,
            .highlight_style = self.highlight_style,
        });
        try panel.right(surface, 0, modified, ctx, self.selected);
    }
};

pub fn visibleCount(io: std.Io, summaries: []const session_mod.SessionSummary, filter: []const u8, folded_projects: []const []const u8, group_by: app_state.NavState.ResumeGroupBy) u32 {
    return switch (group_by) {
        .flat => flatVisibleCount(summaries, filter),
        .project => projectVisibleCount(summaries, filter, folded_projects),
        .date => dateVisibleCount(io, summaries, filter),
    };
}

fn projectVisibleCount(summaries: []const session_mod.SessionSummary, filter: []const u8, folded_projects: []const []const u8) u32 {
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

fn dateVisibleCount(io: std.Io, summaries: []const session_mod.SessionSummary, filter: []const u8) u32 {
    // Count matching sessions, then add one header per non-empty date bucket.
    const now_ms = std.Io.Clock.now(.real, io).toMilliseconds();
    var seen_buckets: [6]bool = .{false} ** 6;
    var session_count: u32 = 0;
    for (summaries) |*summary| {
        if (!matches(summary, filter)) continue;
        session_count += 1;
        const bucket = dateBucket(now_ms, summary.updated_at_ms);
        seen_buckets[@intFromEnum(bucket)] = true;
    }
    var header_count: u32 = 0;
    for (seen_buckets) |seen| {
        if (seen) header_count += 1;
    }
    return session_count + header_count;
}

fn flatVisibleCount(summaries: []const session_mod.SessionSummary, filter: []const u8) u32 {
    var count: u32 = 0;
    for (summaries) |*summary| {
        if (matches(summary, filter)) count += 1;
    }
    return count;
}

pub fn selectedSummary(summaries: []const session_mod.SessionSummary, filter: []const u8, folded_projects: []const []const u8, selection: u32, group_by: app_state.NavState.ResumeGroupBy) ?*const session_mod.SessionSummary {
    return switch (group_by) {
        .flat => selectedFlatSummary(summaries, filter, selection),
        .project => selectedProjectSummary(summaries, filter, folded_projects, selection),
        .date => selectedFlatSummary(summaries, filter, selection),
    };
}

fn selectedProjectSummary(summaries: []const session_mod.SessionSummary, filter: []const u8, folded_projects: []const []const u8, selection: u32) ?*const session_mod.SessionSummary {
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

test "resume picker shows a first-run empty state when there are no sessions" {
    var list: vxfw.ListView = .{ .children = .{ .slice = &.{} }, .draw_cursor = false };
    var content: Content = .{
        .io = std.testing.io,
        .list = &list,
        .summaries = &.{},
        .selection = 0,
        .folded_projects = &.{},
        .filter = "",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 8 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try content.widget().draw(ctx);

    try std.testing.expectEqualStrings("N", surface.readCell(message.ConversationLayout.left -| 1, 0).char.grapheme);
}

test "resume picker shows a no-match empty state when the filter filters everything out" {
    var list: vxfw.ListView = .{ .children = .{ .slice = &.{} }, .draw_cursor = false };
    var content: Content = .{
        .io = std.testing.io,
        .list = &list,
        .summaries = &.{
            .{ .id = @constCast("1"), .title = @constCast("one"), .cwd = @constCast("/repo/a"), .created_at_ms = 0, .updated_at_ms = 1, .leaf_entry_id = null, .model_provider = null, .model_id = null, .reasoning_effort = null },
        },
        .selection = 0,
        .folded_projects = &.{},
        .filter = "zzz",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 8 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try content.widget().draw(ctx);

    try std.testing.expectEqualStrings("N", surface.readCell(message.ConversationLayout.left -| 1, 0).char.grapheme);
    const row1 = surface.readCell(message.ConversationLayout.left -| 1, 1).char.grapheme;
    try std.testing.expect(std.mem.eql(u8, row1, "A")); // "Adjust the search text above."
}

test "session tree counts project rows and folds children" {
    var summaries = [_]session_mod.SessionSummary{
        .{ .id = @constCast("1"), .title = @constCast("one"), .cwd = @constCast("/repo/a"), .created_at_ms = 0, .updated_at_ms = 2, .leaf_entry_id = null, .model_provider = null, .model_id = null, .reasoning_effort = null },
        .{ .id = @constCast("2"), .title = @constCast("two"), .cwd = @constCast("/repo/a"), .created_at_ms = 0, .updated_at_ms = 1, .leaf_entry_id = null, .model_provider = null, .model_id = null, .reasoning_effort = null },
        .{ .id = @constCast("3"), .title = @constCast("three"), .cwd = @constCast("/repo/b"), .created_at_ms = 0, .updated_at_ms = 3, .leaf_entry_id = null, .model_provider = null, .model_id = null, .reasoning_effort = null },
    };

    try std.testing.expectEqual(@as(u32, 3), visibleCount(std.testing.io, &summaries, "", &.{}, .flat));
    try std.testing.expectEqual(@as(u32, 5), visibleCount(std.testing.io, &summaries, "", &.{}, .project));
    try std.testing.expectEqual(@as(u32, 3), visibleCount(std.testing.io, &summaries, "", &.{"/repo/a"}, .project));
    try std.testing.expect(selectedProject(&summaries, "", &.{}, 0) != null);
    try std.testing.expect(selectedSummary(&summaries, "", &.{}, 1, .project) != null);
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
