//! context_prune.zig — historical tool-result pruning, history image eviction,
//! and pruned-request token estimates.
//!
//! Split out of `context/assembly.zig` (strangler-fig; `assembly.zig` remains
//! the re-export umbrella callers import). Historical Tool Result Pruning
//! (Context Compression for Active Turns): keeps recent tool outputs in full,
//! while capping/truncating ancient tool outputs in the prompt to prevent
//! context bloat. Also the #122 image eviction pass, which replaces image
//! blocks in older user messages with deterministic re-mention stubs.

const std = @import("std");
const ai = @import("../ai.zig");
const tools_common = @import("../tools/common.zig");
const output_policy = @import("../tools/output_policy.zig");
const compaction = @import("compaction.zig");
const SkillContext = @import("skill_context.zig").SkillContext;
const skill_history = @import("skill_history.zig");

const assert = std.debug.assert;

/// Shared tool-result byte limit used at the model boundary and by historical pruning.
/// Mirrored as `config.CompactionSettings.tool_output_cap_bytes`
/// (`context.compaction.toolOutputCapBytes`).
pub const default_historical_tool_cap_bytes: u32 = output_policy.default_tool_output_cap_bytes;
/// Number of recent tool result turns left alone by historical pruning.
/// Mirrored as the `config.CompactionSettings.keep_recent_tool_turns` default
/// (`context.compaction.keepRecentToolTurns`).
pub const default_keep_recent_tool_turns: u32 = 12;
/// Count tool result turns backwards from the end of `messages` and return the
/// index at which historical pruning begins: everything at `idx < cutoff` is a
/// tool turn older than the `keep_recent_tool_turns` most recent ones.
/// Messages at `>= cutoff` are kept in full.
///
/// A "turn" is a contiguous run of `.tool` messages — the results of one
/// assistant batch, which `takeToolResults` appends contiguously. The count
/// increments only at the end of a run, so a parallel batch is never split:
/// the `(keep+1)`-th run is pruned whole.
fn computeCutoff(messages: []const ai.ChatMessage, keep_recent_tool_turns: u32) ?usize {
    var tool_turns_seen: u32 = 0;
    var cutoff_index: ?usize = null;
    var i: usize = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i] == .tool) {
            const run_end = i + 1 >= messages.len or messages[i + 1] != .tool;
            if (run_end) tool_turns_seen += 1;
            if (tool_turns_seen > keep_recent_tool_turns and cutoff_index == null) {
                cutoff_index = i + 1; // Everything before cutoff_index is historical
            }
        }
    }
    return cutoff_index;
}

