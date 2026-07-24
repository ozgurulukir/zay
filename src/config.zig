//! Nova's resolved preferences record and its layered loader.
//! Four sources, field-merged, later overrides earlier:
//!   1. built-in defaults
//!   2. global  `<home>/.nova/config.json`
//!   3. project `<cwd>/.nova/config.json`
//!   4. env vars: OPENAI_BASE_URL, OPENAI_API_KEY, OPENAI_MODEL,
//!                NOVA_USE_RESPONSES_ENDPOINT, NOVA_ENABLE_THINKING,
//!                NOVA_BASH_CLASSIFIER_URL
//!
//! `model` is a `<provider>/<model-id>` selection string. Model-specific
//! fields such as `reasoningEffort` live under `providers.<provider>.models`.

const std = @import("std");
const ai = @import("ai.zig");

const assert = std.debug.assert;

pub const Provider = enum {
    openai,
    openai_compatible,
    ollama,
    llama_cpp,
    openrouter,
    cerebras,
    ollama_cloud,
    huggingface,
    nvidia_nim,
    opencode_zen,
    anthropic,

    pub fn label(self: Provider) []const u8 {
        return providerSpec(self).label;
    }

    pub fn displayName(self: Provider) []const u8 {
        return providerSpec(self).display_name;
    }

    /// Default base_url for this Provider. `null` means the user MUST
    /// supply one (e.g. raw `openai_compatible` and `anthropic`).
    pub fn defaultBaseUrl(self: Provider) ?[]const u8 {
        return providerSpec(self).base_url_default;
    }

    pub fn adapter(self: Provider) ?AdapterKind {
        return providerSpec(self).adapter_kind;
    }

    pub fn isCatalogue(self: Provider) bool {
        return providerSpec(self).catalogue;
    }

    pub fn requiresApiKey(self: Provider) bool {
        return providerSpec(self).requires_api_key;
    }

    pub fn anonymousApiKey(self: Provider) ?[]const u8 {
        return switch (self) {
            .opencode_zen => "public",
            else => null,
        };
    }

    pub fn description(self: Provider) []const u8 {
        return switch (self) {
            .openai => "OpenAI ChatGPT & Codex authentication",
            .openai_compatible => "Custom OpenAI-compatible REST server",
            .ollama => "Local Ollama server instance (localhost:11434)",
            .llama_cpp => "Local llama.cpp HTTP server (localhost:8080)",
            .openrouter => "Unified router for 200+ AI models",
            .cerebras => "Ultra-fast Cerebras WSE-3 wafer inference",
            .ollama_cloud => "Hosted Ollama cloud model infrastructure",
            .huggingface => "HuggingFace Serverless Inference API",
            .nvidia_nim => "NVIDIA NIM microservices & GPU platform",
            .opencode_zen => "Free public OpenCode Zen endpoint",
            .anthropic => "Direct Anthropic API (Claude 3.5 Sonnet)",
        };
    }
};

pub fn catalogueProviders() []const Provider {
    const list = comptime blk: {
        var buf: [provider_specs.len]Provider = undefined;
        var n: usize = 0;
        for (provider_specs) |spec| {
            if (spec.catalogue) {
                buf[n] = spec.provider;
                n += 1;
            }
        }
        const final = buf[0..n].*;
        break :blk final;
    };
    return &list;
}

pub const AdapterKind = enum {
    codex_responses,
    openai_responses,
    openai_compatible,
};

const ProviderSpec = struct {
    provider: Provider,
    label: []const u8,
    display_name: []const u8,
    base_url_default: ?[]const u8,
    adapter_kind: ?AdapterKind,
    catalogue: bool = false,
    requires_api_key: bool = true,
};

