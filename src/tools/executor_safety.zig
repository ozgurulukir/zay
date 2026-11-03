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

/// Re-exports so callers of the gate can mint tokens without importing the
/// classifier module directly.
pub const ClassifiedCommand = shell_safety.ClassifiedCommand;
pub const mintClassified = shell_safety.mintClassified;

/// The verdict of the shell classification gate (#295). The approved case
/// carries the minted proof that the command was classified — the executor
/// threads it into `runContained*` so the contained runners receive
/// classified input by construction.
pub const Outcome = union(enum) {
    /// Run the call; `command` was classified (safe, or unsafe-but-approved).
    allowed: shell_safety.ClassifiedCommand,
    /// Refuse the call; the reason is surfaced to the model verbatim.
    /// Static literals only — the executor dupes it, never frees the field.
    rejected: []const u8,
    /// Not a classification matter (non-shell call, malformed args dispatch
    /// will reject, unknown skill) — let the dispatch path produce its own
    /// structured error.
    defer_to_dispatch,
};

/// Rejection reason for a shell/skill call whose arguments cannot be parsed
/// into a command (#295: fail closed at the gate — refuse, never let
/// unclassified input reach a contained runner).
const unclassifiable_reason = "The tool call could not be safety-classified: the shell command arguments are invalid (expected {\"command\": \"...\"}). The call was refused.";

/// Check if a tool call invokes the host shell with a destructive command
/// and whether the approval hook rejects it.
pub fn shouldRejectUnsafeShell(
    gpa: std.mem.Allocator,
    io: std.Io,
    bash_classifier_url: ?[]const u8,
    cwd: []const u8,
    call: ai.ToolCall,
    observer: anytype,
) !Outcome {
    if (!std.mem.eql(u8, call.name, tools.shell_tool.name) and !std.mem.eql(u8, call.name, "skill")) return .defer_to_dispatch;
    // Fail closed: an unparseable shell/skill call cannot be classified, so
    // it is refused outright instead of silently proceeding unclassified.
    // Gate-level defense-in-depth — dispatch validation would also reject
    // the call, but that ordering is knowledge no type carries (#295).
    // OOM propagates: hiding resource exhaustion behind a refusal reason
    // would misreport the failure class.
    const command = shell_safety.commandFromArguments(gpa, call.arguments) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .rejected = unclassifiable_reason };
    };
    defer gpa.free(command);
    // The optional URL is threaded straight through: with a classifier set it
    // does the remote+local-fallback dance; with none the local destructive-
    // command matcher runs directly, so `rm -rf /` is always caught.
    const verdict = shell_safety.classify(gpa, io, bash_classifier_url, cwd, command);
    // The token borrows `call.arguments` — owned by the turn and stable for
    // the whole batch — never the extracted `command` (freed below).
    if (verdict != .unsafe) return .{ .allowed = shell_safety.mintClassified(call.arguments) };
    const approved = try observer.approve_unsafe_bash(observer.ctx, call, command);
    if (approved) return .{ .allowed = shell_safety.mintClassified(call.arguments) };
    return .{ .rejected = "The tool call was rejected by the user for being unsafe. Try something else." };
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

    const outcome = try shouldRejectUnsafeShell(gpa, std.testing.io, null, "/tmp", call, observer);
    try std.testing.expect(outcome == .defer_to_dispatch);
    try std.testing.expect(!mock_ctx.approve_called);
}

test "shouldRejectUnsafeShell refuses invalid arguments JSON (fail closed)" {
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
    const outcome = try shouldRejectUnsafeShell(gpa, std.testing.io, null, "/tmp", call, observer);
    try std.testing.expect(outcome == .rejected);
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

    const outcome = try shouldRejectUnsafeShell(gpa, std.testing.io, null, "/tmp", call, observer);
    try std.testing.expect(outcome == .allowed);
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
    const outcome = try shouldRejectUnsafeShell(gpa, std.testing.io, null, "/tmp", call, observer);
    try std.testing.expect(outcome == .rejected);
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

    const outcome = try shouldRejectUnsafeShell(gpa, std.testing.io, null, "/tmp", call, observer);
    try std.testing.expect(outcome == .allowed);
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

        const outcome = try shouldRejectUnsafeShell(gpa, std.testing.io, null, "/tmp", call, observer);
        try std.testing.expect(outcome == .rejected);
        try std.testing.expect(mock_ctx.approve_called);
    }
}
