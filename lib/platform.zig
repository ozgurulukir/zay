//! Portable platform abstractions. One place for OS-adaptive behavior
//! (clock, environment, raw fd writes) so the rest of the codebase stays
//! clean of `builtin.os.tag` switches.

const std = @import("std");
const builtin = @import("builtin");

/// Write raw bytes to a file descriptor (1 = stdout, 2 = stderr).
/// Works before the Io is set up (pre-init escape hatch).
/// On Windows, uses @ptrFromInt because fd_t is HANDLE (*anyopaque)
/// but the C runtime's _write receives it as an int at the ABI level.
pub fn writeToFd(fd: u2, buf: []const u8) void {
    if (builtin.os.tag == .windows) {
        // SAFETY: @ptrFromInt(2) produces a dangling pointer by design —
        // it must only be used for the pre-init stderr/stdout escape hatch
        // where fd_t is HANDLE but the C runtime's _write expects an int.
        _ = std.c.write(@ptrFromInt(fd), buf.ptr, buf.len);
    } else {
        _ = std.c.write(fd, buf.ptr, buf.len);
    }
}

/// Realtime clock in nanoseconds since Unix epoch.
/// Returns 0 if the clock is unavailable.
pub fn realtimeNowNs() i128 {
    if (builtin.os.tag == .windows) {
        var tv: std.c.timeval = undefined;
        if (std.c.gettimeofday(&tv, null) != 0) return 0;
        return @as(i128, tv.sec) * std.time.ns_per_s +
            @as(i128, tv.usec) * std.time.ns_per_us;
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// Monotonic clock in nanoseconds (never goes backward).
/// Returns 0 if the clock is unavailable.
pub fn monotonicNowNs() i128 {
    if (builtin.os.tag == .windows) {
        // RtlQueryPerformanceCounter from ntdll gives high-resolution
        // monotonic ticks. Call RtlQueryPerformanceFrequency each time
        // (~20ns) instead of caching — the Lua instruction hook can run
        // on multiple threads, and a static cache is a data race.
        var freq: i64 = undefined;
        if (std.os.windows.ntdll.RtlQueryPerformanceFrequency(&freq) == .FALSE) return 0;
        var counter: i64 = undefined;
        if (std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter) == .FALSE) return 0;
        return @divTrunc(@as(i128, counter) * std.time.ns_per_s, @as(i128, freq));
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// Get the process environment as an Environ.Map.
/// On POSIX: reads from std.c.environ (null-safe via std.mem.span).
/// On Windows: uses the global block.
pub fn getEnvMap(gpa: std.mem.Allocator) !std.process.Environ.Map {
    if (builtin.os.tag == .windows) {
        return std.process.Environ.createMap(.{ .block = .global }, gpa);
    }
    const env_slice = std.mem.span(std.c.environ);
    return std.process.Environ.createMap(.{ .block = .{ .slice = env_slice } }, gpa);
}

// --- Tests ----------------------------------------------------------------

test "realtimeNowNs returns positive non-zero value" {
    const ns = realtimeNowNs();
    try std.testing.expect(ns > 0);
}

test "monotonicNowNs is non-decreasing across consecutive calls" {
    const a = monotonicNowNs();
    const b = monotonicNowNs();
    try std.testing.expect(b >= a);
}

test "getEnvMap contains PATH" {
    const allocator = std.testing.allocator;
    var map = try getEnvMap(allocator);
    defer map.deinit();
    try std.testing.expect(map.get("PATH") != null);
}

test "writeToFd does not crash writing to stderr" {
    const msg = "platform_test_ok\n";
    writeToFd(2, msg);
}
