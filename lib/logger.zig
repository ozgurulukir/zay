//! Nova logger. Decouples the *sink* from the build mode.
//!
//! Two sinks, gated independently:
//!   - File sink: persistent trail, the background writer thread. **Debug only**
//!     (`enabled_file`) — keeps release lean (no thread spawn, no fs touch).
//!   - Stderr sink: always compiled in (all build modes), runtime-gated by
//!     `stderr_level`. This is the half that restores operational logging to
//!     the shipped ReleaseFast binary (B1).
//!
//! Debug: both sinks run (true tee — file gets the full stream, stderr gets
//! `stderr_level` and above). ReleaseFast: only the stderr sink runs.

const std = @import("std");
const builtin = @import("builtin");
const bounded_queue = @import("bounded_queue");

const assert = std.debug.assert;

/// File-writer thread exists in Debug only.
pub const enabled_file = builtin.mode == .Debug;

const entry_count_max: u32 = 256;
const entry_bytes_max: u32 = 16 * 1024;

/// Default log-file rotation cap (10 MB), overridable via `NOVA_LOG_MAX_BYTES`.
const default_max_bytes: u64 = 10 * 1024 * 1024;

const Entry = struct {
    bytes: [entry_bytes_max]u8 = undefined,
    len: u32 = 0,
};

const EntryQueue = bounded_queue.BoundedQueue(Entry);

const State = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    io: std.Io = undefined,
    enabled_file: bool = false,
    stderr_ready: bool = false,
    stderr_level: std.log.Level = .warn,
    max_bytes: u64 = default_max_bytes,
    stopping: bool = false,
    dropped: u64 = 0,
    entries: [entry_count_max]Entry = undefined,
    entry_queue: EntryQueue = .{},
    thread: ?std.Thread = null,
    path: [1024]u8 = undefined,
    path_len: u32 = 0,
    // Lazily initialized on first stderr write; its buffer lives here so the
    // writer is stable across calls.
    stderr_buf: [4096]u8 = undefined,
    stderr_writer: ?std.Io.File.Writer = null,
};

var state: State = .{};

pub const Options = struct {
    io: std.Io,
    log_path: []const u8,
    /// Min level emitted to the stderr sink. Defaults to `warn`.
    stderr_level: std.log.Level = .warn,
    /// File rotation cap in bytes. Defaults to `default_max_bytes`.
    max_bytes: u64 = default_max_bytes,
};

pub fn init(options: Options) error{PathTooLong}!void {
    if (state.mutex.lock(state.io)) |_| {
        defer state.mutex.unlock(state.io);

        // Captured for every build — the stderr sink needs an `io` to write.
        state.io = options.io;
        state.stderr_ready = true;
        state.stderr_level = options.stderr_level;
        state.max_bytes = options.max_bytes;

        if (enabled_file) {
            if (state.enabled_file) return;
            if (options.log_path.len >= state.path.len) return error.PathTooLong;
            @memcpy(state.path[0..options.log_path.len], options.log_path);
            state.path_len = @intCast(options.log_path.len);
            state.enabled_file = true;
            state.thread = std.Thread.spawn(.{}, writerThread, .{}) catch null;
            if (state.thread == null) state.enabled_file = false;
        }
    } else |_| {
        // Lock failed (canceled) — init is best-effort during teardown.
    }
}

/// Single entry point for the `std.log` path (via `novaLog` in `main.zig`).
/// `level`/`scope_name` gate the stderr sink and travel into the file entry.
pub fn dispatch(level: std.log.Level, scope_name: []const u8, comptime fmt: []const u8, args: anytype) void {
    _ = scope_name; // scope already baked into `fmt` by novaLog's prefix

    // G-C1: pre-init / init-failed escape hatch. No io, no lock — direct raw
    // stderr so early failures (config load before init) are still visible.
    // Uses the libc `write` (the binary links libc anyway; mirrors
    // `src/clipboard.zig`'s `std.c.write`), fd 2 = stderr.
    if (!state.stderr_ready) {
        var buf: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&buf, fmt, args)) |line| {
            _ = std.c.write(2, line.ptr, line.len);
            _ = std.c.write(2, "\n", 1);
        } else |_| {}
        return;
    }

    var msg_buf: [entry_bytes_max]u8 = undefined;
    const formatted = std.fmt.bufPrint(&msg_buf, fmt, args) catch |err| blk: {
        if (err == error.NoSpaceLeft) {
            break :blk std.fmt.bufPrint(&msg_buf, "logger entry too large: {s}", .{fmt}) catch "logger entry too large";
        }
        break :blk std.fmt.bufPrint(&msg_buf, "logger format failed: {s}", .{@errorName(err)}) catch "logger format failed";
    };

    if (state.mutex.lock(state.io)) |_| {
        defer state.mutex.unlock(state.io);

        // Tee: stderr sink (all builds, runtime level-gated). `std.log.Level`
        // orders by severity — err=0 < warn=1 < info=2 < debug=3 — so
        // "stderr_level and more severe" is `<=`, not `>=`.
        if (@intFromEnum(level) <= @intFromEnum(state.stderr_level)) {
            writeStderrLine(formatted);
        }

        // Tee: file sink (Debug only).
        if (enabled_file and state.enabled_file) {
            if (state.entry_queue.full(&state.entries)) {
                state.dropped += 1;
            } else {
                var entry: Entry = .{};
                @memcpy(entry.bytes[0..formatted.len], formatted);
                entry.len = @intCast(formatted.len);
                const pushed = state.entry_queue.push(&state.entries, entry);
                assert(pushed);
                state.condition.signal(state.io);
            }
        }
    } else |_| {
        // Lock failed (canceled) — drop the entry silently.
    }
}

