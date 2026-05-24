const std = @import("std");
const common = @import("common.zig");
const apply_mod = @import("hashline/apply.zig");
const parse_mod = @import("hashline/parse.zig");
const render_diff = @import("hashline/render_diff.zig");

const assert = std.debug.assert;

const max_file_bytes: usize = 16 * 1024 * 1024;

pub const tool: common.Tool = .{
    .name = "edit_file",
    .description = @embedFile("../prompts/tools/edit_file.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "input",
                .kind = .string,
                .description = "Hashline patch document only, not an explanation. Must contain at least one @@ PATH header, followed by hashline operations using anchors from read.",
                .required = true,
            },
        },
    },
    .run = runTool,
    .displayLabel = displayLabel,
};

/// Display label for edit_file. Parses the patch document's `@@ PATH`
/// headers to surface the affected path(s) rather than the full patch.
fn displayLabel(gpa: std.mem.Allocator, args: []const u8) std.mem.Allocator.Error![]u8 {
    const input = common.extractStringField(gpa, args, "input", "") catch return error.OutOfMemory;
    defer gpa.free(input);
    if (input.len == 0) return gpa.dupe(u8, "edit_file");
    return labelFromPatch(gpa, input);
}

fn labelFromPatch(gpa: std.mem.Allocator, patch: []const u8) std.mem.Allocator.Error![]u8 {
    var first_path: ?[]const u8 = null;
    var extra_count: u32 = 0;
    var iter = std.mem.splitScalar(u8, patch, '\n');
    while (iter.next()) |raw_line| {
        const line = trimTrailingCR(raw_line);
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "@@")) continue;
        const path = std.mem.trim(u8, trimmed[2..], " \t");
        if (path.len == 0) continue;
        if (first_path == null) {
            first_path = path;
            continue;
        }
        extra_count += 1;
    }
    const path = first_path orelse return gpa.dupe(u8, "edit_file");
    if (extra_count == 0) return std.fmt.allocPrint(gpa, "edit_file {s}", .{path});
    return std.fmt.allocPrint(gpa, "edit_file {s} (+{d} more)", .{ path, extra_count });
}

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, arguments, .{}) catch {
        return common.fail(gpa, "edit_file: invalid JSON arguments\n", 2);
    };
    defer parsed.deinit();

    const input = parsed.value.object.get("input") orelse return common.fail(gpa, "edit_file: missing input\n", 2);
    if (input != .string) return common.fail(gpa, "edit_file: input must be a string\n", 2);
    return runPatchDocument(gpa, io, cwd, input.string);
}

const Section = struct {
    path: []const u8,
    diff: []u8,

    fn deinit(self: *Section, gpa: std.mem.Allocator) void {
        gpa.free(self.diff);
        self.* = undefined;
    }
};

fn runPatchDocument(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, input: []const u8) common.Error!common.Output {
    var sections = parseSections(gpa, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return common.failFmt(gpa, 2, "edit_file: invalid patch document: {s}\n", .{@errorName(err)}),
    };
    defer {
        for (sections.items) |*section| section.deinit(gpa);
        sections.deinit(gpa);
    }
    if (sections.items.len == 0) return common.fail(gpa, "edit_file: patch document must include @@ PATH\n", 2);

    var stdout_buffer: std.ArrayList(u8) = .empty;
    errdefer stdout_buffer.deinit(gpa);
    var stderr_buffer: std.ArrayList(u8) = .empty;
    errdefer stderr_buffer.deinit(gpa);
    var display_buffer: std.ArrayList(u8) = .empty;
    errdefer display_buffer.deinit(gpa);
    var final_code: u8 = 0;
    const multiple_sections = sections.items.len > 1;

    for (sections.items) |section| {
        var output = try runSingle(gpa, io, cwd, section.path, section.diff);
        defer output.deinit(gpa);
        try stdout_buffer.appendSlice(gpa, output.stdout);
        try stderr_buffer.appendSlice(gpa, output.stderr);
        if (output.display) |display| {
            try appendSectionDisplay(gpa, &display_buffer, section.path, display, multiple_sections);
        }
        if (output.code != 0) final_code = output.code;
        if (output.code != 0) break;
    }

    return finalizeDocument(gpa, &stdout_buffer, &stderr_buffer, &display_buffer, final_code);
}

fn appendSectionDisplay(
    gpa: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    path: []const u8,
    display: []const u8,
    include_header: bool,
) !void {
    assert(display.len > 0);
    if (buffer.items.len > 0) try buffer.append(gpa, '\n');
    if (include_header) try buffer.print(gpa, "── {s} ──\n", .{path});
    try buffer.appendSlice(gpa, display);
    if (buffer.items[buffer.items.len - 1] != '\n') try buffer.append(gpa, '\n');
}

fn finalizeDocument(
    gpa: std.mem.Allocator,
    stdout_buffer: *std.ArrayList(u8),
    stderr_buffer: *std.ArrayList(u8),
    display_buffer: *std.ArrayList(u8),
    code: u8,
) !common.Output {
    const display: ?[]u8 = blk: {
        if (display_buffer.items.len == 0) {
            display_buffer.deinit(gpa);
            break :blk null;
        }
        break :blk try display_buffer.toOwnedSlice(gpa);
    };
    return .{
        .stdout = try stdout_buffer.toOwnedSlice(gpa),
        .stderr = try stderr_buffer.toOwnedSlice(gpa),
        .code = code,
        .display = display,
    };
}

