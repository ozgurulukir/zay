//! SSE event decoding and block accumulation for the Responses API.
//!
//! Extracted from responses_core.zig: parses SSE data events, extracts usage
//! information, tracks parallel function call deltas, and updates the assistant
//! message block state.

const std = @import("std");
const stream_part = @import("stream_part.zig");
const stream_parser = @import("stream_parser.zig");
const http = @import("../http.zig");
const log = std.log.scoped(.ai);

const ai = @import("../ai.zig");

pub const ToolBuilder = struct {
    call_id: std.ArrayList(u8) = .empty,
    item_id: std.ArrayList(u8) = .empty,
    output_index: ?u32 = null,
    block_index: u32 = 0,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *ToolBuilder, gpa: std.mem.Allocator) void {
        self.call_id.deinit(gpa);
        self.item_id.deinit(gpa);
        self.name.deinit(gpa);
        self.arguments.deinit(gpa);
        self.* = undefined;
    }
};

/// Terminal-event accumulators shared by `StreamState` and direct
/// `processEvent` callers. `completed` and `incomplete` are distinct on
/// purpose: a stream that ends with NEITHER is truncated
/// (`error.ResponseIncomplete`), while `response.incomplete` is a
/// deliberate provider termination that must surface as a normal Turn —
/// the partial output, usage, and `finish_reason` all belong to the caller
/// (the agent auto-continues `.length` cuts, mirroring chat-completions).
pub const Terminal = struct {
    completed: bool = false,
    incomplete: bool = false,
    usage: ?ai.Usage = null,
    finish_reason: ?ai.FinishReason = null,

    /// The one "stream reached a deliberate end" predicate. `finish()`'s
    /// gate and the codex websocket loop must stay in lockstep — both go
    /// through here so a future terminal condition can't update one site
    /// and not the other.
    pub fn isTerminal(self: Terminal) bool {
        return self.completed or self.incomplete;
    }
};
/// Uniform stream-adapter entry (the Responses counterpart of
/// `stream_parser.readStream`): drain the SSE source into a `StreamState`,
/// then finalise the turn. The transport calls this and never touches the
/// adapter's internal state, so event ownership stays here — the `errdefer`
/// below must not move out.
pub fn run(gpa: std.mem.Allocator, reader: *std.Io.Reader, observer: anytype, env: stream_part.StreamEnv) !ai.Turn {
    var state: StreamState = .{ .limits = env.limits };
    defer state.deinit(gpa);
    errdefer state.deinitBlocks(gpa);
    var call_seq = env.id_seq.*;
    var source: stream_part.Source = .{ .reader = reader };
    while (try source.next(gpa)) |data| {
        defer gpa.free(data);
        log.info("responses.response.sse data={s}", .{http.logBytesHead(data)});
        try state.processJson(gpa, data, observer, &call_seq);
    }
    const turn = try state.finish(gpa, &call_seq);
    env.id_seq.* = call_seq;
    return turn;
}

const TextPart = struct {
    content_index: u32,
    text: []u8,
};

const ItemRoute = struct {
    id: ?[]u8,
    output_index: ?u32,
    block_index: usize,
    kind: std.meta.Tag(ai.ContentBlock),
    text_parts: std.ArrayList(TextPart) = .empty,
};

pub const StreamState = struct {
    routes: std.ArrayList(ItemRoute) = .empty,
    blocks: std.ArrayList(ai.ContentBlock) = .empty,
    tools: std.ArrayList(ToolBuilder) = .empty,
    terminal: Terminal = .{},
    /// Shared stream policy (parallel-call cap + reject-log label) — the same
    /// struct the chat-completions parser takes, so the cap is no longer
    /// chat-only. Defaults keep existing tests and the codex websocket loop
    /// at the historical behaviour.
    limits: stream_part.StreamLimits = .{},
    /// Tool calls dropped because the parallel-call cap was hit; surfaced at
    /// `finish` so the caller can inform the model, mirroring the chat side.
    dropped: u32 = 0,

    pub fn deinit(self: *StreamState, gpa: std.mem.Allocator) void {
        for (self.routes.items) |*route| {
            if (route.id) |id| gpa.free(id);
            for (route.text_parts.items) |part| gpa.free(part.text);
            route.text_parts.deinit(gpa);
        }
        self.routes.deinit(gpa);
        for (self.tools.items) |*tool| tool.deinit(gpa);
        self.tools.deinit(gpa);
    }

    pub fn deinitBlocks(self: *StreamState, gpa: std.mem.Allocator) void {
        for (self.blocks.items) |*block| block.deinit(gpa);
        self.blocks.deinit(gpa);
    }

    pub fn processJson(self: *StreamState, gpa: std.mem.Allocator, data: []const u8, observer: anytype, call_seq: *u64) !void {
        try processEventRouted(gpa, data, &self.blocks, &self.tools, observer, call_seq, &self.terminal, self.limits, &self.dropped, &self.routes);
    }

    pub fn finish(self: *StreamState, gpa: std.mem.Allocator, call_seq: *u64) !ai.Turn {
        if (self.dropped > 0) {
            log.warn("readStream.dropped dropped={d} max_calls={d} model={s}", .{ self.dropped, self.limits.max_parallel_calls, self.limits.model_label });
        }
        if (!self.terminal.isTerminal()) return error.ResponseIncomplete;
        try syncToolBlocks(gpa, &self.blocks, self.tools.items, call_seq);
        const truncated = dropIncompleteToolBlocks(gpa, &self.blocks, self.tools.items, self.limits.model_label);
        const content = try self.blocks.toOwnedSlice(gpa);
        self.blocks = .empty;
        return .{ .assistant = .{ .assistant = .{ .content = content } }, .usage = self.terminal.usage, .finish_reason = self.terminal.finish_reason, .tool_calls_truncated = truncated };
    }
};

pub fn processEvent(
    gpa: std.mem.Allocator,
    data: []const u8,
    blocks: *std.ArrayList(ai.ContentBlock),
    tools: *std.ArrayList(ToolBuilder),
    observer: anytype,
    call_seq: *u64,
    terminal: *Terminal,
    limits: stream_part.StreamLimits,
    dropped: *u32,
) !void {
    return processEventRouted(gpa, data, blocks, tools, observer, call_seq, terminal, limits, dropped, null);
}

fn processEventRouted(
    gpa: std.mem.Allocator,
    data: []const u8,
    blocks: *std.ArrayList(ai.ContentBlock),
    tools: *std.ArrayList(ToolBuilder),
    observer: anytype,
    call_seq: *u64,
    terminal: *Terminal,
    limits: stream_part.StreamLimits,
    dropped: *u32,
    routes: ?*std.ArrayList(ItemRoute),
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const type_value = parsed.value.object.get("type") orelse return;
    if (type_value != .string) return;
    const event_type = responseEventFromString(type_value.string) orelse {
        log.warn("responses.response.ignored_event type={s}", .{type_value.string});
        return;
    };
    switch (event_type) {
        .provider_error => return error.ProviderError,
        .completed => {
            terminal.completed = true;
            terminal.usage = parseResponseUsage(parsed.value);
            return;
        },
        .incomplete => {
            terminal.incomplete = true;
            terminal.usage = parseResponseUsage(parsed.value);
            terminal.finish_reason = parseIncompleteReason(parsed.value);
            return;
        },
        .lifecycle => return,
        .output_item_added => {
            const before = blocks.items.len;
            try onItemAdded(gpa, parsed.value, blocks, tools, call_seq, limits, dropped);
            if (routes) |mapping| {
                if (blocks.items.len > before) {
                    const item = parsed.value.object.get("item").?;
                    const id = try optionalString(gpa, item, "id");
                    errdefer if (id) |bytes| gpa.free(bytes);
                    try mapping.append(gpa, .{ .id = id, .output_index = optionalU32(parsed.value, "output_index"), .block_index = before, .kind = std.meta.activeTag(blocks.items[before]) });
                }
            }
        },
        .content_part_added => {
            const part_kind = contentPartKind(parsed.value) orelse return;
            const block_kind = contentBlockTag(part_kind);
            if (hasItemIdentity(parsed.value)) {
                if (routes) |mapping| {
                    _ = try ensureItemRoute(gpa, parsed.value, blocks, tools, mapping, block_kind);
                    return;
                }
            }
            return onContentPartAdded(gpa, parsed.value, blocks, part_kind);
        },
        .output_text_delta => return onTextDelta(gpa, parsed.value, blocks, tools, observer, routes, .text),
        .refusal_delta => return onTextDelta(gpa, parsed.value, blocks, tools, observer, routes, .refusal),
        .reasoning_text_delta, .reasoning_summary_text_delta => return onReasoningDelta(gpa, parsed.value, blocks, observer, routes),
        .reasoning_summary_part_done => return onReasoningSummaryPartDone(gpa, parsed.value, blocks, observer, routes),
        .function_call_arguments_delta => return onArgumentsDelta(gpa, parsed.value, blocks, tools, observer),
        .function_call_arguments_done => return onArgumentsDone(gpa, parsed.value, blocks, tools, observer),
        .output_item_done => return onItemDone(gpa, parsed.value, blocks, tools, observer, routes),
    }
}

