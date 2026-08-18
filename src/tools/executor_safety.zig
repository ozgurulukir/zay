//! Shell safety classification and interactive approval integration for the executor.
//!
//! Extracted from executor.zig: checks whether a tool call invokes the host shell,
//! runs local and optional remote classification on destructive commands, and queries
//! the tool observer for interactive approval.

const std = @import("std");

const ai = @import("../ai.zig");
const os = @import("../os.zig");
const shell_safety = @import("bash_safety.zig");
const tools = @import("../tools.zig");

/// Check if a tool call invokes the host shell with a destructive command
/// and whether the approval hook rejects it.
pub fn shouldRejectUnsafeShell(
    gpa: std.mem.Allocator,
    io: std.Io,
    bash_classifier_url: ?[]const u8,
    cwd: []const u8,
    call: ai.ToolCall,
    observer: anytype,
) !bool {
    if (!std.mem.eql(u8, call.name, tools.shell_tool.name)) return false;
    const command = shell_safety.commandFromArguments(gpa, call.arguments) catch return false;
    defer gpa.free(command);
    // The optional URL is threaded straight through: with a classifier set it
    // does the remote+local-fallback dance; with none the local destructive-
    // command matcher runs directly, so `rm -rf /` is always caught.
    const verdict = shell_safety.classify(gpa, io, bash_classifier_url, cwd, command);
    if (verdict != .unsafe) return false;
    const approved = try observer.approve_unsafe_bash(observer.ctx, call, command);
    return !approved;
}

test "shouldRejectUnsafeShell ignores non-shell tools" {
    const gpa = std.testing.allocator;
    const call: ai.ToolCall = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_1") },
        .name = try gpa.dupe(u8, "read_file"),
        .arguments = try gpa.dupe(u8, "{\"path\":\"/etc/passwd\"}"),
    };
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    const MockCtx = struct {
        approve_called: bool = false,
        fn approve(ctx: *@This(), _: ai.ToolCall, _: []const u8) anyerror!bool {
            ctx.approve_called = true;
            return false;
        }
    };
    var mock_ctx: MockCtx = .{};
    const observer = .{
        .ctx = &mock_ctx,
        .approve_unsafe_bash = MockCtx.approve,
    };

    const rejected = try shouldRejectUnsafeShell(gpa, std.testing.io, null, "/tmp", call, observer);
    try std.testing.expect(!rejected);
    try std.testing.expect(!mock_ctx.approve_called);
}

test "shouldRejectUnsafeShell ignores invalid arguments JSON gracefully" {
    const gpa = std.testing.allocator;
    const call: ai.ToolCall = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_bad_json") },
        .name = try gpa.dupe(u8, tools.shell_tool.name),
        .arguments = try gpa.dupe(u8, "{invalid JSON"),
    };
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    const MockCtx = struct {
        approve_called: bool = false,
        fn approve(ctx: *@This(), _: ai.ToolCall, _: []const u8) anyerror!bool {
            ctx.approve_called = true;
            return false;
        }
    };
    var mock_ctx: MockCtx = .{};
    const observer = .{
        .ctx = &mock_ctx,
        .approve_unsafe_bash = MockCtx.approve,
    };

    const rejected = try shouldRejectUnsafeShell(gpa, std.testing.io, null, "/tmp", call, observer);
    try std.testing.expect(!rejected);
    try std.testing.expect(!mock_ctx.approve_called);
}

test "shouldRejectUnsafeShell allows safe commands without prompting observer" {
    const gpa = std.testing.allocator;
    const call: ai.ToolCall = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_safe") },
        .name = try gpa.dupe(u8, tools.shell_tool.name),
        .arguments = try gpa.dupe(u8, "{\"command\":\"git status\"}"),
    };
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    const MockCtx = struct {
        approve_called: bool = false,
        fn approve(ctx: *@This(), _: ai.ToolCall, _: []const u8) anyerror!bool {
            ctx.approve_called = true;
            return false;
        }
    };
    var mock_ctx: MockCtx = .{};
    const observer = .{
        .ctx = &mock_ctx,
        .approve_unsafe_bash = MockCtx.approve,
    };

    const rejected = try shouldRejectUnsafeShell(gpa, std.testing.io, null, "/tmp", call, observer);
    try std.testing.expect(!rejected);
    try std.testing.expect(!mock_ctx.approve_called);
}

test "shouldRejectUnsafeShell consults observer and rejects when denied" {
    const gpa = std.testing.allocator;
    const call: ai.ToolCall = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_unsafe") },
        .name = try gpa.dupe(u8, tools.shell_tool.name),
        .arguments = try gpa.dupe(u8, "{\"command\":\"rm -rf /\"}"),
    };
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    const MockCtx = struct {
        approve_called: bool = false,
        fn approve(ctx: *@This(), _: ai.ToolCall, _: []const u8) anyerror!bool {
            ctx.approve_called = true;
            return false; // User denies
        }
    };
    var mock_ctx: MockCtx = .{};
    const observer = .{
        .ctx = &mock_ctx,
        .approve_unsafe_bash = MockCtx.approve,
    };

    const rejected = try shouldRejectUnsafeShell(gpa, std.testing.io, null, "/tmp", call, observer);
    try std.testing.expect(rejected);
    try std.testing.expect(mock_ctx.approve_called);
}

test "shouldRejectUnsafeShell consults observer and allows when approved" {
    const gpa = std.testing.allocator;
    const call: ai.ToolCall = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_approved") },
        .name = try gpa.dupe(u8, tools.shell_tool.name),
        .arguments = try gpa.dupe(u8, "{\"command\":\"rm -rf /\"}"),
    };
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    const MockCtx = struct {
        approve_called: bool = false,
        fn approve(ctx: *@This(), _: ai.ToolCall, _: []const u8) anyerror!bool {
            ctx.approve_called = true;
            return true; // User approves
        }
    };
    var mock_ctx: MockCtx = .{};
    const observer = .{
        .ctx = &mock_ctx,
        .approve_unsafe_bash = MockCtx.approve,
    };

    const rejected = try shouldRejectUnsafeShell(gpa, std.testing.io, null, "/tmp", call, observer);
    try std.testing.expect(!rejected);
    try std.testing.expect(mock_ctx.approve_called);
}

test "shouldRejectUnsafeShell catches chained destructive commands" {
    const gpa = std.testing.allocator;
    const chained_commands = [_][]const u8{
        "echo starting; rm -rf /; echo done",
        "ls -la && rm -rf /",
    };

    for (chained_commands) |cmd| {
        const json = try std.fmt.allocPrint(gpa, "{{\"command\":\"{s}\"}}", .{cmd});
        defer gpa.free(json);

        const call: ai.ToolCall = .{
            .call_id = .{ .value = try gpa.dupe(u8, "call_chained") },
            .name = try gpa.dupe(u8, tools.shell_tool.name),
            .arguments = try gpa.dupe(u8, json),
        };
        defer {
            gpa.free(call.call_id.value);
            gpa.free(call.name);
            gpa.free(call.arguments);
        }

        const MockCtx = struct {
            approve_called: bool = false,
            fn approve(ctx: *@This(), _: ai.ToolCall, _: []const u8) anyerror!bool {
                ctx.approve_called = true;
                return false;
            }
        };
        var mock_ctx: MockCtx = .{};
        const observer = .{
            .ctx = &mock_ctx,
            .approve_unsafe_bash = MockCtx.approve,
        };

        const rejected = try shouldRejectUnsafeShell(gpa, std.testing.io, null, "/tmp", call, observer);
        try std.testing.expect(rejected);
        try std.testing.expect(mock_ctx.approve_called);
    }
}
