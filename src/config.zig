//! Nova's resolved preferences record and its layered loader.
//! Four sources, field-merged, later overrides earlier:
//!   1. built-in defaults
//!   2. global  `<home>/.config/nova/config.json`
//!   3. project `<cwd>/.nova/config.json`
//!   4. env vars: OPENAI_BASE_URL, OPENAI_API_KEY, OPENAI_MODEL,
//!                NOVA_USE_RESPONSES_ENDPOINT, NOVA_ENABLE_THINKING,
//!                NOVA_BASH_CLASSIFIER_URL
//!
//! `model` is a `<provider>/<model-id>` selection string. Model-specific
//! fields such as `reasoningEffort` live under `providers.<provider>.models`.

const std = @import("std");
const builtin = @import("builtin");
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

/// All builtin provider labels, for auth.json integrity checks.
/// Builtin keys are never pruned — they're always valid.
pub fn allBuiltinLabels() []const []const u8 {
    return &.{ "openai", "openai_compatible", "ollama", "llama.cpp", "openrouter", "cerebras", "ollama_cloud", "huggingface", "nvidia_nim", "opencode_zen", "anthropic" };
}

fn providerSpec(provider: Provider) ProviderSpec {
    const index: usize = @intFromEnum(provider);
    comptime std.debug.assert(provider_specs.len == @typeInfo(Provider).@"enum".fields.len);
    std.debug.assert(provider_specs[index].provider == provider);
    return provider_specs[index];
}

