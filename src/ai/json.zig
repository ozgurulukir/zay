//! Shared JSON wire helpers for AI provider adapters.

const std = @import("std");

/// Write `text` as a JSON string, replacing invalid UTF-8 with U+FFFD.
///
/// Tool and MCP output is not guaranteed to be UTF-8. Zig's JSON stringifier
/// deliberately encodes an invalid `[]const u8` as an array of byte integers;
/// provider schemas interpret that as structured content, not text.
pub fn writeString(out: *std.Io.Writer, gpa: std.mem.Allocator, text: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(text)) {
        try std.json.Stringify.value(text, .{}, out);
        return;
    }

    const repaired_capacity = std.math.mul(usize, text.len, 4) catch return error.OutOfMemory;
    const repaired = try gpa.alloc(u8, repaired_capacity);
    defer gpa.free(repaired);

    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < text.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(text[input_index]) catch {
            repaired[output_index] = 0xef;
            repaired[output_index + 1] = 0xbf;
            repaired[output_index + 2] = 0xbd;
            output_index += 3;
            input_index += 1;
            continue;
        };
        const sequence_fits = sequence_length <= text.len - input_index;
        if (sequence_fits and std.unicode.utf8ValidateSlice(text[input_index..][0..sequence_length])) {
            @memcpy(repaired[output_index..][0..sequence_length], text[input_index..][0..sequence_length]);
            output_index += sequence_length;
            input_index += sequence_length;
        } else {
            repaired[output_index] = 0xef;
            repaired[output_index + 1] = 0xbf;
            repaired[output_index + 2] = 0xbd;
            output_index += 3;
            input_index += 1;
        }
    }

    try std.json.Stringify.value(repaired[0..output_index], .{}, out);
}

test "writeString repairs invalid UTF-8 without emitting a byte array" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();

    try writeString(&output.writer, gpa, "ok\xff");

    try std.testing.expectEqualStrings("\"ok\xef\xbf\xbd\"", output.written());
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "[") == null);
}

test "writeString preserves valid bytes after an invalid UTF-8 sequence" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();

    try writeString(&output.writer, gpa, "bad\xf5abc");

    try std.testing.expectEqualStrings("\"bad\xef\xbf\xbdabc\"", output.written());
}
