const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const session_mod = @import("../../session.zig");
const message = @import("message.zig");
const panel = @import("panel.zig");
const tui_style = @import("../style.zig");
const tree_art = @import("tree_art.zig");

const entry_id_len = session_mod.entry_id_len;
const Id = [entry_id_len]u8;

pub const FilterMode = enum {
    default,
    no_tools,
    user_only,
    all,

    pub fn label(self: FilterMode) []const u8 {
        return switch (self) {
            .default => "Default",
            .no_tools => "No tools",
            .user_only => "User only",
            .all => "Everything",
        };
    }

    fn next(self: FilterMode) FilterMode {
        return switch (self) {
            .default => .no_tools,
            .no_tools => .user_only,
            .user_only => .all,
            .all => .default,
        };
    }

    fn previous(self: FilterMode) FilterMode {
        return switch (self) {
            .default => .all,
            .no_tools => .default,
            .user_only => .no_tools,
            .all => .user_only,
        };
    }
};

/// A persistent node in the full session tree (kept across re-flattens, freed
/// on `load`/`deinit`).
const FullNode = struct {
    id: Id,
    parent_id: ?Id,
    kind: session_mod.EntryKind,
    on_active_path: bool,
    is_leaf: bool,
    text: []u8,
};

/// A node in the currently visible layout (rebuilt every `reflatten`, allocated
/// from the state arena).
const VisibleNode = struct {
    full_index: usize,
    /// Tree-art prefix (gutters + connector + fold marker), arena-owned.
    prefix: []const u8,
    text: []const u8,
    is_leaf: bool,
    on_active_path: bool,
    is_folded: bool,
    is_foldable: bool,
    branch_color: ?[3]u8,
};

