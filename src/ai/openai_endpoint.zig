const std = @import("std");

pub fn v1Root(gpa: std.mem.Allocator, base_url: []const u8) ![]u8 {
    std.debug.assert(base_url.len > 0);
    const root = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, root, "/v1")) return try gpa.dupe(u8, root);
    return try std.fmt.allocPrint(gpa, "{s}/v1", .{root});
}

test "v1 root accepts already-versioned base urls" {
    const gpa = std.testing.allocator;
    const root = try v1Root(gpa, "http://localhost:11434/v1");
    defer gpa.free(root);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", root);
}

test "v1 root appends version to provider roots" {
    const gpa = std.testing.allocator;
    const root = try v1Root(gpa, "http://localhost:11434");
    defer gpa.free(root);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", root);
}