/// Extract `response.usage` from a `response.completed` event. Returns null
/// when the event carries no usage (e.g. the synthetic completed events in
/// tests). The Responses API names tokens `input_tokens`/`output_tokens`,
/// unlike Chat Completions — see `ai.Usage`.
pub fn parseResponseUsage(event: std.json.Value) ?ai.Usage {
    const response = event.object.get("response") orelse return null;
    if (response != .object) return null;
    const usage = response.object.get("usage") orelse return null;
    if (usage != .object) return null;
    return .{
        .input_tokens = usageInteger(usage, "input_tokens"),
        .output_tokens = usageInteger(usage, "output_tokens"),
        .total_tokens = usageInteger(usage, "total_tokens"),
        .cached_input_tokens = usageNestedInteger(usage, "input_tokens_details", "cached_tokens"),
        .reasoning_tokens = usageNestedInteger(usage, "output_tokens_details", "reasoning_tokens"),
    };
}

/// Map `response.incomplete_details.reason` onto `ai.FinishReason`,
/// mirroring the chat-completions string mapping: `max_output_tokens` is the
/// actionable one (the agent auto-continues it); every other or absent
/// reason is carried for observability only.
fn parseIncompleteReason(event: std.json.Value) ai.FinishReason {
    const response = event.object.get("response") orelse return .other;
    if (response != .object) return .other;
    const details = response.object.get("incomplete_details") orelse return .other;
    if (details != .object) return .other;
    const reason = details.object.get("reason") orelse return .other;
    if (reason != .string) return .other;
    if (std.mem.eql(u8, reason.string, "max_output_tokens")) return .length;
    if (std.mem.eql(u8, reason.string, "content_filter")) return .content_filter;
    return .other;
}

fn usageInteger(usage: std.json.Value, name: []const u8) u32 {
    const field = usage.object.get(name) orelse return 0;
    if (field != .integer) return 0;
    return ai.clampTokenCount(field.integer);
}

fn usageNestedInteger(usage: std.json.Value, object_name: []const u8, field_name: []const u8) u32 {
    const nested = usage.object.get(object_name) orelse return 0;
    if (nested != .object) return 0;
    const field = nested.object.get(field_name) orelse return 0;
    if (field != .integer) return 0;
    return ai.clampTokenCount(field.integer);
}

pub const ResponseEvent = enum {
    provider_error,
    completed,
    incomplete,
    lifecycle,
    output_item_added,
    content_part_added,
    output_text_delta,
    refusal_delta,
    reasoning_text_delta,
    reasoning_summary_text_delta,
    reasoning_summary_part_done,
    function_call_arguments_delta,
    function_call_arguments_done,
    output_item_done,
};

pub const ResponseEventSpec = struct {
    name: []const u8,
    event: ResponseEvent,
};

pub const response_event_specs = [_]ResponseEventSpec{
    .{ .name = "error", .event = .provider_error },
    .{ .name = "response.failed", .event = .provider_error },
    .{ .name = "response.completed", .event = .completed },
    // A deliberate provider termination carrying partial output + usage —
    // NOT a failure (response.failed stays ProviderError). The Turn must own
    // what streamed so the agent can auto-continue `max_output_tokens` cuts.
    .{ .name = "response.incomplete", .event = .incomplete },
    // Lifecycle/telemetry events carry no assistant content. Recognize them so
    // Codex does not turn normal WebSocket protocol traffic into warnings.
    .{ .name = "response.created", .event = .lifecycle },
    .{ .name = "response.in_progress", .event = .lifecycle },
    .{ .name = "response.content_part.done", .event = .lifecycle },
    .{ .name = "response.output_text.done", .event = .lifecycle },
    .{ .name = "response.reasoning_summary_part.added", .event = .lifecycle },
    .{ .name = "response.reasoning_summary_text.done", .event = .lifecycle },
    .{ .name = "codex.rate_limits", .event = .lifecycle },
    .{ .name = "codex.response.metadata", .event = .lifecycle },
    .{ .name = "responsesapi.websocket_timing", .event = .lifecycle },
    .{ .name = "response.output_item.added", .event = .output_item_added },
    .{ .name = "response.content_part.added", .event = .content_part_added },
    .{ .name = "response.output_text.delta", .event = .output_text_delta },
    .{ .name = "response.refusal.delta", .event = .refusal_delta },
    .{ .name = "response.reasoning_text.delta", .event = .reasoning_text_delta },
    .{ .name = "response.reasoning_summary_text.delta", .event = .reasoning_summary_text_delta },
    .{ .name = "response.reasoning_summary_part.done", .event = .reasoning_summary_part_done },
    .{ .name = "response.function_call_arguments.delta", .event = .function_call_arguments_delta },
    .{ .name = "response.function_call_arguments.done", .event = .function_call_arguments_done },
    .{ .name = "response.output_item.done", .event = .output_item_done },
};

pub fn responseEventFromString(name: []const u8) ?ResponseEvent {
    for (response_event_specs) |spec| {
        if (std.mem.eql(u8, name, spec.name)) return spec.event;
    }
    return null;
}

fn onItemAdded(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), tools: *std.ArrayList(ToolBuilder), call_seq: *u64, limits: stream_part.StreamLimits, dropped: *u32) !void {
    const item = value.object.get("item") orelse return;
    if (item != .object) return;
    const kind = item.object.get("type") orelse return;
    if (kind != .string) return;
    if (std.mem.eql(u8, kind.string, "message")) {
        var block: ai.ContentBlock = .{ .text = .{ .text = try gpa.alloc(u8, 0) } };
        errdefer block.deinit(gpa);
        block.text.responses_item_id = try optionalString(gpa, item, "id");
        block.text.responses_phase = try optionalString(gpa, item, "phase");
        try blocks.append(gpa, block);
    } else if (std.mem.eql(u8, kind.string, "reasoning")) {
        const raw = try std.json.Stringify.valueAlloc(gpa, item, .{});
        errdefer gpa.free(raw);
        try blocks.append(gpa, .{ .reasoning = .{ .text = try gpa.alloc(u8, 0), .responses_item_json = raw } });
    } else if (std.mem.eql(u8, kind.string, "function_call")) {
        // Same parallel-call cap as the chat-completions parser: a call at or
        // above the cap is dropped (counted) so the remaining calls can still
        // complete the turn.
        if (tools.items.len >= limits.max_parallel_calls) {
            dropped.* += 1;
            log.warn("parseToolCall.reject index={d} exceeds max_parallel_tool_calls={d} model={s}", .{ tools.items.len, limits.max_parallel_calls, limits.model_label });
            return;
        }
        var builder: ToolBuilder = .{};
        errdefer builder.deinit(gpa);
        builder.output_index = optionalU32(value, "output_index");
        if (try optionalString(gpa, item, "call_id")) |id| {
            defer gpa.free(id);
            try builder.call_id.appendSlice(gpa, id);
        }
        if (try optionalString(gpa, item, "id")) |id| {
            defer gpa.free(id);
            try builder.item_id.appendSlice(gpa, id);
        }
        if (try optionalString(gpa, item, "name")) |name| {
            defer gpa.free(name);
            try builder.name.appendSlice(gpa, name);
        }
        if (try optionalString(gpa, item, "arguments")) |args| {
            defer gpa.free(args);
            try builder.arguments.appendSlice(gpa, args);
        }
        if (builder.call_id.items.len == 0) {
            const minted = try std.fmt.allocPrint(gpa, "call_{d}", .{call_seq.*});
            defer gpa.free(minted);
            try builder.call_id.appendSlice(gpa, minted);
            call_seq.* += 1;
        }
        builder.block_index = @intCast(blocks.items.len);
        try blocks.append(gpa, .{ .tool_call = .{
            .call_id = .{ .value = try gpa.dupe(u8, builder.call_id.items) },
            .responses_item_id = if (builder.item_id.items.len > 0) try gpa.dupe(u8, builder.item_id.items) else null,
            .name = try gpa.dupe(u8, builder.name.items),
            .arguments = try gpa.dupe(u8, builder.arguments.items),
        } });
        try tools.append(gpa, builder);
    }
}

const ContentPartKind = enum { text, refusal };

