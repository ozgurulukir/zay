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
//!
//! This file is the public facade: types live here, provider/model types in
//! provider.zig, MCP types in mcp.zig, and all parse/serialize/IO/merge logic
//! in parse.zig.

const std = @import("std");

const assert = std.debug.assert;

const provider_types = @import("provider.zig");
const mcp_types = @import("mcp.zig");
const parse_mod = @import("parse.zig");

// --- Provider & model re-exports ---

pub const Provider = provider_types.Provider;
pub const AdapterKind = provider_types.AdapterKind;
pub const Model = provider_types.Model;
pub const BaseUrl = provider_types.BaseUrl;
pub const ReasoningSetting = provider_types.ReasoningSetting;
pub const ProviderModel = provider_types.ProviderModel;
pub const ProviderConfig = provider_types.ProviderConfig;
pub const ModelSelectionRef = provider_types.ModelSelectionRef;
pub const ModelSelection = provider_types.ModelSelection;
pub const catalogueProviders = provider_types.catalogueProviders;
pub const allBuiltinLabels = provider_types.allBuiltinLabels;

// --- MCP re-exports ---

pub const McpHeader = mcp_types.McpHeader;
pub const McpServerConfig = mcp_types.McpServerConfig;
pub const cloneHeaders = mcp_types.cloneHeaders;
pub const freeHeaders = mcp_types.freeHeaders;
pub const mcpServerFromUrl = mcp_types.mcpServerFromUrl;
pub const expandMcpServer = mcp_types.expandMcpServer;

// --- Parse / serialize / IO re-exports ---

pub const load = parse_mod.load;
pub const syncModelSelectionFromLegacy = parse_mod.syncModelSelectionFromLegacy;
pub const writeGlobal = parse_mod.writeGlobal;
pub const readGlobal = parse_mod.readGlobal;
pub const mergeAndWriteGlobal = parse_mod.mergeAndWriteGlobal;
pub const readProject = parse_mod.readProject;
pub const writeProject = parse_mod.writeProject;
pub const mergeAndWriteProject = parse_mod.mergeAndWriteProject;
pub const projectConfigExists = parse_mod.projectConfigExists;
pub const globalConfigPath = parse_mod.globalConfigPath;

// --- Types owned by this file ---

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
            const major = parse_mod.parseSemverMajor(v) orelse {
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