const provider_specs = [_]ProviderSpec{
    .{ .provider = .openai, .label = "openai", .display_name = "OpenAI Codex", .base_url_default = "https://chatgpt.com/backend-api", .adapter_kind = .codex_responses },
    .{ .provider = .openai_compatible, .label = "openai_compatible", .display_name = "OpenAI Compatible", .base_url_default = null, .adapter_kind = .openai_compatible },
    .{ .provider = .ollama, .label = "ollama", .display_name = "Ollama", .base_url_default = "http://localhost:11434", .adapter_kind = .openai_compatible },
    .{ .provider = .llama_cpp, .label = "llama.cpp", .display_name = "llama.cpp", .base_url_default = "http://localhost:8080", .adapter_kind = .openai_compatible },
    .{ .provider = .openrouter, .label = "openrouter", .display_name = "OpenRouter", .base_url_default = "https://openrouter.ai/api", .adapter_kind = .openai_compatible, .catalogue = true },
    .{ .provider = .cerebras, .label = "cerebras", .display_name = "Cerebras", .base_url_default = "https://api.cerebras.ai/v1", .adapter_kind = .openai_compatible, .catalogue = true },
    .{ .provider = .ollama_cloud, .label = "ollama_cloud", .display_name = "Ollama Cloud", .base_url_default = "https://ollama.com/v1", .adapter_kind = .openai_compatible, .catalogue = true },
    .{ .provider = .huggingface, .label = "huggingface", .display_name = "HuggingFace", .base_url_default = "https://router.huggingface.co/v1", .adapter_kind = .openai_compatible, .catalogue = true },
    .{ .provider = .nvidia_nim, .label = "nvidia_nim", .display_name = "Nvidia Nim", .base_url_default = "https://integrate.api.nvidia.com/v1", .adapter_kind = .openai_compatible, .catalogue = true },
    .{ .provider = .opencode_zen, .label = "opencode_zen", .display_name = "OpenCode Zen", .base_url_default = "https://opencode.ai/zen/v1", .adapter_kind = .openai_compatible, .catalogue = true, .requires_api_key = false },
    .{ .provider = .anthropic, .label = "anthropic", .display_name = "Anthropic", .base_url_default = null, .adapter_kind = null },
};

const providers_by_name = std.StaticStringMap(Provider).initComptime(.{
    .{ "openai", .openai },
    .{ "openai_compatible", .openai_compatible },
    .{ "ollama", .ollama },
    .{ "llama.cpp", .llama_cpp },
    .{ "openrouter", .openrouter },
    .{ "cerebras", .cerebras },
    .{ "ollama_cloud", .ollama_cloud },
    .{ "huggingface", .huggingface },
    .{ "nvidia_nim", .nvidia_nim },
    .{ "opencode_zen", .opencode_zen },
    .{ "anthropic", .anthropic },
});

fn providerSpec(provider: Provider) ProviderSpec {
    const index: usize = @intFromEnum(provider);
    comptime std.debug.assert(provider_specs.len == @typeInfo(Provider).@"enum".fields.len);
    std.debug.assert(provider_specs[index].provider == provider);
    return provider_specs[index];
}

pub const Model = struct {
    id: []u8,
    reasoning_effort: ?ai.ReasoningEffort = null,

    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        self.* = undefined;
    }

    fn clone(self: Model, gpa: std.mem.Allocator) !Model {
        return .{
            .id = try gpa.dupe(u8, self.id),
            .reasoning_effort = self.reasoning_effort,
        };
    }
};

/// Per-provider base URL: either the provider's built-in default or an
/// explicit URL supplied by the user. Replaces `?[]u8` where `null` was
/// ambiguous between "use default" and "not specified in this layer".
/// In overlay merges, `.default` means "don't override"; at final
/// resolution, `.default` falls through to `Provider.defaultBaseUrl()`.
pub const BaseUrl = union(enum) {
    default,
    custom: []u8,
};

/// Per-provider model entry. Identical in shape to `Model` — kept as a
/// type alias so callers that conceptually deal with "a model entry
/// declared inside a ProviderConfig" can name it explicitly. The two
/// were line-for-line duplicates before; the alias removes the drift
/// risk for good.
pub const ProviderModel = Model;

pub const ProviderConfig = struct {
    provider: Provider,
    base_url: BaseUrl = .default,
    models: []ProviderModel = &.{},

    pub fn deinit(self: *ProviderConfig, gpa: std.mem.Allocator) void {
        switch (self.base_url) {
            .custom => |s| gpa.free(s),
            .default => {},
        }
        for (self.models) |*model| model.deinit(gpa);
        if (self.models.len > 0) gpa.free(self.models);
        self.* = undefined;
    }

    fn clone(self: ProviderConfig, gpa: std.mem.Allocator) !ProviderConfig {
        var out: ProviderConfig = .{ .provider = self.provider };
        errdefer out.deinit(gpa);
        switch (self.base_url) {
            .custom => |s| out.base_url = .{ .custom = try gpa.dupe(u8, s) },
            .default => {},
        }
        out.models = try gpa.alloc(ProviderModel, self.models.len);
        for (self.models, 0..) |model, index| out.models[index] = try model.clone(gpa);
        return out;
    }
};

