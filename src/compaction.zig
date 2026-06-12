//! compaction.zig — the pure decisions behind automatic context compaction:
//! how big the model's context window is, WHEN the conversation is close
//! enough to full to compact, WHAT prefix to summarize, and HOW that prefix is
//! rendered for the summarizer.
//!
//! Everything here is a pure function of its inputs (boundary-discipline): no
//! threads, no I/O, no allocation beyond an explicit `gpa` for the serialized
//! prefix. The background orchestration (the second client, the worker thread,
//! the history swap) is layered on top of these in the runtime.

const std = @import("std");

const ai = @import("ai.zig");
/// Static model→token-limit table generated at build time from the vendored
/// models.dev snapshot (see `build.zig` and `tools/gen_model_catalog.zig`).
const model_catalog = @import("model_catalog");

const assert = std.debug.assert;

/// Instruction sent to the summarizer (codex's CONTEXT CHECKPOINT COMPACTION
/// prompt). Combined with the rendered conversation in `buildSummaryRequest`.
pub const compaction_prompt = @embedFile("prompts/compaction.md");

/// Handover template stored as the boundary message, so the resuming model
/// knows the summary came from a prior model (codex's summary_prefix). It
/// carries a `${SUMMARY}` placeholder that `buildStoredSummary` replaces with
/// the produced summary.
pub const handover_template = @embedFile("prompts/handover.md");

/// Placeholder in `handover_template` where the summary is injected. Its
/// position is resolved at compile time; a build fails loudly if the template
/// ever loses the placeholder.
const summary_placeholder = "${SUMMARY}";
const summary_placeholder_index = std.mem.indexOf(u8, handover_template, summary_placeholder) orelse
    @compileError("prompts/handover.md must contain the " ++ summary_placeholder ++ " placeholder");

/// chars-per-token divisor for the size estimate used when a provider reports
/// no usage, and when choosing the cut point. Deliberately conservative (real
/// text is ~3.5–4 chars/token); overestimating tokens compacts slightly early,
/// which is the safe direction.
const tokens_per_char_divisor: u32 = 4;

/// Background summarization starts once the footprint crosses this fraction of
/// the window. Kicking off early gives the summary time to finish before it is
/// needed, so the swap is instant and the agent never blocks.
const start_watermark_percent: u32 = 70;

/// The summary is swapped into history once the footprint crosses this higher
/// fraction. Started at `start_watermark_percent`, the background summary is
/// normally ready by here. Everything appended between the two watermarks
/// survives the swap verbatim: the boundary references a tree entry id and the
/// projection emits every entry from it to the leaf (see `Session.messages`).
const swap_watermark_percent: u32 = 90;

/// Tokens of the most recent conversation kept verbatim; the older prefix is
/// summarized. Mirrors the codex/pi retention budget.
pub const keep_recent_tokens_default: u32 = 20_000;

/// Conservative fallback context window when the model id is unknown. Smaller
/// than most real windows on purpose — a low denominator only compacts early.
const context_window_default_tokens: u32 = 128_000;

/// Per-tool-result cap (in bytes) when rendering the prefix for the summarizer,
/// so a single huge command output cannot dominate the summary input.
const tool_output_render_cap_bytes: u32 = 2048;

/// Context window in tokens for `model_id`, from the generated models.dev
/// catalogue, or a conservative default when the id matches no catalogue entry.
///
/// Matches by longest id prefix: an exact id wins, and a dated/suffixed variant
/// (e.g. `gpt-5-2025-08-07`) falls back to its base family (`gpt-5`). The
/// catalogue carries only the providers Nova integrates with; anything else
/// lands on the conservative default, which only compacts early — the safe
/// direction.
pub fn contextWindowTokens(model_id: []const u8) u32 {
    var best: ?model_catalog.Entry = null;
    for (model_catalog.entries) |entry| {
        if (!std.mem.startsWith(u8, model_id, entry.id)) continue;
        if (best == null or entry.id.len > best.?.id.len) best = entry;
    }
    if (best) |entry| return entry.context;
    return context_window_default_tokens;
}

/// True once `used_tokens` crosses the start watermark: begin producing the
/// background summary. `used_tokens` is the conversation's footprint — prompt
/// plus completion of the last turn — since the completion becomes part of the
/// next request's prompt.
pub fn shouldStartSummary(used_tokens: u32, context_window: u32) bool {
    assert(context_window > 0);
    const threshold: u32 = @intCast(@as(u64, context_window) * start_watermark_percent / 100);
    return used_tokens > threshold;
}

