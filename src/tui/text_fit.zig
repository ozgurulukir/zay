//! Shared width-aware text fitting for TUI widgets (issue #490).
//!
//! One place for display-width measurement and ellipsizing so widgets stop
//! re-implementing truncation with inconsistent semantics — some clips
//! silently, some reserve a full ellipsis cell, some keep the tail. Pure
//! functions over display width (vaxis gwidth, unicode method), so draw and
//! row-count paths can share them safely.

const std = @import("std");
const vaxis = @import("vaxis");

/// Display width of `text` in terminal cells (grapheme-aware, unicode
/// method). The single measurement helper every widget should call instead
/// of touching vaxis directly.
pub fn measure(text: []const u8) u16 {
    return vaxis.gwidth.gwidth(text, .unicode);
}

pub const Truncation = struct {
    text: []const u8,
    /// True when `text` was shortened (an ellipsis was appended or the tail
    /// was cut by `truncateMiddle`).
    truncated: bool,
};

/// Cut `text` to at most `max_width` cells, ending with an ellipsis when it
/// does not fit. Returns the input slice unchanged when it fits (callers with
/// per-frame arenas can pass the original through); otherwise a fresh
/// arena/gpa-owned prefix + "…" — the caller owns the buffer.
pub fn truncateEnd(alloc: std.mem.Allocator, text: []const u8, max_width: u16) !Truncation {
    if (measure(text) <= max_width) return .{ .text = text, .truncated = false };
    const ellipsis = "…";
    const keep = max_width -| measure(ellipsis);
    const cut = graphemeCut(text, keep);
    return .{ .text = try std.fmt.allocPrint(alloc, "{s}{s}", .{ cut, ellipsis }), .truncated = true };
}

/// Cut `text` to at most `max_width` cells keeping the FINAL component of a
/// path-like value visible: when a separator exists, the result is
/// `…/<tail>` where the tail is the longest suffix that fits.
pub fn truncateMiddle(alloc: std.mem.Allocator, text: []const u8, max_width: u16) !Truncation {
    if (measure(text) <= max_width) return .{ .text = text, .truncated = false };
    const separator_index = lastPathSeparator(text) orelse return truncateEnd(alloc, text, max_width);
    const tail = text[separator_index + 1 ..];
    const ellipsis = "…/";
    const budget = max_width -| measure(ellipsis);
    var keep: usize = 0;
    var used: u16 = 0;
    var iter = vaxis.unicode.graphemeIterator(tail);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(tail);
        const width = measure(bytes);
        if (used + width > budget) break;
        used += width;
        keep += bytes.len;
    }
    return .{
        .text = try std.fmt.allocPrint(alloc, "{s}{s}", .{ ellipsis, tail[0..keep] }),
        .truncated = true,
    };
}

fn lastPathSeparator(text: []const u8) ?usize {
    var i = text.len;
    while (i > 0) {
        i -= 1;
        if (text[i] == '/' or text[i] == '\\') return i;
    }
    return null;
}

/// Pad `text` with trailing spaces to exactly `width` cells (no-op when it is
/// already wider). Caller owns the result when a fresh buffer is returned.
pub fn padTo(alloc: std.mem.Allocator, text: []const u8, width: u16) ![]const u8 {
    const measured = measure(text);
    if (measured >= width) return text;
    const pad: u16 = width - measured;
    const out = try alloc.alloc(u8, text.len + pad);
    @memcpy(out[0..text.len], text);
    @memset(out[text.len..], ' ');
    return out;
}

/// Byte offset of the longest prefix of `text` whose display width fits
/// `max_width` cells (grapheme-aware). Shared by both truncate helpers.
fn graphemeCut(text: []const u8, max_width: u16) []const u8 {
    var used: u16 = 0;
    var end: usize = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const width = measure(bytes);
        if (used + width > max_width) break;
        used += width;
        end += bytes.len;
    }
    return text[0..end];
}

test "measure counts display width, not bytes" {
    try std.testing.expectEqual(@as(u16, 5), measure("hello"));
    try std.testing.expectEqual(@as(u16, 6), measure("日本語")); // 3 wide chars
    try std.testing.expectEqual(@as(u16, 3), measure("aé̌x")); // combining mark rides 'e'
    try std.testing.expectEqual(@as(u16, 2), measure("🦎"));
    try std.testing.expectEqual(@as(u16, 0), measure(""));
    // Zero-width joiner sequence stays one grapheme.
    try std.testing.expectEqual(@as(u16, 2), measure("👨‍👩"));
}

test "truncateEnd appends an ellipsis only when cutting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fits = try truncateEnd(a, "model-name", 20);
    try std.testing.expectEqualStrings("model-name", fits.text);
    try std.testing.expect(!fits.truncated);

    const cut = try truncateEnd(a, "a-very-long-model-identifier", 10);
    try std.testing.expect(cut.truncated);
    try std.testing.expect(std.mem.endsWith(u8, cut.text, "…"));
    try std.testing.expect(measure(cut.text) <= 10);
}

test "truncateEnd handles wide chars and width 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A wide grapheme that cannot fit is dropped entirely (never overflows).
    const wide = try truncateEnd(a, "日本語のテスト", 5);
    try std.testing.expect(wide.truncated);
    try std.testing.expect(measure(wide.text) <= 5);

    const one = try truncateEnd(a, "abc", 1);
    try std.testing.expectEqualStrings("…", one.text);
}

test "truncateMiddle keeps the final path component visible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The final component (11 cells) plus the "…/" prefix (2) needs 13 cells.
    const cut = try truncateMiddle(a, "src/tui/widgets/message.zig", 14);
    try std.testing.expect(cut.truncated);
    try std.testing.expect(std.mem.endsWith(u8, cut.text, "message.zig"));
    try std.testing.expect(measure(cut.text) <= 14);
    try std.testing.expect(std.mem.startsWith(u8, cut.text, "…/"));

    // Below that, the tail itself is cut at the budget.
    const tight = try truncateMiddle(a, "src/tui/widgets/message.zig", 10);
    try std.testing.expect(tight.truncated);
    try std.testing.expect(std.mem.startsWith(u8, tight.text, "…/message"));
    try std.testing.expect(measure(tight.text) <= 10);

    // No separator: falls back to end truncation.
    const plain = try truncateMiddle(a, "averylongidentifierwithoutseparator", 8);
    try std.testing.expect(plain.truncated);
    try std.testing.expect(std.mem.endsWith(u8, plain.text, "…"));
}

test "padTo pads with spaces to the exact width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const padded = try padTo(a, "ab", 5);
    try std.testing.expectEqualStrings("ab   ", padded);
    const overflow = try padTo(a, "toolong", 3);
    try std.testing.expectEqualStrings("toolong", overflow);
    const wide = try padTo(a, "日", 4);
    try std.testing.expectEqualStrings("日  ", wide);
}
