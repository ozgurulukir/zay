//! Cross-dialect tool-call argument hygiene.
//!
//! The executability policy for a tool-call arguments payload is shared by
//! both wire dialects (chat completions and Responses) and by both
//! directions (outbound history re-serialization and finish-time hygiene).
//! This leaf module is its single home — sibling dialect modules import it
//! directly, never through each other's parser (the INV-RESP-1 quirk-leaf
//! pattern used by `model_compat.zig` and `provider_headers.zig`).

const std = @import("std");

/// True when `raw` will dispatch as a valid tool-call arguments JSON object.
/// `sanitizeToolArguments` collapses empty/severed input to "{}"; this tells
/// the two apart: a literal (trimmed) `{}` is an intentional no-argument call,
/// anything else that sanitize cannot round-trip to a `{...}` object is a
/// provider truncation (no args delivered, or the JSON cut mid-stream).
pub fn argumentsAreExecutable(raw: []const u8) bool {
    const sanitized = sanitizeToolArguments(raw);
    if (!std.mem.eql(u8, sanitized, "{}")) return true;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return trimmed.len == 2 and trimmed[0] == '{' and trimmed[1] == '}';
}

pub fn sanitizeToolArguments(raw: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return "{}";

    if (std.mem.startsWith(u8, trimmed, "```")) {
        if (std.mem.indexOf(u8, trimmed, "\n")) |newline_pos| {
            trimmed = std.mem.trim(u8, trimmed[newline_pos + 1 ..], " \t\r\n");
        } else {
            trimmed = std.mem.trim(u8, trimmed[3..], " \t\r\n");
        }
        if (std.mem.endsWith(u8, trimmed, "```")) {
            trimmed = std.mem.trim(u8, trimmed[0 .. trimmed.len - 3], " \t\r\n");
        }
    }

    if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        return trimmed;
    }

    // When a model wraps a JSON object with conversational text or comments,
    // extract the slice between the first '{' and last '}'.
    if (std.mem.indexOfScalar(u8, trimmed, '{')) |start| {
        if (std.mem.lastIndexOfScalar(u8, trimmed, '}')) |end| {
            if (end > start) {
                return trimmed[start .. end + 1];
            }
        }
    }

    return "{}";
}

/// Mint the synthetic `call_{d}` id used when a provider omits one, from the
/// caller's shared call-id sequence. The returned slice is owned by `gpa`.
pub fn mintSyntheticCallId(gpa: std.mem.Allocator, call_seq: *u64) ![]u8 {
    const minted = try std.fmt.allocPrint(gpa, "call_{d}", .{call_seq.*});
    call_seq.* += 1;
    return minted;
}

test "sanitizeToolArguments extracts json object from conversational prose or fences" {
    try std.testing.expectEqualStrings("{\"command\":\"echo 1\"}", sanitizeToolArguments("```json\n{\"command\":\"echo 1\"}\n```"));
    try std.testing.expectEqualStrings("{\"key\":\"value\"}", sanitizeToolArguments("Calling tool: {\"key\":\"value\"} finished"));
    try std.testing.expectEqualStrings("{}", sanitizeToolArguments("no json here"));
    try std.testing.expectEqualStrings("{}", sanitizeToolArguments("{ unclosed"));
}

test "sanitizeToolArguments strips markdown backticks and falls back to empty object" {
    try std.testing.expectEqualStrings("{}", sanitizeToolArguments(""));
    try std.testing.expectEqualStrings("{}", sanitizeToolArguments("   "));
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", sanitizeToolArguments("{\"command\":\"ls\"}"));
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", sanitizeToolArguments("```json\n{\"command\":\"ls\"}\n```"));
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", sanitizeToolArguments("// Running command:\n{\"command\":\"ls\"}\n// done"));
    try std.testing.expectEqualStrings("{}", sanitizeToolArguments("not a json string"));
    try std.testing.expectEqualStrings("{}", sanitizeToolArguments("{\"comm"));
}

test "argumentsAreExecutable distinguishes intentional empty object from truncation" {
    try std.testing.expect(argumentsAreExecutable("{\"command\":\"ls\"}"));
    // A literal (trimmed) `{}` is an intentional no-argument call.
    try std.testing.expect(argumentsAreExecutable("{}"));
    try std.testing.expect(argumentsAreExecutable("  {}  \n"));
    // Anything that sanitize collapses to `{}` from a non-`{}` raw is a
    // provider truncation: no args delivered, or the JSON cut mid-stream.
    // The verdict runs on the RAW payload — even a fenced `{}` counts as
    // truncation, because the streamed bytes were never a bare `{}`.
    try std.testing.expect(!argumentsAreExecutable(""));
    try std.testing.expect(!argumentsAreExecutable("   "));
    try std.testing.expect(!argumentsAreExecutable("not a json string"));
    try std.testing.expect(!argumentsAreExecutable("{\"comm"));
    try std.testing.expect(!argumentsAreExecutable("no braces here"));
    try std.testing.expect(!argumentsAreExecutable("```json\n{}\n```"));
}

test "mintSyntheticCallId advances the shared sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var call_seq: u64 = 42;
    const first = try mintSyntheticCallId(gpa, &call_seq);
    try std.testing.expectEqualStrings("call_42", first);
    const second = try mintSyntheticCallId(gpa, &call_seq);
    try std.testing.expectEqualStrings("call_43", second);
}