/// True once `used_tokens` crosses the swap watermark: install the background
/// summary, replacing the summarized prefix while the recent tail survives
/// verbatim. By here the summary started at `shouldStartSummary` is normally
/// ready, so the swap does not block.
pub fn shouldSwap(used_tokens: u32, context_window: u32) bool {
    assert(context_window > 0);
    const threshold: u32 = @intCast(@as(u64, context_window) * swap_watermark_percent / 100);
    return used_tokens > threshold;
}

/// Summarize `prefix_text` with `client`: one user message (instruction +
/// conversation) so it works across providers without relying on per-provider
/// system handling, taking only the model's text. Caller owns the result. Safe
/// to call off the main thread provided `client` is not the one driving the
/// live turn.
pub fn summarize(gpa: std.mem.Allocator, client: ai.LanguageModel, prefix_text: []const u8) ![]u8 {
    const request = try buildSummaryRequest(gpa, prefix_text);
    const blocks = gpa.alloc(ai.ContentBlock, 1) catch |err| {
        gpa.free(request);
        return err;
    };
    blocks[0] = .{ .text = .{ .text = request } };
    var message: ai.ChatMessage = .{ .role = .user, .content = blocks };
    defer message.deinit(gpa);

    var turn = try client.prompt(&.{message}, ai.StreamObserver.noop);
    defer turn.deinit(gpa);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (turn.assistant.content) |block| {
        if (block == .text) try out.appendSlice(gpa, block.text.text);
    }
    return out.toOwnedSlice(gpa);
}

/// Estimate the token cost of one message from the byte length of its content
/// (chars/4, rounded up). A fallback for when the provider omits usage and the
/// unit used to choose the cut point.
pub fn estimateMessageTokens(message: ai.ChatMessage) u32 {
    var bytes: u32 = 0;
    for (message.content) |block| {
        bytes +|= blockBytes(block);
    }
    return divCeil(bytes, tokens_per_char_divisor);
}

fn blockBytes(block: ai.ContentBlock) u32 {
    return switch (block) {
        .text => |text| saturatingLen(text.text),
        .reasoning => |reasoning| saturatingLen(reasoning.text),
        .image => |image| saturatingLen(image.data_base64),
        .tool_call => |call| saturatingLen(call.name) +| saturatingLen(call.arguments),
    };
}

/// Index of the first message to keep verbatim. Messages before it are the
/// prefix to summarize; index 0 means everything fits and nothing should be
/// compacted. Three rules, applied in order by this parent so the leaves stay
/// branch-free:
///   1. keep the most recent `keep_recent_tokens` of messages,
///   2. pull the cut back to keep the most recent user message (the live
///      request) unless that would retain too much,
///   3. back up past a leading tool result so a kept `.tool` message never
///      loses the assistant tool-call it answers.
pub fn findCutIndex(messages: []const ai.ChatMessage, keep_recent_tokens: u32) u32 {
    assert(keep_recent_tokens > 0);
    var cut = cutByTokenBudget(messages, keep_recent_tokens);
    cut = keepRecentUserMessage(messages, cut, keep_recent_tokens *| 2);
    cut = avoidOrphanToolResult(messages, cut);
    return cut;
}

/// First index of the most-recent `keep_recent_tokens` of messages.
fn cutByTokenBudget(messages: []const ai.ChatMessage, keep_recent_tokens: u32) u32 {
    var index: u32 = @intCast(messages.len);
    var accumulated: u32 = 0;
    while (index > 0) {
        index -= 1;
        accumulated +|= estimateMessageTokens(messages[index]);
        if (accumulated >= keep_recent_tokens) break;
    }
    return index;
}

/// Pull `cut` back to the most recent user message so a large tool result can't
/// push the user's current request into the summary — unless keeping from there
/// would retain more than `kept_tokens_max` (a stale, long tool-only run still
/// compacts rather than being kept whole).
fn keepRecentUserMessage(messages: []const ai.ChatMessage, cut: u32, kept_tokens_max: u32) u32 {
    const last_user = lastUserIndex(messages) orelse return cut;
    if (last_user >= cut) return cut;
    var kept: u32 = 0;
    var index: usize = last_user;
    while (index < messages.len) : (index += 1) {
        kept +|= estimateMessageTokens(messages[index]);
    }
    if (kept > kept_tokens_max) return cut;
    return last_user;
}