pub const ModelSelectionRef = struct {
    provider: Provider,
    model: *const Model,
};

pub const McpServerConfig = struct {
    name: []u8,
    enabled: bool = true,
    /// How the server is reached. Variants make illegal combinations
    /// unrepresentable: a stdio server must have command+args, an sse
    /// server must have a url.
    transport: union(enum) {
        stdio: struct {
            command: []u8,
            args: [][]u8 = &.{},
        },
        sse: struct {
            url: []u8,
        },
    },

    pub fn deinit(self: *McpServerConfig, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        switch (self.transport) {
            .stdio => |t| {
                gpa.free(t.command);
                for (t.args) |arg| gpa.free(arg);
                if (t.args.len > 0) gpa.free(t.args);
            },
            .sse => |t| gpa.free(t.url),
        }
        self.* = undefined;
    }

    pub fn clone(self: McpServerConfig, gpa: std.mem.Allocator) !McpServerConfig {
        return .{
            .name = try gpa.dupe(u8, self.name),
            .enabled = self.enabled,
            .transport = switch (self.transport) {
                .stdio => |t| blk: {
                    var args = try gpa.alloc([]u8, t.args.len);
                    errdefer gpa.free(args);
                    for (t.args, 0..) |arg, i| args[i] = try gpa.dupe(u8, arg);
                    break :blk .{ .stdio = .{
                        .command = try gpa.dupe(u8, t.command),
                        .args = args,
                    } };
                },
                .sse => |t| .{ .sse = .{ .url = try gpa.dupe(u8, t.url) } },
            },
        };
    }
};

/// A complete, ready-to-use model selection. The fields that were
/// previously optional on `Config` and runtime-asserted to be all-set
/// (provider, base_url, api_key, model) live here as non-optional.
/// Optional settings stay optional. `Config.model_selection: ?ModelSelection`
/// is the typed view; legacy callers that read the loose `Config`
/// fields keep working until the migration PRs land.
pub const ModelSelection = struct {
    provider: Provider,
    model: Model,
    base_url: []u8,
    api_key: []u8,
    use_responses_endpoint: bool = false,
    enable_thinking: bool = false,
    system_prompt: ?[]u8 = null,
    bash_classifier_url: ?[]u8 = null,

    pub fn deinit(self: *ModelSelection, gpa: std.mem.Allocator) void {
        gpa.free(self.base_url);
        gpa.free(self.api_key);
        self.model.deinit(gpa);
        if (self.system_prompt) |s| gpa.free(s);
        if (self.bash_classifier_url) |s| gpa.free(s);
        self.* = undefined;
    }

    pub fn clone(self: ModelSelection, gpa: std.mem.Allocator) !ModelSelection {
        return .{
            .provider = self.provider,
            .model = try self.model.clone(gpa),
            .base_url = try gpa.dupe(u8, self.base_url),
            .api_key = try gpa.dupe(u8, self.api_key),
            .use_responses_endpoint = self.use_responses_endpoint,
            .enable_thinking = self.enable_thinking,
            .system_prompt = if (self.system_prompt) |s| try gpa.dupe(u8, s) else null,
            .bash_classifier_url = if (self.bash_classifier_url) |s| try gpa.dupe(u8, s) else null,
        };
    }
};

