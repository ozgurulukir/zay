const std = @import("std");
const os = @import("os.zig");

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
        .argv = &.{ bashPath(io), "-c", options.command },
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
        .argv = &.{ bashPath(io), "-c", command },
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

/// Inline-vs-spill thresholds for `capture`.
pub const CaptureLimits = struct {
    /// Spill to disk (and mark the tail truncated) once either is exceeded.
    bytes_max: usize,
    lines_max: u32,
    /// In-memory rolling-tail capacity. Must exceed `bytes_max`: the spill file
    /// is seeded from the still-untrimmed tail the instant the threshold trips,
    /// so the tail must hold the full output up to that point.
    tail_bytes_max: usize,
};

pub const CaptureOptions = struct {
    cwd: []const u8,
    command: []const u8,
    env_map: ?*const std.process.Environ.Map = null,
    timeout: std.Io.Timeout = timeoutFromSeconds(timeout_seconds_default),
    limits: CaptureLimits,
};

/// Combined stdout+stderr capture of one command, streamed rather than buffered.
///
/// A bounded rolling `tail` is kept in memory; only once output exceeds the
/// inline budget is the full stream spilled to `spill_path` on disk. Small
/// commands — the common case — never touch the filesystem.
pub const Capture = struct {
    /// Trailing slice of the merged output, UTF-8-clean, bounded by
    /// `limits.tail_bytes_max`. The complete output when `spill_path` is null.
    tail: []u8,
    total_bytes: u64,
    total_lines: u32,
    /// Full output on disk, set iff the inline budget was exceeded. Caller owns
    /// the path string; the file itself is left in place for later retrieval.
    spill_path: ?[]u8,
    /// The command was killed for exceeding its timeout.
    timed_out: bool,
    /// Process exit code (255 for signal/unknown, 124 when `timed_out`).
    code: u8,

    pub fn deinit(self: *Capture, gpa: std.mem.Allocator) void {
        gpa.free(self.tail);
        if (self.spill_path) |path| gpa.free(path);
        self.* = undefined;
    }
};

const capture_read_reserve: usize = 64 * 1024;

