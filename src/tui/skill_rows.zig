//! UI-owned activation rows: safe while a lane worker owns the agent ledger.
const std = @import("std");
const Transcript = @import("../transcript.zig").Transcript;

pub fn appendOnce(gpa: std.mem.Allocator, transcript: *Transcript, name: []const u8) !void {
    var buffer: [128]u8 = undefined;
    const title = try std.fmt.bufPrint(&buffer, "[SKILL] {s}", .{name});
    for (transcript.messages.items) |message| {
        if (message == .skill and std.ascii.eqlIgnoreCase(message.skill.title, title)) return;
    }
    _ = try transcript.append(gpa, .skill, title, "");
}

test "skill context transcript rows deduplicate case-insensitively and reset with conversation" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);
    try appendOnce(gpa, &transcript, "how");
    try appendOnce(gpa, &transcript, "HOW");
    try std.testing.expectEqual(@as(usize, 1), transcript.messages.items.len);
    transcript.deinit(gpa);
    transcript = .{};
    try appendOnce(gpa, &transcript, "how");
    try std.testing.expectEqual(@as(usize, 1), transcript.messages.items.len);
}
