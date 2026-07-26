//! SSE streaming parser for OpenAI-compatible chat completions.
//!
//! Extracted from openai_compatible.zig. Pure parsing logic: consumes SSE
//! data lines via `stream_part.Source`, accumulates content/reasoning/tool-call
//! deltas through a `std.json.Scanner`, and emits observer callbacks. No HTTP,
//! no Client state — just the wire format → `ai.Turn` projection.

const std = @import("std");
const logger = @import("logger");
const ai = @import("../ai.zig");
const stream_part = @import("stream_part.zig");

const Scanner = std.json.Scanner;

/// Hard upper bound for fixed-size remap/index arrays in ToolCallStream
/// and ChunkChange. The runtime-configurable gate is `max_parallel_tool_calls`
/// in ai.Config (default 16); this cap just sizes the stack arrays.
const tool_call_array_cap: u32 = 64;

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
    return "{}";
}

const ToolCallBuilder = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolCallBuilder, gpa: std.mem.Allocator) void {
        self.id.deinit(gpa);
        self.name.deinit(gpa);
        self.arguments.deinit(gpa);
        self.* = undefined;
    }

    /// Finalise the accumulated chunks into a canonical `ai.ToolCall`.
    /// When the server omitted an id, synthesise one from `tool_call_seq`
    /// — the agent never sees an empty id.
    /// Arguments are sanitised (markdown fences stripped, empty → "{}")
    /// so downstream consumers (executor, display) always see valid JSON.
    fn toToolCall(self: *ToolCallBuilder, gpa: std.mem.Allocator, tool_call_seq: *u64) !ai.ToolCall {
        const id = if (self.id.items.len > 0)
            try self.id.toOwnedSlice(gpa)
        else id_blk: {
            const minted = try std.fmt.allocPrint(gpa, "call_{d}", .{tool_call_seq.*});
            tool_call_seq.* += 1;
            break :id_blk minted;
        };
        const raw_args = try self.arguments.toOwnedSlice(gpa);
        const sanitized = sanitizeToolArguments(raw_args);
        const arguments = if (sanitized.ptr == raw_args.ptr and sanitized.len == raw_args.len)
            raw_args
        else blk: {
            const duped = try gpa.dupe(u8, sanitized);
            gpa.free(raw_args);
            break :blk duped;
        };
        return .{
            .call_id = .{ .value = id },
            .name = try self.name.toOwnedSlice(gpa),
            .arguments = arguments,
        };
    }
};

/// Streaming tool-call accumulator with logical-to-physical index remapping.
///
/// Some OpenAI-compatible providers reuse `index: 0` for parallel tool calls
/// instead of incrementing the index per call. This struct detects that by
/// comparing tool-call IDs — which are always unique — and forks a new
/// physical builder slot when a collision is found. Subsequent argument
/// deltas (which carry no ID) route through the remap to the correct slot.
pub const ToolCallStream = struct {
    builders: std.ArrayList(ToolCallBuilder) = .empty,
    remapped_slot: [tool_call_array_cap]u32 = @splat(0),
    is_remapped: [tool_call_array_cap]bool = @splat(false),
    /// Runtime-configurable upper bound on parallel tool calls (from
    /// ai.Config.max_parallel_tool_calls). Indices at or above this
    /// are rejected with a logged error.
    max_calls: u32 = 16,

    fn physicalSlot(self: *const ToolCallStream, logical: u32) u32 {
        return if (self.is_remapped[logical]) self.remapped_slot[logical] else logical;
    }

    pub fn deinit(self: *ToolCallStream, gpa: std.mem.Allocator) void {
        for (self.builders.items) |*b| b.deinit(gpa);
        self.builders.deinit(gpa);
    }
};

