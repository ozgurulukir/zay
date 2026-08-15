//! Structured parts pipeline: a shared, pure module that derives typed
//! display parts (`.json` / `.diff` / `.text`) from a raw tool body and
//! beautifies a tool's expanded title. Both the TUI (`drawToolBody`,
//! `drawToolTitle`) and the LLM observation path (`formatLlmObservation`)
//! import this module, so formatting never diverges between the screen and
//! the model (SSOT).
//!
//! This module imports only `std` and `common.zig`. It must NOT import
//! `transcript` or any TUI module — the dependency direction is one-way:
//! transcript → parts, display → parts. `message` / `metrics` consume
//! `ToolView.parts`.

const std = @import("std");
const tools_common = @import("common.zig");

/// Cap for a single tool display body rendered in the TUI. Bodies larger than
/// this are head+tail elided (`common.pruneToolText`) before parts are built,
/// so a multi-MB output never materializes into the row list. `u32` to match
/// `pruneToolText`'s `cap_bytes` parameter.
pub const tool_body_display_max_bytes: u32 = 64 * 1024;

pub const PartKind = enum(u8) { text, diff, json };

pub const JsonTokenKind = enum(u8) { punctuation, key, string, number, boolean, null };

pub const JsonSpan = struct { start: usize, end: usize, kind: JsonTokenKind };

pub const Part = struct {
    kind: PartKind,
    text: []u8,
    /// Non-empty only for `.json`; token spans into `text` (byte offsets).
    spans: []JsonSpan = &.{},
    pub fn deinit(self: *Part, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.spans);
        self.* = undefined;
    }
};

/// Pretty-printed JSON plus token spans into the formatted text.
pub const FormattedJson = struct {
    text: []u8,
    spans: []JsonSpan,
    pub fn deinit(self: *FormattedJson, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.spans);
        self.* = undefined;
    }
};

/// Cheap JSON heuristic: first non-whitespace is `{` or `[` and the last
/// non-whitespace is `}` or `]`. Used to gate the formatter.
pub fn isJson(text: []const u8) bool {
    const first = skipWhitespace(text, 0);
    if (first >= text.len) return false;
    var last = text.len;
    while (last > 0 and std.ascii.isWhitespace(text[last - 1])) last -= 1;
    if (last <= first) return false;
    const open = text[first];
    const close = text[last - 1];
    return (open == '{' and close == '}') or (open == '[' and close == ']');
}

/// Classify a body. `hint` is the source's declared kind (from `Output.display`);
/// a `.diff` hint wins. Otherwise `isJson` → `.json`, else `.text`.
pub fn classify(text: []const u8, hint: PartKind) PartKind {
    if (hint == .diff) return .diff;
    if (isJson(text)) return .json;
    return .text;
}