fn onContentPartAdded(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), kind: ContentPartKind) !void {
    const part = value.object.get("part") orelse return;
    if (part != .object) return;
    if (contentPartKind(value) != kind) return;
    if (blocks.items.len > 0 and std.meta.activeTag(blocks.items[blocks.items.len - 1]) == contentBlockTag(kind)) return;
    try blocks.append(gpa, try emptyTextBlock(gpa, kind));
}
fn onItemDone(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), tools: *std.ArrayList(ToolBuilder), observer: anytype, routes: ?*std.ArrayList(ItemRoute)) !void {
    const item = value.object.get("item") orelse return;
    if (item != .object) return;
    const kind = item.object.get("type") orelse return;
    if (kind != .string) return;
    if (std.mem.eql(u8, kind.string, "message")) {
        const content = item.object.get("content") orelse return;
        if (content != .array) return;
        var text_seen = false;
        var refusal_seen = false;
        var first_kind: ?ContentPartKind = null;
        for (content.array.items) |part| {
            const part_kind = itemPartKind(part) orelse continue;
            if (first_kind == null) first_kind = part_kind;
            const already_seen = switch (part_kind) {
                .text => text_seen,
                .refusal => refusal_seen,
            };
            if (already_seen) continue;
            switch (part_kind) {
                .text => text_seen = true,
                .refusal => refusal_seen = true,
            }
            const text = try textFromItem(gpa, item, part_kind) orelse continue;
            defer gpa.free(text);
            const block_kind = contentBlockTag(part_kind);
            const index = resolveItemBlock(value, blocks.items, routes, block_kind) orelse
                try ensureItemRoute(gpa, value, blocks, tools, routes orelse return, block_kind);
            try updateTextBlockMetadata(gpa, blocks, index, item);
            if (textRoute(routes, index)) |route| {
                if (route.text_parts.items.len > 0) {
                    try finishTextParts(gpa, route, item, observer, part_kind);
                    const replacement = try gpa.dupe(u8, text);
                    const text_block = try textBlockAt(blocks, index);
                    gpa.free(text_block.text);
                    text_block.text = replacement;
                    continue;
                }
            }
            try finishTextBlock(gpa, blocks, observer, index, text);
        }
        // Delta arrival order cannot determine the final message's part order.
        if (routes) |mapping| {
            if (first_kind) |first| {
                const first_index = resolveItemBlock(value, blocks.items, routes, contentBlockTag(first)) orelse return;
                const second_kind: ContentPartKind = if (first == .text) .refusal else .text;
                const second_index = resolveItemBlock(value, blocks.items, routes, contentBlockTag(second_kind)) orelse return;
                if (first_index > second_index) {
                    std.mem.swap(ai.ContentBlock, &blocks.items[first_index], &blocks.items[second_index]);
                    for (mapping.items) |*route| {
                        if (route.block_index == first_index) {
                            route.block_index = second_index;
                        } else if (route.block_index == second_index) {
                            route.block_index = first_index;
                        }
                    }
                }
            }
        }
        return;
    }
    if (std.mem.eql(u8, kind.string, "reasoning")) {
        const index = resolveItemBlock(value, blocks.items, routes, .reasoning) orelse return;
        const raw = try std.json.Stringify.valueAlloc(gpa, item, .{});
        errdefer gpa.free(raw);
        if (blocks.items[index].reasoning.responses_item_json) |old| gpa.free(old);
        blocks.items[index].reasoning.responses_item_json = raw;
        return;
    }
    if (std.mem.eql(u8, kind.string, "function_call")) {
        const index = (try updateToolFromItem(gpa, item, tools.items)) orelse return;
        try syncOneToolBlock(gpa, blocks, &tools.items[index]);
        try observer.on_tool_delta(observer.ctx, .{ .index = index, .name = tools.items[index].name.items, .arguments = tools.items[index].arguments.items });
        try observer.on_delta_end(observer.ctx);
    }
}
fn contentPartKind(value: std.json.Value) ?ContentPartKind {
    const part = value.object.get("part") orelse return null;
    return itemPartKind(part);
}

fn itemPartKind(part: std.json.Value) ?ContentPartKind {
    if (part != .object) return null;
    const kind = stringField(part, "type") orelse return null;
    if (std.mem.eql(u8, kind, "output_text")) return .text;
    if (std.mem.eql(u8, kind, "refusal")) return .refusal;
    return null;
}

fn itemPartText(part: std.json.Value, part_kind: ContentPartKind) ?[]const u8 {
    if (itemPartKind(part) != part_kind) return null;
    return switch (part_kind) {
        .text => stringField(part, "text"),
        .refusal => stringField(part, "refusal"),
    };
}

fn textFromItem(gpa: std.mem.Allocator, item: std.json.Value, part_kind: ContentPartKind) !?[]u8 {
    const content = item.object.get("content") orelse return null;
    if (content != .array) return null;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var found = false;
    for (content.array.items) |part| {
        const value = itemPartText(part, part_kind) orelse continue;
        try text.appendSlice(gpa, value);
        found = true;
    }
    return if (found) try text.toOwnedSlice(gpa) else null;
}

fn contentBlockTag(kind: ContentPartKind) std.meta.Tag(ai.ContentBlock) {
    return switch (kind) {
        .text => .text,
        .refusal => .refusal,
    };
}

fn emptyTextBlock(gpa: std.mem.Allocator, kind: ContentPartKind) !ai.ContentBlock {
    const text = try gpa.alloc(u8, 0);
    return switch (kind) {
        .text => .{ .text = .{ .text = text } },
        .refusal => .{ .refusal = .{ .text = text } },
    };
}
fn onTextDelta(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), tools: *std.ArrayList(ToolBuilder), observer: anytype, routes: ?*std.ArrayList(ItemRoute), kind: ContentPartKind) !void {
    const delta = stringField(value, "delta") orelse return;
    const block_kind = contentBlockTag(kind);
    const index = if (resolveItemBlock(value, blocks.items, routes, block_kind)) |resolved|
        resolved
    else if (kind == .refusal and routes != null and hasItemIdentity(value))
        try ensureItemRoute(gpa, value, blocks, tools, routes.?, block_kind)
    else if (kind == .refusal) blk: {
        try blocks.append(gpa, try emptyTextBlock(gpa, kind));
        break :blk blocks.items.len - 1;
    } else return;
    if (textRoute(routes, index)) |route| {
        const part = try textPart(gpa, route, optionalU32(value, "content_index") orelse 0);
        part.text = try appendOwned(gpa, part.text, delta);
        var combined: std.ArrayList(u8) = .empty;
        defer combined.deinit(gpa);
        for (route.text_parts.items) |fragment| try combined.appendSlice(gpa, fragment.text);
        const replacement = try combined.toOwnedSlice(gpa);
        const text_block = try textBlockAt(blocks, index);
        gpa.free(text_block.text);
        text_block.text = replacement;
    } else {
        const text_block = try textBlockAt(blocks, index);
        text_block.text = try appendOwned(gpa, text_block.text, delta);
    }
    try observer.on_content(observer.ctx, delta);
    try observer.on_delta_end(observer.ctx);
}
fn textRoute(routes: ?*std.ArrayList(ItemRoute), block_index: usize) ?*ItemRoute {
    const mapping = routes orelse return null;
    for (mapping.items) |*route| if (route.block_index == block_index) return route;
    return null;
}

fn textPart(gpa: std.mem.Allocator, route: *ItemRoute, content_index: u32) !*TextPart {
    var position: usize = 0;
    while (position < route.text_parts.items.len) : (position += 1) {
        const part = &route.text_parts.items[position];
        if (part.content_index == content_index) return part;
        if (part.content_index > content_index) break;
    }
    const empty = try gpa.alloc(u8, 0);
    errdefer gpa.free(empty);
    try route.text_parts.insert(gpa, position, .{ .content_index = content_index, .text = empty });
    return &route.text_parts.items[position];
}

fn finishTextParts(gpa: std.mem.Allocator, route: *ItemRoute, item: std.json.Value, observer: anytype, part_kind: ContentPartKind) !void {
    const content = item.object.get("content") orelse return;
    if (content != .array) return;
    for (route.text_parts.items) |part| {
        if (part.content_index >= content.array.items.len) return error.ResponseContentMismatch;
        const final = itemPartText(content.array.items[part.content_index], part_kind) orelse return error.ResponseContentMismatch;
        if (!std.mem.startsWith(u8, final, part.text)) return error.ResponseContentMismatch;
    }
    for (content.array.items, 0..) |part, content_index| {
        const final = itemPartText(part, part_kind) orelse continue;
        const streamed = try textPart(gpa, route, @intCast(content_index));
        if (final.len < streamed.text.len) return error.ResponseContentMismatch;
        const suffix = final[streamed.text.len..];
        if (suffix.len == 0) continue;
        streamed.text = try appendOwned(gpa, streamed.text, suffix);
        try observer.on_content(observer.ctx, suffix);
        try observer.on_delta_end(observer.ctx);
    }
}
fn onReasoningDelta(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), observer: anytype, routes: ?*std.ArrayList(ItemRoute)) !void {
    const delta = stringField(value, "delta") orelse return;
    const index = resolveItemBlock(value, blocks.items, routes, .reasoning) orelse return;
    const old = blocks.items[index].reasoning.text;
    blocks.items[index].reasoning.text = try appendOwned(gpa, old, delta);
    try observer.on_reasoning(observer.ctx, delta);
    try observer.on_delta_end(observer.ctx);
}