/// Cache of pruned historical tool messages across run-loop iterations (TD-13).
///
/// Keys are message indices in ContextManager. Stored values are heap-allocated
/// `*ai.ChatMessage` pointers, guaranteeing pointer stability even when the
/// hash map resizes. Unchanged historical tool results are served directly from
/// this cache without re-running `pruneSingleToolMessage` or re-allocating
/// strings.
///
/// Invalidated on `clearNonSystemMessages` (compaction swap, branch switch,
/// session reload) or when `historical_tool_cap_bytes` changes.
pub const PrunedToolCache = struct {
    entries: std.AutoHashMapUnmanaged(usize, *ai.ChatMessage) = .empty,
    cached_cap_bytes: u32 = 0,

    pub fn deinit(self: *PrunedToolCache, gpa: std.mem.Allocator) void {
        self.clear(gpa);
        self.entries.deinit(gpa);
    }

    pub fn clear(self: *PrunedToolCache, gpa: std.mem.Allocator) void {
        var it = self.entries.valueIterator();
        while (it.next()) |ptr| {
            ptr.*.deinit(gpa);
            gpa.destroy(ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }
};
/// Borrow-based view of the pruned history. Unchanged messages BORROW from
/// `messages` — no byte copy, so base64 images are never duplicated per turn —
/// and only historical tool messages older than the cutoff become owned pruned
/// copies (or borrowed from `cache` if provided). Caller owns the returned slice
/// and must free with `freePrunedViews`.
///
/// Safe while `messages` is stable: the caller (`Agent.run`) holds the
/// ContextManager list and does not append between building the views and the
/// synchronous `client.prompt` returning.
pub fn pruneHistoricalToolResultsViews(
    gpa: std.mem.Allocator,
    messages: []const ai.ChatMessage,
    keep_recent_tool_turns: u32,
    historical_tool_cap_bytes: u32,
) ![]ai.MessageView {
    return pruneHistoricalToolResultsViewsCached(
        gpa,
        null,
        messages,
        keep_recent_tool_turns,
        historical_tool_cap_bytes,
    );
}

/// Cached variant of `pruneHistoricalToolResultsViews` (TD-13). When `cache` is
/// non-null, owned pruned copies are stored in the cache and returned as
/// `.borrowed = ptr`, eliminating repetitive pruning allocations across run-loop
/// iterations. When `cache` is null, operates identically to the uncached path.
pub fn pruneHistoricalToolResultsViewsCached(
    gpa: std.mem.Allocator,
    cache: ?*PrunedToolCache,
    messages: []const ai.ChatMessage,
    keep_recent_tool_turns: u32,
    historical_tool_cap_bytes: u32,
) ![]ai.MessageView {
    return pruneHistoricalToolResultsViewsWithSkills(gpa, cache, messages, keep_recent_tool_turns, historical_tool_cap_bytes, null);
}

pub fn pruneHistoricalToolResultsViewsWithSkills(
    gpa: std.mem.Allocator,
    cache: ?*PrunedToolCache,
    messages: []const ai.ChatMessage,
    keep_recent_tool_turns: u32,
    historical_tool_cap_bytes: u32,
    skills: ?*const SkillContext,
) ![]ai.MessageView {
    if (cache) |c| {
        if (c.cached_cap_bytes != historical_tool_cap_bytes) {
            c.clear(gpa);
            c.cached_cap_bytes = historical_tool_cap_bytes;
        }
    }

    const missing = if (skills) |context| try skill_history.formatMissing(context, gpa, messages) else null;
    var missing_transferred = false;
    errdefer if (!missing_transferred) {
        if (missing) |text| gpa.free(text);
    };
    const views = try gpa.alloc(ai.MessageView, messages.len + @as(usize, @intFromBool(missing != null)));
    var built: usize = 0;
    errdefer {
        for (views[0..built]) |*view| switch (view.*) {
            .owned => |*m| m.deinit(gpa),
            .borrowed => {},
        };
        gpa.free(views);
    }

    const maybe_cutoff = computeCutoff(messages, keep_recent_tool_turns);
    const pruning_active = maybe_cutoff != null;
    const cutoff_index = maybe_cutoff orelse 0;

    for (messages, 0..) |*msg, idx| {
        const retained = if (skills) |context| skill_history.retainedTool(context, messages, idx) else false;
        if (pruning_active and idx < cutoff_index and msg.* == .tool and !retained) {
            if (cache) |c| {
                if (c.entries.get(idx)) |cached_ptr| {
                    views[idx] = .{ .borrowed = cached_ptr };
                } else {
                    const pruned = try pruneSingleToolMessage(gpa, msg.*, historical_tool_cap_bytes);
                    var pruned_owned = pruned;
                    errdefer pruned_owned.deinit(gpa);

                    const msg_ptr = try gpa.create(ai.ChatMessage);
                    errdefer gpa.destroy(msg_ptr);
                    msg_ptr.* = pruned_owned;

                    try c.entries.put(gpa, idx, msg_ptr);
                    views[idx] = .{ .borrowed = msg_ptr };
                }
            } else {
                views[idx] = .{ .owned = try pruneSingleToolMessage(gpa, msg.*, historical_tool_cap_bytes) };
            }
        } else {
            views[idx] = .{ .borrowed = msg };
        }
        built = idx + 1;
    }
    if (missing) |text| {
        const blocks = try gpa.alloc(ai.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = text } };
        // Insert before conversation messages, preserving call/result adjacency
        // and the newest real user message's image-retention window.
        var insertion: usize = 0;
        while (insertion < messages.len and messages[insertion] == .system) insertion += 1;
        std.mem.copyBackwards(ai.MessageView, views[insertion + 1 ..], views[insertion..messages.len]);
        views[insertion] = .{ .owned = .{ .user = .{ .content = blocks } } };
        missing_transferred = true;
        built += 1;
    }
    return views;
}

/// Free a view slice produced by `pruneHistoricalToolResultsViews`. Only the
/// `.owned` pruned copies are released; borrowed views point into the
/// ContextManager and are left untouched.
pub fn freePrunedViews(gpa: std.mem.Allocator, views: []ai.MessageView) void {
    for (views) |*view| switch (view.*) {
        .owned => |*m| m.deinit(gpa),
        .borrowed => {},
    };
    gpa.free(views);
}

/// History image eviction with re-mention stubs (#122). Chat-completions
/// APIs are stateless, so every image block re-uploads its base64 on every
/// follow-up turn until compaction prunes the message. This pass replaces
/// image blocks in OLDER user messages with a deterministic text stub — the
/// model can re-attach any file by `@`-mentioning the path shown in the
/// stub, mirroring how the `@`-mention markers already read.
///
/// Recency window: only the NEWEST user message keeps its images. Once a
/// message stops being the newest user message its stub form never changes
/// again, so the prompt-cache prefix pays exactly one miss per eviction and
/// is stable thereafter. Affected messages become OWNED copies (borrowed
/// history is never mutated); unaffected views keep their borrow/own state
/// exactly as `pruneHistoricalToolResultsViews` left it. The stub text embeds
/// the (already XML-escaped) `src` from the message's own `<image src="…"/>`
/// marker when the pairing is unambiguous, and the decoded byte size.
pub fn evictHistoryImagesViews(gpa: std.mem.Allocator, views: []ai.MessageView) !void {
    if (views.len == 0) return;

    var newest_user: ?usize = null;
    for (views, 0..) |view, i| {
        const msg = view.message();
        if (msg.* == .user) newest_user = i;
    }
    const newest = newest_user orelse return;

    for (views[0..newest]) |*view| {
        // Only user messages can carry image blocks; tool prunes above may
        // have left `.owned` copies — stub those the same way.
        const msg = view.message();
        if (msg.* != .user) continue;
        if (!userMessageHasImage(msg.*)) continue;
        view.* = .{ .owned = try stubImagesInUserMessage(gpa, msg.*) };
    }
}

fn userMessageHasImage(msg: ai.ChatMessage) bool {
    for (msg.user.content) |block| {
        if (block == .image) return true;
    }
    return false;
}

/// Owned copy of a user message with every image block replaced by its
/// re-mention stub. Text blocks are cloned (owned); the stub owns its bytes.
fn stubImagesInUserMessage(gpa: std.mem.Allocator, msg: ai.ChatMessage) !ai.ChatMessage {
    var srcs: std.ArrayList([]const u8) = .empty;
    defer srcs.deinit(gpa);
    collectAttachedImageSrcs(gpa, msg.user.content, &srcs) catch {};

    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    errdefer {
        for (blocks.items) |*block| block.deinit(gpa);
        blocks.deinit(gpa);
    }

    var image_index: usize = 0;
    for (msg.user.content) |block| {
        if (block == .image) {
            const src: ?[]const u8 = if (image_index < srcs.items.len) srcs.items[image_index] else null;
            image_index += 1;
            const stub = try makeImageStub(gpa, block.image, src);
            errdefer gpa.free(stub);
            try blocks.append(gpa, .{ .text = .{ .text = stub } });
        } else {
            try blocks.append(gpa, try cloneContentBlock(gpa, block));
        }
    }
    return .{ .user = .{ .content = try blocks.toOwnedSlice(gpa) } };
}

/// Collect the `src` values of every successful (non-error) `<image …/>`
/// marker across the message's text blocks, in order. The attach path emits
/// exactly one marker per attached image in mention order, so marker k pairs
/// with image block k. Returned slices borrow from the text blocks (safe:
/// the stub copies them into its own allocation before the caller reads on).
fn collectAttachedImageSrcs(
    gpa: std.mem.Allocator,
    content: []const ai.ContentBlock,
    out: *std.ArrayList([]const u8),
) !void {
    for (content) |block| {
        if (block != .text) continue;
        var rest = block.text.text;
        while (std.mem.indexOf(u8, rest, "<image src=\"")) |open| {
            const after = rest[open + "<image src=\"".len ..];
            const close = std.mem.indexOfScalar(u8, after, '"') orelse break;
            const src = after[0..close];
            // Error markers (`<image src="…" error="…"/>`) name images that
            // were NOT attached — they never pair with an image block.
            const is_error = std.mem.startsWith(u8, after[close..], "\" error=");
            if (!is_error and src.len > 0) {
                try out.append(gpa, src);
            }
            rest = after[close..];
        }
    }
}

/// Human-readable byte size for the stub, e.g. `2.4 MB` / `812 KB` / `900 B`.
fn formatStubSize(buf: []u8, bytes: usize) []const u8 {
    if (bytes >= 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)}) catch "large";
    }
    if (bytes >= 1024) {
        return std.fmt.bufPrint(buf, "{d:.0} KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0}) catch "large";
    }
    return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "small";
}

