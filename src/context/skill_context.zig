//! Owned, conversation-scoped skill instructions. Activation is append-only;
//! reaching the cap rejects new entries rather than evicting active instructions.
const std = @import("std");

pub const SkillContext = struct {
    entries: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,

    pub const Entry = struct { name: []const u8, body: []const u8 };
    pub const Activation = enum { inserted, already_loaded };
    pub const bytes_max = 8 * 1024 * 1024;
    pub const body_bytes_max = 256 * 1024;
    pub const entries_max = 256;
    // JSON escaping can expand each input byte into six bytes.
    pub const payload_bytes_max = bytes_max * 6 + entries_max * 64;

    pub fn deinit(self: *SkillContext, gpa: std.mem.Allocator) void {
        self.clear(gpa);
        self.entries.deinit(gpa);
        self.* = .{};
    }

    pub fn clear(self: *SkillContext, gpa: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            gpa.free(entry.name);
            gpa.free(entry.body);
        }
        self.entries.clearRetainingCapacity();
        self.bytes = 0;
    }

    pub fn body(self: *const SkillContext, name: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.body;
        }
        return null;
    }

    pub fn contains(self: *const SkillContext, name: []const u8) bool {
        return self.body(name) != null;
    }

    /// Undo entries prepared for a message that was not admitted.
    pub fn rollbackTo(self: *SkillContext, gpa: std.mem.Allocator, count: usize) void {
        std.debug.assert(count <= self.entries.items.len);
        for (self.entries.items[count..]) |entry| {
            self.bytes -= entry.name.len + entry.body.len;
            gpa.free(entry.name);
            gpa.free(entry.body);
        }
        self.entries.items.len = count;
    }

    /// First activation wins, including when discovery later changes the body.
    /// All fallible work precedes admission, so failure leaves the ledger intact.
    pub fn activate(self: *SkillContext, gpa: std.mem.Allocator, name: []const u8, instructions: []const u8) !Activation {
        if (!validName(name)) return error.InvalidSkillName;
        if (self.contains(name)) return .already_loaded;
        if (instructions.len > body_bytes_max) return error.SkillBodyTooLarge;
        if (self.entries.items.len == entries_max) return error.SkillContextFull;
        const added_bytes = name.len + instructions.len;
        if (added_bytes > bytes_max - self.bytes) return error.SkillContextFull;

        const owned_name = try gpa.dupe(u8, name);
        errdefer gpa.free(owned_name);
        const owned_body = try gpa.dupe(u8, instructions);
        errdefer gpa.free(owned_body);
        try self.entries.append(gpa, .{ .name = owned_name, .body = owned_body });
        self.bytes += added_bytes;
        std.debug.assert(self.bytes <= bytes_max);
        return .inserted;
    }

    pub fn toJson(self: *const SkillContext, gpa: std.mem.Allocator) ![]u8 {
        std.debug.assert(self.bytes <= bytes_max);
        return std.json.Stringify.valueAlloc(gpa, .{ .skills = self.entries.items }, .{});
    }

    /// Parse into a temporary owner; malformed metadata never replaces live state.
    pub fn replaceFromJson(self: *SkillContext, gpa: std.mem.Allocator, payload: []const u8) !void {
        if (payload.len > payload_bytes_max) return error.SkillContextFull;
        const Payload = struct { skills: []const Entry };
        const parsed = try std.json.parseFromSlice(Payload, gpa, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var replacement: SkillContext = .{};
        errdefer replacement.deinit(gpa);
        for (parsed.value.skills) |entry| {
            const outcome = try replacement.activate(gpa, entry.name, entry.body);
            if (outcome == .already_loaded) return error.DuplicateSkill;
        }
        self.deinit(gpa);
        self.* = replacement;
    }
};

/// The notice is constant-size and independent of untrusted tool arguments.
pub const loaded_notice = "Skill already loaded. Its full instructions remain active in this conversation.";

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    var needs_segment = true;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) and byte < 128) {
            needs_segment = false;
        } else if (byte == '-' and !needs_segment) {
            needs_segment = true;
        } else return false;
    }
    return !needs_segment;
}

