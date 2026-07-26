//! Tool display formatting: human-facing labels, bodies, and LLM observations.
//!
//! Consolidates display helpers that were previously split across agent.zig
//! (parseCommand, formatToolDisplay) and executor.zig (makeDisplay,
//! makeDisplayBody, formatLlmObservation). All are pure formatting functions
//! with no side effects beyond allocation.

const std = @import("std");
const tools = @import("../tools.zig");

/// Parse just the `command` field of bash's argument JSON. The TUI uses
/// this to detect whether the streaming bash JSON is complete enough to
/// surface a meaningful title — for partial JSON we hold the title back.
pub fn parseCommand(gpa: std.mem.Allocator, arguments: []const u8) ![]u8 {
    const JsonArgs = struct {
        command: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch return error.InvalidToolArguments;
    defer parsed.deinit();

    const command = parsed.value.command orelse return error.InvalidToolArguments;
    return try gpa.dupe(u8, command);
}

/// Render friendly display metadata for a tool call by delegating to the
/// registered tool. Falls back to `<name> <arguments>` for tools that aren't
/// in the registry (shouldn't happen outside test paths).
pub fn formatToolDisplay(gpa: std.mem.Allocator, name: []const u8, arguments: []const u8) !tools.ToolDisplay {
    const tool = tools.lookup(name) orelse
        return .{ .label = try std.fmt.allocPrint(gpa, "{s} {s}", .{ name, arguments }) };
    return tool.display(gpa, arguments);
}

/// Look up the tool in the registry and delegate to its display formatter.
/// Falls back to the tool name itself when unknown — used by the executor
/// internally where the full arguments string would be noisy.
pub fn lookupDisplay(gpa: std.mem.Allocator, name: []const u8, args: []const u8) !tools.ToolDisplay {
    const tool = tools.lookup(name) orelse return .{ .label = try gpa.dupe(u8, name) };
    return tool.display(gpa, args);
}

/// The human-facing body. Each tool owns its own display: when it sets a
/// `display`, that is the body. Otherwise the body is the raw stdout, or a
/// sentinel when there is none.
pub fn makeDisplayBody(gpa: std.mem.Allocator, result: tools.Output) ![]u8 {
    switch (result.display) {
        inline .text, .diff => |display| return gpa.dupe(u8, display),
        .none => {},
    }
    if (result.stdout.len == 0) {
        if (result.stderr.len > 0) return gpa.alloc(u8, 0);
        return gpa.dupe(u8, "no output");
    }
    return gpa.dupe(u8, result.stdout);
}

/// The LLM facing observation: stdout if non-empty, else stderr if
/// non-empty, else the literal "empty". When both are non-empty (typical
/// for bash commands writing to both) concatenate so we don't drop signal.
pub fn formatLlmObservation(gpa: std.mem.Allocator, result: tools.Output) ![]u8 {
    if (result.observation) |observation| return observation.render(gpa);
    if (result.stdout.len > 0 and result.stderr.len > 0) {
        return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ result.stdout, result.stderr });
    }
    if (result.stdout.len > 0) return gpa.dupe(u8, result.stdout);
    if (result.stderr.len > 0) return gpa.dupe(u8, result.stderr);
    return gpa.dupe(u8, "empty");
}

test "parse bash command arguments" {
    const gpa = std.testing.allocator;
    const command = try parseCommand(gpa, "{\"command\":\"zig build test\"}");
    defer gpa.free(command);
    try std.testing.expectEqualStrings("zig build test", command);
}
