//! External $EDITOR / $VISUAL prompt editing (issue #510).
//!
//! Invoked via `Ctrl+X Ctrl+E` in normal mode. Suspends the vaxis terminal,
//! writes the current prompt to a hex-named temporary file, spawns `$VISUAL`
//! or `$EDITOR` as a child process, restores the terminal, and replaces the
//! prompt with the display-normalized result (keeping the original prompt on
//! empty output or non-zero exit).

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");
const tools_common = @import("../tools/common.zig");
const os = @import("../os.zig");

const App = tui.App;

const max_editor_bytes: usize = 1024 * 1024;

pub const EditResult = union(enum) {
    ok: []u8,
    unchanged,
    non_zero_exit: u8,
};

pub fn resolveEditor(env_map: ?*const std.process.Environ.Map) ?[]const u8 {
    if (env_map) |m| {
        if (m.get("VISUAL")) |v| {
            if (v.len > 0) return v;
        }
        if (m.get("EDITOR")) |e| {
            if (e.len > 0) return e;
        }
    }
    return null;
}

fn fillHex(io: std.Io, buf: []u8) void {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const alphabet = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        if (i * 2 + 1 >= buf.len) break;
        buf[i * 2] = alphabet[b >> 4];
        buf[i * 2 + 1] = alphabet[b & 0x0f];
    }
}

pub fn tempDir(env_map: ?*const std.process.Environ.Map) []const u8 {
    if (env_map) |m| {
        if (m.get("TMPDIR")) |d| if (d.len > 0) return d;
        if (m.get("TEMP")) |d| if (d.len > 0) return d;
        if (m.get("TMP")) |d| if (d.len > 0) return d;
    }
    return if (os.is_windows) "." else "/tmp";
}

/// Write `initial_text` to a hex-named temp file, run `editor_cmd`, and
/// read back the normalized result.
pub fn editTextInEditor(
    gpa: std.mem.Allocator,
    io: std.Io,
    editor_cmd: []const u8,
    initial_text: []const u8,
    env_map: ?*const std.process.Environ.Map,
) !EditResult {
    var hex: [16]u8 = undefined;
    fillHex(io, &hex);
    const dir = tempDir(env_map);
    const sep = std.fs.path.sep_str;
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}{s}zay-edit-{s}.md", .{ dir, sep, hex });
    defer gpa.free(tmp_path);

    {
        var f = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{ .truncate = true });
        defer f.close(io);
        if (initial_text.len > 0) {
            try f.writeStreamingAll(io, initial_text);
        }
    }
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    const exit_code = try spawnEditor(gpa, io, editor_cmd, tmp_path, null, env_map);
    if (exit_code != 0) {
        return .{ .non_zero_exit = exit_code };
    }

    const raw = std.Io.Dir.cwd().readFileAlloc(io, tmp_path, gpa, .limited(max_editor_bytes)) catch |err| switch (err) {
        error.FileTooBig => return .{ .non_zero_exit = 1 },
        else => return err,
    };
    defer gpa.free(raw);

    const normalized = try tools_common.normalizeDisplayText(gpa, raw);
    const trimmed_end = std.mem.trimEnd(u8, normalized, "\n");
    if (trimmed_end.len == 0 or std.mem.eql(u8, trimmed_end, initial_text)) {
        gpa.free(normalized);
        return .unchanged;
    }
    if (trimmed_end.len != normalized.len) {
        const shrunk = try gpa.dupe(u8, trimmed_end);
        gpa.free(normalized);
        return .{ .ok = shrunk };
    }
    return .{ .ok = normalized };
}

/// Split `editor_cmd` into argv tokens, respecting single quotes, double
/// quotes, and backslash escapes, without invoking a shell.
pub fn parseEditorCommand(gpa: std.mem.Allocator, editor_cmd: []const u8) !std.ArrayList([]u8) {
    var args: std.ArrayList([]u8) = .empty;
    errdefer {
        for (args.items) |a| gpa.free(a);
        args.deinit(gpa);
    }

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(gpa);
    var in_token = false;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < editor_cmd.len) : (i += 1) {
        const c = editor_cmd[i];
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
            } else if (quote == '"' and c == '\\' and i + 1 < editor_cmd.len) {
                i += 1;
                try current.append(gpa, editor_cmd[i]);
            } else {
                try current.append(gpa, c);
            }
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            if (in_token) {
                try args.append(gpa, try current.toOwnedSlice(gpa));
                in_token = false;
            }
            continue;
        }
        in_token = true;
        if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '\\' and i + 1 < editor_cmd.len) {
            i += 1;
            try current.append(gpa, editor_cmd[i]);
        } else {
            try current.append(gpa, c);
        }
    }
    if (quote != 0) return error.InvalidEditorCommand;
    if (in_token) {
        try args.append(gpa, try current.toOwnedSlice(gpa));
    }
    if (args.items.len == 0) return error.InvalidEditorCommand;
    return args;
}

