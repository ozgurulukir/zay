//! Build-time generator: reads the vendored models.dev `models.json` and
//! `api.json` snapshots and emits two modules:
//!
//!   `model_catalog.zig` — static table mapping model id → token limits
//!   `provider_registry.zig` — static table of provider id → base_url + name
//!                             filtered to @ai-sdk/openai-compatible providers
//!
//! Wired into `build.zig`; both emitted files are imported at build time.
//!
//! Invocation (set up by build.zig):
//!   gen-model-catalog <models.json> <api.json> <model_catalog.zig> <provider_registry.zig>
//!
//! Refresh by re-curling both files and rebuilding:
//!   curl -o vendor/models.dev/models.json https://models.dev/models.json
//!   curl -o vendor/models.dev/api.json    https://models.dev/api.json
//!   zig build

const std = @import("std");

const ModelEntry = struct {
    id: []const u8,
    context: u32,
    output: u32,
};

const ProviderEntry = struct {
    id: []const u8,
    name: []const u8,
    base_url: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next(); // executable path
    const models_path = arg_it.next() orelse return error.MissingModelsArg;
    const api_path = arg_it.next() orelse return error.MissingApiArg;
    const model_catalog_path = arg_it.next() orelse return error.MissingModelCatalogArg;
    const provider_registry_path = arg_it.next() orelse return error.MissingProviderRegistryArg;

    // ── Read models.json (model → token limits) ──
    const models_bytes = try std.Io.Dir.cwd().readFileAlloc(io, models_path, gpa, .unlimited);
    defer gpa.free(models_bytes);

    const models_parsed = try std.json.parseFromSlice(std.json.Value, gpa, models_bytes, .{});
    defer models_parsed.deinit();
    if (models_parsed.value != .object) return error.ModelsRootNotObject;

    var model_entries: std.ArrayList(ModelEntry) = .empty;
    defer model_entries.deinit(gpa);

    {
        var it = models_parsed.value.object.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const slash = std.mem.indexOfScalar(u8, key, '/') orelse continue;
            const model_id = key[slash + 1 ..];
            if (model_id.len == 0) continue;
            if (kv.value_ptr.* != .object) continue;
            const limit = kv.value_ptr.object.get("limit") orelse continue;
            if (limit != .object) continue;
            const context = limitField(limit, "context") orelse continue;
            const output = limitField(limit, "output") orelse 0;
            try model_entries.append(gpa, .{ .id = model_id, .context = context, .output = output });
        }
    }
    std.mem.sort(ModelEntry, model_entries.items, {}, lessThanById(ModelEntry));

    // ── Read api.json (provider → base_url + name) ──
    // Only include providers whose `npm` field is `@ai-sdk/openai-compatible`
    // AND that expose an `api` field. This guarantees every entry in the
    // registry speaks the OpenAI-compatible protocol that Nova's
    // `openai_compatible` adapter can drive.
    const api_bytes = try std.Io.Dir.cwd().readFileAlloc(io, api_path, gpa, .unlimited);
    defer gpa.free(api_bytes);

    const api_parsed = try std.json.parseFromSlice(std.json.Value, gpa, api_bytes, .{});
    defer api_parsed.deinit();
    if (api_parsed.value != .object) return error.ApiRootNotObject;

    var provider_entries: std.ArrayList(ProviderEntry) = .empty;
    defer provider_entries.deinit(gpa);

    {
        var it = api_parsed.value.object.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* != .object) continue;

            // Only include providers whose npm field confirms OpenAI-compatible.
            const npm_field = kv.value_ptr.object.get("npm") orelse continue;
            if (npm_field != .string) continue;
            if (!std.mem.eql(u8, npm_field.string, "@ai-sdk/openai-compatible")) continue;

            // Must have an api (base URL) field.
            const api_field = kv.value_ptr.object.get("api") orelse continue;
            if (api_field != .string) continue;

            const name_field = kv.value_ptr.object.get("name") orelse continue;
            if (name_field != .string) continue;

            // Must serve at least one model.
            const models_field = kv.value_ptr.object.get("models") orelse continue;
            if (models_field != .object) continue;
            if (models_field.object.count() == 0) continue;

            try provider_entries.append(gpa, .{
                .id = kv.key_ptr.*,
                .name = name_field.string,
                .base_url = api_field.string,
            });
        }
    }
    std.mem.sort(ProviderEntry, provider_entries.items, {}, lessThanById(ProviderEntry));

    // ── Write model_catalog.zig ──
    {
        if (std.fs.path.dirname(model_catalog_path)) |dir| {
            try std.Io.Dir.createDirPath(.cwd(), io, dir);
        }

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;

        try w.writeAll(
            \\// GENERATED by tools/gen_model_catalog.zig from vendor/models.dev/models.json.
            \\// Do not edit by hand.
            \\
            \\pub const Entry = struct {
            \\    id: []const u8,
            \\    context: u32,
            \\    output: u32,
            \\};
            \\
            \\pub const entries = [_]Entry{
            \\
        );
        for (model_entries.items) |entry| {
            try w.print("    .{{ .id = \"{s}\", .context = {d}, .output = {d} }},\n", .{ entry.id, entry.context, entry.output });
        }
        try w.writeAll("};\n");

        const file = try std.Io.Dir.cwd().createFile(io, model_catalog_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, out.written());
    }

    // ── Write provider_registry.zig ──
    {
        if (std.fs.path.dirname(provider_registry_path)) |dir| {
            try std.Io.Dir.createDirPath(.cwd(), io, dir);
        }

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;

        try w.writeAll(
            \\// GENERATED by tools/gen_model_catalog.zig from vendor/models.dev/api.json.
            \\// Do not edit by hand.
            \\// Only includes providers whose models.dev `npm` field is
            \\// `@ai-sdk/openai-compatible` — every entry here speaks the
            \\// OpenAI-compatible protocol that Nova's adapter can drive.
            \\
            \\const std = @import("std");
            \\
            \\/// A models.dev provider with an OpenAI-compatible API endpoint.
            \\pub const Provider = struct {
            \\    id: []const u8,
            \\    name: []const u8,
            \\    base_url: []const u8,
            \\};
            \\
            \\/// All providers discovered from models.dev that expose an
            \\/// OpenAI-compatible `api` field. Sorted by `id`.
            \\pub const providers = [_]Provider{
            \\
        );
        for (provider_entries.items) |entry| {
            try w.print("    .{{ .id = \"{s}\", .name = \"{s}\", .base_url = \"{s}\" }},\n", .{ entry.id, entry.name, entry.base_url });
        }
        try w.writeAll(
            \\};
            \\
            \\/// Look up a provider's base URL by its models.dev id.
            \\/// Returns null when the id is not in the registry.
            \\pub fn lookupBaseUrl(id: []const u8) ?[]const u8 {
            \\    for (providers) |p| {
            \\        if (std.mem.eql(u8, p.id, id)) return p.base_url;
            \\    }
            \\    return null;
            \\}
            \\
            \\/// Look up a provider's display name by its models.dev id.
            \\/// Returns null when the id is not in the registry.
            \\pub fn lookupName(id: []const u8) ?[]const u8 {
            \\    for (providers) |p| {
            \\        if (std.mem.eql(u8, p.id, id)) return p.name;
            \\    }
            \\    return null;
            \\}
            \\
        );

        const file = try std.Io.Dir.cwd().createFile(io, provider_registry_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, out.written());
    }
}

fn limitField(limit: std.json.Value, name: []const u8) ?u32 {
    const value = limit.object.get(name) orelse return null;
    if (value != .integer) return null;
    if (value.integer < 0) return 0;
    if (value.integer > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(value.integer);
}

fn lessThanById(comptime T: type) fn (void, T, T) bool {
    return struct {
        fn cmp(_: void, a: T, b: T) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.cmp;
}