fn makeImageStub(gpa: std.mem.Allocator, img: ai.ImageBlock, src: ?[]const u8) ![]u8 {
    var size_buf: [24]u8 = undefined;
    const decoded = std.base64.standard.Decoder.calcSizeForSlice(img.data_base64) catch
        (img.data_base64.len * 3 / 4);
    const size_text = formatStubSize(&size_buf, decoded);
    if (src) |s| {
        // `s` is already XML-escaped (it came from a marker) and the stub is
        // stable text inside the cache prefix.
        return std.fmt.allocPrint(
            gpa,
            "[image: {s} ({s}) — shown in an earlier turn; mention @{s} to view it again]",
            .{ s, size_text, s },
        );
    }
    return std.fmt.allocPrint(
        gpa,
        "[image ({s}, {s}) — shown in an earlier turn; mention the image's @path from the text above to view it again]",
        .{ img.mime_type, size_text },
    );
}

/// Estimate the token footprint of `messages[from_index..]` as the *pruned*
/// request would actually send it: historical tool messages (below the cutoff
/// computed over the FULL slice, so trailing messages get the same kept/pruned
/// verdict the next request will) count with their text capped at
/// `historical_tool_cap_bytes`; everything else counts in full. This keeps the
/// watermark estimator and the wire request in agreement (TD-9).
/// Token estimate for one evicted image stub (#122). The stub is bounded,
/// fixed-shape text (~100–150 bytes), so a constant keeps the watermark
/// estimator and the wire request in agreement (TD-9) without duplicating
/// the stub formatter.
pub const evicted_image_stub_tokens: u32 = 40;

pub fn estimatePrunedTokensRange(
    messages: []const ai.ChatMessage,
    from_index: usize,
    keep_recent_tool_turns: u32,
    historical_tool_cap_bytes: u32,
    evict_history_images: bool,
) u32 {
    return estimatePrunedTokensRangeWithSkills(messages, from_index, keep_recent_tool_turns, historical_tool_cap_bytes, evict_history_images, null);
}

pub fn estimatePrunedTokensRangeWithSkills(
    messages: []const ai.ChatMessage,
    from_index: usize,
    keep_recent_tool_turns: u32,
    historical_tool_cap_bytes: u32,
    evict_history_images: bool,
    skills: ?*const SkillContext,
) u32 {
    assert(from_index <= messages.len);
    const maybe_cutoff = computeCutoff(messages, keep_recent_tool_turns);
    const pruning_active = maybe_cutoff != null;
    const cutoff_index = maybe_cutoff orelse 0;
    // The eviction window mirrors `evictHistoryImagesViews`: only the newest
    // user message keeps its images.
    var newest_user: ?usize = null;
    if (evict_history_images) {
        for (messages, 0..) |*msg, i| {
            if (msg.* == .user) newest_user = i;
        }
    }
    var total: u32 = 0;
    var index: usize = from_index;
    while (index < messages.len) : (index += 1) {
        const message = messages[index];
        const retained = if (skills) |context| skill_history.retainedTool(context, messages, index) else false;
        if (pruning_active and index < cutoff_index and message == .tool and !retained) {
            total +|= if (skills != null) estimateRenderedToolTokens(message, historical_tool_cap_bytes) else compaction.estimateMessageTokensCapped(message, historical_tool_cap_bytes);
        } else if (evict_history_images and message == .user and
            newest_user != null and index < newest_user.? and userMessageHasImage(message))
        {
            total +|= estimateUserMessageWithEvictedImages(message);
        } else {
            total +|= compaction.estimateMessageTokens(message);
        }
    }
    if (from_index == 0) {
        if (skills) |context| {
            const bytes: u32 = @intCast(skill_history.missingBytes(context, messages));
            total +|= std.math.divCeil(u32, bytes, 4) catch unreachable;
        }
    }
    return total;
}

