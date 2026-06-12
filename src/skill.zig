//! Project skill discovery, prompt formatting, and explicit invocation expansion.
const std = @import("std");

const assert = std.debug.assert;

pub const Skill = struct {
    name: []u8,
    description: []u8,
    path: []u8,
    base_dir: []u8,
    disable_model_invocation: bool = false,

    pub fn deinit(self: *Skill, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.description);
        gpa.free(self.path);
        gpa.free(self.base_dir);
        self.* = undefined;
    }
};

pub fn loadProject(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]Skill {
    assert(cwd.len > 0);
    const root = try std.fs.path.join(gpa, &.{ cwd, ".agents", "skills" });
    defer gpa.free(root);

    var skills: std.ArrayList(Skill) = .empty;
    errdefer {
        for (skills.items) |*skill| skill.deinit(gpa);
        skills.deinit(gpa);
    }
    try loadFromDir(gpa, io, root, true, &skills);
    return skills.toOwnedSlice(gpa);
}

pub fn deinitAll(gpa: std.mem.Allocator, skills: []Skill) void {
    for (skills) |*skill| skill.deinit(gpa);
    gpa.free(skills);
}

pub fn formatForPrompt(gpa: std.mem.Allocator, skills: []const Skill) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    var visible: u32 = 0;
    for (skills) |skill| {
        if (!skill.disable_model_invocation) visible += 1;
    }
    if (visible == 0) return out.toOwnedSlice();

    try out.writer.writeAll("\n\nThe following skills provide specialized instructions for specific tasks.\n");
    try out.writer.writeAll("Use bash to load a skill's file when the task matches its description.\n");
    try out.writer.writeAll("When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.\n\n");
    try out.writer.writeAll("<available_skills>\n");
    for (skills) |skill| {
        if (skill.disable_model_invocation) continue;
        try out.writer.writeAll("  <skill>\n");
        try writeXmlTag(&out.writer, "name", skill.name, 4);
        try writeXmlTag(&out.writer, "description", skill.description, 4);
        try writeXmlTag(&out.writer, "location", skill.path, 4);
        try out.writer.writeAll("  </skill>\n");
    }
    try out.writer.writeAll("</available_skills>");
    return out.toOwnedSlice();
}

pub fn activeQuery(before_cursor: []const u8) ?struct { start: usize, query: []const u8 } {
    var index: usize = before_cursor.len;
    while (index > 0) : (index -= 1) {
        const byte = before_cursor[index - 1];
        if (isBoundary(byte)) return null;
        if (byte == '$') {
            const start = index - 1;
            if (start == 0 or isBoundary(before_cursor[start - 1])) {
                return .{ .start = start, .query = before_cursor[start + 1 ..] };
            }
            return null;
        }
    }
    return null;
}

pub fn filterNames(gpa: std.mem.Allocator, skills: []const Skill, query: []const u8) ![][]const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |item| gpa.free(item);
        results.deinit(gpa);
    }
    const max_results = 50;
    for (skills) |skill| {
        if (results.items.len >= max_results) break;
        if (query.len > 0) {
            if (std.ascii.indexOfIgnoreCase(skill.name, query) == null) continue;
        }
        try results.append(gpa, try gpa.dupe(u8, skill.name));
    }
    return results.toOwnedSlice(gpa);
}

pub fn promptPrefix(gpa: std.mem.Allocator, io: std.Io, skills: []const Skill, prompt: []const u8) ![]u8 {
    const names = try collectInvocations(gpa, skills, prompt);
    defer gpa.free(names);
    if (names.len == 0) return gpa.dupe(u8, "");

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (names) |name| {
        const skill = find(skills, name) orelse continue;
        try appendSkillBlock(gpa, io, &out.writer, skill);
        try out.writer.writeAll("\n\n");
    }
    return out.toOwnedSlice();
}

