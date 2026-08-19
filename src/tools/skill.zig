//! The `skill` builtin tool — enables the model to read instructions for
//! specialized skills loaded into the agent's runtime.
//! Reaches the active skill set through a scoped thread-local slot (`skills_slot`)
//! bound in `ExecutorService.produceOutput`.

const std = @import("std");

const common = @import("common.zig");
const skill_mod = @import("../skill.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.skill_tool);

pub threadlocal var skills_slot: ?[]const skill_mod.Skill = null;

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
        },
    },
    .run = runTool,
    .display = display,
};

pub const Args = struct {
    name: []u8,

    pub fn deinit(self: *Args, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        self.* = undefined;
    }
};

const JsonArgs = struct {
    name: ?[]const u8 = null,
    skill: ?[]const u8 = null,
    command: ?[]const u8 = null,
};

pub const ParseError = error{ InvalidArguments, OutOfMemory };

pub fn parseArgs(gpa: std.mem.Allocator, arguments: []const u8) ParseError!Args {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArguments,
    };
    defer parsed.deinit();

    const raw_name = parsed.value.name orelse parsed.value.skill orelse parsed.value.command orelse return error.InvalidArguments;
    const trimmed = std.mem.trim(u8, raw_name, " \t\r\n$");
    if (trimmed.len == 0) return error.InvalidArguments;

    const owned_name = try gpa.dupe(u8, trimmed);
    return .{ .name = owned_name };
}

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
    userdata: *anyopaque,
) common.Error!common.Output {
    _ = io;
    _ = cwd;
    _ = userdata;

    const skills = skills_slot orelse return common.failFmt(gpa, 1, "No skills loaded in active runtime.\n", .{});

    var args = parseArgs(gpa, arguments) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => return common.failFmt(gpa, 2, "Invalid arguments: 'name' is required (e.g. {{\"name\":\"tigerstyle\"}}).\n", .{}),
    };
    defer args.deinit(gpa);

    if (skill_mod.find(skills, args.name)) |skill| {
        const stdout = try gpa.dupe(u8, skill.body);
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
    userdata: *anyopaque,
) std.mem.Allocator.Error!common.ToolDisplay {
    _ = userdata;
    const JsonArgsDisplay = struct {
        name: ?[]const u8 = null,
        skill: ?[]const u8 = null,
        command: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(JsonArgsDisplay, gpa, arguments, .{ .ignore_unknown_fields = true }) catch return .{
        .label = try gpa.dupe(u8, "skill"),
    };
    defer parsed.deinit();

    const target_name = parsed.value.name orelse parsed.value.skill orelse parsed.value.command orelse "skill";
    const trimmed = std.mem.trim(u8, target_name, " \t\r\n$");
    const display_name = if (trimmed.len > 0) trimmed else "skill";

    const label = try std.fmt.allocPrint(gpa, "Read {s} skill", .{display_name});
    errdefer gpa.free(label);
    const expanded_label = try std.fmt.allocPrint(gpa, "skill: {s}", .{display_name});

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

test "skill tool parseArgs accepts alias fields and strips leading dollar" {
    const gpa = std.testing.allocator;
    var args1 = try parseArgs(gpa, "{\"skill\":\"$how\"}");
    defer args1.deinit(gpa);
    try std.testing.expectEqualStrings("how", args1.name);

    var args2 = try parseArgs(gpa, "{\"command\":\"write-lua-plugin\"}");
    defer args2.deinit(gpa);
    try std.testing.expectEqualStrings("write-lua-plugin", args2.name);
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

    const prev_slot = skills_slot;
    skills_slot = &skills;
    defer skills_slot = prev_slot;

    var output = try runTool(gpa, undefined, ".", "{\"name\":\"tigerstyle\"}", undefined);
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

    const prev_slot = skills_slot;
    skills_slot = &skills;
    defer skills_slot = prev_slot;

    var output = try runTool(gpa, undefined, ".", "{\"name\":\"nonexistent\"}", undefined);
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
