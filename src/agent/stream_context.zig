//! Wire-stream observation for one provider stream: the coalescing buffers
//! that batch content/reasoning deltas into single listener events, the
//! once-per-tool delta flags the executor bridge consults, and the typed
//! stream-observer wrappers those callbacks run through.
//!
//! Ownership: this module owns only the stream-local state. `Agent.run`
//! constructs the context on its stack each model iteration and keeps the
//! ordering contract around it — the explicit end-of-stream flush before
//! message finalization and tool dispatch, plus the `defer` teardown —
//! because that ordering is against Agent's own event queue. `ExecutorBridge`
//! holds a `*const StreamContext` to consult `toolDeltaSeen` during tool
//! dispatch. Coupling to `Agent` is allocator-only: the context takes a
//! `gpa` and reads no agent state, so there is no back-reference (the #367
//! slice-4 seam, extraction over facade). The `on*Impl` wrappers are pub
//! for agent.zig's stream-callback tests, which drive the wire path
//! directly; `emitToolDelta` is also pub for the `tool_batch.emitToolDelta`
//! delegate (ExecutorBridge's synthesized tool_delta).

const std = @import("std");
const ai = @import("../ai.zig");
const stream_parser = @import("../ai/stream_parser.zig");

const log = std.log.scoped(.stream_context);

/// Byte threshold at which a pending buffer flushes mid-stream. ~2s of text
/// at 100 tok/s, ~0.4s at 500 tok/s. A config knob adds surface area for
/// little gain; a comptime constant is simpler.
const coalesce_threshold_bytes: usize = 1024;

/// Per-stream context shared between the agent and the ai client's
/// stream observer callbacks. Holds the typed listener plus once-per-tool
/// delta tracking. The `observer()` method builds a
/// `StreamObserver(*Self)` whose callbacks are comptime-baked wrappers
/// around this `StreamContext` and its typed listener — no
/// `@ptrCast` at the seam.
pub fn StreamContext(comptime L: type) type {
    return struct {
        gpa: std.mem.Allocator,
        listener: L,
        /// Fixed per-tool-slot "first delta seen" flags for the executor
        /// bridge, replacing the old grown `ArrayList(bool)` scan with an
        /// O(1) index. Sized by the SSOT `tool_call_array_cap`
        /// (stream_parser.zig), which already bounds the tool slots.
        tool_delta_seen: [stream_parser.tool_call_array_cap]bool = @splat(false),
        /// Coalesced content bytes awaiting a flush. Multiple consecutive
        /// `on_content` deltas accumulate here and are emitted as a single
        /// `response_delta`, cutting per-token allocs/locks on the dominant
        /// content path.
        pending_content: std.ArrayList(u8) = .empty,
        /// Coalesced reasoning bytes, flushed as a single `thinking_delta`.
        pending_reasoning: std.ArrayList(u8) = .empty,
        /// One-shot pre-sizing flags for the pending buffers (step #7); the
        /// ArrayList grows on first append, so these — not `capacity == 0` —
        /// are the reliable signal for the first-delta sizing hint.
        content_sized: bool = false,
        reasoning_sized: bool = false,
        emit_failed: bool = false,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            // Belt-and-suspenders flush: frees + flushes any bytes stranded
            // on an early-return/error path that skipped the explicit
            // end-of-stream flush. Skip if an earlier emit already failed so
            // teardown never replays the same delta (#543).
            if (!self.emit_failed) {
                self.flushPending() catch |err| {
                    // The stranded tail is dropped without replay (#543), so
                    // this is the only trace the truncated response leaves —
                    // log it instead of vanishing (#554).
                    log.warn("deferred stream flush failed on teardown; response tail dropped without replay: {s}", .{@errorName(err)});
                };
            }
            self.pending_content.deinit(self.gpa);
            self.pending_reasoning.deinit(self.gpa);
        }

        pub fn toolDeltaSeen(self: *const Self, tool_index: u32) bool {
            if (tool_index >= self.tool_delta_seen.len) return false;
            return self.tool_delta_seen[tool_index];
        }

        fn markToolDeltaSeen(self: *Self, tool_index: u32) void {
            if (tool_index >= self.tool_delta_seen.len) return;
            self.tool_delta_seen[tool_index] = true;
        }

        /// Emit any pending content/reasoning as a single event each and
        /// reset the buffers, retaining capacity for the next batch.
        pub fn flushPending(self: *Self) !void {
            if (self.pending_reasoning.items.len > 0) {
                const owned = try self.gpa.dupe(u8, self.pending_reasoning.items);
                self.listener.emit(.{ .thinking_delta = owned }) catch |err| {
                    self.emit_failed = true;
                    return err;
                };
                self.pending_reasoning.clearRetainingCapacity();
            }
            if (self.pending_content.items.len > 0) {
                const owned = try self.gpa.dupe(u8, self.pending_content.items);
                self.listener.emit(.{ .response_delta = owned }) catch |err| {
                    self.emit_failed = true;
                    return err;
                };
                self.pending_content.clearRetainingCapacity();
            }
            self.emit_failed = false;
        }

        pub fn observer(self: *Self) ai.StreamObserver(Self) {
            return .{
                .ctx = self,
                .on_content = onContentDeltaImpl(L),
                .on_reasoning = onReasoningDeltaImpl(L),
                .on_tool_delta = onToolDeltaImpl(L),
                .on_delta_end = onDeltaEndImpl(L),
            };
        }

        fn maybeSizeContent(self: *Self, delta: []const u8) !void {
            if (self.content_sized) return;
            try self.pending_content.ensureTotalCapacity(self.gpa, delta.len * 4);
            self.content_sized = true;
        }

        fn maybeSizeReasoning(self: *Self, delta: []const u8) !void {
            if (self.reasoning_sized) return;
            try self.pending_reasoning.ensureTotalCapacity(self.gpa, delta.len * 4);
            self.reasoning_sized = true;
        }
    };
}

