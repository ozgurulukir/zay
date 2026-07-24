//! Runtime models.dev provider registry.
//!
//! Merges two sources into a single provider list:
//!   1. Builtin providers (OpenAI Codex OAuth, OpenRouter, Cerebras, etc.)
//!      defined as a comptime constant in this file.
//!   2. `https://models.dev/api.json` — fetched on demand, cached to
//!      `~/.nova/cache/models.dev/api.json` with a 24-hour TTL.
//!
//! Builtin providers always take precedence: when a models.dev provider
//! shares an id with a builtin, the builtin wins (its base_url, adapter,
//! and metadata are authoritative). The models.dev registry fills in
//! every other OpenAI-compatible provider (npm is `@ai-sdk/openai-compatible`
//! or `@ai-sdk/openai`, with an `api` field).
//!
//! Callers get a flat `[]Provider` slice. The first entry is always the
//! OpenAI Codex OAuth provider (id == "openai").

const std = @import("std");
const logger = @import("logger");

const cache_subdir = "models.dev";
const cache_filename = "api.json";
const api_url = "https://models.dev/api.json";

/// 24 hours in milliseconds.
const cache_ttl_ms: i64 = 24 * 60 * 60 * 1000;

pub const Adapter = enum {
    codex_responses,
    openai_compatible,
};

/// A single provider entry — either from builtins or models.dev.
/// All string fields are borrowed from the registry's backing store;
/// callers must not free them individually.
pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    base_url: []const u8,
    adapter: Adapter,
    requires_api_key: bool,
    /// OAuth flow (OpenAI Codex) instead of an API-key form.
    oauth: bool = false,
    /// Anonymous free-tier sentinel key (e.g. OpenCode Zen "public").
    anonymous_key: ?[]const u8 = null,
};

/// The merged, deduplicated provider list. Owns all string memory.
pub const Registry = struct {
    providers: []Provider,
    /// Backing store for all string fields. Freed in deinit.
    strings: std.ArrayList(u8),

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        gpa.free(self.providers);
        self.strings.deinit(gpa);
        self.* = undefined;
    }

    /// Find a provider by id. Returns null when not found.
    pub fn lookup(self: *const Registry, id: []const u8) ?Provider {
        for (self.providers) |p| {
            if (std.mem.eql(u8, p.id, id)) return p;
        }
        return null;
    }
};

