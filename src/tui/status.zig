const std = @import("std");

const ai = @import("../ai.zig");
const config_mod = @import("../config/config.zig");
const os = @import("../os.zig");
const runtime_mod = @import("../runtime.zig");

pub const ModelStatus = struct {
    provider: []const u8,
    model: []const u8,
    /// Active reasoning effort label ("default", "medium", "high", …).
    /// Borrowed: from the live client's config or the model selection,
    /// both of which resolve to static @tagName memory.
    reasoning: []const u8 = "medium",
};

/// Resolve the active reasoning effort for display. Source priority:
/// 1. live client config (what's actually being sent on the wire)
/// 2. the model selection's configured reasoning
/// 3. "medium" (the runtime default)
pub fn modelStatus(runtime: ?*const runtime_mod.AgentRuntime, config: config_mod.Config) ?ModelStatus {
    if (runtime) |rt| {
        switch (rt.clientState()) {
            .disconnected => return null,
            .connected => |language_model| switch (language_model) {
                .codex_responses => |client| return .{
                    .provider = "openai",
                    .model = client.core_client.config.model,
                    .reasoning = effortLabel(if (client.core_client.config.reasoning) |r| r.effort else null),
                },
                .responses => |client| return .{
                    .provider = connectedProviderName(client.config, config, "openai"),
                    .model = client.config.model,
                    .reasoning = effortLabel(if (client.config.reasoning) |r| r.effort else null),
                },
                .openai_compatible => |client| return .{
                    .provider = connectedProviderName(client.config, config, "openai_compatible"),
                    .model = client.config.model,
                    .reasoning = effortLabel(if (client.config.reasoning) |r| r.effort else null),
                },
                // Only reachable from tests that wire the scripted adapter
                // into a runtime; label it loudly so it can never pass for a
                // wired provider.
                .scripted => |client| return .{
                    .provider = "scripted",
                    .model = client.model_label,
                    .reasoning = effortLabel(null),
                },
                .none => unreachable,
            },
        }
    }

    const model = if (config.model_selection) |ms| ms.model().id else if (config.model) |m| m.id else return null;
    const reasoning = if (config.model_selection) |ms|
        effortLabel(ms.model().reasoning.resolve())
    else
        "medium";
    return .{
        .provider = providerDisplayName(config) orelse return null,
        .model = model,
        .reasoning = reasoning,
    };
}

pub fn formatModelStatus(gpa: std.mem.Allocator, status: ModelStatus) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} · {s} [{s}]", .{ status.provider, status.model, status.reasoning });
}

/// Render an optional effort as its label; unset falls back to "medium".
fn effortLabel(effort: ?ai.ReasoningEffort) []const u8 {
    return if (effort) |e| e.label() else "medium";
}

pub fn formatCwdRelative(
    arena: std.mem.Allocator,
    cwd: []const u8,
    home_dir: []const u8,
) std.mem.Allocator.Error![]const u8 {
    std.debug.assert(cwd.len > 0);
    if (home_dir.len == 0) return cwd;
    if (cwd.len < home_dir.len) return cwd;

    const prefix = cwd[0..home_dir.len];
    const prefix_matches = switch (os.tag) {
        .windows => std.ascii.eqlIgnoreCase(prefix, home_dir),
        else => std.mem.eql(u8, prefix, home_dir),
    };
    if (!prefix_matches) return cwd;

    const tail = cwd[home_dir.len..];
    if (tail.len == 0) return "~";
    if (tail[0] != '/' and tail[0] != '\\') return cwd;

    std.debug.assert(tail.len >= 1);
    return std.fmt.allocPrint(arena, "~{s}", .{tail});
}

