const std = @import("std");
const ai = @import("../ai.zig");
const core = @import("responses_core.zig");

pub const Client = struct {
    core_client: core.Client,

    pub fn init(target: *Client, gpa: std.mem.Allocator, io: std.Io, config: ai.Config) !void {
        var openai_config = config;
        openai_config.provider = .openai_compatible;
        try target.core_client.init(gpa, io, openai_config);
    }

    pub fn deinit(self: *Client) void {
        self.core_client.deinit();
        self.* = undefined;
    }

    pub fn prompt(self: *Client, messages: []const ai.ChatMessage, observer: ai.StreamObserver) !ai.Turn {
        return self.core_client.prompt(messages, observer);
    }
};

test {
    std.testing.refAllDecls(@This());
}
