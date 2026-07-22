//! TUI Clipboard Integration Helper.
//!
//! Bridges TUI modes, inputs, and selection state with `clipboard.zig`.

const std = @import("std");
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");
const clipboard_mod = @import("../clipboard.zig");

const App = tui.App;

/// Paste `text` into whichever text input currently has focus for `app.mode`.
pub fn pasteToFocusedInput(app: *App, text: []const u8) !void {
    if (text.len == 0) return;
    const clean_text = std.mem.trim(u8, text, "\r\n");
    if (clean_text.len == 0) return;

    switch (app.getMode()) {
        .normal => {
            try app.inputs.input.insertSliceAtCursor(clean_text);
        },
        .command, .session_picker, .model_picker, .tree_picker => {
            try app.inputs.palette.insertSliceAtCursor(clean_text);
        },
        .provider_picker => {
            if (app.pickers.provider.stage == .form) {
                try app.getProviderKeyInput().appendSlice(app.gpa, clean_text);
            }
        },
        .settings => {
            if (app.pickers.settings.edit_target != .none) {
                try app.settings_text_input.appendSlice(app.gpa, clean_text);
            }
        },
        .diff_viewer => {
            if (app.diff.sub == .commenting) {
                try app.inputs.comment.insertSliceAtCursor(clean_text);
            } else if (app.diff.sub == .file_search) {
                try app.inputs.palette.insertSliceAtCursor(clean_text);
            }
        },
        .save_message => {
            try app.inputs.palette.insertSliceAtCursor(clean_text);
        },
        .lanes, .help => {},
    }
}

/// Paste system clipboard content into the focused input field.
pub fn pasteFromSystemClipboard(app: *App) !bool {
    if (clipboard_mod.readFromClipboard(app.gpa, app.getIo())) |text| {
        defer app.gpa.free(text);
        try pasteToFocusedInput(app, text);
        return true;
    }
    return false;
}

/// Copy the text of the selected transcript block (or last agent response) to clipboard.
pub fn copySelectedTranscriptBlock(app: *App) !bool {
    const selected_idx = app.thread.transcript.selected orelse blk: {
        // Fall back to last agent response if no block is selected.
        if (app.thread.transcript.messages.items.len == 0) return false;
        var i = app.thread.transcript.messages.items.len;
        while (i > 0) {
            i -= 1;
            const msg = &app.thread.transcript.messages.items[i];
            if (msg.kind == .agent) break :blk @as(u32, @intCast(i));
        }
        break :blk @as(u32, @intCast(app.thread.transcript.messages.items.len - 1));
    };

    if (selected_idx >= app.thread.transcript.messages.items.len) return false;
    const msg = &app.thread.transcript.messages.items[selected_idx];
    const text = msg.body;
    if (text.len == 0) return false;

    clipboard_mod.copyToClipboard(app.gpa, app.getIo(), text);

    var notice_buf: [256]u8 = undefined;
    const kind_name = @tagName(msg.kind);
    const notice_text = try std.fmt.bufPrint(&notice_buf, "Copied {s} message block to clipboard ({d} bytes).", .{ kind_name, text.len });
    _ = try app.thread.transcript.append(app.gpa, .notice, "clipboard", notice_text);
    return true;
}

/// Copy current diff file patch or review text to clipboard.
pub fn copyDiffToClipboard(app: *App) !bool {
    if (!app.isDiffViewerMode()) return false;
    const composed = try app.diff.composeMessage(app.gpa);
    if (composed) |msg| {
        defer app.gpa.free(msg);
        clipboard_mod.copyToClipboard(app.gpa, app.getIo(), msg);
        _ = try app.thread.transcript.append(app.gpa, .notice, "clipboard", "Copied diff review comments to clipboard.");
        return true;
    }
    return false;
}

const agent_mod = @import("../agent.zig");

test "pasteToFocusedInput inserts text into main prompt in normal mode" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .normal;
    try pasteToFocusedInput(&app, "pasted prompt text\n");

    const val = try app.peekInput();
    defer gpa.free(val);
    try std.testing.expectEqualStrings("pasted prompt text", val);
}

test "pasteToFocusedInput inserts text into provider key input in provider form" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .provider_picker;
    app.pickers.provider.stage = .form;

    try pasteToFocusedInput(&app, "sk-proj-12345");
    try std.testing.expectEqualStrings("sk-proj-12345", app.provider_key_input.items);
}
