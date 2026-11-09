//! Database backend vocabulary: the single source for every backend name the
//! `ZAY_DATABASE_BACKEND` env var, `config.json`'s `database.backend`,
//! `schema/config.schema.json`, and the session store express. Config imports
//! this leaf directly and re-exports the type; session/backend.zig maps its
//! own store-side tags through the leaf so the two vocabularies cannot drift
//! (the `/database` notice string-compares the two `asString` outputs). The
//! `database.backend` enum in `schema/config.schema.json` is cross-checked
//! against this vocabulary by the test below.

const std = @import("std");

/// Database backend selection for session persistence and roaming sync.
/// The canonical tags are also the wire labels `asString` writes to
/// `config.json`, so a renamed tag is a config-format change and must not
/// happen casually.
pub const DatabaseBackendKind = enum {
    local,
    zay_service,
    turso_http,
    d1_http,
    postgres_native,

    pub fn fromString(str: []const u8) ?DatabaseBackendKind {
        if (std.mem.eql(u8, str, "local") or std.mem.eql(u8, str, "local_sqlite") or std.mem.eql(u8, str, "sqlite")) return .local;
        if (std.mem.eql(u8, str, "zay_service") or std.mem.eql(u8, str, "remote_service") or std.mem.eql(u8, str, "service")) return .zay_service;
        if (std.mem.eql(u8, str, "turso_http") or std.mem.eql(u8, str, "turso") or std.mem.eql(u8, str, "libsql")) return .turso_http;
        if (std.mem.eql(u8, str, "d1_http") or std.mem.eql(u8, str, "d1") or std.mem.eql(u8, str, "cloudflare_d1") or std.mem.eql(u8, str, "cloudflare")) return .d1_http;
        if (std.mem.eql(u8, str, "postgres_native") or std.mem.eql(u8, str, "postgres") or std.mem.eql(u8, str, "postgresql")) return .postgres_native;
        return null;
    }

    pub fn asString(self: DatabaseBackendKind) []const u8 {
        return switch (self) {
            .local => "local",
            .zay_service => "zay_service",
            .turso_http => "turso_http",
            .d1_http => "d1_http",
            .postgres_native => "postgres_native",
        };
    }
};

test "DatabaseBackendKind.fromString accepts every documented alias and round-trips asString" {
    const AliasRow = struct { tag: DatabaseBackendKind, aliases: []const []const u8 };
    const alias_table = [_]AliasRow{
        .{ .tag = .local, .aliases = &.{ "local", "local_sqlite", "sqlite" } },
        .{ .tag = .zay_service, .aliases = &.{ "zay_service", "remote_service", "service" } },
        .{ .tag = .turso_http, .aliases = &.{ "turso_http", "turso", "libsql" } },
        .{ .tag = .d1_http, .aliases = &.{ "d1_http", "d1", "cloudflare_d1", "cloudflare" } },
        .{ .tag = .postgres_native, .aliases = &.{ "postgres_native", "postgres", "postgresql" } },
    };
    for (alias_table) |row| {
        for (row.aliases) |alias| {
            try std.testing.expectEqual(row.tag, DatabaseBackendKind.fromString(alias).?);
        }
    }

    // The wire labels are the config.json values the schema enum pins; spell
    // them out so a label change fails here before it fails a user's config.
    try std.testing.expectEqualStrings("local", DatabaseBackendKind.local.asString());
    try std.testing.expectEqualStrings("zay_service", DatabaseBackendKind.zay_service.asString());
    try std.testing.expectEqualStrings("turso_http", DatabaseBackendKind.turso_http.asString());
    try std.testing.expectEqualStrings("d1_http", DatabaseBackendKind.d1_http.asString());
    try std.testing.expectEqualStrings("postgres_native", DatabaseBackendKind.postgres_native.asString());

    // Negative space: empty and unknown names parse to null, not to a
    // silently-wrong backend.
    try std.testing.expectEqual(@as(?DatabaseBackendKind, null), DatabaseBackendKind.fromString(""));
    try std.testing.expectEqual(@as(?DatabaseBackendKind, null), DatabaseBackendKind.fromString("bogus_backend"));
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

test "config schema database backend enum matches this vocabulary exactly" {
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
    const database_def = try schemaField(defs, "DatabaseConfig");
    const properties = try schemaField(database_def, "properties");
    const backend_def = try schemaField(properties, "backend");
    const backend_enum = try schemaEnumList(backend_def, "enum");

    // Count equality pins the negative space: the schema may not carry a
    // backend this vocabulary lacks. The loop below pins the positive space:
    // every backend the vocabulary defines must appear in the schema list.
    const field_count = @typeInfo(DatabaseBackendKind).@"enum".fields.len;
    try std.testing.expectEqual(field_count, backend_enum.len);
    inline for (std.meta.fields(DatabaseBackendKind)) |field| {
        try std.testing.expect(schemaEnumContains(backend_enum, field.name));
    }
}