/// Builtin providers shipped with the binary. These always take precedence
/// over models.dev entries with the same id.
const builtin_defs = [_]struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    base_url: []const u8,
    adapter: Adapter,
    requires_api_key: bool,
    oauth: bool = false,
    anonymous_key: ?[]const u8 = null,
}{
    .{
        .id = "openai",
        .name = "OpenAI Codex",
        .description = "OpenAI ChatGPT & Codex OAuth authentication",
        .base_url = "https://chatgpt.com/backend-api",
        .adapter = .codex_responses,
        .requires_api_key = false,
        .oauth = true,
    },
    .{
        .id = "openrouter",
        .name = "OpenRouter",
        .description = "Unified router for 200+ AI models",
        .base_url = "https://openrouter.ai/api/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "cerebras",
        .name = "Cerebras",
        .description = "Ultra-fast Cerebras WSE-3 wafer inference",
        .base_url = "https://api.cerebras.ai/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "ollama_cloud",
        .name = "Ollama Cloud",
        .description = "Hosted Ollama cloud model infrastructure",
        .base_url = "https://ollama.com/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "huggingface",
        .name = "HuggingFace",
        .description = "HuggingFace Serverless Inference API",
        .base_url = "https://router.huggingface.co/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "nvidia_nim",
        .name = "Nvidia Nim",
        .description = "NVIDIA NIM microservices & GPU platform",
        .base_url = "https://integrate.api.nvidia.com/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "opencode_zen",
        .name = "OpenCode Zen",
        .description = "Free public OpenCode Zen endpoint",
        .base_url = "https://opencode.ai/zen/v1",
        .adapter = .openai_compatible,
        .requires_api_key = false,
        .anonymous_key = "public",
    },
    .{
        .id = "deepseek",
        .name = "DeepSeek",
        .description = "DeepSeek AI models (DeepSeek-V3, DeepSeek-R1)",
        .base_url = "https://api.deepseek.com",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "google",
        .name = "Google Gemini",
        .description = "Google Gemini models via OpenAI-compatible endpoint",
        .base_url = "https://generativelanguage.googleapis.com/v1beta/openai",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "mistral",
        .name = "Mistral AI",
        .description = "Mistral AI models (Mistral Large, Codestral, Pixtral)",
        .base_url = "https://api.mistral.ai/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "xai",
        .name = "xAI Grok",
        .description = "xAI Grok models (Grok-4, Grok-4.3)",
        .base_url = "https://api.x.ai/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "perplexity",
        .name = "Perplexity",
        .description = "Perplexity AI models (Sonar, Sonar Pro)",
        .base_url = "https://api.perplexity.ai",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "cohere",
        .name = "Cohere",
        .description = "Cohere Command models (Command R+, Command R7B)",
        .base_url = "https://api.cohere.com/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "alibaba",
        .name = "Alibaba Qwen",
        .description = "Alibaba Cloud Qwen models (Qwen3, Qwen2.5)",
        .base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
};

/// Load the builtin providers. The returned slice borrows from a comptime
/// constant — no allocation, no deinit needed.
pub fn loadBuiltins() []const Provider {
    const out = comptime blk: {
        var buf: [builtin_defs.len]Provider = undefined;
        for (&builtin_defs, 0..) |def, i| {
            buf[i] = .{
                .id = def.id,
                .name = def.name,
                .description = def.description,
                .base_url = def.base_url,
                .adapter = def.adapter,
                .requires_api_key = def.requires_api_key,
                .oauth = def.oauth,
                .anonymous_key = def.anonymous_key,
            };
        }
        break :blk buf;
    };
    return &out;
}

/// Load the cached models.dev api.json if it exists and is younger than
/// `cache_ttl_ms`. Returns null when the cache is missing or stale.
/// Caller owns the returned Registry.
pub fn loadCache(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !?Registry {
    return loadCacheWithOptions(gpa, io, home_dir, false);
}

pub fn loadCacheWithOptions(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, ignore_ttl: bool) !?Registry {
    if (home_dir.len == 0) return null;

    const path = cachePath(gpa, home_dir) catch return null;
    defer gpa.free(path);

    const file = std.Io.Dir.openFile(.cwd(), io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer file.close(io);

    if (!ignore_ttl) {
        const stat = try file.stat(io);
        const now_ms = std.Io.Clock.now(.real, io).toMilliseconds();
        const age_ms = now_ms - stat.mtime.toMilliseconds();
        if (age_ms > cache_ttl_ms) return null;
    }

    var reader = file.reader(io, &.{});
    const bytes = try reader.interface.allocRemaining(gpa, .limited(4 * 1024 * 1024));
    defer gpa.free(bytes);

    return try parseModelsDevJson(gpa, bytes);
}

/// Fetch api.json from models.dev, cache it, and return the parsed providers.
/// Caller owns the returned Registry.
pub fn fetchAndCache(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !Registry {
    if (home_dir.len == 0) return error.HomeNotSet;

    const bytes = try fetchApiJson(gpa, io);
    defer gpa.free(bytes);

    cacheApiJson(gpa, io, home_dir, bytes) catch |err| {
        logger.log("modelsdev.cache.write.failed err={s}", .{@errorName(err)});
    };

    return parseModelsDevJson(gpa, bytes);
}

/// Retrieve the merged provider registry. Prefers a fresh network fetch so
/// newly added providers are visible immediately; falls back to cache or
/// builtins when offline.
pub fn loadOrFetchRegistry(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) Registry {
    const builtins = loadBuiltins();

    // Try network first so the picker always shows the latest providers.
    if (fetchAndCache(gpa, io, home_dir)) |fetched| {
        var f = fetched;
        defer f.deinit(gpa);
        if (buildRegistry(gpa, builtins, &f)) |merged| {
            return merged;
        } else |_| {}
    } else |err| {
        logger.log("modelsdev.fetch.failed err={s}", .{@errorName(err)});
    }

    if (loadCache(gpa, io, home_dir) catch null) |cached| {
        var c = cached;
        defer c.deinit(gpa);
        if (buildRegistry(gpa, builtins, &c)) |merged| {
            return merged;
        } else |_| {}
    }

    if (loadCacheWithOptions(gpa, io, home_dir, true) catch null) |stale| {
        var s = stale;
        defer s.deinit(gpa);
        if (buildRegistry(gpa, builtins, &s)) |merged| {
            return merged;
        } else |_| {}
    }

    var empty_remote: Registry = .{ .providers = &.{}, .strings = .empty };
    return buildRegistry(gpa, builtins, &empty_remote) catch .{
        .providers = &.{},
        .strings = .empty,
    };
}

const StringRef = struct {
    start: usize,
    len: usize,

    fn slice(self: StringRef, buf: []const u8) []const u8 {
        return buf[self.start .. self.start + self.len];
    }
};

fn appendString(gpa: std.mem.Allocator, strings: *std.ArrayList(u8), s: []const u8) !StringRef {
    const start = strings.items.len;
    try strings.appendSlice(gpa, s);
    return .{ .start = start, .len = s.len };
}

const UnresolvedProvider = struct {
    id: StringRef,
    name: StringRef,
    description: StringRef,
    base_url: StringRef,
    adapter: Adapter,
    requires_api_key: bool,
    oauth: bool = false,
    anonymous_key: ?StringRef = null,

    fn resolve(self: UnresolvedProvider, buf: []const u8) Provider {
        return .{
            .id = self.id.slice(buf),
            .name = self.name.slice(buf),
            .description = self.description.slice(buf),
            .base_url = self.base_url.slice(buf),
            .adapter = self.adapter,
            .requires_api_key = self.requires_api_key,
            .oauth = self.oauth,
            .anonymous_key = if (self.anonymous_key) |k| k.slice(buf) else null,
        };
    }
};

/// Build the full merged registry: builtins first, then models.dev providers
/// that don't shadow a builtin id. Caller owns the returned Registry.
pub fn buildRegistry(gpa: std.mem.Allocator, builtins: []const Provider, remote_registry: *const Registry) !Registry {
    var strings: std.ArrayList(u8) = .empty;
    errdefer strings.deinit(gpa);

    var unresolved: std.ArrayList(UnresolvedProvider) = .empty;
    defer unresolved.deinit(gpa);

    // Builtins always come first and take precedence.
    for (builtins) |p| {
        try unresolved.append(gpa, .{
            .id = try appendString(gpa, &strings, p.id),
            .name = try appendString(gpa, &strings, p.name),
            .description = try appendString(gpa, &strings, p.description),
            .base_url = try appendString(gpa, &strings, p.base_url),
            .adapter = p.adapter,
            .requires_api_key = p.requires_api_key,
            .oauth = p.oauth,
            .anonymous_key = if (p.anonymous_key) |k| try appendString(gpa, &strings, k) else null,
        });
    }

    // Remote providers: skip any whose id already exists in builtins.
    for (remote_registry.providers) |p| {
        if (lookupBuiltin(builtins, p.id) != null) continue;
        try unresolved.append(gpa, .{
            .id = try appendString(gpa, &strings, p.id),
            .name = try appendString(gpa, &strings, p.name),
            .description = try appendString(gpa, &strings, p.description),
            .base_url = try appendString(gpa, &strings, p.base_url),
            .adapter = p.adapter,
            .requires_api_key = p.requires_api_key,
            .oauth = p.oauth,
            .anonymous_key = if (p.anonymous_key) |k| try appendString(gpa, &strings, k) else null,
        });
    }

    const providers = try gpa.alloc(Provider, unresolved.items.len);
    errdefer gpa.free(providers);

    for (unresolved.items, 0..) |item, i| {
        providers[i] = item.resolve(strings.items);
    }

    return .{
        .providers = providers,
        .strings = strings,
    };
}

fn lookupBuiltin(builtins: []const Provider, id: []const u8) ?Provider {
    for (builtins) |p| {
        if (std.mem.eql(u8, p.id, id)) return p;
    }
    return null;
}

// ── HTTP fetch ──

fn fetchApiJson(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(api_url);
    var request = try client.request(.GET, uri, .{});
    defer request.deinit();
    try request.sendBodiless();

    var redirect_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    const status: u16 = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) return error.HttpError;

    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    return reader.allocRemaining(gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.StreamTooLong => error.ResponseTooLarge,
        else => |e| e,
    };
}

fn cacheApiJson(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, bytes: []const u8) !void {
    const dir = try cacheDir(gpa, home_dir);
    defer gpa.free(dir);
    try std.Io.Dir.createDirPath(.cwd(), io, dir);

    const path = try cachePath(gpa, home_dir);
    defer gpa.free(path);

    const file = try std.Io.Dir.createFile(.cwd(), io, path, .{ .truncate = true });
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn cacheDir(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ home_dir, ".nova", "cache", cache_subdir });
}

fn cachePath(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    const dir = try cacheDir(gpa, home_dir);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, cache_filename });
}