/// Token estimate for a user message whose image blocks were replaced by
/// stubs on the wire: text blocks at full length, each image at the stub
/// constant.
fn estimateUserMessageWithEvictedImages(message: ai.ChatMessage) u32 {
    var tokens: u32 = 0;
    for (message.user.content) |block| {
        tokens +|= if (block == .image)
            evicted_image_stub_tokens
        else
            compaction.estimateBlockTokens(block);
    }
    return tokens;
}
test "skill context retains old tool bodies and estimator matches request views" {
    const gpa = std.testing.allocator;
    const instructions = try gpa.alloc(u8, 4096);
    defer gpa.free(instructions);
    @memset(instructions, 'x');
    var ledger: SkillContext = .{};
    defer ledger.deinit(gpa);
    _ = try ledger.activate(gpa, "how", instructions);
    var call_blocks = [_]ai.ContentBlock{.{ .tool_call = .{
        .call_id = .{ .value = @constCast("skill-call") },
        .name = @constCast("skill"),
        .arguments = @constCast("{\"name\":\"how\"}"),
    } }};
    var body_blocks = [_]ai.ContentBlock{.{ .text = .{ .text = instructions } }};
    var normal_blocks = [_]ai.ContentBlock{.{ .text = .{ .text = instructions } }};
    const messages = [_]ai.ChatMessage{
        .{ .assistant = .{ .content = &call_blocks } },
        .{ .tool = .{ .call_id = .{ .value = @constCast("skill-call") }, .content = &body_blocks } },
        .{ .tool = .{ .call_id = .{ .value = @constCast("ordinary") }, .content = &normal_blocks } },
    };
    var cache: PrunedToolCache = .{};
    defer cache.deinit(gpa);
    for ([_]?*PrunedToolCache{ null, &cache }) |maybe_cache| {
        const views = try pruneHistoricalToolResultsViewsWithSkills(gpa, maybe_cache, &messages, 0, 64, &ledger);
        defer freePrunedViews(gpa, views);
        try std.testing.expectEqual(@as(usize, 3), views.len);
        try std.testing.expectEqualStrings(instructions, views[1].message().text());
        try std.testing.expectEqualStrings("skill-call", views[1].message().tool.call_id.slice());
        try std.testing.expect(views[2].message().text().len < instructions.len);
        var estimate: u32 = 0;
        for (views) |view| estimate += compaction.estimateMessageTokens(view.message().*);
        try std.testing.expectEqual(estimate, estimatePrunedTokensRangeWithSkills(&messages, 0, 0, 64, false, &ledger));
        try std.testing.expectEqualStrings(instructions, messages[2].text());
    }
    const compacted = [_]ai.ChatMessage{.{ .user = .{ .content = &.{} } }};
    const resumed = try pruneHistoricalToolResultsViewsWithSkills(gpa, &cache, &compacted, 0, 64, &ledger);
    defer freePrunedViews(gpa, resumed);
    try std.testing.expectEqual(@as(usize, 2), resumed.len);
    try std.testing.expect(std.mem.indexOf(u8, resumed[0].message().text(), instructions) != null);
    var estimate: u32 = 0;
    for (resumed) |view| estimate += compaction.estimateMessageTokens(view.message().*);
    try std.testing.expectEqual(estimate, estimatePrunedTokensRangeWithSkills(&compacted, 0, 0, 64, false, &ledger));
}

test "estimatePrunedTokensRange matches the bytes the pruned request sends" {
    const gpa = std.testing.allocator;
    // Two distinct tool runs (separated by an assistant message); keep=1 prunes
    // the older run (message 0) at the cap, keeps the recent one in full.
    var messages: [3]ai.ChatMessage = undefined;
    messages[0] = try makeToolMessage(gpa, "c1", "x" ** 4000); // ~1000 tokens raw
    messages[1] = try makeTextMessage(gpa, .assistant, "done");
    messages[2] = try makeToolMessage(gpa, "c3", "y" ** 4000); // ~1000 tokens raw
    defer for (&messages) |*m| m.deinit(gpa);

    const cap: u32 = 100;
    const estimated = estimatePrunedTokensRange(&messages, 0, 1, cap, false);
    // message 0 capped at 100 bytes (~25 tokens) + message 1 (~1 token) +
    // message 2 in full (~1000 tokens).
    const expected = compaction.estimateMessageTokensCapped(messages[0], cap) +
        compaction.estimateMessageTokens(messages[1]) +
        compaction.estimateMessageTokens(messages[2]);
    try std.testing.expectEqual(expected, estimated);
    // The pruned estimate is strictly below the un-pruned one.
    const unpruned = compaction.estimateMessageTokens(messages[0]) +
        compaction.estimateMessageTokens(messages[1]) +
        compaction.estimateMessageTokens(messages[2]);
    try std.testing.expect(estimated < unpruned);
}

