const std = @import("std");

const bash_tool = @import("tools/bash.zig");
const common = @import("tools/common.zig");
const lane_tool = @import("tools/lane.zig");
const registry_mod = @import("tools/registry.zig");

const assert = std.debug.assert;

pub const Output = common.Output;
pub const DisplayKind = common.DisplayKind;
pub const Error = common.Error;
pub const Tool = common.Tool;
pub const Schema = common.Schema;
pub const ToolDisplay = common.ToolDisplay;

/// Runtime-mutable tool registry. The App owns one; builtin tools live in
/// its immutable `builtin` slice, plugin tools are appended at runtime
/// through `addPluginTool`. This is the single source of truth for tools
/// in the agent — both `tools.run` (dispatch) and each `LanguageModel`
/// adapter (schema serialization) read from it.
pub const ToolRegistry = registry_mod.ToolRegistry;

/// Static builtin slice — the only thing the runtime cannot synthesize.
/// Consumed by `ToolRegistry.init` and by tests.
pub fn builtinRegistry() []const Tool {
    return &.{
        bash_tool.tool,
        lane_tool.tool,
    };
}

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    name: []const u8,
    arguments: []const u8,
) Error!Output {
    return runWith(builtinRegistry(), gpa, io, cwd, name, arguments);
}

/// Dispatch a tool by name through a registry slice. Used by the executor
/// after it has resolved which registry owns the call.
pub fn runWith(
    tools: []const Tool,
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    name: []const u8,
    arguments: []const u8,
) Error!Output {
    const tool = lookupIn(tools, name) orelse return failFmt(gpa, 2, "unknown tool: {s}\n", .{name});
    return tool.run(gpa, io, cwd, arguments, tool.userdata);
}

/// Locate a tool by name in an arbitrary slice. Returns null when no
/// tool with that name exists. Linear scan — fine for the handful of
/// tools Nova exposes.
pub fn lookupIn(slice: []const Tool, name: []const u8) ?Tool {
    assert(name.len > 0);
    for (slice) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

fn failFmt(gpa: std.mem.Allocator, code: u8, comptime fmt: []const u8, args: anytype) Error!Output {
    return common.failFmt(gpa, code, fmt, args);
}

test "registry contains every tool exactly once" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    for (builtinRegistry()) |tool| {
        const gop = try seen.getOrPut(std.testing.allocator, tool.name);
        try std.testing.expect(!gop.found_existing);
    }
    try std.testing.expectEqual(@as(usize, 2), builtinRegistry().len);
}

test "lookup finds a registered tool" {
    const tool = lookupIn(builtinRegistry(), "bash") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("bash", tool.name);
}

test "lookup returns null for unknown tool" {
    try std.testing.expect(lookupIn(builtinRegistry(), "does_not_exist") == null);
}

test {
    _ = bash_tool;
    _ = lane_tool;
    _ = common;
}
