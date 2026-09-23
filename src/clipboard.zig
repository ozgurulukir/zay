//! System clipboard integration for Zay.
//!
//! Provides cross-platform copy and paste functionality:
//!   - Copying uses OSC 52 terminal escape sequences as the primary mechanism
//!     (works seamlessly over SSH, tmux, kitty, alacritty, wezterm, iTerm2,
//!     foot, Windows Terminal) with native OS utility fallback (`wl-copy`,
//!     `xclip`, `xsel`, `pbcopy`, or the `pwsh` backend's `Set-Clipboard`
//!     cmdlet on Windows).
//!   - Pasting queries OS system clipboard tools (`wl-paste`, `xclip`, `xsel`,
//!     `pbpaste`, or the `pwsh` backend's `Get-Clipboard` cmdlet on Windows)
//!     and processes terminal bracketed paste events.

const std = @import("std");
const builtin = @import("builtin");
const bash = @import("tools/bash_exec.zig");
const pwsh_exec = @import("tools/pwsh_exec.zig");
const platform = @import("platform");

const assert = std.debug.assert;
const log = std.log.scoped(.clipboard);

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

    platform.writeToFd(1, buf);
}

// ---------------------------------------------------------------------------
// Native OS Clipboard Execution via the platform shell executor
// (pwsh cmdlets on Windows, bash elsewhere)
// ---------------------------------------------------------------------------

/// The exec layer that runs OS-clipboard commands on this platform.
/// Windows uses the native PowerShell backend (`pwsh_exec`) — clipboard
/// commands are PowerShell cmdlets, and `bash` may resolve to the WSL
/// launcher stub on hosts where Git lives outside the standard install dir.
/// POSIX/macOS keep the bash executor (pbpaste/wl-*/xclip/xsel are POSIX
/// shell commands).
const clipboard_exec = if (builtin.os.tag == .windows) pwsh_exec else bash;

/// Windows has exactly one clipboard command per direction, so a non-zero
/// exit is always a real failure worth a toast. POSIX/macOS chain
/// intentional fallbacks (wl-* → xclip → xsel): a missing first-choice tool
/// exits 127 — an expected miss, kept at `log.debug` to avoid toast spam.
const warn_on_failure = builtin.os.tag == .windows;

/// Exit-code failure where it is a real failure (Windows: single command, no
/// fallback) vs an expected POSIX fallback miss.
fn logClipboardFailure(kind: []const u8, code: u8, cmd: []const u8) void {
    if (warn_on_failure) {
        log.warn("clipboard: {s} command failed (exit {d}): {s}", .{ kind, code, cmd });
    } else {
        log.debug("clipboard: {s} fallback miss (exit {d}): {s}", .{ kind, code, cmd });
    }
}

/// Windows clipboard commands, run INSIDE the pwsh exec process
/// (`pwsh_exec`): no `powershell.exe -Command` wrapper (it would re-spawn a
/// child pwsh) and no bash (may resolve to the WSL launcher stub). POSIX and
/// macOS command strings stay inline in the callers — their fallback chains
/// (wl → xclip → xsel) are load-bearing and must not be collapsed.
fn windowsReadCommand() []const u8 {
    return "Get-Clipboard";
}

fn windowsWriteCommand() []const u8 {
    // Pipeline binding, NOT `-Value $input`: under `-File`, `$input` is an
    // IEnumerator, and `Set-Clipboard -Value $input` binds it through
    // `[string[]]$input`, coercing a multi-line copy to ONE space-joined string.
    // The pipeline enumerates it element-by-element, preserving newlines.
    return "$input | Set-Clipboard";
}

fn isWayland() bool {
    if (builtin.os.tag == .windows or builtin.os.tag == .macos) return false;
    return std.c.getenv("WAYLAND_DISPLAY") != null;
}

fn copyToOsClipboard(gpa: std.mem.Allocator, io: std.Io, text: []const u8) void {
    switch (builtin.os.tag) {
        .macos => _ = execWithStdin(gpa, io, "pbcopy", text),
        .windows => _ = execWithStdin(gpa, io, windowsWriteCommand(), text),
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
        .windows => runCaptureStdout(gpa, io, windowsReadCommand()),
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
    var result = clipboard_exec.runWithStdin(gpa, io, ".", cmd, stdin_data) catch |err| {
        log.warn("clipboard: executor failed to spawn {s} ({s})", .{ cmd, @errorName(err) });
        return false;
    };
    defer result.deinit(gpa);
    if (result.code != 0) {
        logClipboardFailure("write", result.code, cmd);
        return false;
    }
    return true;
}

fn runCaptureStdout(gpa: std.mem.Allocator, io: std.Io, cmd: []const u8) ?[]u8 {
    var result = clipboard_exec.run(gpa, io, ".", cmd) catch |err| {
        log.warn("clipboard: executor failed to spawn {s} ({s})", .{ cmd, @errorName(err) });
        return null;
    };
    defer result.deinit(gpa);
    if (result.code != 0) {
        logClipboardFailure("read", result.code, cmd);
        return null;
    }
    if (result.stdout.len == 0) return null; // benign: empty clipboard — no warn
    return gpa.dupe(u8, result.stdout) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "base64 encoding for OSC 52 helper" {
    const gpa = std.testing.allocator;
    const sample = "Hello Zay Clipboard!";
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

test "windows clipboard commands are bare PowerShell cmdlets" {
    // Platform-independent: the helpers are constants, testable everywhere.
    try std.testing.expectEqualStrings("Get-Clipboard", windowsReadCommand());
    try std.testing.expectEqualStrings("$input | Set-Clipboard", windowsWriteCommand());
    // No shell wrapper, no WSL-stub-exposed bash.
    try std.testing.expect(std.mem.indexOf(u8, windowsReadCommand(), "bash") == null);
    try std.testing.expect(std.mem.indexOf(u8, windowsWriteCommand(), "powershell.exe") == null);
}

test "windows clipboard executor is the pwsh exec layer" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(clipboard_exec == pwsh_exec);
}

test "posix/macOS clipboard executor stays bash" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(clipboard_exec == bash);
}

test "clipboard executors keep an identical exec contract" {
    // Coercion-based pin. Do NOT use `@TypeOf(a) != @TypeOf(b)` here: both
    // run/runWithStdin return INFERRED error sets (`!Result`), and Zig 0.16
    // compares two distinct functions' inferred-error-set types as unequal
    // regardless of structural identity — the check would be true on every
    // platform and hard-break `zig build test`. Coercion to an explicit
    // `anyerror!Result` fn pointer is the correct pin: it fails to compile
    // if either signature (param order/types or error set) diverges.
    // Parameter types verified against pwsh_exec.zig:66/76 and
    // bash_exec.zig:41/56 (gpa, io, cwd, command[, stdin]).
    const ExecFn = *const fn (std.mem.Allocator, std.Io, []const u8, []const u8) anyerror!bash.Result;
    const ExecStdinFn = *const fn (std.mem.Allocator, std.Io, []const u8, []const u8, []const u8) anyerror!bash.Result;
    comptime {
        // Legitimately true today (both alias capture_sink.Result) — keep as
        // a guard against a future per-module Result split.
        if (bash.Result != pwsh_exec.Result) @compileError("clipboard exec Result types diverged — clipboard needs an adapter");
        _ = @as(ExecFn, &pwsh_exec.run);
        _ = @as(ExecFn, &bash.run);
        _ = @as(ExecStdinFn, &pwsh_exec.runWithStdin);
        _ = @as(ExecStdinFn, &bash.runWithStdin);
    }
}