pub fn expandPrompt(gpa: std.mem.Allocator, io: std.Io, skills: []const Skill, prompt: []const u8) ![]u8 {
    const prefix = try promptPrefix(gpa, io, skills, prompt);
    defer gpa.free(prefix);
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, prompt });
}

pub fn collectInvocations(gpa: std.mem.Allocator, skills: []const Skill, prompt: []const u8) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);

    var index: usize = 0;
    while (index < prompt.len) {
        const at_boundary = index == 0 or isBoundary(prompt[index - 1]);
        if (prompt[index] == '$' and at_boundary) {
            var end = index + 1;
            while (end < prompt.len and !isBoundary(prompt[end])) end += 1;
            const name = trimTrailingPunctuation(prompt[index + 1 .. end]);
            if (name.len > 0 and find(skills, name) != null and !contains(names.items, name)) {
                try names.append(gpa, name);
            }
            index = end;
        } else {
            index += 1;
        }
    }
    return names.toOwnedSlice(gpa);
}

pub fn find(skills: []const Skill, name: []const u8) ?*const Skill {
    for (skills) |*skill| {
        if (std.mem.eql(u8, skill.name, name)) return skill;
    }
    return null;
}

fn loadFromDir(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, include_root_files: bool, skills: *std.ArrayList(Skill)) !void {
    var dir = std.Io.Dir.openDir(.cwd(), io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);

    const skill_path = try std.fs.path.join(gpa, &.{ dir_path, "SKILL.md" });
    defer gpa.free(skill_path);
    if (loadOne(gpa, io, skill_path)) |skill| {
        try skills.append(gpa, skill);
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        const child = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        defer gpa.free(child);
        switch (entry.kind) {
            .directory => try loadFromDir(gpa, io, child, false, skills),
            .file => if (include_root_files and std.mem.endsWith(u8, entry.name, ".md")) {
                if (loadOne(gpa, io, child)) |skill| {
                    try skills.append(gpa, skill);
                } else |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                }
            },
            else => {},
        }
    }
}

fn loadOne(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Skill {
    const raw = try std.Io.Dir.readFileAllocOptions(.cwd(), io, path, gpa, .limited(256 * 1024), .of(u8), 0);
    defer gpa.free(raw);
    const frontmatter = parseFrontmatter(raw);
    const description = frontmatterValue(frontmatter, "description") orelse return error.MissingDescription;
    const name_value = frontmatterValue(frontmatter, "name") orelse std.fs.path.basename(std.fs.path.dirname(path) orelse path);
    const base_dir = std.fs.path.dirname(path) orelse ".";
    return .{
        .name = try gpa.dupe(u8, name_value),
        .description = try gpa.dupe(u8, description),
        .path = try gpa.dupe(u8, path),
        .base_dir = try gpa.dupe(u8, base_dir),
        .disable_model_invocation = frontmatterBool(frontmatter, "disable-model-invocation"),
    };
}

/// Byte length of the opening `---` fence line, tolerating both LF and CRLF
/// line endings (SKILL.md authored on Windows ships as CRLF), or null when the
/// input does not open with a frontmatter fence.
fn frontmatterOpenLen(raw: []const u8) ?u32 {
    if (std.mem.startsWith(u8, raw, "---\r\n")) return 5;
    if (std.mem.startsWith(u8, raw, "---\n")) return 4;
    return null;
}

fn parseFrontmatter(raw: []const u8) []const u8 {
    const open_len = frontmatterOpenLen(raw) orelse return "";
    const rest = raw[open_len..];
    // `\n---` matches the closing fence under both LF and CRLF; any trailing
    // `\r` on a value line is stripped by `frontmatterValue`.
    const end = std.mem.indexOf(u8, rest, "\n---") orelse return "";
    return rest[0..end];
}

fn frontmatterValue(frontmatter: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const found = std.mem.trim(u8, line[0..colon], " \t\r");
        if (!std.mem.eql(u8, found, key)) continue;
        return stripQuotes(std.mem.trim(u8, line[colon + 1 ..], " \t\r"));
    }
    return null;
}

