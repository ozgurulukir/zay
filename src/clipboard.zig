//! System clipboard integration for Nova.
//!
//! Provides cross-platform copy and paste functionality:
//!   - Copying uses OSC 52 terminal escape sequences as the primary mechanism
//!     (works seamlessly over SSH, tmux, kitty, alacritty, wezterm, iTerm2,
//!     foot, Windows Terminal) with native OS utility fallback (`wl-copy`,
//!     `xclip`, `xsel`, `pbcopy`, `clip.exe`).
//!   - Pasting queries OS system clipboard tools (`wl-paste`, `xclip`, `xsel`,
//!     `pbpaste`, `powershell`) and processes terminal bracketed paste events.

const std = @import("std");
const builtin = @import("builtin");
const bash = @import("tools/bash_exec.zig");

const assert = std.debug.assert;

// Maximum bytes allowed for clipboard copy/paste (10 MB sanity limit).
pub const max_clipboard_bytes: usize = 10 * 1024 * 1024;

/// Copy `text` to the system clipboard.
///
/// Sends an OSC 52 sequence to the terminal and attempts to invoke native
/// OS clipboard tools (`wl-copy`, `xclip`, `pbcopy`, etc.) so external
/// desktop applications also receive the text.
pub fn copyToClipboard(gpa: std.mem.Allocator, io: std.Io, text: []const u8) void {
    if (text.len == 0) return;
    const send_len = @min(text.len, max_clipboard_bytes);
    const slice = text[0..send_len];

    // 1. Terminal OSC 52 escape sequence.
    sendOsc52(gpa, slice);

    // 2. Native OS clipboard command.
    copyToOsClipboard(gpa, io, slice);
}

/// Read text from the system clipboard using OS clipboard tools.
/// Caller owns the returned memory slice. Returns `null` if clipboard reading
/// is unavailable or empty.
pub fn readFromClipboard(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    return readFromOsClipboard(gpa, io);
}

// ---------------------------------------------------------------------------
// OSC 52 Terminal Escape Sequence
// ---------------------------------------------------------------------------

/// Send OSC 52 sequence to stdout (`\x1b]52;c;<base64>\x07`).
fn sendOsc52(gpa: std.mem.Allocator, text: []const u8) void {
    const Encoder = std.base64.standard.Encoder;
    const b64_len = Encoder.calcSize(text.len);
    const total_len = "\x1b]52;c;".len + b64_len + "\x07".len;

    const buf = gpa.alloc(u8, total_len) catch return;
    defer gpa.free(buf);

    @memcpy(buf[0.."\x1b]52;c;".len], "\x1b]52;c;");
    _ = Encoder.encode(buf["\x1b]52;c;".len .. "\x1b]52;c;".len + b64_len], text);
    buf[buf.len - 1] = 0x07; // BEL terminator

    _ = std.c.write(1, buf.ptr, buf.len);
}

// ---------------------------------------------------------------------------
// Native OS Clipboard Execution via bash subsystem
// ---------------------------------------------------------------------------

fn isWayland() bool {
    if (builtin.os.tag == .windows or builtin.os.tag == .macos) return false;
    return std.c.getenv("WAYLAND_DISPLAY") != null;
}

fn copyToOsClipboard(gpa: std.mem.Allocator, io: std.Io, text: []const u8) void {
    switch (builtin.os.tag) {
        .macos => execWithStdin(gpa, io, "pbcopy", text),
        .windows => execWithStdin(gpa, io, "powershell.exe -NoProfile -Command Set-Clipboard -Value $input", text),
        else => {
            // Linux / BSD / POSIX — check Wayland (wl-copy) then X11 (xclip / xsel).
            if (isWayland()) {
                if (execWithStdin(gpa, io, "wl-copy", text)) return;
            }
            if (execWithStdin(gpa, io, "xclip -selection clipboard", text)) return;
            _ = execWithStdin(gpa, io, "xsel --clipboard --input", text);
        },
    }
}

fn readFromOsClipboard(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    return switch (builtin.os.tag) {
        .macos => runCaptureStdout(gpa, io, "pbpaste"),
        .windows => runCaptureStdout(gpa, io, "powershell.exe -NoProfile -Command Get-Clipboard"),
        else => blk: {
            if (isWayland()) {
                if (runCaptureStdout(gpa, io, "wl-paste -n")) |res| break :blk res;
            }
            if (runCaptureStdout(gpa, io, "xclip -selection clipboard -o")) |res| break :blk res;
            break :blk runCaptureStdout(gpa, io, "xsel --clipboard --output");
        },
    };
}

fn execWithStdin(gpa: std.mem.Allocator, io: std.Io, cmd: []const u8, stdin_data: []const u8) bool {
    var result = bash.runWithStdin(gpa, io, ".", cmd, stdin_data) catch return false;
    defer result.deinit(gpa);
    return result.code == 0;
}

fn runCaptureStdout(gpa: std.mem.Allocator, io: std.Io, cmd: []const u8) ?[]u8 {
    var result = bash.run(gpa, io, ".", cmd) catch return null;
    defer result.deinit(gpa);

    if (result.code != 0 or result.stdout.len == 0) return null;
    return gpa.dupe(u8, result.stdout) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "base64 encoding for OSC 52 helper" {
    const gpa = std.testing.allocator;
    const sample = "Hello Nova Clipboard!";
    const Encoder = std.base64.standard.Encoder;
    const b64_len = Encoder.calcSize(sample.len);
    const buf = try gpa.alloc(u8, b64_len);
    defer gpa.free(buf);
    _ = Encoder.encode(buf, sample);

    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(buf);
    const decoded_buf = try gpa.alloc(u8, decoded_len);
    defer gpa.free(decoded_buf);
    try std.base64.standard.Decoder.decode(decoded_buf, buf);

    try std.testing.expectEqualStrings(sample, decoded_buf);
}