test "skill context owns first body and deduplicates case insensitively" {
    const gpa = std.testing.allocator;
    var ledger: SkillContext = .{};
    defer ledger.deinit(gpa);
    var instructions = [_]u8{ 'a', 'b', 'c' };
    try std.testing.expectEqual(.inserted, try ledger.activate(gpa, "how", &instructions));
    instructions[0] = 'x';
    try std.testing.expectEqual(.already_loaded, try ledger.activate(gpa, "HOW", "different"));
    try std.testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
    try std.testing.expectEqualStrings("abc", ledger.body("How").?);
    ledger.clear(gpa);
    try std.testing.expect(!ledger.contains("how"));
    try std.testing.expectEqual(@as(usize, 0), ledger.bytes);
}

test "skill context JSON preserves order and ignores unknown fields" {
    const gpa = std.testing.allocator;
    var ledger: SkillContext = .{};
    defer ledger.deinit(gpa);
    try ledger.replaceFromJson(gpa, "{\"extra\":true,\"skills\":[{\"name\":\"why\",\"body\":\"a\\nb\",\"future\":1},{\"name\":\"how\",\"body\":\"c\"}]}");
    const payload = try ledger.toJson(gpa);
    defer gpa.free(payload);
    var restored: SkillContext = .{};
    defer restored.deinit(gpa);
    try restored.replaceFromJson(gpa, payload);
    try std.testing.expectEqualStrings("why", restored.entries.items[0].name);
    try std.testing.expectEqualStrings("a\nb", restored.body("why").?);
    try std.testing.expectEqualStrings("how", restored.entries.items[1].name);
}

test "skill context invalid metadata preserves prior state" {
    const gpa = std.testing.allocator;
    var ledger: SkillContext = .{};
    defer ledger.deinit(gpa);
    _ = try ledger.activate(gpa, "how", "original");
    try std.testing.expectError(error.DuplicateSkill, ledger.replaceFromJson(gpa, "{\"skills\":[{\"name\":\"why\",\"body\":\"a\"},{\"name\":\"WHY\",\"body\":\"b\"}]}"));
    try std.testing.expectError(error.InvalidSkillName, ledger.replaceFromJson(gpa, "{\"skills\":[{\"name\":\"../bad\",\"body\":\"a\"}]}"));
    if (ledger.replaceFromJson(gpa, "{broken")) |_| return error.ExpectedError else |_| {}
    try std.testing.expectEqualStrings("original", ledger.body("how").?);
    try std.testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
}

test "skill context rejects capacity without evicting instructions" {
    const gpa = std.testing.allocator;
    var ledger: SkillContext = .{};
    defer ledger.deinit(gpa);
    const large = try gpa.alloc(u8, SkillContext.body_bytes_max);
    defer gpa.free(large);
    @memset(large, 'x');
    var name_buffer: [64]u8 = undefined;
    for (0..31) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "skill-{d}", .{index});
        _ = try ledger.activate(gpa, name, large);
    }
    try std.testing.expectError(error.SkillContextFull, ledger.activate(gpa, "overflow", large));
    try std.testing.expectEqual(@as(usize, 31), ledger.entries.items.len);
    try std.testing.expectEqualStrings(large, ledger.body("skill-0").?);
}

test "skill context activation OOM leaves no partial entry" {
    const gpa = std.testing.allocator;
    for (0..3) |fail_index| {
        var ledger: SkillContext = .{};
        defer ledger.deinit(gpa);
        var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, ledger.activate(failing.allocator(), "how", "instructions"));
        try std.testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
        try std.testing.expectEqual(@as(usize, 0), ledger.bytes);
    }
}

test "skill context metadata restoration OOM preserves existing instructions" {
    const gpa = std.testing.allocator;
    const payload = "{\"skills\":[{\"name\":\"why\",\"body\":\"replacement\"}]}";
    var saw_success = false;
    for (0..32) |fail_index| {
        var ledger: SkillContext = .{};
        defer ledger.deinit(gpa);
        _ = try ledger.activate(gpa, "how", "original");
        var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        if (ledger.replaceFromJson(failing.allocator(), payload)) |_| {
            try std.testing.expect(!ledger.contains("how"));
            try std.testing.expectEqualStrings("replacement", ledger.body("why").?);
            saw_success = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
            try std.testing.expectEqualStrings("original", ledger.body("how").?);
        }
    }
    try std.testing.expect(saw_success);
}