pub fn spawnEditor(
    gpa: std.mem.Allocator,
    io: std.Io,
    editor_cmd: []const u8,
    file_path: []const u8,
    line: ?u32,
    env_map: ?*const std.process.Environ.Map,
) !u8 {
    var line_arg_buf: [24]u8 = undefined;
    const line_arg: ?[]const u8 = if (line) |l| std.fmt.bufPrint(&line_arg_buf, "+{d}", .{l}) catch null else null;

    var parsed = try parseEditorCommand(gpa, editor_cmd);
    defer {
        for (parsed.items) |a| gpa.free(a);
        parsed.deinit(gpa);
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, parsed.items);
    if (line_arg) |la| try argv.append(gpa, la);
    try argv.append(gpa, file_path);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = env_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

fn suspendTerminal(app: *App) void {
    const fw = app.fw_app orelse return;
    fw.vx.setMouseMode(fw.tty.writer(), false) catch {};
    fw.vx.setBracketedPaste(fw.tty.writer(), false) catch {};
    fw.vx.exitAltScreen(fw.tty.writer()) catch {};
    fw.vx.resetState(fw.tty.writer()) catch {};
    fw.tty.writer().flush() catch {};
    if (!builtin.is_test and builtin.os.tag != .windows) {
        std.posix.tcsetattr(fw.tty.fd.handle, .FLUSH, fw.tty.termios) catch {};
    }
}

fn resumeTerminal(app: *App) void {
    const fw = app.fw_app orelse return;
    if (!builtin.is_test and builtin.os.tag != .windows) {
        _ = vaxis.Tty.makeRaw(fw.tty.fd.handle) catch {};
    }
    fw.vx.enterAltScreen(fw.tty.writer()) catch {};
    fw.vx.setBracketedPaste(fw.tty.writer(), true) catch {};
    fw.vx.setMouseMode(fw.tty.writer(), true) catch {};
    fw.vx.queueRefresh();
    fw.tty.writer().flush() catch {};
}

pub fn editPromptInExternalEditor(app: *App) !void {
    const editor_cmd = resolveEditor(app.environ_map) orelse {
        _ = try app.thread.transcript.append(
            app.gpa,
            .notice,
            "Editor",
            "Set $EDITOR or $VISUAL to edit the prompt in an external editor.",
        );
        return;
    };

    const initial = try app.inputs.input.buf.dupe();
    defer app.gpa.free(initial);

    suspendTerminal(app);
    defer resumeTerminal(app);

    const res = editTextInEditor(app.gpa, app.getIo(), editor_cmd, initial, app.environ_map) catch |err| {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Failed to launch external editor: {s}", .{@errorName(err)}) catch "Failed to launch external editor";
        _ = try app.thread.transcript.append(app.gpa, .notice, "Editor", msg);
        return;
    };

    switch (res) {
        .ok => |updated| {
            defer app.gpa.free(updated);
            app.inputs.paste_stash.clear(app.gpa);
            app.clearInput();
            try app.inputs.input.insertSliceAtCursor(updated);
        },
        .unchanged => {},
        .non_zero_exit => |code| {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "External editor exited with status {d}; prompt unchanged.", .{code}) catch "External editor failed; prompt unchanged.";
            _ = try app.thread.transcript.append(app.gpa, .notice, "Editor", msg);
        },
    }
}

test "resolveEditor prefers VISUAL over EDITOR and returns null when unset" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expect(resolveEditor(&env) == null);
    try env.put("EDITOR", "nano");
    try std.testing.expectEqualStrings("nano", resolveEditor(&env).?);
    try env.put("VISUAL", "nvim");
    try std.testing.expectEqualStrings("nvim", resolveEditor(&env).?);
}

test "editTextInEditor round-trips edited text and preserves on non-zero exit" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    // Successful edit via printf -> appends text.
    const res = try editTextInEditor(gpa, std.testing.io, "sh -c 'printf \"edited\\tline\" > \"$1\"' _", "initial", &env);
    switch (res) {
        .ok => |text| {
            defer gpa.free(text);
            try std.testing.expectEqualStrings("edited  line", text);
        },
        else => return error.TestUnexpectedResult,
    }

    // Non-zero exit -> preserves prompt.
    const fail_res = try editTextInEditor(gpa, std.testing.io, "false", "initial", &env);
    switch (fail_res) {
        .non_zero_exit => |code| try std.testing.expect(code != 0),
        else => return error.TestUnexpectedResult,
    }
}

test "parseEditorCommand splits quoted paths and flags without shell expansion" {
    const gpa = std.testing.allocator;
    var parsed = try parseEditorCommand(gpa, "\"/path/with spaces/code\" --wait -n");
    defer {
        for (parsed.items) |a| gpa.free(a);
        parsed.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 3), parsed.items.len);
    try std.testing.expectEqualStrings("/path/with spaces/code", parsed.items[0]);
    try std.testing.expectEqualStrings("--wait", parsed.items[1]);
    try std.testing.expectEqualStrings("-n", parsed.items[2]);

    try std.testing.expectError(error.InvalidEditorCommand, parseEditorCommand(gpa, "\"unterminated"));
    try std.testing.expectError(error.InvalidEditorCommand, parseEditorCommand(gpa, "   "));
}