fn frontmatterBool(frontmatter: []const u8, key: []const u8) bool {
    const value = frontmatterValue(frontmatter, key) orelse return false;
    return std.ascii.eqlIgnoreCase(value, "true");
}

fn stripQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
    if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') return value[1 .. value.len - 1];
    return value;
}

fn appendSkillBlock(gpa: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, skill: *const Skill) !void {
    const raw = try std.Io.Dir.readFileAllocOptions(.cwd(), io, skill.path, gpa, .limited(256 * 1024), .of(u8), 0);
    defer gpa.free(raw);
    const body = stripFrontmatter(raw);
    try writer.print("<skill name=\"{s}\" location=\"{s}\">\n", .{ skill.name, skill.path });
    try writer.print("References are relative to {s}.\n\n", .{skill.base_dir});
    try writer.writeAll(body);
    try writer.writeAll("\n</skill>");
}

fn stripFrontmatter(raw: []const u8) []const u8 {
    const open_len = frontmatterOpenLen(raw) orelse return raw;
    const rest = raw[open_len..];
    const end = std.mem.indexOf(u8, rest, "\n---") orelse return raw;
    const after_fence = rest[end + 4 ..];
    // Drop the remainder of the closing fence line (LF or CRLF) so the body
    // starts on its own line.
    const newline = std.mem.indexOfScalar(u8, after_fence, '\n') orelse return "";
    return after_fence[newline + 1 ..];
}

test "frontmatter parses CRLF line endings" {
    const raw = "---\r\nname: demo\r\ndescription: \"a demo skill\"\r\n---\r\nbody line\r\n";
    const frontmatter = parseFrontmatter(raw);
    try std.testing.expectEqualStrings("demo", frontmatterValue(frontmatter, "name").?);
    try std.testing.expectEqualStrings("a demo skill", frontmatterValue(frontmatter, "description").?);
    try std.testing.expectEqualStrings("body line\r\n", stripFrontmatter(raw));
}

test "frontmatter parses LF line endings" {
    const raw = "---\nname: demo\ndescription: d\n---\nbody\n";
    const frontmatter = parseFrontmatter(raw);
    try std.testing.expectEqualStrings("demo", frontmatterValue(frontmatter, "name").?);
    try std.testing.expectEqualStrings("d", frontmatterValue(frontmatter, "description").?);
    try std.testing.expectEqualStrings("body\n", stripFrontmatter(raw));
}

fn writeXmlTag(writer: *std.Io.Writer, tag: []const u8, value: []const u8, spaces: u8) !void {
    var count: u8 = 0;
    while (count < spaces) : (count += 1) try writer.writeByte(' ');
    try writer.print("<{s}>", .{tag});
    try writeXmlEscaped(writer, value);
    try writer.print("</{s}>\n", .{tag});
}

fn writeXmlEscaped(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(byte),
        }
    }
}

fn isBoundary(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn trimTrailingPunctuation(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0) : (end -= 1) {
        switch (value[end - 1]) {
            '.', ',', ';', ':', '!', '?' => {},
            else => break,
        }
    }
    return value[0..end];
}

fn contains(values: []const []const u8, candidate: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

test "activeQuery detects dollar skill token" {
    const active = activeQuery("use $tiger").?;
    try std.testing.expectEqual(@as(usize, 4), active.start);
    try std.testing.expectEqualStrings("tiger", active.query);
}

test "collectInvocations finds known skills only" {
    const gpa = std.testing.allocator;
    const skills = [_]Skill{.{ .name = @constCast("how"), .description = @constCast("d"), .path = @constCast("p"), .base_dir = @constCast(".") }};
    const names = try collectInvocations(gpa, &skills, "$how and $missing");
    defer gpa.free(names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("how", names[0]);
}
