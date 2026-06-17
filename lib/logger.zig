const std = @import("std");
const builtin = @import("builtin");
const bounded_queue = @import("bounded_queue");

const assert = std.debug.assert;

pub const enabled = builtin.mode == .Debug;
const entry_count_max: u32 = 256;
const entry_bytes_max: u32 = 16 * 1024;

const Entry = struct {
    bytes: [entry_bytes_max]u8 = undefined,
    len: u32 = 0,
};

const EntryQueue = bounded_queue.BoundedQueue(Entry);

const State = struct {
    mutex: std.atomic.Mutex = .unlocked,
    io: std.Io = undefined,
    enabled: bool = false,
    stopping: bool = false,
    dropped: u64 = 0,
    entries: [entry_count_max]Entry = undefined,
    entry_queue: EntryQueue = .{},
    thread: ?std.Thread = null,
    path: [1024]u8 = undefined,
    path_len: u32 = 0,
};

var state: State = .{};

pub const Options = struct {
    io: std.Io,
    log_path: []const u8,
};

pub const init = if (enabled) initEnabled else initDisabled;
pub const log = if (enabled) logEnabled else logDisabled;
pub const deinit = if (enabled) deinitEnabled else deinitDisabled;

fn initEnabled(options: Options) error{PathTooLong}!void {
    lock();
    defer state.mutex.unlock();
    if (state.enabled) return;
    if (options.log_path.len >= state.path.len) return error.PathTooLong;
    @memcpy(state.path[0..options.log_path.len], options.log_path);
    state.path_len = @intCast(options.log_path.len);
    state.io = options.io;
    state.enabled = true;
    state.thread = std.Thread.spawn(.{}, writerThread, .{}) catch null;
    if (state.thread == null) state.enabled = false;
}

fn initDisabled(_: Options) error{PathTooLong}!void {}

fn logEnabled(comptime fmt: []const u8, args: anytype) void {
    lock();
    defer state.mutex.unlock();
    if (!state.enabled) return;
    if (state.entry_queue.full(&state.entries)) {
        state.dropped += 1;
        return;
    }
    var entry: Entry = .{};
    const message = std.fmt.bufPrint(&entry.bytes, fmt, args) catch |err| blk: {
        if (err == error.NoSpaceLeft) {
            const fallback = std.fmt.bufPrint(&entry.bytes, "logger entry too large: {s}", .{fmt}) catch "logger entry too large";
            break :blk fallback;
        }
        const fallback = std.fmt.bufPrint(&entry.bytes, "logger format failed: {s}", .{@errorName(err)}) catch "logger format failed";
        break :blk fallback;
    };
    entry.len = @intCast(message.len);
    const pushed = state.entry_queue.push(&state.entries, entry);
    assert(pushed);
}

fn logDisabled(comptime _: []const u8, _: anytype) void {}

fn deinitEnabled() void {
    lock();
    if (!state.enabled) {
        state.mutex.unlock();
        return;
    }
    state.stopping = true;
    const thread = state.thread;
    state.mutex.unlock();
    if (thread) |t| t.join();
}

fn deinitDisabled() void {}

fn lock() void {
    while (!state.mutex.tryLock()) std.Thread.yield() catch {};
}

fn writerThread() void {
    const path = state.path[0..state.path_len];

    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.createDirPath(.cwd(), state.io, dir) catch return;
    }

    var file = std.Io.Dir.createFile(.cwd(), state.io, path, .{ .truncate = false }) catch return;
    defer file.close(state.io);

    const existing_size: u64 = if (file.stat(state.io)) |s| s.size else |_| 0;

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(state.io, &buffer);
    writer.seekTo(existing_size) catch {};

    var local: Entry = .{};
    while (true) {
        var should_stop = false;
        var has_entry = false;
        var dropped: u64 = 0;
        lock();
        if (state.entry_queue.pop(&state.entries)) |entry| {
            local = entry;
            has_entry = true;
        } else {
            should_stop = state.stopping;
            dropped = state.dropped;
            state.dropped = 0;
        }
        state.mutex.unlock();

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
        std.Thread.yield() catch {};
    }
}

fn writeLine(writer: *std.Io.File.Writer, bytes: []const u8) void {
    writer.interface.writeAll(bytes) catch {};
    writer.interface.writeAll("\n") catch {};
    writer.interface.flush() catch {};
}

test "logger stays disabled without init" {
    log("test {d}", .{1});
}
