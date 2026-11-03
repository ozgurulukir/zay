//! Shared test helpers. Import from test code in any module; nothing here
//! runs in production paths.

const std = @import("std");

/// Count occurrences of `needle` in `haystack`, including matches that
/// start inside a previous match's tail (advance by one on each hit).
/// Test-only assertion helper.
pub fn countSubstring(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, idx, needle)) |pos| {
        count += 1;
        idx = pos + 1;
    }
    return count;
}

test "countSubstring counts overlapping starts and the empty-haystack edge case" {
    try std.testing.expectEqual(@as(usize, 0), countSubstring("banana", "kiwi"));
    try std.testing.expectEqual(@as(usize, 1), countSubstring("banana", "b"));
    // Overlapping starts: "aa" hits at index 0 and 1.
    try std.testing.expectEqual(@as(usize, 2), countSubstring("aaa", "aa"));
    try std.testing.expectEqual(@as(usize, 1), countSubstring("\"a\",\"a\"", ","));
    try std.testing.expectEqual(@as(usize, 2), countSubstring("a,b,c", ","));
    try std.testing.expectEqual(@as(usize, 0), countSubstring("", "x"));
}
