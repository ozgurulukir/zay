const std = @import("std");
const builtin = @import("builtin");
const bash = @import("../bash.zig");
const common = @import("common.zig");

pub const tool: common.Tool = .{
    .name = "bash",
    .description = @embedFile("../prompts/tools/bash.md"),
    .schema = .{
        .properties = &.{ .{
            .name = "command",
            .kind = .string,
            .description = "Shell command to run.",
            .required = true,
        }, .{
            .name = "reason",
            .kind = .string,
            .description = "Human-readable single-sentence explanation of what this command does.",
            .required = true,
        }, .{
            .name = "cwd",
            .kind = .string,
            .description = "Working directory. Relative to the project unless absolute.",
            .required = false,
        }, .{
            .name = "env",
            .kind = .object,
            .description = "Extra environment variables, merged over the inherited env. String values only.",
            .required = false,
        }, .{ .name = "timeout", .kind = .integer, .description = "Timeout in seconds (default 10).", .required = false } },
    },
    .run = runTool,
    .display = display,
};

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    var args = parseArgs(gpa, arguments) catch |err| return parseError(gpa, err);
    defer args.deinit();
    var command_cwd: ?[]u8 = null;
    defer if (command_cwd) |path| gpa.free(path);
    const resolved_cwd = if (args.cwd) |path| value: {
        if (std.fs.path.isAbsolute(path)) break :value path;
        command_cwd = std.fs.path.join(gpa, &.{ cwd, path }) catch return error.OutOfMemory;
        break :value command_cwd.?;
    } else cwd;

    const output_path = tempOutputPath(gpa, io) catch return error.OutOfMemory;
    var keep_output_file = false;
    defer {
        if (!keep_output_file) std.Io.Dir.deleteFile(.cwd(), io, output_path) catch {};
        gpa.free(output_path);
    }

    var env_map = try currentEnvMap(gpa);
    defer env_map.deinit();
    if (args.env) |env| try applyEnv(&env_map, env);
    try env_map.put("NOVA_BASH_OUTPUT", output_path);

    const wrapped_command = wrapCommandForOutputFile(gpa, args.command) catch return error.OutOfMemory;
    defer gpa.free(wrapped_command);

    var run_result = bash.runWithOptions(gpa, io, .{
        .cwd = resolved_cwd,
        .command = wrapped_command,
        .env_map = &env_map,
        .timeout = bash.timeoutFromSeconds(args.timeout_seconds),
    }) catch |err| switch (err) {
        error.Timeout => return finishBashOutput(gpa, io, output_path, 124, .{ .timeout_seconds = args.timeout_seconds }, &keep_output_file),
        else => return mapBashError(err),
    };
    defer run_result.deinit(gpa);

    return finishBashOutput(gpa, io, output_path, run_result.code, .{}, &keep_output_file);
}