pub const Model = struct {
    id: []u8,
    reasoning: ReasoningSetting = .unset,
    /// Explicit context window override for this model (tokens).
    /// When set, overrides the model catalogue lookup.
    context_window: ?u32 = null,
    /// Maximum output tokens per generation turn for this model.
    max_output_tokens: ?u32 = null,
    /// Reasoning efforts this model supports. Empty = all efforts
    /// available (backward compatible). The TUI model picker filters
    /// its reasoning cycle to this list.
    reasoning_options: []const ai.ReasoningEffort = &.{},

    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        if (self.reasoning_options.len > 0) gpa.free(self.reasoning_options);
        self.* = undefined;
    }

    fn clone(self: Model, gpa: std.mem.Allocator) !Model {
        var out: Model = .{
            .id = try gpa.dupe(u8, self.id),
            .reasoning = self.reasoning,
            .context_window = self.context_window,
            .max_output_tokens = self.max_output_tokens,
        };
        if (self.reasoning_options.len > 0) {
            out.reasoning_options = try gpa.dupe(ai.ReasoningEffort, self.reasoning_options);
        }
        return out;
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

/// Per-model reasoning effort setting. Follows the same overlay-merge
/// pattern as `BaseUrl`: `.unset` means "not specified in this layer,
/// don't override"; `.effort` carries an explicit level (including
/// `.default` which tells the request builder to omit the parameter).
pub const ReasoningSetting = union(enum) {
    /// Not specified in this config layer — inherit from lower layer.
    unset,
    /// Explicit effort level.
    effort: ai.ReasoningEffort,

    /// Resolve to a concrete effort for the AI client. `.unset` falls
    /// back to `.medium` (the runtime default).
    pub fn resolve(self: ReasoningSetting) ai.ReasoningEffort {
        return switch (self) {
            .unset => .medium,
            .effort => |e| e,
        };
    }
};

/// Per-provider model entry. Identical in shape to `Model` — kept as a
/// type alias so callers that conceptually deal with "a model entry
/// declared inside a ProviderConfig" can name it explicitly. The two
/// were line-for-line duplicates before; the alias removes the drift
/// risk for good.
pub const ProviderModel = Model;

pub const ProviderConfig = struct {
    /// The JSON map key. For builtins this equals `provider.label()`;
    /// for custom providers it's the user-chosen name (e.g. "qwen-cloud").
    name: []u8,
    provider: Provider,
    base_url: BaseUrl = .default,
    models: []ProviderModel = &.{},

    pub fn deinit(self: *ProviderConfig, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        switch (self.base_url) {
            .custom => |s| gpa.free(s),
            .default => {},
        }
        for (self.models) |*model| model.deinit(gpa);
        if (self.models.len > 0) gpa.free(self.models);
        self.* = undefined;
    }

    fn clone(self: ProviderConfig, gpa: std.mem.Allocator) !ProviderConfig {
        var out: ProviderConfig = .{
            .name = try gpa.dupe(u8, self.name),
            .provider = self.provider,
        };
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
    provider_name: []const u8,
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
    /// The provider name as written in config (map key or defaultModel prefix).
    /// For builtins this equals `provider.label()`; for custom providers it's
    /// the user-chosen name. Used for display, auth.json lookup, and session
    /// persistence.
    provider_name: []u8,
    model: Model,
    base_url: []u8,
    api_key: []u8,
    use_responses_endpoint: bool = false,
    enable_thinking: bool = false,
    system_prompt: ?[]u8 = null,
    bash_classifier_url: ?[]u8 = null,

    pub fn deinit(self: *ModelSelection, gpa: std.mem.Allocator) void {
        gpa.free(self.provider_name);
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
            .provider_name = try gpa.dupe(u8, self.provider_name),
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

/// Context window management and automatic compaction policy.
/// Serialized as `"context"` in JSON (camelCase keys inside).
pub const ContextSettings = struct {
    /// Explicit context window override in tokens. When set, overrides
    /// the model catalogue lookup (useful for local Ollama/LMStudio).
    override_context_window: ?u32 = null,
    /// Maximum tokens per single model generation turn.
    max_output_tokens: ?u32 = null,
    /// Upper bound on parallel tool calls accepted from the model.
    /// Providers exceeding this get a logged error. Default 16.
    max_parallel_tool_calls: ?u32 = null,
    /// Socket read timeout in seconds for streaming responses.
    /// Prevents indefinite hangs when the server stops mid-stream.
    request_timeout_seconds: ?u32 = null,
    compaction: CompactionSettings = .{},
};

/// Automatic context summarization policy when approaching the model
/// context window limit. All fields have sensible defaults matching
/// the previous hardcoded constants in compaction.zig.
pub const CompactionSettings = struct {
    /// Enable automatic context compaction before reaching limits.
    auto: bool = true,
    /// Fraction of context window (0.1–1.0) that triggers compaction.
    threshold: f64 = 0.75,
    /// Reserve token buffer for compaction preflight checks.
    buffer_tokens: u32 = 20_000,
    /// Recent conversation tokens retained verbatim alongside the summary.
    keep_recent_tokens: u32 = 8_000,
};

pub const Config = struct {
    /// Semantic version of the configuration schema instance.
    /// Null means the default ("2.0.0"). Stored as an owned slice
    /// when parsed from disk; the default points to static memory.
    version: ?[]u8 = null,
    provider: ?Provider = null,
    /// The provider name as written in config (defaultModel prefix or
    /// providers map key). For builtins equals `provider.label()`; for
    /// custom providers it's the user-chosen name. Used for display,
    /// auth.json lookup, and providers-map matching.
    provider_name: ?[]u8 = null,
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,
    bash_classifier_url: ?[]u8 = null,
    model: ?Model = null,
    providers: []ProviderConfig = &.{},
    mcp_servers: []McpServerConfig = &.{},
    use_responses_endpoint: ?bool = null,
    enable_thinking: ?bool = null,
    system_prompt: ?[]u8 = null,
    /// Context window management and compaction policy.
    context: ContextSettings = .{},
    /// Typed view of the model selection. `null` when the required
    /// fields (provider, base_url, api_key, model) aren't all set.
    /// Equivalent to the old `assertModelSelection` check — but the
    /// presence is now encoded in the type, not enforced at runtime.
    model_selection: ?ModelSelection = null,

    /// Runtime-only: the human-readable provider name from models.dev
    /// (e.g. "StepFun", "DeepSeek"). Set when a dynamic provider is
    /// selected; cleared when switching to a builtin. Never serialized.
    /// Falls back to `provider.label()` when null.
    dynamic_provider_name: ?[]u8 = null,

    /// Runtime-only: the provider ID used as the auth.json key
    /// (e.g. "stepfun-ai"). For dynamic providers this is `provider.id`;
    /// for config providers it equals `provider.name`. Used to resolve
    /// the stored API key on session resume.
    dynamic_provider_id: ?[]u8 = null,

    /// The default schema version written by `serialize` when
    /// `version` is null.
    pub const default_version = "2.0.0";

    pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
        if (self.version) |s| gpa.free(s);
        if (self.provider_name) |s| gpa.free(s);
        if (self.base_url) |s| gpa.free(s);
        if (self.api_key) |s| gpa.free(s);
        if (self.bash_classifier_url) |s| gpa.free(s);
        if (self.model) |*m| m.deinit(gpa);
        for (self.providers) |*provider| provider.deinit(gpa);
        if (self.providers.len > 0) gpa.free(self.providers);
        for (self.mcp_servers) |*server| server.deinit(gpa);
        if (self.mcp_servers.len > 0) gpa.free(self.mcp_servers);
        if (self.system_prompt) |s| gpa.free(s);
        if (self.dynamic_provider_name) |s| gpa.free(s);
        if (self.dynamic_provider_id) |s| gpa.free(s);
        if (self.model_selection) |*ms| ms.deinit(gpa);
        self.* = undefined;
    }

    pub fn clone(self: Config, gpa: std.mem.Allocator) !Config {
        var out: Config = .{
            .provider = self.provider,
            .use_responses_endpoint = self.use_responses_endpoint,
            .enable_thinking = self.enable_thinking,
            .context = self.context,
        };
        errdefer out.deinit(gpa);
        if (self.version) |s| out.version = try gpa.dupe(u8, s);
        if (self.provider_name) |s| out.provider_name = try gpa.dupe(u8, s);
        if (self.base_url) |s| out.base_url = try gpa.dupe(u8, s);
        if (self.api_key) |s| out.api_key = try gpa.dupe(u8, s);
        if (self.bash_classifier_url) |s| out.bash_classifier_url = try gpa.dupe(u8, s);
        if (self.model) |m| out.model = try m.clone(gpa);
        out.providers = try gpa.alloc(ProviderConfig, self.providers.len);
        for (self.providers, 0..) |provider, index| out.providers[index] = try provider.clone(gpa);
        out.mcp_servers = try gpa.alloc(McpServerConfig, self.mcp_servers.len);
        for (self.mcp_servers, 0..) |server, index| out.mcp_servers[index] = try server.clone(gpa);
        if (self.system_prompt) |s| out.system_prompt = try gpa.dupe(u8, s);
        if (self.dynamic_provider_name) |s| out.dynamic_provider_name = try gpa.dupe(u8, s);
        if (self.dynamic_provider_id) |s| out.dynamic_provider_id = try gpa.dupe(u8, s);
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
            const major = parseSemverMajor(v) orelse {
                try list.append(gpa, .{ .config_parse_error = .{
                    .path = try gpa.dupe(u8, "version"),
                    .reason = try std.fmt.allocPrint(gpa, "invalid semver '{s}'", .{v}),
                } });
                return try list.toOwnedSlice(gpa);
            };
            if (major > 2) {
                try list.append(gpa, .{ .config_parse_error = .{
                    .path = try gpa.dupe(u8, "version"),
                    .reason = try std.fmt.allocPrint(gpa, "unsupported schema version {s}", .{v}),
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
        const name = self.provider_name orelse provider.label();
        return .{ .provider = provider, .provider_name = name, .model = model };
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
///
/// When `updates.model_selection` is present it is treated as the canonical
/// form and all legacy fields are derived from it. When absent, individual
/// legacy fields are applied and `target.model_selection` (if present) is
/// kept in sync so `serialize` — which prefers `model_selection` — always
/// writes the correct values.
fn applyConfigOverlay(gpa: std.mem.Allocator, target: *Config, updates: Config) !void {
    if (updates.model_selection) |ms| {
        // Canonical form: model_selection is the single source of truth.
        // Mirror all fields onto the target's legacy fields so the merge
        // result is self-consistent regardless of which path serialize uses.
        target.provider = ms.provider;
        // Propagate provider_name so serialize's legacy fallback writes the
        // correct config key (e.g. "stepfun-ai-step-plan") instead of the
        // enum label ("openai_compatible").
        if (target.provider_name) |old| gpa.free(old);
        target.provider_name = try gpa.dupe(u8, ms.provider_name);
        if (target.model) |*old| old.deinit(gpa);
        target.model = try ms.model.clone(gpa);
        try replaceOptionalSlice(gpa, &target.base_url, ms.base_url);
        try replaceOptionalSlice(gpa, &target.api_key, ms.api_key);
        target.use_responses_endpoint = ms.use_responses_endpoint;
        target.enable_thinking = ms.enable_thinking;
        if (ms.system_prompt) |s| try replaceOptionalSlice(gpa, &target.system_prompt, s);
        if (ms.bash_classifier_url) |s| try replaceOptionalSlice(gpa, &target.bash_classifier_url, s);
    } else {
        // Legacy fields: apply individual field overrides.
        if (updates.provider) |v| target.provider = v;
        if (updates.use_responses_endpoint) |v| target.use_responses_endpoint = v;
        if (updates.enable_thinking) |v| target.enable_thinking = v;
        if (updates.base_url) |s| try replaceOptionalSlice(gpa, &target.base_url, s);
        if (updates.api_key) |s| try replaceOptionalSlice(gpa, &target.api_key, s);
        if (updates.bash_classifier_url) |s| try replaceOptionalSlice(gpa, &target.bash_classifier_url, s);
        if (updates.system_prompt) |s| try replaceOptionalSlice(gpa, &target.system_prompt, s);
        if (updates.model) |m| {
            if (target.model) |*old| old.deinit(gpa);
            target.model = try m.clone(gpa);
        }
        // Keep model_selection in sync with legacy fields so serialize
        // (which prefers model_selection) picks up the changes.
        try syncModelSelectionFromLegacy(gpa, target);
    }
    for (updates.providers) |provider| try applyProviderOverlay(gpa, target, provider);
    for (updates.mcp_servers) |mcp_server| try applyMcpServerOverlay(gpa, target, mcp_server);
    applyContextOverlay(&target.context, updates.context);
}

/// Merge context settings: non-default values in `updates` override `target`.
fn applyContextOverlay(target: *ContextSettings, updates: ContextSettings) void {
    if (updates.override_context_window != null) target.override_context_window = updates.override_context_window;
    if (updates.max_output_tokens != null) target.max_output_tokens = updates.max_output_tokens;
    if (updates.max_parallel_tool_calls != null) target.max_parallel_tool_calls = updates.max_parallel_tool_calls;
    if (updates.request_timeout_seconds != null) target.request_timeout_seconds = updates.request_timeout_seconds;
    const d: CompactionSettings = .{};
    if (updates.compaction.auto != d.auto) target.compaction.auto = updates.compaction.auto;
    if (updates.compaction.threshold != d.threshold) target.compaction.threshold = updates.compaction.threshold;
    if (updates.compaction.buffer_tokens != d.buffer_tokens) target.compaction.buffer_tokens = updates.compaction.buffer_tokens;
    if (updates.compaction.keep_recent_tokens != d.keep_recent_tokens) target.compaction.keep_recent_tokens = updates.compaction.keep_recent_tokens;
}

/// After applying legacy-field updates, mirror the changes onto
/// `target.model_selection` (if present) so `serialize` — which
/// prefers `model_selection` — writes the correct values.
pub fn syncModelSelectionFromLegacy(gpa: std.mem.Allocator, target: *Config) !void {
    if (target.model_selection) |*ms| {
        if (target.provider) |p| ms.provider = p;
        if (target.model) |m| {
            ms.model.deinit(gpa);
            ms.model = try m.clone(gpa);
        }
        if (target.base_url) |s| {
            gpa.free(ms.base_url);
            ms.base_url = try gpa.dupe(u8, s);
        }
        if (target.api_key) |s| {
            gpa.free(ms.api_key);
            ms.api_key = try gpa.dupe(u8, s);
        }
        if (target.use_responses_endpoint) |v| ms.use_responses_endpoint = v;
        if (target.enable_thinking) |v| ms.enable_thinking = v;
        if (target.system_prompt) |s| {
            if (ms.system_prompt) |old| gpa.free(old);
            ms.system_prompt = try gpa.dupe(u8, s);
        }
        if (target.bash_classifier_url) |s| {
            if (ms.bash_classifier_url) |old| gpa.free(old);
            ms.bash_classifier_url = try gpa.dupe(u8, s);
        }
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
            switch (update.reasoning) {
                .effort => model.reasoning = update.reasoning,
                .unset => {},
            }
            if (update.reasoning_options.len > 0) {
                if (model.reasoning_options.len > 0) gpa.free(model.reasoning_options);
                model.reasoning_options = try gpa.dupe(ai.ReasoningEffort, update.reasoning_options);
            }
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
    const name = config.provider_name orelse provider.label();
    for (config.providers) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        try hydrateFromProviderEntry(gpa, config, entry);
        return;
    }
    // Recovery: configs written before the provider_name serialization
    // fix have provider_name = "openai_compatible" (the enum label)
    // while the providers[] key is the actual id (e.g. "stepfun-ai").
    // Match by provider enum and repair provider_name so auth.json
    // lookups and subsequent serializations use the correct key.
    if (provider == .openai_compatible) {
        for (config.providers) |entry| {
            if (entry.provider != .openai_compatible) continue;
            if (config.provider_name) |old| gpa.free(old);
            config.provider_name = try gpa.dupe(u8, entry.name);
            try hydrateFromProviderEntry(gpa, config, entry);
            return;
        }
    }
}

fn hydrateFromProviderEntry(gpa: std.mem.Allocator, config: *Config, entry: ProviderConfig) !void {
    switch (entry.base_url) {
        .custom => |base_url| try replaceOptionalSlice(gpa, &config.base_url, base_url),
        .default => {},
    }
    for (entry.models) |model| {
        if (!std.mem.eql(u8, model.id, config.model.?.id)) continue;
        // When adding fields to Model, also copy them here so they
        // survive the merge → hydrate cycle.
        switch (model.reasoning) {
            .effort => config.model.?.reasoning = model.reasoning,
            .unset => {},
        }
        config.model.?.context_window = model.context_window;
        config.model.?.max_output_tokens = model.max_output_tokens;
        if (model.reasoning_options.len > 0) {
            if (config.model.?.reasoning_options.len > 0) gpa.free(config.model.?.reasoning_options);
            config.model.?.reasoning_options = try gpa.dupe(ai.ReasoningEffort, model.reasoning_options);
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

    // Version: accept semver string ("2.0.0") or legacy integer (1).
    if (value.object.get("version")) |ver| {
        switch (ver) {
            .string => |s| out.version = try gpa.dupe(u8, s),
            .integer => |v| out.version = try std.fmt.allocPrint(gpa, "{d}.0.0", .{v}),
            else => {},
        }
    }

    // Model: accept "defaultModel" (camelCase) or "model" (legacy).
    const model_str = stringFieldCompat(value, "defaultModel", "model");
    if (model_str) |s| {
        if (parseModelSelection(gpa, s)) |selection| {
            out.provider = selection.provider;
            out.provider_name = selection.provider_name;
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
    const mcp_val = value.object.get("mcpServers") orelse value.object.get("mcp_servers") orelse value.object.get("mcp");
    if (mcp_val) |val| {
        if (val == .object) out.mcp_servers = try parseMcpServers(gpa, val);
    }

    // Scalar fields: camelCase primary, snake_case fallback.
    if (stringFieldCompat(value, "baseURL", "base_url")) |s| {
        out.base_url = try gpa.dupe(u8, s);
    }
    if (stringFieldCompat(value, "bashClassifierUrl", "bash_classifier_url")) |s| {
        if (s.len > 0) out.bash_classifier_url = try gpa.dupe(u8, s);
    }
    if (boolFieldCompat(value, "useResponsesEndpoint", "use_responses_endpoint")) |b| out.use_responses_endpoint = b;
    if (boolFieldCompat(value, "enableThinking", "enable_thinking")) |b| out.enable_thinking = b;
    if (stringFieldCompat(value, "systemPrompt", "system_prompt")) |s| {
        out.system_prompt = try gpa.dupe(u8, s);
    }

    // Context window and compaction settings.
    if (value.object.get("context")) |ctx_val| {
        if (ctx_val == .object) out.context = parseContext(ctx_val);
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
            .provider_name = out.provider_name orelse try gpa.dupe(u8, out.provider.?.label()),
            .model = out.model.?, // ownership moves; clear the legacy field
            .base_url = out.base_url.?,
            .api_key = out.api_key.?,
            .use_responses_endpoint = out.use_responses_endpoint orelse false,
            .enable_thinking = out.enable_thinking orelse false,
            .system_prompt = out.system_prompt,
            .bash_classifier_url = out.bash_classifier_url,
        };
        out.provider = null;
        out.provider_name = null;
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

/// String field with camelCase primary and snake_case fallback.
fn stringFieldCompat(value: std.json.Value, camel: []const u8, snake: []const u8) ?[]const u8 {
    if (fieldCompat(value.object, camel, snake)) |field| {
        if (field == .string) return field.string;
    }
    return null;
}

/// Bool field with camelCase primary and snake_case fallback.
fn boolFieldCompat(value: std.json.Value, camel: []const u8, snake: []const u8) ?bool {
    if (fieldCompat(value.object, camel, snake)) |field| {
        if (field == .bool) return field.bool;
    }
    return null;
}

/// Parse the `"context"` object into `ContextSettings`. Pure — no
/// allocation (all fields are scalars).
fn parseContext(value: std.json.Value) ContextSettings {
    var ctx: ContextSettings = .{};
    if (intField(value, "overrideContextWindow")) |v| {
        if (v >= 1024) ctx.override_context_window = @intCast(v);
    }
    if (intField(value, "maxOutputTokens")) |v| {
        if (v >= 1) ctx.max_output_tokens = @intCast(v);
    }
    if (intField(value, "maxParallelToolCalls")) |v| {
        if (v >= 1 and v <= 64) ctx.max_parallel_tool_calls = @intCast(v);
    }
    if (intField(value, "requestTimeoutSeconds")) |v| {
        if (v >= 1) ctx.request_timeout_seconds = @intCast(v);
    }
    if (value.object.get("compaction")) |comp_val| {
        if (comp_val == .object) ctx.compaction = parseCompaction(comp_val);
    }
    return ctx;
}

fn parseCompaction(value: std.json.Value) CompactionSettings {
    var comp: CompactionSettings = .{};
    if (boolField(value, "auto")) |b| comp.auto = b;
    if (floatField(value, "threshold")) |f| {
        if (f >= 0.1 and f <= 1.0) comp.threshold = f;
    }
    if (intField(value, "bufferTokens")) |v| {
        if (v >= 0) comp.buffer_tokens = @intCast(v);
    }
    if (intField(value, "keepRecentTokens")) |v| {
        if (v >= 0) comp.keep_recent_tokens = @intCast(v);
    }
    return comp;
}

fn parseProviders(gpa: std.mem.Allocator, value: std.json.Value) ![]ProviderConfig {
    var providers: std.ArrayList(ProviderConfig) = .empty;
    errdefer {
        for (providers.items) |*provider| provider.deinit(gpa);
        providers.deinit(gpa);
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        // Builtin labels resolve to their enum; unknown keys are custom
        // providers using the openai_compatible adapter.
        const provider = providers_by_name.get(entry.key_ptr.*) orelse .openai_compatible;
        try providers.append(gpa, try parseProviderConfig(gpa, entry.key_ptr.*, provider, entry.value_ptr.*));
    }
    return try providers.toOwnedSlice(gpa);
}

fn parseMcpServers(gpa: std.mem.Allocator, value: std.json.Value) ![]McpServerConfig {
    var servers: std.ArrayList(McpServerConfig) = .empty;
    errdefer {
        for (servers.items) |*server| server.deinit(gpa);
        servers.deinit(gpa);
    }
    // Process environment, captured once so `{env:VAR}` placeholders in
    // command/args/url expand against a consistent snapshot.
    var env_map = try loadEnvMap(gpa);
    defer env_map.deinit();

    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const val = entry.value_ptr.*;

        const cmd = stringField(val, "command");
        const url = stringField(val, "url");
        // Exactly one transport: stdio (command) or remote (url). Both or
        // neither is invalid — mirrors the transport union and the
        // MCPServerConfig oneOf in schema/config.schema.json. Checked before
        // `server`/its errdefer so a rejection never deinits a server whose
        // transport is still undefined.
        if (cmd != null and url != null) return error.InvalidMcpServerConfig;
        if (cmd == null and url == null) return error.InvalidMcpServerConfig;

        var server: McpServerConfig = undefined;
        server.name = try gpa.dupe(u8, entry.key_ptr.*);
        server.enabled = boolField(val, "enabled") orelse true;
        errdefer server.deinit(gpa);

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
                            try args_list.append(gpa, try expandEnvVars(gpa, arg_item.string, &env_map));
                        }
                    }
                    args = try args_list.toOwnedSlice(gpa);
                }
            }
            server.transport = .{ .stdio = .{
                .command = try expandEnvVars(gpa, c, &env_map),
                .args = args,
            } };
        } else {
            // url is guaranteed non-null by the guards above (exactly one transport).
            server.transport = .{ .sse = .{ .url = try expandEnvVars(gpa, url.?, &env_map) } };
        }
        try servers.append(gpa, server);
    }
    return try servers.toOwnedSlice(gpa);
}

/// Capture the process environment as a lookup map for `{env:VAR}` expansion.
/// POSIX reads the raw environ block via `std.mem.span` (null-safe in
/// multi-threaded contexts); Windows uses the global block. Mirrors the
/// established pattern in `tools/bash.zig:currentEnvMap`.
fn loadEnvMap(gpa: std.mem.Allocator) !std.process.Environ.Map {
    if (builtin.os.tag == .windows) {
        return std.process.Environ.createMap(.{ .block = .global }, gpa);
    }
    const env_slice = std.mem.span(std.c.environ);
    return std.process.Environ.createMap(.{ .block = .{ .slice = env_slice } }, gpa);
}

/// Expand `{env:VAR}` placeholders in `input`, looking each name up in
/// `env_map`. Returns a newly-allocated string (caller frees). A placeholder
/// whose variable is unset is replaced with an empty string and a warning is
/// logged, so a missing secret surfaces instead of silently producing a
/// broken URL. Mirrors the `{env:VAR}` convention used by other MCP clients
/// so existing server snippets work unchanged.
fn expandEnvVars(gpa: std.mem.Allocator, input: []const u8, env_map: *const std.process.Environ.Map) ![]u8 {
    // Fast path: no placeholder — dupe as-is.
    if (std.mem.indexOf(u8, input, "{env:") == null) return try gpa.dupe(u8, input);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var rest = input;
    while (std.mem.indexOf(u8, rest, "{env:")) |start| {
        try out.writer.writeAll(rest[0..start]);
        const name_begin = start + "{env:".len;
        const close_rel = std.mem.indexOfScalar(u8, rest[name_begin..], '}') orelse {
            // Unterminated placeholder — emit the remainder verbatim and stop.
            try out.writer.writeAll(rest[start..]);
            rest = "";
            break;
        };
        const name = rest[name_begin .. name_begin + close_rel];
        if (env_map.get(name)) |value| {
            try out.writer.writeAll(value);
        } else {
            std.log.warn("MCP config: environment variable '{s}' is not set; substituting empty string. Export it or remove the placeholder.", .{name});
        }
        rest = rest[name_begin + close_rel + 1 ..];
    }
    try out.writer.writeAll(rest);
    return out.toOwnedSlice();
}

/// Build a remote (Streamable HTTP) MCP server config from a name and a raw
/// URL, expanding any `{env:VAR}` placeholders against the process environment.
/// Used by the TUI's "add server by URL" flow so env expansion stays in one
/// place (the same `expandEnvVars` the JSON parser uses). Caller owns the
/// result; free with `McpServerConfig.deinit`.
pub fn mcpServerFromUrl(gpa: std.mem.Allocator, name: []const u8, raw_url: []const u8) !McpServerConfig {
    var env_map = try loadEnvMap(gpa);
    defer env_map.deinit();
    return .{
        .name = try gpa.dupe(u8, name),
        .enabled = true,
        .transport = .{ .sse = .{ .url = try expandEnvVars(gpa, raw_url, &env_map) } },
    };
}

fn parseProviderConfig(gpa: std.mem.Allocator, name: []const u8, provider: Provider, value: std.json.Value) !ProviderConfig {
    var out: ProviderConfig = .{
        .name = try gpa.dupe(u8, name),
        .provider = provider,
    };
    errdefer out.deinit(gpa);
    if (stringFieldCompat(value, "baseURL", "base_url")) |s| out.base_url = .{ .custom = try gpa.dupe(u8, s) };
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
        const val = entry.value_ptr.*;
        var model: ProviderModel = .{
            .id = try gpa.dupe(u8, entry.key_ptr.*),
            .reasoning = if (stringField(val, "reasoningEffort")) |effort|
                if (reasoning_efforts_by_name.get(effort)) |e| .{ .effort = e } else .unset
            else
                .unset,
        };
        if (intField(val, "contextWindow")) |v| {
            if (v >= 1024) model.context_window = @intCast(v);
        }
        if (intField(val, "maxOutputTokens")) |v| {
            if (v >= 1) model.max_output_tokens = @intCast(v);
        }
        if (val.object.get("reasoningOptions")) |opts| {
            if (opts == .array) {
                var list: std.ArrayList(ai.ReasoningEffort) = .empty;
                errdefer list.deinit(gpa);
                for (opts.array.items) |item| {
                    if (item != .string) continue;
                    if (reasoning_efforts_by_name.get(item.string)) |e| {
                        try list.append(gpa, e);
                    }
                }
                if (list.items.len > 0) {
                    model.reasoning_options = try list.toOwnedSlice(gpa);
                }
            }
        }
        try models.append(gpa, model);
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
            out.provider_name = parsed.provider_name;
            out.model = parsed.model;
        } else |_| {
            try diagnostics.append(gpa, .{ .bad_env_model = try gpa.dupe(u8, raw) });
        }
    }
    return out;
}

const ParsedModelSelection = struct {
    /// Resolved builtin provider, or `.openai_compatible` for custom names.
    provider: Provider,
    /// The raw provider name as written in the selection string. For
    /// builtins this equals `provider.label()`; for custom providers
    /// it's the user-chosen name (e.g. "qwen-cloud").
    provider_name: []u8,
    model: Model,
};

fn parseModelSelection(gpa: std.mem.Allocator, raw: []const u8) !ParsedModelSelection {
    const slash = std.mem.findScalar(u8, raw, '/') orelse return error.MissingSeparator;
    const provider_part = raw[0..slash];
    const model_part = raw[slash + 1 ..];
    if (provider_part.len == 0) return error.MissingProvider;
    if (model_part.len == 0) return error.MissingModel;
    // Builtin providers resolve to their enum; unknown names are treated
    // as custom providers using the openai_compatible adapter. The name
    // is preserved for display, auth lookup, and providers-map matching.
    const provider = providers_by_name.get(provider_part) orelse .openai_compatible;
    return .{
        .provider = provider,
        .provider_name = try gpa.dupe(u8, provider_part),
        .model = .{ .id = try gpa.dupe(u8, model_part) },
    };
}

fn parseBool(s: []const u8) bool {
    if (std.mem.eql(u8, s, "1")) return true;
    if (std.ascii.eqlIgnoreCase(s, "true")) return true;
    return false;
}

/// Extract the major version number from a semver string ("2.0.0" → 2).
/// Returns null when the string is not a valid semver.
fn parseSemverMajor(s: []const u8) ?u32 {
    const dot = std.mem.findScalar(u8, s, '.') orelse {
        // Bare integer ("2") is accepted as major-only.
        return std.fmt.parseInt(u32, s, 10) catch null;
    };
    return std.fmt.parseInt(u32, s[0..dot], 10) catch null;
}

const reasoning_efforts_by_name = std.StaticStringMap(ai.ReasoningEffort).initComptime(.{
    .{ "default", .default },
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

fn floatField(value: std.json.Value, name: []const u8) ?f64 {
    const field = value.object.get(name) orelse return null;
    return switch (field) {
        .float => field.float,
        .integer => @floatFromInt(field.integer),
        else => null,
    };
}

/// Look up a JSON key trying camelCase first, then snake_case fallback.
/// Returns the value from whichever key exists (camelCase wins).
fn fieldCompat(object: std.json.ObjectMap, camel: []const u8, snake: []const u8) ?std.json.Value {
    return object.get(camel) orelse object.get(snake);
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
/// auth.json (see auth.ApiKeyMap). This is the one place that enforces it, so
/// callers never have to thread a "should I persist the key?" flag through the
/// merge path. The "serialize: skips api_key even if present" test guards it.
///
/// JSON keys are camelCase (schema v2). Parse accepts both camelCase and
/// legacy snake_case for backward compatibility.
fn serialize(gpa: std.mem.Allocator, writer: *std.Io.Writer, config: Config) !void {
    // Version: semver string.
    try writer.writeAll("{\n  \"version\": ");
    try std.json.Stringify.value(config.version orelse Config.default_version, .{}, writer);
    var wrote_any = true;

    // Prefer the typed `model_selection` when present; fall back to
    // legacy fields for Configs that bypass parseObject (tests).
    // "provider" is NOT written — defaultModel already encodes the
    // provider name as its "provider/model" prefix, and parseObject
    // only reads defaultModel (via parseModelSelection).
    if (config.model_selection) |ms| {
        try writeKey(writer, "defaultModel", &wrote_any);
        try writeModelSelection(gpa, writer, ms.provider_name, ms.model.id);
        if (ms.use_responses_endpoint) {
            try writeKey(writer, "useResponsesEndpoint", &wrote_any);
            try writer.writeAll("true");
        }
        if (ms.enable_thinking) {
            try writeKey(writer, "enableThinking", &wrote_any);
            try writer.writeAll("true");
        }
        if (ms.system_prompt) |s| {
            try writeKey(writer, "systemPrompt", &wrote_any);
            try std.json.Stringify.value(s, .{}, writer);
        }
        if (ms.bash_classifier_url) |url| {
            try writeKey(writer, "bashClassifierUrl", &wrote_any);
            try std.json.Stringify.value(url, .{}, writer);
        }
    } else {
        if (config.use_responses_endpoint) |b| {
            try writeKey(writer, "useResponsesEndpoint", &wrote_any);
            try writer.writeAll(if (b) "true" else "false");
        }
        if (config.enable_thinking) |b| {
            try writeKey(writer, "enableThinking", &wrote_any);
            try writer.writeAll(if (b) "true" else "false");
        }
        if (config.model) |m| {
            if (config.provider) |provider| {
                try writeKey(writer, "defaultModel", &wrote_any);
                const name = config.provider_name orelse provider.label();
                try writeModelSelection(gpa, writer, name, m.id);
            }
        }
        if (config.system_prompt) |s| {
            try writeKey(writer, "systemPrompt", &wrote_any);
            try std.json.Stringify.value(s, .{}, writer);
        }
        if (config.bash_classifier_url) |url| {
            try writeKey(writer, "bashClassifierUrl", &wrote_any);
            try std.json.Stringify.value(url, .{}, writer);
        }
    }
    if (config.providers.len > 0) {
        try writeKey(writer, "providers", &wrote_any);
        try writeProviders(writer, config.providers);
    }
    if (config.mcp_servers.len > 0) {
        try writeKey(writer, "mcpServers", &wrote_any);
        try writeMcpServers(writer, config.mcp_servers);
    }
    // Context: only written when at least one field differs from defaults.
    if (hasNonDefaultContext(config.context)) {
        try writeKey(writer, "context", &wrote_any);
        try writeContext(writer, config.context);
    }
    try writer.writeAll("\n}\n");
}

fn hasNonDefaultContext(ctx: ContextSettings) bool {
    const d: ContextSettings = .{};
    if (ctx.override_context_window != null) return true;
    if (ctx.max_output_tokens != null) return true;
    if (ctx.max_parallel_tool_calls != null) return true;
    if (ctx.request_timeout_seconds != null) return true;
    if (ctx.compaction.auto != d.compaction.auto) return true;
    if (ctx.compaction.threshold != d.compaction.threshold) return true;
    if (ctx.compaction.buffer_tokens != d.compaction.buffer_tokens) return true;
    if (ctx.compaction.keep_recent_tokens != d.compaction.keep_recent_tokens) return true;
    return false;
}

fn writeContext(writer: *std.Io.Writer, ctx: ContextSettings) !void {
    try writer.writeByte('{');
    var wrote_any = false;
    if (ctx.override_context_window) |v| {
        try writeKeyNoIndent(writer, "overrideContextWindow", &wrote_any);
        try writer.print("{d}", .{v});
    }
    if (ctx.max_output_tokens) |v| {
        try writeKeyNoIndent(writer, "maxOutputTokens", &wrote_any);
        try writer.print("{d}", .{v});
    }
    if (ctx.max_parallel_tool_calls) |v| {
        try writeKeyNoIndent(writer, "maxParallelToolCalls", &wrote_any);
        try writer.print("{d}", .{v});
    }
    if (ctx.request_timeout_seconds) |v| {
        try writeKeyNoIndent(writer, "requestTimeoutSeconds", &wrote_any);
        try writer.print("{d}", .{v});
    }
    // Compaction: always written when context is present.
    try writeKeyNoIndent(writer, "compaction", &wrote_any);
    try writeCompaction(writer, ctx.compaction);
    try writer.writeByte('}');
}

fn writeCompaction(writer: *std.Io.Writer, comp: CompactionSettings) !void {
    try writer.writeByte('{');
    var wrote_any = false;
    if (!comp.auto) {
        try writeKeyNoIndent(writer, "auto", &wrote_any);
        try writer.writeAll("false");
    }
    {
        try writeKeyNoIndent(writer, "threshold", &wrote_any);
        try writer.print("{d:.2}", .{comp.threshold});
    }
    {
        try writeKeyNoIndent(writer, "bufferTokens", &wrote_any);
        try writer.print("{d}", .{comp.buffer_tokens});
    }
    {
        try writeKeyNoIndent(writer, "keepRecentTokens", &wrote_any);
        try writer.print("{d}", .{comp.keep_recent_tokens});
    }
    try writer.writeByte('}');
}

fn writeModelSelection(gpa: std.mem.Allocator, writer: *std.Io.Writer, provider_name: []const u8, model_id: []const u8) !void {
    const selection = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ provider_name, model_id });
    defer gpa.free(selection);
    try std.json.Stringify.value(selection, .{}, writer);
}

fn writeProviders(writer: *std.Io.Writer, providers: []const ProviderConfig) !void {
    try writer.writeByte('{');
    var wrote_provider = false;
    for (providers) |provider| {
        if (wrote_provider) try writer.writeByte(',');
        try std.json.Stringify.value(provider.name, .{}, writer);
        try writer.writeByte(':');
        try writeProvider(writer, provider);
        wrote_provider = true;
    }
    try writer.writeByte('}');
}

fn writeProvider(writer: *std.Io.Writer, provider: ProviderConfig) !void {
    try writer.writeByte('{');
    var wrote_any = false;
    switch (provider.base_url) {
        .custom => |base_url| {
            try writeKeyNoIndent(writer, "baseURL", &wrote_any);
            try std.json.Stringify.value(base_url, .{}, writer);
        },
        .default => {},
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
        var wrote_field = false;
        if (model.reasoning == .effort) {
            try std.json.Stringify.value("reasoningEffort", .{}, writer);
            try writer.writeByte(':');
            try std.json.Stringify.value(model.reasoning.effort.label(), .{}, writer);
            wrote_field = true;
        }
        if (model.context_window) |cw| {
            if (wrote_field) try writer.writeByte(',');
            try std.json.Stringify.value("contextWindow", .{}, writer);
            try writer.writeByte(':');
            try writer.print("{d}", .{cw});
            wrote_field = true;
        }
        if (model.max_output_tokens) |mot| {
            if (wrote_field) try writer.writeByte(',');
            try std.json.Stringify.value("maxOutputTokens", .{}, writer);
            try writer.writeByte(':');
            try writer.print("{d}", .{mot});
            wrote_field = true;
        }
        if (model.reasoning_options.len > 0) {
            if (wrote_field) try writer.writeByte(',');
            try std.json.Stringify.value("reasoningOptions", .{}, writer);
            try writer.writeByte(':');
            try writer.writeByte('[');
            for (model.reasoning_options, 0..) |opt, idx| {
                if (idx > 0) try writer.writeByte(',');
                try std.json.Stringify.value(opt.label(), .{}, writer);
            }
            try writer.writeByte(']');
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

    // Standard XDG path: ~/.config/nova/config.json
    const xdg_path = try std.fs.path.join(gpa, &.{ home_dir, ".config", "nova", "config.json" });
    errdefer gpa.free(xdg_path);

    if (std.Io.Dir.access(.cwd(), io, xdg_path, .{})) |_| {
        return xdg_path;
    } else |_| {}

    // Default to XDG path for new config writes
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
    defer gpa.free(parsed.provider_name);
    try std.testing.expectEqual(Provider.openai, parsed.provider);
    try std.testing.expectEqualStrings("openai", parsed.provider_name);
    try std.testing.expectEqualStrings("gpt-5.5", parsed.model.id);
}

test "parseModelSelection: ollama/llama3.1:8b" {
    const gpa = std.testing.allocator;
    var parsed = try parseModelSelection(gpa, "ollama/llama3.1:8b");
    defer parsed.model.deinit(gpa);
    defer gpa.free(parsed.provider_name);
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
    defer gpa.free(parsed.provider_name);
    try std.testing.expectEqual(Provider.openrouter, parsed.provider);
    try std.testing.expectEqualStrings("anthropic/claude-3.7-sonnet", parsed.model.id);
}

test "parseModelSelection: unknown provider resolves to openai_compatible" {
    const gpa = std.testing.allocator;
    var parsed = try parseModelSelection(gpa, "qwen-cloud/qwen-plus");
    defer parsed.model.deinit(gpa);
    defer gpa.free(parsed.provider_name);
    try std.testing.expectEqual(Provider.openai_compatible, parsed.provider);
    try std.testing.expectEqualStrings("qwen-cloud", parsed.provider_name);
    try std.testing.expectEqualStrings("qwen-plus", parsed.model.id);
}

test "parseModelSelection: anthropic parses (validity checked downstream)" {
    const gpa = std.testing.allocator;
    var parsed = try parseModelSelection(gpa, "anthropic/claude-3.7-sonnet");
    defer parsed.model.deinit(gpa);
    defer gpa.free(parsed.provider_name);
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
    try std.testing.expectEqual(ReasoningSetting.unset, cfg.model.?.reasoning);
    // Merging hydrates the active model against the parsed providers.
    var merged = try mergeLayers(gpa, &.{cfg});
    defer merged.deinit(gpa);
    try std.testing.expectEqual(ai.ReasoningEffort.high, merged.model.?.reasoning.effort);
}

test "parseObject: unknown provider resolves to openai_compatible custom" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (sink.items) |*d| d.deinit(gpa);
        sink.deinit(gpa);
    }
    var cfg = try parseFile(gpa, "<test>", "{\"defaultModel\":\"qwen-cloud/qwen-plus\"}", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Provider.openai_compatible, cfg.provider.?);
    try std.testing.expectEqualStrings("qwen-cloud", cfg.provider_name.?);
    try std.testing.expectEqualStrings("qwen-plus", cfg.model.?.id);
    try std.testing.expectEqual(@as(usize, 0), sink.items.len);
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
        .model = .{ .id = try gpa.dupe(u8, "m1"), .reasoning = .{ .effort = .low } },
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
    try std.testing.expectEqual(ai.ReasoningEffort.low, merged.model.?.reasoning.effort);
}

test "mergeLayers: model is indivisible — higher layer's model replaces whole" {
    const gpa = std.testing.allocator;
    var layer1: Config = .{
        .model = .{ .id = try gpa.dupe(u8, "m1"), .reasoning = .{ .effort = .high } },
    };
    defer layer1.deinit(gpa);
    var layer2: Config = .{
        .model = .{ .id = try gpa.dupe(u8, "m2") }, // no reasoning
    };
    defer layer2.deinit(gpa);

    var merged = try mergeLayers(gpa, &.{ layer1, layer2 });
    defer merged.deinit(gpa);

    try std.testing.expectEqualStrings("m2", merged.model.?.id);
    // Higher layer's model replaces whole — lower layer's reasoning
    // does NOT survive, because model is indivisible during merge.
    try std.testing.expectEqual(ReasoningSetting.unset, merged.model.?.reasoning);
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
    provider_models[0] = .{ .id = try gpa.dupe(u8, "gpt-5.5"), .reasoning = .{ .effort = .medium } };
    var providers = try gpa.alloc(ProviderConfig, 1);
    providers[0] = .{ .name = try gpa.dupe(u8, "openai"), .provider = .openai, .models = provider_models };
    var cfg: Config = .{
        .provider = .openai,
        .api_key = try gpa.dupe(u8, "sk-should-never-appear"),
        .model = .{ .id = try gpa.dupe(u8, "gpt-5.5"), .reasoning = .{ .effort = .medium } },
        .providers = providers,
    };
    defer cfg.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, cfg);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "api_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "sk-should-never-appear") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"defaultModel\": \"openai/gpt-5.5\"") != null);
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
    models[0] = .{ .id = try gpa.dupe(u8, "gpt-5.5"), .reasoning = .{ .effort = .medium } };
    const providers = try gpa.alloc(ProviderConfig, 1);
    providers[0] = .{ .name = try gpa.dupe(u8, "openai"), .provider = .openai, .base_url = .{ .custom = try gpa.dupe(u8, "https://from-provider") }, .models = models };
    var global: Config = .{ .providers = providers };
    defer global.deinit(gpa);
    // ...the active model selection comes from another, carrying no reasoning.
    var project: Config = .{ .provider = .openai, .model = .{ .id = try gpa.dupe(u8, "gpt-5.5") } };
    defer project.deinit(gpa);

    var merged = try mergeLayers(gpa, &.{ global, project });
    defer merged.deinit(gpa);

    // Hydration runs once over the merged providers, so the cross-layer match
    // copies reasoning effort and base_url onto the chosen model.
    try std.testing.expectEqual(ai.ReasoningEffort.medium, merged.model.?.reasoning.effort);
    try std.testing.expectEqualStrings("https://from-provider", merged.base_url.?);
}

test "serialize then parse roundtrips" {
    const gpa = std.testing.allocator;
    var provider_models = try gpa.alloc(ProviderModel, 1);
    provider_models[0] = .{ .id = try gpa.dupe(u8, "llama3.1:8b") };
    var providers = try gpa.alloc(ProviderConfig, 1);
    providers[0] = .{
        .name = try gpa.dupe(u8, "ollama"),
        .provider = .ollama,
        .base_url = .{ .custom = try gpa.dupe(u8, "http://localhost:11434/v1") },
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

test "globalConfigPath resolves XDG .config/nova/config.json" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const path = try globalConfigPath(gpa, io, "/home/testuser");
    defer gpa.free(path);

    try std.testing.expect(std.mem.indexOf(u8, path, ".config/nova/config.json") != null);
}

test "Config.validate validates schema version and base_url scheme" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{
        .version = try gpa.dupe(u8, "3.0.0"),
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

    try std.testing.expectEqual(@as(?[]u8, null), res.config.version);
    try std.testing.expectEqual(@as(?Provider, null), res.config.provider);
    try std.testing.expectEqual(@as(usize, 0), res.diagnostics.len);
}

test "serialize outputs semver version and camelCase 2-space indented JSON" {
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
    try std.testing.expect(std.mem.startsWith(u8, text, "{\n  \"version\": \"2.0.0\""));
    // "provider" is no longer written — defaultModel encodes the provider.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"provider\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  \"useResponsesEndpoint\": true") != null);
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

test "parseFile parses remote mcp server (url transport)" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"mcp_servers\":{\"remote\":{\"url\":\"https://mcp.example.com/mcp\"}}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.len);
    try std.testing.expectEqualStrings("remote", cfg.mcp_servers[0].name);
    switch (cfg.mcp_servers[0].transport) {
        .sse => |t| try std.testing.expectEqualStrings("https://mcp.example.com/mcp", t.url),
        .stdio => return error.Unexpected,
    }
}

test "parseFile rejects mcp server configuring both transports" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    // command + url is ambiguous — the transport union allows exactly one,
    // matching schema/config.schema.json's MCPServerConfig oneOf.
    const json = "{\"mcp_servers\":{\"bad\":{\"command\":\"npx\",\"url\":\"https://mcp.example.com/mcp\"}}}";
    try std.testing.expectError(
        error.InvalidMcpServerConfig,
        parseFile(gpa, "<test>", json, &sink),
    );
}

test "parseFile rejects mcp server with neither command nor url" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"mcp_servers\":{\"bad\":{\"enabled\":true}}}";
    try std.testing.expectError(
        error.InvalidMcpServerConfig,
        parseFile(gpa, "<test>", json, &sink),
    );
}

test "expandEnvVars leaves input without placeholders unchanged" {
    const gpa = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();

    const out = try expandEnvVars(gpa, "https://example.com/mcp", &env_map);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("https://example.com/mcp", out);
}

test "expandEnvVars substitutes a known variable" {
    const gpa = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("TAVILY_API_KEY", "secret123");

    const out = try expandEnvVars(gpa, "https://mcp.tavily.com/mcp/?tavilyApiKey={env:TAVILY_API_KEY}", &env_map);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("https://mcp.tavily.com/mcp/?tavilyApiKey=secret123", out);
}

test "expandEnvVars substitutes multiple variables with surrounding text" {
    const gpa = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("HOST", "example.com");
    try env_map.put("TOKEN", "abc");

    const out = try expandEnvVars(gpa, "https://{env:HOST}/mcp?token={env:TOKEN}&x=1", &env_map);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("https://example.com/mcp?token=abc&x=1", out);
}

test "expandEnvVars replaces an unset variable with an empty string" {
    const gpa = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();

    const out = try expandEnvVars(gpa, "https://x.com/?key={env:NOVA_TEST_UNSET_VAR}", &env_map);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("https://x.com/?key=", out);
}

test "expandEnvVars emits an unterminated placeholder verbatim" {
    const gpa = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("FOO", "bar");

    const out = try expandEnvVars(gpa, "https://x.com/?key={env:FOO", &env_map);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("https://x.com/?key={env:FOO", out);
}

test "parseFile expands {env:VAR} placeholders in mcp url" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    // Unset variable → empty substitution; verifies the parse→expand wiring
    // against the real environment without depending on a specific value.
    const json = "{\"mcp_servers\":{\"tavily\":{\"url\":\"https://mcp.tavily.com/mcp/?key={env:NOVA_TEST_UNSET_MCP_VAR}\"}}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.len);
    switch (cfg.mcp_servers[0].transport) {
        .sse => |t| try std.testing.expectEqualStrings("https://mcp.tavily.com/mcp/?key=", t.url),
        .stdio => return error.Unexpected,
    }
}

test "mcpServerFromUrl builds an enabled remote server with duped name and url" {
    const gpa = std.testing.allocator;
    var server = try mcpServerFromUrl(gpa, "tavily", "https://mcp.tavily.com/mcp/");
    defer server.deinit(gpa);
    try std.testing.expectEqualStrings("tavily", server.name);
    try std.testing.expect(server.enabled);
    switch (server.transport) {
        .sse => |t| try std.testing.expectEqualStrings("https://mcp.tavily.com/mcp/", t.url),
        .stdio => return error.Unexpected,
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

test "applyConfigOverlay: model_selection present uses canonical form" {
    const gpa = std.testing.allocator;
    var target: Config = .{
        .provider = .ollama,
        .model = .{ .id = try gpa.dupe(u8, "llama3.1:8b") },
    };
    defer target.deinit(gpa);

    // Updates carry model_selection (canonical) — legacy fields should be
    // ignored in favour of model_selection.
    var updates: Config = .{
        .provider = .openai, // legacy — should be ignored
        .model_selection = .{
            .provider = .anthropic,
            .provider_name = try gpa.dupe(u8, "anthropic"),
            .model = .{ .id = try gpa.dupe(u8, "claude-3.7-sonnet") },
            .base_url = try gpa.dupe(u8, "https://api.anthropic.com"),
            .api_key = try gpa.dupe(u8, ""),
        },
    };
    defer updates.deinit(gpa);

    try applyConfigOverlay(gpa, &target, updates);

    try std.testing.expectEqual(Provider.anthropic, target.provider.?);
    try std.testing.expectEqualStrings("claude-3.7-sonnet", target.model.?.id);
    try std.testing.expectEqualStrings("https://api.anthropic.com", target.base_url.?);
}

test "applyConfigOverlay: legacy fields sync to model_selection" {
    const gpa = std.testing.allocator;

    // Target starts with model_selection populated.
    var target: Config = .{};
    defer target.deinit(gpa);
    target.provider = .openai;
    target.model = .{ .id = try gpa.dupe(u8, "gpt-5.5") };
    target.base_url = try gpa.dupe(u8, "https://api.openai.com");
    target.api_key = try gpa.dupe(u8, "sk-test");
    target.use_responses_endpoint = false;
    target.enable_thinking = false;
    // Manually populate model_selection (normally done by parseObject).
    target.model_selection = .{
        .provider = .openai,
        .provider_name = try gpa.dupe(u8, "openai"),
        .model = .{ .id = try gpa.dupe(u8, "gpt-5.5") },
        .base_url = try gpa.dupe(u8, "https://api.openai.com"),
        .api_key = try gpa.dupe(u8, "sk-test"),
    };

    // Updates carry only legacy fields (no model_selection).
    var updates: Config = .{
        .enable_thinking = true,
        .system_prompt = try gpa.dupe(u8, "You are a helpful assistant."),
    };
    defer updates.deinit(gpa);

    try applyConfigOverlay(gpa, &target, updates);

    // Legacy fields updated.
    try std.testing.expectEqual(true, target.enable_thinking.?);
    try std.testing.expectEqualStrings("You are a helpful assistant.", target.system_prompt.?);

    // model_selection should also be in sync.
    try std.testing.expectEqual(true, target.model_selection.?.enable_thinking);
    try std.testing.expectEqualStrings("You are a helpful assistant.", target.model_selection.?.system_prompt.?);

    // Provider/model should be unchanged.
    try std.testing.expectEqual(Provider.openai, target.provider.?);
    try std.testing.expectEqualStrings("gpt-5.5", target.model.?.id);
}

test "mergeLayers: settings-only overlay does not overwrite provider/model" {
    const gpa = std.testing.allocator;

    // Simulate a global config with provider/model set.
    var global: Config = .{
        .provider = .openai,
        .model = .{ .id = try gpa.dupe(u8, "gpt-5.5") },
    };
    defer global.deinit(gpa);

    // Simulate a project config with a different provider/model.
    var project: Config = .{
        .provider = .ollama,
        .model = .{ .id = try gpa.dupe(u8, "llama3.1:8b") },
    };
    defer project.deinit(gpa);

    // Simulate a settings-only update (no provider/model, just enable_thinking).
    var settings: Config = .{
        .enable_thinking = true,
    };
    defer settings.deinit(gpa);

    // Merge: global → project → settings
    var merged = try mergeLayers(gpa, &.{ global, project, settings });
    defer merged.deinit(gpa);

    // Provider/model should come from project (last layer that set them).
    try std.testing.expectEqual(Provider.ollama, merged.provider.?);
    try std.testing.expectEqualStrings("llama3.1:8b", merged.model.?.id);
    // enable_thinking should come from settings.
    try std.testing.expectEqual(true, merged.enable_thinking.?);
}

// ---------------------------------------------------------------------------
// Schema v2: camelCase, semver version, context/compaction
// ---------------------------------------------------------------------------

test "parseObject accepts camelCase keys (schema v2)" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json =
        \\{"defaultModel":"ollama/llama3.1:8b","baseURL":"http://localhost:11434","useResponsesEndpoint":true,"enableThinking":true,"systemPrompt":"You are Nova.","bashClassifierUrl":"http://localhost:9999"}
    ;
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Provider.ollama, cfg.provider.?);
    try std.testing.expectEqualStrings("llama3.1:8b", cfg.model.?.id);
    try std.testing.expectEqualStrings("http://localhost:11434", cfg.base_url.?);
    try std.testing.expectEqual(true, cfg.use_responses_endpoint.?);
    try std.testing.expectEqual(true, cfg.enable_thinking.?);
    try std.testing.expectEqualStrings("You are Nova.", cfg.system_prompt.?);
    try std.testing.expectEqualStrings("http://localhost:9999", cfg.bash_classifier_url.?);
    try std.testing.expectEqual(@as(usize, 0), sink.items.len);
}

test "parseObject accepts legacy snake_case keys (backward compat)" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json =
        \\{"model":"openai/gpt-5.5","base_url":"https://api.openai.com","use_responses_endpoint":false,"enable_thinking":false,"system_prompt":"Legacy.","bash_classifier_url":"http://old:8080"}
    ;
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Provider.openai, cfg.provider.?);
    try std.testing.expectEqualStrings("gpt-5.5", cfg.model.?.id);
    try std.testing.expectEqualStrings("https://api.openai.com", cfg.base_url.?);
    try std.testing.expectEqual(false, cfg.use_responses_endpoint.?);
    try std.testing.expectEqual(false, cfg.enable_thinking.?);
    try std.testing.expectEqualStrings("Legacy.", cfg.system_prompt.?);
    try std.testing.expectEqualStrings("http://old:8080", cfg.bash_classifier_url.?);
}