test "trailing estimate uses the full-history cutoff verdict" {
    const gpa = std.testing.allocator;
    // Two distinct tool runs; keep=1 prunes the older run. The trailing range
    // starting at index 1 must apply the SAME cutoff as the full range.
    var messages: [4]ai.ChatMessage = undefined;
    messages[0] = try makeToolMessage(gpa, "c1", "x" ** 4000); // pruned
    messages[1] = try makeTextMessage(gpa, .assistant, "done");
    messages[2] = try makeToolMessage(gpa, "c3", "y" ** 4000); // recent, kept
    messages[3] = try makeTextMessage(gpa, .user, "next");
    defer for (&messages) |*m| m.deinit(gpa);

    const cap: u32 = 100;
    const full = estimatePrunedTokensRange(&messages, 0, 1, cap, false);
    const trailing = estimatePrunedTokensRange(&messages, 1, 1, cap, false);
    // full = pruned(msg0) + msg1 + msg2 + msg3; trailing = msg1 + msg2 + msg3.
    try std.testing.expectEqual(full - compaction.estimateMessageTokensCapped(messages[0], cap), trailing);
}
// Head+tail sandwich for tool-result truncation lives in `tools/common.zig`
// (`pruneToolText`) — the single source of truth shared by compaction,
// historical pruning, and LLM observation formatting. It keeps the
// load-bearing conclusion (tail) alongside the start (head), so an old
// command result doesn't lose its answer.

fn pruneSingleToolMessage(gpa: std.mem.Allocator, msg: ai.ChatMessage, cap_bytes: u32) !ai.ChatMessage {
    assert(msg == .tool);
    const content = msg.tool.content;
    var pruned_blocks = try gpa.alloc(ai.ContentBlock, content.len);
    var placed: usize = 0;
    errdefer {
        for (pruned_blocks[0..placed]) |*block| block.deinit(gpa);
        gpa.free(pruned_blocks);
    }

    for (content, 0..) |block, b_idx| {
        if (block == .text and block.text.text.len > cap_bytes) {
            // Head+tail sandwich: keep the START of the output (file-read
            // preamble, command banner) AND the CONCLUSION (errors, test
            // results, rg hits, git status — the load-bearing tail). Head-only
            // truncation discarded the tail, so an old command output lost its
            // answer and the model re-ran it to rediscover it.
            const pruned = try tools_common.pruneToolText(gpa, block.text.text, cap_bytes);
            pruned_blocks[b_idx] = .{ .text = .{ .text = pruned } };
        } else {
            pruned_blocks[b_idx] = try cloneContentBlock(gpa, block);
        }
        placed = b_idx + 1;
    }

    const call_id = try gpa.dupe(u8, msg.tool.call_id.slice());
    errdefer gpa.free(call_id);
    const display_label = if (msg.tool.display_label) |l| try gpa.dupe(u8, l) else null;
    errdefer if (display_label) |l| gpa.free(l);

    return .{
        .tool = .{
            .content = pruned_blocks,
            .call_id = .{ .value = call_id },
            .display_label = display_label,
            .failed = msg.tool.failed,
        },
    };
}

fn cloneContentBlock(gpa: std.mem.Allocator, block: ai.ContentBlock) !ai.ContentBlock {
    return switch (block) {
        .text => |t| .{ .text = .{ .text = try gpa.dupe(u8, t.text) } },
        .refusal => |t| .{ .refusal = .{ .text = try gpa.dupe(u8, t.text) } },
        .reasoning => |r| .{ .reasoning = .{ .text = try gpa.dupe(u8, r.text) } },
        .image => |img| {
            const mime = try gpa.dupe(u8, img.mime_type);
            errdefer gpa.free(mime);
            const data = try gpa.dupe(u8, img.data_base64);
            return .{ .image = .{ .mime_type = mime, .data_base64 = data } };
        },
        .tool_call => |call| {
            const call_id = try gpa.dupe(u8, call.call_id.slice());
            errdefer gpa.free(call_id);
            const name = try gpa.dupe(u8, call.name);
            errdefer gpa.free(name);
            const arguments = try gpa.dupe(u8, call.arguments);
            return .{ .tool_call = .{ .call_id = .{ .value = call_id }, .name = name, .arguments = arguments } };
        },
    };
}
test "pruneHistoricalToolResultsViews caps old tool outputs while preserving recent ones" {
    const gpa = std.testing.allocator;

    // Distinct tool runs are separated by assistant messages, so each tool
    // message is its own turn. keep=2 prunes the older two turns.
    var messages: [9]ai.ChatMessage = undefined;
    messages[0] = try makeTextMessage(gpa, .user, "hello");
    messages[1] = try makeToolMessage(gpa, "c1", "a" ** 2000); // Historical tool 1 (turn 1)
    messages[2] = try makeTextMessage(gpa, .assistant, "done 1");
    messages[3] = try makeToolMessage(gpa, "c2", "b" ** 2000); // Historical tool 2 (turn 2)
    messages[4] = try makeTextMessage(gpa, .assistant, "done 2");
    messages[5] = try makeToolMessage(gpa, "c3", "c" ** 2000); // Recent tool 1 (turn 3)
    messages[6] = try makeTextMessage(gpa, .assistant, "done 3");
    messages[7] = try makeToolMessage(gpa, "c4", "d" ** 2000); // Recent tool 2 (turn 4)
    messages[8] = try makeTextMessage(gpa, .user, "next user ask");
    defer for (&messages) |*m| m.deinit(gpa);

    // Keep recent 2 tool turns intact, prune older tools at 100 bytes
    const pruned = try pruneHistoricalToolResultsViews(gpa, &messages, 2, 100);
    defer freePrunedViews(gpa, pruned);

    try std.testing.expectEqual(@as(usize, 9), pruned.len);
    // Historical tool 1 (index 1) should be owned and truncated
    try std.testing.expect(pruned[1] == .owned);
    const t1_text = pruned[1].owned.tool.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, t1_text, "[...]") != null);
    try std.testing.expect(t1_text.len < 300);

    // Recent tool 1 (index 5) should be borrowed and kept in full
    try std.testing.expect(pruned[5] == .borrowed);
    const t3_text = pruned[5].borrowed.tool.content[0].text.text;
    try std.testing.expectEqual(@as(usize, 2000), t3_text.len);
}

