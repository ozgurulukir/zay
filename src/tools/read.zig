const std = @import("std");
const common = @import("common.zig");
const hashline = @import("hashline/hash.zig");

const max_file_bytes: usize = 16 * 1024 * 1024;
const max_output_lines: u32 = 2000;
const max_output_bytes: usize = 50 * 1024;
const max_directory_entries: u32 = 2000;

pub const tool: common.Tool = .{
    .name = "read",
    .description = @embedFile("../prompts/tools/read.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "path",
                .kind = .string,
                .description = "File or directory to read. Append a selector for ranges or modes: :50, :50-200, :50+150, :raw, :conflicts.",
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
    if (path.len == 0) return gpa.dupe(u8, "read");
    return std.fmt.allocPrint(gpa, "read {s}", .{path});
}

const Args = struct {
    path: []const u8,
    selector: Selector = .anchored,
};

const Selector = union(enum) {
    anchored,
    raw,
    conflicts,
    range_from: u32,
    range_between: Range,
    range_count: RangeCount,
};

const Range = struct {
    start: u32,
    end: u32,
};

const RangeCount = struct {
    start: u32,
    count: u32,
};

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch {
        return common.fail(gpa, "read: invalid JSON arguments\n", 2);
    };
    defer parsed.deinit();

    const args = parseToolArgs(parsed.value) catch |err| return parseToolError(gpa, err);
    return read(gpa, io, cwd, args);
}

const JsonArgs = struct {
    path: ?[]const u8 = null,
};

const ParseToolError = error{ MissingPath, BadPath, BadSelector };

fn parseToolArgs(value: JsonArgs) ParseToolError!Args {
    const path = value.path orelse return ParseToolError.MissingPath;
    if (path.len == 0) return ParseToolError.MissingPath;
    return parsePathSelector(path) catch return ParseToolError.BadSelector;
}

fn parseToolError(gpa: std.mem.Allocator, err: ParseToolError) common.Error!common.Output {
    const message = switch (err) {
        ParseToolError.MissingPath => "read: missing required field `path`\n",
        ParseToolError.BadPath => "read: path must be a string\n",
        ParseToolError.BadSelector => "read: invalid path selector\n",
    };
    return common.fail(gpa, message, 2);
}

fn parsePathSelector(path: []const u8) ParseToolError!Args {
    const colon = std.mem.findScalarLast(u8, path, ':') orelse return .{ .path = path };
    const suffix = path[colon + 1 ..];
    if (suffix.len == 0) return .{ .path = path };
    if (std.mem.eql(u8, suffix, "raw")) return .{ .path = path[0..colon], .selector = .raw };
    if (std.mem.eql(u8, suffix, "conflicts")) return .{ .path = path[0..colon], .selector = .conflicts };
    if (!std.ascii.isDigit(suffix[0])) return .{ .path = path };
    if (path[0..colon].len == 0) return ParseToolError.BadSelector;

    if (std.mem.findScalar(u8, suffix, '-')) |dash| {
        const start = try parsePositive(suffix[0..dash]);
        const end = try parsePositive(suffix[dash + 1 ..]);
        if (end < start) return ParseToolError.BadSelector;
        return .{ .path = path[0..colon], .selector = .{ .range_between = .{ .start = start, .end = end } } };
    }
    if (std.mem.findScalar(u8, suffix, '+')) |plus| {
        const start = try parsePositive(suffix[0..plus]);
        const count = try parsePositiveAllowZero(suffix[plus + 1 ..]);
        return .{ .path = path[0..colon], .selector = .{ .range_count = .{ .start = start, .count = count } } };
    }
    return .{ .path = path[0..colon], .selector = .{ .range_from = try parsePositive(suffix) } };
}

fn parsePositive(text: []const u8) ParseToolError!u32 {
    const value = try parsePositiveAllowZero(text);
    if (value == 0) return ParseToolError.BadSelector;
    return value;
}

fn parsePositiveAllowZero(text: []const u8) ParseToolError!u32 {
    if (text.len == 0) return ParseToolError.BadSelector;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return ParseToolError.BadSelector;
    }
    return std.fmt.parseInt(u32, text, 10) catch return ParseToolError.BadSelector;
}

fn read(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, args: Args) common.Error!common.Output {
    const absolute = common.joinPath(gpa, cwd, args.path) catch |err| return common.mapAllocError(err);
    defer gpa.free(absolute);

    return readDirectory(gpa, io, absolute) catch |dir_err| switch (dir_err) {
        error.NotDir => readFile(gpa, io, args, absolute),
        else => common.failFmt(gpa, 1, "read: {s}: {s}\n", .{ args.path, @errorName(dir_err) }),
    };
}

// TODO: Investigate io_uring here
fn readDirectory(gpa: std.mem.Allocator, io: std.Io, absolute: []const u8) !common.Output {
    var dir = try std.Io.Dir.openDirAbsolute(io, absolute, .{ .iterate = true });
    defer dir.close(io);

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);

    var iter = dir.iterate();
    var count: u32 = 0;
    while (try iter.next(io)) |entry| {
        if (count >= max_directory_entries) {
            try buffer.print(gpa, "\n[Showing first {d} entries.]", .{max_directory_entries});
            break;
        }
        const suffix: []const u8 = if (entry.kind == .directory) "/" else "";
        try buffer.print(gpa, "{s}{s}\n", .{ entry.name, suffix });
        count += 1;
    }
    return common.ok(gpa, try buffer.toOwnedSlice(gpa));
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, args: Args, absolute: []const u8) common.Error!common.Output {
    const bytes = common.readFileBytes(gpa, io, absolute, max_file_bytes) catch |err| {
        return common.failFmt(gpa, 1, "read: {s}: {s}\n", .{ args.path, @errorName(err) });
    };
    defer gpa.free(bytes);

    return switch (args.selector) {
        .raw => common.ok(gpa, try gpa.dupe(u8, bytes)),
        .conflicts => formatConflicts(gpa, bytes),
        else => formatAnchoredOutput(gpa, args, bytes),
    };
}

