const std = @import("std");
const search = @import("../search.zig");
const common = @import("common.zig");

pub const tool: common.Tool = .{
    .name = "grep",
    .description = @embedFile("../prompts/tools/grep.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "query",
                .kind = .string,
                .description = "Regex matched against file contents.",
                .required = true,
            },
            .{
                .name = "cursor",
                .kind = .string,
                .description = "Page token from a previous grep result. Reuse only with the same query.",
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

const JsonArgs = struct {
    query: ?[]const u8 = null,
    cursor: ?[]const u8 = null,
};

fn parseArgs(gpa: std.mem.Allocator, arguments: []const u8) ParseError!search.Request {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch return error.InvalidJson;
    defer parsed.deinit();

    const raw_query = parsed.value.query orelse return error.MissingQuery;
    if (raw_query.len == 0) return error.MissingQuery;

    const cursor = if (parsed.value.cursor) |raw_cursor| value: {
        if (raw_cursor.len == 0) return error.BadCursor;
        break :value gpa.dupe(u8, raw_cursor) catch return error.InvalidJson;
    } else null;
    errdefer if (cursor) |owned| gpa.free(owned);

    const query = gpa.dupe(u8, raw_query) catch return error.InvalidJson;
    return .{ .op = .grep, .query = query, .cursor = cursor };
}

fn parseError(gpa: std.mem.Allocator, err: ParseError) common.Error!common.Output {
    const message = switch (err) {
        error.InvalidJson => "grep: invalid JSON arguments\n",
        error.MissingQuery => "grep: missing query\n",
        error.BadQuery => "grep: query must be a string\n",
        error.BadCursor => "grep: cursor must be a non-empty string\n",
    };
    return common.fail(gpa, message, 2);
}

fn runError(gpa: std.mem.Allocator, err: anyerror) common.Error!common.Output {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidCursor => common.fail(gpa, "grep: invalid cursor; reuse it with the same query, or omit cursor for a new search\n", 2),
        error.FffFailed => common.fail(gpa, "grep: search index failed; retry without cursor to use fallback search\n", 2),
        else => common.failFmt(gpa, 2, "grep: {s}\n", .{@errorName(err)}),
    };
}

fn displayLabel(gpa: std.mem.Allocator, args: []const u8) std.mem.Allocator.Error![]u8 {
    const query = common.extractStringField(gpa, args, "query", "") catch return error.OutOfMemory;
    defer gpa.free(query);
    if (query.len == 0) return gpa.dupe(u8, "grep");
    return std.fmt.allocPrint(gpa, "grep {s}", .{query});
}