pub fn modifiedTime(io: std.Io, buffer: []u8, updated_at_ms: i64) []const u8 {
    if (updated_at_ms < 0) return "unknown time";
    if (buffer.len == 0) return "unknown time";
    const now_ms = std.Io.Clock.now(.real, io).toMilliseconds();
    const diff_ms = now_ms - updated_at_ms;
    if (diff_ms < 0) return "in the future";
    const seconds: i64 = @divTrunc(diff_ms, 1000);
    if (seconds < 60) return "just now";
    const minutes: i64 = @divTrunc(seconds, 60);
    if (minutes < 60) {
        return std.fmt.bufPrint(buffer, "{d}m ago", .{minutes}) catch "unknown time";
    }
    const hours: i64 = @divTrunc(minutes, 60);
    if (hours < 24) {
        return std.fmt.bufPrint(buffer, "{d}h ago", .{hours}) catch "unknown time";
    }
    const days: i64 = @divTrunc(hours, 24);
    if (days < 7) {
        return std.fmt.bufPrint(buffer, "{d}d ago", .{days}) catch "unknown time";
    }
    if (days < 28) {
        return std.fmt.bufPrint(buffer, "{d}w ago", .{@divTrunc(days, 7)}) catch "unknown time";
    }
    if (days < 365) {
        return std.fmt.bufPrint(buffer, "{d}mo ago", .{@divTrunc(days, 30)}) catch "unknown time";
    }
    return std.fmt.bufPrint(buffer, "{d}y ago", .{@divTrunc(days, 365)}) catch "unknown time";
}

/// Display name for a CONNECTED client. The client's recorded provider key
/// (written into its `ai.Config` at attach time) is authoritative over
/// `cached_config`, which lags the live connection after a session resume
/// (resume restores from the session DB, not cached_config). An empty key
/// means attach recorded none, so fall back to the config-derived name.
fn connectedProviderName(
    client_config: ai.Config,
    config: config_mod.Config,
    fallback: []const u8,
) []const u8 {
    if (client_config.provider_name.len > 0) return client_config.provider_name;
    return providerDisplayName(config) orelse fallback;
}
fn providerLabel(config: config_mod.Config) ?[]const u8 {
    if (config.model_selection) |ms| return ms.provider().label();
    // After restart model_selection is null (api_key is never serialized);
    // fall back to the legacy provider field populated by parseObject.
    if (config.providerFromName()) |p| return p.label();
    return null;
}

/// Returns the config-derived display name (used when no client is
/// connected). Prefers the serialized model_selection.provider_name, falls
/// back to the dynamic provider name, then the legacy provider_name
/// (populated from the "defaultModel" field), then the builtin label. When a
/// client IS connected, connectedProviderName uses the client's recorded
/// provider key instead, authoritative over cached_config.
fn providerDisplayName(config: config_mod.Config) ?[]const u8 {
    if (config.model_selection) |ms| {
        if (ms.provider() == .openai_compatible and ms.providerName().len > 0) return ms.providerName();
        return ms.provider().label();
    }
    if (config.dynamic_provider_name) |name| return name;
    // After restart model_selection is null; the legacy provider_name
    // IS populated from the "defaultModel" config field (e.g. "stepfun-ai").
    if (config.provider_name) |name| {
        if ((config.providerFromName() orelse .openai_compatible) == .openai_compatible and name.len > 0) return name;
    }
    return providerLabel(config);
}

test "model status formats as provider · model [effort]" {
    const gpa = std.testing.allocator;
    const text = try formatModelStatus(gpa, .{ .provider = "ollama", .model = "llama" });
    defer gpa.free(text);
    try std.testing.expectEqualStrings("ollama · llama [medium]", text);
}

test "model status renders a non-default reasoning effort" {
    const gpa = std.testing.allocator;
    const text = try formatModelStatus(gpa, .{ .provider = "ollama", .model = "llama3.1:8b", .reasoning = "high" });
    defer gpa.free(text);
    try std.testing.expectEqualStrings("ollama · llama3.1:8b [high]", text);
}

test "model status prefers selected provider over stale dynamic display name" {
    const config: config_mod.Config = .{
        .dynamic_provider_name = @constCast("provider-a"),
        .model_selection = .{ .custom = .{
            .provider_name = @constCast("provider-b"),
            .base_url = @constCast("https://provider-b.example/v1"),
            .api_key = @constCast(""),
            .model = .{ .id = @constCast("model-x") },
        } },
    };
    const status = modelStatus(null, config).?;
    try std.testing.expectEqualStrings("provider-b", status.provider);
    try std.testing.expectEqualStrings("model-x", status.model);
}

