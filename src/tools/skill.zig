//! The `skill` builtin tool — enables the model to read instructions for
//! specialized skills loaded into the agent's runtime, read bundled text,
//! and execute commands from their registered directories.
//! Reaches the active skill set through `Tool.Env.ctx` (the executor-owned
//! runtime context).

const std = @import("std");

const common = @import("common.zig");
const skill_mod = @import("../skill.zig");
const paths = @import("../paths.zig");
const shell = if (@import("../os.zig").is_windows) @import("pwsh.zig") else @import("bash.zig");

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
            .{ .name = "command", .kind = .string, .description = "Shell command to run from the registered skill directory, e.g. python3 scripts/check.py. Mutually exclusive with resource. Uses the host shell and normal command safety approval.", .required = false },
            .{ .name = "timeout", .kind = .integer, .description = "Command timeout in seconds (default 30, maximum 3600). Only valid with command.", .required = false },
        },
    },
    .run = runTool,
    .display = display,
};

pub const Args = struct {
    name: []u8,
    resource: ?[]u8 = null,
    command: ?[]u8 = null,
    timeout_seconds: ?u32 = null,

    pub fn deinit(self: *Args, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.resource) |resource| gpa.free(resource);
        if (self.command) |command| gpa.free(command);
        self.* = undefined;
    }
};

const JsonArgs = struct {
    name: ?[]const u8 = null,
    resource: ?[]const u8 = null,
    command: ?[]const u8 = null,
    timeout: ?u32 = null,
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
    if (parsed.value.command != null and parsed.value.resource != null) return error.InvalidArguments;
    if (parsed.value.timeout != null and parsed.value.command == null) return error.InvalidArguments;
    if (parsed.value.command) |command| {
        if (std.mem.trim(u8, command, " \t\r\n").len == 0) return error.InvalidArguments;
        if (std.mem.indexOfScalar(u8, command, 0) != null) return error.InvalidArguments;
    }
    if (parsed.value.timeout) |timeout| {
        if (timeout == 0 or timeout > shell.Backend.exec.timeout_seconds_max) return error.InvalidArguments;
    }

    const owned_name = try gpa.dupe(u8, trimmed);
    errdefer gpa.free(owned_name);
    const resource = if (parsed.value.resource) |value| blk: {
        if (value.len == 0) return error.InvalidArguments;
        break :blk try gpa.dupe(u8, value);
    } else null;
    errdefer if (resource) |value| gpa.free(value);
    const command = if (parsed.value.command) |value| try gpa.dupe(u8, value) else null;
    return .{ .name = owned_name, .resource = resource, .command = command, .timeout_seconds = parsed.value.timeout };
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
    _ = env.userdata;

    const skills = env.ctx.skills;
    if (skills.len == 0) return common.failFmt(gpa, 1, "No skills loaded in active runtime.\n", .{});

    var args = parseArgs(gpa, arguments) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => return common.failFmt(gpa, 2, "Invalid skill arguments: name is required; resource and command are mutually exclusive; timeout requires command and must be 1–3600 seconds.\n", .{}),
    };
    defer args.deinit(gpa);

    if (skill_mod.find(skills, args.name)) |skill| {
        if (args.command) |command| {
            const root = std.Io.Dir.realPathFileAlloc(.cwd(), io, skill.base_dir, gpa) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return common.failFmt(gpa, 1, "Could not open skill '{s}' directory: {s}\n", .{ args.name, @errorName(err) });
            };
            defer gpa.free(root);
            const workspace = std.fs.path.resolve(gpa, &.{cwd}) catch return error.OutOfMemory;
            defer gpa.free(workspace);
            const shell_args = try std.json.Stringify.valueAlloc(gpa, .{
                .command = command,
                .timeout = args.timeout_seconds,
                .env = .{ .ZAY_WORKSPACE_CWD = workspace },
            }, .{});
            defer gpa.free(shell_args);
            return shell.runContainedWithCancellation(gpa, io, root, shell_args, null, env.ctx.cancel_requested);
        }
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
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = false }) catch return .{
        .label = try gpa.dupe(u8, "skill"),
    };
    defer parsed.deinit();

    const target_name = parsed.value.name orelse "skill";
    const trimmed = std.mem.trim(u8, target_name, " \t\r\n$");
    const display_name = if (trimmed.len > 0) trimmed else "skill";

    const label = try std.fmt.allocPrint(gpa, "{s} {s} skill", .{ if (parsed.value.command != null) "Run" else "Read", display_name });
    errdefer gpa.free(label);
    const expanded_label = if (parsed.value.command) |command|
        try std.fmt.allocPrint(gpa, "skill: {s} command: {s}", .{ display_name, command })
    else if (parsed.value.resource) |resource|
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

