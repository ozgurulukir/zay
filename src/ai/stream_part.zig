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

/// Shared stream-parsing policy: both wire adapters (chat-completions and
/// Responses) accept this so the parallel-call cap and reject logging behave
/// identically regardless of protocol.
pub const StreamLimits = struct {
    /// Upper bound on parallel tool calls per turn. Deltas at or above the
    /// cap are dropped (counted in `dropped`) so the remaining calls can
    /// still complete the turn.
    max_parallel_calls: u32 = 16,
    /// Borrowed; used only so the over-cap reject log can name which model
    /// tripped the cap. Never affects parsing behaviour.
    model_label: []const u8 = "",
};

/// Per-stream environment shared by both adapters: the policy above plus the
/// client-owned monotonic counter for minting synthetic tool-call ids when
/// the server omits them (client lifetime preserves cross-turn uniqueness).
pub const StreamEnv = struct {
    limits: StreamLimits = .{},
    id_seq: *u64,
    response_policy: @import("response_policy.zig").Policy = .{},
};

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
    saw_done: bool = false,
    pending_data: ?[]u8 = null,

    pub fn deinit(self: *Source, gpa: std.mem.Allocator) void {
        if (self.pending_data) |p| {
            gpa.free(p);
            self.pending_data = null;
        }
    }

    /// Return the next SSE event `data:` payload (owned by the caller), or null
    /// at the `[DONE]` sentinel or end of stream. Consecutive `data:` lines in
    /// one event are joined with `\n` and dispatched at the blank-line boundary
    /// (or EOF) per the SSE specification. If a consecutive `data:` line arrives
    /// after an already-complete JSON object without an intervening blank line,
    /// the completed object is yielded first so single-newline-delimited streams
    /// also parse cleanly.
    pub fn next(self: *Source, gpa: std.mem.Allocator) !?[]u8 {
        if (self.saw_done) {
            if (self.pending_data) |p| {
                gpa.free(p);
                self.pending_data = null;
            }
            return null;
        }
        var event_buf: std.ArrayList(u8) = .empty;
        errdefer event_buf.deinit(gpa);
        var has_data = false;

        if (self.pending_data) |p| {
            defer gpa.free(p);
            self.pending_data = null;
            try event_buf.appendSlice(gpa, p);
            has_data = true;
        }

        while (try readLine(gpa, self.reader, bytes_max -| self.bytes_read)) |line| {
            defer gpa.free(line);
            self.chunk_count += 1;
            self.bytes_read += line.len;
            if (self.chunk_count > chunk_count_max) return error.StreamTooManyChunks;
            if (self.bytes_read > bytes_max) return error.StreamTooLarge;

            const trimmed_cr = std.mem.trimEnd(u8, line, "\r");
            if (trimmed_cr.len == 0) {
                if (has_data) return try event_buf.toOwnedSlice(gpa);
                continue;
            }
            switch (classify(line)) {
                .skip => continue,
                .done => {
                    self.saw_done = true;
                    if (has_data) return try event_buf.toOwnedSlice(gpa);
                    event_buf.deinit(gpa);
                    return null;
                },
                .data => |data| {
                    if (has_data and isJsonBalanced(event_buf.items)) {
                        self.pending_data = try gpa.dupe(u8, data);
                        return try event_buf.toOwnedSlice(gpa);
                    }
                    if (has_data) try event_buf.append(gpa, '\n');
                    try event_buf.appendSlice(gpa, data);
                    has_data = true;
                },
            }
        }
        if (has_data) return try event_buf.toOwnedSlice(gpa);
        event_buf.deinit(gpa);
        return null;
    }
};

fn isJsonBalanced(bytes: []const u8) bool {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len < 2) return false;
    if (trimmed[0] != '{' and trimmed[0] != '[') return false;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (trimmed) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => {},
        }
    }
    return !in_string and depth == 0;
}