/// Owns the full tree plus the fold/filter UI state for the `/tree` overlay.
/// The App holds one of these; the `Content` widget is a thin per-draw view.
pub const TreeState = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: []FullNode = &.{},
    index_by_id: std.AutoHashMapUnmanaged(Id, usize) = .{},
    folded: std.AutoHashMapUnmanaged(Id, void) = .{},
    filter_mode: FilterMode = .default,
    selection: u32 = 0,
    visible: []VisibleNode = &.{},

    pub fn init(gpa: std.mem.Allocator) TreeState {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *TreeState) void {
        self.freeNodes();
        self.index_by_id.deinit(self.gpa);
        self.folded.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    fn freeNodes(self: *TreeState) void {
        for (self.nodes) |*node| self.gpa.free(node.text);
        self.gpa.free(self.nodes);
        self.nodes = &.{};
    }

    /// Replace the tree from a session's entries (oldest-first). `leaf_id` marks
    /// the active branch. Resets fold/filter/search state.
    pub fn load(self: *TreeState, records: []const session_mod.EntryRecord, leaf_id: ?[]const u8) !void {
        self.freeNodes();
        self.index_by_id.clearRetainingCapacity();
        self.folded.clearRetainingCapacity();
        self.filter_mode = .default;
        self.selection = 0;

        // Map id -> record index, then assemble pre-order so a parent always
        // precedes its children and siblings keep chronological order.
        var record_index = std.AutoHashMap(Id, usize).init(self.gpa);
        defer record_index.deinit();
        try record_index.ensureTotalCapacity(@intCast(records.len));
        for (records, 0..) |record, i| record_index.putAssumeCapacity(record.id, i);

        const children = try self.gpa.alloc(std.ArrayList(usize), records.len);
        defer {
            for (children) |*list| list.deinit(self.gpa);
            self.gpa.free(children);
        }
        for (children) |*list| list.* = .empty;

        var roots: std.ArrayList(usize) = .empty;
        defer roots.deinit(self.gpa);
        for (records, 0..) |record, i| {
            if (record.parent_id) |parent_id| {
                if (record_index.get(parent_id)) |parent_index| {
                    try children[parent_index].append(self.gpa, i);
                    continue;
                }
            }
            try roots.append(self.gpa, i);
        }

        var active = std.AutoHashMap(Id, void).init(self.gpa);
        defer active.deinit();
        if (leaf_id) |id| {
            if (id.len == entry_id_len) {
                var current: Id = undefined;
                @memcpy(current[0..], id);
                while (true) {
                    try active.put(current, {});
                    const index = record_index.get(current) orelse break;
                    const parent = records[index].parent_id orelse break;
                    current = parent;
                }
            }
        }

        var nodes: std.ArrayList(FullNode) = .empty;
        errdefer {
            for (nodes.items) |*node| self.gpa.free(node.text);
            nodes.deinit(self.gpa);
        }

        const Frame = struct { index: usize };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(self.gpa);
        var root_index = roots.items.len;
        while (root_index > 0) {
            root_index -= 1;
            try stack.append(self.gpa, .{ .index = roots.items[root_index] });
        }

        while (stack.pop()) |frame| {
            const record = records[frame.index];
            const summary = try session_mod.entrySummary(self.gpa, record);
            errdefer self.gpa.free(summary.text);
            const is_leaf = leaf_id != null and std.mem.eql(u8, record.id[0..], leaf_id.?);
            try nodes.append(self.gpa, .{
                .id = record.id,
                .parent_id = record.parent_id,
                .kind = summary.kind,
                .on_active_path = active.contains(record.id),
                .is_leaf = is_leaf,
                .text = summary.text,
            });
            const kids = children[frame.index].items;
            var kid_index = kids.len;
            while (kid_index > 0) {
                kid_index -= 1;
                try stack.append(self.gpa, .{ .index = kids[kid_index] });
            }
        }

        self.nodes = try nodes.toOwnedSlice(self.gpa);
        try self.index_by_id.ensureTotalCapacity(self.gpa, @intCast(self.nodes.len));
        for (self.nodes, 0..) |node, i| self.index_by_id.putAssumeCapacity(node.id, i);

        try self.reflatten("");
        self.selection = self.leafSelection() orelse 0;
    }

    pub fn isEmpty(self: *const TreeState) bool {
        return self.nodes.len == 0;
    }

    pub fn visibleCount(self: *const TreeState) u32 {
        return @intCast(self.visible.len);
    }

    pub fn selectedId(self: *const TreeState) ?[]const u8 {
        if (self.selection >= self.visible.len) return null;
        return self.nodes[self.visible[self.selection].full_index].id[0..];
    }

    pub fn selectedIsLeaf(self: *const TreeState) bool {
        if (self.selection >= self.visible.len) return false;
        return self.visible[self.selection].is_leaf;
    }

    pub fn moveUp(self: *TreeState) void {
        if (self.visible.len == 0) return;
        self.selection = if (self.selection == 0) @intCast(self.visible.len - 1) else self.selection - 1;
    }

    pub fn moveDown(self: *TreeState) void {
        if (self.visible.len == 0) return;
        self.selection = if (self.selection + 1 >= self.visible.len) 0 else self.selection + 1;
    }

    pub fn cycleFilter(self: *TreeState, search: []const u8, forward: bool) !void {
        self.filter_mode = if (forward) self.filter_mode.next() else self.filter_mode.previous();
        try self.reflattenKeepingSelection(search);
    }

    /// Fold an expanded foldable node, or unfold a folded one. No-op otherwise.
    pub fn toggleFoldSelected(self: *TreeState, search: []const u8) !void {
        if (self.selection >= self.visible.len) return;
        const node = self.visible[self.selection];
        const id = self.nodes[node.full_index].id;
        if (node.is_folded) {
            _ = self.folded.remove(id);
        } else if (node.is_foldable) {
            try self.folded.put(self.gpa, id, {});
        } else {
            return;
        }
        try self.reflattenKeepingSelection(search);
    }

    /// Recompute the visible layout, preserving the selected node by id where
    /// possible (otherwise clamp).
    pub fn reflattenKeepingSelection(self: *TreeState, search: []const u8) !void {
        const previous: ?Id = if (self.selection < self.visible.len)
            self.nodes[self.visible[self.selection].full_index].id
        else
            null;
        try self.reflatten(search);
        if (previous) |id| {
            for (self.visible, 0..) |node, i| {
                if (std.mem.eql(u8, self.nodes[node.full_index].id[0..], id[0..])) {
                    self.selection = @intCast(i);
                    return;
                }
            }
        }
        if (self.selection >= self.visible.len) {
            self.selection = if (self.visible.len == 0) 0 else @intCast(self.visible.len - 1);
        }
    }

    fn leafSelection(self: *const TreeState) ?u32 {
        for (self.visible, 0..) |node, i| {
            if (node.is_leaf) return @intCast(i);
        }
        return null;
    }

    /// Rebuild `self.visible` for the current filter mode, fold set, and search.
    pub fn reflatten(self: *TreeState, search: []const u8) !void {
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        if (self.nodes.len == 0) {
            self.visible = &.{};
            return;
        }

        // 1. Visibility mask: filter + search, minus fold-hidden subtrees.
        const visible_mask = try arena.alloc(bool, self.nodes.len);
        for (self.nodes, 0..) |node, i| {
            const kind_ok = node.is_leaf or self.kindPasses(node.kind);
            const search_ok = search.len == 0 or containsIgnoreCase(node.text, search);
            visible_mask[i] = kind_ok and search_ok and !self.foldHidden(i);
        }

        // 2. Visible tree structure: nearest-visible parent + ordered children.
        const visible_parent = try arena.alloc(?usize, self.nodes.len);
        const child_lists = try arena.alloc(std.ArrayList(usize), self.nodes.len);
        for (child_lists) |*list| list.* = .empty;
        var roots: std.ArrayList(usize) = .empty;
        for (self.nodes, 0..) |_, i| {
            if (!visible_mask[i]) {
                visible_parent[i] = null;
                continue;
            }
            const ancestor = self.nearestVisibleAncestor(i, visible_mask);
            visible_parent[i] = ancestor;
            if (ancestor) |parent| {
                try child_lists[parent].append(arena, i);
            } else {
                try roots.append(arena, i);
            }
        }

        // 3a. DFS over the visible tree assigning each node a display indent.
        // The root and any single-child (linear) chain stay flush at indent 0 —
        // they read as one connected thread, not a staircase of siblings. The
        // indent steps in by one only at a branch: each arm, and that arm's
        // first continuation, moves one level deeper so sibling arms keep a free
        // `│` gutter column.
        const Layout = struct { full_index: usize, indent: u16, foldable: bool, is_folded: bool, branch_point: bool, branch_color: ?[3]u8 };
        var layout: std.ArrayList(Layout) = .empty;
        const Frame = struct { index: usize, indent: u16, just_branched: bool, branch_color: ?[3]u8 };
        var next_branch_color: usize = 0;
        var stack: std.ArrayList(Frame) = .empty;
        var root_index = roots.items.len;
        while (root_index > 0) {
            root_index -= 1;
            try stack.append(arena, .{ .index = roots.items[root_index], .indent = 0, .just_branched = false, .branch_color = null });
        }
        while (stack.pop()) |frame| {
            const kids = child_lists[frame.index].items;
            const multiple = kids.len > 1;
            const parent = visible_parent[frame.index];
            // Fold only at branches: a node is foldable when it is one arm of a
            // branch (its visible parent has >1 children) and has children of
            // its own. Folding hides that arm's descendants — its children, not
            // its siblings. Such a node always sits at indent ≥ 1, so its fold
            // marker rides in the connector's middle slot.
            const foldable = kids.len > 0 and parent != null and child_lists[parent.?].items.len > 1;
            const node_color: ?[3]u8 = if (multiple) null else frame.branch_color;
            try layout.append(arena, .{
                .full_index = frame.index,
                .indent = frame.indent,
                .foldable = foldable,
                .is_folded = self.folded.contains(self.nodes[frame.index].id),
                .branch_point = multiple,
                .branch_color = node_color,
            });

            const child_indent: u16 = if (multiple or (frame.just_branched and frame.indent > 0))
                frame.indent + 1
            else
                frame.indent;

            const first_child_color = next_branch_color;
            if (multiple) next_branch_color += kids.len;
            var kid_index = kids.len;
            while (kid_index > 0) {
                kid_index -= 1;
                const child_color = if (multiple) branchColor(first_child_color + kid_index) else node_color;
                try stack.append(arena, .{ .index = kids[kid_index], .indent = child_indent, .just_branched = multiple, .branch_color = child_color });
            }
        }

        // 3b. Second pass: derive connectors from the *displayed* layout. Within
        // a branch (indent ≥ 1) a run of nodes at the same indent connects as a
        // thread (`├─`…`╰─`); only the genuine last node at a level gets the
        // rounded corner. `last_at_indent[k]` tracks whether the current
        // ancestor at indent k is the last at its level (drives the `│`
        // gutters); pre-order + ≤+1 indent steps keep it pointing at ancestors.
        var out: std.ArrayList(VisibleNode) = try .initCapacity(arena, layout.items.len);
        var last_at_indent = [_]bool{false} ** (tree_art.max_levels + 2);
        for (layout.items, 0..) |item, i| {
            // Last at its level when the next node at indent <= this one steps
            // back out (indent <), or there is none.
            var is_last = true;
            var j = i + 1;
            while (j < layout.items.len) : (j += 1) {
                if (layout.items[j].indent == item.indent) {
                    is_last = false;
                    break;
                }
                if (layout.items[j].indent < item.indent) break;
            }
            const prefix = try tree_art.buildPrefix(arena, item.indent, is_last, last_at_indent[0..], item.is_folded, item.foldable, item.branch_point);
            if (item.indent <= tree_art.max_levels) last_at_indent[item.indent] = is_last;
            out.appendAssumeCapacity(.{
                .full_index = item.full_index,
                .prefix = prefix,
                .text = self.nodes[item.full_index].text,
                .is_leaf = self.nodes[item.full_index].is_leaf,
                .on_active_path = self.nodes[item.full_index].on_active_path,
                .is_folded = item.is_folded,
                .is_foldable = item.foldable,
                .branch_color = item.branch_color,
            });
        }

        self.visible = try out.toOwnedSlice(arena);
    }

    fn kindPasses(self: *const TreeState, kind: session_mod.EntryKind) bool {
        return switch (self.filter_mode) {
            .all => true,
            .user_only => kind == .user,
            .no_tools => kind != .tool and kind != .session_info and kind != .assistant_empty,
            .default => kind != .session_info and kind != .assistant_empty,
        };
    }

    /// True if any actual ancestor of node `i` is folded.
    fn foldHidden(self: *const TreeState, i: usize) bool {
        if (self.folded.count() == 0) return false;
        var current = self.nodes[i].parent_id;
        while (current) |parent_id| {
            if (self.folded.contains(parent_id)) return true;
            const parent_index = self.index_by_id.get(parent_id) orelse break;
            current = self.nodes[parent_index].parent_id;
        }
        return false;
    }

    fn nearestVisibleAncestor(self: *const TreeState, i: usize, visible_mask: []const bool) ?usize {
        var current = self.nodes[i].parent_id;
        while (current) |parent_id| {
            const parent_index = self.index_by_id.get(parent_id) orelse return null;
            if (visible_mask[parent_index]) return parent_index;
            current = self.nodes[parent_index].parent_id;
        }
        return null;
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub const Content = struct {
    state: *TreeState,
    list: *vxfw.ListView,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});

        if (self.state.isEmpty()) {
            try panel.commandLine(&surface, 0, "No messages yet.", ctx, false);
            return surface;
        }

        // Row 0 is a white status header: filter mode on the left, position on
        // the right (justify-between). Row 1 is blank padding; the scrollable
        // list starts at row 2.
        const white = tui_style.Palette.panel_header;
        const start_col = message.ConversationLayout.left -| 1;
        const mode_label = try std.fmt.allocPrint(ctx.arena, "Filter: {s}", .{self.state.filter_mode.label()});
        try panel.lineStyledAt(&surface, 0, mode_label, ctx, start_col, white);
        const position = if (self.state.visible.len == 0) 0 else self.state.selection + 1;
        const count = try std.fmt.allocPrint(ctx.arena, "{d}/{d}", .{ position, self.state.visible.len });
        try panel.right(&surface, 0, count, ctx, false);

        const widgets = try self.rowWidgets(ctx);
        self.list.children = .{ .slice = widgets };
        self.list.item_count = @intCast(widgets.len);
        self.list.cursor = self.state.selection;
        self.list.ensureScroll();

        const list_row: u16 = 2;
        const list_height = height -| list_row;
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{
            .origin = .{ .row = list_row, .col = 0 },
            .surface = try self.list.widget().draw(ctx.withConstraints(
                .{ .width = width, .height = list_height },
                .{ .width = width, .height = list_height },
            )),
            .z_index = 0,
        };
        surface.children = children;
        return surface;
    }

    fn rowWidgets(self: *Content, ctx: vxfw.DrawContext) ![]vxfw.Widget {
        const visible = self.state.visible;
        const widgets = try ctx.arena.alloc(vxfw.Widget, visible.len);
        const rows = try ctx.arena.alloc(Row, visible.len);
        for (visible, 0..) |*node, i| {
            rows[i] = .{ .node = node, .selected = i == self.state.selection };
            widgets[i] = rows[i].widget();
        }
        return widgets;
    }
};