test "pruneHistoricalToolResultsViews preserves the bash spill recovery footer" {
    const gpa = std.testing.allocator;

    // A truncated bash observation whose tail carries the spill footer. The
    // footer is the model's only handle to re-read the full spill on disk, so
    // the head+tail sandwich must keep it (it sits inside the preserved tail).
    const spill_path = "/tmp/zay-bash-0123456789abcdef.log";
    const body = "a" ** 4000;
    const obs = try std.fmt.allocPrint(
        gpa,
        "{s}\n\n[Showing last 12 of 300 lines (50 KB of 200 KB). Full output: {s}]",
        .{ body, spill_path },
    );
    defer gpa.free(obs);

    var messages: [3]ai.ChatMessage = undefined;
    messages[0] = try makeToolMessage(gpa, "c1", obs);
    messages[1] = try makeTextMessage(gpa, .assistant, "done");
    messages[2] = try makeTextMessage(gpa, .user, "next");
    defer for (&messages) |*m| m.deinit(gpa);

    const pruned = try pruneHistoricalToolResultsViews(gpa, &messages, 0, 100);
    defer freePrunedViews(gpa, pruned);

    try std.testing.expect(pruned[0] == .owned);
    const text = pruned[0].owned.tool.content[0].text.text;
    // The recovery handle survives the head-truncation.
    try std.testing.expect(std.mem.indexOf(u8, text, spill_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[...]") != null);
    // The head is still bounded.
    try std.testing.expect(text.len < 400);
}

test "computeCutoff counts a contiguous tool batch as one turn" {
    // A single 8-result parallel batch is one turn: keep=4 keeps all 8.
    const gpa = std.testing.allocator;

    var messages: [9]ai.ChatMessage = undefined;
    messages[0] = try makeTextMessage(gpa, .user, "hello");
    for (0..8) |k| {
        messages[1 + k] = try makeToolMessage(gpa, "c", "x" ** 2000);
    }
    defer for (&messages) |*m| m.deinit(gpa);

    const pruned = try pruneHistoricalToolResultsViews(gpa, &messages, 4, 100);
    defer freePrunedViews(gpa, pruned);
    // The whole batch counts as one turn, so nothing is pruned.
    for (1..9) |k| try std.testing.expect(pruned[k] == .borrowed);
}

test "computeCutoff with keep=0 prunes trailing tool message" {
    const gpa = std.testing.allocator;

    var messages: [2]ai.ChatMessage = undefined;
    messages[0] = try makeTextMessage(gpa, .user, "hello");
    messages[1] = try makeToolMessage(gpa, "c", "x" ** 2000);
    defer for (&messages) |*m| m.deinit(gpa);

    const pruned = try pruneHistoricalToolResultsViews(gpa, &messages, 0, 100);
    defer freePrunedViews(gpa, pruned);

    try std.testing.expect(pruned[0] == .borrowed);
    try std.testing.expect(pruned[1] == .owned);
}

test "pruneHistoricalToolResultsViews borrows unchanged messages without copying" {
    // The zero-copy contract: an image user message must be BORROWED with
    // pointer identity (its base64 bytes are never re-duped), while a
    // historical tool message older than the cutoff becomes an owned pruned
    // copy. Recent tool messages are borrowed in full.
    const gpa = std.testing.allocator;

    var messages: [3]ai.ChatMessage = undefined;
    messages[0] = try makeToolMessage(gpa, "c_old", "a" ** 2000); // historical (over cap)
    messages[1] = try makeImageUserMessage(gpa); // image user message
    messages[2] = try makeToolMessage(gpa, "c_new", "b" ** 2000); // recent tool
    defer for (&messages) |*m| m.deinit(gpa);

    const views = try pruneHistoricalToolResultsViews(gpa, &messages, 1, 100);
    defer freePrunedViews(gpa, views);

    try std.testing.expectEqual(@as(usize, 3), views.len);

    // Historical tool message → owned, pruned.
    try std.testing.expect(views[0] == .owned);
    const pruned_text = views[0].owned.tool.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, pruned_text, "[...]") != null);

    // Image user message → borrowed with pointer identity: no copy was made.
    try std.testing.expect(views[1] == .borrowed);
    try std.testing.expect(views[1].borrowed == &messages[1]);
    const image = views[1].borrowed.user.content[0].image;
    try std.testing.expect(image.data_base64.ptr == messages[1].user.content[0].image.data_base64.ptr);

    // Recent tool message → borrowed, kept in full.
    try std.testing.expect(views[2] == .borrowed);
    try std.testing.expectEqual(@as(usize, 2000), views[2].borrowed.tool.content[0].text.text.len);
}