test "skill command rejects ambiguous modes and invalid timeout" {
    const gpa = std.testing.allocator;
    var args = try parseArgs(gpa, "{\"name\":\"review\",\"command\":\"python3 scripts/check.py\",\"timeout\":120}");
    defer args.deinit(gpa);
    try std.testing.expectEqualStrings("python3 scripts/check.py", args.command.?);
    try std.testing.expectEqual(@as(u32, 120), args.timeout_seconds.?);
    const invalid = [_][]const u8{
        "{\"name\":\"review\",\"command\":\" \"}",
        "{\"name\":\"review\",\"command\":\"echo\\u0000bad\"}",
        "{\"name\":\"review\",\"command\":\"echo ok\",\"resource\":\"x.md\"}",
        "{\"name\":\"review\",\"timeout\":1}",
        "{\"name\":\"review\",\"command\":\"echo ok\",\"timeout\":0}",
        "{\"name\":\"review\",\"command\":\"echo ok\",\"timeout\":3601}",
        "{\"name\":\"review\",\"command\":\"echo ok\",\"cwd\":\"/tmp\"}",
    };
    for (invalid) |json| try std.testing.expectError(error.InvalidArguments, parseArgs(gpa, json));
}

test "skill command executes a script and assets from its registered cwd" {
    const windows = @import("../os.zig").is_windows;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "skill with spaces/scripts");
    try tmp.dir.createDirPath(io, "skill with spaces/assets");
    try tmp.dir.createDirPath(io, "workspace");
    try tmp.dir.writeFile(io, .{ .sub_path = "skill with spaces/assets/value.txt", .data = "asset-content-from-skill\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = if (windows) "skill with spaces/scripts/check.ps1" else "skill with spaces/scripts/check.sh",
        .data = if (windows)
            "Get-Content assets/value.txt\nWrite-Output $env:ZAY_WORKSPACE_CWD\nWrite-Output ('argument=[' + $args[0] + ']')\n"
        else
            "cat assets/value.txt\nprintf '%s\\n' \"$ZAY_WORKSPACE_CWD\"\nprintf 'argument=[%s]\\n' \"$1\"\n",
    });
    var skill_dir = try tmp.dir.openDir(io, "skill with spaces", .{});
    defer skill_dir.close(io);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try skill_dir.realPath(io, &root_buf);
    var workspace_buf: [std.fs.max_path_bytes]u8 = undefined;
    var workspace_dir = try tmp.dir.openDir(io, "workspace", .{});
    defer workspace_dir.close(io);
    const workspace_len = try workspace_dir.realPath(io, &workspace_buf);
    const workspace = workspace_buf[0..workspace_len];
    const skills = [_]skill_mod.Skill{.{
        .name = @constCast("review"),
        .description = @constCast(""),
        .path = @constCast(""),
        .base_dir = root_buf[0..root_len],
        .body = @constCast("Instructions"),
    }};
    var ctx: common.ToolContext = .{ .skills = &skills };
    const command = if (windows) "& ./scripts/check.ps1 'argument with spaces'" else "bash scripts/check.sh 'argument with spaces'";
    const json = try std.json.Stringify.valueAlloc(gpa, .{ .name = "review", .command = command }, .{});
    defer gpa.free(json);
    var output = try runTool(gpa, io, workspace, json, .{ .ctx = &ctx });
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "asset-content-from-skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, workspace) != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "argument=[argument with spaces]") != null);
    var shown = try display(gpa, json, .{ .ctx = &ctx });
    defer shown.deinit(gpa);
    try std.testing.expectEqualStrings("Run review skill", shown.label);
    const escape_json = try std.json.Stringify.valueAlloc(gpa, .{
        .name = "review",
        .command = if (windows) "Set-Location $env:ZAY_WORKSPACE_CWD" else "cd \"$ZAY_WORKSPACE_CWD\"",
    }, .{});
    defer gpa.free(escape_json);
    var escaped = try runTool(gpa, io, workspace, escape_json, .{ .ctx = &ctx });
    defer escaped.deinit(gpa);
    try std.testing.expect(escaped.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, escaped.stdout, "escapes the workspace root") != null);

    var failed = try runTool(gpa, io, workspace, "{\"name\":\"review\",\"command\":\"exit 7\"}", .{ .ctx = &ctx });
    defer failed.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 7), failed.code);
    var timed_out = try runTool(gpa, io, workspace, if (windows)
        "{\"name\":\"review\",\"command\":\"Start-Sleep -Seconds 10\",\"timeout\":1}"
    else
        "{\"name\":\"review\",\"command\":\"sleep 10\",\"timeout\":1}", .{ .ctx = &ctx });
    defer timed_out.deinit(gpa);
    try std.testing.expect(timed_out.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, timed_out.stdout, "timed out") != null);
    var cancelled: std.atomic.Value(bool) = .init(true);
    ctx.cancel_requested = &cancelled;
    try std.testing.expectError(error.Canceled, runTool(gpa, io, workspace, json, .{ .ctx = &ctx }));
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