/// Run `command` under bash, merging stderr into stdout (`exec 2>&1`) so the
/// captured stream preserves chronological interleaving, and stream the result
/// into a bounded tail with lazy spill. See `Capture`.
pub fn capture(gpa: std.mem.Allocator, io: std.Io, options: CaptureOptions) !Capture {
    assert(options.cwd.len > 0);
    assert(options.command.len > 0);
    assert(options.limits.tail_bytes_max > options.limits.bytes_max);

    // `exec 2>&1` merges stderr into stdout so the captured stream preserves
    // chronological interleaving. The shell is non-login (see `bashPath`), so no
    // profile runs and only the command's own output reaches the pipe.
    const merged = try std.fmt.allocPrint(gpa, "exec 2>&1\n{s}", .{options.command});
    defer gpa.free(merged);

    var child = try std.process.spawn(io, .{
        .argv = &.{ bashPath(io), "-c", merged },
        .cwd = .{ .path = options.cwd },
        .environ_map = options.env_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    var sink: Sink = .{ .limits = options.limits };
    errdefer sink.deinit(gpa, io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(1) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{child.stdout.?});
    defer multi_reader.deinit();
    const reader = multi_reader.reader(0);

    var timed_out = false;
    while (multi_reader.fill(capture_read_reserve, options.timeout)) |_| {
        const chunk = reader.buffered();
        if (chunk.len == 0) continue;
        try sink.ingest(gpa, io, chunk);
        reader.tossBuffered();
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => timed_out = true,
        else => |e| return e,
    }

    if (!timed_out) try multi_reader.checkAnyError();
    const code = if (timed_out) 124 else termCode(try child.wait(io));

    return sink.finish(gpa, io, code, timed_out);
}

/// Streaming accumulator behind `capture`: keeps a bounded rolling tail and,
/// once the inline budget is exceeded, spills the full output to a temp file.
const Sink = struct {
    limits: CaptureLimits,
    tail: std.ArrayList(u8) = .empty,
    total_bytes: u64 = 0,
    newline_count: u32 = 0,
    ended_with_newline: bool = false,
    spill: ?Spill = null,

    const Spill = struct {
        file: std.Io.File,
        path: []u8,
    };

    fn ingest(self: *Sink, gpa: std.mem.Allocator, io: std.Io, chunk: []const u8) !void {
        const chunk_ends_newline = chunk[chunk.len - 1] == '\n';
        const new_total = self.total_bytes + chunk.len;
        const new_lines = self.newline_count + countNewlines(chunk);
        // Count an unterminated trailing line as a line, exactly like the
        // `total_lines` reported in `finish`, so the spill trigger and the
        // observation's truncation test agree: a spill file exists iff the tail
        // is shown truncated.
        const new_total_lines = new_lines + @intFromBool(!chunk_ends_newline);

        // Decide to spill before appending/trimming. The tail is still untrimmed
        // here (the byte threshold is below the trim threshold), so it holds the
        // complete output so far and can seed the file; the current chunk is then
        // written whole, so the file captures everything from this point on.
        if (self.spill == null and (new_total > self.limits.bytes_max or new_total_lines > self.limits.lines_max)) {
            self.spill = try openSpill(gpa, io);
            try self.spill.?.file.writeStreamingAll(io, self.tail.items);
        }
        if (self.spill) |spill| try spill.file.writeStreamingAll(io, chunk);

        try self.tail.appendSlice(gpa, chunk);
        self.total_bytes = new_total;
        self.newline_count = new_lines;
        self.ended_with_newline = chunk_ends_newline;
        self.trimTail();
    }

    /// Drop leading bytes once the tail grows past twice its budget, keeping the
    /// last `tail_bytes_max` bytes and not splitting a UTF-8 sequence.
    fn trimTail(self: *Sink) void {
        if (self.tail.items.len <= self.limits.tail_bytes_max * 2) return;
        var start = self.tail.items.len - self.limits.tail_bytes_max;
        while (start < self.tail.items.len and (self.tail.items[start] & 0xC0) == 0x80) start += 1;
        std.mem.copyForwards(u8, self.tail.items[0 .. self.tail.items.len - start], self.tail.items[start..]);
        self.tail.shrinkRetainingCapacity(self.tail.items.len - start);
    }

    fn finish(self: *Sink, gpa: std.mem.Allocator, io: std.Io, code: u8, timed_out: bool) !Capture {
        const tail = try self.tail.toOwnedSlice(gpa);
        if (self.spill) |spill| spill.file.close(io);
        return .{
            .tail = tail,
            .total_bytes = self.total_bytes,
            .total_lines = if (self.total_bytes == 0) 0 else self.newline_count + @intFromBool(!self.ended_with_newline),
            .spill_path = if (self.spill) |spill| spill.path else null,
            .timed_out = timed_out,
            .code = code,
        };
    }

    fn deinit(self: *Sink, gpa: std.mem.Allocator, io: std.Io) void {
        self.tail.deinit(gpa);
        if (self.spill) |spill| {
            spill.file.close(io);
            std.Io.Dir.deleteFile(.cwd(), io, spill.path) catch {};
            gpa.free(spill.path);
        }
        self.* = undefined;
    }
};

fn countNewlines(bytes: []const u8) u32 {
    var count: u32 = 0;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn openSpill(gpa: std.mem.Allocator, io: std.Io) !Sink.Spill {
    const path = try tempSpillPath(gpa, io);
    errdefer gpa.free(path);
    const file = try std.Io.Dir.createFile(.cwd(), io, path, .{});
    return .{ .file = file, .path = path };
}

fn tempSpillPath(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var random: [16]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const name = try std.fmt.allocPrint(gpa, "nova-bash-{s}.log", .{hex[0..]});
    defer gpa.free(name);
    const dir = try tempDir(gpa);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, name });
}

/// Resolve a temp directory that both the shell and Nova agree on.
///
/// On Windows the bash tool runs under git bash, which maps `/tmp` to `%TEMP%`,
/// but Nova reads the spilled output back through the Windows file API — there
/// a literal `/tmp/...` resolves against the current drive root (`C:\tmp\...`),
/// not where the shell actually wrote. Using the real `%TEMP%` keeps the write
/// and the read pointing at the same file. POSIX shares one `/tmp` already.
fn tempDir(gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    if (!os.is_windows) return gpa.dupe(u8, "/tmp");
    for ([_][]const u8{ "TEMP", "TMP" }) |key| {
        const value = std.process.Environ.getAlloc(.{ .block = .global }, gpa, key) catch continue;
        if (value.len == 0) {
            gpa.free(value);
            continue;
        }
        return value;
    }
    return gpa.dupe(u8, ".");
}

// Commands run under a non-login shell (see `bashPath`), but a non-login shell
// skips the profile — so on a GUI-launched POSIX host it would miss PATH/vars
// set only in login dotfiles. Rather than pay the profile cost (and leak its
// startup chatter) on every command, resolve the login environment once: run a
// login shell, dump its exported vars, and reuse them as the base env for every
// command. This mirrors codex's shell-snapshot approach; the captured vars are
// applied via the command's env map, so the per-command shell stays non-login.
//
// The dump is fenced by a NUL-delimited marker so the login profile's own stdout
// chatter (which precedes the marker) is discarded. `compgen -e` lists exported
// names; `${!k}` reads each value; `PWD`/`OLDPWD` are skipped so a stale cwd is
// not carried. Values are emitted NUL-terminated so newlines/`=` survive intact.
const login_env_marker = "\x00__NOVA_LOGIN_ENV__\x00";
const login_env_dump =
    "printf '\\0__NOVA_LOGIN_ENV__\\0'; " ++
    "for k in $(compgen -e); do case \"$k\" in PWD|OLDPWD) continue ;; esac; printf '%s=%s\\0' \"$k\" \"${!k}\"; done";
const login_env_bytes_limit: usize = 1024 * 1024;
const login_env_timeout_seconds: u32 = 10;

var login_env_cache: ?[]const u8 = null;
var login_env_attempted: bool = false;

/// POSIX only: the login shell's exported environment as a NUL-separated
/// `KEY=VALUE` block, captured once and cached for the process lifetime. Returns
/// null on Windows, or if the capture fails (callers then fall back to the
/// inherited process env). See the comment above for the rationale.
pub fn loginEnvBlock(io: std.Io) ?[]const u8 {
    if (os.is_windows) return null;
    if (!login_env_attempted) {
        login_env_attempted = true;
        login_env_cache = captureLoginEnv(io) catch null;
    }
    return login_env_cache;
}

fn captureLoginEnv(io: std.Io) ![]const u8 {
    // Cached for the process lifetime, so it is owned independently of any
    // caller's allocator.
    const gpa = std.heap.page_allocator;
    var result = try std.process.run(gpa, io, .{
        .argv = &.{ bashPath(io), "-lc", login_env_dump },
        .stdout_limit = .limited(login_env_bytes_limit),
        .stderr_limit = .limited(64 * 1024),
        .timeout = timeoutFromSeconds(login_env_timeout_seconds),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (termCode(result.term) != 0) return error.LoginEnvFailed;
    const marker_at = std.mem.indexOf(u8, result.stdout, login_env_marker) orelse return error.LoginEnvFailed;
    return gpa.dupe(u8, result.stdout[marker_at + login_env_marker.len ..]);
}

// On Windows, `bash` on PATH may resolve to the WSL bash bridge in
// system32, which talks to a Windows service that intermittently exhausts
// socket buffers (WSAENOBUFS / Bash/Service/0x80072747). Prefer git bash when
// available.
const windows_bash_candidates = [_][]const u8{
    "C:\\Program Files\\Git\\bin\\bash.exe",
    "C:\\Program Files\\Git\\usr\\bin\\bash.exe",
};

var bash_path_value: ?[]const u8 = null;

fn bashPath(io: std.Io) []const u8 {
    if (bash_path_value) |p| return p;
    const resolved = resolveBashPath(io);
    bash_path_value = resolved;
    return resolved;
}

fn resolveBashPath(io: std.Io) []const u8 {
    if (!os.is_windows) return "bash";
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
