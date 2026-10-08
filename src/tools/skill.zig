//! The `skill` builtin tool — enables the model to read instructions for
//! specialized skills loaded into the agent's runtime.
//! Reaches the active skill set through `Tool.Env.ctx` (the executor-owned
//! runtime context).

const std = @import("std");

const common = @import("common.zig");
const skill_mod = @import("../skill.zig");
const paths = @import("../paths.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.skill_tool);

pub const tool: common.Tool = .{
    .name = "skill",
    .description = @embedFile("../prompts/tools/skill.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "name",
                .kind = .string,
                .description = "The name of the skill to load and read instructions for (e.g. 'tigerstyle', 'how', 'write-lua-plugin').",
                .required = true,
            },
            .{ .name = "resource", .kind = .string, .description = "Optional relative resource path inside this skill, e.g. references/review-rubric.md. Omit to load the skill instructions.", .required = false },
        },
    },
    .run = runTool,
    .display = display,
};

pub const Args = struct {
    name: []u8,
    resource: ?[]u8 = null,

    pub fn deinit(self: *Args, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.resource) |resource| gpa.free(resource);
        self.* = undefined;
    }
};

const JsonArgs = struct {
    name: ?[]const u8 = null,
    resource: ?[]const u8 = null,
};

pub const ParseError = error{ InvalidArguments, OutOfMemory };

pub fn parseArgs(gpa: std.mem.Allocator, arguments: []const u8) ParseError!Args {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArguments,
    };
    defer parsed.deinit();

    const raw_name = parsed.value.name orelse return error.InvalidArguments;
    const trimmed = std.mem.trim(u8, raw_name, " \t\r\n$");
    if (trimmed.len == 0) return error.InvalidArguments;

    const owned_name = try gpa.dupe(u8, trimmed);
    errdefer gpa.free(owned_name);
    const resource = if (parsed.value.resource) |value| blk: {
        if (value.len == 0) return error.InvalidArguments;
        break :blk try gpa.dupe(u8, value);
    } else null;
    return .{ .name = owned_name, .resource = resource };
}

const resource_bytes_max = 256 * 1024;

/// Read the verified file handle, so a path replacement after checking cannot
/// redirect the read. General file tools retain workspace confinement.
fn readResource(gpa: std.mem.Allocator, io: std.Io, skill: *const skill_mod.Skill, relative: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(relative)) return error.PathTraversal;
    for (relative) |byte| if (byte < 0x20 or byte == ':' or byte == '\\') return error.InvalidPath;
    var segments = std.mem.splitScalar(u8, relative, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return error.PathTraversal;
    }
    var root = try std.Io.Dir.cwd().openDir(io, skill.base_dir, .{});
    defer root.close(io);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try root.realPath(io, &root_buf);
    // Reject streams before opening: a FIFO open can wait forever for a writer.
    const path_stat = try root.statFile(io, relative, .{ .follow_symlinks = true });
    if (path_stat.kind != .file) return error.NotRegularFile;
    const file = try root.openFile(io, relative, .{ .mode = .read_only, .resolve_beneath = true });
    defer file.close(io);
    const file_stat = try file.stat(io);
    if (file_stat.kind != .file) return error.NotRegularFile;
    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_len = try file.realPath(io, &file_buf);
    const file_path = file_buf[0..file_len];
    const parent = root_buf[0..root_len];
    if (file_path.len <= parent.len or !paths.pathsEqual(file_path[0..parent.len], parent)) return error.PathTraversal;
    if (file_path[parent.len] != '/' and file_path[parent.len] != '\\') return error.PathTraversal;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const body = try reader.interface.allocRemaining(gpa, .limited(resource_bytes_max));
    errdefer gpa.free(body);
    if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidUtf8;
    return body;
}

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
    env: common.Env,
) common.Error!common.Output {
    _ = cwd;
    _ = env.userdata;

    const skills = env.ctx.skills;
    if (skills.len == 0) return common.failFmt(gpa, 1, "No skills loaded in active runtime.\n", .{});

    var args = parseArgs(gpa, arguments) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => return common.failFmt(gpa, 2, "Invalid arguments: 'name' is required (e.g. {{\"name\":\"tigerstyle\"}}).\n", .{}),
    };
    defer args.deinit(gpa);

    if (skill_mod.find(skills, args.name)) |skill| {
        const stdout = if (args.resource) |resource|
            readResource(gpa, io, skill, resource) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return common.failFmt(gpa, 1, "Could not read skill '{s}' resource '{s}': {s}\n", .{ args.name, resource, @errorName(err) });
            }
        else
            try gpa.dupe(u8, skill.body);
        errdefer gpa.free(stdout);
        const stderr = try gpa.alloc(u8, 0);
        return .{
            .stdout = stdout,
            .stderr = stderr,
            .code = 0,
        };
    }

    var available_buf: std.ArrayList(u8) = .empty;
    defer available_buf.deinit(gpa);
    var count: usize = 0;
    for (skills) |s| {
        if (!s.disable_model_invocation) {
            try available_buf.appendSlice(gpa, "  - ");
            try available_buf.appendSlice(gpa, s.name);
            try available_buf.append(gpa, '\n');
            count += 1;
        }
    }

    if (count == 0) {
        return common.failFmt(gpa, 1, "Skill '{s}' not found (no available skills loaded).\n", .{args.name});
    }
    return common.failFmt(gpa, 1, "Skill '{s}' not found.\nAvailable skills:\n{s}", .{ args.name, available_buf.items });
}

