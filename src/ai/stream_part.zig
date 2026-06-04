//! StreamPart — the transport-level SSE event source shared by the streaming
//! adapters.
//!
//! Both the Completions (`openai_compatible`) and Responses (`responses_core`)
//! adapters read Server-Sent-Events the same way: line-framed `data:` payloads,
//! a terminal `[DONE]` sentinel, and a hard cap on chunk count and total bytes.
//! That framing — not the JSON *inside* each payload — is what they genuinely
//! share, so it lives here once. Each adapter still owns its own per-payload
//! parsing (the two wire protocols are different and must stay free to diverge;
//! merging them would be a leaky abstraction).
//!
//! `Source.next` yields one decoded payload at a time so a caller drives it at
//! its own pace:
//!
//!     var source: StreamPart.Source = .{ .reader = reader };
//!     while (try source.next(gpa)) |data| {
//!         defer gpa.free(data);
//!         // adapter-specific: parse `data` and update accumulators
//!     }
//!     // adapter-specific: finalise accumulated blocks into an ai.Turn

const std = @import("std");

/// Upper bounds on a single response stream. Hit either and `next` errors
/// rather than letting a misbehaving server stream unbounded work.
pub const chunk_count_max: u32 = 100_000;
pub const bytes_max: u32 = 8 * 1024 * 1024;

/// The classification of one raw SSE line. Pure: the returned `data` slice
/// borrows from the input line.
pub const Line = union(enum) {
    /// A non-`data:` line, or a `data:` line with an empty payload (keep-alive)
    /// — carries nothing to parse.
    skip,
    /// The `[DONE]` sentinel: the server has finished the stream.
    done,
    /// A `data:` payload (trimmed), ready for the adapter to parse.
    data: []const u8,
};

/// Classify one raw SSE line. No allocation; the `.data` slice borrows `line`.
pub fn classify(line: []const u8) Line {
    const trimmed = std.mem.trim(u8, line, " \r");
    if (!std.mem.startsWith(u8, trimmed, "data:")) return .skip;
    const data = std.mem.trim(u8, trimmed["data:".len..], " ");
    if (std.mem.eql(u8, data, "[DONE]")) return .done;
    if (data.len == 0) return .skip;
    return .{ .data = data };
}

pub const Source = struct {
    reader: *std.Io.Reader,
    chunk_count: u32 = 0,
    bytes_read: u64 = 0,

    /// Return the next `data:` payload (owned by the caller), or null at the
    /// `[DONE]` sentinel or end of stream. Skips non-data and keep-alive lines
    /// and enforces the stream bounds.
    pub fn next(self: *Source, gpa: std.mem.Allocator) !?[]u8 {
        while (try readLine(gpa, self.reader)) |line| {
            defer gpa.free(line);
            self.chunk_count += 1;
            self.bytes_read += line.len;
            if (self.chunk_count > chunk_count_max) return error.StreamTooManyChunks;
            if (self.bytes_read > bytes_max) return error.StreamTooLarge;
            switch (classify(line)) {
                .skip => continue,
                .done => return null,
                .data => |data| return try gpa.dupe(u8, data),
            }
        }
        return null;
    }
};

/// Read one `\n`-terminated line (delimiter stripped). Returns null at end of
/// stream when no trailing bytes remain.
fn readLine(gpa: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var line_writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer line_writer.deinit();
    _ = reader.streamDelimiterEnding(&line_writer.writer, '\n') catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => return error.OutOfMemory,
    };
    const delimiter = reader.take(1) catch |err| switch (err) {
        error.EndOfStream => {
            if (line_writer.written().len == 0) return null;
            return try line_writer.toOwnedSlice();
        },
        else => |e| return e,
    };
    std.debug.assert(delimiter.len == 1);
    std.debug.assert(delimiter[0] == '\n');
    return try line_writer.toOwnedSlice();
}

test "classify distinguishes data, done, and skip lines" {
    try std.testing.expectEqual(Line.skip, classify(": keep-alive comment"));
    try std.testing.expectEqual(Line.skip, classify("event: message"));
    try std.testing.expectEqual(Line.skip, classify("data: "));
    try std.testing.expectEqual(Line.done, classify("data: [DONE]"));
    switch (classify("data: {\"k\":1}\r")) {
        .data => |payload| try std.testing.expectEqualStrings("{\"k\":1}", payload),
        else => try std.testing.expect(false),
    }
}
