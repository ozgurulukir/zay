//! Nova's resolved preferences record and its layered loader.
//! Four sources, field-merged, later overrides earlier:
//!   1. built-in defaults
//!   2. global  `<home>/.nova/config.json`
//!   3. project `<cwd>/.nova/config.json`
//!   4. env vars: OPENAI_BASE_URL, OPENAI_API_KEY, OPENAI_MODEL,
//!                NOVA_USE_RESPONSES_ENDPOINT, NOVA_ENABLE_THINKING
//!
//! `model` is an indivisible unit: supplying it at any layer replaces
//! lower layers' `model` whole, because `reasoning_effort` is meaningful
//! only relative to a specific model id.

const std = @import("std");
const ai = @import("ai.zig");

pub const Provider = enum {
    openai,
    openai_compatible,
    ollama,
    llama_cpp,
    openrouter,
    anthropic,

    pub fn fromString(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "openai")) return .openai;
        if (std.mem.eql(u8, s, "openai_compatible")) return .openai_compatible;
        if (std.mem.eql(u8, s, "ollama")) return .ollama;
        if (std.mem.eql(u8, s, "llama.cpp")) return .llama_cpp;
        if (std.mem.eql(u8, s, "openrouter")) return .openrouter;
        if (std.mem.eql(u8, s, "anthropic")) return .anthropic;
        return null;
    }

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .openai => "openai",
            .openai_compatible => "openai_compatible",
            .ollama => "ollama",
            .llama_cpp => "llama.cpp",
            .openrouter => "openrouter",
            .anthropic => "anthropic",
        };
    }

    /// Default base_url for this Provider. `null` means the user MUST
    /// supply one (e.g. raw `openai_compatible` and `anthropic`).
    pub fn defaultBaseUrl(self: Provider) ?[]const u8 {
        return switch (self) {
            .openai => "https://chatgpt.com/backend-api",
            .openai_compatible => null,
            .ollama => "http://localhost:11434/v1",
            .llama_cpp => "http://localhost:8080/v1",
            .openrouter => "https://openrouter.ai/api/v1",
            .anthropic => null,
        };
    }

    pub fn adapter(self: Provider) ?AdapterKind {
        return switch (self) {
            .openai => .codex_responses,
            .openai_compatible, .ollama, .llama_cpp, .openrouter => .openai_compatible,
            .anthropic => null,
        };
    }
};

pub const AdapterKind = enum {
    codex_responses,
    openai_responses,
    openai_compatible,
};

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

pub const Config = struct {
    provider: ?Provider = null,
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,
    model: ?Model = null,
    use_responses_endpoint: ?bool = null,
    enable_thinking: ?bool = null,
    system_prompt: ?[]u8 = null,

    pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
        if (self.base_url) |s| gpa.free(s);
        if (self.api_key) |s| gpa.free(s);
        if (self.model) |*m| m.deinit(gpa);
        if (self.system_prompt) |s| gpa.free(s);
        self.* = undefined;
    }

    pub fn clone(self: Config, gpa: std.mem.Allocator) !Config {
        var out: Config = .{
            .provider = self.provider,
            .use_responses_endpoint = self.use_responses_endpoint,
            .enable_thinking = self.enable_thinking,
        };
        errdefer out.deinit(gpa);
        if (self.base_url) |s| out.base_url = try gpa.dupe(u8, s);
        if (self.api_key) |s| out.api_key = try gpa.dupe(u8, s);
        if (self.model) |m| out.model = try m.clone(gpa);
        if (self.system_prompt) |s| out.system_prompt = try gpa.dupe(u8, s);
        return out;
    }

    /// Alias for `clone`, used by `nova.run` to hand the TUI an owned
    /// copy of the merged config that outlives `load_result`.
    pub fn cloneForTui(self: Config, gpa: std.mem.Allocator) !Config {
        return self.clone(gpa);
    }
};

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

fn mergeLayers(gpa: std.mem.Allocator, layers: []const Config) !Config {
    var out: Config = .{};
    errdefer out.deinit(gpa);
    for (layers) |layer| {
        if (layer.provider) |v| out.provider = v;
        if (layer.use_responses_endpoint) |v| out.use_responses_endpoint = v;
        if (layer.enable_thinking) |v| out.enable_thinking = v;
        if (layer.base_url) |s| {
            if (out.base_url) |old| gpa.free(old);
            out.base_url = try gpa.dupe(u8, s);
        }
        if (layer.api_key) |s| {
            if (out.api_key) |old| gpa.free(old);
            out.api_key = try gpa.dupe(u8, s);
        }
        if (layer.system_prompt) |s| {
            if (out.system_prompt) |old| gpa.free(old);
            out.system_prompt = try gpa.dupe(u8, s);
        }
        if (layer.model) |m| {
            if (out.model) |*old| old.deinit(gpa);
            out.model = try m.clone(gpa);
        }
    }
    return out;
}