test "parseObject: camelCase wins over snake_case when both present" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json =
        \\{"defaultModel":"ollama/llama3.1:8b","model":"openai/gpt-5.5","baseURL":"http://camel","base_url":"http://snake"}
    ;
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Provider.ollama, cfg.provider.?);
    try std.testing.expectEqualStrings("http://camel", cfg.base_url.?);
}

test "parseObject: semver string version" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{\"version\":\"2.1.0\"}", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("2.1.0", cfg.version.?);
}

test "parseObject: legacy integer version normalized to semver" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{\"version\":1}", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("1.0.0", cfg.version.?);
}

test "parseObject: context with compaction settings" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json =
        \\{"context":{"overrideContextWindow":32000,"maxOutputTokens":4096,"compaction":{"auto":false,"threshold":0.80,"bufferTokens":10000,"keepRecentTokens":5000}}}
    ;
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 32_000), cfg.context.override_context_window.?);
    try std.testing.expectEqual(@as(u32, 4_096), cfg.context.max_output_tokens.?);
    try std.testing.expectEqual(false, cfg.context.compaction.auto);
    try std.testing.expectApproxEqAbs(@as(f64, 0.80), cfg.context.compaction.threshold, 0.001);
    try std.testing.expectEqual(@as(u32, 10_000), cfg.context.compaction.buffer_tokens);
    try std.testing.expectEqual(@as(u32, 5_000), cfg.context.compaction.keep_recent_tokens);
}

