//! Transcript search lifecycle: open/close, match-list rebuild, and Enter-jump.
//! Free functions taking `*App`, extracted into their own module so `tui.zig`
//! stays lean. The overlay widget + pure scan live in `widgets/search.zig`.

const std = @import("std");

const tui = @import("../tui.zig");
const search_widget = @import("widgets/search.zig");
const command_panel = @import("widgets/command_panel.zig");

const App = tui.App;

/// Open the transcript-search overlay. The palette input owns the query; a
/// leading `/` in it routes to the command menu (see `shouldOpenCommandMenuForSlash`).
pub fn openSearch(app: *App) !void {
    app.mode = .search;
    app.pickers.search.reset(app.gpa);
    app.clearInput();
    app.clearPaletteInput();
    try rebuildMatches(app, "");
}

pub fn closeSearch(app: *App) void {
    app.mode = .normal;
    app.pickers.search.reset(app.gpa);
    app.clearInput();
    app.clearPaletteInput();
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
    }
    app.mode = .normal;
    app.pickers.search.reset(app.gpa);
    app.clearInput();
    app.clearPaletteInput();
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
    state.reset(app.gpa);
    state.filter_empty = filter.len == 0;
    if (filter.len == 0) return;

    const messages = app.thread.transcript.messages.items;
    for (messages, 0..) |message, index| {
        const src = search_widget.searchable(message) orelse continue;
        const body_match = firstMatchingLine(src.body, filter);
        if (command_panel.containsIgnoreCase(src.title, filter) or body_match != null) {
            // Dup the snippet: the transcript keeps streaming while the overlay
            // is open, and a realloc of the source body would dangle a borrow.
            const snippet = try app.gpa.dupe(u8, body_match orelse src.title);
            errdefer app.gpa.free(snippet);
            try state.matches.append(app.gpa, .{
                .message_index = @intCast(index),
                .role = src.role,
                .snippet = snippet,
            });
        }
    }
}

/// The first line of `text` containing `filter`, or null. Split on `\n`; each
/// line is searched case-insensitively.
fn firstMatchingLine(text: []const u8, filter: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (command_panel.containsIgnoreCase(line, filter)) return line;
    }
    return null;
}
