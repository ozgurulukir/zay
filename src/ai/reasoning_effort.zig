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

    /// Comma-joined vocabulary for diagnostics ("default,minimal,...,max").
    /// Config parse warnings name the accepted set so a typo'd user config
    /// explains itself instead of silently falling back.
    pub const label_csv: []const u8 = blk: {
        var names: []const u8 = "";
        for (std.meta.fields(ReasoningEffort), 0..) |field, i| {
            if (i > 0) names = names ++ ",";
            names = names ++ field.name;
        }
        break :blk names;
    };
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

/// One schema traversal step: fetch `key` from a JSON object and fail the
/// test naming the drifted key. The schema is hand-edited, so the diagnostic
/// must say which key moved or was retyped; a bare `.?` unwrap would only
/// panic with an anonymous null error.
fn schemaField(value: std.json.Value, key: []const u8) !std.json.Value {
    if (value != .object) {
        std.debug.print("config schema drift: while fetching \"{s}\", the traversed value is {s}, expected object\n", .{ key, @tagName(value) });
        return error.SchemaShapeDrift;
    }
    if (value.object.get(key)) |child| return child;
    std.debug.print("config schema drift: key \"{s}\" missing\n", .{key});
    return error.SchemaShapeDrift;
}

/// The enum array stored at `key`, with the same named-key diagnostics.
fn schemaEnumList(value: std.json.Value, key: []const u8) ![]const std.json.Value {
    const list = try schemaField(value, key);
    if (list != .array) {
        std.debug.print("config schema drift: \"{s}\" is {s}, expected array\n", .{ key, @tagName(list) });
        return error.SchemaShapeDrift;
    }
    return list.array.items;
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
    const defs = try schemaField(parsed.value, "$defs");
    const model_def = try schemaField(defs, "ModelConfig");
    const properties = try schemaField(model_def, "properties");
    const effort_def = try schemaField(properties, "reasoningEffort");
    const options_def = try schemaField(properties, "reasoningOptions");
    const effort_enum = try schemaEnumList(effort_def, "enum");
    const options_items = try schemaField(options_def, "items");
    const options_enum = try schemaEnumList(options_items, "enum");

    // Count equality pins the negative space: the schema may not carry a
    // level this vocabulary lacks. The loop below pins the positive space:
    // every level the vocabulary defines must appear in both schema lists.
    const field_count = @typeInfo(ReasoningEffort).@"enum".fields.len;
    try std.testing.expectEqual(field_count, effort_enum.len);
    try std.testing.expectEqual(field_count, options_enum.len);
    inline for (std.meta.fields(ReasoningEffort)) |field| {
        try std.testing.expect(schemaEnumContains(effort_enum, field.name));
        try std.testing.expect(schemaEnumContains(options_enum, field.name));
    }
}