test "parseObject: context defaults when absent" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{}", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(?u32, null), cfg.context.override_context_window);
    try std.testing.expectEqual(@as(?u32, null), cfg.context.max_output_tokens);
    try std.testing.expectEqual(true, cfg.context.compaction.auto);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), cfg.context.compaction.threshold, 0.001);
    try std.testing.expectEqual(@as(u32, 20_000), cfg.context.compaction.buffer_tokens);
    try std.testing.expectEqual(@as(u32, 8_000), cfg.context.compaction.keep_recent_tokens);
}

test "parseObject: compaction threshold clamped to valid range" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{\"context\":{\"compaction\":{\"threshold\":5.0}}}", &sink);
    defer cfg.deinit(gpa);
    // Out-of-range threshold keeps the default.
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), cfg.context.compaction.threshold, 0.001);
}

test "serialize writes camelCase keys and context section" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{
        .provider = .ollama,
        .model = .{ .id = try gpa.dupe(u8, "llama3.1:8b") },
        .use_responses_endpoint = true,
        .enable_thinking = true,
        .system_prompt = try gpa.dupe(u8, "Be helpful."),
        .context = .{
            .override_context_window = 32_000,
            .compaction = .{ .threshold = 0.80, .keep_recent_tokens = 5_000 },
        },
    };
    defer cfg.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, cfg);

    const text = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"defaultModel\": \"ollama/llama3.1:8b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"useResponsesEndpoint\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"enableThinking\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"systemPrompt\": \"Be helpful.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"context\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"overrideContextWindow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"compaction\"") != null);
}