/// Back `cut` up past a leading tool result so the kept window never starts on
/// a `.tool` message orphaned from its assistant tool-call.
fn avoidOrphanToolResult(messages: []const ai.ChatMessage, cut: u32) u32 {
    var index = cut;
    while (index > 0 and messages[index].role == .tool) {
        index -= 1;
    }
    return index;
}

fn lastUserIndex(messages: []const ai.ChatMessage) ?u32 {
    var index: u32 = @intCast(messages.len);
    while (index > 0) {
        index -= 1;
        if (messages[index].role == .user) return index;
    }
    return null;
}

/// Render `messages` as plain role-tagged text for the summarizer. Text is kept
/// in full; reasoning blocks are dropped (they are not load-bearing once a turn
/// is summarized); tool calls render as `name(args)`; tool results are capped
/// at `tool_output_render_cap_bytes` so one large output cannot dominate. The
/// result is the user content of the compaction request. Caller owns it.
pub fn serializePrefix(gpa: std.mem.Allocator, messages: []const ai.ChatMessage) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (messages) |message| {
        try writeMessage(&out.writer, message);
    }
    return out.toOwnedSlice();
}

fn writeMessage(out: *std.Io.Writer, message: ai.ChatMessage) !void {
    const label = message.role.label();
    if (message.role == .tool) {
        try out.print("[tool result]: {s}\n", .{cappedText(firstText(message))});
        return;
    }
    for (message.content) |block| {
        switch (block) {
            .text => |text| try out.print("[{s}]: {s}\n", .{ label, text.text }),
            .tool_call => |call| try out.print("[{s} tool_call]: {s}({s})\n", .{ label, call.name, call.arguments }),
            .reasoning, .image => {},
        }
    }
}

fn firstText(message: ai.ChatMessage) []const u8 {
    for (message.content) |block| {
        if (block == .text) return block.text.text;
    }
    return "";
}

fn cappedText(text: []const u8) []const u8 {
    if (text.len <= tool_output_render_cap_bytes) return text;
    return text[0..tool_output_render_cap_bytes];
}

/// Build the summarizer's user content: the compaction instruction followed by
/// the rendered conversation, wrapped so the model treats it as data to
/// summarize rather than a conversation to continue. Caller owns the result.
pub fn buildSummaryRequest(gpa: std.mem.Allocator, prefix_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\n\n<conversation>\n{s}\n</conversation>", .{ compaction_prompt, prefix_text });
}

/// Inject a produced summary into the handover template's `${SUMMARY}`
/// placeholder, yielding the boundary message stored in the tree. Caller owns
/// the result.
pub fn buildStoredSummary(gpa: std.mem.Allocator, summary: []const u8) ![]u8 {
    assert(summary.len > 0);
    const before = handover_template[0..summary_placeholder_index];
    const after = handover_template[summary_placeholder_index + summary_placeholder.len ..];
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ before, summary, after });
}

fn saturatingLen(slice: []const u8) u32 {
    if (slice.len > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(slice.len);
}

fn divCeil(numerator: u32, denominator: u32) u32 {
    assert(denominator > 0);
    return (numerator + denominator - 1) / denominator;
}

test "context window lookup uses the generated catalogue with a default fallback" {
    // Unknown ids fall back to the conservative default.
    try std.testing.expectEqual(context_window_default_tokens, contextWindowTokens("some-unknown-model"));
    // Exact ids resolve to their real models.dev context window.
    try std.testing.expectEqual(@as(u32, 1_000_000), contextWindowTokens("claude-opus-4-8"));
    try std.testing.expectEqual(@as(u32, 1_047_576), contextWindowTokens("gpt-4.1-mini"));
    // A dated/suffixed variant falls back to its longest-prefix base family.
    try std.testing.expectEqual(@as(u32, 400_000), contextWindowTokens("gpt-5-2025-08-07"));
}

test "summary starts at the lower watermark and swaps at the higher" {
    const window: u32 = 100_000; // start 70_000, swap 90_000
    try std.testing.expect(!shouldStartSummary(70_000, window));
    try std.testing.expect(shouldStartSummary(70_001, window));
    try std.testing.expect(!shouldStartSummary(0, window));
    // The swap watermark sits above the start watermark.
    try std.testing.expect(!shouldSwap(90_000, window));
    try std.testing.expect(shouldSwap(90_001, window));
    try std.testing.expect(!shouldSwap(80_000, window));
}

test "estimate message tokens from content bytes" {
    const gpa = std.testing.allocator;
    var message = try textMessage(gpa, .user, "12345678"); // 8 bytes -> 2 tokens
    defer message.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), estimateMessageTokens(message));
}

