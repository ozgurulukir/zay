//! The host operating system, resolved once at comptime. A single place for the
//! rest of the program to branch on (`is_windows`, `tag`) or label (`label`) the
//! OS, instead of reaching for `builtin.os.tag` — and re-deriving the human name —
//! in scattered spots.

const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;

/// Host OS tag. Prefer this over `builtin.os.tag` so every OS check shares one source.
pub const tag = builtin.os.tag;

/// Whether the host is Windows — Zay's most common OS branch.
pub const is_windows = tag == .windows;

/// Human-facing OS name, e.g. for the system prompt's `${OS}` placeholder.
pub const label: []const u8 = switch (tag) {
    .windows => "Windows",
    .linux => "Linux",
    .macos => "macOS",
    .freebsd => "FreeBSD",
    .netbsd => "NetBSD",
    .openbsd => "OpenBSD",
    else => @tagName(tag),
};

/// Extract the exit code from a child process termination. Non-exit
/// terminations (signal, stop, unknown) map to 255 so callers always see a
/// u8. Shared by `vcs.zig` and `background.zig` — the single source of truth.
pub fn termCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |value| value,
        .signal, .stopped, .unknown => 255,
    };
}

/// Milliseconds `terminateChildBounded` waits after SIGTERM before escalating
/// to SIGKILL: long enough for graceful-shutdown handlers, short enough that a
/// stuck tool call feels interruptible.
pub const child_term_grace_ms: u64 = 5_000;

const child_term_poll_ms: u64 = 10;

/// Bounded teardown of a spawned child's process tree (POSIX): SIGTERM the
/// process group, poll for exit up to `grace_ms`, then SIGKILL the group.
///
/// NEVER reaps — signals and liveness polls only. The caller's existing
/// `child.wait`/`child.kill` stays the single reap point; a second reap panics
/// in std's `childWaitPosix` (ECHILD maps to `errnoBug`). Liveness uses
/// `waitid(NOHANG | NOWAIT)`, which observes an exit without consuming it:
/// `kill(pid, 0)` cannot distinguish a live child from an unreaped zombie and
/// would burn the whole grace on every instant-TERM death. The spawn must pass
/// `.pgid = 0` so the group signal reaches shell grandchildren; `kill(-pid)`
/// falling back to `kill(pid)` covers the window before the child ran
/// `setpgid` (the `background.terminateTreeSync` shape). No-op on Windows,
/// where the call site's `child.kill` is kernel-enforced and fast. Best-effort
/// by contract: no error escapes (this runs in defers during unwind).
pub fn terminateChildBounded(child: *std.process.Child, io: std.Io, grace_ms: u64) void {
    // Branch guard, not a comptime early return: docs/PATTERNS.md requires
    // POSIX syscalls (`std.posix.kill`) inside the untaken branch so the
    // Windows target never analyzes them.
    if (!is_windows) {
        const pid = child.id orelse return; // already reaped (the success path)
        assert(pid > 1); // never signal init or the reaper
        signalTree(pid, .TERM);
        if (awaitExit(io, pid, grace_ms)) return;
        signalTree(pid, .KILL);
    }
}

fn signalTree(pid: std.posix.pid_t, sig: std.posix.SIG) void {
    // ESRCH means "already dead"; swallow it along with any other failure so
    // the escalation loop (and the caller's defer) can never panic.
    std.posix.kill(-pid, sig) catch {
        std.posix.kill(pid, sig) catch {};
    };
}

fn awaitExit(io: std.Io, pid: std.posix.pid_t, grace_ms: u64) bool {
    var waited_ms: u64 = 0;
    while (true) {
        if (processExited(pid)) return true;
        if (waited_ms >= grace_ms) return false;
        const step_ms = @min(child_term_poll_ms, grace_ms - waited_ms);
        // A cancel landing inside the grace has already been consumed by the
        // aborted read upstream; treat it as "poll once more, then escalate"
        // so a defer can never be interrupted mid-teardown.
        io.sleep(.fromMilliseconds(@intCast(step_ms)), .awake) catch {};
        waited_ms += step_ms;
    }
}

