//! Transcript search overlay widget: the match list shown under the shared
//! palette search row while `Mode.search` is active.
//!
//! The state (`State`) and the pure scan live here; the mode lifecycle
//! (open/close/jump) lives in `search_lifecycle.zig`, mirroring the
//! resume-picker (`widgets/resume_picker.zig` + `session_switcher.zig`) split.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");
const tui_style = @import("../style.zig");
const transcript_mod = @import("../../transcript.zig");

/// One transcript match. `snippet` is owned (duped at rebuild time): the
/// overlay does NOT pause streaming — a turn keeps projecting deltas onto the
/// transcript while search is open, and `appendOwned`'s realloc can move (and
/// free) the very body a borrowed snippet pointed into. `role` is a static
/// literal from `searchable` and stays borrowed.
pub const Match = struct {
    message_index: u32,
    role: []const u8,
    snippet: []const u8,
    /// Byte range of the first query hit inside the message body (issue #484
    /// highlight + scroll-to-match). Zero-width when unavailable.
    start: usize = 0,
    end: usize = 0,
};

pub const Hit = struct {
    message_index: u32,
    start: usize,
    end: usize,
};

pub const max_hits: usize = 512;

pub const State = struct {
    matches: std.ArrayList(Match) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    active_hit: usize = 0,
    selection: u32 = 0,
    scroll: panel.ListScrollState = .{},
    /// True when the palette filter is empty (the overlay shows a usage hint
    /// rather than a "No matching messages" row).
    filter_empty: bool = true,
    /// The active query, kept alive after accept so the transcript draw path
    /// can highlight the matched text until the next open/clear (issue #484).
    /// Owned.
    query: ?[]u8 = null,

    /// Clear the match list. `keep_query` preserves the highlight query and
    /// hit-cycling state across the accept jump; a fresh open or close clears it.
    pub fn reset(self: *State, gpa: std.mem.Allocator, keep_query: bool) void {
        self.freeSnippets(gpa);
        self.matches.clearRetainingCapacity();
        self.selection = 0;
        self.scroll = .{};
        self.filter_empty = true;
        if (!keep_query) {
            self.hits.clearRetainingCapacity();
            self.active_hit = 0;
            if (self.query) |q| gpa.free(q);
            self.query = null;
        }
    }

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.freeSnippets(gpa);
        self.matches.deinit(gpa);
        self.hits.deinit(gpa);
        if (self.query) |q| gpa.free(q);
        self.* = undefined;
    }

    pub fn cycleHit(self: *State, forward: bool) ?Hit {
        const len = self.hits.items.len;
        if (len == 0) return null;
        if (forward) {
            self.active_hit = (self.active_hit + 1) % len;
        } else {
            self.active_hit = if (self.active_hit == 0) len - 1 else self.active_hit - 1;
        }
        return self.hits.items[self.active_hit];
    }

    pub fn activeHit(self: *const State) ?Hit {
        if (self.active_hit >= self.hits.items.len) return null;
        return self.hits.items[self.active_hit];
    }

    pub fn hitCounterText(self: *const State, buf: []u8) ?[]const u8 {
        if (self.hits.items.len == 0) return null;
        const current = @min(self.active_hit + 1, self.hits.items.len);
        return std.fmt.bufPrint(buf, "{d}/{d}", .{ current, self.hits.items.len }) catch null;
    }

    fn freeSnippets(self: *State, gpa: std.mem.Allocator) void {
        for (self.matches.items) |*match| {
            gpa.free(match.snippet);
            match.snippet = "";
        }
    }
};

/// The role label + display title/body a message contributes to search.
/// `.logo`/`.status` carry no searchable content.
pub const Searchable = struct {
    role: []const u8,
    title: []const u8,
    body: []const u8,
};

