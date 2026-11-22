//! TUI Clipboard Integration Helper.
//!
//! Bridges TUI modes, inputs, and selection state with `clipboard.zig`.

const std = @import("std");
const tui = @import("../tui.zig");
const clipboard_mod = @import("../clipboard.zig");
const mode_lifecycle = @import("mode_lifecycle.zig");
const paste_stash_mod = @import("paste_stash.zig");
const tools_common = @import("../tools/common.zig");

const App = tui.App;

/// Paste `text` into whichever text input currently has focus for `app.mode`.
/// The target comes from `mode_lifecycle.modeTextInputSlot`, so paste
/// routing follows the shared mode/sub-state classifier rather than a
/// private switch. This arm carries no extra policy: paste drops text in
/// every `.none` slot, including the provider list stage (typing filters
/// there, paste does not).
pub fn pasteToFocusedInput(app: *App, text: []const u8) !void {
    if (text.len == 0) return;
    // The prompt is a multiline field: paste goes through the shared display
    // normalizer (tools_common.normalizeDisplayText) so CRLF folds to LF,
    // tabs expand to predictable column stops, and escape/control bytes from
    // the clipboard never reach the input buffer — cursor math in the input
    // widget stays correct without per-tab width handling. Every other target
    // is single-line — trim line endings so a multiline clipboard can't leak
    // newlines into a filter field.
    var normalized: ?[]u8 = null;
    const clean_text: []const u8 = if (app.getMode() == .normal) blk: {
        const buf = try tools_common.normalizeDisplayText(app.gpa, text);
        normalized = buf;
        break :blk buf;
    } else std.mem.trim(u8, text, "\r\n");
    defer if (normalized) |buf| app.gpa.free(buf);
    if (clean_text.len == 0) return;

    switch (mode_lifecycle.modeTextInputSlot(app)) {
        .prompt => {
            if (paste_stash_mod.shouldCollapse(clean_text)) {
                const current = try app.inputs.input.buf.dupe();
                defer app.gpa.free(current);
                const cursor = app.inputs.input.buf.cursor;
                const placeholder = try app.inputs.paste_stash.stashAt(app.gpa, clean_text, current, cursor);
                try app.inputs.input.insertSliceAtCursor(placeholder);
            } else {
                try app.inputs.input.insertSliceAtCursor(clean_text);
            }
        },
        .palette => try app.inputs.palette.insertSliceAtCursor(clean_text),
        .session_rename => try app.input_buffers.session_rename_text.appendSlice(app.gpa, clean_text),
        .session_project_root => try app.input_buffers.project_root_text.appendSlice(app.gpa, clean_text),
        .provider_key => {
            try app.getProviderKeyInput().appendSlice(app.gpa, clean_text);
            // Paste bypasses ProviderPicker.handle, so mark the key dirty
            // here too — otherwise a pasted key over a pre-filled one stays
            // masked and the user can't verify the paste.
            app.pickers.provider.key_dirty = true;
        },
        .settings_value => try app.input_buffers.settings_text.appendSlice(app.gpa, clean_text),
        .diff_comment => try app.inputs.comment.insertSliceAtCursor(clean_text),
        .mcp_url => try app.input_buffers.mcp_url.appendSlice(app.gpa, clean_text),
        .none => {},
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

fn formatTruncSuffix(res: clipboard_mod.CopyResult) []const u8 {
    return if (res.truncated) " (truncated at 10 MB limit)" else "";
}

/// Copy arbitrary `text` to the system clipboard and append an info notice.
pub fn copyTextWithNotice(app: *App, text: []const u8, notice: []const u8) !void {
    if (text.len == 0) return;
    const res = clipboard_mod.copyToClipboard(app.gpa, app.getIo(), text);
    if (res.truncated) {
        const msg = try std.fmt.allocPrint(app.gpa, "{s} (copied {d} bytes, truncated at 10 MB limit)", .{ notice, res.copied_bytes });
        defer app.gpa.free(msg);
        _ = try app.thread.transcript.append(app.gpa, .info, "clipboard", msg);
    } else {
        _ = try app.thread.transcript.append(app.gpa, .info, "clipboard", notice);
    }
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
            if (msg.* == .agent) break :blk @as(u32, @intCast(i));
        }
        break :blk @as(u32, @intCast(app.thread.transcript.messages.items.len - 1));
    };

    if (selected_idx >= app.thread.transcript.messages.items.len) return false;
    const msg = &app.thread.transcript.messages.items[selected_idx];
    const mirror = msg.mirror();
    const text = mirror.body;
    if (text.len == 0) return false;

    // A within-body selection (issue #487) copies just the selected logical
    // bytes — unwrapped source text, no card margins or bar glyphs.
    if (app.thread.transcript.body_selection) |selection| {
        if (selection.message_index == selected_idx) {
            const range = selection.range();
            if (range[1] > range[0] and range[1] <= text.len) {
                const res = clipboard_mod.copyToClipboard(app.gpa, app.getIo(), text[range[0]..range[1]]);
                var notice_buf: [160]u8 = undefined;
                const notice = std.fmt.bufPrint(&notice_buf, "Copied {d} selected bytes{s}", .{ res.copied_bytes, formatTruncSuffix(res) }) catch "Copied selection";
                _ = try app.thread.transcript.append(app.gpa, .info, "clipboard", notice);
                return true;
            }
        }
    }

    const res = clipboard_mod.copyToClipboard(app.gpa, app.getIo(), text);

    var notice_buf: [256]u8 = undefined;
    const kind_name = @tagName(mirror.kind);
    const notice_text = try std.fmt.bufPrint(&notice_buf, "Copied {s} message as plain text ({d} bytes{s}).", .{ kind_name, res.copied_bytes, formatTruncSuffix(res) });
    _ = try app.thread.transcript.append(app.gpa, .notice, "clipboard", notice_text);
    return true;
}

