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

pub const ProviderModel = struct {
    id: []u8,
    reasoning_effort: ?ai.ReasoningEffort = null,

    pub fn deinit(self: *ProviderModel, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        self.* = undefined;
    }

    fn clone(self: ProviderModel, gpa: std.mem.Allocator) !ProviderModel {
        return .{
            .id = try gpa.dupe(u8, self.id),
            .reasoning_effort = self.reasoning_effort,
        };
    }
};

pub const ProviderConfig = struct {
    provider: Provider,
    base_url: ?[]u8 = null,
    models: []ProviderModel = &.{},

    pub fn deinit(self: *ProviderConfig, gpa: std.mem.Allocator) void {
        if (self.base_url) |s| gpa.free(s);
        for (self.models) |*model| model.deinit(gpa);
        if (self.models.len > 0) gpa.free(self.models);
        self.* = undefined;
    }

    fn clone(self: ProviderConfig, gpa: std.mem.Allocator) !ProviderConfig {
        var out: ProviderConfig = .{ .provider = self.provider };
        errdefer out.deinit(gpa);
        if (self.base_url) |s| out.base_url = try gpa.dupe(u8, s);
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

pub fn assertModelSelection(config: *const Config) void {
    if (config.provider) |_| {
        assert(config.model != null);
    } else {
        assert(config.model == null);
    }
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
        if (updates.base_url) |s| try replaceOptionalSlice(gpa, &provider.base_url, s);
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
        if (entry.base_url) |base_url| try replaceOptionalSlice(gpa, &config.base_url, base_url);
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
    if (stringField(value, "base_url")) |s| {
        out.base_url = try gpa.dupe(u8, s);
    }
    if (stringField(value, "bash_classifier_url")) |s| {
        if (s.len > 0) out.bash_classifier_url = try gpa.dupe(u8, s);
    }
    if (boolField(value, "use_responses_endpoint")) |b| out.use_responses_endpoint = b;
    if (boolField(value, "enable_thinking")) |b| out.enable_thinking = b;
    if (stringField(value, "system_prompt")) |s| {
        out.system_prompt = try gpa.dupe(u8, s);
    }

    // Populate the typed `model_selection` when all required fields
    // are present. Missing any of them leaves it null — the legacy
    // optional fields stay so existing callers keep working until
    // they migrate to `model_selection`.
    if (out.provider != null and out.model != null and
        out.base_url != null and out.api_key != null)
    {
        out.model_selection = .{
            .provider = out.provider.?,
            .model = out.model.?, // ownership moves; clear the legacy field
            .base_url = out.base_url.?,
            .api_key = out.api_key.?,
            .use_responses_endpoint = out.use_responses_endpoint orelse false,
            .enable_thinking = out.enable_thinking orelse false,
            .system_prompt = out.system_prompt,
            .bash_classifier_url = out.bash_classifier_url,
        };
        out.provider = null;
        out.model = null;
        out.base_url = null;
        out.api_key = null;
        out.use_responses_endpoint = null;
        out.enable_thinking = null;
        out.system_prompt = null;
        out.bash_classifier_url = null;
    }

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

        const cmd = stringField(val, "command");
        const url = stringField(val, "url");
        if (cmd) |c| {
            var args: [][]u8 = &.{};
            if (val.object.get("args")) |args_val| {
                if (args_val == .array) {
                    var args_list: std.ArrayList([]u8) = .empty;
                    errdefer {
                        for (args_list.items) |arg| gpa.free(arg);
                        args_list.deinit(gpa);
                    }
                    for (args_val.array.items) |arg_item| {
                        if (arg_item == .string) {
                            try args_list.append(gpa, try gpa.dupe(u8, arg_item.string));
                        }
                    }
                    args = try args_list.toOwnedSlice(gpa);
                }
            }
            server.transport = .{ .stdio = .{
                .command = try gpa.dupe(u8, c),
                .args = args,
            } };
        } else if (url) |u| {
            server.transport = .{ .sse = .{ .url = try gpa.dupe(u8, u) } };
        } else {
            return error.InvalidMcpServerConfig;
        }
        try servers.append(gpa, server);
    }
    return try servers.toOwnedSlice(gpa);
}

fn parseProviderConfig(gpa: std.mem.Allocator, provider: Provider, value: std.json.Value) !ProviderConfig {
    var out: ProviderConfig = .{ .provider = provider };
    errdefer out.deinit(gpa);
    if (stringField(value, "base_url")) |s| out.base_url = try gpa.dupe(u8, s);
    if (value.object.get("models")) |models_value| {
        if (models_value == .object) out.models = try parseProviderModels(gpa, models_value);
    }
    return out;
}

fn parseProviderModels(gpa: std.mem.Allocator, value: std.json.Value) ![]ProviderModel {
    var models: std.ArrayList(ProviderModel) = .empty;
    errdefer {
        for (models.items) |*model| model.deinit(gpa);
        models.deinit(gpa);
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        try models.append(gpa, .{
            .id = try gpa.dupe(u8, entry.key_ptr.*),
            .reasoning_effort = if (stringField(entry.value_ptr.*, "reasoningEffort")) |effort| reasoning_efforts_by_name.get(effort) else null,
        });
    }
    return try models.toOwnedSlice(gpa);
}

fn loadEnv(
    gpa: std.mem.Allocator,
    env: anytype,
    diagnostics: *std.ArrayList(Diagnostic),
) !Config {
    var out: Config = .{};
    errdefer out.deinit(gpa);

    if (env.get("OPENAI_BASE_URL")) |s| out.base_url = try gpa.dupe(u8, s);
    if (env.get("OPENAI_API_KEY")) |s| out.api_key = try gpa.dupe(u8, s);
    if (env.get("NOVA_BASH_CLASSIFIER_URL")) |s| {
        if (s.len > 0) out.bash_classifier_url = try gpa.dupe(u8, s);
    }
    if (env.get("NOVA_USE_RESPONSES_ENDPOINT")) |s| {
        out.use_responses_endpoint = parseBool(s);
    }
    if (env.get("NOVA_ENABLE_THINKING")) |s| {
        out.enable_thinking = parseBool(s);
    }
    if (env.get("OPENAI_MODEL")) |raw| {
        if (parseModelSelection(gpa, raw)) |parsed| {
            out.provider = parsed.provider;
            out.model = parsed.model;
        } else |_| {
            try diagnostics.append(gpa, .{ .bad_env_model = try gpa.dupe(u8, raw) });
        }
    }
    return out;
}

const ParsedModelSelection = struct {
    provider: Provider,
    model: Model,
};

fn parseModelSelection(gpa: std.mem.Allocator, raw: []const u8) !ParsedModelSelection {
    const slash = std.mem.findScalar(u8, raw, '/') orelse return error.MissingSeparator;
    const provider_part = raw[0..slash];
    const model_part = raw[slash + 1 ..];
    if (provider_part.len == 0) return error.MissingProvider;
    if (model_part.len == 0) return error.MissingModel;
    const provider = providers_by_name.get(provider_part) orelse return error.UnknownProvider;
    return .{
        .provider = provider,
        .model = .{ .id = try gpa.dupe(u8, model_part) },
    };
}

fn parseBool(s: []const u8) bool {
    if (std.mem.eql(u8, s, "1")) return true;
    if (std.ascii.eqlIgnoreCase(s, "true")) return true;
    return false;
}

const reasoning_efforts_by_name = std.StaticStringMap(ai.ReasoningEffort).initComptime(.{
    .{ "minimal", .minimal },
    .{ "low", .low },
    .{ "none", .none },
    .{ "medium", .medium },
    .{ "high", .high },
    .{ "xhigh", .xhigh },
});

fn intField(value: std.json.Value, name: []const u8) ?i64 {
    const field = value.object.get(name) orelse return null;
    if (field != .integer) return null;
    return field.integer;
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn boolField(value: std.json.Value, name: []const u8) ?bool {
    const field = value.object.get(name) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

pub fn writeGlobal(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    config: Config,
) !void {
    const path = try globalConfigPath(gpa, io, home_dir);
    defer gpa.free(path);

    const dirname = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.createDirPath(.cwd(), io, dirname);

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try serialize(gpa, &payload.writer, config);

    {
        var file = try std.Io.Dir.createFile(.cwd(), io, tmp_path, .{ .truncate = true });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll(payload.written());
        try writer.interface.flush();
    }

    try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), path, io);
}

pub fn readGlobal(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !Config {
    const path = try globalConfigPath(gpa, io, home_dir);
    defer gpa.free(path);
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (sink.items) |*d| d.deinit(gpa);
        sink.deinit(gpa);
    }
    return loadFile(gpa, io, path, &sink);
}

pub fn mergeAndWriteGlobal(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    updates: Config,
) !void {
    var current = try readGlobal(gpa, io, home_dir);
    defer current.deinit(gpa);
    try applyConfigOverlay(gpa, &current, updates);
    try writeGlobal(gpa, io, home_dir, current);
}

pub fn readProject(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) !Config {
    const path = try projectConfigPath(gpa, cwd);
    defer gpa.free(path);
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (sink.items) |*d| d.deinit(gpa);
        sink.deinit(gpa);
    }
    return loadFile(gpa, io, path, &sink);
}