/// Exit check that leaves the reap to the caller. On Linux the kernel fills
/// `siginfo` only when the child is in a waitable state, so the pid field is
/// pre-zeroed to make the "no status" answer distinguishable; any waitid error
/// (ECHILD among them) is reported as exited — nothing is left to signal.
fn processExited(pid: std.posix.pid_t) bool {
    if (comptime tag == .linux) {
        var info: std.os.linux.siginfo_t = std.mem.zeroes(std.os.linux.siginfo_t);
        const rc = std.os.linux.waitid(
            .PID,
            pid,
            &info,
            std.os.linux.W.EXITED | std.os.linux.W.NOHANG | std.os.linux.W.NOWAIT,
            null,
        );
        if (std.os.linux.errno(rc) != .SUCCESS) return true;
        // The kernel fills `siginfo` (with the child's pid) only when the
        // child is in a waitable state — a zombie counts as exited here.
        return info.fields.common.first.piduid.pid != 0;
    }
    // Non-Linux POSIX fallback: zombie-blind — correct escalation, but it pays
    // the full grace when SIGTERM lands instantly.
    std.posix.kill(pid, 0) catch return true;
    return false;
}

/// Spawn `bash -c <command>` in its own process group — the shape the shell
/// capture paths use — so the group-signal teardown in
/// `terminateChildBounded` reaches grandchildren. Caller reaps via
/// `child.wait`/`child.kill`.
fn spawnGrouped(command: []const u8) !std.process.Child {
    return std.process.spawn(std.testing.io, .{
        .argv = &.{ "/usr/bin/env", "bash", "-c", command },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = if (is_windows) null else 0,
    });
}

test "terminateChildBounded escalates to SIGKILL when TERM is trapped" {
    if (is_windows) return error.SkipZigTest;
    const io = std.testing.io;

    var child = try spawnGrouped("trap '' TERM; sleep 30");
    defer child.kill(io);
    assert(child.id != null);

    const start_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    // A short grace keeps the test fast while still exercising both the
    // TERM-ignore window and the KILL escalation.
    terminateChildBounded(&child, io, 300);
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - start_ms;
    try std.testing.expect(elapsed_ms < 10_000);

    // The helper never reaps — the caller's kill does (and must succeed).
    _ = try child.wait(io);
    try std.testing.expect(child.id == null);
}

test "terminateChildBounded returns quickly when TERM kills instantly" {
    // Pins the Linux `waitid(NOWAIT)` fast path; the non-Linux POSIX fallback
    // is zombie-blind by design and pays the full grace here.
    if (is_windows or tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;

    var child = try spawnGrouped("sleep 30");
    defer child.kill(io);
    assert(child.id != null);

    const start_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    // Full default grace: if the zombie-blind `kill(pid, 0)` poll ever
    // regresses in, this waits it out and fails the elapsed bound below.
    terminateChildBounded(&child, io, child_term_grace_ms);
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - start_ms;
    try std.testing.expect(elapsed_ms < child_term_grace_ms);

    _ = try child.wait(io);
    try std.testing.expect(child.id == null);
}

const windows = if (is_windows) struct {
    const BOOL = i32;
    const UINT = u32;
    extern "kernel32" fn SetConsoleOutputCP(wCodePageID: UINT) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleCP(wCodePageID: UINT) callconv(.winapi) BOOL;
} else struct {};

/// Ensure Windows console input/output codepage is set to UTF-8 (65001)
/// so Unicode characters render cleanly instead of falling back to legacy OEM codepages.
pub fn initConsoleUtf8() void {
    if (comptime is_windows) {
        _ = windows.SetConsoleOutputCP(65001);
        _ = windows.SetConsoleCP(65001);
    }
}
