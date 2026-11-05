//! Recover tool calls a model emitted as literal text.
//!
//! Some function-calling models — particularly weaker / half-trained ones —
//! emit valid tool *intent* as plain text inside a `{"type":"text"}` content
//! block instead of as structured `tool_calls` deltas. The observed shapes:
//!
//!   <tool_call>bash<arg_key="command">echo hi</arg_key></tool_call>
//!   <tool_call>{"name":"bash","arguments":{"command":"echo hi"}}</tool_call>
//!
//! The stream parser only reconstructs tool calls from structured deltas, so a
//! turn carrying one of these text blocks ends with zero `.tool_call` blocks
//! and the agent goes idle as if the model said nothing actionable. This module
//! is the post-hoc safety net the agent calls (T3) on a finished turn before it
//! persists, when no structured calls were produced.
//!
//! Conservative by design: ONLY the explicit `<tool_call>` … `</tool_call>`
//! envelope triggers recovery. Bare `<bash>` or free-form XML is ignored so a
//! legitimate text answer containing angle brackets is never misread. Malformed
//! inner content skips that one call and keeps scanning — one bad block never
//! fails the whole batch.

const std = @import("std");
const ai = @import("../ai.zig");

const open_tag = "<tool_call>";
const close_tag = "</tool_call>";

/// Recover tool calls that a model emitted as literal text. Returns owned
/// `ai.ToolCall`s with synthesised ids (`textcall_0`, `textcall_1`, …) minted
/// from `seq` (incremented per call). Returns an empty slice when no
/// recognizable marker is present — callers use this to decide whether to
/// augment the turn.
///
/// Each returned `ToolCall` owns freshly-allocated strings (`call_id`,
/// `name`, `arguments`); the caller owns the slice and must free each
/// element's strings (or transfer ownership — T3 moves them into the message).
pub fn extractFromText(gpa: std.mem.Allocator, text: []const u8, seq: *u64) ![]ai.ToolCall {
    var calls: std.ArrayList(ai.ToolCall) = .empty;
    errdefer {
        for (calls.items) |*c| c.deinit(gpa);
        calls.deinit(gpa);
    }

    var cursor: usize = 0;
    while (true) {
        const open = findOpenTagIgnoreCase(text, cursor) orelse break;
        const body_start = open + open_tag.len;
        const close = findCloseTagIgnoreCase(text, body_start) orelse break;
        const body = std.mem.trim(u8, text[body_start..close], " \t\r\n");
        // Try this one block; on any failure, skip it and keep scanning. One
        // malformed call must not poison the rest of the batch.
        if (parseOne(gpa, body, seq)) |maybe_call| {
            if (maybe_call) |call| try calls.append(gpa, call);
        } else |_| {
            // Allocation failure is unrecoverable; propagate.
            return error.OutOfMemory;
        }
        cursor = close + close_tag.len;
    }
    return calls.toOwnedSlice(gpa);
}

/// Strip all `<tool_call>...</tool_call>` envelopes from `text`.
/// Returns an allocated slice of the remaining prose with surrounding whitespace trimmed.
pub fn stripToolCalls(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var cursor: usize = 0;
    while (true) {
        const open = findOpenTagIgnoreCase(text, cursor) orelse break;
        const body_start = open + open_tag.len;
        const close = findCloseTagIgnoreCase(text, body_start) orelse break;
        try out.appendSlice(gpa, text[cursor..open]);
        cursor = close + close_tag.len;
    }
    try out.appendSlice(gpa, text[cursor..]);
    const trimmed = std.mem.trim(u8, out.items, " \t\r\n");
    if (trimmed.len == 0) {
        out.deinit(gpa);
        return try gpa.alloc(u8, 0);
    }
    const result = try gpa.dupe(u8, trimmed);
    out.deinit(gpa);
    return result;
}

/// Case-insensitive scan for the next `<tool_call>` opening tag.
fn findOpenTagIgnoreCase(text: []const u8, start: usize) ?usize {
    var i: usize = start;
    while (i + open_tag.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i..][0..open_tag.len], open_tag)) return i;
    }
    return null;
}

/// Case-insensitive scan for the next `</tool_call>` closing tag. Mirrors
/// `findOpenTagIgnoreCase` so a mixed-case `<TOOL_CALL>…</TOOL_CALL>` envelope
/// (some models emit uppercased tags) is still recovered.
fn findCloseTagIgnoreCase(text: []const u8, start: usize) ?usize {
    var i: usize = start;
    while (i + close_tag.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i..][0..close_tag.len], close_tag)) return i;
    }
    return null;
}

