//! Inbound response semantics, independent of request serialization dialects.
//! Adapters classify wire fields here; orchestration and presentation consume
//! the resulting text/reasoning types without inspecting generated prose.

const std = @import("std");

pub const TextKind = enum { text, reasoning, ignore };

/// Missing fields inherit from the provider or lower configuration layer.
pub const Overrides = struct {
    reasoning: ?TextKind = null,
    reasoning_content: ?TextKind = null,
    reasoning_details: ?TextKind = null,
    thinking: ?TextKind = null,

    pub fn overlay(self: *Overrides, update: Overrides) void {
        inline for (std.meta.fields(Overrides)) |field| {
            if (@field(update, field.name)) |kind| @field(self, field.name) = kind;
        }
    }

    pub fn apply(self: Overrides, base: Policy) Policy {
        var result = base;
        inline for (std.meta.fields(Overrides)) |field| {
            if (@field(self, field.name)) |kind| @field(result, field.name) = kind;
        }
        return result;
    }
};

/// Value-only overrides can be attached to a provider/model configuration
/// without introducing borrowed strings or additional client ownership.
pub const Policy = struct {
    reasoning: TextKind = .reasoning,
    reasoning_content: TextKind = .reasoning,
    reasoning_details: TextKind = .reasoning,
    thinking: TextKind = .ignore,

    pub fn fieldKind(self: Policy, field: []const u8) TextKind {
        if (std.mem.eql(u8, field, "content")) return .text;
        if (std.mem.eql(u8, field, "reasoning")) return self.reasoning;
        if (std.mem.eql(u8, field, "reasoning_content")) return self.reasoning_content;
        if (std.mem.eql(u8, field, "reasoning_details")) return self.reasoning_details;
        if (std.mem.eql(u8, field, "thinking")) return self.thinking;
        return .ignore;
    }

    pub fn partKind(self: Policy, part_type: []const u8) TextKind {
        if (std.mem.eql(u8, part_type, "text") or std.mem.eql(u8, part_type, "output_text") or std.mem.eql(u8, part_type, "refusal")) return .text;
        if (std.mem.eql(u8, part_type, "reasoning.text") or std.mem.eql(u8, part_type, "reasoning.summary") or std.mem.eql(u8, part_type, "reasoning_text") or std.mem.eql(u8, part_type, "summary_text")) return .reasoning;
        if (std.mem.eql(u8, part_type, "thinking")) return self.thinking;
        // Opaque/encrypted/redacted content is never display text.
        return .ignore;
    }

    /// Provider identity controls extensions. Model quirks belong in an
    /// explicit Policy override, rather than substring guesses about models.
    pub fn resolve(provider: []const u8, base_url: []const u8) Policy {
        if (std.ascii.eqlIgnoreCase(provider, "ollama")) return .{ .thinking = .reasoning };
        const uri = std.Uri.parse(base_url) catch return .{};
        const host = uri.host orelse return .{};
        const hostname = switch (host) {
            .raw => |value| value,
            .percent_encoded => |value| value,
        };
        if (std.ascii.eqlIgnoreCase(hostname, "ollama.com")) return .{ .thinking = .reasoning };
        return .{};
    }
};

test "response policy keeps answers separate from reasoning and unknown fields" {
    const policy: Policy = .{};
    try std.testing.expectEqual(TextKind.text, policy.fieldKind("content"));
    try std.testing.expectEqual(TextKind.reasoning, policy.fieldKind("reasoning_content"));
    try std.testing.expectEqual(TextKind.reasoning, policy.fieldKind("reasoning"));
    try std.testing.expectEqual(TextKind.ignore, policy.fieldKind("thinking"));
    try std.testing.expectEqual(TextKind.ignore, policy.fieldKind("analysis"));
}

test "response policy supports explicit model and proxy field semantics" {
    const policy: Policy = .{ .thinking = .text, .reasoning = .ignore };
    try std.testing.expectEqual(TextKind.text, policy.fieldKind("thinking"));
    try std.testing.expectEqual(TextKind.ignore, policy.fieldKind("reasoning"));
    try std.testing.expectEqual(TextKind.text, policy.fieldKind("content"));
}

test "response policy resolves extensions from provider identity or exact host" {
    try std.testing.expectEqual(TextKind.reasoning, Policy.resolve("ollama", "http://localhost:11434/v1").thinking);
    try std.testing.expectEqual(TextKind.reasoning, Policy.resolve("custom", "https://ollama.com/v1").thinking);
    try std.testing.expectEqual(TextKind.ignore, Policy.resolve("custom", "https://example.com/ollama.com/v1").thinking);
    try std.testing.expectEqual(TextKind.ignore, Policy.resolve("custom", "https://ollama.com.example.com/v1").thinking);
}

test "response policy overrides inherit unspecified provider and model fields" {
    var provider: Overrides = .{ .thinking = .reasoning, .reasoning = .ignore };
    provider.overlay(.{ .thinking = .text });
    const model: Overrides = .{ .reasoning_content = .text };
    const policy = model.apply(provider.apply(.{}));
    try std.testing.expectEqual(TextKind.text, policy.thinking);
    try std.testing.expectEqual(TextKind.ignore, policy.reasoning);
    try std.testing.expectEqual(TextKind.text, policy.reasoning_content);
}