pub fn writeProject(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    config: Config,
) !void {
    const path = try projectConfigPath(gpa, cwd);
    defer gpa.free(path);

    const dirname = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.createDirPath(.cwd(), io, dirname);

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try serialize(gpa, &payload.writer, config);

    {
        var file = try std.Io.Dir.createFile(.cwd(), io, tmp_path, .{ .truncate = true });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll(payload.written());
        try writer.interface.flush();
    }

    try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), path, io);
}

pub fn mergeAndWriteProject(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    updates: Config,
) !void {
    var current = try readProject(gpa, io, cwd);
    defer current.deinit(gpa);
    try applyConfigOverlay(gpa, &current, updates);
    try writeProject(gpa, io, cwd, current);
}

pub fn projectConfigExists(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) bool {
    const path = projectConfigPath(gpa, cwd) catch return false;
    defer gpa.free(path);
    std.Io.Dir.access(.cwd(), io, path, .{}) catch return false;
    return true;
}

/// The single seam between an in-memory Config and config.json on disk.
/// Invariant: `api_key` is NEVER written here — API keys live only in
/// auth.json (see codex.ApiKeyMap). This is the one place that enforces it, so
/// callers never have to thread a "should I persist the key?" flag through the
/// merge path. The "serialize: skips api_key even if present" test guards it.
fn serialize(gpa: std.mem.Allocator, writer: *std.Io.Writer, config: Config) !void {
    try writer.writeAll("{\n  \"version\": 1");
    var wrote_any = true;

    if (config.provider) |p| {
        try writeKey(writer, "provider", &wrote_any);
        try std.json.Stringify.value(p.label(), .{}, writer);
    }
    if (config.use_responses_endpoint) |b| {
        try writeKey(writer, "use_responses_endpoint", &wrote_any);
        try writer.writeAll(if (b) "true" else "false");
    }
    if (config.enable_thinking) |b| {
        try writeKey(writer, "enable_thinking", &wrote_any);
        try writer.writeAll(if (b) "true" else "false");
    }
    if (config.model) |m| {
        if (config.provider) |provider| {
            try writeKey(writer, "model", &wrote_any);
            try writeModelSelection(gpa, writer, provider, m.id);
        }
    }
    if (config.providers.len > 0) {
        try writeKey(writer, "providers", &wrote_any);
        try writeProviders(writer, config.providers);
    }
    if (config.mcp_servers.len > 0) {
        try writeKey(writer, "mcp_servers", &wrote_any);
        try writeMcpServers(writer, config.mcp_servers);
    }
    if (config.system_prompt) |s| {
        try writeKey(writer, "system_prompt", &wrote_any);
        try std.json.Stringify.value(s, .{}, writer);
    }
    if (config.bash_classifier_url) |url| {
        try writeKey(writer, "bash_classifier_url", &wrote_any);
        try std.json.Stringify.value(url, .{}, writer);
    }
    try writer.writeAll("\n}\n");
}