fn loadGlobalFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !Config {
    const path = globalConfigPath(gpa, home_dir) catch return .{};
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

    if (stringField(value, "provider")) |s| {
        if (Provider.fromString(s)) |p| {
            out.provider = p;
        } else {
            try diagnostics.append(gpa, .{ .config_parse_error = .{
                .path = try gpa.dupe(u8, path),
                .reason = try std.fmt.allocPrint(gpa, "unknown provider '{s}'", .{s}),
            } });
        }
    }
    if (stringField(value, "base_url")) |s| {
        out.base_url = try gpa.dupe(u8, s);
    }
    if (boolField(value, "use_responses_endpoint")) |b| out.use_responses_endpoint = b;
    if (boolField(value, "enable_thinking")) |b| out.enable_thinking = b;
    if (stringField(value, "system_prompt")) |s| {
        out.system_prompt = try gpa.dupe(u8, s);
    }
    if (value.object.get("model")) |model_value| {
        if (model_value == .object) {
            if (stringField(model_value, "id")) |id| {
                var model: Model = .{ .id = try gpa.dupe(u8, id) };
                if (stringField(model_value, "reasoningEffort")) |effort| {
                    model.reasoning_effort = reasoningEffortFromString(effort);
                }
                out.model = model;
            }
        }
    }
    return out;
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
    if (env.get("NOVA_USE_RESPONSES_ENDPOINT")) |s| {
        out.use_responses_endpoint = parseBool(s);
    }
    if (env.get("NOVA_ENABLE_THINKING")) |s| {
        out.enable_thinking = parseBool(s);
    }
    if (env.get("OPENAI_MODEL")) |raw| {
        if (parseEnvModel(gpa, raw)) |parsed| {
            out.provider = parsed.provider;
            out.model = parsed.model;
        } else |_| {
            try diagnostics.append(gpa, .{ .bad_env_model = try gpa.dupe(u8, raw) });
        }
    }
    return out;
}

const EnvModel = struct {
    provider: Provider,
    model: Model,
};

fn parseEnvModel(gpa: std.mem.Allocator, raw: []const u8) !EnvModel {
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse return error.MissingSeparator;
    const provider_part = raw[0..slash];
    const model_part = raw[slash + 1 ..];
    if (model_part.len == 0) return error.MissingModel;
    if (std.mem.indexOfScalar(u8, model_part, '/') != null) return error.TooManySeparators;
    const provider = Provider.fromString(provider_part) orelse return error.UnknownProvider;
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

fn reasoningEffortFromString(s: []const u8) ?ai.ReasoningEffort {
    if (std.mem.eql(u8, s, "minimal")) return .minimal;
    if (std.mem.eql(u8, s, "low")) return .low;
    if (std.mem.eql(u8, s, "medium")) return .medium;
    if (std.mem.eql(u8, s, "high")) return .high;
    if (std.mem.eql(u8, s, "xhigh")) return .xhigh;
    return null;
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
    const path = try globalConfigPath(gpa, home_dir);
    defer gpa.free(path);

    const dirname = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.createDirPath(.cwd(), io, dirname);

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try serialize(&payload.writer, config);

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
    const path = try globalConfigPath(gpa, home_dir);
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
    if (updates.provider) |v| current.provider = v;
    if (updates.use_responses_endpoint) |v| current.use_responses_endpoint = v;
    if (updates.enable_thinking) |v| current.enable_thinking = v;
    if (updates.base_url) |s| {
        if (current.base_url) |old| gpa.free(old);
        current.base_url = try gpa.dupe(u8, s);
    }
    if (updates.model) |m| {
        if (current.model) |*old| old.deinit(gpa);
        current.model = try m.clone(gpa);
    }
    if (updates.system_prompt) |s| {
        if (current.system_prompt) |old| gpa.free(old);
        current.system_prompt = try gpa.dupe(u8, s);
    }
    try writeGlobal(gpa, io, home_dir, current);
}

fn serialize(writer: *std.Io.Writer, config: Config) !void {
    try writer.writeByte('{');
    var wrote_any = false;
    if (config.provider) |p| {
        try writeKey(writer, "provider", &wrote_any);
        try std.json.Stringify.value(p.label(), .{}, writer);
    }
    if (config.base_url) |s| {
        try writeKey(writer, "base_url", &wrote_any);
        try std.json.Stringify.value(s, .{}, writer);
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
        try writeKey(writer, "model", &wrote_any);
        try writer.writeAll("{\"id\":");
        try std.json.Stringify.value(m.id, .{}, writer);
        if (m.reasoning_effort) |effort| {
            try writer.writeAll(",\"reasoningEffort\":");
            try std.json.Stringify.value(effort.label(), .{}, writer);
        }
        try writer.writeByte('}');
    }
    if (config.system_prompt) |s| {
        try writeKey(writer, "system_prompt", &wrote_any);
        try std.json.Stringify.value(s, .{}, writer);
    }
    try writer.writeAll("}\n");
}

fn writeKey(writer: *std.Io.Writer, name: []const u8, wrote_any: *bool) !void {
    if (wrote_any.*) try writer.writeByte(',');
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    wrote_any.* = true;
}

fn globalConfigPath(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    if (home_dir.len == 0) return error.HomeNotSet;
    return std.fs.path.join(gpa, &.{ home_dir, ".nova", "config.json" });
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

test "Provider.fromString recognizes known vendor names" {
    try std.testing.expectEqual(Provider.openai, Provider.fromString("openai").?);
    try std.testing.expectEqual(Provider.openai_compatible, Provider.fromString("openai_compatible").?);
    try std.testing.expectEqual(Provider.ollama, Provider.fromString("ollama").?);
    try std.testing.expectEqual(Provider.llama_cpp, Provider.fromString("llama.cpp").?);
    try std.testing.expectEqual(Provider.openrouter, Provider.fromString("openrouter").?);
    try std.testing.expectEqual(Provider.anthropic, Provider.fromString("anthropic").?);
    try std.testing.expectEqual(@as(?Provider, null), Provider.fromString("mystery"));
}

test "Provider.adapter returns null for unimplemented anthropic" {
    try std.testing.expectEqual(AdapterKind.codex_responses, Provider.openai.adapter().?);
    try std.testing.expectEqual(AdapterKind.openai_compatible, Provider.ollama.adapter().?);
    try std.testing.expectEqual(@as(?AdapterKind, null), Provider.anthropic.adapter());
}

test "parseEnvModel: valid <provider>/<model>" {
    const gpa = std.testing.allocator;
    var parsed = try parseEnvModel(gpa, "openai/gpt-5.5");
    defer parsed.model.deinit(gpa);
    try std.testing.expectEqual(Provider.openai, parsed.provider);
    try std.testing.expectEqualStrings("gpt-5.5", parsed.model.id);
}

test "parseEnvModel: ollama/llama3.1:8b" {
    const gpa = std.testing.allocator;
    var parsed = try parseEnvModel(gpa, "ollama/llama3.1:8b");
    defer parsed.model.deinit(gpa);
    try std.testing.expectEqual(Provider.ollama, parsed.provider);
    try std.testing.expectEqualStrings("llama3.1:8b", parsed.model.id);
}

test "parseEnvModel: missing slash is error" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.MissingSeparator, parseEnvModel(gpa, "gpt-5.5"));
}