const Args = struct {
    command: []const u8,
    reason: []const u8,
    cwd: ?[]const u8 = null,
    env: ?std.json.Value = null,
    parsed: std.json.Parsed(JsonArgs),
    timeout_seconds: u32 = bash.timeout_seconds_default,

    fn deinit(self: *Args) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

const JsonArgs = struct {
    command: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?std.json.Value = null,
    timeout: ?u32 = null,
};

const ParseError = error{
    InvalidJson,
    MissingCommand,
    MissingReason,
    BadCommand,
    BadCwd,
    BadEnv,
    BadEnvKey,
    BadEnvValue,
    BadTimeout,
};

fn parseArgs(gpa: std.mem.Allocator, arguments: []const u8) ParseError!Args {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch return error.InvalidJson;
    errdefer parsed.deinit();

    const command = parsed.value.command orelse return error.MissingCommand;
    if (command.len == 0) return error.MissingCommand;

    const reason = parsed.value.reason orelse return error.MissingReason;
    if (reason.len == 0) return error.MissingReason;

    if (parsed.value.cwd) |cwd| {
        if (cwd.len == 0) return error.BadCwd;
    }

    if (parsed.value.env) |env| {
        if (env != .object) return error.BadEnv;
        try validateEnv(env);
    }

    const timeout_seconds = parsed.value.timeout orelse bash.timeout_seconds_default;
    if (timeout_seconds == 0) return error.BadTimeout;

    return .{
        .command = command,
        .reason = reason,
        .cwd = parsed.value.cwd,
        .env = parsed.value.env,
        .parsed = parsed,
        .timeout_seconds = timeout_seconds,
    };
}

fn validateEnv(env: std.json.Value) ParseError!void {
    var iterator = env.object.iterator();
    while (iterator.next()) |entry| {
        if (!std.process.Environ.Map.validateKeyForPut(entry.key_ptr.*)) return error.BadEnvKey;
        if (entry.value_ptr.* != .string) return error.BadEnvValue;
    }
}

fn parseError(gpa: std.mem.Allocator, err: ParseError) common.Error!common.Output {
    return switch (err) {
        error.InvalidJson => common.fail(gpa, "bash: invalid JSON arguments\n", 2),
        error.MissingCommand => common.fail(gpa, "bash: missing command\n", 2),
        error.MissingReason => common.fail(gpa, "bash: missing reason\n", 2),
        error.BadCommand => common.fail(gpa, "bash: command must be a string\n", 2),
        error.BadCwd => common.fail(gpa, "bash: cwd must be a non-empty string\n", 2),
        error.BadEnv => common.fail(gpa, "bash: env must be an object\n", 2),
        error.BadEnvKey => common.fail(gpa, "bash: env keys must be valid environment variable names\n", 2),
        error.BadEnvValue => common.fail(gpa, "bash: env values must be strings\n", 2),
        error.BadTimeout => common.fail(gpa, "bash: timeout must be a positive integer number of seconds\n", 2),
    };
}

fn currentEnvMap(gpa: std.mem.Allocator) (std.mem.Allocator.Error || std.Io.UnexpectedError)!std.process.Environ.Map {
    if (builtin.os.tag == .windows) {
        return std.process.Environ.createMap(.{ .block = .global }, gpa);
    }

    var map = std.process.Environ.Map.init(gpa);
    errdefer map.deinit();
    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) {
        const line = std.mem.span(entry);
        const separator = std.mem.findScalar(u8, line, '=') orelse continue;
        if (separator == 0) continue;
        try map.put(line[0..separator], line[separator + 1 ..]);
    }
    return map;
}

fn applyEnv(map: *std.process.Environ.Map, env: std.json.Value) std.mem.Allocator.Error!void {
    var iterator = env.object.iterator();
    while (iterator.next()) |entry| {
        try map.put(entry.key_ptr.*, entry.value_ptr.string);
    }
}

const observation_lines_max: u32 = 2000;
const observation_bytes_max: usize = 50 * 1024;
const rolling_bytes_max: usize = observation_bytes_max * 2;

const FinishStatus = struct {
    timeout_seconds: ?u32 = null,
};

const TailSnapshot = struct {
    text: []u8,
    total_lines: u32,
    shown_lines: u32,
    total_bytes: u64,
    shown_bytes: u32,
    truncated: bool,
    last_line_partial: bool,
};

fn finishBashOutput(
    gpa: std.mem.Allocator,
    io: std.Io,
    output_path: []const u8,
    code: u8,
    status: FinishStatus,
    keep_output_file: *bool,
) common.Error!common.Output {
    var snapshot = readTailSnapshot(gpa, io, output_path) catch |err| return mapBashError(err);
    defer snapshotDeinit(gpa, &snapshot);

    const observation_text = formatBashText(gpa, snapshot.text, code, status) catch return error.OutOfMemory;
    var observation_text_moved = false;
    errdefer if (!observation_text_moved) gpa.free(observation_text);

    var observation: common.Observation = if (snapshot.truncated) truncated: {
        const path = try gpa.dupe(u8, output_path);
        errdefer gpa.free(path);
        keep_output_file.* = true;
        break :truncated .{ .truncated_tail = .{
            .text = observation_text,
            .total_lines = snapshot.total_lines,
            .shown_lines = snapshot.shown_lines,
            .total_bytes = snapshot.total_bytes,
            .shown_bytes = snapshot.shown_bytes,
            .full_output_path = path,
        } };
    } else .{ .complete = observation_text };
    observation_text_moved = true;
    errdefer observation.deinit(gpa);
    const display_text = observation.render(gpa) catch return error.OutOfMemory;
    errdefer gpa.free(display_text);

    const stderr = try gpa.alloc(u8, 0);
    errdefer gpa.free(stderr);
    return .{
        .stdout = display_text,
        .stderr = stderr,
        .code = code,
        .display = null,
        .observation = observation,
    };
}

fn snapshotDeinit(gpa: std.mem.Allocator, snapshot: *TailSnapshot) void {
    gpa.free(snapshot.text);
    snapshot.* = undefined;
}

fn wrapCommandForOutputFile(gpa: std.mem.Allocator, command: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "exec >\"$NOVA_BASH_OUTPUT\" 2>&1\n{s}", .{command});
}

