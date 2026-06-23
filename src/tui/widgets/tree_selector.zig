const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const session_mod = @import("../../session.zig");
const message = @import("message.zig");
const panel = @import("panel.zig");
const tui_style = @import("../style.zig");
const tree_art = @import("tree_art.zig");

const assert = std.debug.assert;
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
    tool_failed: bool,
    on_active_path: bool,
    is_leaf: bool,
    /// This entry carries a git snapshot (its `snapshot` column is set) — the
    /// code state at this conversation node. Drives the ✦ marker + navigation.
    has_snapshot: bool,
    text: []u8,
};

/// A node in the currently visible layout (rebuilt every `reflatten`, allocated
/// from the state arena).
const VisibleNode = struct {
    full_index: usize,
    /// Tree-art prefix (gutters + connector + fold marker), arena-owned.
    prefix: []const u8,
    text: []const u8,
    kind: session_mod.EntryKind,
    tool_failed: bool,
    is_leaf: bool,
    on_active_path: bool,
    is_folded: bool,
    is_foldable: bool,
    /// A git snapshot is bound at or within this row's collapsed segment (its own
    /// entry, or a hidden descendant like a tool result) — shown as a ✦ marker.
    has_snapshot: bool,
    /// The id of the snapshot-bearing entry this row maps to (the deepest one in
    /// its segment), or null when the row has none. Navigation targets it so
    /// `snapshotAt` resolves exactly that code state.
    snapshot_entry: ?Id,
};

