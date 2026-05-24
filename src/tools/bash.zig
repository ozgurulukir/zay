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
            .description = "Required. Shell command to execute.",
            .required = true,
        }, .{
            .name = "cwd",
            .kind = .string,
            .description = "Optional. Working directory for the command, relative to the current project unless absolute.",
            .required = false,
        }, .{
            .name = "env",
            .kind = .object,
            .description = "Optional. Environment variables to add or override. Values must be strings.",
            .required = false,
        }, .{ .name = "timeout", .kind = .integer, .description = "Optional. Timeout for this command in seconds. Defaults to 10.", .required = false } },
    },
    .run = runTool,
    .displayLabel = displayLabel,
};

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, arguments, .{}) catch {
        return common.fail(gpa, "bash: invalid JSON arguments\n", 2);
    };
    defer parsed.deinit();

    const args = parseArgs(parsed.value) catch |err| return parseError(gpa, err);
    var command_cwd: ?[]u8 = null;
    defer if (command_cwd) |path| gpa.free(path);
    const resolved_cwd = if (args.cwd) |path| value: {
        if (std.fs.path.isAbsolute(path)) break :value path;
        command_cwd = std.fs.path.join(gpa, &.{ cwd, path }) catch return error.OutOfMemory;
        break :value command_cwd.?;
    } else cwd;

    var env_map = if (args.env) |_| try currentEnvMap(gpa) else null;
    defer if (env_map) |*map| map.deinit();
    if (args.env) |env| try applyEnv(&env_map.?, env);

    const result = bash.runWithOptions(gpa, io, .{
        .cwd = resolved_cwd,
        .command = args.command,
        .env_map = if (env_map) |*map| map else null,
        .timeout = bash.timeoutFromSeconds(args.timeout_seconds),
    }) catch |err| switch (err) {
        error.Timeout => return common.failFmt(gpa, 124, "bash: command timed out after {d} seconds\n", .{args.timeout_seconds}),
        else => return mapBashError(err),
    };
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .code = result.code,
        .display = result.display,
    };
}

const Args = struct {
    command: []const u8,
    cwd: ?[]const u8 = null,
    env: ?std.json.Value = null,
    timeout_seconds: u32 = bash.timeout_seconds_default,
};

const ParseError = error{
    InvalidJson,
    MissingCommand,
    BadCommand,
    BadCwd,
    BadEnv,
    BadEnvKey,
    BadEnvValue,
    BadTimeout,
};

fn parseArgs(value: std.json.Value) ParseError!Args {
    if (value != .object) return error.InvalidJson;

    const command = value.object.get("command") orelse return error.MissingCommand;
    if (command != .string) return error.BadCommand;
    if (command.string.len == 0) return error.MissingCommand;

    const cwd = if (value.object.get("cwd")) |cwd_value| cwd: {
        if (cwd_value != .string) return error.BadCwd;
        if (cwd_value.string.len == 0) return error.BadCwd;
        break :cwd cwd_value.string;
    } else null;

    const env = if (value.object.get("env")) |env_value| env: {
        if (env_value != .object) return error.BadEnv;
        try validateEnv(env_value);
        break :env env_value;
    } else null;

    const timeout_seconds = if (value.object.get("timeout")) |timeout_value| timeout: {
        if (timeout_value != .integer) return error.BadTimeout;
        if (timeout_value.integer <= 0) return error.BadTimeout;
        break :timeout std.math.cast(u32, timeout_value.integer) orelse return error.BadTimeout;
    } else bash.timeout_seconds_default;

    return .{ .command = command.string, .cwd = cwd, .env = env, .timeout_seconds = timeout_seconds };
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
        error.BadCommand => common.fail(gpa, "bash: command must be a string\n", 2),
        error.BadCwd => common.fail(gpa, "bash: cwd must be a non-empty string\n", 2),
        error.BadEnv => common.fail(gpa, "bash: env must be an object\n", 2),
        error.BadEnvKey => common.fail(gpa, "bash: env keys must be valid environment variable names\n", 2),
        error.BadEnvValue => common.fail(gpa, "bash: env values must be strings\n", 2),
        error.BadTimeout => common.fail(gpa, "bash: timeout must be a positive integer number of seconds\n", 2),
    };
}

fn currentEnvMap(gpa: std.mem.Allocator) std.mem.Allocator.Error!std.process.Environ.Map {
    if (builtin.os.tag == .windows) {
        return std.process.Environ.createMap(.{ .block = .global }, gpa);
    }

    var map = std.process.Environ.Map.init(gpa);
    errdefer map.deinit();
    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) {
        const line = std.mem.span(entry);
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
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

fn mapBashError(err: anyerror) common.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.Unexpected,
    };
}

/// The bash Display label is the command itself, not "bash <command>" —
/// the `$ ` prefix added by `thread.zig` already reads as a shell prompt.
fn displayLabel(gpa: std.mem.Allocator, args: []const u8) std.mem.Allocator.Error![]u8 {
    return common.extractStringField(gpa, args, "command", "bash");
}

test "bash displayLabel extracts command" {
    const gpa = std.testing.allocator;
    const label = try displayLabel(gpa, "{\"command\":\"pwd\"}");
    defer gpa.free(label);
    try std.testing.expectEqualStrings("pwd", label);
}

test "bash displayLabel falls back on partial JSON" {
    const gpa = std.testing.allocator;
    const label = try displayLabel(gpa, "{\"command");
    defer gpa.free(label);
    try std.testing.expectEqualStrings("bash", label);
}

test "bash tool applies env object" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runTool(gpa, std.testing.io, cwd, "{\"command\":\"printf \\\"$BASH_TOOL_TEST\\\"\",\"env\":{\"BASH_TOOL_TEST\":\"hello-env\"}}");
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

    var output = try runTool(gpa, std.testing.io, cwd, "{\"command\":\"printf \\\"$PWD\\\"\",\"cwd\":\".zig-cache/bash-tool-test\"}");
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expectEqualStrings(expected, output.stdout);
}

test "bash tool parses timeout" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"command\":\"printf ok\",\"timeout\":42}", .{});
    defer parsed.deinit();

    const args = try parseArgs(parsed.value);

    try std.testing.expectEqual(@as(u32, 42), args.timeout_seconds);
}