pub fn onContentDeltaImpl(comptime L: type) *const fn (*StreamContext(L), []const u8) anyerror!void {
    const F = struct {
        fn call(ctx: *StreamContext(L), delta: []const u8) anyerror!void {
            // Preserve wire order: flush reasoning before buffering content
            // when a cross-type sequence fires reason-before-content.
            if (ctx.pending_reasoning.items.len > 0) try ctx.flushPending();
            try ctx.maybeSizeContent(delta);
            try ctx.pending_content.appendSlice(ctx.gpa, delta);
            if (ctx.pending_content.items.len >= coalesce_threshold_bytes) {
                try ctx.flushPending();
            }
        }
    };
    return &F.call;
}

pub fn onReasoningDeltaImpl(comptime L: type) *const fn (*StreamContext(L), []const u8) anyerror!void {
    const F = struct {
        fn call(ctx: *StreamContext(L), delta: []const u8) anyerror!void {
            // Preserve wire order: flush content before buffering reasoning.
            if (ctx.pending_content.items.len > 0) try ctx.flushPending();
            try ctx.maybeSizeReasoning(delta);
            try ctx.pending_reasoning.appendSlice(ctx.gpa, delta);
            if (ctx.pending_reasoning.items.len >= coalesce_threshold_bytes) {
                try ctx.flushPending();
            }
        }
    };
    return &F.call;
}

pub fn onToolDeltaImpl(comptime L: type) *const fn (*StreamContext(L), ai.ToolDelta) anyerror!void {
    const F = struct {
        fn call(ctx: *StreamContext(L), delta: ai.ToolDelta) anyerror!void {
            // Preserve wire order: flush any pending content/reasoning before
            // the tool preview so the transcript sees text first.
            try ctx.flushPending();
            ctx.markToolDeltaSeen(delta.index);
            try emitToolDelta(L, ctx.gpa, ctx.listener, delta.index, delta.name, delta.arguments);
        }
    };
    return &F.call;
}

pub fn onDeltaEndImpl(comptime L: type) *const fn (*StreamContext(L)) anyerror!void {
    const F = struct {
        fn call(ctx: *StreamContext(L)) anyerror!void {
            // delta_end stays a pure no-op for coalescing: flushing here is
            // handled by the byte threshold, the cross-type flush, the tool
            // delta pre-flush, and the explicit post-prompt flush.
            try ctx.listener.emit(.delta_end);
        }
    };
    return &F.call;
}

pub fn emitToolDelta(
    comptime L: type,
    gpa: std.mem.Allocator,
    listener: L,
    tool_index: u32,
    name: []const u8,
    arguments: []const u8,
) !void {
    var transferred = false;
    const owned_name = try gpa.dupe(u8, name);
    errdefer if (!transferred) gpa.free(owned_name);
    const owned_arguments = try gpa.dupe(u8, arguments);
    errdefer if (!transferred) gpa.free(owned_arguments);
    transferred = true;
    try listener.emit(.{
        .tool_delta = .{
            .index = tool_index,
            .name = owned_name,
            .arguments = owned_arguments,
        },
    });
}

/// Minimal duck-typed event for the failure-path tests below. Mirrors the
/// listener ownership contract (a listener that reports failure has not
/// consumed the event and deinits its payload itself — see
/// `agent_worker.postAgentEvent`'s errdefer) so the testing allocator's leak
/// check can police the teardown path.
const TestEvent = union(enum) {
    thinking_delta: []const u8,
    response_delta: []const u8,

    fn deinit(self: *TestEvent, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .thinking_delta, .response_delta => |payload| gpa.free(payload),
        }
    }
};

const TestListener = struct {
    gpa: std.mem.Allocator,
    emits: usize = 0,
    fail_all: bool = true,

    pub fn emit(self: *TestListener, event: TestEvent) anyerror!void {
        self.emits += 1;
        if (self.fail_all) {
            var owned = event;
            owned.deinit(self.gpa);
            return error.EmitFailed;
        }
        var owned = event;
        owned.deinit(self.gpa);
    }
};

test "deferred flush failure on teardown is attempted, swallowed, and not replayed" {
    const gpa = std.testing.allocator;
    var listener: TestListener = .{ .gpa = gpa };
    var context: StreamContext(*TestListener) = .{
        .gpa = gpa,
        .listener = &listener,
    };

    // Buffer below the coalesce threshold so nothing flushes mid-stream; the
    // only flush attempt is the teardown one.
    try onContentDeltaImpl(*TestListener)(&context, "stranded tail");

    context.deinit();
    // One emit: the teardown flush itself (it failed). The emit_failed latch
    // from that failure means no second attempt can ever replay the delta.
    try std.testing.expectEqual(@as(usize, 1), listener.emits);
    try std.testing.expect(context.emit_failed);
}

test "a prior emit failure skips the teardown flush entirely" {
    const gpa = std.testing.allocator;
    var listener: TestListener = .{ .gpa = gpa };
    var context: StreamContext(*TestListener) = .{
        .gpa = gpa,
        .listener = &listener,
    };

    try onContentDeltaImpl(*TestListener)(&context, "first tail");
    try std.testing.expectError(error.EmitFailed, context.flushPending());
    try std.testing.expect(context.emit_failed);
    const emits_after_failed_flush = listener.emits;

    // More content after the failure must not be flushed on teardown (#543:
    // no replay), so the emit count stays frozen.
    try onContentDeltaImpl(*TestListener)(&context, "second tail");
    context.deinit();
    try std.testing.expectEqual(emits_after_failed_flush, listener.emits);
}
