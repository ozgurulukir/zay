const std = @import("std");

const bash_tool = @import("tools/bash.zig");
const common = @import("tools/common.zig");
const edit_file = @import("tools/edit_file.zig");
const find_tool = @import("tools/find.zig");
const grep_tool = @import("tools/grep.zig");
const read = @import("tools/read.zig");
const write_file = @import("tools/write_file.zig");

const assert = std.debug.assert;

pub const Output = common.Output;
pub const Error = common.Error;
pub const Tool = common.Tool;
pub const Schema = common.Schema;

/// The Tool registry — single source of truth for what tools exist.
/// Consumed by `ExecutorService` (for dispatch) and by each `LanguageModel`
/// adapter (for building its provider-specific tools schema).
pub const registry: []const Tool = &.{
    bash_tool.tool,
    read.tool,
    write_file.tool,
    edit_file.tool,
    find_tool.tool,
    grep_tool.tool,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    name: []const u8,
    arguments: []const u8,
) Error!Output {
    const tool = lookup(name) orelse return failFmt(gpa, 2, "unknown tool: {s}\n", .{name});
    return tool.run(gpa, io, cwd, arguments);
}

/// Locate a tool in the registry by name. Returns null when no tool with
/// that name exists. Linear scan over a fixed-size slice — fine for the
/// handful of tools Nova exposes.
pub fn lookup(name: []const u8) ?Tool {
    assert(name.len > 0);
    for (registry) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

fn failFmt(gpa: std.mem.Allocator, code: u8, comptime fmt: []const u8, args: anytype) Error!Output {
    return common.failFmt(gpa, code, fmt, args);
}

test "registry contains every tool exactly once" {
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    for (registry) |tool| {
        const gop = try seen.getOrPut(tool.name);
        try std.testing.expect(!gop.found_existing);
    }
    try std.testing.expectEqual(@as(usize, 6), registry.len);
}

test "lookup finds a registered tool" {
    const tool = lookup("bash") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("bash", tool.name);
}

test "lookup returns null for unknown tool" {
    try std.testing.expect(lookup("does_not_exist") == null);
}

test {
    _ = bash_tool;
    _ = common;
    _ = edit_file;
    _ = find_tool;
    _ = grep_tool;
    _ = read;
    _ = write_file;
    _ = @import("tools/hashline/hash.zig");
    _ = @import("tools/hashline/parse.zig");
    _ = @import("tools/hashline/apply.zig");
    _ = @import("tools/hashline/render_diff.zig");
}