pub fn searchable(message: transcript_mod.Message) ?Searchable {
    return switch (message) {
        .user => |m| .{ .role = "user", .title = m.title, .body = m.body },
        .agent => |m| .{ .role = "agent", .title = m.title, .body = m.body },
        .notice => |m| .{ .role = "notice", .title = m.title, .body = m.body },
        .success => |m| .{ .role = "success", .title = m.title, .body = m.body },
        .info => |m| .{ .role = "info", .title = m.title, .body = m.body },
        .tool => |t| .{ .role = "tool", .title = t.title, .body = t.body },
        .skill => |m| .{ .role = "skill", .title = m.title, .body = m.body },
        .thinking => |m| .{ .role = "thinking", .title = m.title, .body = m.body },
        .logo, .status => null,
    };
}

pub const Content = struct {
    state: *State,
    palette: *const tui_style.Palette = &tui_style.default_palette,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const p = self.palette;
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        if (width == 0 or height == 0) return surface;

        const matches = self.state.matches.items;
        if (matches.len == 0) {
            // Empty query: hint at the workflow. Non-empty query with no hits:
            // the "No matching messages" row (same house pattern as the command
            // palette's "No matching commands").
            const hint = if (self.state.filter_empty)
                "  Type to search this transcript · Enter jumps · Esc closes"
            else
                "  No matching messages";
            panel.lineStyledAt(&surface, 0, hint, ctx, 1, p.thinking_body) catch {};
            return surface;
        }

        // Viewport math: only the visible rows are drawn, so a pathological
        // match count can never blow up the overlay.
        const viewport = panel.ViewportWindow.computeStateful(self.state.selection, @intCast(matches.len), height, &self.state.scroll);
        var match_idx = viewport.start_index;
        while (match_idx < viewport.end_index) : (match_idx += 1) {
            const m = matches[match_idx];
            const selected = match_idx == self.state.selection;
            const screen_row = viewport.screenRow(match_idx);
            var label_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{d} {s}  ", .{ m.message_index, m.role }) catch unreachable;
            try panel.commandLine(&surface, screen_row, label, ctx, selected, p);
            if (m.snippet.len > 0 and width > 24) {
                const desc_style = if (selected) p.selected_item else p.thinking_body;
                _ = panel.writeBorderTextEndingAt(&surface, ctx, screen_row, width -| 2, m.snippet, desc_style);
            }
        }
        return surface;
    }
};

// ---------------------------------------------------------------------------
// Tests

test "search content shows a no-matches row for a non-empty query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: State = .{ .filter_empty = false };
    var content: Content = .{ .state = &state };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 60, .height = 5 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try content.widget().draw(ctx);
    var buf: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, panel.readRow(&surface, 0, &buf), "No matching messages") != null);
}

test "search content shows a usage hint when the filter is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: State = .{ .filter_empty = true };
    var content: Content = .{ .state = &state };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 60, .height = 5 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try content.widget().draw(ctx);
    var buf: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, panel.readRow(&surface, 0, &buf), "Type to search") != null);
}

test "State.cycleHit wraps at both ends and formats n/m counter" {
    const gpa = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(gpa);

    try state.hits.append(gpa, .{ .message_index = 0, .start = 1, .end = 4 });
    try state.hits.append(gpa, .{ .message_index = 2, .start = 5, .end = 8 });
    try state.hits.append(gpa, .{ .message_index = 2, .start = 10, .end = 13 });

    var cbuf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1/3", state.hitCounterText(&cbuf).?);

    const h1 = state.cycleHit(true).?;
    try std.testing.expectEqual(@as(u32, 2), h1.message_index);
    try std.testing.expectEqualStrings("2/3", state.hitCounterText(&cbuf).?);

    const h2 = state.cycleHit(true).?;
    try std.testing.expectEqual(@as(usize, 10), h2.start);
    const h_wrap_fwd = state.cycleHit(true).?;
    try std.testing.expectEqual(@as(u32, 0), h_wrap_fwd.message_index);

    const h_wrap_back = state.cycleHit(false).?;
    try std.testing.expectEqual(@as(usize, 10), h_wrap_back.start);
}