fn onArgumentsDelta(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), tools: *std.ArrayList(ToolBuilder), observer: anytype) !void {
    const delta = stringField(value, "delta") orelse return;
    const index = toolIndexForEvent(value, tools.items) orelse return;
    try tools.items[index].arguments.appendSlice(gpa, delta);
    try syncOneToolBlock(gpa, blocks, &tools.items[index]);
    try observer.on_tool_delta(observer.ctx, .{ .index = index, .name = tools.items[index].name.items, .arguments = tools.items[index].arguments.items });
    try observer.on_delta_end(observer.ctx);
}

fn onArgumentsDone(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), tools: *std.ArrayList(ToolBuilder), observer: anytype) !void {
    const arguments = stringField(value, "arguments") orelse return;
    const index = toolIndexForEvent(value, tools.items) orelse return;
    tools.items[index].arguments.clearRetainingCapacity();
    try tools.items[index].arguments.appendSlice(gpa, arguments);
    try syncOneToolBlock(gpa, blocks, &tools.items[index]);
    try observer.on_tool_delta(observer.ctx, .{ .index = index, .name = tools.items[index].name.items, .arguments = tools.items[index].arguments.items });
    try observer.on_delta_end(observer.ctx);
}

fn toolIndexForEvent(value: std.json.Value, tools: []const ToolBuilder) ?u32 {
    if (tools.len == 0) return null;
    if (stringField(value, "item_id")) |item_id| {
        for (tools, 0..) |tool, index| {
            if (std.mem.eql(u8, tool.item_id.items, item_id)) return @intCast(index);
        }
    }
    if (stringField(value, "call_id")) |call_id| {
        for (tools, 0..) |tool, index| {
            if (std.mem.eql(u8, tool.call_id.items, call_id)) return @intCast(index);
        }
    }
    if (optionalU32(value, "output_index")) |output_index| {
        for (tools, 0..) |tool, index| {
            if (tool.output_index) |tool_output_index| {
                if (tool_output_index == output_index) return @intCast(index);
            }
        }
    }
    if (tools.len == 1) return 0;
    return null;
}

fn finishTextBlock(gpa: std.mem.Allocator, blocks: *std.ArrayList(ai.ContentBlock), observer: anytype, index: usize, text: []const u8) !void {
    const text_block = try textBlockAt(blocks, index);
    const old = text_block.text;
    if (!std.mem.startsWith(u8, text, old)) return error.ResponseContentMismatch;
    const suffix = text[old.len..];
    if (suffix.len == 0) return;
    text_block.text = try appendOwned(gpa, old, suffix);
    try observer.on_content(observer.ctx, suffix);
    try observer.on_delta_end(observer.ctx);
}

fn textBlockAt(blocks: *std.ArrayList(ai.ContentBlock), index: usize) !*ai.TextBlock {
    if (index >= blocks.items.len) return error.ResponseContentMismatch;
    return switch (blocks.items[index]) {
        .text => |*block| block,
        .refusal => |*block| block,
        else => error.ResponseContentMismatch,
    };
}

fn updateTextBlockMetadata(gpa: std.mem.Allocator, blocks: *std.ArrayList(ai.ContentBlock), index: usize, item: std.json.Value) !void {
    const phase = try optionalString(gpa, item, "phase");
    const text_block = try textBlockAt(blocks, index);
    if (text_block.responses_phase) |old| gpa.free(old);
    text_block.responses_phase = phase;
}
fn onReasoningSummaryPartDone(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), observer: anytype, routes: ?*std.ArrayList(ItemRoute)) !void {
    const index = resolveItemBlock(value, blocks.items, routes, .reasoning) orelse return;
    const old = blocks.items[index].reasoning.text;
    blocks.items[index].reasoning.text = try appendOwned(gpa, old, "\n\n");
    try observer.on_reasoning(observer.ctx, "\n\n");
    try observer.on_delta_end(observer.ctx);
}

fn ensureItemRoute(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), tools: *std.ArrayList(ToolBuilder), routes: *std.ArrayList(ItemRoute), kind: std.meta.Tag(ai.ContentBlock)) !usize {
    if (resolveItemBlock(value, blocks.items, routes, kind)) |index| return index;
    const item_id = eventItemId(value);
    const output_index = optionalU32(value, "output_index");
    var insert_index = blocks.items.len;
    if (kind == .refusal) {
        for (routes.items) |route| {
            if (route.kind != .text) continue;
            if (item_id) |requested| {
                const actual = route.id orelse continue;
                if (!std.mem.eql(u8, requested, actual)) continue;
            } else if (output_index) |requested| {
                if (route.output_index != requested) continue;
            } else continue;
            insert_index = route.block_index;
            break;
        }
    }
    // Reserve both containers before transferring ownership to either one.
    try blocks.ensureUnusedCapacity(gpa, 1);
    try routes.ensureUnusedCapacity(gpa, 1);
    const text = try gpa.alloc(u8, 0);
    errdefer gpa.free(text);
    const block_id = if (item_id) |id| try gpa.dupe(u8, id) else null;
    errdefer if (block_id) |id| gpa.free(id);
    const route_id = if (item_id) |id| try gpa.dupe(u8, id) else null;
    errdefer if (route_id) |id| gpa.free(id);
    const block: ai.ContentBlock = switch (kind) {
        .text => .{ .text = .{ .text = text, .responses_item_id = block_id } },
        .refusal => .{ .refusal = .{ .text = text, .responses_item_id = block_id } },
        else => return error.ResponseContentMismatch,
    };
    blocks.insertAssumeCapacity(insert_index, block);
    for (routes.items) |*route| {
        if (route.block_index >= insert_index) route.block_index += 1;
    }
    for (tools.items) |*tool| {
        if (tool.block_index >= insert_index) tool.block_index += 1;
    }
    routes.appendAssumeCapacity(.{ .id = route_id, .output_index = output_index, .block_index = insert_index, .kind = kind });
    return insert_index;
}

fn eventItemId(value: std.json.Value) ?[]const u8 {
    if (stringField(value, "item_id")) |id| return id;
    const item = value.object.get("item") orelse return null;
    if (item != .object) return null;
    return stringField(item, "id");
}

fn hasItemIdentity(value: std.json.Value) bool {
    return eventItemId(value) != null or optionalU32(value, "output_index") != null;
}

fn resolveItemBlock(value: std.json.Value, blocks: []const ai.ContentBlock, routes: ?*const std.ArrayList(ItemRoute), kind: std.meta.Tag(ai.ContentBlock)) ?usize {
    const id = eventItemId(value);
    const output_index = optionalU32(value, "output_index");
    if (id != null or output_index != null) {
        if (routes) |mapping| {
            for (mapping.items) |route| {
                if (id) |requested| {
                    const actual = route.id orelse continue;
                    if (!std.mem.eql(u8, requested, actual)) continue;
                }
                if (output_index) |requested| {
                    if (route.output_index != requested) continue;
                }
                if (route.kind != kind) continue;
                if (route.block_index >= blocks.len) return null;
                if (std.meta.activeTag(blocks[route.block_index]) != kind) continue;
                return route.block_index;
            }
            // An explicit unknown/mismatched identity cannot fall back to a
            // different item's latest block.
            return null;
        }
    }
    return switch (kind) {
        .text => lastTextBlock(blocks),
        .refusal => lastRefusalBlock(blocks),
        .reasoning => lastReasoningBlock(blocks),
        else => null,
    };
}

fn lastTextBlock(blocks: []const ai.ContentBlock) ?usize {
    var index = blocks.len;
    while (index > 0) {
        index -= 1;
        if (blocks[index] == .text) return index;
    }
    return null;
}

fn lastRefusalBlock(blocks: []const ai.ContentBlock) ?usize {
    var index = blocks.len;
    while (index > 0) {
        index -= 1;
        if (blocks[index] == .refusal) return index;
    }
    return null;
}

fn lastReasoningBlock(blocks: []const ai.ContentBlock) ?usize {
    var index = blocks.len;
    while (index > 0) {
        index -= 1;
        if (blocks[index] == .reasoning) return index;
    }
    return null;
}