pub fn display(
    gpa: std.mem.Allocator,
    arguments: []const u8,
    env: common.Env,
) std.mem.Allocator.Error!common.ToolDisplay {
    _ = env;
    const JsonArgsDisplay = struct {
        name: ?[]const u8 = null,
        resource: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(JsonArgsDisplay, gpa, arguments, .{ .ignore_unknown_fields = false }) catch return .{
        .label = try gpa.dupe(u8, "skill"),
    };
    defer parsed.deinit();

    const target_name = parsed.value.name orelse "skill";
    const trimmed = std.mem.trim(u8, target_name, " \t\r\n$");
    const display_name = if (trimmed.len > 0) trimmed else "skill";

    const label = try std.fmt.allocPrint(gpa, "Read {s} skill", .{display_name});
    errdefer gpa.free(label);
    const expanded_label = if (parsed.value.resource) |resource|
        try std.fmt.allocPrint(gpa, "skill: {s} resource: {s}", .{ display_name, resource })
    else
        try std.fmt.allocPrint(gpa, "skill: {s}", .{display_name});

    return .{
        .label = label,
        .expanded_label = expanded_label,
    };
}

test "skill tool parseArgs accepts standard name parameter" {
    const gpa = std.testing.allocator;
    var args = try parseArgs(gpa, "{\"name\":\"tigerstyle\"}");
    defer args.deinit(gpa);
    try std.testing.expectEqualStrings("tigerstyle", args.name);
}

test "skill resource reads a registered root and rejects paths outside it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "references");
    try tmp.dir.writeFile(io, .{ .sub_path = "references/rubric.md", .data = "Review rubric" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const source: skill_mod.Skill = .{
        .name = @constCast("review"),
        .description = @constCast(""),
        .path = @constCast(""),
        .base_dir = root_buf[0..root_len],
        .body = @constCast("Instructions"),
    };
    const text = try readResource(gpa, io, &source, "references/rubric.md");
    defer gpa.free(text);
    try std.testing.expectEqualStrings("Review rubric", text);
    try std.testing.expectError(error.PathTraversal, readResource(gpa, io, &source, "../outside"));
    try std.testing.expectError(error.PathTraversal, readResource(gpa, io, &source, root_buf[0..root_len]));
    try std.testing.expectError(error.InvalidPath, readResource(gpa, io, &source, "C:\\outside"));

    var skills = [_]skill_mod.Skill{source};
    var ctx: common.ToolContext = .{ .skills = &skills };
    var output = try runTool(gpa, io, "/unrelated/workspace", "{\"name\":\"review\",\"resource\":\"references/rubric.md\"}", .{ .ctx = &ctx });
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expectEqualStrings("Review rubric", output.stdout);
}

test "skill resource rejects symlinks escaping the registered directory" {
    if (@import("../os.zig").is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "skill");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.md", .data = "private" });
    try tmp.dir.symLink(io, "../outside.md", "skill/escape.md", .{});
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir = try tmp.dir.openDir(io, "skill", .{});
    defer dir.close(io);
    const root_len = try dir.realPath(io, &root_buf);
    const source: skill_mod.Skill = .{
        .name = @constCast("review"),
        .description = @constCast(""),
        .path = @constCast(""),
        .base_dir = root_buf[0..root_len],
        .body = @constCast("Instructions"),
    };
    const result = readResource(gpa, io, &source, "escape.md");
    if (result) |body| {
        gpa.free(body);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expect(err == error.PathTraversal or err == error.AccessDenied);
    }
}

test "skill resource rejects a FIFO without waiting for a writer" {
    if (@import("../os.zig").is_windows) return error.SkipZigTest;
    const libc = struct {
        extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;
    };
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const fifo_path = try std.fmt.allocPrintSentinel(gpa, "{s}/stream", .{root_buf[0..root_len]}, 0);
    defer gpa.free(fifo_path);
    try std.testing.expectEqual(@as(c_int, 0), libc.mkfifo(fifo_path, 0o600));
    const source: skill_mod.Skill = .{
        .name = @constCast("review"),
        .description = @constCast(""),
        .path = @constCast(""),
        .base_dir = root_buf[0..root_len],
        .body = @constCast("Instructions"),
    };
    try std.testing.expectError(error.NotRegularFile, readResource(gpa, io, &source, "stream"));
    try tmp.dir.createDirPath(io, "directory");
    try std.testing.expectError(error.NotRegularFile, readResource(gpa, io, &source, "directory"));
}

test "skill tool parseArgs strips leading dollar and rejects alias fields" {
    const gpa = std.testing.allocator;
    var args = try parseArgs(gpa, "{\"name\":\"$how\"}");
    defer args.deinit(gpa);
    try std.testing.expectEqualStrings("how", args.name);
    try std.testing.expectError(error.InvalidArguments, parseArgs(gpa, "{\"skill\":\"how\"}"));
    try std.testing.expectError(error.InvalidArguments, parseArgs(gpa, "{\"command\":\"how\"}"));
}

test "skill tool parseArgs rejects empty or missing name" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidArguments, parseArgs(gpa, "{}"));
    try std.testing.expectError(error.InvalidArguments, parseArgs(gpa, "{\"name\":\"   \"}"));
}

