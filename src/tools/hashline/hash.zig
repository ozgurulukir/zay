const std = @import("std");

const bigrams = @import("bigrams.zig");

const assert = std.debug.assert;

/// Stable separator between an anchor (`LINE+HASH`) and the line body in
/// hashline-prefixed read output.
pub const body_sep = '|';

/// Marker prefix at the start of every hashline-formatted line. Distinctive
/// enough that real file content is extremely unlikely to begin with it, so
/// the strip pass can identify hashlines unambiguously without misclassifying
/// arbitrary tool output.
pub const line_prefix = "#HL";

/// Compute the two-character bigram hash for a line. Trailing whitespace and
/// trailing CRs are stripped before hashing so CRLF/LF differences and stray
/// trailing spaces don't shift hashes. Lines with no alphanumeric content
/// (e.g. brace-only lines) mix the line index into the seed so adjacent
/// identical punctuation lines still get distinct anchors.
pub fn computeLineHash(line_idx: u32, raw_line: []const u8) []const u8 {
    assert(line_idx >= 1);
    const trimmed = trimTrailingWhitespace(raw_line);
    const seed: u32 = if (hasSignificantChar(trimmed)) 0 else line_idx;
    const h = std.hash.XxHash32.hash(seed, trimmed);
    const bigram = bigrams.all[h % bigrams.all.len];
    assert(bigram.len == 2);
    return bigram;
}

fn trimTrailingWhitespace(line: []const u8) []const u8 {
    var end: usize = line.len;
    while (end > 0) {
        const c = line[end - 1];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            end -= 1;
        } else break;
    }
    return line[0..end];
}

fn hasSignificantChar(line: []const u8) bool {
    for (line) |c| {
        if (std.ascii.isAlphanumeric(c)) return true;
    }
    return false;
}

/// Write a hashline-prefixed line to the buffer: `#HL{LINE}{HASH}|{TEXT}`.
pub fn writeHashLine(
    gpa: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    line_number: u32,
    line: []const u8,
) !void {
    assert(line_number >= 1);
    const hash = computeLineHash(line_number, line);
    try buffer.print(gpa, "{s}{d}{s}{c}{s}", .{ line_prefix, line_number, hash, body_sep, line });
}

/// Append `text` to `buffer`, stripping a `LINE+HASH|` prefix from any line
/// that has one. Lines that don't match the prefix pass through verbatim, so
/// this is safe to apply to arbitrary tool output: only read-file-shaped
/// lines actually get rewritten. Single pass over the input, O(n) total.
pub fn appendStripped(
    gpa: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    text: []const u8,
) !void {
    var iter = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (iter.next()) |line| {
        if (!first) try buffer.append(gpa, '\n');
        first = false;
        try buffer.appendSlice(gpa, stripHashlinePrefix(line));
    }
}

/// Return the byte slice of `line` with a leading `#HL{LINE}{HASH}|` removed
/// if present. The original slice is returned unchanged when no such prefix
/// is found.
pub fn stripHashlinePrefix(line: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, line, line_prefix)) return line;
    var i: usize = line_prefix.len;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i == line_prefix.len) return line;
    if (i + 2 >= line.len) return line;
    if (line[i] < 'a' or line[i] > 'z') return line;
    if (line[i + 1] < 'a' or line[i + 1] > 'z') return line;
    if (line[i + 2] != body_sep) return line;
    return line[i + 3 ..];
}

/// Hashline-format every line of `text`. Lines are joined with `\n`.
pub fn formatHashLines(gpa: std.mem.Allocator, text: []const u8, start_line: u32) ![]u8 {
    assert(start_line >= 1);
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    var iter = std.mem.splitScalar(u8, text, '\n');
    var line_idx = start_line;
    var first = true;
    while (iter.next()) |line| {
        if (!first) try buffer.append(gpa, '\n');
        first = false;
        try writeHashLine(gpa, &buffer, line_idx, line);
        line_idx += 1;
    }
    return buffer.toOwnedSlice(gpa);
}

test "stripHashlinePrefix removes #HL prefix, anchor, and pipe" {
    try std.testing.expectEqualStrings("function foo() {", stripHashlinePrefix("#HL42sr|function foo() {"));
    try std.testing.expectEqualStrings("plain text", stripHashlinePrefix("plain text"));
    try std.testing.expectEqualStrings("", stripHashlinePrefix("#HL1ab|"));
    // A line without the #HL prefix is left intact even if the rest matches.
    try std.testing.expectEqualStrings("42sr|legacy form", stripHashlinePrefix("42sr|legacy form"));
    // A line that has #HL but a malformed anchor is left intact.
    try std.testing.expectEqualStrings("#HL42sr no pipe", stripHashlinePrefix("#HL42sr no pipe"));
    try std.testing.expectEqualStrings("#HL42!!|foo", stripHashlinePrefix("#HL42!!|foo"));
}

test "appendStripped strips every hashline-prefixed line" {
    const gpa = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    try appendStripped(gpa, &buffer, "#HL1ab|alpha\n#HL2cd|beta\nbare line\n#HL3ef|gamma");
    try std.testing.expectEqualStrings("alpha\nbeta\nbare line\ngamma", buffer.items);
}

test "computeLineHash returns a 2-char bigram" {
    const hash = computeLineHash(1, "function foo() {");
    try std.testing.expectEqual(@as(usize, 2), hash.len);
    try std.testing.expect(std.ascii.isLower(hash[0]));
    try std.testing.expect(std.ascii.isLower(hash[1]));
}

test "computeLineHash is stable across calls" {
    const a = computeLineHash(7, "    return result;");
    const b = computeLineHash(7, "    return result;");
    try std.testing.expectEqualSlices(u8, a, b);
}

test "trailing whitespace does not affect the hash" {
    const clean = computeLineHash(3, "let x = 1;");
    const padded = computeLineHash(3, "let x = 1;   \t\r");
    try std.testing.expectEqualSlices(u8, clean, padded);
}

test "blank lines distinguish by line number" {
    const at_one = computeLineHash(1, "");
    const at_two = computeLineHash(2, "");
    try std.testing.expect(!std.mem.eql(u8, at_one, at_two));
}

test "formatHashLines prefixes every line" {
    const gpa = std.testing.allocator;
    const out = try formatHashLines(gpa, "alpha\nbeta\ngamma", 1);
    defer gpa.free(out);
    var iter = std.mem.splitScalar(u8, out, '\n');
    var index: u32 = 1;
    while (iter.next()) |line| : (index += 1) {
        try std.testing.expect(std.mem.startsWith(u8, line, line_prefix));
        try std.testing.expect(std.mem.findScalar(u8, line, body_sep) != null);
    }
    try std.testing.expectEqual(@as(u32, 4), index);
}