test "model status prefers selected builtin over stale dynamic display name" {
    const config: config_mod.Config = .{
        .dynamic_provider_name = @constCast("provider-a"),
        .model_selection = .{ .builtin = .{
            .provider = .ollama,
            .provider_name = @constCast("ollama"),
            .model = .{ .id = @constCast("model-x") },
        } },
    };
    const status = modelStatus(null, config).?;
    try std.testing.expectEqualStrings("ollama", status.provider);
    try std.testing.expectEqualStrings("model-x", status.model);
}

test "model status connected runtime reports its actual provider over stale cached_config after resume" {
    // Regression: after /resume the runtime's client is attached to the
    // session's own provider (restored from the session DB), but cached_config
    // still carries the pre-resume provider. The connected modelStatus must
    // trust the client's recorded provider key, not the stale cached_config.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const home_abs = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_abs);

    var runtime: runtime_mod.AgentRuntime = undefined;
    try runtime.initNew(.{
        .gpa = gpa,
        .io = std.testing.io,
        .cwd = home_abs,
        .session_dir = home_abs,
        .home_dir = home_abs,
        .base_system_prompt = "test system prompt",
        .config = .{
            .model_selection = .{ .builtin = .{
                .provider = .ollama,
                .provider_name = @constCast("ollama"),
                .model = .{ .id = @constCast("init-model") },
            } },
        },
        .diagnostics = &.{},
    });
    defer runtime.deinit();

    // Simulate resume restoring a session that had switched to a different
    // provider: re-attach records "green-provider" on the live client while
    // cached_config stays on the old one.
    try runtime.attachOpenAiCompatibleClient(
        "green-provider",
        "https://green.example/v1",
        "test-key",
        "green-model",
        .medium,
        &.{},
    );

    const stale_config: config_mod.Config = .{
        .model_selection = .{ .custom = .{
            .provider_name = @constCast("old-provider"),
            .base_url = @constCast("https://old.example/v1"),
            .api_key = @constCast(""),
            .model = .{ .id = @constCast("old-model") },
        } },
    };
    const status = modelStatus(&runtime, stale_config).?;
    // The live client's provider is authoritative over stale cached_config.
    try std.testing.expectEqualStrings("green-provider", status.provider);
    try std.testing.expectEqualStrings("green-model", status.model);
}

test "connected provider name preserves adapter fallback labels" {
    const client_config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "model",
    };
    const config: config_mod.Config = .{};

    try std.testing.expectEqualStrings("openai", connectedProviderName(client_config, config, "openai"));
    try std.testing.expectEqualStrings("openai_compatible", connectedProviderName(client_config, config, "openai_compatible"));
}

test "effortLabel defaults unset to medium" {
    try std.testing.expectEqualStrings("medium", effortLabel(null));
    try std.testing.expectEqualStrings("high", effortLabel(.high));
    try std.testing.expectEqualStrings("none", effortLabel(.none));
}

test "modifiedTime buckets" {
    const io = std.testing.io;
    var buf: [32]u8 = undefined;
    const now = std.Io.Clock.now(.real, io).toMilliseconds();
    const sec_ms: i64 = 1000;
    const min_ms: i64 = 60 * sec_ms;
    const hour_ms: i64 = 60 * min_ms;
    const day_ms: i64 = 24 * hour_ms;
    try std.testing.expectEqualStrings("just now", modifiedTime(io, &buf, now - 30 * sec_ms));
    try std.testing.expectEqualStrings("5m ago", modifiedTime(io, &buf, now - 5 * min_ms));
    try std.testing.expectEqualStrings("3h ago", modifiedTime(io, &buf, now - 3 * hour_ms));
    try std.testing.expectEqualStrings("3d ago", modifiedTime(io, &buf, now - 3 * day_ms));
    try std.testing.expectEqualStrings("2w ago", modifiedTime(io, &buf, now - 14 * day_ms));
    try std.testing.expectEqualStrings("3mo ago", modifiedTime(io, &buf, now - 90 * day_ms));
    try std.testing.expectEqualStrings("2y ago", modifiedTime(io, &buf, now - 730 * day_ms));
}
