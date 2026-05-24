const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    display: ?[]u8 = null,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        if (self.display) |display| gpa.free(display);
        self.* = undefined;
    }
};

const stdout_bytes_limit: usize = 512 * 1024;
const stderr_bytes_limit: usize = 512 * 1024;
pub const timeout_seconds_default: u32 = 10;

pub const RunOptions = struct {
    cwd: []const u8,
    command: []const u8,
    env_map: ?*const std.process.Environ.Map = null,
    timeout: std.Io.Timeout = timeoutFromSeconds(timeout_seconds_default),
};

pub fn timeoutFromSeconds(seconds: u32) std.Io.Timeout {
    assert(seconds > 0);
    return .{ .duration = .{ .raw = .fromSeconds(seconds), .clock = .awake } };
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, command: []const u8) !Result {
    return runWithOptions(gpa, io, .{ .cwd = cwd, .command = command });
}

pub fn runWithOptions(gpa: std.mem.Allocator, io: std.Io, options: RunOptions) !Result {
    assert(options.cwd.len > 0);
    assert(options.command.len > 0);
    const child_result = try std.process.run(gpa, io, .{
        .argv = &.{ bashPath(io), "-lc", options.command },
        .cwd = .{ .path = options.cwd },
        .environ_map = options.env_map,
        .stdout_limit = .limited(stdout_bytes_limit),
        .stderr_limit = .limited(stderr_bytes_limit),
        .timeout = options.timeout,
    });
    errdefer gpa.free(child_result.stdout);
    errdefer gpa.free(child_result.stderr);

    return .{
        .stdout = child_result.stdout,
        .stderr = child_result.stderr,
        .code = termCode(child_result.term),
    };
}

pub fn runWithStdin(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    command: []const u8,
    stdin: []const u8,
) !Result {
    assert(cwd.len > 0);
    assert(command.len > 0);
    var child = try std.process.spawn(io, .{
        .argv = &.{ bashPath(io), "-lc", command },
        .cwd = .{ .path = cwd },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    // Write the full stdin buffer up front, then close so the child sees EOF.
    // Intercept handler output is byte-bounded (well under the OS pipe buffer),
    // so a write-then-drain ordering does not deadlock for our usage.
    if (child.stdin) |stdin_file| {
        try stdin_file.writeStreamingAll(io, stdin);
        stdin_file.close(io);
        child.stdin = null;
    }

    return drainChild(gpa, io, &child);
}

fn drainChild(gpa: std.mem.Allocator, io: std.Io, child: *std.process.Child) !Result {
    assert(child.stdout != null);
    assert(child.stderr != null);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > stdout_bytes_limit) return error.StreamTooLong;
        if (stderr_reader.buffered().len > stderr_bytes_limit) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer gpa.free(stderr_slice);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .code = termCode(term),
    };
}

fn termCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |value| value,
        .signal, .stopped, .unknown => 255,
    };
}

// On Windows, `bash` on PATH may resolve to the WSL bash bridge in
// system32, which talks to a Windows service that intermittently exhausts
// socket buffers (WSAENOBUFS / Bash/Service/0x80072747). Prefer git bash when
// available.
const windows_bash_candidates = [_][]const u8{
    "C:\\Program Files\\Git\\bin\\bash.exe",
    "C:\\Program Files\\Git\\usr\\bin\\bash.exe",
};

// TODO: Persist this
var bash_path_value: ?[]const u8 = null;

fn bashPath(io: std.Io) []const u8 {
    if (bash_path_value) |p| return p;
    const resolved = resolveBashPath(io);
    bash_path_value = resolved;
    return resolved;
}

fn resolveBashPath(io: std.Io) []const u8 {
    if (builtin.os.tag != .windows) return "bash";
    for (windows_bash_candidates) |path| {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
        return path;
    }
    return "bash";
}

test "bash captures stdout and exit code" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var result = try run(gpa, std.testing.io, cwd, "printf hello");
    defer result.deinit(gpa);

    try std.testing.expectEqualStrings("hello", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.code);
}

test "bash forwards stdin from buffer" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var result = try runWithStdin(gpa, std.testing.io, cwd, "cat", "piped-bytes");
    defer result.deinit(gpa);

    try std.testing.expectEqualStrings("piped-bytes", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.code);
}