test "cut index keeps recent budget and never orphans a tool result" {
    const gpa = std.testing.allocator;
    // 4 messages, each ~25 tokens (100 bytes). keep_recent of 60 tokens keeps
    // the last 3 (75 tokens >= 60 reached at index 1).
    var messages: [4]ai.ChatMessage = undefined;
    messages[0] = try textMessage(gpa, .user, "u" ** 100);
    messages[1] = try textMessage(gpa, .assistant, "a" ** 100);
    messages[2] = try toolMessage(gpa, "t" ** 100);
    messages[3] = try textMessage(gpa, .assistant, "b" ** 100);
    defer for (&messages) |*m| m.deinit(gpa);

    const cut = findCutIndex(&messages, 60);
    // Reached budget at index 1, which is the assistant — not a tool result —
    // so the kept window does not start on an orphaned tool result.
    try std.testing.expect(cut <= 1);
    try std.testing.expect(messages[cut].role != .tool);
}

test "stored summary injects into the handover placeholder" {
    const gpa = std.testing.allocator;
    const stored = try buildStoredSummary(gpa, "GOAL: ship it");
    defer gpa.free(stored);

    // The summary replaces the placeholder (which is gone), inside the tags.
    try std.testing.expect(std.mem.indexOf(u8, stored, summary_placeholder) == null);
    try std.testing.expect(std.mem.indexOf(u8, stored, "GOAL: ship it") != null);
    const open = std.mem.indexOf(u8, stored, "<summary>").?;
    const body = std.mem.indexOf(u8, stored, "GOAL: ship it").?;
    const close = std.mem.indexOf(u8, stored, "</summary>").?;
    try std.testing.expect(open < body);
    try std.testing.expect(body < close);
}

test "cut keeps a recent user message a large tool result pushed out of the tail" {
    const gpa = std.testing.allocator;
    // old assistant turn, then the user's current ask, then a large tool result
    // that alone fills the keep-recent budget and would otherwise exclude the ask.
    var messages: [3]ai.ChatMessage = undefined;
    messages[0] = try textMessage(gpa, .assistant, "z" ** 400); // ~100 tokens
    messages[1] = try textMessage(gpa, .user, "current ask"); // ~3 tokens
    messages[2] = try toolMessage(gpa, "x" ** 400); // ~100 tokens
    defer for (&messages) |*m| m.deinit(gpa);

    // budget 80 keeps only the tool (100t); the user ask sits just before it.
    const cut = findCutIndex(&messages, 80);
    try std.testing.expectEqual(@as(u32, 1), cut); // pulled back to the user ask
    try std.testing.expectEqual(.user, messages[cut].role);
}

test "cut does not force-keep an ancient user message behind heavy tool output" {
    const gpa = std.testing.allocator;
    // one old user ask, then heavy assistant output far exceeding the extend cap.
    var messages: [3]ai.ChatMessage = undefined;
    messages[0] = try textMessage(gpa, .user, "old ask"); // ~2 tokens
    messages[1] = try textMessage(gpa, .assistant, "x" ** 2000); // ~500 tokens
    messages[2] = try textMessage(gpa, .assistant, "y" ** 2000); // ~500 tokens
    defer for (&messages) |*m| m.deinit(gpa);

    // budget 300, extend cap 600; keeping from the user ask would retain ~1002.
    const cut = findCutIndex(&messages, 300);
    try std.testing.expect(cut > 0); // the ancient ask is summarized, not kept
}

test "serialize prefix drops reasoning and tags roles" {
    const gpa = std.testing.allocator;
    var user = try textMessage(gpa, .user, "hello");
    defer user.deinit(gpa);
    var tool = try toolMessage(gpa, "output");
    defer tool.deinit(gpa);

    const text = try serializePrefix(gpa, &.{ user, tool });
    defer gpa.free(text);
    try std.testing.expectEqualStrings("[user]: hello\n[tool result]: output\n", text);
}

fn textMessage(gpa: std.mem.Allocator, role: ai.Role, text: []const u8) !ai.ChatMessage {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    errdefer gpa.free(blocks);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, text) } };
    return .{ .role = role, .content = blocks };
}

fn toolMessage(gpa: std.mem.Allocator, text: []const u8) !ai.ChatMessage {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    errdefer gpa.free(blocks);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, text) } };
    return .{ .role = .tool, .content = blocks, .call_id = try gpa.dupe(u8, "c1") };
}