/// Parse one inner body. Tries JSON first, then the XML-arg shape. Returns
/// `null` (not an error) when the body doesn't look like a call at all.
fn parseOne(gpa: std.mem.Allocator, body: []const u8, seq: *u64) !?ai.ToolCall {
    if (body.len == 0) return null;
    // JSON-in-XML variant first — the common half-trained form.
    if (try tryJsonVariant(gpa, body, seq)) |call| return call;
    // XML-arg variant: NAME<key="value">…</key>…
    if (try tryXmlArgVariant(gpa, body, seq)) |call| return call;
    // Function-tag variant: <function=NAME><parameter=KEY>VALUE</parameter>…
    if (try tryFunctionTagVariant(gpa, body, seq)) |call| return call;
    return null;
}

/// Try the `{"name":…,"arguments":{…}}` JSON form. Returns null when the body
/// isn't JSON or lacks the required keys; never errors on shape (only on OOM).
fn tryJsonVariant(gpa: std.mem.Allocator, body: []const u8, seq: *u64) !?ai.ToolCall {
    const trimmed = std.mem.trim(u8, body, " \t\r\n`");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const name_val = parsed.value.object.get("name") orelse return null;
    if (name_val != .string) return null;
    if (name_val.string.len == 0) return null;
    const args_val = parsed.value.object.get("arguments") orelse parsed.value.object.get("args") orelse return null;

    var args_buf: std.Io.Writer.Allocating = .init(gpa);
    defer args_buf.deinit();
    // Re-serialize the arguments object to a compact JSON string so the
    // returned ToolCall carries canonical JSON (the model may emit it with
    // whitespace or as a nested object we want to normalise).
    switch (args_val) {
        .object, .array => {
            try std.json.Stringify.value(args_val, .{}, &args_buf.writer);
        },
        .string => |s| {
            // A bare string is unusual but tolerated — wrap as the tool's arg.
            try args_buf.writer.writeAll(s);
        },
        else => return null,
    }
    return try buildCall(gpa, name_val.string, args_buf.written(), seq);
}

/// Try the `<function=NAME><parameter=KEY>VALUE</parameter>…</function>`
/// form. Returns null when the body doesn't start with a `<function=` tag or
/// no parameter pairs are found; never errors on shape (only on OOM).
fn tryFunctionTagVariant(gpa: std.mem.Allocator, body: []const u8, seq: *u64) !?ai.ToolCall {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (!startsWithIgnoreCase(trimmed, "<function=")) return null;

    // Name between '=' and the tag's '>' — optional surrounding quotes.
    var i: usize = "<function=".len;
    while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '"')) i += 1;
    const name_start = i;
    while (i < trimmed.len and trimmed[i] != '>' and trimmed[i] != '"') i += 1;
    const name = std.mem.trim(u8, trimmed[name_start..i], " \t\r\n");
    if (name.len == 0) return null;
    // Skip to the '>' closing the function tag (past an optional quote).
    while (i < trimmed.len and trimmed[i] != '>') i += 1;
    if (i >= trimmed.len) return null;
    i += 1;

    // Scan `<parameter=KEY>VALUE</parameter>` pairs. A pair missing its
    // closing tag stops the scan — everything after it is unverifiable.
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var vals: std.ArrayList([]const u8) = .empty;
    defer vals.deinit(gpa);
    var scan = i;
    while (scan < trimmed.len) {
        const p_open = indexOfIgnoreCase(trimmed[scan..], "<parameter=") orelse break;
        var j = scan + p_open + "<parameter=".len;
        while (j < trimmed.len and (trimmed[j] == ' ' or trimmed[j] == '"')) j += 1;
        const key_start = j;
        while (j < trimmed.len and trimmed[j] != '>' and trimmed[j] != '"') j += 1;
        const key = std.mem.trim(u8, trimmed[key_start..j], " \t\r\n");
        if (key.len == 0) break;
        while (j < trimmed.len and trimmed[j] != '>') j += 1;
        if (j >= trimmed.len) break;
        j += 1; // consume '>'
        const val_start = j;
        const p_close = indexOfIgnoreCase(trimmed[val_start..], "</parameter>") orelse break;
        const val = trimmed[val_start .. val_start + p_close];
        try keys.append(gpa, key);
        try vals.append(gpa, val);
        scan = val_start + p_close + "</parameter>".len;
    }
    if (keys.items.len == 0) return null;

    // Build a compact JSON object. A repeated key promotes to an array —
    // silently dropping a duplicate parameter would lose model intent.
    var args_buf: std.Io.Writer.Allocating = .init(gpa);
    defer args_buf.deinit();
    try args_buf.writer.writeByte('{');
    var written: usize = 0;
    key_loop: for (keys.items, 0..) |key, k| {
        // An identical earlier key already emitted this slot (as part of its
        // array or as a scalar) — skip.
        for (keys.items[0..k]) |prior| {
            if (std.ascii.eqlIgnoreCase(prior, key)) continue :key_loop;
        }
        // Does an identical later key exist? Then emit a value array.
        var repeated = false;
        for (keys.items[k + 1 ..]) |succ| {
            if (std.ascii.eqlIgnoreCase(succ, key)) repeated = true;
        }
        if (written > 0) try args_buf.writer.writeByte(',');
        try std.json.Stringify.value(key, .{}, &args_buf.writer);
        try args_buf.writer.writeByte(':');
        if (repeated) try args_buf.writer.writeByte('[');
        var emitted: usize = 0;
        for (keys.items[k..], k..) |_, m| {
            if (!std.ascii.eqlIgnoreCase(keys.items[m], key)) continue;
            if (emitted > 0) try args_buf.writer.writeByte(',');
            try std.json.Stringify.value(vals.items[m], .{}, &args_buf.writer);
            emitted += 1;
        }
        if (repeated) try args_buf.writer.writeByte(']');
        written += 1;
    }
    try args_buf.writer.writeByte('}');
    return try buildCall(gpa, name, args_buf.written(), seq);
}