pub fn readStream(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    observer: anytype,
    tool_call_seq: *u64,
    max_calls: u32,
) !ai.Turn {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: ToolCallStream = .{ .max_calls = max_calls };
    defer stream.deinit(gpa);

    // Parse and apply each chunk inline (rather than via `processStreamChunk`)
    // so the final usage-only chunk's `change.usage` reaches the Turn. The
    // server emits at most one usage chunk; the last one observed wins.
    var usage: ?ai.Usage = null;
    var source: stream_part.Source = .{ .reader = reader };
    while (try source.next(gpa)) |data| {
        defer gpa.free(data);
        const change = try parseStreamChunk(gpa, data, &content, &reasoning, &stream);
        if (change.usage) |chunk_usage| usage = chunk_usage;
        try applyChunkCallbacks(change, content.items, reasoning.items, stream.builders.items, observer);
    }

    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    errdefer {
        for (blocks.items) |*block| block.deinit(gpa);
        blocks.deinit(gpa);
    }
    if (reasoning.items.len > 0) {
        try blocks.append(gpa, .{ .reasoning = .{ .text = try reasoning.toOwnedSlice(gpa) } });
    }
    if (content.items.len > 0) {
        try blocks.append(gpa, .{ .text = .{ .text = try content.toOwnedSlice(gpa) } });
    }
    for (stream.builders.items, 0..) |*builder, i| {
        if (builder.name.items.len == 0) continue;
        logger.log(
            "readStream.builder[{d}] name={s} id_len={d} args_len={d}",
            .{ i, builder.name.items, builder.id.items.len, builder.arguments.items.len },
        );
        try blocks.append(gpa, .{ .tool_call = try builder.toToolCall(gpa, tool_call_seq) });
    }
    logger.log("readStream.done content_len={d} reasoning_len={d} blocks={d}", .{ content.items.len, reasoning.items.len, blocks.items.len });
    return .{ .assistant = .{ .assistant = .{ .content = try blocks.toOwnedSlice(gpa) } }, .usage = usage };
}

pub const ChunkChange = struct {
    content_start: ?u32 = null,
    reasoning_start: ?u32 = null,
    tool_call_indexes: [tool_call_array_cap]u32 = @splat(0),
    tool_call_count: u32 = 0,
    /// Token usage when this chunk was the final usage-only chunk; otherwise
    /// null. Does not affect `empty()` — a usage chunk emits no callbacks.
    usage: ?ai.Usage = null,

    pub fn empty(self: *const ChunkChange) bool {
        if (self.content_start != null) return false;
        if (self.reasoning_start != null) return false;
        if (self.tool_call_count > 0) return false;
        return true;
    }

    fn recordToolCall(self: *ChunkChange, index: u32) void {
        for (self.tool_call_indexes[0..self.tool_call_count]) |existing| {
            if (existing == index) return;
        }
        std.debug.assert(self.tool_call_count < tool_call_array_cap);
        self.tool_call_indexes[self.tool_call_count] = index;
        self.tool_call_count += 1;
    }
};

fn applyChunkCallbacks(
    change: ChunkChange,
    content: []const u8,
    reasoning: []const u8,
    builders: []const ToolCallBuilder,
    observer: anytype,
) !void {
    if (change.content_start) |start| {
        try observer.on_content(observer.ctx, content[start..]);
    }
    if (change.reasoning_start) |start| {
        try observer.on_reasoning(observer.ctx, reasoning[start..]);
    }
    for (change.tool_call_indexes[0..change.tool_call_count]) |idx| {
        const builder = builders[idx];
        try observer.on_tool_delta(observer.ctx, .{
            .index = idx,
            .name = builder.name.items,
            .arguments = builder.arguments.items,
        });
    }
    if (change.empty()) return;
    try observer.on_delta_end(observer.ctx);
}

pub fn processStreamChunk(
    gpa: std.mem.Allocator,
    data: []const u8,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    stream: *ToolCallStream,
    observer: anytype,
) !void {
    const change = try parseStreamChunk(gpa, data, content, reasoning, stream);
    try applyChunkCallbacks(change, content.items, reasoning.items, stream.builders.items, observer);
}

pub fn parseStreamChunk(
    gpa: std.mem.Allocator,
    data: []const u8,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    stream: *ToolCallStream,
) !ChunkChange {
    // Empty payloads carry no chunk (keep-alive lines). Return early rather than
    // feeding the scanner an empty document.
    if (data.len == 0) return .{};

    var scanner = Scanner.initCompleteInput(gpa, data);
    defer scanner.deinit();

    var change: ChunkChange = .{};
    try expectObjectBegin(&scanner);
    while (try nextObjectKey(&scanner)) |key| {
        if (std.mem.eql(u8, key, "choices")) {
            try parseChoicesArray(gpa, &scanner, content, reasoning, stream, &change);
        } else if (std.mem.eql(u8, key, "usage")) {
            try parseUsageValue(&scanner, &change.usage);
        } else {
            try scanner.skipValue();
        }
    }
    return change;
}

/// Parse the chat-completions `usage` value. Content chunks carry `usage:null`
/// (consumed and ignored); the final usage-only chunk carries the object.
fn parseUsageValue(scanner: *Scanner, usage: *?ai.Usage) !void {
    const peeked = try scanner.peekNextTokenType();
    if (peeked == .null) {
        _ = try scanner.next();
        return;
    }
    usage.* = try parseUsageObject(scanner);
}