const Row = struct {
    node: *const VisibleNode,
    selected: bool,

    fn widget(self: *Row) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Row = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = 1 }, &.{});
        const marker = if (self.selected) "‣ " else "  ";
        const text = try std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ marker, self.node.prefix, self.node.text });
        if (self.node.branch_color) |color| {
            if (self.selected) panel.fillRow(&surface, 0, tui_style.Palette.selected);
            try panel.lineStyledAt(&surface, 0, text, ctx, message.ConversationLayout.left -| 1, branchStyle(color, self.selected));
        } else {
            try panel.commandLine(&surface, 0, text, ctx, self.selected);
        }
        return surface;
    }
};

fn branchStyle(color: [3]u8, selected: bool) vaxis.Style {
    return tui_style.onSelectionBg(.{ .fg = .{ .rgb = color } }, selected);
}

fn branchColor(index: usize) [3]u8 {
    const hue = branchColorHue(index);
    const color = hsvToRgb(hue, 80, 255);
    std.debug.assert(color[0] <= 255);
    std.debug.assert(color[1] <= 255);
    std.debug.assert(color[2] <= 255);
    return color;
}

fn branchColorHue(index: usize) u16 {
    const excluded_min: u16 = 10;
    const excluded_max: u16 = 40;
    const excluded_count: u16 = excluded_max - excluded_min + 1;
    const allowed_count: u16 = 360 - excluded_count;
    const hue: u16 = @intCast((index *% 137 +% 17) % allowed_count);
    std.debug.assert(excluded_min <= excluded_max);
    std.debug.assert(hue < allowed_count);
    if (hue < excluded_min) return hue;
    return hue + excluded_count;
}