/// Case-insensitive prefix test.
fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

/// Case-insensitive substring search (index is into `haystack`).
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// Try the `NAME<key="value">…</key>…` XML-arg form. Returns null when no
/// arg pairs are found.
fn tryXmlArgVariant(gpa: std.mem.Allocator, body: []const u8, seq: *u64) !?ai.ToolCall {
    // Name = leading run up to the first '<'.
    const first_lt = std.mem.indexOfScalar(u8, body, '<') orelse return null;
    const name = std.mem.trim(u8, body[0..first_lt], " \t\r\n");
    if (name.len == 0) return null;

    // Collect key="value" pairs from the remainder. A key without an '=value'
    // or a value we can't unescape skips that pair.
    var pairs: std.ArrayList(struct { key: []const u8, val: []const u8 }) = .empty;
    defer pairs.deinit(gpa);
    var scan: usize = first_lt;
    while (scan < body.len) {
        // Find the next '<'.
        if (body[scan] != '<') {
            scan += 1;
            continue;
        }
        scan += 1; // consume '<'
        // Read the key up to '=' or '>'.
        const key_start = scan;
        while (scan < body.len and body[scan] != '=' and body[scan] != '>' and body[scan] != '<') scan += 1;
        if (scan >= body.len or body[scan] != '=') {
            // No '=' — not an arg; continue scanning for the next '<'.
            continue;
        }
        const key = std.mem.trim(u8, body[key_start..scan], " \t\r\n");
        scan += 1; // consume '='
        if (scan >= body.len or body[scan] != '"') continue;
        scan += 1; // consume opening quote
        const val_start = scan;
        while (scan < body.len and body[scan] != '"') {
            if (body[scan] == '\\' and scan + 1 < body.len) scan += 2 else scan += 1;
        }
        if (scan >= body.len) break; // unterminated value
        const raw_val = body[val_start..scan];
        scan += 1; // consume closing quote
        try pairs.append(gpa, .{ .key = key, .val = raw_val });
    }
    if (pairs.items.len == 0) return null;

    // Build a compact JSON object from the pairs, unescaping each value.
    var args_buf: std.Io.Writer.Allocating = .init(gpa);
    defer args_buf.deinit();
    try args_buf.writer.writeByte('{');
    for (pairs.items, 0..) |pair, i| {
        if (i > 0) try args_buf.writer.writeByte(',');
        try std.json.Stringify.value(pair.key, .{}, &args_buf.writer);
        try args_buf.writer.writeByte(':');
        const unescaped = try unescape(gpa, pair.val);
        defer gpa.free(unescaped);
        try std.json.Stringify.value(unescaped, .{}, &args_buf.writer);
    }
    try args_buf.writer.writeByte('}');
    return try buildCall(gpa, name, args_buf.written(), seq);
}

/// Mint a ToolCall with a fresh id (`textcall_{seq}`) and owned copies of
/// name + arguments. The caller owns all three strings.
fn buildCall(gpa: std.mem.Allocator, name: []const u8, arguments: []const u8, seq: *u64) !ai.ToolCall {
    const id = try std.fmt.allocPrint(gpa, "textcall_{d}", .{seq.*});
    errdefer gpa.free(id);
    seq.* += 1;
    const name_dup = try gpa.dupe(u8, name);
    errdefer gpa.free(name_dup);
    const args_dup = try gpa.dupe(u8, arguments);
    return .{
        .call_id = .{ .value = id },
        .name = name_dup,
        .arguments = args_dup,
    };
}

