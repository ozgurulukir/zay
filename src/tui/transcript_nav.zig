//! Transcript navigation: scrolling, auto-scroll, long-message paging.
//! Free functions taking `*App` — extracted from `tui.zig`.

const std = @import("std");

const tui = @import("../tui.zig");
const tui_message = @import("widgets/message.zig");
const tui_metrics = @import("metrics.zig");
const ConversationLayout = tui_message.ConversationLayout;
const messageRowsCached = tui_metrics.messageRowsCached;

const App = tui.App;

pub const TranscriptNavigation = enum { previous, next };

const long_message_scroll_step_rows: u16 = 3;

pub fn scrollStepRows(height: u16) u16 {
    if (height == 0) return 1;
    return @min(height, long_message_scroll_step_rows);
}

pub fn selectionIsLastMessage(app: *const App) bool {
    const selected = app.thread.transcript.selected orelse return false;
    if (app.thread.transcript.messages.items.len == 0) return false;
    return selected == app.thread.transcript.messages.items.len - 1;
}

pub fn jumpTranscriptToBottom(app: *App) void {
    app.nav.block_nav = false;
    app.thread.transcript.selectLast();
    app.thread.auto_scroll = true;
    app.thread.transcript_list.scroll.pending_lines = 0;
    app.thread.transcript_list.scroll.wants_cursor = false;
}

pub fn updateMouseAutoScroll(app: *App) void {
    app.thread.auto_scroll = !app.thread.transcript_list.scroll.has_more and
        selectionIsLastMessage(app) and
        !selectedMessageIsLong(app);
}

pub fn navigateTranscript(app: *App, direction: TranscriptNavigation) bool {
    app.thread.auto_scroll = false;
    if (scrollSelectedLongMessage(app, direction)) return true;

    const selected_before = app.thread.transcript.selected;
    switch (direction) {
        .previous => app.thread.transcript.moveSelection(.previous),
        .next => app.thread.transcript.moveSelection(.next),
    }
    if (app.thread.transcript.selected != selected_before) anchorSelectedLongMessage(app, direction);
    return false;
}

fn scrollSelectedLongMessage(app: *App, direction: TranscriptNavigation) bool {
    const selected = app.thread.transcript.selected orelse return false;
    if (selected >= app.thread.transcript.messages.items.len) return false;
    const rows = messageRowsCached(&app.thread.transcript.messages.items[selected], ConversationLayout.contentWidth(app.thread.transcript_view_width));
    const height = app.thread.transcript_view_height;
    if (rows <= height) return false;
    const rows_hidden = rows - height;
    const step = scrollStepRows(height);

    switch (direction) {
        .next => {
            const offset = selectedMessageOffset(app, selected);
            if (offset >= rows_hidden) return false;
            setSelectedMessageOffset(app, selected, @min(rows_hidden, offset + step));
            return true;
        },
        .previous => {
            const offset = selectedMessageOffset(app, selected);
            if (offset == 0) return false;
            setSelectedMessageOffset(app, selected, offset - @min(offset, step));
            return true;
        },
    }
}

pub fn selectedMessageIsLong(app: *const App) bool {
    const selected = app.thread.transcript.selected orelse return false;
    if (selected >= app.thread.transcript.messages.items.len) return false;
    const rows = messageRowsCached(&app.thread.transcript.messages.items[selected], ConversationLayout.contentWidth(app.thread.transcript_view_width));
    return rows > app.thread.transcript_view_height;
}

pub fn selectedMessageCanScrollDown(app: *const App) bool {
    const selected = app.thread.transcript.selected orelse return false;
    if (selected >= app.thread.transcript.messages.items.len) return false;
    const rows = messageRowsCached(&app.thread.transcript.messages.items[selected], ConversationLayout.contentWidth(app.thread.transcript_view_width));
    const height = app.thread.transcript_view_height;
    if (rows <= height) return false;
    return selectedMessageOffset(app, selected) < rows - height;
}

fn anchorSelectedLongMessage(app: *App, direction: TranscriptNavigation) void {
    const selected = app.thread.transcript.selected orelse return;
    if (selected >= app.thread.transcript.messages.items.len) return;
    const rows = messageRowsCached(&app.thread.transcript.messages.items[selected], ConversationLayout.contentWidth(app.thread.transcript_view_width));
    const height = app.thread.transcript_view_height;
    if (rows <= height) return;
    const offset = switch (direction) {
        .next => 0,
        .previous => rows - height,
    };
    setSelectedMessageOffset(app, selected, offset);
}

fn selectedMessageOffset(app: *const App, selected: u32) u16 {
    if (app.thread.transcript_list.scroll.top == selected) return @intCast(@max(app.thread.transcript_list.scroll.offset, 0));
    return 0;
}

pub fn setSelectedMessageOffset(app: *App, selected: u32, offset: u16) void {
    app.thread.transcript_list.cursor = selected;
    app.thread.transcript_list.scroll.top = selected;
    app.thread.transcript_list.scroll.offset = @intCast(offset);
    app.thread.transcript_list.scroll.pending_lines = 0;
    app.thread.transcript_list.scroll.wants_cursor = false;
}
