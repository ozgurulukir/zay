const std = @import("std");
const search = @import("../search.zig");
const common = @import("common.zig");

pub const tool: common.Tool = .{
    .name = "find",
    .description = @embedFile("../prompts/tools/find.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "query",
                .kind = .string,
                .description = "Fuzzy text matched against paths. Not a regex.",
                .required = true,
            },
            .{
                .name = "cursor",
                .kind = .string,
                .description = "Page token from a previous find result. Reuse only with the same query.",
                .required = false,
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
    const request = parseArgs(gpa, arguments) catch |err| return parseError(gpa, err);
    defer gpa.free(request.query);
    defer if (request.cursor) |cursor| gpa.free(cursor);
    const result = search.run(gpa, io, cwd, request) catch |err| return runError(gpa, err);
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .code = result.code,
        .display = null,
    };
}

const ParseError = error{
    InvalidJson,
    MissingQuery,
    BadQuery,
    BadCursor,
};

fn parseArgs(gpa: std.mem.Allocator, arguments: []const u8) ParseError!search.Request {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, arguments, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;

    const query_value = parsed.value.object.get("query") orelse return error.MissingQuery;
    if (query_value != .string) return error.BadQuery;
    if (query_value.string.len == 0) return error.MissingQuery;

    const cursor = if (parsed.value.object.get("cursor")) |cursor_value| value: {
        if (cursor_value != .string) return error.BadCursor;
        if (cursor_value.string.len == 0) return error.BadCursor;
        break :value gpa.dupe(u8, cursor_value.string) catch return error.InvalidJson;
    } else null;
    errdefer if (cursor) |owned| gpa.free(owned);

    const query = gpa.dupe(u8, query_value.string) catch return error.InvalidJson;
    return .{ .op = .find, .query = query, .cursor = cursor };
}

fn parseError(gpa: std.mem.Allocator, err: ParseError) common.Error!common.Output {
    const message = switch (err) {
        error.InvalidJson => "find: invalid JSON arguments\n",
        error.MissingQuery => "find: missing query\n",
        error.BadQuery => "find: query must be a string\n",
        error.BadCursor => "find: cursor must be a non-empty string\n",
    };
    return common.fail(gpa, message, 2);
}

fn runError(gpa: std.mem.Allocator, err: anyerror) common.Error!common.Output {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidCursor => common.fail(gpa, "find: invalid cursor; reuse it with the same query, or omit cursor for a new search\n", 2),
        error.FffFailed => common.fail(gpa, "find: search index failed; retry without cursor to use fallback search\n", 2),
        else => common.failFmt(gpa, 2, "find: {s}\n", .{@errorName(err)}),
    };
}

fn displayLabel(gpa: std.mem.Allocator, args: []const u8) std.mem.Allocator.Error![]u8 {
    const query = common.extractStringField(gpa, args, "query", "") catch return error.OutOfMemory;
    defer gpa.free(query);
    if (query.len == 0) return gpa.dupe(u8, "find");
    return std.fmt.allocPrint(gpa, "find {s}", .{query});
}
