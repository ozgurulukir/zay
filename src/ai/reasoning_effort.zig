//! Reasoning-effort vocabulary: the single source for every reasoning-effort
//! level the wire, the config parser, the session store, and the UI picker
//! express. Config imports this leaf directly, so config-only changes never
//! touch the ai wire stack. The `reasoningEffort` and `reasoningOptions`
//! enums in `schema/config.schema.json` are cross-checked against this
//! vocabulary by the test below.

const std = @import("std");

pub const ReasoningEffort = enum {
    /// Don't override the model's default reasoning behaviour — no
    /// `reasoning_effort` parameter is sent in the request.
    default,
    minimal,
    low,
    none,
    medium,
    high,
    xhigh,
    /// Highest reasoning effort (OpenRouter extension). The official OpenAPI
    /// enum is `["max","xhigh","high","medium","low","minimal","none"]`; `max`
    /// is the top level, above `xhigh`. OpenAI-native dialects ignore it.
    max,

    pub fn label(self: ReasoningEffort) []const u8 {
        return @tagName(self);
    }

    /// Parse a persisted effort label back into the enum. Mirrors
    /// `Role.fromString`: a string match → enum or error. Used to restore
    /// session-scoped reasoning effort from the DB on resume. An unknown
    /// label (e.g. from a newer schema or hand-edited data) errors instead
    /// of silently mapping to a wrong level.
    pub fn fromString(text: []const u8) !ReasoningEffort {
        return std.meta.stringToEnum(ReasoningEffort, text) orelse error.InvalidReasoningEffort;
    }
};

test "ReasoningEffort.fromString round-trips labels and rejects unknowns" {
    try std.testing.expectEqual(ReasoningEffort.default, try ReasoningEffort.fromString("default"));
    try std.testing.expectEqual(ReasoningEffort.high, try ReasoningEffort.fromString("high"));
    try std.testing.expectEqual(ReasoningEffort.none, try ReasoningEffort.fromString("none"));
    try std.testing.expectEqual(ReasoningEffort.max, try ReasoningEffort.fromString("max"));
    try std.testing.expectEqualStrings("max", ReasoningEffort.max.label());
    try std.testing.expectError(error.InvalidReasoningEffort, ReasoningEffort.fromString("turbo"));
    try std.testing.expectError(error.InvalidReasoningEffort, ReasoningEffort.fromString(""));
}

/// True when the schema enum list carries `tag`. Non-string entries can't
/// match, so a malformed schema fails the count check below instead.
fn schemaEnumContains(schema_enum: []const std.json.Value, tag: []const u8) bool {
    for (schema_enum) |entry| {
        if (entry == .string and std.mem.eql(u8, entry.string, tag)) return true;
    }
    return false;
}

test "config schema reasoning-effort enums match this vocabulary exactly" {
    // Reads the schema from the repo root — the documented `zig build test`
    // invocation runs from there; a missing file fails the test loudly.
    const io = std.testing.io;
    const file = try std.Io.Dir.openFile(.cwd(), io, "schema/config.schema.json", .{});
    defer file.close(io);
    const schema_len: usize = @intCast(try file.length(io));
    const schema_text = try std.testing.allocator.alloc(u8, schema_len);
    defer std.testing.allocator.free(schema_text);
    try std.testing.expectEqual(schema_len, try file.readPositionalAll(io, schema_text, 0));
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema_text, .{});
    defer parsed.deinit();
    const model_config = parsed.value.object.get("$defs").?.object.get("ModelConfig").?.object.get("properties").?.object;
    const effort_enum = model_config.get("reasoningEffort").?.object.get("enum").?.array;
    const options_enum = model_config.get("reasoningOptions").?.object.get("items").?.object.get("enum").?.array;

    // Count equality pins the negative space: the schema may not carry a
    // level this vocabulary lacks. The loop below pins the positive space:
    // every level the vocabulary defines must appear in both schema lists.
    const field_count = @typeInfo(ReasoningEffort).@"enum".fields.len;
    try std.testing.expectEqual(field_count, effort_enum.items.len);
    try std.testing.expectEqual(field_count, options_enum.items.len);
    inline for (std.meta.fields(ReasoningEffort)) |field| {
        try std.testing.expect(schemaEnumContains(effort_enum.items, field.name));
        try std.testing.expect(schemaEnumContains(options_enum.items, field.name));
    }
}