// ── JSON parsing ──

fn isOpenAiCompatibleNpm(npm: []const u8) bool {
    return std.mem.eql(u8, npm, "@ai-sdk/openai-compatible") or
        std.mem.eql(u8, npm, "@ai-sdk/openai");
}

fn parseModelsDevJson(gpa: std.mem.Allocator, bytes: []const u8) !Registry {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidApiJson;

    var strings: std.ArrayList(u8) = .empty;
    errdefer strings.deinit(gpa);

    var unresolved: std.ArrayList(UnresolvedProvider) = .empty;
    defer unresolved.deinit(gpa);

    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .object) continue;

        const npm_field = kv.value_ptr.object.get("npm") orelse continue;
        if (npm_field != .string) continue;
        if (!isOpenAiCompatibleNpm(npm_field.string)) continue;

        const api_field = kv.value_ptr.object.get("api") orelse continue;
        if (api_field != .string) continue;

        const name_field = kv.value_ptr.object.get("name") orelse continue;
        if (name_field != .string) continue;

        const models_field = kv.value_ptr.object.get("models") orelse continue;
        if (models_field != .object) continue;
        if (models_field.object.count() == 0) continue;

        const desc_value = kv.value_ptr.object.get("description") orelse name_field;
        const desc: []const u8 = if (desc_value == .string) desc_value.string else name_field.string;

        try unresolved.append(gpa, .{
            .id = try appendString(gpa, &strings, kv.key_ptr.*),
            .name = try appendString(gpa, &strings, name_field.string),
            .description = try appendString(gpa, &strings, desc),
            .base_url = try appendString(gpa, &strings, api_field.string),
            .adapter = .openai_compatible,
            .requires_api_key = true,
        });
    }

    const providers = try gpa.alloc(Provider, unresolved.items.len);
    errdefer gpa.free(providers);

    for (unresolved.items, 0..) |item, i| {
        providers[i] = item.resolve(strings.items);
    }

    return .{
        .providers = providers,
        .strings = strings,
    };
}

