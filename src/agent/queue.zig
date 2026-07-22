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