fn writeModelSelection(gpa: std.mem.Allocator, writer: *std.Io.Writer, provider: Provider, model_id: []const u8) !void {
    const selection = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ provider.label(), model_id });
    defer gpa.free(selection);
    try std.json.Stringify.value(selection, .{}, writer);
}

fn writeProviders(writer: *std.Io.Writer, providers: []const ProviderConfig) !void {
    try writer.writeByte('{');
    var wrote_provider = false;
    for (providers) |provider| {
        if (wrote_provider) try writer.writeByte(',');
        try std.json.Stringify.value(provider.provider.label(), .{}, writer);
        try writer.writeByte(':');
        try writeProvider(writer, provider);
        wrote_provider = true;
    }
    try writer.writeByte('}');
}

fn writeProvider(writer: *std.Io.Writer, provider: ProviderConfig) !void {
    try writer.writeByte('{');
    var wrote_any = false;
    if (provider.base_url) |base_url| {
        try writeKey(writer, "base_url", &wrote_any);
        try std.json.Stringify.value(base_url, .{}, writer);
    }
    if (provider.models.len > 0) {
        try writeKey(writer, "models", &wrote_any);
        try writeProviderModels(writer, provider.models);
    }
    try writer.writeByte('}');
}

fn writeProviderModels(writer: *std.Io.Writer, models: []const ProviderModel) !void {
    try writer.writeByte('{');
    var wrote_model = false;
    for (models) |model| {
        if (wrote_model) try writer.writeByte(',');
        try std.json.Stringify.value(model.id, .{}, writer);
        try writer.writeByte(':');
        try writer.writeByte('{');
        if (model.reasoning_effort) |effort| {
            try std.json.Stringify.value("reasoningEffort", .{}, writer);
            try writer.writeByte(':');
            try std.json.Stringify.value(effort.label(), .{}, writer);
        }
        try writer.writeByte('}');
        wrote_model = true;
    }
    try writer.writeByte('}');
}

