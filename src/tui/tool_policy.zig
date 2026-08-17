const std = @import("std");

const transcript_mod = @import("../transcript.zig");
const tools_mod = @import("../tools.zig");

pub const Policy = struct {
    expand_by_default: bool,
    render: transcript_mod.Render,
};

const entries = [_]struct { name: []const u8, policy: Policy }{
    // Exactly ONE shell-tool entry, keyed off the canonical comptime shell
    // name (`pwsh` on Windows, `bash` elsewhere). The bidirectional comptime
    // validation below demands every builtin have an entry and every entry
    // have a builtin — so a hardcoded `"bash"` here would leave an orphan on
    // Windows and a hardcoded `"pwsh"` an orphan on POSIX. One entry matching
    // the one selected shell is the only correct form.
    .{ .name = tools_mod.shell_tool.name, .policy = .{ .expand_by_default = false, .render = .plain } },
    .{ .name = "lane", .policy = .{ .expand_by_default = false, .render = .plain } },
    .{ .name = "background", .policy = .{ .expand_by_default = false, .render = .plain } },
};

comptime {
    for (tools_mod.builtinRegistry()) |tool| {
        var found = false;
        for (entries) |entry| if (std.mem.eql(u8, entry.name, tool.name)) {
            found = true;
        };
        if (!found) @compileError("missing TUI policy for tool: " ++ tool.name);
    }

    for (entries) |entry| {
        var found = false;
        for (tools_mod.builtinRegistry()) |tool| if (std.mem.eql(u8, entry.name, tool.name)) {
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
    const policy = forName("unknown_tool");
    try std.testing.expect(policy.expand_by_default);
    try std.testing.expectEqual(transcript_mod.Render.plain, policy.render);
}
