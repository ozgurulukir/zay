const std = @import("std");

const entry_count_max: u32 = 256;
const entry_bytes_max: u32 = 16 * 1024;

const Entry = struct {
    bytes: [entry_bytes_max]u8 = undefined,
    len: u32 = 0,
};

const State = struct {
    mutex: std.atomic.Mutex = .unlocked,
    io: std.Io = undefined,
    enabled: bool = false,
    stopping: bool = false,
    dropped: u64 = 0,
    head: u32 = 0,
    count: u32 = 0,
    entries: [entry_count_max]Entry = undefined,
    thread: ?std.Thread = null,
    path: [1024]u8 = undefined,
    path_len: u32 = 0,
};

var state: State = .{};

pub const Options = struct {
    io: std.Io,
    log_path: []const u8,
};

pub fn init(options: Options) error{PathTooLong}!void {
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

pub fn log(comptime fmt: []const u8, args: anytype) void {
    lock();
    defer state.mutex.unlock();
    if (!state.enabled) return;
    if (state.count >= entry_count_max) {
        state.dropped += 1;
        return;
    }
    const index = (state.head + state.count) % entry_count_max;
    var entry = &state.entries[index];
    const message = std.fmt.bufPrint(&entry.bytes, fmt, args) catch |err| blk: {
        if (err == error.NoSpaceLeft) {
            const fallback = std.fmt.bufPrint(&entry.bytes, "logger entry too large: {s}", .{fmt}) catch "logger entry too large";
            break :blk fallback;
        }
        const fallback = std.fmt.bufPrint(&entry.bytes, "logger format failed: {s}", .{@errorName(err)}) catch "logger format failed";
        break :blk fallback;
    };
    entry.len = @intCast(message.len);
    state.count += 1;
}

pub fn deinit() void {
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
        if (state.count > 0) {
            local = state.entries[state.head];
            state.head = (state.head + 1) % entry_count_max;
            state.count -= 1;
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