fn writeMcpServers(writer: *std.Io.Writer, servers: []const McpServerConfig) !void {
    try writer.writeByte('{');
    var wrote_server = false;
    for (servers) |server| {
        if (wrote_server) try writer.writeByte(',');
        try std.json.Stringify.value(server.name, .{}, writer);
        try writer.writeByte(':');
        try writeMcpServer(writer, server);
        wrote_server = true;
    }
    try writer.writeByte('}');
}

fn writeMcpServer(writer: *std.Io.Writer, server: McpServerConfig) !void {
    try writer.writeByte('{');
    var wrote_any = false;
    switch (server.transport) {
        .stdio => |t| {
            try writeKeyNoIndent(writer, "command", &wrote_any);
            try std.json.Stringify.value(t.command, .{}, writer);
            if (t.args.len > 0) {
                try writeKeyNoIndent(writer, "args", &wrote_any);
                try writer.writeByte('[');
                for (t.args, 0..) |arg, i| {
                    if (i > 0) try writer.writeByte(',');
                    try std.json.Stringify.value(arg, .{}, writer);
                }
                try writer.writeByte(']');
            }
        },
        .sse => |t| {
            try writeKeyNoIndent(writer, "url", &wrote_any);
            try std.json.Stringify.value(t.url, .{}, writer);
        },
    }
    if (!server.enabled) {
        try writeKeyNoIndent(writer, "enabled", &wrote_any);
        try writer.writeAll("false");
    }
    try writer.writeByte('}');
}

fn writeKeyNoIndent(writer: *std.Io.Writer, name: []const u8, wrote_any: *bool) !void {
    if (wrote_any.*) try writer.writeByte(',');
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    wrote_any.* = true;
}

fn writeKey(writer: *std.Io.Writer, name: []const u8, wrote_any: *bool) !void {
    if (wrote_any.*) try writer.writeByte(',');
    try writer.writeAll("\n  ");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(": ");
    wrote_any.* = true;
}

pub fn globalConfigPath(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) ![]u8 {
    if (home_dir.len == 0) return error.HomeNotSet;

    // 1. Standard XDG path: ~/.config/nova/config.json
    const xdg_path = try std.fs.path.join(gpa, &.{ home_dir, ".config", "nova", "config.json" });
    errdefer gpa.free(xdg_path);

    if (std.Io.Dir.access(.cwd(), io, xdg_path, .{})) |_| {
        return xdg_path;
    } else |_| {}

    // 2. Legacy fallback path: ~/.nova/config.json
    const legacy_path = try std.fs.path.join(gpa, &.{ home_dir, ".nova", "config.json" });
    errdefer gpa.free(legacy_path);

    if (std.Io.Dir.access(.cwd(), io, legacy_path, .{})) |_| {
        gpa.free(xdg_path);
        return legacy_path;
    } else |_| {}

    // 3. Default to XDG path for new config writes
    gpa.free(legacy_path);
    return xdg_path;
}

fn projectConfigPath(gpa: std.mem.Allocator, cwd: []const u8) ![]u8 {
    if (cwd.len == 0) return error.InvalidPath;
    return std.fs.path.join(gpa, &.{ cwd, ".nova", "config.json" });
}

const TestEnv = struct {
    entries: []const Entry,

    const Entry = struct { key: []const u8, value: []const u8 };

    pub fn get(self: TestEnv, key: []const u8) ?[]const u8 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }
};