/// Copy the selected transcript message's original Markdown source bytes and
/// announce the format in a notice (issue #514).
pub fn copySelectedTranscriptBlockAsMarkdown(app: *App) !bool {
    const selected_idx = app.thread.transcript.selected orelse return false;
    if (selected_idx >= app.thread.transcript.messages.items.len) return false;
    const mirror = app.thread.transcript.messages.items[selected_idx].mirror();
    if (mirror.body.len == 0) return false;

    const res = clipboard_mod.copyToClipboard(app.gpa, app.getIo(), mirror.body);
    var notice_buf: [256]u8 = undefined;
    const notice_text = try std.fmt.bufPrint(&notice_buf, "Copied {s} message as Markdown ({d} bytes{s}).", .{ @tagName(mirror.kind), res.copied_bytes, formatTruncSuffix(res) });
    _ = try app.thread.transcript.append(app.gpa, .notice, "clipboard", notice_text);
    return true;
}

/// Copy the first `path[:line[:col]]` token in the active selection (when
/// present) or in the selected message body (issue #514).
pub fn copyFirstPathToken(app: *App) !bool {
    const token_scan = @import("token_scan.zig");
    const selected_idx = app.thread.transcript.selected orelse return false;
    if (selected_idx >= app.thread.transcript.messages.items.len) return false;
    const body = app.thread.transcript.messages.items[selected_idx].mirror().body;
    if (body.len == 0) return false;

    var scan_slice: []const u8 = body;
    if (app.thread.transcript.body_selection) |selection| {
        if (selection.message_index == selected_idx) {
            const range = selection.range();
            if (range[1] > range[0] and range[1] <= body.len) {
                const sel_tokens = try token_scan.scanPathLineTokens(app.gpa, body[range[0]..range[1]], 1);
                if (sel_tokens.len > 0) {
                    defer app.gpa.free(sel_tokens);
                    const tok = body[range[0] + sel_tokens[0].start .. range[0] + sel_tokens[0].end];
                    _ = clipboard_mod.copyToClipboard(app.gpa, app.getIo(), tok);
                    var notice_buf: [256]u8 = undefined;
                    const notice_text = std.fmt.bufPrint(&notice_buf, "Copied path token: {s}", .{tok}) catch "Copied path token";
                    _ = try app.thread.transcript.append(app.gpa, .notice, "clipboard", notice_text);
                    return true;
                }
                app.gpa.free(sel_tokens);
                scan_slice = body;
            }
        }
    }

    const tokens = try token_scan.scanPathLineTokens(app.gpa, scan_slice, 1);
    defer app.gpa.free(tokens);
    if (tokens.len == 0) {
        _ = try app.thread.transcript.append(app.gpa, .notice, "clipboard", "No path:line token found in selected message.");
        return true;
    }
    const tok = scan_slice[tokens[0].start..tokens[0].end];
    _ = clipboard_mod.copyToClipboard(app.gpa, app.getIo(), tok);
    var notice_buf: [256]u8 = undefined;
    const notice_text = std.fmt.bufPrint(&notice_buf, "Copied path token: {s}", .{tok}) catch "Copied path token";
    _ = try app.thread.transcript.append(app.gpa, .notice, "clipboard", notice_text);
    return true;
}

