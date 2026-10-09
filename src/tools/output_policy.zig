//! Shared limits for model-facing tool output and retrieval windows.

const std = @import("std");

pub const default_tool_output_cap_bytes: u32 = 8 * 1024;
pub const minimum_tool_output_cap_bytes: u32 = 4 * 1024;

/// Leave room for the retrieval header and continuation instruction when a
/// database tool reads a saved result. Four UTF-8 bytes per character is the
/// conservative upper bound for the returned body.
const read_result_metadata_reserve_bytes: u32 = 1024;

pub fn readWindowLimitChars(output_cap_bytes: u32, requested_limit: u64) u64 {
    const body_budget = output_cap_bytes -| read_result_metadata_reserve_bytes;
    const max_utf8_chars: u64 = @as(u64, body_budget) / 4;
    return @max(1, @min(@max(1, requested_limit), @max(1, max_utf8_chars)));
}

test "database result windows stay within the configured output budget" {
    try std.testing.expectEqual(@as(u64, 1_792), readWindowLimitChars(8 * 1024, 4_096));
    try std.testing.expectEqual(@as(u64, 768), readWindowLimitChars(4 * 1024, 4_096));
    try std.testing.expectEqual(@as(u64, 100), readWindowLimitChars(8 * 1024, 100));
}