fn hsvToRgb(hue_degrees: u16, saturation_percent: u8, value: u8) [3]u8 {
    std.debug.assert(hue_degrees < 360);
    std.debug.assert(saturation_percent <= 100);

    const sector: u16 = hue_degrees / 60;
    const fraction: u16 = hue_degrees % 60;
    const chroma: u16 = @as(u16, value) * saturation_percent / 100;
    const minimum: u16 = @as(u16, value) - chroma;
    const rising: u16 = minimum + chroma * fraction / 60;
    const falling: u16 = minimum + chroma * (60 - fraction) / 60;

    const rgb: [3]u16 = switch (sector) {
        0 => .{ value, rising, minimum },
        1 => .{ falling, value, minimum },
        2 => .{ minimum, value, rising },
        3 => .{ minimum, falling, value },
        4 => .{ rising, minimum, value },
        else => .{ value, minimum, falling },
    };
    std.debug.assert(rgb[0] <= 255);
    std.debug.assert(rgb[1] <= 255);
    std.debug.assert(rgb[2] <= 255);
    return .{ @intCast(rgb[0]), @intCast(rgb[1]), @intCast(rgb[2]) };
}

test "linear chains stay flush; only branch children get connectors" {
    const gpa = std.testing.allocator;
    var state = TreeState.init(gpa);
    defer state.deinit();

    // root -> a -> {b, c}; leaf = b
    var records = [_]session_mod.EntryRecord{
        makeRecord("aaaaaaaa", null),
        makeRecord("bbbbbbbb", "aaaaaaaa"),
        makeRecord("cccccccc", "bbbbbbbb"),
        makeRecord("dddddddd", "bbbbbbbb"),
    };
    try state.load(&records, "cccccccc");

    try std.testing.expectEqual(@as(usize, 4), state.visible.len);
    // The root linear node renders flush, with no tree art.
    try std.testing.expectEqualStrings("", state.visible[0].prefix);
    // bbbbbbbb is a branch point: it grows a `┬` tee for its children to join.
    try std.testing.expectEqualStrings("┬ ", state.visible[1].prefix);
    // Its two children are the branch arms: one tee, one rounded last corner,
    // both aligned under the parent's `┬`.
    try std.testing.expect(std.mem.indexOf(u8, state.visible[2].prefix, "├") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.visible[3].prefix, "╰") != null);
}

