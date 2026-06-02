//! ASCII black-hole intro animation shown in place of the old static logo.
//!
//! The 120 frames are embedded at compile time and rendered by
//! `tui/widgets/message.zig`. Every frame is a fixed 24x80 grid of printable
//! ASCII drawn from a brightness ramp (` .~ox+=*%$@`); space is the void and
//! `.` doubles as a faint star. Because the geometry is constant we render
//! byte-by-byte through a precomputed colour table and slice grapheme bytes
//! straight out of the static frame data, so a frame costs no allocation and
//! at most `rows * cols` cell writes.
const std = @import("std");

/// Each frame is exactly this many rows/columns of single-width ASCII.
pub const rows: u16 = 24;
pub const cols: u16 = 80;

/// Total frames in the seamless loop (frame_119 -> frame_000 is continuous).
pub const frame_count: u16 = 120;

/// Target cadence (~24 fps). The animation tick carries the remainder so the
/// average frame interval matches this even when the host tick is coarser.
pub const frame_interval_ms: u32 = 42;

const frames = blk: {
    var arr: [frame_count][]const u8 = undefined;
    for (0..frame_count) |i| {
        arr[i] = @embedFile(std.fmt.comptimePrint("../assets/blackhole/frame_{d:0>3}.txt", .{i}));
    }
    break :blk arr;
};

/// Bytes for `index`, wrapping so callers never have to bound the counter.
pub fn frame(index: usize) []const u8 {
    return frames[index % frame_count];
}

const Rgb = [3]u8;

// Brightness ramp -> warm accretion-disk gradient. Dim outer fringe in deep
// red, hot inner core in near-white, with the glow (255,90,40) and accent
// (#ff6a3d) filling the mid-bright transition. ` ` is the void (no cell), so
// the table returns null for everything that isn't part of the ramp.
const color_table = blk: {
    var table = [_]?Rgb{null} ** 256;
    table['.'] = .{ 110, 96, 88 }; // stars / faintest fringe
    table['~'] = .{ 58, 10, 10 }; // #3a0a0a
    table['o'] = .{ 140, 28, 14 }; // #8c1c0e
    table['x'] = .{ 140, 28, 14 };
    table['+'] = .{ 224, 67, 26 }; // #e0431a
    table['='] = .{ 255, 90, 40 }; // glow
    table['*'] = .{ 255, 106, 61 }; // accent #ff6a3d
    table['%'] = .{ 255, 138, 61 }; // #ff8a3d
    table['$'] = .{ 255, 138, 61 };
    table['@'] = .{ 255, 226, 194 }; // #ffe2c2 hot core
    break :blk table;
};

/// Foreground colour for a ramp byte, or null for the void (space) and any
/// non-ramp byte the caller should skip.
pub fn colorAt(byte: u8) ?Rgb {
    return color_table[byte];
}

test "frame wraps around the loop" {
    try std.testing.expectEqual(frame(0).ptr, frame(frame_count).ptr);
    try std.testing.expect(frame(0).len > 0);
}

test "void and ramp colours" {
    try std.testing.expect(colorAt(' ') == null);
    try std.testing.expect(colorAt('@') != null);
}