fn tempOutputPath(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
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
/// but Nova reads the captured output back through the Windows file API — there
/// a literal `/tmp/...` resolves against the current drive root (`C:\tmp\...`),
/// not where the shell actually wrote. Using the real `%TEMP%` keeps the write
/// and the read pointing at the same file. POSIX shares one `/tmp` already.
fn tempDir(gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    if (builtin.os.tag != .windows) return gpa.dupe(u8, "/tmp");
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

fn formatBashText(gpa: std.mem.Allocator, text: []const u8, code: u8, status: FinishStatus) std.mem.Allocator.Error![]u8 {
    if (status.timeout_seconds) |seconds| {
        if (text.len == 0) return std.fmt.allocPrint(gpa, "Command timed out after {d} seconds", .{seconds});
        return std.fmt.allocPrint(gpa, "{s}\n\nCommand timed out after {d} seconds", .{ text, seconds });
    }
    if (code != 0) {
        if (text.len == 0) return std.fmt.allocPrint(gpa, "Command exited with code {d}", .{code});
        return std.fmt.allocPrint(gpa, "{s}\n\nCommand exited with code {d}", .{ text, code });
    }
    if (text.len == 0) return gpa.dupe(u8, "(no output)");
    return gpa.dupe(u8, text);
}

fn readTailSnapshot(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !TailSnapshot {
    var file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    var tail: std.ArrayList(u8) = .empty;
    errdefer tail.deinit(gpa);
    var total_bytes: u64 = 0;
    var newline_count: u32 = 0;
    var ended_with_newline = false;
    var buffer: [8192]u8 = undefined;
    while (true) {
        const read_count = reader.interface.readSliceShort(&buffer) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
        };
        if (read_count == 0) break;
        const chunk = buffer[0..read_count];
        total_bytes += read_count;
        for (chunk) |byte| {
            if (byte == '\n') newline_count += 1;
        }
        ended_with_newline = chunk[chunk.len - 1] == '\n';
        try tail.appendSlice(gpa, chunk);
        trimRollingTail(&tail);
    }
    const total_lines: u32 = if (total_bytes == 0) 0 else newline_count + @intFromBool(!ended_with_newline);
    const text = try truncateTailBuffer(gpa, tail.items, total_lines, total_bytes);
    tail.deinit(gpa);
    return text;
}

fn trimRollingTail(tail: *std.ArrayList(u8)) void {
    if (tail.items.len <= rolling_bytes_max * 2) return;
    var start = tail.items.len - rolling_bytes_max;
    while (start < tail.items.len and (tail.items[start] & 0xC0) == 0x80) start += 1;
    std.mem.copyForwards(u8, tail.items[0 .. tail.items.len - start], tail.items[start..]);
    tail.shrinkRetainingCapacity(tail.items.len - start);
}

fn truncateTailBuffer(gpa: std.mem.Allocator, tail: []const u8, total_lines: u32, total_bytes: u64) !TailSnapshot {
    const truncated = total_lines > observation_lines_max or total_bytes > observation_bytes_max;
    if (!truncated) {
        return .{
            .text = try gpa.dupe(u8, tail),
            .total_lines = total_lines,
            .shown_lines = total_lines,
            .total_bytes = total_bytes,
            .shown_bytes = @intCast(@min(total_bytes, std.math.maxInt(u32))),
            .truncated = false,
            .last_line_partial = false,
        };
    }

    var start = tail.len;
    var lines_seen: u32 = 0;
    var bytes_seen: usize = 0;
    while (start > 0) {
        const next = previousUtf8Start(tail, start);
        const byte_count = start - next;
        if (bytes_seen + byte_count > observation_bytes_max) break;
        bytes_seen += byte_count;
        start = next;
        if (tail[start] == '\n') {
            if (lines_seen >= observation_lines_max) {
                start += 1;
                break;
            }
            lines_seen += 1;
        }
    }
    while (start < tail.len and (tail[start] & 0xC0) == 0x80) start += 1;
    const out = try gpa.dupe(u8, tail[start..]);
    return .{
        .text = out,
        .total_lines = total_lines,
        .shown_lines = countLines(out),
        .total_bytes = total_bytes,
        .shown_bytes = @intCast(@min(out.len, std.math.maxInt(u32))),
        .truncated = true,
        .last_line_partial = start > 0 and start < tail.len and tail[start - 1] != '\n',
    };
}

fn previousUtf8Start(text: []const u8, end: usize) usize {
    var index = end - 1;
    while (index > 0 and (text[index] & 0xC0) == 0x80) index -= 1;
    return index;
}

fn countLines(text: []const u8) u32 {
    if (text.len == 0) return 0;
    var count: u32 = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    if (text[text.len - 1] == '\n') count -= 1;
    return count;
}

fn mapBashError(err: anyerror) common.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.Unexpected,
    };
}

