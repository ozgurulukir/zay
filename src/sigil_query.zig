//! Shared cursor-token scanner for the two prompt sigils: `@` file mentions
//! (`at_mention.zig`) and `$` skill invocations (`skill.zig`).
//!
//! The scan rules are identical for both surfaces — the token starts at a
//! sigil that sits at the start of the text or right after whitespace and runs
//! to the cursor. Quoted tokens (`@"path with spaces"`) may contain
//! whitespace; picker-generated tokens escape `\` and `"` inside the quotes.
//!
//! paths.zig-style leaf: pure std-only helpers, no imports from `src/`.
//! `bash_safety.zig`'s `isBoundary` is a different predicate (shell
//! metacharacters) and deliberately NOT shared with this one.

const std = @import("std");

/// One sigil token ending at the cursor.
pub const Token = struct {
    /// Byte offset of the sigil within the scanned text.
    start: usize,
    /// The fragment after the sigil. Quoted tokens exclude the surrounding
    /// quotes but retain escape sequences until `decodeQuery` runs.
    query: []const u8,
    /// Whether the token uses the quoted form (`@"..."`).
    quoted: bool = false,
};

/// A token parsed from a complete or partial input buffer.
pub const ParsedToken = struct {
    token: Token,
    /// Byte offset immediately after the token. For an unfinished quoted
    /// token this is the end of the input buffer.
    end: usize,
    /// Unquoted tokens and closed quoted tokens are complete. An unfinished
    /// quoted token is useful to the live picker but is not a submitted path.
    closed: bool,
};

/// Parse a token beginning at `start`. The caller may pass a partial quoted
/// token while the user is typing; `closed` distinguishes it from a complete
/// token for submission.
pub fn parseTokenAt(text: []const u8, start: usize, trigger: u8) ?ParsedToken {
    if (start >= text.len) return null;
    if (text[start] != trigger) return null;
    if (start > 0 and !isBoundary(text[start - 1])) return null;

    const content_start = start + 1;
    if (content_start < text.len and text[content_start] == '"') {
        var index = content_start + 1;
        var escaped = false;
        while (index < text.len) : (index += 1) {
            const c = text[index];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') {
                const end = index + 1;
                if (end < text.len and !isBoundary(text[end])) {
                    if (!isSentencePunctuation(text[end])) return null;
                }
                return .{
                    .token = .{
                        .start = start,
                        .query = text[content_start + 1 .. index],
                        .quoted = true,
                    },
                    .end = end,
                    .closed = true,
                };
            }
        }
        return .{
            .token = .{
                .start = start,
                .query = text[content_start + 1 ..],
                .quoted = true,
            },
            .end = text.len,
            .closed = false,
        };
    }

    var end = content_start;
    while (end < text.len and !isBoundary(text[end])) : (end += 1) {}
    return .{
        .token = .{ .start = start, .query = text[content_start..end] },
        .end = end,
        .closed = true,
    };
}

/// The active sigil token ending at the cursor, given the text *before* the
/// cursor. The token starts right after a `trigger` byte that sits at the
/// start of the text or just after whitespace. Quoted tokens can contain
/// whitespace and may be unfinished while the user is typing.
pub fn activeQuery(before_cursor: []const u8, trigger: u8) ?Token {
    var index: usize = 0;
    while (index < before_cursor.len) {
        if (before_cursor[index] != trigger) {
            index += 1;
            continue;
        }
        const parsed = parseTokenAt(before_cursor, index, trigger) orelse {
            index += 1;
            continue;
        };
        // Skip the complete token so a sigil inside a quoted path cannot be
        // mistaken for a new token (for example `@"a @b.txt"`).
        if (parsed.end == before_cursor.len) return parsed.token;
        index = parsed.end;
        if (index < before_cursor.len and !isBoundary(before_cursor[index])) return null;
    }
    return null;
}

/// Decode the query portion of a parsed token into an owned path/name.
/// Unquoted tokens retain the historical sentence-punctuation trimming rule;
/// quoted tokens preserve punctuation and unescape only the `\\` and `\"`
/// sequences emitted by `formatToken`.
pub fn decodeQuery(gpa: std.mem.Allocator, token: Token) ![]u8 {
    if (!token.quoted) return gpa.dupe(u8, trimTrailingPunctuation(token.query));

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var index: usize = 0;
    while (index < token.query.len) : (index += 1) {
        const c = token.query[index];
        if (c == '\\' and index + 1 < token.query.len and
            (token.query[index + 1] == '\\' or token.query[index + 1] == '"'))
        {
            index += 1;
            try out.writer.writeByte(token.query[index]);
        } else {
            try out.writer.writeByte(c);
        }
    }
    return out.toOwnedSlice();
}

