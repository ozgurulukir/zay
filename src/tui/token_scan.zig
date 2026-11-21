//! Pure scanners for `path[:line[:col]]` tokens and shell diagnostic prefixes.
//!
//! Used by `.shell` tool output highlighting (#501) and `path:line` token
//! actions (#514). Pure byte-slice scanners with zero UI state.

const std = @import("std");

pub const DiagnosticKind = enum {
    err,
    warn,
    path_line,
};

pub const Token = struct {
    start: usize,
    end: usize,
    kind: DiagnosticKind,
};

pub const PathLineToken = struct {
    start: usize,
    end: usize,
    path_end: usize,
    line: u32,
    col: ?u32 = null,
};

fn isTokenChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '/' or b == '\\' or b == '.' or b == '_' or b == '-' or b == ':';
}

fn isPathChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '/' or b == '\\' or b == '.' or b == '_' or b == '-';
}

/// Scan `text` for `path:line[:col]` references such as `src/a.zig:10` or
/// `./b/c.py:3:7`. Requires at least one `/`, `\`, or `.` in the path portion
/// so bare `host:8080` or `error:1` are not misclassified. Bounded to `max_tokens`.
pub fn scanPathLineTokens(alloc: std.mem.Allocator, text: []const u8, max_tokens: usize) ![]PathLineToken {
    var out: std.ArrayList(PathLineToken) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len and out.items.len < max_tokens) {
        if (!isTokenChar(text[i])) {
            i += 1;
            continue;
        }
        const tok_start = i;
        while (i < text.len and isTokenChar(text[i])) : (i += 1) {}
        var tok_end = i;
        while (tok_end > tok_start and (text[tok_end - 1] == '.' or text[tok_end - 1] == ':')) {
            tok_end -= 1;
        }
        const tok = text[tok_start..tok_end];
        if (tok.len < 4) continue;
        if (std.mem.indexOf(u8, tok, "://") != null) continue;

        if (parsePathLine(tok)) |parsed| {
            try out.append(alloc, .{
                .start = tok_start,
                .end = tok_end,
                .path_end = tok_start + parsed.path_len,
                .line = parsed.line,
                .col = parsed.col,
            });
        }
    }
    return out.toOwnedSlice(alloc);
}

const Parsed = struct {
    path_len: usize,
    line: u32,
    col: ?u32,
};

fn parsePathLine(tok: []const u8) ?Parsed {
    const first_colon = std.mem.indexOfScalar(u8, tok, ':') orelse return null;
    if (first_colon == 0 or first_colon + 1 >= tok.len) return null;
    const path = tok[0..first_colon];
    if (std.mem.indexOfAny(u8, path, "/\\") == null) return null;
    for (path) |b| {
        if (!isPathChar(b)) return null;
    }
    const rest = tok[first_colon + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, ':')) |second_colon| {
        if (second_colon == 0 or second_colon + 1 >= rest.len) return null;
        const line_str = rest[0..second_colon];
        const col_str = rest[second_colon + 1 ..];
        const line = std.fmt.parseInt(u32, line_str, 10) catch return null;
        const col = std.fmt.parseInt(u32, col_str, 10) catch return null;
        if (line == 0) return null;
        return .{ .path_len = first_colon, .line = line, .col = col };
    } else {
        const line = std.fmt.parseInt(u32, rest, 10) catch return null;
        if (line == 0) return null;
        return .{ .path_len = first_colon, .line = line, .col = null };
    }
}

/// Scan `text` for shell diagnostic prefixes (`error:`, `warning:`, `FAIL`,
/// `panic:`) at line starts and `path[:line[:col]]` tokens.
pub fn scanShellDiagnostics(alloc: std.mem.Allocator, text: []const u8, max_tokens: usize) ![]Token {
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(alloc);

    var line_start: usize = 0;
    while (line_start <= text.len and out.items.len < max_tokens) {
        const line_end = std.mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        var ws: usize = 0;
        while (ws < line.len and (line[ws] == ' ' or line[ws] == '\t')) : (ws += 1) {}
        const trimmed = line[ws..];
        const abs = line_start + ws;

        if (startsWithCaseInsensitive(trimmed, "error:") or startsWithCaseInsensitive(trimmed, "panic:") or startsWithWord(trimmed, "FAIL")) {
            const tok_len: usize = if (startsWithWord(trimmed, "FAIL")) 4 else 6;
            try out.append(alloc, .{ .start = abs, .end = abs + tok_len, .kind = .err });
        } else if (startsWithCaseInsensitive(trimmed, "warning:")) {
            try out.append(alloc, .{ .start = abs, .end = abs + 8, .kind = .warn });
        }

        if (line_end == text.len) break;
        line_start = line_end + 1;
    }

    if (out.items.len < max_tokens) {
        const paths = try scanPathLineTokens(alloc, text, max_tokens - out.items.len);
        defer alloc.free(paths);
        for (paths) |pt| {
            try out.append(alloc, .{ .start = pt.start, .end = pt.end, .kind = .path_line });
        }
    }
    return out.toOwnedSlice(alloc);
}

fn startsWithCaseInsensitive(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn startsWithWord(haystack: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, haystack, word)) return false;
    if (haystack.len == word.len) return true;
    return !std.ascii.isAlphanumeric(haystack[word.len]) and haystack[word.len] != '_';
}

test "scanPathLineTokens recognizes path:line and path:line:col" {
    const text = "See src/a.zig:10 and ./b/c.py:3:7, ignore https://example.com:8080/a and host:8080";
    const tokens = try scanPathLineTokens(std.testing.allocator, text, 16);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqualStrings("src/a.zig:10", text[tokens[0].start..tokens[0].end]);
    try std.testing.expectEqual(@as(u32, 10), tokens[0].line);
    try std.testing.expect(tokens[0].col == null);

    try std.testing.expectEqualStrings("./b/c.py:3:7", text[tokens[1].start..tokens[1].end]);
    try std.testing.expectEqual(@as(u32, 3), tokens[1].line);
    try std.testing.expectEqual(@as(?u32, 7), tokens[1].col);
}

test "scanShellDiagnostics detects error, warning, FAIL, panic and path:line" {
    const gpa = std.testing.allocator;
    const text = "error: build failed\n  warning: unused\nFAIL src/foo.zig:42\n";
    const tokens = try scanShellDiagnostics(gpa, text, 16);
    defer gpa.free(tokens);

    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(DiagnosticKind.err, tokens[0].kind);
    try std.testing.expectEqual(DiagnosticKind.warn, tokens[1].kind);
    try std.testing.expectEqual(DiagnosticKind.err, tokens[2].kind);
    try std.testing.expectEqual(DiagnosticKind.path_line, tokens[3].kind);
    try std.testing.expectEqualStrings("src/foo.zig:42", text[tokens[3].start..tokens[3].end]);
}