/// Single-pass pretty-printer + tokenizer. Returns `error.InvalidJson` on any
/// unexpected byte or unterminated string (caller falls back to `.text`).
/// The caller owns both `text` and `spans`.
pub fn formatJson(gpa: std.mem.Allocator, text: []const u8) !FormattedJson {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var spans: std.ArrayList(JsonSpan) = .empty;
    errdefer spans.deinit(gpa);

    var depth: u32 = 0;
    var i: usize = 0;

    while (i < text.len) {
        i = skipWhitespace(text, i);
        if (i >= text.len) break;

        const byte = text[i];
        switch (byte) {
            '{', '[' => {
                const open_offset = out.items.len;
                try out.append(gpa, byte);
                try spans.append(gpa, .{ .start = open_offset, .end = out.items.len, .kind = .punctuation });
                i += 1;
                const close: u8 = if (byte == '{') '}' else ']';
                const next = skipWhitespace(text, i);
                if (next < text.len and text[next] == close) {
                    // Empty container: emit `{}` / `[]` with no newline (m3).
                    try out.append(gpa, close);
                    try spans.append(gpa, .{ .start = out.items.len - 1, .end = out.items.len, .kind = .punctuation });
                    i = next + 1;
                } else {
                    depth += 1;
                    try writeIndent(&out, depth, gpa);
                    i = next;
                }
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
                try writeIndent(&out, depth, gpa);
                try out.append(gpa, byte);
                try spans.append(gpa, .{ .start = out.items.len - 1, .end = out.items.len, .kind = .punctuation });
                i += 1;
            },
            ',' => {
                try out.append(gpa, byte);
                try spans.append(gpa, .{ .start = out.items.len - 1, .end = out.items.len, .kind = .punctuation });
                i += 1;
                try writeIndent(&out, depth, gpa);
            },
            ':' => {
                try out.append(gpa, byte);
                try spans.append(gpa, .{ .start = out.items.len - 1, .end = out.items.len, .kind = .punctuation });
                i += 1;
                try out.append(gpa, ' ');
            },
            '"' => {
                // Honor `\` escapes; an unterminated string is invalid.
                const token_start = i;
                i += 1;
                var closed = false;
                while (i < text.len) {
                    switch (text[i]) {
                        '"' => {
                            closed = true;
                            i += 1;
                            break;
                        },
                        '\\' => i += if (i + 1 < text.len) 2 else 1,
                        else => i += 1,
                    }
                }
                if (!closed) return error.InvalidJson;
                const raw = text[token_start..i];
                const span_start = out.items.len;
                try out.appendSlice(gpa, raw);
                const span_end = out.items.len;
                const after = skipWhitespace(text, i);
                const kind: JsonTokenKind = if (after < text.len and text[after] == ':') .key else .string;
                try spans.append(gpa, .{ .start = span_start, .end = span_end, .kind = kind });
                i = after;
            },
            '-', '0'...'9' => {
                const span_start = out.items.len;
                var num_end = i;
                while (num_end < text.len and isNumberByte(text[num_end])) num_end += 1;
                try out.appendSlice(gpa, text[i..num_end]);
                try spans.append(gpa, .{ .start = span_start, .end = out.items.len, .kind = .number });
                i = num_end;
            },
            't', 'f', 'n' => {
                const literal = literal: {
                    if (std.mem.startsWith(u8, text[i..], "true")) break :literal "true";
                    if (std.mem.startsWith(u8, text[i..], "false")) break :literal "false";
                    if (std.mem.startsWith(u8, text[i..], "null")) break :literal "null";
                    return error.InvalidJson;
                };
                const span_start = out.items.len;
                try out.appendSlice(gpa, literal);
                const kind: JsonTokenKind = if (std.mem.eql(u8, literal, "null")) .null else .boolean;
                try spans.append(gpa, .{ .start = span_start, .end = out.items.len, .kind = kind });
                i += literal.len;
            },
            else => return error.InvalidJson,
        }
    }

    return .{
        .text = try out.toOwnedSlice(gpa),
        .spans = try spans.toOwnedSlice(gpa),
    };
}

/// A single byte of a JSON number: digits, sign, exponent, or decimal point.
/// Lenient (does not enforce canonical number grammar) — just enough to slice
/// the token for pretty-printing.
fn isNumberByte(byte: u8) bool {
    return std.ascii.isDigit(byte) or byte == '-' or byte == '+' or
        byte == '.' or byte == 'e' or byte == 'E';
}

/// Emit a newline plus `2 * depth` spaces into the output buffer.
fn writeIndent(out: *std.ArrayList(u8), depth: u32, gpa: std.mem.Allocator) !void {
    try out.append(gpa, '\n');
    var spaces: u32 = depth * 2;
    while (spaces > 0) : (spaces -= 1) try out.append(gpa, ' ');
}

fn skipWhitespace(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    return i;
}

