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

/// Scan `text` for `path[:line[:col]]` tokens (e.g. `src/a.zig:10`,
/// `./b/c.py:3:7`). Requires at least one `/` (or `./` / `../`) before `:line`
/// so bare `host:8080` or `error:1` are not misclassified as file paths.
pub fn scanPathLineTokens(alloc: std.mem.Allocator, text: []const u8, max_tokens: usize) ![]Token {
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len and out.items.len < max_tokens) {
        if (!isPathStart(text, i)) {
            i += 1;
            continue;
        }
        const start = i;
        var j = i;
        var has_slash = false;
        while (j < text.len and isPathChar(text[j])) : (j += 1) {
            if (text[j] == '/') has_slash = true;
        }
        if (has_slash and j < text.len and text[j] == ':') {
            var k = j + 1;
            const line_start = k;
            while (k < text.len and std.ascii.isDigit(text[k])) : (k += 1) {}
            if (k > line_start) {
                if (k < text.len and text[k] == ':') {
                    const col_colon = k;
                    var m = k + 1;
                    const col_start = m;
                    while (m < text.len and std.ascii.isDigit(text[m])) : (m += 1) {}
                    if (m > col_start) {
                        k = m;
                    } else {
                        k = col_colon;
                    }
                }
                if (k == text.len or !isPathTailBoundary(text[k])) {
                    try out.append(alloc, .{ .start = start, .end = k, .kind = .path_line });
                    i = k;
                    continue;
                }
            }
        }
        i = @max(j, i + 1);
    }
    return out.toOwnedSlice(alloc);
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
        try out.appendSlice(alloc, paths);
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

fn isPathStart(text: []const u8, idx: usize) bool {
    if (idx > 0 and !isDelimiter(text[idx - 1])) return false;
    const ch = text[idx];
    return std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '/' or ch == '_' or ch == '-';
}

fn isDelimiter(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '(' or ch == '[' or ch == '\'' or ch == '"' or ch == '`';
}

fn isPathChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '.' or ch == '_' or ch == '-';
}

fn isPathTailBoundary(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

test "scanPathLineTokens matches relative and nested path:line[:col] tokens" {
    const gpa = std.testing.allocator;
    const text = "see src/a.zig:10 and ./b/c.py:3:7, not host:8080";
    const tokens = try scanPathLineTokens(gpa, text, 16);
    defer gpa.free(tokens);

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqualStrings("src/a.zig:10", text[tokens[0].start..tokens[0].end]);
    try std.testing.expectEqualStrings("./b/c.py:3:7", text[tokens[1].start..tokens[1].end]);
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
