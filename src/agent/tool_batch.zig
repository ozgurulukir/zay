//! ToolBatch — a snapshot of tool calls collected from an assistant message.
//!
//! Created before executing a tool round so the agent can release the
//! assistant message's memory early.

const std = @import("std");
const ai = @import("../ai.zig");

const assert = std.debug.assert;

/// Snapshot of tool calls from an assistant message, collected before the
/// streaming result is freed.
pub const ToolBatch = struct {
    calls: []const ai.ToolCall,

    pub fn init(calls: []const ai.ToolCall) ToolBatch {
        assert(calls.len > 0);
        return .{ .calls = calls };
    }
};