/// Read one `\n`-terminated line (delimiter stripped), bounded by `max_bytes`
/// during the read so an unterminated line cannot exhaust memory (#422).
/// Returns null at end of stream when no trailing bytes remain.
fn readLine(gpa: std.mem.Allocator, reader: *std.Io.Reader, max_bytes: usize) !?[]u8 {
    var line_writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer line_writer.deinit();
    _ = reader.streamDelimiterLimit(&line_writer.writer, '\n', .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.StreamTooLarge,
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

test "classify returns .skip for non-data lines, comments, and empty payloads" {
    // Non-data field names and comments
    try std.testing.expectEqual(Line.skip, classify(""));
    try std.testing.expectEqual(Line.skip, classify("   \r"));
    try std.testing.expectEqual(Line.skip, classify(": keep-alive comment"));
    try std.testing.expectEqual(Line.skip, classify("event: message"));
    try std.testing.expectEqual(Line.skip, classify("id: 101"));
    try std.testing.expectEqual(Line.skip, classify("retry: 3000"));
    try std.testing.expectEqual(Line.skip, classify("data_other: value"));
    try std.testing.expectEqual(Line.skip, classify("DATA: uppercase"));

    // Empty data payloads with various whitespace
    try std.testing.expectEqual(Line.skip, classify("data:"));
    try std.testing.expectEqual(Line.skip, classify("data: "));
    try std.testing.expectEqual(Line.skip, classify("data:    "));
    try std.testing.expectEqual(Line.skip, classify("data: \r"));
    try std.testing.expectEqual(Line.skip, classify("  data:   \r"));
}

test "classify returns .done for [DONE] sentinel with surrounding whitespace" {
    try std.testing.expectEqual(Line.done, classify("data: [DONE]"));
    try std.testing.expectEqual(Line.done, classify("data: [DONE]\r"));
    try std.testing.expectEqual(Line.done, classify("data:   [DONE]  "));
    try std.testing.expectEqual(Line.done, classify("  data:   [DONE]  \r"));
}

test "classify returns .data with correct slice borrowing for JSON and text payloads" {
    switch (classify("data: {\"k\":1}")) {
        .data => |payload| try std.testing.expectEqualStrings("{\"k\":1}", payload),
        else => try std.testing.expect(false),
    }

    switch (classify("data:   {\"k\":1}  \r")) {
        .data => |payload| try std.testing.expectEqualStrings("{\"k\":1}", payload),
        else => try std.testing.expect(false),
    }

    switch (classify("data:hello")) {
        .data => |payload| try std.testing.expectEqualStrings("hello", payload),
        else => try std.testing.expect(false),
    }

    switch (classify("  data:   hello world  \r")) {
        .data => |payload| try std.testing.expectEqualStrings("hello world", payload),
        else => try std.testing.expect(false),
    }
}

test "Source.next extracts data lines skipping comments, IDs, and empty lines" {
    const gpa = std.testing.allocator;
    const sse_input =
        \\: ping keepalive
        \\event: message
        \\id: 101
        \\data: {"chunk": 1}
        \\
        \\: another comment
        \\data: {"chunk": 2}
        \\data: [DONE]
        \\data: {"ignored": 3}
    ;

    var reader = std.Io.Reader.fixed(sse_input);
    var source: Source = .{ .reader = &reader };

    const first = try source.next(gpa);
    defer if (first) |f| gpa.free(f);
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("{\"chunk\": 1}", first.?);

    const second = try source.next(gpa);
    defer if (second) |s| gpa.free(s);
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("{\"chunk\": 2}", second.?);

    // [DONE] encountered -> yields null
    const done = try source.next(gpa);
    try std.testing.expect(done == null);
}

test "Source.next handles final line at EOF without trailing newline" {
    const gpa = std.testing.allocator;
    const sse_input = "data: {\"final\": true}";

    var reader = std.Io.Reader.fixed(sse_input);
    var source: Source = .{ .reader = &reader };

    const payload = try source.next(gpa);
    defer if (payload) |p| gpa.free(p);
    try std.testing.expect(payload != null);
    try std.testing.expectEqualStrings("{\"final\": true}", payload.?);

    const at_end = try source.next(gpa);
    try std.testing.expect(at_end == null);
}

test "Source.next enforces bytes_max limit with StreamTooLarge error" {
    const gpa = std.testing.allocator;
    var reader = std.Io.Reader.fixed("data: hello\n");
    var source: Source = .{ .reader = &reader, .bytes_read = bytes_max + 1 };

    const result = source.next(gpa);
    try std.testing.expectError(error.StreamTooLarge, result);
}

test "Source.next enforces chunk_count_max with StreamTooManyChunks error" {
    const gpa = std.testing.allocator;
    var reader = std.Io.Reader.fixed("data: hello\n");
    var source: Source = .{ .reader = &reader, .chunk_count = chunk_count_max + 1 };

    const result = source.next(gpa);
    try std.testing.expectError(error.StreamTooManyChunks, result);
}

test "readLine aborts during read when line exceeds max_bytes (#422)" {
    const gpa = std.testing.allocator;
    var reader = std.Io.Reader.fixed("data: " ++ ("x" ** 64));
    try std.testing.expectError(error.StreamTooLarge, readLine(gpa, &reader, 32));
}

test "Source.next joins multi-line data events at blank-line boundary (#538)" {
    const gpa = std.testing.allocator;
    const sse_input =
        \\data: {
        \\data:   "chunk": 1
        \\data: }
        \\
        \\data: [DONE]
    ;
    var reader = std.Io.Reader.fixed(sse_input);
    var source: Source = .{ .reader = &reader };

    const first = (try source.next(gpa)).?;
    defer gpa.free(first);
    try std.testing.expectEqualStrings("{\n\"chunk\": 1\n}", first);
    try std.testing.expect((try source.next(gpa)) == null);
    try std.testing.expect(source.saw_done);
}