/// Build the display parts for a tool body. Caps oversized input with
/// `pruneToolText`, then classifies and (for JSON) formats. Returns 0 or 1 parts.
/// Caller owns the returned slice and each part's `text`/`spans`.
pub fn buildParts(gpa: std.mem.Allocator, text: []const u8, hint: PartKind) ![]Part {
    // M5: empty input → a non-heap `&.{}` slice. `&.{}` coerces to `[]T`
    // (mutable) in Zig 0.16 and is NOT heap-allocated, so the free sites' guard
    // `if (t.parts.len > 0)` correctly skips it.
    if (text.len == 0) return &.{};
    // M2: reuse the SSOT `pruneToolText` (fresh dupe when it fits, head+tail
    // elision when it doesn't) instead of reimplementing the split inline.
    const bounded = try tools_common.pruneToolText(gpa, text, tool_body_display_max_bytes);
    errdefer gpa.free(bounded);
    const kind = classify(bounded, hint);
    if (kind == .json) {
        if (formatJson(gpa, bounded)) |formatted| {
            var owned = formatted;
            // M3: if the `gpa.alloc(Part, 1)` below fails, cover `owned` with a
            // scoped errdefer so neither `owned.text` nor `owned.spans` leaks;
            // `bounded` is freed by the outer errdefer.
            errdefer owned.deinit(gpa);
            const out = try gpa.alloc(Part, 1);
            defer gpa.free(bounded); // C1: free `bounded` exactly once on success
            out[0] = .{ .kind = .json, .text = owned.text, .spans = owned.spans };
            return out;
        } else |_| {} // malformed JSON → fall through to a `.text` part
    }
    const out = try gpa.alloc(Part, 1);
    out[0] = .{ .kind = if (kind == .diff) .diff else .text, .text = bounded };
    return out;
}

/// Beautified expanded title: `"name args"` with JSON args pretty-printed.
/// Used by `transcript.updateToolExpanded`; no emoji prefix (draw/metrics strip
/// or ignore it). Caller owns the result. The first whitespace-delimited word
/// is the name; the remainder is dimmed args (every non-JSON args string is
/// pasted through verbatim).
pub fn formatExpandedTitle(gpa: std.mem.Allocator, expanded_command: []const u8) ![]u8 {
    const name_end = std.mem.indexOfScalar(u8, expanded_command, ' ') orelse expanded_command.len;
    const name = expanded_command[0..name_end];
    const args_rest = if (name_end < expanded_command.len)
        std.mem.trimStart(u8, expanded_command[name_end..], " \t")
    else
        "";
    // No args → just the name.
    if (args_rest.len == 0) return gpa.dupe(u8, name);
    // If args-rest is JSON, pretty-print it. `formatJson` returns a
    // `FormattedJson { text, spans }` that owns BOTH fields, so free both.
    if (isJson(args_rest)) {
        if (formatJson(gpa, args_rest)) |formatted| {
            var owned = formatted;
            defer owned.deinit(gpa); // M6: don't leak text or spans
            return std.fmt.allocPrint(gpa, "{s} {s}", .{ name, owned.text });
        } else |_| {} // malformed → fall through to raw args
    }
    // Not JSON (or unparseable) → name + raw args.
    return std.fmt.allocPrint(gpa, "{s} {s}", .{ name, args_rest });
}

test "isJson detects objects and arrays with whitespace padding" {
    try std.testing.expect(isJson("{\"a\":1}"));
    try std.testing.expect(isJson("[1,2]"));
    try std.testing.expect(isJson("  {\"a\":1}  "));
    try std.testing.expect(isJson("\n{\"a\":1}\n"));
    try std.testing.expect(!isJson("hello"));
    try std.testing.expect(!isJson("{\"a\":1} extra"));
    try std.testing.expect(!isJson(""));
    try std.testing.expect(!isJson("   "));
}

test "classify diff hint wins over JSON-looking text" {
    try std.testing.expectEqual(PartKind.json, classify("{\"a\":1}", .text));
    try std.testing.expectEqual(PartKind.diff, classify("{\"a\":1}", .diff));
    try std.testing.expectEqual(PartKind.text, classify("plain", .text));
}

test "formatJson pretty-prints with indentation and token spans" {
    const gpa = std.testing.allocator;
    var formatted = try formatJson(gpa, "{\"a\":\"x\",\"n\":1,\"b\":[true,null]}");
    defer formatted.deinit(gpa);

    const expected =
        \\{
        \\  "a": "x",
        \\  "n": 1,
        \\  "b": [
        \\    true,
        \\    null
        \\  ]
        \\}
    ;
    try std.testing.expectEqualStrings(expected, formatted.text);

    // Keys, strings, numbers, booleans, and nulls each get a typed span.
    var saw_key_a = false;
    var saw_string = false;
    var saw_number = false;
    var saw_boolean = false;
    var saw_null = false;
    for (formatted.spans) |span| {
        switch (span.kind) {
            .key => saw_key_a = saw_key_a or std.mem.eql(u8, formatted.text[span.start..span.end], "\"a\""),
            .string => saw_string = true,
            .number => saw_number = true,
            .boolean => saw_boolean = true,
            .null => saw_null = true,
            else => {},
        }
    }
    try std.testing.expect(saw_key_a);
    try std.testing.expect(saw_string);
    try std.testing.expect(saw_number);
    try std.testing.expect(saw_boolean);
    try std.testing.expect(saw_null);
}