fn formatAnchoredOutput(gpa: std.mem.Allocator, args: Args, bytes: []const u8) common.Error!common.Output {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line| try lines.append(gpa, line);
    const total_lines: u32 = @intCast(lines.items.len);

    const window = selectWindow(args.selector, total_lines);
    if (window.start > total_lines) {
        return common.failFmt(gpa, 2, "read: line {d} is past end of file ({d} lines)\n", .{ window.start, total_lines });
    }

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    var emitted: u32 = 0;
    var line_number = window.start;
    while (line_number <= window.end) : (line_number += 1) {
        const new_size = buffer.items.len + estimateLineCost(line_number, lines.items[line_number - 1]);
        if (emitted > 0 and new_size > max_output_bytes) break;
        if (emitted > 0) try buffer.append(gpa, '\n');
        try hashline.writeHashLine(gpa, &buffer, line_number, lines.items[line_number - 1]);
        emitted += 1;
        if (emitted >= max_output_lines) break;
    }
    try appendFooter(gpa, &buffer, window, total_lines, line_number, emitted);

    // The LLM channel keeps the `#HL…|` anchors (edit_file references them);
    // the human display strips them. read owns that stripping — the anchor
    // format is its concern, so no downstream client needs to know about it.
    const anchored = try buffer.toOwnedSlice(gpa);
    errdefer gpa.free(anchored);
    var display: std.ArrayList(u8) = .empty;
    errdefer display.deinit(gpa);
    try hashline.appendStripped(gpa, &display, anchored);
    const stderr = try gpa.alloc(u8, 0);
    errdefer gpa.free(stderr);
    return .{ .stdout = anchored, .stderr = stderr, .code = 0, .display = try display.toOwnedSlice(gpa) };
}

const Window = struct {
    start: u32,
    end: u32,
};

fn selectWindow(selector: Selector, total_lines: u32) Window {
    return switch (selector) {
        .anchored => .{ .start = 1, .end = total_lines },
        .range_from => |start| .{ .start = start, .end = total_lines },
        .range_between => |range| .{ .start = range.start, .end = @min(range.end, total_lines) },
        .range_count => |range| .{ .start = range.start, .end = if (range.count == 0) range.start - 1 else @min(range.start + range.count - 1, total_lines) },
        .raw, .conflicts => unreachable,
    };
}

fn estimateLineCost(line_number: u32, line: []const u8) usize {
    var digits: usize = 1;
    var n = line_number;
    while (n >= 10) : (n /= 10) digits += 1;
    return digits + 2 + 1 + line.len + 1;
}

fn appendFooter(
    gpa: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    window: Window,
    total_lines: u32,
    next_line: u32,
    emitted: u32,
) common.Error!void {
    if (next_line > total_lines) return;
    try buffer.print(gpa, "\n\n[Showing lines {d}-{d} of {d} (truncated at {d} lines / {d}KB). Use path suffix :{d} to continue.]", .{
        window.start, window.start + emitted - 1, total_lines, max_output_lines, max_output_bytes / 1024, next_line,
    });
}

fn formatConflicts(gpa: std.mem.Allocator, bytes: []const u8) common.Error!common.Output {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    var iter = std.mem.splitScalar(u8, bytes, '\n');
    var line: u32 = 1;
    var start: ?u32 = null;
    var count: u32 = 0;
    while (iter.next()) |text| : (line += 1) {
        if (std.mem.startsWith(u8, text, "<<<<<<<")) start = line;
        if (std.mem.startsWith(u8, text, ">>>>>>>")) {
            if (start) |conflict_start| {
                if (count > 0) try buffer.append(gpa, '\n');
                try buffer.print(gpa, "conflict {d}: lines {d}-{d}", .{ count + 1, conflict_start, line });
                count += 1;
                start = null;
            }
        }
    }
    if (count == 0) try buffer.appendSlice(gpa, "No merge conflicts found.\n");
    return common.ok(gpa, try buffer.toOwnedSlice(gpa));
}

test "read missing path is a usage error" {
    var output = try runTool(std.testing.allocator, std.testing.io, ".", "{}");
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "missing required field `path`") != null);
}

test "parse path selectors" {
    try std.testing.expectEqual(Selector.raw, (try parsePathSelector("src/a.zig:raw")).selector);
    try std.testing.expectEqual(@as(u32, 50), (try parsePathSelector("src/a.zig:50")).selector.range_from);
    const range = (try parsePathSelector("src/a.zig:50-60")).selector.range_between;
    try std.testing.expectEqual(@as(u32, 50), range.start);
    try std.testing.expectEqual(@as(u32, 60), range.end);
    const count = (try parsePathSelector("src/a.zig:50+10")).selector.range_count;
    try std.testing.expectEqual(@as(u32, 50), count.start);
    try std.testing.expectEqual(@as(u32, 10), count.count);
}