pub const Config = struct {
    version: ?u32 = 1,
    provider: ?Provider = null,
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,
    bash_classifier_url: ?[]u8 = null,
    model: ?Model = null,
    providers: []ProviderConfig = &.{},
    mcp_servers: []McpServerConfig = &.{},
    use_responses_endpoint: ?bool = null,
    enable_thinking: ?bool = null,
    system_prompt: ?[]u8 = null,
    /// Typed view of the model selection. `null` when the required
    /// fields (provider, base_url, api_key, model) aren't all set.
    /// Equivalent to the old `assertModelSelection` check — but the
    /// presence is now encoded in the type, not enforced at runtime.
    model_selection: ?ModelSelection = null,

    pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
        if (self.base_url) |s| gpa.free(s);
        if (self.api_key) |s| gpa.free(s);
        if (self.bash_classifier_url) |s| gpa.free(s);
        if (self.model) |*m| m.deinit(gpa);
        for (self.providers) |*provider| provider.deinit(gpa);
        if (self.providers.len > 0) gpa.free(self.providers);
        for (self.mcp_servers) |*server| server.deinit(gpa);
        if (self.mcp_servers.len > 0) gpa.free(self.mcp_servers);
        if (self.system_prompt) |s| gpa.free(s);
        if (self.model_selection) |*ms| ms.deinit(gpa);
        self.* = undefined;
    }

    pub fn clone(self: Config, gpa: std.mem.Allocator) !Config {
        var out: Config = .{
            .version = self.version,
            .provider = self.provider,
            .use_responses_endpoint = self.use_responses_endpoint,
            .enable_thinking = self.enable_thinking,
        };
        errdefer out.deinit(gpa);
        if (self.base_url) |s| out.base_url = try gpa.dupe(u8, s);
        if (self.api_key) |s| out.api_key = try gpa.dupe(u8, s);
        if (self.bash_classifier_url) |s| out.bash_classifier_url = try gpa.dupe(u8, s);
        if (self.model) |m| out.model = try m.clone(gpa);
        out.providers = try gpa.alloc(ProviderConfig, self.providers.len);
        for (self.providers, 0..) |provider, index| out.providers[index] = try provider.clone(gpa);
        out.mcp_servers = try gpa.alloc(McpServerConfig, self.mcp_servers.len);
        for (self.mcp_servers, 0..) |server, index| out.mcp_servers[index] = try server.clone(gpa);
        if (self.system_prompt) |s| out.system_prompt = try gpa.dupe(u8, s);
        if (self.model_selection) |ms| out.model_selection = try ms.clone(gpa);
        return out;
    }

    pub fn validate(self: *const Config, gpa: std.mem.Allocator) ![]Diagnostic {
        var list: std.ArrayList(Diagnostic) = .empty;
        errdefer {
            for (list.items) |*d| d.deinit(gpa);
            list.deinit(gpa);
        }
        if (self.version) |v| {
            if (v > 1) {
                try list.append(gpa, .{ .config_parse_error = .{
                    .path = try gpa.dupe(u8, "version"),
                    .reason = try std.fmt.allocPrint(gpa, "unsupported schema version {d}", .{v}),
                } });
            }
        }
        if (self.base_url) |url| {
            if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
                try list.append(gpa, .{ .config_parse_error = .{
                    .path = try gpa.dupe(u8, "base_url"),
                    .reason = try std.fmt.allocPrint(gpa, "invalid URL scheme in '{s}'", .{url}),
                } });
            }
        }
        return try list.toOwnedSlice(gpa);
    }

    /// Alias for `clone`, used by `nova.run` to hand the TUI an owned
    /// copy of the merged config that outlives `load_result`.
    pub fn cloneForTui(self: Config, gpa: std.mem.Allocator) !Config {
        return self.clone(gpa);
    }

    pub fn activeModelSelection(self: *const Config) ?ModelSelectionRef {
        const provider = self.provider orelse return null;
        const model = if (self.model) |*model| model else return null;
        return .{ .provider = provider, .model = model };
    }
};

/// Legacy runtime check. With `model_selection: ?ModelSelection`, the
/// invariant is encoded in the type: either the selection is fully
/// populated or it's absent. Kept for callers that still pass a Config
/// without going through parseObject (tests); it's a no-op when
/// `model_selection` is set.
pub fn assertModelSelection(config: *const Config) void {
    if (config.model_selection) |_| return;
    // When model_selection is null but the legacy fields are partially
    // set, that's a programming error. Catch it loudly.
    assert(config.provider == null);
    assert(config.model == null);
    assert(config.base_url == null);
    assert(config.api_key == null);
}

pub const Diagnostic = union(enum) {
    config_parse_error: ParseError,
    bad_env_model: []u8,

    pub const ParseError = struct {
        path: []u8,
        reason: []u8,

        fn deinit(self: *ParseError, gpa: std.mem.Allocator) void {
            gpa.free(self.path);
            gpa.free(self.reason);
            self.* = undefined;
        }
    };

    pub fn deinit(self: *Diagnostic, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .config_parse_error => |*e| e.deinit(gpa),
            .bad_env_model => |s| gpa.free(s),
        }
        self.* = undefined;
    }
};