test "providers_by_name recognizes known vendor names" {
    try std.testing.expectEqual(Provider.openai, providers_by_name.get("openai").?);
    try std.testing.expectEqual(Provider.openai_compatible, providers_by_name.get("openai_compatible").?);
    try std.testing.expectEqual(Provider.ollama, providers_by_name.get("ollama").?);
    try std.testing.expectEqual(Provider.llama_cpp, providers_by_name.get("llama.cpp").?);
    try std.testing.expectEqual(Provider.openrouter, providers_by_name.get("openrouter").?);
    try std.testing.expectEqual(Provider.cerebras, providers_by_name.get("cerebras").?);
    try std.testing.expectEqual(Provider.ollama_cloud, providers_by_name.get("ollama_cloud").?);
    try std.testing.expectEqual(Provider.huggingface, providers_by_name.get("huggingface").?);
    try std.testing.expectEqual(Provider.nvidia_nim, providers_by_name.get("nvidia_nim").?);
    try std.testing.expectEqual(Provider.opencode_zen, providers_by_name.get("opencode_zen").?);
    try std.testing.expectEqual(Provider.anthropic, providers_by_name.get("anthropic").?);
    try std.testing.expectEqual(@as(?Provider, null), providers_by_name.get("mystery"));
}

test "every catalogue provider round-trips through providers_by_name and has a base url" {
    for (catalogueProviders()) |provider| {
        try std.testing.expectEqual(provider, providers_by_name.get(provider.label()).?);
        try std.testing.expect(provider.defaultBaseUrl() != null);
        try std.testing.expectEqual(AdapterKind.openai_compatible, provider.adapter().?);
    }
    // OpenCode Zen is the one catalogue provider with an anonymous (free) tier.
    try std.testing.expect(!Provider.opencode_zen.requiresApiKey());
    try std.testing.expectEqualStrings("public", Provider.opencode_zen.anonymousApiKey().?);
    try std.testing.expect(Provider.cerebras.requiresApiKey());
    try std.testing.expectEqual(@as(?[]const u8, null), Provider.cerebras.anonymousApiKey());
}

test "Provider.adapter returns null for unimplemented anthropic" {
    try std.testing.expectEqual(AdapterKind.codex_responses, Provider.openai.adapter().?);
    try std.testing.expectEqual(AdapterKind.openai_compatible, Provider.ollama.adapter().?);
    try std.testing.expectEqual(@as(?AdapterKind, null), Provider.anthropic.adapter());
}

test "parseModelSelection: valid <provider>/<model>" {
    const gpa = std.testing.allocator;
    var parsed = try parseModelSelection(gpa, "openai/gpt-5.5");
    defer parsed.model.deinit(gpa);
    try std.testing.expectEqual(Provider.openai, parsed.provider);
    try std.testing.expectEqualStrings("gpt-5.5", parsed.model.id);
}

test "parseModelSelection: ollama/llama3.1:8b" {
    const gpa = std.testing.allocator;
    var parsed = try parseModelSelection(gpa, "ollama/llama3.1:8b");
    defer parsed.model.deinit(gpa);
    try std.testing.expectEqual(Provider.ollama, parsed.provider);
    try std.testing.expectEqualStrings("llama3.1:8b", parsed.model.id);
}

test "parseModelSelection: missing slash is error" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.MissingSeparator, parseModelSelection(gpa, "gpt-5.5"));
}

test "parseModelSelection: model id may contain slashes" {
    const gpa = std.testing.allocator;
    var parsed = try parseModelSelection(gpa, "openrouter/anthropic/claude-3.7-sonnet");
    defer parsed.model.deinit(gpa);
    try std.testing.expectEqual(Provider.openrouter, parsed.provider);
    try std.testing.expectEqualStrings("anthropic/claude-3.7-sonnet", parsed.model.id);
}

test "parseModelSelection: unknown provider is error" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.UnknownProvider, parseModelSelection(gpa, "mystery/foo"));
}

test "parseModelSelection: anthropic parses (validity checked downstream)" {
    const gpa = std.testing.allocator;
    var parsed = try parseModelSelection(gpa, "anthropic/claude-3.7-sonnet");
    defer parsed.model.deinit(gpa);
    try std.testing.expectEqual(Provider.anthropic, parsed.provider);
}

test "parseObject: minimal config" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{\"model\":\"ollama/llama3.1:8b\"}", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Provider.ollama, cfg.provider.?);
    try std.testing.expectEqualStrings("llama3.1:8b", cfg.model.?.id);
    try std.testing.expectEqual(@as(usize, 0), sink.items.len);
}