/// Parse the chat-completions usage object. Only the top-level totals are
/// captured; the optional `*_tokens_details` sub-objects are skipped (their
/// cached/reasoning breakdown is informational and not needed for budgeting).
fn parseUsageObject(scanner: *Scanner) !ai.Usage {
    try expectObjectBegin(scanner);
    var input_tokens: i64 = 0;
    var output_tokens: i64 = 0;
    var total_tokens: i64 = 0;
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "prompt_tokens")) {
            input_tokens = try nextInteger(scanner);
        } else if (std.mem.eql(u8, key, "completion_tokens")) {
            output_tokens = try nextInteger(scanner);
        } else if (std.mem.eql(u8, key, "total_tokens")) {
            total_tokens = try nextInteger(scanner);
        } else {
            try scanner.skipValue();
        }
    }
    return .{
        .input_tokens = ai.clampTokenCount(input_tokens),
        .output_tokens = ai.clampTokenCount(output_tokens),
        .total_tokens = ai.clampTokenCount(total_tokens),
    };
}

fn parseChoicesArray(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    stream: *ToolCallStream,
    change: *ChunkChange,
) !void {
    try expectArrayBegin(scanner);
    var saw_first = false;
    while (true) {
        const peeked = try scanner.peekNextTokenType();
        if (peeked == .array_end) {
            _ = try scanner.next();
            return;
        }
        if (saw_first) {
            try scanner.skipValue();
            continue;
        }
        try expectObjectBegin(scanner);
        try parseChoiceObject(gpa, scanner, content, reasoning, stream, change);
        saw_first = true;
    }
}

fn parseChoiceObject(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    stream: *ToolCallStream,
    change: *ChunkChange,
) !void {
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "delta")) {
            try parseDeltaObject(gpa, scanner, content, reasoning, stream, change);
        } else {
            try scanner.skipValue();
        }
    }
}

fn parseDeltaObject(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    stream: *ToolCallStream,
    change: *ChunkChange,
) !void {
    try expectObjectBegin(scanner);
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "content")) {
            const before: u32 = @intCast(content.items.len);
            const appended = try appendStringValue(scanner, gpa, content, .allow_null);
            if (appended) {
                if (content.items.len > before) change.content_start = before;
            }
        } else if (std.mem.eql(u8, key, "reasoning") or std.mem.eql(u8, key, "reasoning_content")) {
            const before: u32 = @intCast(reasoning.items.len);
            const appended = try appendStringValue(scanner, gpa, reasoning, .allow_null);
            if (appended) {
                if (reasoning.items.len > before) change.reasoning_start = before;
            }
        } else if (std.mem.eql(u8, key, "tool_calls")) {
            try parseToolCallsArray(gpa, scanner, stream, change);
        } else {
            try scanner.skipValue();
        }
    }
}

fn parseToolCallsArray(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    stream: *ToolCallStream,
    change: *ChunkChange,
) !void {
    try expectArrayBegin(scanner);
    while (true) {
        const peeked = try scanner.peekNextTokenType();
        if (peeked == .array_end) {
            _ = try scanner.next();
            return;
        }
        try expectObjectBegin(scanner);
        try parseToolCallObject(gpa, scanner, stream, change);
    }
}

