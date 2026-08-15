//! Tool display formatting: human-facing labels, bodies, and LLM observations.
//!
//! Consolidates display helpers that were previously split across agent.zig
//! (parseCommand, formatToolDisplay) and executor.zig (makeDisplay,
//! makeDisplayBody, formatLlmObservation). All are pure formatting functions
//! with no side effects beyond allocation.

const std = @import("std");
const tools = @import("../tools.zig");
const parts_mod = @import("parts.zig");
const tools_common = @import("common.zig");

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
/// tool's display formatter. Falls back to `<name> <arguments>` when the
/// tool is unknown (shouldn't happen outside test paths).
pub fn formatToolDisplay(
    gpa: std.mem.Allocator,
    tool: ?tools.Tool,
    arguments: []const u8,
) !tools.ToolDisplay {
    const t = tool orelse
        return .{ .label = try std.fmt.allocPrint(gpa, "<unknown> {s}", .{arguments}) };
    return t.display(gpa, arguments, t.userdata);
}

/// Look up a display label for a tool. Falls back to the tool name when
/// unknown — used by the executor internally where the full arguments
/// string would be noisy. Pass `null` for `tool` when the registry did
/// not resolve the call.
pub fn lookupDisplay(
    gpa: std.mem.Allocator,
    tool: ?tools.Tool,
    name: []const u8,
    args: []const u8,
) !tools.ToolDisplay {
    const t = tool orelse return .{ .label = try gpa.dupe(u8, name) };
    return t.display(gpa, args, t.userdata);
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
    // m4: a truncated_tail's rendered footer ("[Showing last …]") guarantees
    // the string is not clean JSON, and its head may be truncated mid-JSON.
    // isJson could spuriously return true (head starts '{', footer ends ']'),
    // so never pretty-print a truncated_tail.
    const skip_pretty = if (result.observation) |o| o == .truncated_tail else false;
    const obs = if (result.observation) |o| try o.render(gpa) else if (result.stdout.len > 0 and result.stderr.len > 0)
        try std.fmt.allocPrint(gpa, "{s}\n{s}", .{ result.stdout, result.stderr })
    else if (result.stdout.len > 0) try gpa.dupe(u8, result.stdout) else if (result.stderr.len > 0) try gpa.dupe(u8, result.stderr) else try gpa.dupe(u8, "empty");
    errdefer gpa.free(obs);
    if (!skip_pretty and parts_mod.isJson(obs)) {
        if (parts_mod.formatJson(gpa, obs)) |formatted| {
            defer gpa.free(formatted.spans); // C2: don't leak spans
            gpa.free(obs);
            return formatted.text;
        } else |_| {} // malformed → return the plain string
    }
    return obs;
}

test "formatLlmObservation pretty-prints JSON stdout" {
    const gpa = std.testing.allocator;
    const stdout = try gpa.dupe(u8, "{\"a\":1}");
    const stderr = try gpa.alloc(u8, 0);
    var output: tools.Output = .{ .stdout = stdout, .stderr = stderr, .code = 0 };
    defer output.deinit(gpa);
    const text = try formatLlmObservation(gpa, output);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"a\": 1") != null);
}

test "formatLlmObservation leaves mixed stdout+stderr unchanged" {
    const gpa = std.testing.allocator;
    const stdout = try gpa.dupe(u8, "prefix {");
    const stderr = try gpa.dupe(u8, "err");
    var output: tools.Output = .{ .stdout = stdout, .stderr = stderr, .code = 0 };
    defer output.deinit(gpa);
    const text = try formatLlmObservation(gpa, output);
    defer gpa.free(text);
    // Not clean JSON, so no pretty-print: raw concatenation.
    try std.testing.expectEqualStrings("prefix {\nerr", text);
}

test "formatLlmObservation does not pretty-print a truncated tail" {
    const gpa = std.testing.allocator;
    const tail_text = try gpa.dupe(u8, "{");
    const path = try gpa.dupe(u8, "/tmp/out.log");
    const observation: tools_common.Observation = .{ .truncated_tail = .{
        .text = tail_text,
        .total_lines = 10,
        .shown_lines = 2,
        .total_bytes = 100,
        .shown_bytes = 50,
        .full_output_path = path,
    } };
    const stdout = try gpa.alloc(u8, 0);
    const stderr = try gpa.alloc(u8, 0);
    var output: tools.Output = .{ .stdout = stdout, .stderr = stderr, .code = 0, .observation = observation };
    defer output.deinit(gpa);
    const text = try formatLlmObservation(gpa, output);
    defer gpa.free(text);
    // Rendered footer verbatim — no pretty-print attempt.
    try std.testing.expect(std.mem.indexOf(u8, text, "[Showing last 2 of 10 lines") != null);
}

test "parse bash command arguments" {
    const gpa = std.testing.allocator;
    const command = try parseCommand(gpa, "{\"command\":\"zig build test\"}");
    defer gpa.free(command);
    try std.testing.expectEqualStrings("zig build test", command);
}
