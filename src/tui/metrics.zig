const std = @import("std");

const thread_mod = @import("../thread.zig");

pub const RowViewport = struct {
    first: u32,
    height: u16,
};

pub fn visibleRows(
    messages: []const thread_mod.Message,
    selected: ?u32,
    width: u16,
    height: u16,
) RowViewport {
    const total = threadRows(messages, width);
    if (total <= height) return .{ .first = 0, .height = height };

    const selected_index = selected orelse return .{
        .first = total - height,
        .height = height,
    };
    std.debug.assert(selected_index < messages.len);

    const last_index: u32 = @intCast(messages.len - 1);
    if (selected_index == last_index) {
        return .{ .first = total - height, .height = height };
    }

    const selected_start = messageStartRow(messages, selected_index, width);
    const selected_rows = messageRows(messages[selected_index], width);
    const selected_end = selected_start + selected_rows;
    if (selected_rows >= height) {
        return .{ .first = selected_start, .height = height };
    }
    if (selected_end <= height) {
        return .{ .first = 0, .height = height };
    }
    return .{ .first = selected_end - height, .height = height };
}

pub fn firstVisibleMessage(
    messages: []const thread_mod.Message,
    selected: ?u32,
    width: u16,
    height: u16,
) u32 {
    const first_row = visibleRows(messages, selected, width, height).first;
    var row: u32 = 0;
    var index: u32 = 0;
    while (index < messages.len) : (index += 1) {
        const next = row + messageRows(messages[index], width);
        if (next > first_row) return index;
        row = next;
    }
    return 0;
}

pub fn threadRows(messages: []const thread_mod.Message, width: u16) u32 {
    var rows: u32 = 0;
    for (messages) |message| {
        rows += messageRows(message, width);
    }
    return rows;
}

pub fn messageStartRow(messages: []const thread_mod.Message, index: u32, width: u16) u32 {
    std.debug.assert(index < messages.len);
    var rows: u32 = 0;
    var current: u32 = 0;
    while (current < index) : (current += 1) {
        rows += messageRows(messages[current], width);
    }
    return rows;
}

pub fn messageRows(message: thread_mod.Message, width: u16) u16 {
    return messageContentRows(message, width) + 2;
}

pub fn messageContentRows(message: thread_mod.Message, width: u16) u16 {
    return switch (message.kind) {
        .user => textRows(message.body, width -| 2),
        .agent => textRows(message.body, width),
        .logo => logoRows(message.body),
        .thinking => if (message.expanded)
            1 + textRows(message.body, width -| 2)
        else
            1,
        .status => 1,
        .tool => if (message.expanded)
            textRows(message.title, width) + toolBodyRows(message, width)
        else
            textRows(message.title, width),
    };
}

pub fn toolBodyRows(message: thread_mod.Message, width: u16) u16 {
    var rows: u16 = 0;
    if (message.body.len > 0) rows += textRows(message.body, width);
    if (message.stderr_body) |stderr| rows += textRows(stderr, width);
    return rows;
}

pub fn logoRows(text: []const u8) u16 {
    if (text.len == 0) return 1;
    var rows: u16 = 1;
    for (text) |byte| {
        if (byte == '\n') rows += 1;
    }
    return rows;
}

pub fn textRows(text: []const u8, width: u16) u16 {
    if (text.len == 0) return 1;
    const row_width = @max(@as(usize, width), 1);
    var rows: u16 = 1;
    var col: usize = 0;
    for (text) |byte| {
        if (byte == '\n') {
            rows += 1;
            col = 0;
            continue;
        }

        if (col >= row_width) {
            rows += 1;
            col = 0;
        }
        col += 1;
    }
    return rows;
}