/// Owns the full tree plus the fold/filter UI state for the `/timeline` overlay.
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
        // The conversation leaf is usually a (hidden) checkpoint; resolve it to
        // the nearest real message so that row — not nothing — is selected on open.
        var effective_leaf: ?Id = null;
        if (leaf_id) |id| {
            if (id.len == entry_id_len) {
                var current: Id = undefined;
                @memcpy(current[0..], id);
                while (true) {
                    try active.put(current, {});
                    const index = record_index.get(current) orelse break;
                    if (effective_leaf == null and !isCheckpointRecord(records[index])) effective_leaf = current;
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
            const is_leaf = effective_leaf != null and std.mem.eql(u8, record.id[0..], effective_leaf.?[0..]);
            try nodes.append(self.gpa, .{
                .id = record.id,
                .parent_id = record.parent_id,
                .kind = summary.kind,
                .tool_failed = summary.tool_failed,
                .on_active_path = active.contains(record.id),
                .is_leaf = is_leaf,
                .has_snapshot = record.snapshot != null,
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

    /// The entry to navigate to for the selected row: the snapshot-bearing entry
    /// the row maps to (so restoring its code state lands on exactly the commit
    /// the ✦ marks), otherwise the row's own entry — which inherits the nearest
    /// ancestor snapshot at restore time. Slice is stable until the next
    /// `reflatten`/`load`.
    pub fn selectedNavigationId(self: *const TreeState) ?[]const u8 {
        if (self.selection >= self.visible.len) return null;
        const node = &self.visible[self.selection];
        if (node.snapshot_entry) |*id| return id[0..];
        return self.nodes[node.full_index].id[0..];
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
        // Legacy `checkpoint`-kind entries (from old jj-era sessions) never appear
        // as their own rows.
        const visible_mask = try arena.alloc(bool, self.nodes.len);
        for (self.nodes, 0..) |node, i| {
            const kind_ok = node.kind != .checkpoint and (node.is_leaf or self.kindPasses(node.kind));
            const search_ok = search.len == 0 or containsIgnoreCase(node.text, search);
            visible_mask[i] = kind_ok and search_ok and !self.foldHidden(i);
        }

        // 2. Visible tree structure: nearest-visible parent + ordered children.
        // A snapshot-bearing entry (often a hidden tool result) tags the nearest
        // visible row at or above it with a ✦; pre-order means the deepest
        // snapshot in a row's collapsed segment wins (last-write), so the row maps
        // to the latest code state produced under it — which is what navigation
        // restores.
        const visible_parent = try arena.alloc(?usize, self.nodes.len);
        const has_snap = try arena.alloc(bool, self.nodes.len);
        @memset(has_snap, false);
        const snap_id = try arena.alloc(?Id, self.nodes.len);
        @memset(snap_id, null);
        const child_lists = try arena.alloc(std.ArrayList(usize), self.nodes.len);
        for (child_lists) |*list| list.* = .empty;
        var roots: std.ArrayList(usize) = .empty;
        for (self.nodes, 0..) |node, i| {
            if (visible_mask[i]) {
                const ancestor = self.nearestVisibleAncestor(i, visible_mask);
                visible_parent[i] = ancestor;
                if (ancestor) |parent| {
                    try child_lists[parent].append(arena, i);
                } else {
                    try roots.append(arena, i);
                }
                if (node.has_snapshot) {
                    has_snap[i] = true;
                    snap_id[i] = node.id;
                }
            } else {
                visible_parent[i] = null;
                if (node.has_snapshot) {
                    if (self.nearestVisibleAncestor(i, visible_mask)) |anc| {
                        has_snap[anc] = true;
                        snap_id[anc] = node.id; // last-wins: deepest in the segment
                    }
                }
            }
        }

        // 3a. DFS over the visible tree assigning each node a display indent.
        // The root and any single-child (linear) chain stay flush at indent 0 —
        // they read as one connected thread, not a staircase of siblings. The
        // indent steps in by one only at a branch: each arm, and that arm's
        // first continuation, moves one level deeper so sibling arms keep a free
        // `│` gutter column.
        const Layout = struct { full_index: usize, indent: u16, foldable: bool, is_folded: bool, branch_point: bool };
        var layout: std.ArrayList(Layout) = .empty;
        const Frame = struct { index: usize, indent: u16, just_branched: bool };
        var stack: std.ArrayList(Frame) = .empty;
        var root_index = roots.items.len;
        while (root_index > 0) {
            root_index -= 1;
            try stack.append(arena, .{ .index = roots.items[root_index], .indent = 0, .just_branched = false });
        }
        while (stack.pop()) |frame| {
            const kids = child_lists[frame.index].items;
            const multiple = kids.len > 1;
            // Fold controls appear on branch points and on the first node of
            // each branch arm when that arm has descendants.
            const foldable = self.isFoldable(frame.index);
            try layout.append(arena, .{
                .full_index = frame.index,
                .indent = frame.indent,
                .foldable = foldable,
                .is_folded = self.folded.contains(self.nodes[frame.index].id),
                .branch_point = multiple,
            });

            const child_indent: u16 = if (multiple or (frame.just_branched and frame.indent > 0))
                frame.indent + 1
            else
                frame.indent;

            var kid_index = kids.len;
            while (kid_index > 0) {
                kid_index -= 1;
                try stack.append(arena, .{ .index = kids[kid_index], .indent = child_indent, .just_branched = multiple });
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
                .kind = self.nodes[item.full_index].kind,
                .tool_failed = self.nodes[item.full_index].tool_failed,
                .is_leaf = self.nodes[item.full_index].is_leaf,
                .on_active_path = self.nodes[item.full_index].on_active_path,
                .is_folded = item.is_folded,
                .is_foldable = item.foldable,
                .has_snapshot = has_snap[item.full_index],
                .snapshot_entry = snap_id[item.full_index],
            });
        }

        self.visible = try out.toOwnedSlice(arena);
    }

    fn isFoldable(self: *const TreeState, index: usize) bool {
        assert(index < self.nodes.len);
        const own_children = self.childCount(index);
        if (own_children == 0) return false;
        if (own_children > 1) return true;
        const parent_id = self.nodes[index].parent_id orelse return false;
        const parent_index = self.index_by_id.get(parent_id) orelse return false;
        return self.childCount(parent_index) > 1;
    }

    fn childCount(self: *const TreeState, index: usize) u32 {
        assert(index < self.nodes.len);
        const id = self.nodes[index].id;
        var count: u32 = 0;
        for (self.nodes) |node| {
            if (node.parent_id) |parent_id| {
                if (std.mem.eql(u8, parent_id[0..], id[0..])) count += 1;
            }
        }
        return count;
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

fn isCheckpointRecord(record: session_mod.EntryRecord) bool {
    return std.mem.eql(u8, record.kind, "checkpoint");
}

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
        if (self.selected) panel.fillRow(&surface, 0, tui_style.Palette.selected);

        var col = message.ConversationLayout.left -| 1;
        const marker = "  ";
        const marker_style = if (self.selected)
            tui_style.Palette.selected_item
        else
            tui_style.Palette.thinking_body;
        try panel.lineStyledAt(&surface, 0, marker, ctx, col, marker_style);
        col += @intCast(ctx.stringWidth(marker));

        try panel.lineStyledAt(&surface, 0, self.node.prefix, ctx, col, tui_style.onSelectionBg(tui_style.Palette.thinking_body, self.selected));
        col += @intCast(ctx.stringWidth(self.node.prefix));

        const text = try self.displayText(ctx);
        try panel.lineStyledAt(&surface, 0, text, ctx, col, rowStyle(self.node.kind, self.node.tool_failed, self.selected));
        if (self.node.has_snapshot) {
            col += @intCast(ctx.stringWidth(text));
            try panel.lineStyledAt(&surface, 0, " ✦", ctx, col, tui_style.onSelectionBg(tui_style.Palette.checkpoint_mark, self.selected));
        }
        return surface;
    }

    fn displayText(self: *const Row, ctx: vxfw.DrawContext) ![]const u8 {
        if (self.node.kind != .tool) return self.node.text;
        if (std.mem.startsWith(u8, self.node.text, "🛠  ")) return self.node.text;
        return std.fmt.allocPrint(ctx.arena, "🛠  {s}", .{self.node.text});
    }
};

fn rowStyle(kind: session_mod.EntryKind, tool_failed: bool, selected: bool) vaxis.Style {
    _ = tool_failed;
    const style = switch (kind) {
        .user => tui_style.Palette.user,
        .assistant, .assistant_empty => tui_style.Palette.thinking_label,
        .tool => tui_style.Palette.thinking_body,
        .checkpoint => tui_style.Palette.checkpoint,
        .branch_summary, .session_info, .other => tui_style.Palette.thinking_body,
    };
    return tui_style.onSelectionBg(style, selected);
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
    // Linear roots stay flush; branch points get Pi's expand/collapse marker.
    try std.testing.expectEqualStrings("", state.visible[0].prefix);
    try std.testing.expect(std.mem.indexOf(u8, state.visible[1].prefix, "⊟") != null);
    // Its two children are the branch arms: one tee, one corner.
    try std.testing.expect(std.mem.indexOf(u8, state.visible[2].prefix, "├") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.visible[3].prefix, "╰") != null);
}

test "tool rows carry icon gray state" {
    const gpa = std.testing.allocator;
    var state = TreeState.init(gpa);
    defer state.deinit();
    var records = [_]session_mod.EntryRecord{
        makeTool("aaaaaaaa", null, "bash pwd", false),
        makeTool("bbbbbbbb", "aaaaaaaa", "bash false", true),
    };
    try state.load(&records, "bbbbbbbb");

    try std.testing.expectEqual(session_mod.EntryKind.tool, state.visible[0].kind);
    try std.testing.expect(!state.visible[0].tool_failed);
    try std.testing.expectEqualStrings("bash pwd", state.visible[0].text);
    try std.testing.expect(state.visible[1].tool_failed);
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

    // Branch-arm starts with descendants fold independently.
    state.selection = 1;
    try state.toggleFoldSelected("");
    try std.testing.expectEqual(@as(usize, 3), state.visible.len);
    try std.testing.expect(std.mem.indexOf(u8, state.visible[1].prefix, "⊞") != null);
    try state.toggleFoldSelected("");
    try std.testing.expectEqual(@as(usize, 4), state.visible.len);

    // Branch points also fold their whole subtree and show the folded marker.
    state.selection = 0;
    try state.toggleFoldSelected("");
    try std.testing.expectEqual(@as(usize, 1), state.visible.len);
    try std.testing.expect(std.mem.indexOf(u8, state.visible[0].prefix, "⊞") != null);
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

test "a hidden snapshot-bearing entry marks ✦ on its nearest visible row" {
    const gpa = std.testing.allocator;
    var state = TreeState.init(gpa);
    defer state.deinit();
    // user -> assistant -> tool(snapshot) -> assistant2(leaf). In the default
    // filter the tool is hidden; its snapshot tags the *assistant* row with ✦,
    // and navigating that row targets the tool entry (where the snapshot lives).
    var records = [_]session_mod.EntryRecord{
        makeMessage("aaaaaaaa", null, "user", "do it"),
        makeMessage("bbbbbbbb", "aaaaaaaa", "assistant", "running"),
        makeSnapshotTool("cccccccc", "bbbbbbbb"),
        makeMessage("dddddddd", "cccccccc", "assistant", "done"),
    };
    try state.load(&records, "dddddddd");

    // Rows: user, assistant, assistant2 (the tool is hidden).
    try std.testing.expectEqual(@as(usize, 3), state.visible.len);
    try std.testing.expect(!state.visible[0].has_snapshot);
    try std.testing.expect(state.visible[1].has_snapshot); // tagged by the tool
    try std.testing.expect(!state.visible[2].has_snapshot);

    // Selecting the assistant row navigates to the snapshot-bearing tool entry.
    state.selection = 1;
    try std.testing.expectEqualStrings("cccccccc", state.selectedNavigationId().?);
}

fn makeRecord(id: *const [8]u8, parent: ?*const [8]u8) session_mod.EntryRecord {
    return makeMessage(id, parent, "user", "x");
}

fn makeSnapshotTool(id: *const [8]u8, parent: ?*const [8]u8) session_mod.EntryRecord {
    var record = makeTool(id, parent, "build", false);
    record.snapshot = @constCast("0123456789abcdef0123456789abcdef01234567");
    return record;
}

fn makeTool(id: *const [8]u8, parent: ?*const [8]u8, comptime label: []const u8, failed: bool) session_mod.EntryRecord {
    var record = makeMessage(id, parent, "tool", "output");
    record.payload_json = if (failed)
        @constCast("{\"role\":\"tool\",\"tool_display_label\":\"" ++ label ++ "\",\"tool_failed\":true,\"content\":[{\"type\":\"text\",\"text\":\"output\"}]}")
    else
        @constCast("{\"role\":\"tool\",\"tool_display_label\":\"" ++ label ++ "\",\"content\":[{\"type\":\"text\",\"text\":\"output\"}]}");
    return record;
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