/// Extract the first fenced code block content from a markdown body.
pub fn extractFirstCodeBlock(text: []const u8) ?[]const u8 {
    var line_start: usize = 0;
    var fence_start: ?usize = null;
    while (line_start < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = std.mem.trim(u8, text[line_start..line_end], " \t\r");
        if (std.mem.startsWith(u8, line, "```")) {
            if (fence_start) |start| {
                // Closing fence: content is text[start..line_start].
                return text[start..line_start];
            } else {
                // Opening fence: content starts after the line_end newline.
                fence_start = if (line_end < text.len) line_end + 1 else text.len;
            }
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
    return null;
}

/// Copy the first code block of the selected transcript message (falling back
/// to the full transcript block if no code fence is present).
pub fn copySelectedCodeBlock(app: *App) !bool {
    const selected_idx = app.thread.transcript.selected orelse blk: {
        if (app.thread.transcript.messages.items.len == 0) return false;
        var i = app.thread.transcript.messages.items.len;
        while (i > 0) {
            i -= 1;
            const msg = &app.thread.transcript.messages.items[i];
            if (msg.* == .agent) break :blk @as(u32, @intCast(i));
        }
        break :blk @as(u32, @intCast(app.thread.transcript.messages.items.len - 1));
    };

    if (selected_idx >= app.thread.transcript.messages.items.len) return false;
    const msg = &app.thread.transcript.messages.items[selected_idx];
    const mirror = msg.mirror();
    const text = mirror.body;
    if (text.len == 0) return false;

    if (extractFirstCodeBlock(text)) |code| {
        if (code.len > 0) {
            const res = clipboard_mod.copyToClipboard(app.gpa, app.getIo(), code);
            var notice_buf: [256]u8 = undefined;
            const notice_text = try std.fmt.bufPrint(&notice_buf, "Copied code block to clipboard ({d} bytes{s}).", .{ res.copied_bytes, formatTruncSuffix(res) });
            _ = try app.thread.transcript.append(app.gpa, .notice, "clipboard", notice_text);
            return true;
        }
    }

    return copySelectedTranscriptBlock(app);
}

/// Copy current diff file patch or review text to clipboard.
pub fn copyDiffToClipboard(app: *App) !bool {
    if (!app.isDiffViewerMode()) return false;
    const composed = try app.diff.composeMessage(app.gpa);
    if (composed) |msg| {
        defer app.gpa.free(msg);
        const res = clipboard_mod.copyToClipboard(app.gpa, app.getIo(), msg);
        var notice_buf: [128]u8 = undefined;
        const notice_text = std.fmt.bufPrint(&notice_buf, "Copied diff review comments to clipboard{s}.", .{formatTruncSuffix(res)}) catch "Copied diff review comments to clipboard.";
        _ = try app.thread.transcript.append(app.gpa, .notice, "clipboard", notice_text);
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
    try pasteToFocusedInput(&app, "pasted prompt text");

    const val = try app.peekInput();
    defer gpa.free(val);
    try std.testing.expectEqualStrings("pasted prompt text", val);
}

test "pasteToFocusedInput keeps newlines in the multiline prompt" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .normal;
    try pasteToFocusedInput(&app, "line1\nline2\nline3");

    const val = try app.peekInput();
    defer gpa.free(val);
    try std.testing.expectEqualStrings("line1\nline2\nline3", val);
}

test "pasteToFocusedInput folds CRLF to LF in the prompt" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .normal;
    try pasteToFocusedInput(&app, "line1\r\nline2");

    const val = try app.peekInput();
    defer gpa.free(val);
    try std.testing.expectEqualStrings("line1\nline2", val);
}

test "pasteToFocusedInput trims newlines for single-line palette targets" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .model_picker;
    try pasteToFocusedInput(&app, "filter\r\n");

    const val = try app.peekPaletteInput();
    defer gpa.free(val);
    try std.testing.expectEqualStrings("filter", val);
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
    try std.testing.expectEqualStrings("sk-proj-12345", app.input_buffers.provider_key.items);
    // Paste bypasses ProviderPicker.handle, so it must mark the key dirty to
    // reveal the pasted value for verification.
    try std.testing.expect(app.pickers.provider.key_dirty);
}

test "extractFirstCodeBlock extracts fenced content" {
    const markdown =
        \\Here is some code:
        \\```zig
        \\const x = 10;
        \\```
        \\and trailing text.
    ;
    const extracted = extractFirstCodeBlock(markdown);
    try std.testing.expect(extracted != null);
    try std.testing.expectEqualStrings("const x = 10;\n", extracted.?);

    const none = "No code blocks here";
    try std.testing.expect(extractFirstCodeBlock(none) == null);
}