pub const LoadResult = struct {
    config: Config,
    diagnostics: []Diagnostic,

    pub fn deinit(self: *LoadResult, gpa: std.mem.Allocator) void {
        self.config.deinit(gpa);
        for (self.diagnostics) |*d| d.deinit(gpa);
        gpa.free(self.diagnostics);
        self.* = undefined;
    }

    /// Detach the diagnostics slice so it outlives this LoadResult.
    /// Caller owns the returned slice; `deinit` after this no-ops on it.
    pub fn takeDiagnostics(self: *LoadResult) []Diagnostic {
        const out = self.diagnostics;
        self.diagnostics = &.{};
        return out;
    }
};

/// Top-level layered load. Reads global file, project file, and env vars;
/// merges with later sources overriding earlier; collects diagnostics for
/// any soft-fail signals along the way. `home_dir` may be empty when the
/// caller couldn't resolve `HOME` — in that case the global file layer is
/// skipped silently and load continues with project + env.
pub fn load(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home_dir: []const u8,
    env: anytype,
) !LoadResult {
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |*d| d.deinit(gpa);
        diagnostics.deinit(gpa);
    }

    var global = try loadGlobalFile(gpa, io, home_dir, &diagnostics);
    defer global.deinit(gpa);

    var project = try loadProjectFile(gpa, io, cwd, &diagnostics);
    defer project.deinit(gpa);

    var env_layer = try loadEnv(gpa, env, &diagnostics);
    defer env_layer.deinit(gpa);

    var merged = try mergeLayers(gpa, &.{ global, project, env_layer });
    errdefer merged.deinit(gpa);

    return .{
        .config = merged,
        .diagnostics = try diagnostics.toOwnedSlice(gpa),
    };
}

/// The pure layering algebra: fold each layer onto the result in
/// least-to-most-specific order (global, then project, then env), then hydrate
/// the chosen model against the fully merged provider list. No file IO — every
/// input is an already-parsed Config, so the precedence rules and hydration are
/// unit-testable without touching disk (see the "mergeLayers …" tests).
fn mergeLayers(gpa: std.mem.Allocator, layers: []const Config) !Config {
    var out: Config = .{};
    errdefer out.deinit(gpa);
    for (layers) |layer| try applyConfigOverlay(gpa, &out, layer);
    try hydrateActiveModel(gpa, &out);
    return out;
}

/// Merge `updates` onto `target`. `api_key` is merged like any other field —
/// it is needed in the in-memory runtime config. Persistence is a separate
/// concern: `serialize` is the single seam that decides what reaches disk, and
/// it never writes `api_key` (keys live only in auth.json). So this overlay
/// needs no "should I keep the key?" flag — the write path strips it anyway.
fn applyConfigOverlay(gpa: std.mem.Allocator, target: *Config, updates: Config) !void {
    if (updates.provider) |v| target.provider = v;
    if (updates.use_responses_endpoint) |v| target.use_responses_endpoint = v;
    if (updates.enable_thinking) |v| target.enable_thinking = v;
    if (updates.base_url) |s| try replaceOptionalSlice(gpa, &target.base_url, s);
    if (updates.api_key) |s| try replaceOptionalSlice(gpa, &target.api_key, s);
    if (updates.bash_classifier_url) |s| try replaceOptionalSlice(gpa, &target.bash_classifier_url, s);
    if (updates.system_prompt) |s| try replaceOptionalSlice(gpa, &target.system_prompt, s);
    for (updates.providers) |provider| try applyProviderOverlay(gpa, target, provider);
    for (updates.mcp_servers) |mcp_server| try applyMcpServerOverlay(gpa, target, mcp_server);
    if (updates.model) |m| {
        if (target.model) |*old| old.deinit(gpa);
        target.model = try m.clone(gpa);
    }
    // When the updates carry a complete `model_selection`, mirror its
    // fields onto the target's legacy fields so the merge result
    // (which is hydrated to model_selection via parseObject) round-trips
    // correctly. parseObject on the merged result will repackage them
    // into model_selection.
    if (updates.model_selection) |ms| {
        target.provider = ms.provider;
        if (target.model) |*old| old.deinit(gpa);
        target.model = try ms.model.clone(gpa);
        try replaceOptionalSlice(gpa, &target.base_url, ms.base_url);
        try replaceOptionalSlice(gpa, &target.api_key, ms.api_key);
        target.use_responses_endpoint = ms.use_responses_endpoint;
        target.enable_thinking = ms.enable_thinking;
        if (ms.system_prompt) |s| try replaceOptionalSlice(gpa, &target.system_prompt, s);
        if (ms.bash_classifier_url) |s| try replaceOptionalSlice(gpa, &target.bash_classifier_url, s);
    }
}