test "skill tool loads cached skill body when found" {
    const gpa = std.testing.allocator;
    var skills = [_]skill_mod.Skill{
        .{
            .name = try gpa.dupe(u8, "tigerstyle"),
            .description = try gpa.dupe(u8, "Code style"),
            .path = try gpa.dupe(u8, "/path/SKILL.md"),
            .base_dir = try gpa.dupe(u8, "/path"),
            .body = try gpa.dupe(u8, "# Tigerstyle Guidelines\nWrite clean Zig."),
            .disable_model_invocation = false,
        },
    };
    defer {
        for (&skills) |*s| s.deinit(gpa);
    }
    var ctx: common.ToolContext = .{ .skills = &skills };

    var output = try runTool(gpa, undefined, ".", "{\"name\":\"tigerstyle\"}", .{ .ctx = &ctx });
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expectEqualStrings("# Tigerstyle Guidelines\nWrite clean Zig.", output.stdout);
    try std.testing.expectEqualStrings("", output.stderr);
}

test "skill tool returns diagnostic error when skill not found" {
    const gpa = std.testing.allocator;
    var skills = [_]skill_mod.Skill{
        .{
            .name = try gpa.dupe(u8, "tigerstyle"),
            .description = try gpa.dupe(u8, "Code style"),
            .path = try gpa.dupe(u8, "/path/SKILL.md"),
            .base_dir = try gpa.dupe(u8, "/path"),
            .body = try gpa.dupe(u8, "body"),
            .disable_model_invocation = false,
        },
    };
    defer {
        for (&skills) |*s| s.deinit(gpa);
    }
    var ctx: common.ToolContext = .{ .skills = &skills };

    var output = try runTool(gpa, undefined, ".", "{\"name\":\"nonexistent\"}", .{ .ctx = &ctx });
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 1), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "Skill 'nonexistent' not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "tigerstyle") != null);
}

test "skill tool display formats label and expanded label" {
    const gpa = std.testing.allocator;
    var disp = try display(gpa, "{\"name\":\"tigerstyle\"}", undefined);
    defer disp.deinit(gpa);

    try std.testing.expectEqualStrings("Read tigerstyle skill", disp.label);
    try std.testing.expectEqualStrings("skill: tigerstyle", disp.expanded_label.?);
}