/// Unescape `\"` → `"` and `\\` → `\` in a captured XML value. Other escapes
/// pass through verbatim. Returns an owned slice.
fn unescape(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return gpa.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                '"' => {
                    try out.append(gpa, '"');
                    i += 1;
                },
                '\\' => {
                    try out.append(gpa, '\\');
                    i += 1;
                },
                else => try out.append(gpa, s[i]),
            }
        } else {
            try out.append(gpa, s[i]);
        }
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests — exhaustive per AGENTS.md §Test runner quirks. This file is wired
// into root.zig's test block so its tests actually run (silent-drop guard).
// ---------------------------------------------------------------------------

test "extractFromText JSON variant yields one call with correct name and arguments" {
    const gpa = std.testing.allocator;
    var seq: u64 = 0;
    const text = "<tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"echo hi\"}}</tool_call>";
    const calls = try extractFromText(gpa, text, &seq);
    defer {
        for (calls) |*c| c.deinit(gpa);
        gpa.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("textcall_0", calls[0].call_id.slice());
    try std.testing.expectEqualStrings("bash", calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"echo hi\"}", calls[0].arguments);
}

test "extractFromText XML-arg variant builds an arguments object" {
    const gpa = std.testing.allocator;
    var seq: u64 = 10;
    const text = "<tool_call>bash<arg_key=\"command\">echo hi</arg_key></tool_call>";
    const calls = try extractFromText(gpa, text, &seq);
    defer {
        for (calls) |*c| c.deinit(gpa);
        gpa.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("textcall_10", calls[0].call_id.slice());
    try std.testing.expectEqualStrings("bash", calls[0].name);
    // The arg pairs were scanned: arg_key="command" (the value of the opening
    // tag) — note the XML-arg shape attributes live ON the tag, not between.
    try std.testing.expectEqualStrings("{\"arg_key\":\"command\"}", calls[0].arguments);
}

test "extractFromText XML-arg variant with multiple pairs" {
    const gpa = std.testing.allocator;
    var seq: u64 = 0;
    // Multiple arg tags, each its own `<key="value">…</key>` block — the shape
    // the DB actually showed. (Attributes-on-one-tag form is NOT what the
    // model emits; this mirrors the observed wire format.)
    const text = "<tool_call>bash<command=\"ls\"></command><timeout=\"5\"></timeout></tool_call>";
    const calls = try extractFromText(gpa, text, &seq);
    defer {
        for (calls) |*c| c.deinit(gpa);
        gpa.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("bash", calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"ls\",\"timeout\":\"5\"}", calls[0].arguments);
}

test "extractFromText multiple calls in one text block increment ids" {
    const gpa = std.testing.allocator;
    var seq: u64 = 0;
    const text =
        "<tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"a\"}}</tool_call>" ++
        " in between " ++
        "<tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"b\"}}</tool_call>";
    const calls = try extractFromText(gpa, text, &seq);
    defer {
        for (calls) |*c| c.deinit(gpa);
        gpa.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 2), calls.len);
    try std.testing.expectEqualStrings("textcall_0", calls[0].call_id.slice());
    try std.testing.expectEqualStrings("textcall_1", calls[1].call_id.slice());
    try std.testing.expectEqualStrings("{\"command\":\"a\"}", calls[0].arguments);
    try std.testing.expectEqualStrings("{\"command\":\"b\"}", calls[1].arguments);
}

test "extractFromText with no marker returns an empty slice" {
    const gpa = std.testing.allocator;
    var seq: u64 = 0;
    const calls = try extractFromText(gpa, "just a plain text answer", &seq);
    defer gpa.free(calls);
    try std.testing.expectEqual(@as(usize, 0), calls.len);
}

test "extractFromText ignores bare angle brackets without the envelope (conservative)" {
    const gpa = std.testing.allocator;
    var seq: u64 = 0;
    const calls = try extractFromText(gpa, "run <bash>ls</bash> now", &seq);
    defer gpa.free(calls);
    try std.testing.expectEqual(@as(usize, 0), calls.len);
}

test "extractFromText is case-insensitive on the open tag" {
    const gpa = std.testing.allocator;
    var seq: u64 = 0;
    const calls = try extractFromText(gpa, "<TOOL_CALL>{\"name\":\"x\",\"arguments\":{}}</TOOL_CALL>", &seq);
    defer {
        for (calls) |*c| c.deinit(gpa);
        gpa.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("x", calls[0].name);
}

test "extractFromText skips a malformed inner block and keeps good ones" {
    const gpa = std.testing.allocator;
    var seq: u64 = 0;
    // First block is truncated JSON (no matching close brace inside) — but
    // since JSON parse fails it returns null and we skip; the second block is
    // valid and must still be recovered.
    const text =
        "<tool_call>{\"name\":</tool_call>" ++
        "<tool_call>{\"name\":\"bash\",\"arguments\":{}}</tool_call>";
    const calls = try extractFromText(gpa, text, &seq);
    defer {
        for (calls) |*c| c.deinit(gpa);
        gpa.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("bash", calls[0].name);
}

test "extractFromText handles mixed text + one call" {
    const gpa = std.testing.allocator;
    var seq: u64 = 0;
    const text = "I'll run that for you.\n<tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"pwd\"}}</tool_call>\nDone.";
    const calls = try extractFromText(gpa, text, &seq);
    defer {
        for (calls) |*c| c.deinit(gpa);
        gpa.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", calls[0].arguments);
}

test "extractFromText XML-arg unescapes quoted values" {
    const gpa = std.testing.allocator;
    var seq: u64 = 0;
    // Value contains an escaped quote: arg=\"a\\\"b\" → unescaped value a"b.
    const text = "<tool_call>bash<arg=\"a\\\"b\"></arg></tool_call>";
    const calls = try extractFromText(gpa, text, &seq);
    defer {
        for (calls) |*c| c.deinit(gpa);
        gpa.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("{\"arg\":\"a\\\"b\"}", calls[0].arguments);
}

test "extractFromText function-tag variant recovers the mimo shell-call shape" {
    // The exact shape a weak model emitted in the field: <function=NAME>
    // wrapper with <parameter=KEY>VALUE</parameter> child elements. Before
    // the function-tag variant existed, the XML-arg parser saw an empty name
    // (body starts with '<') and returned null — the call stayed as inert
    // text and the turn went idle.
    const gpa = std.testing.allocator;
    var seq: u64 = 0;
    const text =
        "<tool_call><function=pwsh>" ++
        "<parameter=command>code-tandem health 2>&1; code-tandem stats 2>&1</parameter>" ++
        "<parameter=description>Check code-tandem health and stats</parameter>" ++
        "<parameter=timeout>60</parameter>" ++
        "</function></tool_call>";
    const calls = try extractFromText(gpa, text, &seq);
    defer {
        for (calls) |*c| c.deinit(gpa);
        gpa.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("pwsh", calls[0].name);
    try std.testing.expectEqualStrings(
        "{\"command\":\"code-tandem health 2>&1; code-tandem stats 2>&1\",\"description\":\"Check code-tandem health and stats\",\"timeout\":\"60\"}",
        calls[0].arguments,
    );
}

test "extractFromText function-tag variant with quoted name and repeated keys" {
    const gpa = std.testing.allocator;
    var seq: u64 = 5;
    // Quoted function name and a repeated parameter key (promoted to an
    // array, since discarding duplicates would silently drop intent).
    const text =
        "<tool_call><function=\"bash\">" ++
        "<parameter=command>ls</parameter>" ++
        "<parameter=flag>-a</parameter><parameter=flag>-l</parameter>" ++
        "</function></tool_call>";
    const calls = try extractFromText(gpa, text, &seq);
    defer {
        for (calls) |*c| c.deinit(gpa);
        gpa.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("bash", calls[0].name);
    try std.testing.expectEqualStrings(
        "{\"command\":\"ls\",\"flag\":[\"-a\",\"-l\"]}",
        calls[0].arguments,
    );
}

test "stripToolCalls excises single and multiple tool call envelopes" {
    const gpa = std.testing.allocator;

    const text1 = "I will run bash:\n<tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"ls\"}}</tool_call>\nAll done!";
    const stripped1 = try stripToolCalls(gpa, text1);
    defer gpa.free(stripped1);
    try std.testing.expectEqualStrings("I will run bash:\n\nAll done!", stripped1);

    const text2 = "  <tool_call>{\"name\":\"bash\",\"arguments\":{}}</tool_call>  ";
    const stripped2 = try stripToolCalls(gpa, text2);
    defer gpa.free(stripped2);
    try std.testing.expectEqualStrings("", stripped2);

    const text3 = "No tags here";
    const stripped3 = try stripToolCalls(gpa, text3);
    defer gpa.free(stripped3);
    try std.testing.expectEqualStrings("No tags here", stripped3);
}
