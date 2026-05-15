const std = @import("std");
const bash = @import("../bash.zig");
const common = @import("common.zig");

pub const tool: common.Tool = .{
    .name = "bash",
    .description = "Executes bash command in shell session for terminal operations like mkdir, mv, git, builds, and tests. Use the read tool instead of shell commands such as cat, head, tail, less, more, ls, sed -n, or awk NR when inspecting files or directories.",
    .schema = .{
        .properties = &.{
            .{
                .name = "command",
                .kind = .string,
                .description = "Shell command to execute.",
                .required = true,
            },
        },
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

    const command = parsed.value.object.get("command") orelse
        return common.fail(gpa, "bash: missing command\n", 2);
    if (command != .string) return common.fail(gpa, "bash: command must be a string\n", 2);
    if (command.string.len == 0) return common.fail(gpa, "bash: command must not be empty\n", 2);

    const result = bash.run(gpa, io, cwd, command.string) catch |err| return mapBashError(err);
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .code = result.code,
        .display = result.display,
    };
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