fn updateToolFromItem(gpa: std.mem.Allocator, item: std.json.Value, tools: []ToolBuilder) !?u32 {
    const call_id = stringField(item, "call_id") orelse return null;
    for (tools, 0..) |*tool, index| {
        if (!std.mem.eql(u8, tool.call_id.items, call_id)) continue;
        if (stringField(item, "name")) |name| {
            tool.name.clearRetainingCapacity();
            try tool.name.appendSlice(gpa, name);
        }
        if (stringField(item, "arguments")) |arguments| {
            tool.arguments.clearRetainingCapacity();
            try tool.arguments.appendSlice(gpa, arguments);
        }
        return @intCast(index);
    }
    return null;
}

fn syncToolBlocks(gpa: std.mem.Allocator, blocks: *std.ArrayList(ai.ContentBlock), tools: []ToolBuilder, call_seq: *u64) !void {
    for (tools) |*tool| {
        if (tool.name.items.len == 0) continue;
        if (tool.call_id.items.len == 0) {
            const minted = try std.fmt.allocPrint(gpa, "call_{d}", .{call_seq.*});
            defer gpa.free(minted);
            try tool.call_id.appendSlice(gpa, minted);
            call_seq.* += 1;
        }
        try syncOneToolBlock(gpa, blocks, tool);
    }
}

fn syncOneToolBlock(gpa: std.mem.Allocator, blocks: *std.ArrayList(ai.ContentBlock), tool: *const ToolBuilder) !void {
    if (tool.block_index >= blocks.items.len) return;
    if (blocks.items[tool.block_index] != .tool_call) return;
    const block = &blocks.items[tool.block_index].tool_call;
    try replaceSlice(gpa, &block.call_id.value, tool.call_id.items);
    const next_item_id = if (tool.item_id.items.len > 0) try gpa.dupe(u8, tool.item_id.items) else null;
    if (block.responses_item_id) |id| gpa.free(id);
    block.responses_item_id = next_item_id;
    try replaceSlice(gpa, &block.name, tool.name.items);
    try replaceSlice(gpa, &block.arguments, tool.arguments.items);
}

/// Finish-time parity with the chat-completions parser: a named tool call
/// whose arguments never became executable (never streamed, or the JSON cut
/// mid-stream with no healing `done` event) is DROPPED — its eagerly
/// appended block removed and one truncation unit surfaced on the Turn, so
/// the agent's retry-once hint can fire (`tool_calls_truncated` fed the same
/// `argumentsAreExecutable` verdict the chat side uses). Nameless builders
/// (provider never sent a name) lose their orphan eager blocks too, but are
/// not counted — mirroring chat, which warns and skips them without
/// counting. On mask-allocation failure the count is still returned while
/// the blocks are kept: the degraded turn matches the pre-parity Responses
/// behaviour instead of fabricating a drop.
fn dropIncompleteToolBlocks(gpa: std.mem.Allocator, blocks: *std.ArrayList(ai.ContentBlock), tools: []const ToolBuilder, model_label: []const u8) u32 {
    var truncated: u32 = 0;
    var nameless: u32 = 0;
    for (tools) |*tool| {
        if (tool.block_index >= blocks.items.len) continue;
        if (blocks.items[tool.block_index] != .tool_call) continue;
        if (tool.name.items.len == 0) {
            nameless += 1;
        } else if (!stream_parser.argumentsAreExecutable(tool.arguments.items)) {
            truncated += 1;
        }
    }
    if (truncated == 0 and nameless == 0) return 0;

    const keep = gpa.alloc(bool, blocks.items.len) catch {
        // Degrade: the count still surfaces, but with blocks kept the
        // agent's retry-once hint is suppressed (it requires an empty tool
        // surface) and the malformed call dispatches into a structured
        // validation error — exactly the pre-parity Responses behaviour.
        log.warn("responses_events.truncated_count_only truncated={d} nameless={d} model={s} (mask OOM — blocks kept, hint suppressed)", .{ truncated, nameless, model_label });
        return truncated;
    };
    defer gpa.free(keep);
    @memset(keep, true);
    // Guards MUST mirror the counting loop above — the count and the drop
    // set must never diverge.
    for (tools) |*tool| {
        if (tool.block_index >= blocks.items.len) continue;
        if (blocks.items[tool.block_index] != .tool_call) continue;
        if (tool.name.items.len == 0 or !stream_parser.argumentsAreExecutable(tool.arguments.items)) {
            keep[tool.block_index] = false;
        }
    }

    var write: usize = 0;
    for (blocks.items, 0..) |*block, read| {
        if (keep[read]) {
            if (write != read) blocks.items[write] = block.*;
            write += 1;
        } else {
            block.deinit(gpa);
        }
    }
    blocks.shrinkRetainingCapacity(write);

    if (truncated > 0) log.warn("responses_events.truncated_tool_call_dropped dropped={d} model={s}", .{ truncated, model_label });
    if (nameless > 0) log.warn("responses_events.nameless_tool_call_dropped dropped={d} model={s}", .{ nameless, model_label });
    return truncated;
}

fn replaceSlice(gpa: std.mem.Allocator, target: *[]u8, source: []const u8) !void {
    const next = try gpa.dupe(u8, source);
    gpa.free(target.*);
    target.* = next;
}

fn appendOwned(gpa: std.mem.Allocator, old: []u8, suffix: []const u8) ![]u8 {
    const next = try gpa.alloc(u8, old.len + suffix.len);
    @memcpy(next[0..old.len], old);
    @memcpy(next[old.len..], suffix);
    gpa.free(old);
    return next;
}

fn optionalString(gpa: std.mem.Allocator, value: std.json.Value, name: []const u8) !?[]u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return null;
    return try gpa.dupe(u8, field.string);
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn optionalU32(value: std.json.Value, name: []const u8) ?u32 {
    const field = value.object.get(name) orelse return null;
    if (field != .integer) return null;
    if (field.integer < 0) return null;
    if (field.integer > std.math.maxInt(u32)) return null;
    return @intCast(field.integer);
}

test "openresponses emits final item text when no delta arrived" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    const Seen = struct {
        text: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.text.deinit(allocator);
        }

        fn onContent(ctx: *@This(), delta: []const u8) anyerror!void {
            try ctx.text.appendSlice(std.testing.allocator, delta);
        }
    };
    var seen: Seen = .{};
    defer seen.deinit(gpa);
    var observer = ai.noopObserver(Seen, &seen);
    observer.on_content = Seen.onContent;

    var call_seq: u64 = 0;
    var dropped: u32 = 0;
    _ = &dropped;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}", observer, &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello\"}]}}", observer, &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", observer, &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqualStrings("hello", seen.text.items);
    try std.testing.expectEqualStrings("hello", turn.assistant.assistant.content[0].text.text);
}

test "openresponses routes interleaved answers by item identity and preserves phases" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);
    var sequence: u64 = 0;
    const events = [_][]const u8{
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"a","phase":"commentary"}}
        ,
        \\{"type":"response.output_item.added","output_index":1,"item":{"type":"message","id":"b","phase":"final_answer"}}
        ,
        \\{"type":"response.output_text.delta","item_id":"a","output_index":0,"delta":"First"}
        ,
        \\{"type":"response.output_text.delta","output_index":1,"delta":"Last"}
        ,
        \\{"type":"response.output_text.delta","item_id":"missing","delta":"Wrong"}
        ,
        \\{"type":"response.output_text.delta","item_id":"a","output_index":1,"delta":"Wrong"}
        ,
        \\{"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"a","phase":"commentary","content":[{"type":"output_text","text":"First"},{"type":"output_text","text":" plus"}]}}
        ,
        \\{"type":"response.completed"}
        ,
    };
    for (events) |event| try state.processJson(gpa, event, ai.streamNoop(), &sequence);
    var turn = try state.finish(gpa, &sequence);
    defer turn.deinit(gpa);
    const blocks = turn.assistant.assistant.content;
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("First plus", blocks[0].text.text);
    try std.testing.expectEqualStrings("commentary", blocks[0].text.responses_phase.?);
    try std.testing.expectEqualStrings("Last", blocks[1].text.text);
    try std.testing.expectEqualStrings("final_answer", blocks[1].text.responses_phase.?);
}

test "openresponses routes reasoning and opaque snapshots to their own item" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);
    var sequence: u64 = 0;
    const events = [_][]const u8{
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"r1"}}
        ,
        \\{"type":"response.output_item.added","output_index":1,"item":{"type":"reasoning","id":"r2"}}
        ,
        \\{"type":"response.reasoning_summary_text.delta","item_id":"r1","delta":"First check"}
        ,
        \\{"type":"response.reasoning_summary_text.delta","output_index":1,"delta":"Second check"}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"r1","encrypted_content":"opaque"}}
        ,
        \\{"type":"response.completed"}
        ,
    };
    for (events) |event| try state.processJson(gpa, event, ai.streamNoop(), &sequence);
    var turn = try state.finish(gpa, &sequence);
    defer turn.deinit(gpa);
    const blocks = turn.assistant.assistant.content;
    try std.testing.expectEqualStrings("First check", blocks[0].reasoning.text);
    try std.testing.expectEqualStrings("Second check", blocks[1].reasoning.text);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].reasoning.responses_item_json.?, "opaque") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[1].reasoning.responses_item_json.?, "opaque") == null);
}