/// Format a picker-selected token and its trailing separator. Simple values
/// retain the compact legacy form; values that cannot fit one whitespace token
/// use the quoted form understood by `parseTokenAt`.
pub fn formatToken(gpa: std.mem.Allocator, trigger: u8, value: []const u8) ![]u8 {
    var needs_quotes = false;
    for (value) |c| {
        if (isBoundary(c) or c == '"' or c == '\\') {
            needs_quotes = true;
            break;
        }
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeByte(trigger);
    if (!needs_quotes) {
        try out.writer.writeAll(value);
    } else {
        try out.writer.writeByte('"');
        for (value) |c| {
            if (c == '"' or c == '\\') try out.writer.writeByte('\\');
            try out.writer.writeByte(c);
        }
        try out.writer.writeByte('"');
    }
    try out.writer.writeByte(' ');
    return out.toOwnedSlice();
}

/// Whitespace-only token boundary (space, tab, newline, carriage return).
pub fn isBoundary(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isSentencePunctuation(c: u8) bool {
    return switch (c) {
        '.', ',', ';', ':', '!', '?' => true,
        else => false,
    };
}

/// Drops trailing sentence punctuation so `@src/x.zig.` references `src/x.zig`
/// and `$tiger!` references `tiger`.
pub fn trimTrailingPunctuation(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0) : (end -= 1) {
        if (!isSentencePunctuation(value[end - 1])) break;
    }
    return value[0..end];
}

test "activeQuery detects a token at the cursor (both sigils)" {
    var buf: [16]u8 = undefined;
    inline for (.{ '@', '$' }) |sigil| {
        const text = try std.fmt.bufPrint(&buf, "explain {c}src/ag", .{sigil});
        const active = activeQuery(text, sigil).?;
        try std.testing.expectEqual(@as(usize, 8), active.start);
        try std.testing.expectEqualStrings("src/ag", active.query);
        try std.testing.expect(!active.quoted);
    }
}

test "activeQuery handles a bare sigil at the start (both sigils)" {
    var buf: [2]u8 = undefined;
    inline for (.{ '@', '$' }) |sigil| {
        buf[0] = sigil;
        const active = activeQuery(buf[0..1], sigil).?;
        try std.testing.expectEqual(@as(usize, 0), active.start);
        try std.testing.expectEqualStrings("", active.query);
    }
}

test "activeQuery rejects whitespace after the token (both sigils)" {
    var buf: [16]u8 = undefined;
    inline for (.{ '@', '$' }) |sigil| {
        const trailing = try std.fmt.bufPrint(&buf, "explain {c}foo ", .{sigil});
        try std.testing.expect(activeQuery(trailing, sigil) == null);
        try std.testing.expect(activeQuery("hello world", sigil) == null);
    }
}

test "activeQuery accepts a quoted token with spaces" {
    const active = activeQuery("explain @\"Screenshot From 2026", '@').?;
    try std.testing.expectEqual(@as(usize, 8), active.start);
    try std.testing.expectEqualStrings("Screenshot From 2026", active.query);
    try std.testing.expect(active.quoted);

    const complete = activeQuery("explain @\"Screenshot From 2026\"", '@').?;
    try std.testing.expectEqualStrings("Screenshot From 2026", complete.query);
    try std.testing.expect(complete.quoted);
    try std.testing.expect(activeQuery("explain @\"Screenshot From 2026\" ", '@') == null);
}

test "activeQuery ignores escaped quotes inside a quoted token" {
    const active = activeQuery("open @\"a \\\"quote\\\" b", '@').?;
    try std.testing.expectEqualStrings("a \\\"quote\\\" b", active.query);
    try std.testing.expect(active.quoted);
    const decoded = try decodeQuery(std.testing.allocator, active);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("a \"quote\" b", decoded);
}

test "formatToken quotes paths with spaces and escapes special bytes" {
    const formatted = try formatToken(std.testing.allocator, '@', "Screenshot From 2026-10-11 11-02-09.png");
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("@\"Screenshot From 2026-10-11 11-02-09.png\" ", formatted);

    const escaped = try formatToken(std.testing.allocator, '@', "a\\b\"c.txt");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("@\"a\\\\b\\\"c.txt\" ", escaped);
}

test "activeQuery rejects an embedded sigil (email-like)" {
    try std.testing.expect(activeQuery("mail user@host", '@') == null);
}

test "activeQuery only honors its own trigger" {
    try std.testing.expect(activeQuery("see @src", '@') != null);
    try std.testing.expect(activeQuery("see @src", '$') == null);
    try std.testing.expect(activeQuery("use $tiger", '$') != null);
    try std.testing.expect(activeQuery("use $tiger", '@') == null);
}

test "trimTrailingPunctuation strips sentence punctuation only" {
    try std.testing.expectEqualStrings("src/a.zig", trimTrailingPunctuation("src/a.zig."));
    try std.testing.expectEqualStrings("tiger", trimTrailingPunctuation("tiger!?"));
    try std.testing.expectEqualStrings("a,b", trimTrailingPunctuation("a,b"));
    try std.testing.expectEqualStrings("", trimTrailingPunctuation(""));
    try std.testing.expectEqualStrings("", trimTrailingPunctuation("..."));
}