test "PrunedToolCache caches owned messages across iterations with pointer stability" {
    const gpa = std.testing.allocator;

    var messages: [4]ai.ChatMessage = undefined;
    messages[0] = try makeTextMessage(gpa, .user, "hello");
    messages[1] = try makeToolMessage(gpa, "c1", "a" ** 2000); // historical
    messages[2] = try makeTextMessage(gpa, .assistant, "step 1");
    messages[3] = try makeToolMessage(gpa, "c2", "b" ** 2000); // recent
    defer for (&messages) |*m| m.deinit(gpa);

    var cache: PrunedToolCache = .{};
    defer cache.deinit(gpa);

    // Iteration 1: keep=1 keeps c2 in full, prunes c1.
    const views1 = try pruneHistoricalToolResultsViewsCached(gpa, &cache, &messages, 1, 100);
    defer freePrunedViews(gpa, views1);

    try std.testing.expect(views1[1] == .borrowed);
    const ptr1 = views1[1].borrowed;
    const pruned_text1 = ptr1.tool.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, pruned_text1, "[...]") != null);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());

    // Iteration 2: same messages, same cache -> must return the EXACT same pointer (0 new message allocations)
    const views2 = try pruneHistoricalToolResultsViewsCached(gpa, &cache, &messages, 1, 100);
    defer freePrunedViews(gpa, views2);

    try std.testing.expect(views2[1] == .borrowed);
    const ptr2 = views2[1].borrowed;
    try std.testing.expectEqual(ptr1, ptr2);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());

    // Cap change auto-clears and re-prunes. Re-pruning is proven by CONTENT
    // (the head+tail sandwich scales with the cap), not by pointer identity:
    // the fresh copy may legally land on the just-freed address, so an
    // allocator-address comparison is meaningless here.
    const views3 = try pruneHistoricalToolResultsViewsCached(gpa, &cache, &messages, 1, 150);
    defer freePrunedViews(gpa, views3);

    try std.testing.expect(views3[1] == .borrowed);
    const ptr3 = views3[1].borrowed;
    const pruned_text3 = ptr3.tool.content[0].text.text;
    try std.testing.expect(pruned_text3.len > pruned_text1.len); // re-pruned at the larger cap
    try std.testing.expectEqual(@as(u32, 150), cache.cached_cap_bytes);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());
}

fn makeTextMessage(gpa: std.mem.Allocator, role: ai.Role, text: []const u8) !ai.ChatMessage {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    errdefer gpa.free(blocks);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, text) } };
    return switch (role) {
        .system => .{ .system = .{ .content = blocks } },
        .user => .{ .user = .{ .content = blocks } },
        .assistant => .{ .assistant = .{ .content = blocks } },
        .tool => error.InvalidToolRole,
    };
}

fn makeImageUserMessage(gpa: std.mem.Allocator) !ai.ChatMessage {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    errdefer gpa.free(blocks);
    blocks[0] = .{ .image = .{
        .mime_type = try gpa.dupe(u8, "image/png"),
        .data_base64 = try gpa.dupe(u8, "QUJD"),
    } };
    return .{ .user = .{ .content = blocks } };
}

fn makeToolMessage(gpa: std.mem.Allocator, call_id: []const u8, text: []const u8) !ai.ChatMessage {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    errdefer gpa.free(blocks);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, text) } };
    return .{
        .tool = .{
            .content = blocks,
            .call_id = .{ .value = try gpa.dupe(u8, call_id) },
            .display_label = try gpa.dupe(u8, "bash"),
        },
    };
}

test "pruneHistoricalToolResultsViews frees partial pruned copies on failure" {
    // Build the inputs with the real allocator, then fail an allocation inside
    // the pruning path: partial pruned copies built before the failure point
    // must be freed (no leak under the testing allocator).
    const gpa = std.testing.allocator;
    // Two distinct tool runs (separated by an assistant message); keep=1 prunes
    // the older run (message 0) and keeps the recent one (message 2).
    var messages: [3]ai.ChatMessage = undefined;
    messages[0] = try makeToolMessage(gpa, "c1", "a" ** 2000); // historical → owned
    messages[1] = try makeTextMessage(gpa, .assistant, "done");
    messages[2] = try makeToolMessage(gpa, "c3", "b" ** 2000); // recent → borrowed
    defer for (&messages) |*m| m.deinit(gpa);

    // Fail the notice allocation inside message 0's pruning (views=0,
    // pruned_blocks=1, notice=2): the pruned_blocks array must be freed.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 2 });
    try std.testing.expectError(error.OutOfMemory, pruneHistoricalToolResultsViews(failing.allocator(), &messages, 1, 100));
}

test "pruneSingleToolMessage frees placed blocks when call_id duping fails" {
    // A tool message whose content mixes an oversized text block (allocates a
    // notice) and an image block (allocates mime + data), so a failure in the
    // trailing call_id/display_label dupes must free the placed blocks.
    const gpa = std.testing.allocator;
    var message = try makeToolMessage(gpa, "c1", "a" ** 2000);
    defer message.deinit(gpa);

    // Fail the display_label dupe (alloc 3: pruned_blocks=0, notice=1,
    // call_id=2, display_label=3): the placed notice block must be freed.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 3 });
    try std.testing.expectError(error.OutOfMemory, pruneSingleToolMessage(failing.allocator(), message, 100));
}

test "cloneContentBlock frees the mime type when the image data dupe fails" {
    const gpa = std.testing.allocator;
    var block: ai.ContentBlock = .{ .image = .{
        .mime_type = try gpa.dupe(u8, "image/png"),
        .data_base64 = try gpa.dupe(u8, "QUJD"),
    } };
    defer block.deinit(gpa);

    // Fail the data_base64 dupe (alloc 1: mime=0, data=1): the mime must be freed.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, cloneContentBlock(failing.allocator(), block));
}
// ─── #122: history image eviction ────────────────────────────────────────

fn makeMarkerImageUserMessage(gpa: std.mem.Allocator, src: []const u8, data: []const u8) !ai.ChatMessage {
    const blocks = try gpa.alloc(ai.ContentBlock, 2);
    errdefer gpa.free(blocks);
    const marker = try std.fmt.allocPrint(gpa, "look <image src=\"{s}\" />", .{src});
    errdefer gpa.free(marker);
    blocks[0] = .{ .text = .{ .text = marker } };
    blocks[1] = .{ .image = .{
        .mime_type = try gpa.dupe(u8, "image/png"),
        .data_base64 = try gpa.dupe(u8, data),
    } };
    return .{ .user = .{ .content = blocks } };
}