test "openresponses keeps interleaved content parts in canonical order" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);
    var sequence: u64 = 0;
    const events = [_][]const u8{
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"a"}}
        ,
        \\{"type":"response.output_text.delta","item_id":"a","content_index":1,"delta":"Last"}
        ,
        \\{"type":"response.output_text.delta","item_id":"a","content_index":0,"delta":"First"}
        ,
    };
    for (events) |event| try state.processJson(gpa, event, ai.streamNoop(), &sequence);
    try std.testing.expectEqualStrings("FirstLast", state.blocks.items[0].text.text);
    try state.processJson(gpa,
        \\{"type":"response.output_item.done","item":{"type":"message","id":"a","content":[{"type":"output_text","text":"First"},{"type":"output_text","text":"Last"}]}}
    , ai.streamNoop(), &sequence);
    try std.testing.expectEqualStrings("FirstLast", state.blocks.items[0].text.text);
}

test "openresponses snapshots fill earlier unstreamed content parts" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);
    const Seen = struct {
        text: std.ArrayList(u8) = .empty,

        fn onContent(self: *@This(), delta: []const u8) anyerror!void {
            try self.text.appendSlice(std.testing.allocator, delta);
        }
    };
    var seen: Seen = .{};
    defer seen.text.deinit(gpa);
    var observer = ai.noopObserver(Seen, &seen);
    observer.on_content = Seen.onContent;
    var sequence: u64 = 0;
    try state.processJson(gpa,
        \\{"type":"response.output_item.added","item":{"type":"message","id":"a"}}
    , observer, &sequence);
    try state.processJson(gpa,
        \\{"type":"response.output_text.delta","item_id":"a","content_index":1,"delta":"Last"}
    , observer, &sequence);
    try state.processJson(gpa,
        \\{"type":"response.output_item.done","item":{"type":"message","id":"a","content":[{"type":"refusal","refusal":"First"},{"type":"output_text","text":"Last plus"}]}}
    , observer, &sequence);
    try std.testing.expectEqual(@as(usize, 2), state.blocks.items.len);
    try std.testing.expectEqualStrings("First", state.blocks.items[0].refusal.text);
    try std.testing.expectEqualStrings("Last plus", state.blocks.items[1].text.text);
    try std.testing.expectEqualStrings("LastFirst plus", seen.text.items);
    try state.processJson(gpa,
        \\{"type":"response.output_item.done","item":{"type":"message","id":"a","content":[{"type":"refusal","refusal":"First"},{"type":"output_text","text":"Last plus"}]}}
    , observer, &sequence);
    try std.testing.expectEqualStrings("LastFirst plus", seen.text.items);
    try std.testing.expectError(error.ResponseContentMismatch, state.processJson(gpa,
        \\{"type":"response.output_item.done","item":{"type":"message","id":"a","content":[{"type":"refusal","refusal":"First"},{"type":"output_text","text":"Wrong"}]}}
    , observer, &sequence));
    try std.testing.expectEqualStrings("First", state.blocks.items[0].refusal.text);
    try std.testing.expectEqualStrings("Last plus", state.blocks.items[1].text.text);
    try std.testing.expectEqualStrings("LastFirst plus", seen.text.items);
}

test "openresponses refusal deltas remain separate from prose" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);
    var sequence: u64 = 0;

    try state.processJson(gpa,
        \\{"type":"response.output_item.added","item":{"type":"message","id":"refusal-item"}}
    , ai.streamNoop(), &sequence);
    try state.processJson(gpa,
        \\{"type":"response.refusal.delta","item_id":"refusal-item","delta":"No"}
    , ai.streamNoop(), &sequence);
    try state.processJson(gpa,
        \\{"type":"response.refusal.delta","item_id":"refusal-item","delta":" thanks"}
    , ai.streamNoop(), &sequence);
    try state.processJson(gpa,
        \\{"type":"response.output_text.delta","item_id":"refusal-item","content_index":1,"delta":"Safe alternative"}
    , ai.streamNoop(), &sequence);
    try state.processJson(gpa,
        \\{"type":"response.output_item.done","item":{"type":"message","id":"refusal-item","content":[{"type":"refusal","refusal":"No thanks"},{"type":"output_text","text":"Safe alternative"}]}}
    , ai.streamNoop(), &sequence);

    try std.testing.expectEqual(@as(usize, 2), state.blocks.items.len);
    try std.testing.expectEqualStrings("No thanks", state.blocks.items[0].refusal.text);
    try std.testing.expectEqualStrings("Safe alternative", state.blocks.items[1].text.text);
}

test "openresponses refusal insertion preserves pending tool block indexes" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);
    var sequence: u64 = 0;

    try state.processJson(gpa,
        \\{"type":"response.output_item.added","item":{"type":"message","id":"message"}}
    , ai.streamNoop(), &sequence);
    try state.processJson(gpa,
        \\{"type":"response.output_item.added","item":{"type":"function_call","id":"tool","call_id":"call","name":"bash"}}
    , ai.streamNoop(), &sequence);
    try state.processJson(gpa,
        \\{"type":"response.refusal.delta","item_id":"message","delta":"Declined"}
    , ai.streamNoop(), &sequence);
    try state.processJson(gpa,
        \\{"type":"response.function_call_arguments.delta","item_id":"tool","delta":"{}"}
    , ai.streamNoop(), &sequence);

    try std.testing.expectEqual(@as(usize, 2), state.tools.items[0].block_index);
    try std.testing.expectEqualStrings("{}", state.blocks.items[2].tool_call.arguments);
    try state.processJson(gpa,
        \\{"type":"response.completed"}
    , ai.streamNoop(), &sequence);
    var turn = try state.finish(gpa, &sequence);
    defer turn.deinit(gpa);
    try std.testing.expectEqualStrings("{}", turn.assistant.assistant.content[2].tool_call.arguments);
}

test "openresponses final snapshot orders prose before refusal and preserves routes" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);
    var sequence: u64 = 0;

    try state.processJson(gpa,
        \\{"type":"response.output_item.added","item":{"type":"message","id":"message"}}
    , ai.streamNoop(), &sequence);
    try state.processJson(gpa,
        \\{"type":"response.refusal.delta","item_id":"message","content_index":1,"delta":"Declined"}
    , ai.streamNoop(), &sequence);
    try state.processJson(gpa,
        \\{"type":"response.output_text.delta","item_id":"message","content_index":0,"delta":"Alternative"}
    , ai.streamNoop(), &sequence);
    const snapshot =
        \\{"type":"response.output_item.done","item":{"type":"message","id":"message","content":[{"type":"output_text","text":"Alternative"},{"type":"refusal","refusal":"Declined"}]}}
    ;
    try state.processJson(gpa, snapshot, ai.streamNoop(), &sequence);
    try std.testing.expectEqualStrings("Alternative", state.blocks.items[0].text.text);
    try std.testing.expectEqualStrings("Declined", state.blocks.items[1].refusal.text);
    // Repeated snapshots still resolve both kinds to the correct blocks.
    try state.processJson(gpa, snapshot, ai.streamNoop(), &sequence);
    try std.testing.expectEqualStrings("Alternative", state.blocks.items[0].text.text);
    try std.testing.expectEqualStrings("Declined", state.blocks.items[1].refusal.text);
}

test "ensureItemRoute allocation failures never transfer partial ownership" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"item_id":"message"}
    , .{});
    defer parsed.deinit();

    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var state: StreamState = .{};
        defer state.deinit(gpa);
        defer state.deinitBlocks(gpa);
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const result = ensureItemRoute(failing.allocator(), parsed.value, &state.blocks, &state.tools, &state.routes, .refusal);
        if (result) |index| {
            try std.testing.expectEqual(@as(usize, 0), index);
            try std.testing.expectEqual(@as(usize, 1), state.blocks.items.len);
            try std.testing.expectEqual(@as(usize, 1), state.routes.items.len);
            return;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), state.blocks.items.len);
            try std.testing.expectEqual(@as(usize, 0), state.routes.items.len);
        }
    }
    return error.TestUnexpectedResult;
}

