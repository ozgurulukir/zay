//! User message queue for the Agent.
//!
//! QueuedUserMessage holds a raw prompt that will be expanded (file embedding,
//! @-mention resolution) lazily on the agent worker thread rather than the UI
//! thread. MessageQueue is a fixed-capacity bounded queue of these messages.

const std = @import("std");
const bounded_queue = @import("bounded_queue");
const assert = std.debug.assert;

/// Capacity of the user-message queue. Must be a power of two.
pub const capacity: u32 = 64;

comptime {
    assert(std.math.isPowerOfTwo(capacity));
}

/// A single queued user message, stored pre-submit until the agent worker
/// drains it.
pub const QueuedUserMessage = struct {
    /// Raw prompt text as typed. `@`-mentions are expanded (files embedded,
    /// images attached) lazily at drain time so the file I/O lands on the
    /// agent worker thread rather than the UI thread.
    prompt: []u8,
    /// When set, this message is injected after the next tool batch ("steer")
    /// rather than waiting for the turn to go idle. The UI flips it via
    /// `setQueuedSteer` when the user steers a queued message.
    steer: bool = false,
    /// When set, the text is delivered verbatim as a user message — no
    /// `@`-mention expansion or skill-prefix handling. Used for machine-
    /// generated content (e.g. background-job completion notices) whose body
    /// must not be reinterpreted as file references.
    raw: bool = false,
};

/// Bounded queue of queued user messages with fixed capacity.
pub const MessageQueue = bounded_queue.BoundedQueue(QueuedUserMessage);

test "capacityIs64AndPowerOfTwo" {
    try std.testing.expectEqual(@as(u32, 64), capacity);
    try std.testing.expect(std.math.isPowerOfTwo(capacity));
}

test "defaultFields_whenQueuedUserMessageInitialized" {
    // Arrange
    var prompt_buf = "hello".*;
    const msg = QueuedUserMessage{ .prompt = &prompt_buf };

    // Act & Assert
    try std.testing.expectEqualStrings("hello", msg.prompt);
    try std.testing.expect(!msg.steer);
    try std.testing.expect(!msg.raw);
}

test "customFields_whenQueuedUserMessageExplicitlySet" {
    // Arrange
    var prompt_buf = "raw prompt".*;
    const msg = QueuedUserMessage{
        .prompt = &prompt_buf,
        .steer = true,
        .raw = true,
    };

    // Act & Assert
    try std.testing.expectEqualStrings("raw prompt", msg.prompt);
    try std.testing.expect(msg.steer);
    try std.testing.expect(msg.raw);
}

test "pushesAndPopsMessages_inFifoOrder" {
    // Arrange
    var buffer: [capacity]QueuedUserMessage = undefined;
    var queue: MessageQueue = .{};
    var prompt1 = "first".*;
    var prompt2 = "second".*;
    const msg1 = QueuedUserMessage{ .prompt = &prompt1 };
    const msg2 = QueuedUserMessage{ .prompt = &prompt2 };

    // Act
    try std.testing.expect(queue.empty());
    try std.testing.expect(queue.push(&buffer, msg1));
    try std.testing.expect(queue.push(&buffer, msg2));

    // Assert
    try std.testing.expectEqual(@as(u32, 2), queue.len());

    const popped1 = queue.pop(&buffer);
    try std.testing.expect(popped1 != null);
    try std.testing.expectEqualStrings("first", popped1.?.prompt);

    const popped2 = queue.pop(&buffer);
    try std.testing.expect(popped2 != null);
    try std.testing.expectEqualStrings("second", popped2.?.prompt);

    try std.testing.expect(queue.empty());
    try std.testing.expectEqual(@as(?QueuedUserMessage, null), queue.pop(&buffer));
}

test "returnsFalse_whenPushingToFullMessageQueue" {
    // Arrange
    var buffer: [capacity]QueuedUserMessage = undefined;
    var queue: MessageQueue = .{};
    var prompt_buf = "msg".*;

    // Act
    var i: u32 = 0;
    while (i < capacity) : (i += 1) {
        try std.testing.expect(queue.push(&buffer, .{ .prompt = &prompt_buf }));
    }

    // Assert
    try std.testing.expect(queue.full(&buffer));
    try std.testing.expectEqual(capacity, queue.len());
    try std.testing.expect(!queue.push(&buffer, .{ .prompt = &prompt_buf }));
    try std.testing.expectEqual(capacity, queue.len());
}

test "wrapsAroundBuffer_whenPoppedAndPushedContinuously" {
    // Arrange
    var buffer: [4]QueuedUserMessage = undefined;
    var queue: MessageQueue = .{};
    var p0 = "m0".*;
    var p1 = "m1".*;
    var p2 = "m2".*;
    var p3 = "m3".*;
    var p4 = "m4".*;
    var p5 = "m5".*;

    // Act: fill buffer to max (capacity 4)
    try std.testing.expect(queue.push(&buffer, .{ .prompt = &p0 }));
    try std.testing.expect(queue.push(&buffer, .{ .prompt = &p1 }));
    try std.testing.expect(queue.push(&buffer, .{ .prompt = &p2 }));
    try std.testing.expect(queue.push(&buffer, .{ .prompt = &p3 }));

    // Pop 2 items (m0, m1) to advance head
    try std.testing.expectEqualStrings("m0", queue.pop(&buffer).?.prompt);
    try std.testing.expectEqualStrings("m1", queue.pop(&buffer).?.prompt);

    // Push 2 items (m4, m5) which wraps around buffer
    try std.testing.expect(queue.push(&buffer, .{ .prompt = &p4 }));
    try std.testing.expect(queue.push(&buffer, .{ .prompt = &p5 }));

    // Assert: items popped in correct FIFO order across ring buffer wrap
    try std.testing.expectEqualStrings("m2", queue.pop(&buffer).?.prompt);
    try std.testing.expectEqualStrings("m3", queue.pop(&buffer).?.prompt);
    try std.testing.expectEqualStrings("m4", queue.pop(&buffer).?.prompt);
    try std.testing.expectEqualStrings("m5", queue.pop(&buffer).?.prompt);
    try std.testing.expect(queue.empty());
}

test "allowsInPlaceMutationAndPeeking_viaAtAndPeek" {
    // Arrange
    var buffer: [capacity]QueuedUserMessage = undefined;
    var queue: MessageQueue = .{};
    var p1 = "msg1".*;
    var p2 = "msg2".*;
    _ = queue.push(&buffer, .{ .prompt = &p1, .steer = false });
    _ = queue.push(&buffer, .{ .prompt = &p2, .steer = false });

    // Act
    const peeked = queue.peek(&buffer);
    try std.testing.expect(peeked != null);
    try std.testing.expectEqualStrings("msg1", peeked.?.prompt);
    try std.testing.expect(!peeked.?.steer);

    // Mutate item 0 via at()
    const item0 = queue.at(&buffer, 0);
    try std.testing.expect(item0 != null);
    item0.?.steer = true;

    // Assert
    try std.testing.expect(queue.peek(&buffer).?.steer);
    const popped = queue.pop(&buffer).?;
    try std.testing.expect(popped.steer);
    try std.testing.expectEqualStrings("msg1", popped.prompt);

    // Check item 1 (now at logical index 0) remains unmodified
    const item_next = queue.at(&buffer, 0);
    try std.testing.expect(item_next != null);
    try std.testing.expect(!item_next.?.steer);
    try std.testing.expectEqualStrings("msg2", item_next.?.prompt);
}