const SectionParseError = error{MissingHeader} || std.mem.Allocator.Error;

fn parseSections(gpa: std.mem.Allocator, input: []const u8) SectionParseError!std.ArrayList(Section) {
    var sections: std.ArrayList(Section) = .empty;
    errdefer {
        for (sections.items) |*section| section.deinit(gpa);
        sections.deinit(gpa);
    }

    var current_path: ?[]const u8 = null;
    var current_diff: std.ArrayList(u8) = .empty;
    errdefer current_diff.deinit(gpa);

    var iter = std.mem.splitScalar(u8, input, '\n');
    while (iter.next()) |raw_line| {
        const line = trimTrailingCR(raw_line);
        const control_line = std.mem.trimStart(u8, line, " \t");
        if (isEnvelopeLine(control_line)) continue;
        if (parseHeader(control_line)) |path| {
            if (current_path) |existing_path| {
                try sections.append(gpa, .{ .path = existing_path, .diff = try current_diff.toOwnedSlice(gpa) });
                current_diff = .empty;
            }
            current_path = path;
            continue;
        }
        if (current_path == null) {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            return SectionParseError.MissingHeader;
        }
        try current_diff.appendSlice(gpa, raw_line);
        try current_diff.append(gpa, '\n');
    }

    if (current_path) |path| {
        try sections.append(gpa, .{ .path = path, .diff = try current_diff.toOwnedSlice(gpa) });
        current_diff = .empty;
    }
    return sections;
}

fn parseHeader(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "@@")) return null;
    const path = std.mem.trim(u8, line[2..], " \t");
    if (path.len == 0) return null;
    return path;
}

fn isEnvelopeLine(line: []const u8) bool {
    if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "*** Begin Patch")) return true;
    if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "*** End Patch")) return true;
    return false;
}

fn trimTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn runSingle(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, path: []const u8, stdin: []const u8) common.Error!common.Output {
    const absolute = common.joinPath(gpa, cwd, path) catch |err| return common.mapAllocError(err);
    defer gpa.free(absolute);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const edits = parse_mod.parse(arena_state.allocator(), stdin) catch |err| {
        return common.failFmt(gpa, 2, "edit_file: invalid patch: {s}\n", .{@errorName(err)});
    };

    const original = common.readFileBytes(gpa, io, absolute, max_file_bytes) catch |err| {
        return common.failFmt(gpa, 1, "edit_file: cannot read {s}: {s}\n", .{ path, @errorName(err) });
    };
    defer gpa.free(original);

    const outcome = apply_mod.apply(gpa, original, edits) catch |err| {
        return common.failFmt(gpa, 1, "edit_file: apply failed: {s}\n", .{@errorName(err)});
    };
    return finalize(gpa, io, path, absolute, outcome, original, edits);
}

fn finalize(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    absolute: []const u8,
    outcome: apply_mod.Outcome,
    original: []const u8,
    edits: []const parse_mod.Edit,
) common.Error!common.Output {
    switch (outcome) {
        .rejected => |mismatches| {
            defer gpa.free(mismatches);
            return formatRejection(gpa, path, mismatches);
        },
        .applied => |applied| {
            defer gpa.free(applied.content);
            writeBack(io, absolute, applied.content) catch |err| {
                return common.failFmt(gpa, 1, "edit_file: write to {s} failed: {s}\n", .{ path, @errorName(err) });
            };
            return buildAppliedOutput(gpa, path, applied.first_changed_line, original, edits);
        },
    }
}

fn buildAppliedOutput(
    gpa: std.mem.Allocator,
    path: []const u8,
    first_changed_line: ?u32,
    original: []const u8,
    edits: []const parse_mod.Edit,
) common.Error!common.Output {
    assert(edits.len > 0);
    const first = first_changed_line orelse 0;
    const message = std.fmt.allocPrint(
        gpa,
        "Edit applied to {s} (first changed line: {d}).\n",
        .{ path, first },
    ) catch |err| return common.mapAllocError(err);
    errdefer gpa.free(message);
    const display = render_diff.render(gpa, original, edits) catch |err| return common.mapAllocError(err);
    return common.okWithDisplay(gpa, message, display);
}

fn formatRejection(
    gpa: std.mem.Allocator,
    path: []const u8,
    mismatches: []const apply_mod.Mismatch,
) common.Error!common.Output {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    try buffer.print(gpa, "edit_file: {s} has changed since the last read; re-read and retry. Mismatches:\n", .{path});
    for (mismatches) |m| {
        try buffer.print(gpa, "  line {d}: expected {s}, got {s}\n", .{ m.line, &m.expected, &m.actual });
    }
    return .{
        .stdout = try gpa.alloc(u8, 0),
        .stderr = try buffer.toOwnedSlice(gpa),
        .code = 1,
    };
}

fn writeBack(io: std.Io, absolute: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, absolute, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

test "edit_file requires an input document" {
    var output = try runTool(std.testing.allocator, std.testing.io, ".", "{}");
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "missing input") != null);
}