test "branch arms have unique colors and branch points stay neutral" {
    const gpa = std.testing.allocator;
    var state = TreeState.init(gpa);
    defer state.deinit();

    // root -> branch -> {left, right}; each arm should get its own color, but
    // the branch point itself should not be color coded.
    var records = [_]session_mod.EntryRecord{
        makeRecord("aaaaaaaa", null),
        makeRecord("bbbbbbbb", "aaaaaaaa"),
        makeRecord("cccccccc", "bbbbbbbb"),
        makeRecord("dddddddd", "bbbbbbbb"),
    };
    try state.load(&records, "cccccccc");

    try std.testing.expectEqual(@as(?[3]u8, null), state.visible[1].branch_color);
    try std.testing.expect(state.visible[2].branch_color != null);
    try std.testing.expect(state.visible[3].branch_color != null);
    try std.testing.expect(!std.meta.eql(state.visible[2].branch_color.?, state.visible[3].branch_color.?));
}

test "branch colors stay vivid and avoid highlight orange" {
    var index: usize = 0;
    while (index < 128) : (index += 1) {
        const hue = branchColorHue(index);
        const color = branchColor(index);
        const channel_min = @min(color[0], @min(color[1], color[2]));
        const channel_max = @max(color[0], @max(color[1], color[2]));
        try std.testing.expect(hue < 10 or hue > 40);
        try std.testing.expect(channel_min <= 80);
        try std.testing.expect(channel_max >= 240);
    }
}