test "parseFile is pure; merge hydrates model reasoningEffort from providers" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{\"model\":\"openai/gpt-5.5\",\"providers\":{\"openai\":{\"models\":{\"gpt-5.5\":{\"reasoningEffort\":\"high\"}}}}}", &sink);
    defer cfg.deinit(gpa);
    // Parsing one layer never reaches into the provider catalogue.
    try std.testing.expectEqual(@as(?ai.ReasoningEffort, null), cfg.model.?.reasoning_effort);
    // Merging hydrates the active model against the parsed providers.
    var merged = try mergeLayers(gpa, &.{cfg});
    defer merged.deinit(gpa);
    try std.testing.expectEqual(ai.ReasoningEffort.high, merged.model.?.reasoning_effort.?);
}

test "parseObject: unknown provider records diagnostic" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (sink.items) |*d| d.deinit(gpa);
        sink.deinit(gpa);
    }
    var cfg = try parseFile(gpa, "<test>", "{\"model\":\"mystery/foo\"}", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(?Provider, null), cfg.provider);
    try std.testing.expectEqual(@as(usize, 1), sink.items.len);
    try std.testing.expect(sink.items[0] == .config_parse_error);
}

test "parseObject: invalid JSON records diagnostic" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (sink.items) |*d| d.deinit(gpa);
        sink.deinit(gpa);
    }
    var cfg = try parseFile(gpa, "<test>", "not json", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(?Provider, null), cfg.provider);
    try std.testing.expectEqual(@as(usize, 1), sink.items.len);
}

test "mergeLayers: later layer overrides earlier" {
    const gpa = std.testing.allocator;
    var layer1: Config = .{
        .provider = .openai,
        .base_url = try gpa.dupe(u8, "http://layer1"),
        .model = .{ .id = try gpa.dupe(u8, "m1"), .reasoning_effort = .low },
    };
    defer layer1.deinit(gpa);
    var layer2: Config = .{
        .base_url = try gpa.dupe(u8, "http://layer2"),
    };
    defer layer2.deinit(gpa);

    var merged = try mergeLayers(gpa, &.{ layer1, layer2 });
    defer merged.deinit(gpa);

    try std.testing.expectEqual(Provider.openai, merged.provider.?);
    try std.testing.expectEqualStrings("http://layer2", merged.base_url.?);
    try std.testing.expectEqualStrings("m1", merged.model.?.id);
    try std.testing.expectEqual(ai.ReasoningEffort.low, merged.model.?.reasoning_effort.?);
}

test "mergeLayers: model is indivisible — higher layer's model replaces whole" {
    const gpa = std.testing.allocator;
    var layer1: Config = .{
        .model = .{ .id = try gpa.dupe(u8, "m1"), .reasoning_effort = .high },
    };
    defer layer1.deinit(gpa);
    var layer2: Config = .{
        .model = .{ .id = try gpa.dupe(u8, "m2") }, // no reasoning_effort
    };
    defer layer2.deinit(gpa);

    var merged = try mergeLayers(gpa, &.{ layer1, layer2 });
    defer merged.deinit(gpa);

    try std.testing.expectEqualStrings("m2", merged.model.?.id);
    // Higher layer's model replaces whole — lower layer's reasoning_effort
    // does NOT survive, because model is indivisible during merge.
    try std.testing.expectEqual(@as(?ai.ReasoningEffort, null), merged.model.?.reasoning_effort);
}

test "loadEnv: OPENAI_MODEL sets both provider and model" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const env: TestEnv = .{ .entries = &.{
        .{ .key = "OPENAI_MODEL", .value = "openai/gpt-5.5" },
    } };
    var cfg = try loadEnv(gpa, env, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Provider.openai, cfg.provider.?);
    try std.testing.expectEqualStrings("gpt-5.5", cfg.model.?.id);
}

test "loadEnv: malformed OPENAI_MODEL records diagnostic, does not set fields" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (sink.items) |*d| d.deinit(gpa);
        sink.deinit(gpa);
    }
    const env: TestEnv = .{ .entries = &.{
        .{ .key = "OPENAI_MODEL", .value = "gpt-5.5" },
    } };
    var cfg = try loadEnv(gpa, env, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(?Provider, null), cfg.provider);
    try std.testing.expectEqual(@as(?Model, null), cfg.model);
    try std.testing.expectEqual(@as(usize, 1), sink.items.len);
    try std.testing.expect(sink.items[0] == .bad_env_model);
    try std.testing.expectEqualStrings("gpt-5.5", sink.items[0].bad_env_model);
}

test "loadEnv: NOVA_USE_RESPONSES_ENDPOINT parses bools" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const env: TestEnv = .{ .entries = &.{
        .{ .key = "NOVA_USE_RESPONSES_ENDPOINT", .value = "1" },
        .{ .key = "NOVA_ENABLE_THINKING", .value = "true" },
    } };
    var cfg = try loadEnv(gpa, env, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(true, cfg.use_responses_endpoint.?);
    try std.testing.expectEqual(true, cfg.enable_thinking.?);
}