test "serialize omits context section when all defaults" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{ .provider = .openai };
    defer cfg.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, cfg);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"context\"") == null);
}

test "serialize then parse roundtrips with camelCase and context" {
    const gpa = std.testing.allocator;
    var original: Config = .{
        .provider = .ollama,
        .base_url = try gpa.dupe(u8, "http://localhost:11434/v1"),
        .use_responses_endpoint = false,
        .enable_thinking = true,
        .model = .{ .id = try gpa.dupe(u8, "llama3.1:8b") },
        .context = .{
            .override_context_window = 16_000,
            .compaction = .{ .auto = false, .keep_recent_tokens = 4_000 },
        },
    };
    defer original.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, original);

    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var parsed = try parseFile(gpa, "<test>", buf.written(), &sink);
    defer parsed.deinit(gpa);
    var roundtrip = try mergeLayers(gpa, &.{parsed});
    defer roundtrip.deinit(gpa);

    try std.testing.expectEqual(Provider.ollama, roundtrip.provider.?);
    try std.testing.expectEqualStrings("llama3.1:8b", roundtrip.model.?.id);
    try std.testing.expectEqual(false, roundtrip.use_responses_endpoint.?);
    try std.testing.expectEqual(true, roundtrip.enable_thinking.?);
    try std.testing.expectEqual(@as(u32, 16_000), roundtrip.context.override_context_window.?);
    try std.testing.expectEqual(false, roundtrip.context.compaction.auto);
    try std.testing.expectEqual(@as(u32, 4_000), roundtrip.context.compaction.keep_recent_tokens);
}