pub fn deinit() void {
    var residual_dropped: u64 = 0;
    var have_dropped = false;
    {
        if (state.mutex.lock(state.io)) |_| {
            if (!state.stderr_ready and !state.enabled_file) {
                state.mutex.unlock(state.io);
                return;
            }

            if (state.enabled_file) {
                state.stopping = true;
                state.condition.signal(state.io);
            }
            // P3: capture any residual dropped count so it is reported even
            // when the process is tearing down under load. Reported below,
            // outside the lock, after the writer thread has flushed.
            if (state.dropped > 0) {
                residual_dropped = state.dropped;
                have_dropped = true;
                state.dropped = 0;
            }
            state.mutex.unlock(state.io);
        } else |_| {}
    }

    if (state.enabled_file) {
        if (state.thread) |t| t.join();
    }

    // P3: best-effort flush of the residual dropped count to both sinks. The
    // writer thread has already joined, so the file arm can't accept a new
    // entry; report only on stderr (the always-on sink).
    if (have_dropped) {
        var drop_buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&drop_buf, "logger dropped {d} entries (deinit)", .{residual_dropped}) catch "logger dropped entries (deinit)";
        if (state.stderr_ready) {
            if (state.mutex.lock(state.io)) |_| {
                defer state.mutex.unlock(state.io);
                writeStderrLine(text);
            } else |_| {}
        }
    }
}

/// Write `bytes` as one line to the stderr sink. Caller holds `state.mutex`.
fn writeStderrLine(bytes: []const u8) void {
    if (state.stderr_writer == null) {
        state.stderr_writer = std.Io.File.stderr().writer(state.io, &state.stderr_buf);
    }
    if (state.stderr_writer) |*w| {
        var ts_buf: [40]u8 = undefined;
        const ts = formatTimestamp(&ts_buf);
        w.interface.writeAll(ts) catch {};
        w.interface.writeAll(" ") catch {};
        w.interface.writeAll(bytes) catch {};
        w.interface.writeAll("\n") catch {};
        w.interface.flush() catch {};
    }
}

fn writerThread() void {
    const path = state.path[0..state.path_len];

    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.createDirPath(.cwd(), state.io, dir) catch return;
    }

    // P2: size-based rotation. Stat before opening; if the existing file
    // exceeds `max_bytes`, rename it to `<path>.1` — a SIBLING of the live
    // log (a bare "nova.log.1" would resolve against the process cwd and
    // either fail EXDEV or dump the rotated file into the project dir) —
    // and start fresh. Done once at startup; rotation is a launch-time
    // decision.
    const file_stat = std.Io.Dir.cwd().statFile(state.io, path, .{}) catch null;
    if (file_stat) |s| {
        if (s.size > state.max_bytes) {
            var rot_buf: [state.path.len + 2]u8 = undefined;
            if (std.fmt.bufPrint(&rot_buf, "{s}.1", .{path})) |rotated| {
                std.Io.Dir.rename(.cwd(), path, .cwd(), rotated, state.io) catch {};
            } else |_| {}
        }
    }

    var file = std.Io.Dir.createFile(.cwd(), state.io, path, .{ .truncate = false }) catch return;
    defer file.close(state.io);

    // After rotation (above), a rotated-away file is gone so stat reports 0;
    // an un-rotated existing file reports its real size so we append past it.
    const start_size: u64 = if (file.stat(state.io)) |s| s.size else |_| 0;

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(state.io, &buffer);
    writer.seekTo(start_size) catch {};

    var local: Entry = .{};
    while (true) {
        var should_stop = false;
        var has_entry = false;
        var dropped: u64 = 0;
        if (state.mutex.lock(state.io)) |_| {
            while (state.entry_queue.empty() and !state.stopping) {
                state.condition.waitUncancelable(state.io, &state.mutex);
            }
            if (state.entry_queue.pop(&state.entries)) |entry| {
                local = entry;
                has_entry = true;
            } else {
                should_stop = state.stopping;
                dropped = state.dropped;
                state.dropped = 0;
            }
            state.mutex.unlock(state.io);
        } else |_| return;

        if (has_entry) {
            writeLine(&writer, local.bytes[0..local.len]);
            continue;
        }
        if (dropped > 0) {
            var dropped_buf: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&dropped_buf, "logger dropped {d} entries", .{dropped}) catch "logger dropped entries";
            writeLine(&writer, text);
            continue;
        }
        if (should_stop) {
            writer.interface.flush() catch {};
            break;
        }
    }
}

