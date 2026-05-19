const std = @import("std");

const entry_count_max: u32 = 256;
const entry_bytes_max: u32 = 16 * 1024;

const Entry = struct {
    bytes: [entry_bytes_max]u8 = undefined,
    len: u32 = 0,
};

const State = struct {
    mutex: std.atomic.Mutex = .unlocked,
    initialized: bool = false,
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

pub fn log(comptime fmt: []const u8, args: anytype) void {
    ensureInit();
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
    ensureInit();
    lock();
    state.stopping = true;
    const thread = state.thread;
    state.mutex.unlock();
    if (thread) |t| t.join();
}

fn ensureInit() void {
    lock();
    if (state.initialized) {
        state.mutex.unlock();
        return;
    }
    state.initialized = true;
    state.enabled = enabledFromEnv();
    if (state.enabled) {
        setPathFromEnv();
        state.thread = std.Thread.spawn(.{}, writerThread, .{}) catch null;
        if (state.thread == null) state.enabled = false;
    }
    state.mutex.unlock();
}

fn lock() void {
    while (!state.mutex.tryLock()) std.Thread.yield() catch {};
}

fn enabledFromEnv() bool {
    const value_ptr = std.c.getenv("NOVA_DEV_LOG") orelse return false;
    const value = std.mem.span(value_ptr);
    if (std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "yes")) return true;
    return false;
}

fn setPathFromEnv() void {
    const default_path = "/tmp/nova-dev.log";
    const value = if (std.c.getenv("NOVA_LOG_FILE")) |ptr| std.mem.span(ptr) else default_path;
    const len = @min(value.len, state.path.len - 1);
    @memcpy(state.path[0..len], value[0..len]);
    state.path[len] = 0;
    state.path_len = @intCast(len);
}

fn writerThread() void {
    const file = std.c.fopen(@ptrCast(state.path[0..state.path_len :0].ptr), "ab") orelse return;
    defer _ = std.c.fclose(file);
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
            writeLine(file, local.bytes[0..local.len]);
            continue;
        }
        if (dropped > 0) {
            var buffer: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "logger dropped {d} entries", .{dropped}) catch "logger dropped entries";
            writeLine(file, text);
            continue;
        }
        if (should_stop) break;
        std.Thread.yield() catch {};
    }
}

fn writeLine(file: *std.c.FILE, bytes: []const u8) void {
    _ = std.c.fwrite(bytes.ptr, 1, bytes.len, file);
    _ = std.c.fwrite("\n", 1, 1, file);
}

test "logger stays disabled without env" {
    log("test {d}", .{1});
}