test "parseSemverMajor extracts major from various formats" {
    try std.testing.expectEqual(@as(?u32, 2), parseSemverMajor("2.0.0"));
    try std.testing.expectEqual(@as(?u32, 1), parseSemverMajor("1.2.3"));
    try std.testing.expectEqual(@as(?u32, 10), parseSemverMajor("10.0.0"));
    try std.testing.expectEqual(@as(?u32, 3), parseSemverMajor("3"));
    try std.testing.expectEqual(@as(?u32, null), parseSemverMajor("abc"));
    try std.testing.expectEqual(@as(?u32, null), parseSemverMajor(""));
}

test "parseProviderConfig accepts baseURL (camelCase)" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"providers\":{\"ollama\":{\"baseURL\":\"http://custom:11434\"}}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), cfg.providers.len);
    switch (cfg.providers[0].base_url) {
        .custom => |url| try std.testing.expectEqualStrings("http://custom:11434", url),
        .default => return error.Unexpected,
    }
}

test "applyContextOverlay merges non-default values" {
    var target: ContextSettings = .{};
    const updates: ContextSettings = .{
        .override_context_window = 64_000,
        .compaction = .{ .threshold = 0.90 },
    };
    applyContextOverlay(&target, updates);
    try std.testing.expectEqual(@as(u32, 64_000), target.override_context_window.?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.90), target.compaction.threshold, 0.001);
    // Defaults preserved for fields not in updates.
    try std.testing.expectEqual(true, target.compaction.auto);
    try std.testing.expectEqual(@as(u32, 20_000), target.compaction.buffer_tokens);
}
