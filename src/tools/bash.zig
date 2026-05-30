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
    .displayLabel = displayLabel,
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
    parsed: std.json.Parsed(JsonArgs),
    timeout_seconds: u32 = bash.timeout_seconds_default,

    fn deinit(self: *Args) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

const JsonArgs = struct {
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?std.json.Value = null,
    timeout: ?u32 = null,
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

fn parseArgs(gpa: std.mem.Allocator, arguments: []const u8) ParseError!Args {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch return error.InvalidJson;
    errdefer parsed.deinit();

    const command = parsed.value.command orelse return error.MissingCommand;
    if (command.len == 0) return error.MissingCommand;

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
    var args = try parseArgs(std.testing.allocator, "{\"command\":\"printf ok\",\"timeout\":42}");
    defer args.deinit();

    try std.testing.expectEqual(@as(u32, 42), args.timeout_seconds);
}