fn applyMcpServerOverlay(gpa: std.mem.Allocator, target: *Config, updates: McpServerConfig) !void {
    for (target.mcp_servers, 0..) |*server, index| {
        if (!std.mem.eql(u8, server.name, updates.name)) continue;
        server.enabled = updates.enabled;
        server.transport = switch (updates.transport) {
            .stdio => |t| blk: {
                var args = try gpa.alloc([]u8, t.args.len);
                errdefer gpa.free(args);
                for (t.args, 0..) |arg, i| args[i] = try gpa.dupe(u8, arg);
                break :blk .{ .stdio = .{
                    .command = try gpa.dupe(u8, t.command),
                    .args = args,
                } };
            },
            .sse => |t| .{ .sse = .{ .url = try gpa.dupe(u8, t.url) } },
        };
        target.mcp_servers[index] = server.*;
        return;
    }

    const next = if (target.mcp_servers.len == 0)
        try gpa.alloc(McpServerConfig, 1)
    else
        try gpa.realloc(target.mcp_servers, target.mcp_servers.len + 1);
    target.mcp_servers = next;
    target.mcp_servers[target.mcp_servers.len - 1] = try updates.clone(gpa);
}

fn applyProviderOverlay(gpa: std.mem.Allocator, target: *Config, updates: ProviderConfig) !void {
    for (target.providers, 0..) |*provider, index| {
        if (provider.provider != updates.provider) continue;
        switch (updates.base_url) {
            .custom => |s| try replaceBaseUrl(gpa, &provider.base_url, s),
            .default => {},
        }
        try applyProviderModelsOverlay(gpa, provider, updates.models);
        target.providers[index] = provider.*;
        return;
    }

    const next = if (target.providers.len == 0)
        try gpa.alloc(ProviderConfig, 1)
    else
        try gpa.realloc(target.providers, target.providers.len + 1);
    target.providers = next;
    target.providers[target.providers.len - 1] = try updates.clone(gpa);
}

fn applyProviderModelsOverlay(gpa: std.mem.Allocator, target: *ProviderConfig, updates: []const ProviderModel) !void {
    for (updates) |update| {
        var replaced = false;
        for (target.models) |*model| {
            if (!std.mem.eql(u8, model.id, update.id)) continue;
            model.reasoning_effort = update.reasoning_effort;
            replaced = true;
            break;
        }
        if (replaced) continue;
        const next = if (target.models.len == 0)
            try gpa.alloc(ProviderModel, 1)
        else
            try gpa.realloc(target.models, target.models.len + 1);
        target.models = next;
        target.models[target.models.len - 1] = try update.clone(gpa);
    }
}

fn hydrateActiveModel(gpa: std.mem.Allocator, config: *Config) !void {
    const provider = config.provider orelse return;
    if (config.model == null) return;
    for (config.providers) |entry| {
        if (entry.provider != provider) continue;
        switch (entry.base_url) {
            .custom => |base_url| try replaceOptionalSlice(gpa, &config.base_url, base_url),
            .default => {},
        }
        for (entry.models) |model| {
            if (!std.mem.eql(u8, model.id, config.model.?.id)) continue;
            config.model.?.reasoning_effort = model.reasoning_effort;
            return;
        }
        return;
    }
}

fn replaceOptionalSlice(gpa: std.mem.Allocator, target: *?[]u8, source: []const u8) !void {
    const next = try gpa.dupe(u8, source);
    if (target.*) |old| gpa.free(old);
    target.* = next;
}

fn replaceBaseUrl(gpa: std.mem.Allocator, target: *BaseUrl, source: []const u8) !void {
    const next = try gpa.dupe(u8, source);
    switch (target.*) {
        .custom => |old| gpa.free(old),
        .default => {},
    }
    target.* = .{ .custom = next };
}

fn loadGlobalFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !Config {
    const path = globalConfigPath(gpa, io, home_dir) catch return .{};
    defer gpa.free(path);
    return loadFile(gpa, io, path, diagnostics);
}