// ── Tests ──

test "loadBuiltins returns all providers" {
    const providers = loadBuiltins();
    try std.testing.expect(providers.len >= 14);
    try std.testing.expectEqualStrings("openai", providers[0].id);
    try std.testing.expectEqualStrings("OpenAI Codex", providers[0].name);
    try std.testing.expectEqual(Adapter.codex_responses, providers[0].adapter);
    try std.testing.expect(providers[0].oauth);
    try std.testing.expect(!providers[0].requires_api_key);
}

test "parseModelsDevJson filters to openai-compatible providers" {
    const gpa = std.testing.allocator;
    const json =
        \\{
        \\  "deepseek": {
        \\    "npm": "@ai-sdk/openai-compatible",
        \\    "api": "https://api.deepseek.com",
        \\    "name": "DeepSeek",
        \\    "models": { "deepseek-chat": {} }
        \\  },
        \\  "meta": {
        \\    "npm": "@ai-sdk/openai",
        \\    "api": "https://api.meta.ai/v1",
        \\    "name": "Meta",
        \\    "models": { "llama-3-70b": {} }
        \\  },
        \\  "google": {
        \\    "npm": "@ai-sdk/google",
        \\    "name": "Google",
        \\    "models": { "gemini-2.5-flash": {} }
        \\  },
        \\  "no-api": {
        \\    "npm": "@ai-sdk/openai-compatible",
        \\    "name": "NoApi",
        \\    "models": { "m": {} }
        \\  }
        \\}
    ;

    var registry = try parseModelsDevJson(gpa, json);
    defer registry.deinit(gpa);

    // deepseek (openai-compatible) + meta (openai) pass; google (google) and no-api fail.
    try std.testing.expectEqual(@as(usize, 2), registry.providers.len);
    try std.testing.expectEqualStrings("deepseek", registry.providers[0].id);
    try std.testing.expectEqualStrings("DeepSeek", registry.providers[0].name);
    try std.testing.expectEqualStrings("https://api.deepseek.com", registry.providers[0].base_url);
    try std.testing.expectEqualStrings("meta", registry.providers[1].id);
    try std.testing.expectEqualStrings("Meta", registry.providers[1].name);
    try std.testing.expectEqualStrings("https://api.meta.ai/v1", registry.providers[1].base_url);
}