/// The bash display summary is the model-provided reason; the expanded title
/// is the executable command, so users can inspect exactly what ran.
fn display(gpa: std.mem.Allocator, args: []const u8) std.mem.Allocator.Error!common.ToolDisplay {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, args, .{ .ignore_unknown_fields = true }) catch {
        return .{ .label = try gpa.dupe(u8, "bash") };
    };
    defer parsed.deinit();
    const reason = parsed.value.reason orelse return .{ .label = try gpa.dupe(u8, "bash") };
    if (reason.len == 0) return .{ .label = try gpa.dupe(u8, "bash") };
    const command = parsed.value.command orelse return .{ .label = try gpa.dupe(u8, "bash") };
    if (command.len == 0) return .{ .label = try gpa.dupe(u8, "bash") };

    const label = try gpa.dupe(u8, reason);
    errdefer gpa.free(label);
    const expanded_label = try gpa.dupe(u8, command);
    return .{ .label = label, .expanded_label = expanded_label };
}

test "bash display uses reason with command as expanded label" {
    const gpa = std.testing.allocator;
    var label = try display(gpa, "{\"command\":\"pwd\",\"reason\":\"Inspect the current directory\"}");
    defer label.deinit(gpa);
    try std.testing.expectEqualStrings("Inspect the current directory", label.label);
    try std.testing.expectEqualStrings("pwd", label.expanded_label.?);
}

test "bash display falls back on partial JSON" {
    const gpa = std.testing.allocator;
    var label = try display(gpa, "{\"command");
    defer label.deinit(gpa);
    try std.testing.expectEqualStrings("bash", label.label);
    try std.testing.expect(label.expanded_label == null);
}

test "bash tool applies env object" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runTool(gpa, std.testing.io, cwd, "{\"command\":\"printf \\\"$BASH_TOOL_TEST\\\"\",\"reason\":\"read\",\"env\":{\"BASH_TOOL_TEST\":\"hello-env\"}}");
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expectEqualStrings("hello-env", output.stdout);
}

test "bash tool applies relative cwd" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, ".zig-cache/bash-tool-test");
    const expected = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache/bash-tool-test" });
    defer gpa.free(expected);

    var output = try runTool(gpa, std.testing.io, cwd, "{\"command\":\"printf \\\"$PWD\\\"\",\"reason\":\"read\",\"cwd\":\".zig-cache/bash-tool-test\"}");
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expectEqualStrings(expected, output.stdout);
}

test "bash tool parses timeout" {
    var args = try parseArgs(std.testing.allocator, "{\"command\":\"printf ok\",\"reason\":\"read\",\"timeout\":42}");
    defer args.deinit();

    try std.testing.expectEqual(@as(u32, 42), args.timeout_seconds);
}

test "bash tool accepts freeform reason" {
    var args = try parseArgs(std.testing.allocator, "{\"command\":\"printf ok\",\"reason\":\"Print ok\"}");
    defer args.deinit();

    try std.testing.expectEqualStrings("Print ok", args.reason);
}

fn testObservationText(gpa: std.mem.Allocator, output: common.Output) ![]u8 {
    const observation = output.observation orelse return error.MissingObservation;
    return observation.render(gpa);
}

test "bash tool reports exit code in observation" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runTool(gpa, std.testing.io, cwd, "{\"command\":\"printf nope; exit 7\",\"reason\":\"read\"}");
    defer output.deinit(gpa);
    const observation = try testObservationText(gpa, output);
    defer gpa.free(observation);

    try std.testing.expectEqual(@as(u8, 7), output.code);
    try std.testing.expect(std.mem.indexOf(u8, observation, "nope") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "Command exited with code 7") != null);
}

test "bash tool truncates observation tail and keeps full output path" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runTool(gpa, std.testing.io, cwd, "{\"command\":\"python3 - <<'PY'\\nfor i in range(2105): print(f'line-{i}')\\nPY\",\"reason\":\"read\"}");
    defer {
        if (output.observation) |observation| switch (observation) {
            .complete => {},
            .truncated_tail => |tail| std.Io.Dir.deleteFile(.cwd(), std.testing.io, tail.full_output_path) catch {},
        };
        output.deinit(gpa);
    }
    const observation = try testObservationText(gpa, output);
    defer gpa.free(observation);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, observation, "line-2104") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "line-0\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "Full output:") != null);
}