test "parseEnvModel: too many slashes is error" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.TooManySeparators, parseEnvModel(gpa, "openai_compatible/anthropic/claude-3.7-sonnet"));
}

test "parseEnvModel: unknown provider is error" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.UnknownProvider, parseEnvModel(gpa, "mystery/foo"));
}

test "parseEnvModel: anthropic parses (validity checked downstream)" {
    const gpa = std.testing.allocator;
    var parsed = try parseEnvModel(gpa, "anthropic/claude-3.7-sonnet");
    defer parsed.model.deinit(gpa);
    try std.testing.expectEqual(Provider.anthropic, parsed.provider);
}

test "parseObject: minimal config" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{\"provider\":\"ollama\",\"model\":{\"id\":\"llama3.1:8b\"}}", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Provider.ollama, cfg.provider.?);
    try std.testing.expectEqualStrings("llama3.1:8b", cfg.model.?.id);
    try std.testing.expectEqual(@as(usize, 0), sink.items.len);
}

test "parseObject: model with reasoningEffort" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{\"provider\":\"openai\",\"model\":{\"id\":\"gpt-5.5\",\"reasoningEffort\":\"high\"}}", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(ai.ReasoningEffort.high, cfg.model.?.reasoning_effort.?);
}

test "parseObject: unknown provider records diagnostic" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (sink.items) |*d| d.deinit(gpa);
        sink.deinit(gpa);
    }
    var cfg = try parseFile(gpa, "<test>", "{\"provider\":\"mystery\"}", &sink);
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
    var cfg: Config = .{
        .provider = .openai,
        .api_key = try gpa.dupe(u8, "sk-should-never-appear"),
        .model = .{ .id = try gpa.dupe(u8, "gpt-5.5"), .reasoning_effort = .medium },
    };
    defer cfg.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(&buf.writer, cfg);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "api_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "sk-should-never-appear") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"provider\":\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"id\":\"gpt-5.5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"reasoningEffort\":\"medium\"") != null);
}

test "serialize then parse roundtrips" {
    const gpa = std.testing.allocator;
    var original: Config = .{
        .provider = .ollama,
        .base_url = try gpa.dupe(u8, "http://localhost:11434/v1"),
        .use_responses_endpoint = false,
        .enable_thinking = true,
        .model = .{ .id = try gpa.dupe(u8, "llama3.1:8b") },
    };
    defer original.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(&buf.writer, original);

    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var roundtrip = try parseFile(gpa, "<test>", buf.written(), &sink);
    defer roundtrip.deinit(gpa);

    try std.testing.expectEqual(Provider.ollama, roundtrip.provider.?);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", roundtrip.base_url.?);
    try std.testing.expectEqual(false, roundtrip.use_responses_endpoint.?);
    try std.testing.expectEqual(true, roundtrip.enable_thinking.?);
    try std.testing.expectEqualStrings("llama3.1:8b", roundtrip.model.?.id);
}
