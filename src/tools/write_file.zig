const std = @import("std");
const common = @import("common.zig");

const assert = std.debug.assert;

const tab_replacement: []const u8 = "    ";

pub const tool: common.Tool = .{
    .name = "write_file",
    .description = @embedFile("../prompts/tools/write_file.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "path",
                .kind = .string,
                .description = "Required. File path to create or overwrite, relative to the current working directory unless absolute.",
                .required = true,
            },
            .{
                .name = "content",
                .kind = .string,
                .description = "Required. Complete file content to write. Do not put the path here.",
                .required = true,
            },
        },
    },
    .run = runTool,
    .displayLabel = displayLabel,
};

fn displayLabel(gpa: std.mem.Allocator, args: []const u8) std.mem.Allocator.Error![]u8 {
    const path = common.extractStringField(gpa, args, "path", "") catch return error.OutOfMemory;
    defer gpa.free(path);
    if (path.len == 0) return gpa.dupe(u8, "write_file");
    return std.fmt.allocPrint(gpa, "write_file {s}", .{path});
}

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, arguments, .{}) catch {
        return common.fail(gpa, "write_file: invalid JSON arguments\n", 2);
    };
    defer parsed.deinit();

    const path = parsed.value.object.get("path") orelse return common.fail(gpa, "write_file: missing required field `path`; call write_file with both `path` and `content`\n", 2);
    const content = parsed.value.object.get("content") orelse return common.fail(gpa, "write_file: missing required field `content`; call write_file with both `path` and `content`\n", 2);
    if (path != .string) return common.fail(gpa, "write_file: path must be a string\n", 2);
    if (content != .string) return common.fail(gpa, "write_file: content must be a string\n", 2);
    return write(gpa, io, cwd, path.string, content.string);
}

fn write(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, path: []const u8, content: []const u8) common.Error!common.Output {
    const absolute = common.joinPath(gpa, cwd, path) catch |err| return common.mapAllocError(err);
    defer gpa.free(absolute);

    if (std.fs.path.dirname(absolute)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch |err| {
            return common.failFmt(gpa, 1, "write_file: cannot create parent of {s}: {s}\n", .{ path, @errorName(err) });
        };
    }

    var file = std.Io.Dir.createFileAbsolute(io, absolute, .{ .truncate = true }) catch |err| {
        return common.failFmt(gpa, 1, "write_file: cannot open {s}: {s}\n", .{ path, @errorName(err) });
    };
    defer file.close(io);
    file.writeStreamingAll(io, content) catch |err| {
        return common.failFmt(gpa, 1, "write_file: write to {s} failed: {s}\n", .{ path, @errorName(err) });
    };

    return buildOutput(gpa, path, content);
}

fn buildOutput(gpa: std.mem.Allocator, path: []const u8, content: []const u8) common.Error!common.Output {
    assert(path.len > 0);
    const message = std.fmt.allocPrint(
        gpa,
        "Successfully wrote {s}",
        .{path},
    ) catch |err| return common.mapAllocError(err);
    errdefer gpa.free(message);
    if (content.len == 0) return common.ok(gpa, message);
    const display = normaliseContent(gpa, content) catch |err| return common.mapAllocError(err);
    return common.okWithDisplay(gpa, message, display);
}

fn normaliseContent(gpa: std.mem.Allocator, content: []const u8) ![]u8 {
    assert(content.len > 0);
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    for (content) |byte| {
        if (byte == '\t') {
            try buffer.appendSlice(gpa, tab_replacement);
        } else {
            try buffer.append(gpa, byte);
        }
    }
    return buffer.toOwnedSlice(gpa);
}

test "write_file requires a path" {
    var output = try runTool(std.testing.allocator, std.testing.io, ".", "{\"content\":\"data\"}");
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "missing required field `path`") != null);
}