test "serialize: skips api_key even if present" {
    const gpa = std.testing.allocator;
    var provider_models = try gpa.alloc(ProviderModel, 1);
    provider_models[0] = .{ .id = try gpa.dupe(u8, "gpt-5.5"), .reasoning_effort = .medium };
    var providers = try gpa.alloc(ProviderConfig, 1);
    providers[0] = .{ .provider = .openai, .models = provider_models };
    var cfg: Config = .{
        .provider = .openai,
        .api_key = try gpa.dupe(u8, "sk-should-never-appear"),
        .model = .{ .id = try gpa.dupe(u8, "gpt-5.5"), .reasoning_effort = .medium },
        .providers = providers,
    };
    defer cfg.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, cfg);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "api_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "sk-should-never-appear") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"model\": \"openai/gpt-5.5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"reasoningEffort\":\"medium\"") != null);
}

test "mergeLayers: later layers win for scalar fields" {
    const gpa = std.testing.allocator;
    var global: Config = .{ .provider = .openai, .base_url = try gpa.dupe(u8, "https://global") };
    defer global.deinit(gpa);
    var project: Config = .{ .base_url = try gpa.dupe(u8, "https://project") };
    defer project.deinit(gpa);
    var env: Config = .{ .base_url = try gpa.dupe(u8, "https://env") };
    defer env.deinit(gpa);

    // Least-to-most-specific: env is applied last and wins; provider survives
    // from the only layer that set it.
    var merged = try mergeLayers(gpa, &.{ global, project, env });
    defer merged.deinit(gpa);

    try std.testing.expectEqual(Provider.openai, merged.provider.?);
    try std.testing.expectEqualStrings("https://env", merged.base_url.?);
}

test "mergeLayers: active model is hydrated from the merged provider list" {
    const gpa = std.testing.allocator;
    // The provider catalogue entry (reasoning + base_url) comes from one layer...
    const models = try gpa.alloc(ProviderModel, 1);
    models[0] = .{ .id = try gpa.dupe(u8, "gpt-5.5"), .reasoning_effort = .medium };
    const providers = try gpa.alloc(ProviderConfig, 1);
    providers[0] = .{ .provider = .openai, .base_url = try gpa.dupe(u8, "https://from-provider"), .models = models };
    var global: Config = .{ .providers = providers };
    defer global.deinit(gpa);
    // ...the active model selection comes from another, carrying no reasoning.
    var project: Config = .{ .provider = .openai, .model = .{ .id = try gpa.dupe(u8, "gpt-5.5") } };
    defer project.deinit(gpa);

    var merged = try mergeLayers(gpa, &.{ global, project });
    defer merged.deinit(gpa);

    // Hydration runs once over the merged providers, so the cross-layer match
    // copies reasoning effort and base_url onto the chosen model.
    try std.testing.expectEqual(ai.ReasoningEffort.medium, merged.model.?.reasoning_effort.?);
    try std.testing.expectEqualStrings("https://from-provider", merged.base_url.?);
}

test "serialize then parse roundtrips" {
    const gpa = std.testing.allocator;
    var provider_models = try gpa.alloc(ProviderModel, 1);
    provider_models[0] = .{ .id = try gpa.dupe(u8, "llama3.1:8b") };
    var providers = try gpa.alloc(ProviderConfig, 1);
    providers[0] = .{
        .provider = .ollama,
        .base_url = try gpa.dupe(u8, "http://localhost:11434/v1"),
        .models = provider_models,
    };
    var original: Config = .{
        .provider = .ollama,
        .base_url = try gpa.dupe(u8, "http://localhost:11434/v1"),
        .use_responses_endpoint = false,
        .enable_thinking = true,
        .model = .{ .id = try gpa.dupe(u8, "llama3.1:8b") },
        .providers = providers,
    };
    defer original.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, original);

    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var parsed = try parseFile(gpa, "<test>", buf.written(), &sink);
    defer parsed.deinit(gpa);
    // base_url is not serialized; it is rehydrated from the provider entry when
    // the parsed layer is merged.
    var roundtrip = try mergeLayers(gpa, &.{parsed});
    defer roundtrip.deinit(gpa);

    try std.testing.expectEqual(Provider.ollama, roundtrip.provider.?);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", roundtrip.base_url.?);
    try std.testing.expectEqual(false, roundtrip.use_responses_endpoint.?);
    try std.testing.expectEqual(true, roundtrip.enable_thinking.?);
    try std.testing.expectEqualStrings("llama3.1:8b", roundtrip.model.?.id);
}

