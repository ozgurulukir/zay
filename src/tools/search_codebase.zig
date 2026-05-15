const std = @import("std");
const common = @import("common.zig");

pub const tool: common.Tool = .{
    .name = "search_codebase",
    .description = "Search the codebase. TODO: not implemented yet.",
    .schema = .{
        .properties = &.{
            .{
                .name = "query",
                .kind = .string,
                .description = "Search query.",
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
    _ = io;
    _ = cwd;
    _ = arguments;
    return common.fail(gpa, "search_codebase: not implemented yet\n", 2);
}

fn displayLabel(gpa: std.mem.Allocator, args: []const u8) std.mem.Allocator.Error![]u8 {
    const query = common.extractStringField(gpa, args, "query", "") catch return error.OutOfMemory;
    defer gpa.free(query);
    if (query.len == 0) return gpa.dupe(u8, "search_codebase");
    return std.fmt.allocPrint(gpa, "search_codebase {s}", .{query});
}

test "search_codebase is a todo" {
    var output = try runTool(std.testing.allocator, std.testing.io, ".", "{\"query\":\"foo\"}");
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), output.code);
}