test "openresponses final snapshot preserves refusal block type" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);
    var sequence: u64 = 0;

    try state.processJson(gpa,
        \\{"type":"response.output_item.added","item":{"type":"message","id":"snapshot-refusal"}}
    , ai.streamNoop(), &sequence);
    try state.processJson(gpa,
        \\{"type":"response.output_item.done","item":{"type":"message","id":"snapshot-refusal","content":[{"type":"refusal","refusal":"Declined"},{"type":"output_text","text":"Try this instead"}]}}
    , ai.streamNoop(), &sequence);

    try std.testing.expectEqual(@as(usize, 2), state.blocks.items.len);
    try std.testing.expectEqualStrings("Declined", state.blocks.items[0].refusal.text);
    try std.testing.expectEqualStrings("Try this instead", state.blocks.items[1].text.text);
}

test "openresponses rejects snapshots that contradict already streamed answer bytes" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);
    var sequence: u64 = 0;
    try state.processJson(gpa,
        \\{"type":"response.output_item.added","item":{"type":"message","id":"a"}}
    , ai.streamNoop(), &sequence);
    try state.processJson(gpa,
        \\{"type":"response.output_text.delta","item_id":"a","delta":"Answer"}
    , ai.streamNoop(), &sequence);
    try std.testing.expectError(error.ResponseContentMismatch, state.processJson(gpa,
        \\{"type":"response.output_item.done","item":{"type":"message","id":"a","content":[{"type":"output_text","text":"Different"}]}}
    , ai.streamNoop(), &sequence));
    try std.testing.expectEqualStrings("Answer", state.blocks.items[0].text.text);
}

test "openresponses preserves text tool text block order" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    var dropped: u32 = 0;
    _ = &dropped;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_text.delta\",\"delta\":\"before\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_a\",\"id\":\"item_a\",\"name\":\"bash\",\"arguments\":\"{}\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.done\",\"output_index\":1,\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_text.delta\",\"delta\":\"after\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), turn.assistant.assistant.content.len);
    try std.testing.expectEqualStrings("before", turn.assistant.assistant.content[0].text.text);
    try std.testing.expectEqualStrings("bash", turn.assistant.assistant.content[1].tool_call.name);
    try std.testing.expectEqualStrings("after", turn.assistant.assistant.content[2].text.text);
}

test "openresponses parses usage from completed event" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    var dropped: u32 = 0;
    _ = &dropped;
    try state.processJson(gpa, "{\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":2000,\"input_tokens_details\":{\"cached_tokens\":1500},\"output_tokens\":420,\"output_tokens_details\":{\"reasoning_tokens\":256},\"total_tokens\":2420}}}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expect(turn.usage != null);
    try std.testing.expectEqual(@as(u32, 2000), turn.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u32, 1500), turn.usage.?.cached_input_tokens);
    try std.testing.expectEqual(@as(u32, 420), turn.usage.?.output_tokens);
    try std.testing.expectEqual(@as(u32, 256), turn.usage.?.reasoning_tokens);
    try std.testing.expectEqual(@as(u32, 2420), turn.usage.?.total_tokens);
}

test "openresponses completed event without usage leaves null" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    var dropped: u32 = 0;
    _ = &dropped;
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expect(turn.usage == null);
}

test "openresponses incomplete event yields a Turn carrying the length reason" {
    // `response.incomplete` is a deliberate termination, not a failure: the
    // partial output + usage must land in a normal Turn with
    // finish_reason == .length so the agent's auto-continue applies
    // (mirroring chat-completions finish_reason handling).
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    var dropped: u32 = 0;
    _ = &dropped;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_text.delta\",\"delta\":\"halfway plan...\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"usage\":{\"input_tokens\":1200,\"output_tokens\":4096,\"total_tokens\":5296}}}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(ai.FinishReason.length, turn.finish_reason.?);
    try std.testing.expectEqual(@as(u32, 1200), turn.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u32, 4096), turn.usage.?.output_tokens);
    try std.testing.expectEqual(@as(usize, 1), turn.assistant.assistant.content.len);
    try std.testing.expect(turn.assistant.assistant.content[0] == .text);
    try std.testing.expectEqualStrings("halfway plan...", turn.assistant.assistant.content[0].text.text);
}

test "openresponses incomplete maps content_filter and absent reasons" {
    const gpa = std.testing.allocator;
    var call_seq: u64 = 0;
    var dropped: u32 = 0;
    _ = &dropped;

    var filtered: StreamState = .{};
    defer filtered.deinit(gpa);
    defer filtered.deinitBlocks(gpa);
    try filtered.processJson(gpa, "{\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"content_filter\"}}}", ai.streamNoop(), &call_seq);
    var filtered_turn = try filtered.finish(gpa, &call_seq);
    defer filtered_turn.deinit(gpa);
    try std.testing.expectEqual(ai.FinishReason.content_filter, filtered_turn.finish_reason.?);

    var bare: StreamState = .{};
    defer bare.deinit(gpa);
    defer bare.deinitBlocks(gpa);
    try bare.processJson(gpa, "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\"}}", ai.streamNoop(), &call_seq);
    var bare_turn = try bare.finish(gpa, &call_seq);
    defer bare_turn.deinit(gpa);
    try std.testing.expectEqual(ai.FinishReason.other, bare_turn.finish_reason.?);
}

test "openresponses routes parallel argument deltas by output index" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    var dropped: u32 = 0;
    _ = &dropped;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_a\",\"id\":\"item_a\",\"name\":\"bash\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_b\",\"id\":\"item_b\",\"name\":\"bash\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\\\"command\\\":\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{\\\"path\\\":\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"\\\"pwd\\\"}\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"\\\"src/main.zig\\\"}\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), turn.assistant.assistant.content.len);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", turn.assistant.assistant.content[0].tool_call.arguments);
    try std.testing.expectEqualStrings("{\"path\":\"src/main.zig\"}", turn.assistant.assistant.content[1].tool_call.arguments);
    try std.testing.expectEqualStrings("bash", turn.assistant.assistant.content[1].tool_call.name);
}

test "openresponses drops function calls above the parallel-call cap" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{ .limits = .{ .max_parallel_calls = 2, .model_label = "cap-test" } };
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_a\",\"id\":\"item_a\",\"name\":\"bash\",\"arguments\":\"{}\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_b\",\"id\":\"item_b\",\"name\":\"bash\",\"arguments\":\"{}\"}}", ai.streamNoop(), &call_seq);
    // At the cap: this call is dropped (counted, warn-logged at finish) so
    // the already-accepted calls still complete the turn — same policy as
    // the chat-completions parser.
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":2,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_c\",\"id\":\"item_c\",\"name\":\"bash\",\"arguments\":\"{}\"}}", ai.streamNoop(), &call_seq);
    try std.testing.expectEqual(@as(u32, 1), state.dropped);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), turn.assistant.assistant.content.len);
    try std.testing.expectEqualStrings("call_a", turn.assistant.assistant.content[0].tool_call.call_id.slice());
    try std.testing.expectEqualStrings("call_b", turn.assistant.assistant.content[1].tool_call.call_id.slice());
}

test "processEvent ignores malformed JSON payloads gracefully" {
    const gpa = std.testing.allocator;
    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    defer blocks.deinit(gpa);
    var tools: std.ArrayList(ToolBuilder) = .empty;
    defer tools.deinit(gpa);
    var terminal: Terminal = .{};
    var call_seq: u64 = 0;
    var dropped: u32 = 0;
    _ = &dropped;

    // Truncated / broken JSON should not error or crash
    try processEvent(gpa, "{\"type\": \"response.output_text.delta\", \"delta\":", &blocks, &tools, ai.streamNoop(), &call_seq, &terminal, .{}, &dropped);
    try std.testing.expectEqual(@as(usize, 0), blocks.items.len);
    try std.testing.expectEqual(false, terminal.completed);
}

test "processEvent ignores unknown event types without error" {
    const gpa = std.testing.allocator;
    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    defer blocks.deinit(gpa);
    var tools: std.ArrayList(ToolBuilder) = .empty;
    defer tools.deinit(gpa);
    var terminal: Terminal = .{};
    var call_seq: u64 = 0;
    var dropped: u32 = 0;
    _ = &dropped;

    try processEvent(gpa, "{\"type\": \"custom_vendor.telemetry_heartbeat\"}", &blocks, &tools, ai.streamNoop(), &call_seq, &terminal, .{}, &dropped);
    try std.testing.expectEqual(false, terminal.completed);
    try std.testing.expectEqual(@as(usize, 0), blocks.items.len);
}