test "globalConfigPath resolves XDG .config/nova/config.json with fallback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const path = try globalConfigPath(gpa, io, "/home/testuser");
    defer gpa.free(path);

    try std.testing.expect(std.mem.indexOf(u8, path, ".config/nova/config.json") != null or std.mem.indexOf(u8, path, ".nova/config.json") != null);
}

test "Config.validate validates schema version and base_url scheme" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{
        .version = 2,
        .base_url = try gpa.dupe(u8, "ftp://invalid-scheme"),
    };
    defer cfg.deinit(gpa);

    const diags = try cfg.validate(gpa);
    defer {
        for (diags) |*d| d.deinit(gpa);
        gpa.free(diags);
    }

    try std.testing.expectEqual(@as(usize, 2), diags.len);
}

test "config.load with missing files returns default config with version 1 and zero diagnostics" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const env: TestEnv = .{ .entries = &.{} };

    var res = try load(gpa, io, "/nonexistent/cwd", "/nonexistent/home", env);
    defer res.deinit(gpa);

    try std.testing.expectEqual(@as(?u32, 1), res.config.version);
    try std.testing.expectEqual(@as(?Provider, null), res.config.provider);
    try std.testing.expectEqual(@as(usize, 0), res.diagnostics.len);
}

test "serialize outputs version 1 and formatted 2-space indented JSON" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{
        .provider = .openai,
        .use_responses_endpoint = true,
        .enable_thinking = false,
    };
    defer cfg.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, cfg);

    const text = buf.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "{\n  \"version\": 1"));
    try std.testing.expect(std.mem.indexOf(u8, text, "  \"provider\": \"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  \"use_responses_endpoint\": true") != null);
}

test "parseFile parses mcp_servers objects" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"mcp_servers\":{\"memory\":{\"command\":\"npx\",\"args\":[\"-y\",\"@modelcontextprotocol/server-memory\"],\"enabled\":true}}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.len);
    try std.testing.expectEqualStrings("memory", cfg.mcp_servers[0].name);
    switch (cfg.mcp_servers[0].transport) {
        .stdio => |t| {
            try std.testing.expectEqualStrings("npx", t.command);
            try std.testing.expectEqual(@as(usize, 2), t.args.len);
            try std.testing.expectEqualStrings("-y", t.args[0]);
        },
        .sse => return error.Unexpected,
    }
    try std.testing.expectEqual(true, cfg.mcp_servers[0].enabled);
}

test "parseFile parses mcpServers (Claude Desktop format)" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"mcpServers\":{\"codebase-memory-mcp\":{\"command\":\"/path/to/codebase-memory-mcp\",\"args\":[]}}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.len);
    try std.testing.expectEqualStrings("codebase-memory-mcp", cfg.mcp_servers[0].name);
    switch (cfg.mcp_servers[0].transport) {
        .stdio => |t| {
            try std.testing.expectEqualStrings("/path/to/codebase-memory-mcp", t.command);
            try std.testing.expectEqual(@as(usize, 0), t.args.len);
        },
        .sse => return error.Unexpected,
    }
}

test "parseFile parses mcp (short key format)" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"mcp\":{\"test-server\":{\"command\":\"node\",\"args\":[\"index.js\"]}}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.len);
    try std.testing.expectEqualStrings("test-server", cfg.mcp_servers[0].name);
    switch (cfg.mcp_servers[0].transport) {
        .stdio => |t| try std.testing.expectEqualStrings("node", t.command),
        .sse => return error.Unexpected,
    }
}

test "mergeLayers merges mcp_servers across config layers" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);

    var layer1 = try parseFile(gpa, "<layer1>", "{\"mcp_servers\":{\"global-server\":{\"command\":\"python\",\"args\":[]}}}", &sink);
    defer layer1.deinit(gpa);
    var layer2 = try parseFile(gpa, "<layer2>", "{\"mcp\":{\"proj-server\":{\"command\":\"node\",\"args\":[]}}}", &sink);
    defer layer2.deinit(gpa);

    var merged = try mergeLayers(gpa, &.{ layer1, layer2 });
    defer merged.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), merged.mcp_servers.len);
    try std.testing.expectEqualStrings("global-server", merged.mcp_servers[0].name);
    try std.testing.expectEqualStrings("proj-server", merged.mcp_servers[1].name);
}