fn writeLine(writer: *std.Io.File.Writer, bytes: []const u8) void {
    var ts_buf: [40]u8 = undefined;
    const ts = formatTimestamp(&ts_buf);
    writer.interface.writeAll(ts) catch {};
    writer.interface.writeAll(" ") catch {};
    writer.interface.writeAll(bytes) catch {};
    writer.interface.writeAll("\n") catch {};
    writer.interface.flush() catch {};
}

/// P1: ISO-8601 UTC timestamp prefix. The logger has no `Io` handle on the
/// stderr pre-init path and the writer thread's hot path, so read the OS
/// clock directly via `clock_gettime(REALTIME)` (mirrors the Lua instruction
/// hook). Fills `out` and returns the written slice (never dangles — the
/// slice is bounded by the caller-owned `out`).
fn formatTimestamp(out: []u8) []const u8 {
    var ts: std.c.timespec = undefined;
    const ok = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) == 0;
    if (!ok) return std.fmt.bufPrint(out, "ts_err", .{}) catch "ts_err";

    const total_ms: u64 = @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
    const secs = total_ms / std.time.ms_per_s;
    const ms = total_ms % std.time.ms_per_s;

    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = epoch_seconds.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    return std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        hour,
        minute,
        second,
        ms,
    }) catch "ts_err";
}

test "dispatch before init does not crash and drops no queue entries" {
    // Pre-init path: stderr_ready is false here (no init ran in the test), so
    // dispatch must take the raw-stderr fallback and must not touch the queue.
    state.dropped = 0;
    dispatch(.warn, "test", "pre-init test {d}", .{1});
    try std.testing.expectEqual(@as(u64, 0), state.dropped);
    try std.testing.expect(state.entry_queue.empty());
}

test "stderr sink is level-gated and deinit flushes the dropped count" {
    const io = std.testing.io;
    const capture_path = "nova_logger_stderr_capture.log";

    // Point the swappable stderr writer at a temp file so the sink is
    // observable without touching the real fd 2.
    var capture = try std.Io.Dir.createFile(.cwd(), io, capture_path, .{});
    var capture_buf: [4096]u8 = undefined;

    const prev_io = state.io;
    const prev_ready = state.stderr_ready;
    const prev_level = state.stderr_level;
    const prev_writer = state.stderr_writer;
    const prev_dropped = state.dropped;
    defer {
        // Restore global state — other tests in this file assume pre-init.
        state.io = prev_io;
        state.stderr_ready = prev_ready;
        state.stderr_level = prev_level;
        state.stderr_writer = prev_writer;
        state.dropped = prev_dropped;
    }

    state.io = io;
    state.stderr_ready = true;
    state.stderr_level = .warn;
    state.stderr_writer = capture.writer(io, &capture_buf);
    state.dropped = 0;

    dispatch(.info, "test", "below threshold", .{}); // gated off (info < warn in severity)
    dispatch(.warn, "test", "visible {d}", .{7});
    dispatch(.err, "test", "severe passes", .{}); // err is more severe than warn
    state.dropped = 3;
    deinit(); // P3: residual dropped count must reach the stderr sink

    capture.close(io);

    const content = try std.Io.Dir.readFileAlloc(.cwd(), io, capture_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "visible 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "severe passes") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "dropped 3 entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "below threshold") == null);

    std.Io.Dir.deleteFile(.cwd(), io, capture_path) catch {};
}

test "formatTimestamp is pure and fills the caller buffer" {
    var buf: [40]u8 = undefined;
    const ts = formatTimestamp(&buf);
    // Must end in Z (ISO-8601 UTC) and be non-empty.
    try std.testing.expect(ts.len > 0);
    try std.testing.expectEqual(@as(u8, 'Z'), ts[ts.len - 1]);
    // The slice must point into the caller's buffer (no dangling stack frame).
    const ts_addr = @intFromPtr(ts.ptr);
    const buf_start = @intFromPtr(&buf);
    const buf_end = buf_start + buf.len;
    try std.testing.expect(ts_addr >= buf_start and ts_addr <= buf_end);
}