test "processEvent treats Codex lifecycle events as recognized no-ops" {
    const gpa = std.testing.allocator;
    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    defer blocks.deinit(gpa);
    var tools: std.ArrayList(ToolBuilder) = .empty;
    defer tools.deinit(gpa);
    var terminal: Terminal = .{};
    var call_seq: u64 = 0;
    var dropped: u32 = 0;
    _ = &dropped;

    const events = [_][]const u8{
        "{\"type\":\"response.created\"}",
        "{\"type\":\"response.in_progress\"}",
        "{\"type\":\"response.reasoning_summary_part.added\"}",
        "{\"type\":\"response.reasoning_summary_text.done\"}",
        "{\"type\":\"response.output_text.done\"}",
        "{\"type\":\"response.content_part.done\"}",
        "{\"type\":\"codex.rate_limits\"}",
        "{\"type\":\"codex.response.metadata\"}",
        "{\"type\":\"responsesapi.websocket_timing\"}",
    };
    for (events) |event| {
        const type_start = std.mem.indexOf(u8, event, "\"type\":\"").? + "\"type\":\"".len;
        const type_end = std.mem.indexOfPos(u8, event, type_start, "\"").?;
        try std.testing.expectEqual(ResponseEvent.lifecycle, responseEventFromString(event[type_start..type_end]).?);
        try processEvent(gpa, event, &blocks, &tools, ai.streamNoop(), &call_seq, &terminal, .{}, &dropped);
    }
    try std.testing.expect(!terminal.completed);
    try std.testing.expectEqual(@as(usize, 0), blocks.items.len);
}

test "processEvent returns ProviderError on error event" {
    const gpa = std.testing.allocator;
    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    defer blocks.deinit(gpa);
    var tools: std.ArrayList(ToolBuilder) = .empty;
    defer tools.deinit(gpa);
    var terminal: Terminal = .{};
    var call_seq: u64 = 0;
    var dropped: u32 = 0;
    _ = &dropped;

    const result = processEvent(gpa, "{\"type\": \"error\", \"error\": {\"message\": \"Rate limit exceeded\"}}", &blocks, &tools, ai.streamNoop(), &call_seq, &terminal, .{}, &dropped);
    try std.testing.expectError(error.ProviderError, result);
}

test "processEvent reassembles split multi-byte UTF-8 deltas" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    var dropped: u32 = 0;
    _ = &dropped;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_utf8\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_text.delta\",\"delta\":\"Hello 🚀 \"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_text.delta\",\"delta\":\"World! ✨\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), turn.assistant.assistant.content.len);
    try std.testing.expectEqualStrings("Hello 🚀 World! ✨", turn.assistant.assistant.content[0].text.text);
}

test "parseResponseUsage handles malformed and out-of-bound usage values safely" {
    const gpa = std.testing.allocator;

    // 1. Negative counts clamp to 0
    {
        const json = "{\"response\":{\"usage\":{\"input_tokens\":-50,\"output_tokens\":-10,\"total_tokens\":-60}}}";
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
        defer parsed.deinit();
        const usage = parseResponseUsage(parsed.value);
        try std.testing.expect(usage != null);
        try std.testing.expectEqual(@as(u32, 0), usage.?.input_tokens);
        try std.testing.expectEqual(@as(u32, 0), usage.?.output_tokens);
        try std.testing.expectEqual(@as(u32, 0), usage.?.total_tokens);
    }

    // 2. Non-integer types fallback to 0
    {
        const json = "{\"response\":{\"usage\":{\"input_tokens\":\"1000\",\"output_tokens\":true,\"input_tokens_details\":\"invalid_shape\"}}}";
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
        defer parsed.deinit();
        const usage = parseResponseUsage(parsed.value);
        try std.testing.expect(usage != null);
        try std.testing.expectEqual(@as(u32, 0), usage.?.input_tokens);
        try std.testing.expectEqual(@as(u32, 0), usage.?.output_tokens);
        try std.testing.expectEqual(@as(u32, 0), usage.?.cached_input_tokens);
    }
}

test "processEvent mints synthetic call_id when omitted from tool call" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 42;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), turn.assistant.assistant.content.len);
    try std.testing.expectEqualStrings("call_42", turn.assistant.assistant.content[0].tool_call.call_id.slice());
    try std.testing.expectEqualStrings("bash", turn.assistant.assistant.content[0].tool_call.name);
    try std.testing.expectEqual(@as(u64, 43), call_seq);
}

test "finish returns ResponseIncomplete error when stream ends before completed event" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    var dropped: u32 = 0;
    _ = &dropped;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_text.delta\",\"delta\":\"halfway content...\"}", ai.streamNoop(), &call_seq);

    // Call finish without response.completed
    const finish_result = state.finish(gpa, &call_seq);
    try std.testing.expectError(error.ResponseIncomplete, finish_result);
}

test "processEvent handles response.failed as ProviderError" {
    const gpa = std.testing.allocator;
    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    defer blocks.deinit(gpa);
    var tools: std.ArrayList(ToolBuilder) = .empty;
    defer tools.deinit(gpa);
    var terminal: Terminal = .{};
    var call_seq: u64 = 0;
    var dropped: u32 = 0;
    _ = &dropped;

    const result = processEvent(gpa, "{\"type\":\"response.failed\",\"response\":{\"status_details\":{\"error\":{\"message\":\"Server overload\"}}}}", &blocks, &tools, ai.streamNoop(), &call_seq, &terminal, .{}, &dropped);
    try std.testing.expectError(error.ProviderError, result);
}

test "finish drops a named responses tool call whose arguments never streamed" {
    // Parity with the chat parser: name+id arrived, the arguments payload
    // never did — the eager block is removed and the count surfaces so the
    // agent's retry-once hint fires.
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_a\",\"id\":\"item_a\",\"name\":\"bash\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), turn.tool_calls_truncated);
    try std.testing.expectEqual(@as(usize, 0), turn.assistant.assistant.content.len);
}

test "finish keeps a deliberate empty-object arguments call" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_a\",\"id\":\"item_a\",\"name\":\"bash\",\"arguments\":\"{}\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), turn.tool_calls_truncated);
    try std.testing.expectEqual(@as(usize, 1), turn.assistant.assistant.content.len);
    try std.testing.expectEqualStrings("{}", turn.assistant.assistant.content[0].tool_call.arguments);
}

test "finish drops a named call whose arguments JSON is cut mid-stream" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_a\",\"id\":\"item_a\",\"name\":\"bash\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\\\"comm\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), turn.tool_calls_truncated);
    try std.testing.expectEqual(@as(usize, 0), turn.assistant.assistant.content.len);
}

test "a full-arguments done event heals partial deltas before the truncation verdict" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_a\",\"id\":\"item_a\",\"name\":\"bash\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\\\"comm\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    // The done event replaced the partial args wholesale — the same intent
    // as chat's joinSeveredArguments pre-pass.
    try std.testing.expectEqual(@as(u32, 0), turn.tool_calls_truncated);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", turn.assistant.assistant.content[0].tool_call.arguments);
}

test "finish drops a nameless builder's orphan block without counting it" {
    // Chat parity: a provider that never sent the name is dropped silently
    // (no truncation unit) — the Responses-side orphan eager block goes too.
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_a\",\"id\":\"item_a\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), turn.tool_calls_truncated);
    try std.testing.expectEqual(@as(usize, 0), turn.assistant.assistant.content.len);
}

test "dropIncompleteToolBlocks degrades to count-only when the mask allocation fails" {
    // The keep-mask is dropIncompleteToolBlocks' first allocation, so a
    // FailingAllocator with fail_index 0 lands exactly on it (the fixtures
    // are built with the real allocator first): the count must still
    // surface while the block is KEPT — the degraded turn dispatches the
    // malformed call into a structured validation error, the pre-parity
    // behaviour.
    const gpa = std.testing.allocator;
    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    defer {
        for (blocks.items) |*block| block.deinit(gpa);
        blocks.deinit(gpa);
    }
    try blocks.append(gpa, .{ .tool_call = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_a") },
        .name = try gpa.dupe(u8, "bash"),
        .arguments = try gpa.dupe(u8, ""),
    } });

    var tools: std.ArrayList(ToolBuilder) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(gpa);
        tools.deinit(gpa);
    }
    var builder: ToolBuilder = .{};
    try builder.call_id.appendSlice(gpa, "call_a");
    try builder.name.appendSlice(gpa, "bash");
    // `arguments` stays empty — the severed signature.
    try tools.append(gpa, builder);

    // Degrade path: the mask allocation fails, blocks are kept.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectEqual(@as(u32, 1), dropIncompleteToolBlocks(failing.allocator(), &blocks, tools.items, "oom-test"));
    try std.testing.expectEqual(@as(usize, 1), blocks.items.len);

    // Healthy path: the same call is dropped and the block removed.
    try std.testing.expectEqual(@as(u32, 1), dropIncompleteToolBlocks(gpa, &blocks, tools.items, "parity-test"));
    try std.testing.expectEqual(@as(usize, 0), blocks.items.len);
}