test "formatJson keeps empty containers on one line" {
    const gpa = std.testing.allocator;
    var formatted = try formatJson(gpa, "{\"a\":{},\"b\":[]}");
    defer formatted.deinit(gpa);
    try std.testing.expectEqualStrings("{\n  \"a\": {},\n  \"b\": []\n}", formatted.text);
}

test "formatJson rejects malformed input" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidJson, formatJson(gpa, "{\"unterminated}"));
    try std.testing.expectError(error.InvalidJson, formatJson(gpa, "@"));
}

test "buildParts caps oversized bodies with the elision marker" {
    const gpa = std.testing.allocator;
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    var n: usize = 0;
    while (n < tool_body_display_max_bytes + 1000) : (n += 1) big.append(gpa, 'x') catch {};
    const parts = try buildParts(gpa, big.items, .text);
    defer {
        for (parts) |*p| p.deinit(gpa);
        if (parts.len > 0) gpa.free(parts);
    }
    try std.testing.expect(parts.len == 1);
    try std.testing.expect(parts[0].kind == .text);
    try std.testing.expect(std.mem.indexOf(u8, parts[0].text, "elided to save context") != null);
}

test "buildParts empty input returns a non-heap empty slice" {
    const gpa = std.testing.allocator;
    const parts = try buildParts(gpa, "", .text);
    try std.testing.expectEqual(@as(usize, 0), parts.len);
    // Guard-safe: `parts.len > 0` free sites skip it, and the empty slice is
    // not heap-allocated, so nothing is leaked.
}

test "buildParts diff hint yields a single diff part" {
    const gpa = std.testing.allocator;
    const parts = try buildParts(gpa, "+ added\n- removed", .diff);
    defer {
        for (parts) |*p| p.deinit(gpa);
        if (parts.len > 0) gpa.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expect(parts[0].kind == .diff);
}

test "buildParts json success transfers ownership cleanly" {
    const gpa = std.testing.allocator;
    // Asserting via `std.testing.allocator` (leak-checked): the JSON part owns
    // its text and spans, and the temporary `bounded` dupe is freed exactly once.
    const parts = try buildParts(gpa, "{\"ok\":true}", .text);
    defer {
        for (parts) |*p| p.deinit(gpa);
        if (parts.len > 0) gpa.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expect(parts[0].kind == .json);
    try std.testing.expect(parts[0].spans.len > 0);
}

test "formatExpandedTitle pretty-prints JSON args" {
    const gpa = std.testing.allocator;
    const title = try formatExpandedTitle(gpa, "greet {\"name\":\"x\"}");
    defer gpa.free(title);
    try std.testing.expect(std.mem.startsWith(u8, title, "greet {"));
    try std.testing.expect(std.mem.indexOf(u8, title, "\n") != null);
}

test "formatExpandedTitle with plugin-style args and no args" {
    const gpa = std.testing.allocator;
    // Plugin-style `"{tool} {args}"`: JSON args are pretty-printed (Step 6).
    const plugin_title = try formatExpandedTitle(gpa, "greet {\"name\":\"x\"}");
    defer gpa.free(plugin_title);
    try std.testing.expect(std.mem.indexOf(u8, plugin_title, "\"name\": \"x\"") != null);

    // No args → just the name.
    const bare = try formatExpandedTitle(gpa, "pwd");
    defer gpa.free(bare);
    try std.testing.expectEqualStrings("pwd", bare);

    // Non-JSON args → name + raw args.
    const raw = try formatExpandedTitle(gpa, "bash echo hi");
    defer gpa.free(raw);
    try std.testing.expectEqualStrings("bash echo hi", raw);
}