test "buildRegistry merges builtins and remote, builtins win" {
    const gpa = std.testing.allocator;

    const builtins = loadBuiltins();

    // Create a minimal remote registry with a conflicting deepseek and a new provider.
    var remote_registry = try parseModelsDevJson(gpa,
        \\{
        \\  "deepseek": {
        \\    "npm": "@ai-sdk/openai-compatible",
        \\    "api": "https://api.deepseek.com",
        \\    "name": "DeepSeek (remote)",
        \\    "models": { "deepseek-chat": {} }
        \\  },
        \\  "302ai": {
        \\    "npm": "@ai-sdk/openai-compatible",
        \\    "api": "https://api.302.ai/v1",
        \\    "name": "302.AI",
        \\    "models": { "m": {} }
        \\  }
        \\}
    );
    defer remote_registry.deinit(gpa);

    var merged = try buildRegistry(gpa, builtins, &remote_registry);
    defer merged.deinit(gpa);

    // openai (builtin first), deepseek (builtin wins), 302ai (remote only)
    try std.testing.expect(merged.providers.len >= builtins.len + 1);
    try std.testing.expectEqualStrings("openai", merged.providers[0].id);

    // Find deepseek — should be the builtin version
    const ds = merged.lookup("deepseek").?;
    try std.testing.expectEqualStrings("DeepSeek", ds.name);
    try std.testing.expectEqualStrings("https://api.deepseek.com", ds.base_url);

    // 302ai should be present from remote
    const ai302 = merged.lookup("302ai").?;
    try std.testing.expectEqualStrings("302.AI", ai302.name);
}

test "loadOrFetchRegistry fallback to builtins when no cache or network" {
    const gpa = std.testing.allocator;
    const io: std.Io = undefined;
    var registry = loadOrFetchRegistry(gpa, io, "");
    defer registry.deinit(gpa);

    try std.testing.expect(registry.providers.len >= 14);
    const ds = registry.lookup("deepseek").?;
    try std.testing.expectEqualStrings("DeepSeek", ds.name);
}