test "evictHistoryImagesViews stubs older images, keeps the newest, never mutates history" {
    const gpa = std.testing.allocator;
    var messages: [3]ai.ChatMessage = undefined;
    messages[0] = try makeMarkerImageUserMessage(gpa, "photo.png", "QUJD"); // older user message
    messages[1] = try makeTextMessage(gpa, .assistant, "looks great");
    messages[2] = try makeMarkerImageUserMessage(gpa, "chart.png", "REVG"); // newest user message
    defer for (&messages) |*m| m.deinit(gpa);

    const views = try gpa.alloc(ai.MessageView, 3);
    for (&messages, 0..) |*m, i| views[i] = .{ .borrowed = m };
    defer freePrunedViews(gpa, views);

    try evictHistoryImagesViews(gpa, views);

    // Older user message: OWNED copy, image replaced by a stub naming the
    // file and its decoded size, text block preserved.
    try std.testing.expect(views[0] == .owned);
    const older = views[0].owned.user.content;
    try std.testing.expectEqual(@as(usize, 2), older.len);
    try std.testing.expect(older[0] == .text);
    try std.testing.expect(older[1] == .text);
    try std.testing.expect(std.mem.indexOf(u8, older[1].text.text, "[image: photo.png (3 B)") != null);
    try std.testing.expect(std.mem.indexOf(u8, older[1].text.text, "mention @photo.png to view it again") != null);

    // Newest user message: still BORROWED (zero-copy) with the image intact.
    try std.testing.expect(views[2] == .borrowed);
    try std.testing.expect(views[2].borrowed.user.content[1] == .image);
    try std.testing.expect(views[2].borrowed.user.content[1].image.data_base64.ptr ==
        messages[2].user.content[1].image.data_base64.ptr);

    // Borrowed history was never mutated: the older message still carries its
    // real image block.
    try std.testing.expect(messages[0].user.content[1] == .image);
    try std.testing.expectEqualStrings("QUJD", messages[0].user.content[1].image.data_base64);
}

test "evictHistoryImagesViews leaves non-image and single-user histories untouched" {
    const gpa = std.testing.allocator;
    var messages: [2]ai.ChatMessage = undefined;
    messages[0] = try makeTextMessage(gpa, .user, "plain");
    messages[1] = try makeImageUserMessage(gpa);
    defer for (&messages) |*m| m.deinit(gpa);

    const views = try gpa.alloc(ai.MessageView, 2);
    for (&messages, 0..) |*m, i| views[i] = .{ .borrowed = m };
    defer freePrunedViews(gpa, views);

    // The only user message IS the newest — nothing to evict, all borrowed.
    try evictHistoryImagesViews(gpa, views);
    try std.testing.expect(views[0] == .borrowed);
    try std.testing.expect(views[1] == .borrowed);
}

test "estimatePrunedTokensRange counts evicted images as stub tokens" {
    const gpa = std.testing.allocator;
    var messages: [2]ai.ChatMessage = undefined;
    messages[0] = try makeImageUserMessage(gpa); // older
    messages[1] = try makeTextMessage(gpa, .user, "next");
    defer for (&messages) |*m| m.deinit(gpa);

    const evicting = estimatePrunedTokensRange(&messages, 0, 5, 4096, true);
    const keeping = estimatePrunedTokensRange(&messages, 0, 5, 4096, false);
    // With eviction, message 0 counts one stub (evicted_image_stub_tokens)
    // instead of a full image estimate.
    try std.testing.expectEqual(keeping - compaction.estimateMessageTokens(messages[0]) + evicted_image_stub_tokens, evicting);
    try std.testing.expect(evicting < keeping);
}

// Historical tool pruning reserves marker space inside the byte cap, so its
// rendered text is at most `cap` bytes and the token estimate uses that same
// bound.
fn estimateRenderedToolTokens(message: ai.ChatMessage, cap: u32) u32 {
    var total: u32 = 0;
    for (message.tool.content) |block| {
        if (block != .text or block.text.text.len <= cap) {
            total +|= compaction.estimateBlockTokens(block);
            continue;
        }
        total +|= std.math.divCeil(u32, cap, 4) catch unreachable;
    }
    return total;
}

test "skill context retained request OOM preserves history and ledger" {
    const gpa = std.testing.allocator;
    var ledger: SkillContext = .{};
    defer ledger.deinit(gpa);
    _ = try ledger.activate(gpa, "how", "Retained missing instructions");
    var blocks = [_]ai.ContentBlock{.{ .text = .{ .text = @constCast("ordinary output " ** 64) } }};
    const messages = [_]ai.ChatMessage{.{ .tool = .{
        .call_id = .{ .value = @constCast("ordinary") },
        .content = &blocks,
    } }};
    for ([_]bool{ false, true }) |cached| {
        var succeeded = false;
        for (0..64) |fail_index| {
            var cache: PrunedToolCache = .{};
            defer cache.deinit(gpa);
            var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
            const result = pruneHistoricalToolResultsViewsWithSkills(failing.allocator(), if (cached) &cache else null, &messages, 0, 64, &ledger);
            if (result) |views| {
                freePrunedViews(gpa, views);
                succeeded = true;
                break;
            } else |err| {
                try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
            }
            try std.testing.expectEqualStrings("Retained missing instructions", ledger.body("how").?);
            try std.testing.expectEqualStrings("ordinary output " ** 64, messages[0].text());
        }
        try std.testing.expect(succeeded);
    }
}
