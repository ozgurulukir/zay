const std = @import("std");

const thread_mod = @import("../thread.zig");
const tools_mod = @import("../tools.zig");

pub const Policy = struct {
    expand_by_default: bool,
    render: thread_mod.Render,
};

const entries = [_]struct { name: []const u8, policy: Policy }{
    .{ .name = "bash", .policy = .{ .expand_by_default = false, .render = .plain } },
    .{ .name = "read", .policy = .{ .expand_by_default = false, .render = .plain } },
    .{ .name = "find", .policy = .{ .expand_by_default = false, .render = .plain } },
    .{ .name = "grep", .policy = .{ .expand_by_default = false, .render = .plain } },
    .{ .name = "write_file", .policy = .{ .expand_by_default = true, .render = .plain } },
    .{ .name = "edit_file", .policy = .{ .expand_by_default = true, .render = .diff } },
};

comptime {
    for (tools_mod.registry) |tool| {
        var found = false;
        for (entries) |entry| if (std.mem.eql(u8, entry.name, tool.name)) {
            found = true;
        };
        if (!found) @compileError("missing TUI policy for tool: " ++ tool.name);
    }

    for (entries) |entry| {
        var found = false;
        for (tools_mod.registry) |tool| if (std.mem.eql(u8, entry.name, tool.name)) {
            found = true;
        };
        if (!found) @compileError("orphan TUI policy entry: " ++ entry.name);
    }
}

pub fn forName(name: []const u8) Policy {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.policy;
    }
    return .{ .expand_by_default = true, .render = .plain };
}

test "unknown tools use a safe failure display policy" {
    const policy = forName("read_file");
    try std.testing.expect(policy.expand_by_default);
    try std.testing.expectEqual(thread_mod.Render.plain, policy.render);
}