test "fold hides a subtree and unfold restores it" {
    const gpa = std.testing.allocator;
    var state = TreeState.init(gpa);
    defer state.deinit();
    var records = [_]session_mod.EntryRecord{
        makeRecord("aaaaaaaa", null),
        makeRecord("bbbbbbbb", "aaaaaaaa"),
        makeRecord("cccccccc", "aaaaaaaa"),
        makeRecord("dddddddd", "bbbbbbbb"),
    };
    try state.load(&records, "dddddddd");
    try std.testing.expectEqual(@as(usize, 4), state.visible.len);

    // Select bbbbbbbb (non-root with a child) and fold it; dddddddd hides.
    state.selection = 1;
    try state.toggleFoldSelected("");
    try std.testing.expectEqual(@as(usize, 3), state.visible.len);
    try state.toggleFoldSelected("");
    try std.testing.expectEqual(@as(usize, 4), state.visible.len);
}

test "user-only filter keeps only user turns" {
    const gpa = std.testing.allocator;
    var state = TreeState.init(gpa);
    defer state.deinit();
    var records = [_]session_mod.EntryRecord{
        makeMessage("aaaaaaaa", null, "user", "hello"),
        makeMessage("bbbbbbbb", "aaaaaaaa", "assistant", "hi there"),
        makeMessage("cccccccc", "bbbbbbbb", "user", "bye"),
    };
    try state.load(&records, "cccccccc");
    try std.testing.expectEqual(@as(usize, 3), state.visible.len);
    try state.cycleFilter("", true); // default -> no_tools
    try state.cycleFilter("", true); // no_tools -> user_only
    try std.testing.expectEqual(FilterMode.user_only, state.filter_mode);
    try std.testing.expectEqual(@as(usize, 2), state.visible.len);
}

fn makeRecord(id: *const [8]u8, parent: ?*const [8]u8) session_mod.EntryRecord {
    return makeMessage(id, parent, "user", "x");
}

fn makeMessage(id: *const [8]u8, parent: ?*const [8]u8, comptime role: []const u8, comptime text: []const u8) session_mod.EntryRecord {
    var record: session_mod.EntryRecord = undefined;
    @memcpy(record.id[0..], id);
    if (parent) |p| {
        var buffer: [8]u8 = undefined;
        @memcpy(buffer[0..], p);
        record.parent_id = buffer;
    } else {
        record.parent_id = null;
    }
    record.kind = @constCast("message");
    record.role = @constCast(role);
    record.payload_json = @constCast("{\"role\":\"" ++ role ++ "\",\"content\":[{\"type\":\"text\",\"text\":\"" ++ text ++ "\"}]}");
    record.created_at_ms = 0;
    return record;
}