fn loadProjectFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !Config {
    const path = try std.fs.path.join(gpa, &.{ cwd, ".nova", "config.json" });
    defer gpa.free(path);
    return loadFile(gpa, io, path, diagnostics);
}

fn loadFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !Config {
    const bytes = std.Io.Dir.readFileAllocOptions(.cwd(), io, path, gpa, .limited(32 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => {
            try diagnostics.append(gpa, .{ .config_parse_error = .{
                .path = try gpa.dupe(u8, path),
                .reason = try gpa.dupe(u8, @errorName(err)),
            } });
            return .{};
        },
    };
    defer gpa.free(bytes);
    return parseFile(gpa, path, bytes, diagnostics);
}

fn parseFile(
    gpa: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !Config {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| {
        try diagnostics.append(gpa, .{ .config_parse_error = .{
            .path = try gpa.dupe(u8, path),
            .reason = try std.fmt.allocPrint(gpa, "invalid JSON: {s}", .{@errorName(err)}),
        } });
        return .{};
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try diagnostics.append(gpa, .{ .config_parse_error = .{
            .path = try gpa.dupe(u8, path),
            .reason = try gpa.dupe(u8, "top-level value must be an object"),
        } });
        return .{};
    }
    return parseObject(gpa, path, parsed.value, diagnostics);
}

fn parseObject(
    gpa: std.mem.Allocator,
    path: []const u8,
    value: std.json.Value,
    diagnostics: *std.ArrayList(Diagnostic),
) !Config {
    var out: Config = .{};
    errdefer out.deinit(gpa);

    if (intField(value, "version")) |v| {
        out.version = @intCast(v);
        if (v > 1) {
            try diagnostics.append(gpa, .{ .config_parse_error = .{
                .path = try gpa.dupe(u8, path),
                .reason = try std.fmt.allocPrint(gpa, "unsupported config version {d}", .{v}),
            } });
        }
    }
    if (stringField(value, "model")) |s| {
        if (parseModelSelection(gpa, s)) |selection| {
            out.provider = selection.provider;
            out.model = selection.model;
        } else |err| {
            try diagnostics.append(gpa, .{ .config_parse_error = .{
                .path = try gpa.dupe(u8, path),
                .reason = try std.fmt.allocPrint(gpa, "invalid model selection: {s}", .{@errorName(err)}),
            } });
        }
    }
    if (value.object.get("providers")) |providers_value| {
        if (providers_value == .object) out.providers = try parseProviders(gpa, providers_value);
    }
    const mcp_val = value.object.get("mcp_servers") orelse value.object.get("mcpServers") orelse value.object.get("mcp");
    if (mcp_val) |val| {
        if (val == .object) out.mcp_servers = try parseMcpServers(gpa, val);
    }
    try parseModelSelectionFields(gpa, value, &out);

    // Parsing is pure: producing a single layer's Config never reaches into the
    // provider catalogue. Hydration runs once after all layers merge, against
    // the fully merged provider list (see `mergeLayers`).
    return out;
}

fn parseProviders(gpa: std.mem.Allocator, value: std.json.Value) ![]ProviderConfig {
    var providers: std.ArrayList(ProviderConfig) = .empty;
    errdefer {
        for (providers.items) |*provider| provider.deinit(gpa);
        providers.deinit(gpa);
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const provider = providers_by_name.get(entry.key_ptr.*) orelse continue;
        if (entry.value_ptr.* != .object) continue;
        try providers.append(gpa, try parseProviderConfig(gpa, provider, entry.value_ptr.*));
    }
    return try providers.toOwnedSlice(gpa);
}

fn parseMcpServers(gpa: std.mem.Allocator, value: std.json.Value) ![]McpServerConfig {
    var servers: std.ArrayList(McpServerConfig) = .empty;
    errdefer {
        for (servers.items) |*server| server.deinit(gpa);
        servers.deinit(gpa);
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const val = entry.value_ptr.*;
        var server: McpServerConfig = undefined;
        server.name = try gpa.dupe(u8, entry.key_ptr.*);
        server.enabled = boolField(val, "enabled") orelse true;
        errdefer server.deinit(gpa);

        try parseMcpTransport(gpa, val, &server);
        try servers.append(gpa, server);
    }
    return try servers.toOwnedSlice(gpa);
}
