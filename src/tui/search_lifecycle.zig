//! Transcript search lifecycle: open/close, match-list rebuild, and Enter-jump.
//! Free functions taking `*App`, extracted into their own module so `tui.zig`
//! stays lean. The overlay widget + pure scan live in `widgets/search.zig`.

const std = @import("std");

const tui = @import("../tui.zig");
const panel = @import("widgets/panel.zig");
const search_widget = @import("widgets/search.zig");
const ConversationLayout = @import("widgets/message.zig").ConversationLayout;
const terminal_markdown = @import("terminal_markdown");
const tui_metrics = @import("metrics.zig");
const transcript_nav = @import("transcript_nav.zig");

const App = tui.App;

/// Open the transcript-search overlay. The palette input owns the query; a
/// leading `/` in it routes to the command menu (see `shouldOpenCommandMenuForSlash`).
pub fn openSearch(app: *App) !void {
    app.pickers.search.reset(app.gpa, false);
    app.setMode(.search);
    try rebuildMatches(app, "");
}

pub fn closeSearch(app: *App) void {
    app.pickers.search.reset(app.gpa, false);
    app.setMode(.normal);
}

/// Jump to the selected match: pin the transcript selection, disable
/// auto-scroll (the next draw's `syncCursor` scrolls the list to it), and leave
/// search mode. Mirrors the at-mention Enter-jump pattern.
pub fn acceptSearchSelection(app: *App) !void {
    const state = &app.pickers.search;
    if (state.selection >= state.matches.items.len) return;
    const match = state.matches.items[state.selection];
    if (match.message_index < app.thread.transcript.messages.items.len) {
        app.thread.transcript.select(match.message_index);
        app.setThreadAutoScroll(false);
        scrollMatchIntoView(app, match);
    }
    // Keep the query alive so the transcript keeps highlighting the hit after
    // the jump (issue #484); the next open/close clears it.
    app.pickers.search.reset(app.gpa, true);
    app.setMode(.normal);
}

/// Scroll the selected message so the matched row is inside the viewport.
/// Rows above the hit are counted with the same counters the row cache uses
/// (markdown countRows for agent bodies, the byte-based textRows for plain
/// kinds) at the live transcript width, then clamped to the message height.
fn scrollMatchIntoView(app: *App, match: search_widget.Match) void {
    const message = &app.thread.transcript.messages.items[match.message_index];
    const body: []const u8 = switch (message.*) {
        .user => |m| m.body,
        .agent => |m| m.body,
        .skill => |m| m.body,
        .notice => |m| m.body,
        .success => |m| m.body,
        .info => |m| m.body,
        .thinking => |m| m.body,
        else => return,
    };
    if (match.start > body.len) return;
    const width = ConversationLayout.contentWidth(app.thread.transcript_view_width);
    var rows_before: u16 = switch (message.*) {
        .agent => terminal_markdown.countRows(std.heap.page_allocator, body[0..match.start], width),
        else => tui_metrics.textRows(body[0..match.start], width),
    };
    // One title row above the body (see messageRowsCached's +1).
    rows_before += 1;
    const total_rows = tui_metrics.messageRowsCached(message, width);
    const offset = @min(rows_before, total_rows -| 1);
    transcript_nav.setSelectedMessageOffset(app, match.message_index, offset);
}

/// Rebuild the match list from the current transcript for `filter`, in document
/// order (oldest → newest). Empty filter clears the list (the overlay shows a
/// usage hint). O(total bytes) per keystroke, which is fine at transcript
/// scale; if a session ever grows past ~10k messages, move this scan behind the
/// same background-job pattern as `model_loader_job.zig` — noted, not built
/// (YAGNI).
pub fn rebuildMatches(app: *App, filter: []const u8) !void {
    const state = &app.pickers.search;
    // `reset` frees the previous rebuild's owned snippets before clearing.
    state.reset(app.gpa, false);
    state.filter_empty = filter.len == 0;
    // Own the query so the transcript draw path can highlight hits after the
    // accept jump (a realloc of the palette input's buffer would dangle a
    // borrow).
    if (state.query) |q| app.gpa.free(q);
    state.query = if (filter.len > 0) try app.gpa.dupe(u8, filter) else null;
    if (filter.len == 0) return;

    const messages = app.thread.transcript.messages.items;
    for (messages, 0..) |message, index| {
        const src = search_widget.searchable(message) orelse continue;
        const body_match = firstMatchingLine(src.body, filter);
        if (panel.containsIgnoreCase(src.title, filter) or body_match != null) {
            // Byte range of the first hit inside the body (highlight +
            // scroll-to-match); zero when only the title matched.
            const range: ByteRange = if (body_match != null) firstMatchRange(src.body, filter) else .{ .start = 0, .end = 0 };
            // Dup the snippet: the transcript keeps streaming while the overlay
            // is open, and a realloc of the source body would dangle a borrow.
            const snippet = try app.gpa.dupe(u8, body_match orelse src.title);
            errdefer app.gpa.free(snippet);
            try state.matches.append(app.gpa, .{
                .message_index = @intCast(index),
                .role = src.role,
                .snippet = snippet,
                .start = range.start,
                .end = range.end,
            });
        }
    }
}

/// Byte range `[start, end)` of the first case-insensitive `filter` hit in
/// `text`. Returns zeroes when there is no hit.
const ByteRange = struct { start: usize, end: usize };

fn firstMatchRange(text: []const u8, filter: []const u8) ByteRange {
    if (filter.len == 0 or filter.len > text.len) return .{ .start = 0, .end = 0 };
    var i: usize = 0;
    while (i + filter.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + filter.len], filter)) {
            return .{ .start = i, .end = i + filter.len };
        }
    }
    return .{ .start = 0, .end = 0 };
}

/// The first line of `text` containing `filter`, or null. Split on `\n`; each
/// line is searched case-insensitively.
fn firstMatchingLine(text: []const u8, filter: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (panel.containsIgnoreCase(line, filter)) return line;
    }
    return null;
}

test "rebuildMatches records byte ranges and keeps the query after accept" {
    const gpa = std.testing.allocator;
    // This test exercises the pure pieces: range finding + state ownership
    // (the full accept path needs a scripted-turn App fixture, covered by the
    // router tests).
    try std.testing.expectEqual(ByteRange{ .start = 4, .end = 10 }, firstMatchRange("abc needle def", "NEEDLE"));
    try std.testing.expectEqual(ByteRange{ .start = 0, .end = 0 }, firstMatchRange("abc", ""));
    try std.testing.expectEqual(ByteRange{ .start = 0, .end = 0 }, firstMatchRange("short", "much longer query"));

    var state: search_widget.State = .{};
    defer state.deinit(gpa);
    state.query = try gpa.dupe(u8, "needle");
    // keep_query=true must preserve it across a reset (the accept path).
    state.reset(gpa, true);
    try std.testing.expect(state.query != null);
    state.reset(gpa, false);
    try std.testing.expect(state.query == null);
}