fn parseToolCallObject(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    stream: *ToolCallStream,
    change: *ChunkChange,
) !void {
    var pending: ToolCallBuilder = .{};
    defer pending.deinit(gpa);
    var has_pending_id = false;
    var has_pending_name = false;
    var has_pending_arguments = false;
    var resolved_index: ?u32 = null;

    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "index")) {
            const index = try nextInteger(scanner);
            if (index < 0) return error.InvalidToolCallIndex;
            if (index >= tool_call_array_cap) return error.TooManyToolCalls;
            if (index >= stream.max_calls) {
                logger.log("parseToolCall.reject index={d} exceeds max_parallel_tool_calls={d}", .{ index, stream.max_calls });
                return error.TooManyToolCalls;
            }
            resolved_index = @intCast(index);
        } else if (std.mem.eql(u8, key, "id")) {
            _ = try appendStringValue(scanner, gpa, &pending.id, .reject_null);
            has_pending_id = true;
        } else if (std.mem.eql(u8, key, "function")) {
            try parseToolCallFunction(gpa, scanner, &pending, &has_pending_name, &has_pending_arguments);
        } else {
            try scanner.skipValue();
        }
    }

    const logical = resolved_index orelse return;
    while (stream.builders.items.len <= logical) try stream.builders.append(gpa, .{});

    // Detect ID collision: same logical index but a different tool-call ID.
    // This happens when a provider reuses index 0 for parallel tool calls.
    // Fork a new physical slot and remap this logical index to it.
    //
    // Also detect ID duplication: different logical index but the same ID.
    // Some providers (Qwen/DashScope) echo the same tool-call ID across
    // multiple indices. Remap this logical index to the existing builder
    // so argument chunks accumulate in one place instead of creating an
    // empty duplicate.
    if (has_pending_id) {
        // Merge: same ID already lives in another physical slot.
        for (stream.builders.items, 0..) |*existing, i| {
            if (existing.id.items.len == 0) continue;
            if (!std.mem.eql(u8, existing.id.items, pending.id.items)) continue;
            const existing_physical: u32 = @intCast(i);
            if (existing_physical != stream.physicalSlot(logical)) {
                logger.log("parseToolCall.merge logical={d} → physical={d} id={s}", .{ logical, existing_physical, pending.id.items });
                stream.remapped_slot[logical] = existing_physical;
                stream.is_remapped[logical] = true;
            }
            break;
        }
        // Fork: same logical index, different ID → new physical slot.
        const current = stream.physicalSlot(logical);
        const existing = &stream.builders.items[@as(usize, current)];
        if (existing.id.items.len > 0 and !std.mem.eql(u8, existing.id.items, pending.id.items)) {
            const new_slot: u32 = @intCast(stream.builders.items.len);
            logger.log("parseToolCall.fork logical={d} → new_slot={d} old_id={s} new_id={s}", .{ logical, new_slot, existing.id.items, pending.id.items });
            try stream.builders.append(gpa, .{});
            stream.remapped_slot[logical] = new_slot;
            stream.is_remapped[logical] = true;
        }
    }

    const physical = stream.physicalSlot(logical);
    const target = &stream.builders.items[@as(usize, physical)];

    // Names and IDs are atomic in streaming — first complete value wins.
    if (has_pending_id and target.id.items.len == 0) {
        try target.id.appendSlice(gpa, pending.id.items);
    }
    if (has_pending_name and target.name.items.len == 0) {
        try target.name.appendSlice(gpa, pending.name.items);
    }
    if (has_pending_arguments) try target.arguments.appendSlice(gpa, pending.arguments.items);
    change.recordToolCall(physical);
}

fn parseToolCallFunction(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    pending: *ToolCallBuilder,
    has_pending_name: *bool,
    has_pending_arguments: *bool,
) !void {
    try expectObjectBegin(scanner);
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "name")) {
            _ = try appendStringValue(scanner, gpa, &pending.name, .reject_null);
            has_pending_name.* = true;
        } else if (std.mem.eql(u8, key, "arguments")) {
            _ = try appendStringValue(scanner, gpa, &pending.arguments, .reject_null);
            has_pending_arguments.* = true;
        } else {
            try scanner.skipValue();
        }
    }
}

fn expectObjectBegin(scanner: *Scanner) !void {
    const token = try scanner.next();
    if (token != .object_begin) return error.UnexpectedToken;
}

fn expectArrayBegin(scanner: *Scanner) !void {
    const token = try scanner.next();
    if (token != .array_begin) return error.UnexpectedToken;
}

fn nextObjectKey(scanner: *Scanner) !?[]const u8 {
    const token = try scanner.next();
    return switch (token) {
        .object_end => null,
        .string => |s| s,
        else => error.UnexpectedToken,
    };
}

fn nextInteger(scanner: *Scanner) !i64 {
    const token = try scanner.next();
    const text = switch (token) {
        .number => |s| s,
        else => return error.UnexpectedToken,
    };
    return try std.fmt.parseInt(i64, text, 10);
}

const NullStringPolicy = enum { allow_null, reject_null };

fn appendStringValue(
    scanner: *Scanner,
    gpa: std.mem.Allocator,
    list: *std.ArrayList(u8),
    null_policy: NullStringPolicy,
) !bool {
    while (true) {
        const token = try scanner.next();
        switch (token) {
            .null => switch (null_policy) {
                .allow_null => return false,
                .reject_null => return error.UnexpectedToken,
            },
            .string => |s| {
                try list.appendSlice(gpa, s);
                return true;
            },
            .partial_string => |s| try list.appendSlice(gpa, s),
            .partial_string_escaped_1 => |bytes| try list.appendSlice(gpa, &bytes),
            .partial_string_escaped_2 => |bytes| try list.appendSlice(gpa, &bytes),
            .partial_string_escaped_3 => |bytes| try list.appendSlice(gpa, &bytes),
            .partial_string_escaped_4 => |bytes| try list.appendSlice(gpa, &bytes),
            else => return error.UnexpectedToken,
        }
    }
}
