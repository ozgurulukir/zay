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
                .openai_responses => |client| return .{
                    .provider = providerLabel(config) orelse "openai",
                    .model = client.core_client.config.model,
                    .reasoning = effortLabel(if (client.core_client.config.reasoning) |r| r.effort else null),
                },
                .openai_compatible => |client| return .{
                    .provider = providerDisplayName(config) orelse "openai_compatible",
                    .model = client.config.model,
                    .reasoning = effortLabel(if (client.config.reasoning) |r| r.effort else null),
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

fn providerLabel(config: config_mod.Config) ?[]const u8 {
    if (config.model_selection) |ms| return ms.provider().label();
    // After restart model_selection is null (api_key is never serialized);
    // fall back to the legacy provider field populated by parseObject.
    if (config.providerFromName()) |p| return p.label();
    return null;
}

/// Returns the display name for the status bar. Prefers the dynamic
/// provider name (e.g. "StepFun") when set; falls back to the serialized
/// model_selection.provider_name (survives session resume, where the
/// runtime-only dynamic_provider_name is null), then the legacy
/// provider_name (populated from the "defaultModel" field), then the
/// builtin label.
fn providerDisplayName(config: config_mod.Config) ?[]const u8 {
    if (config.dynamic_provider_name) |name| return name;
    if (config.model_selection) |ms| {
        if (ms.provider() == .openai_compatible and ms.providerName().len > 0) return ms.providerName();
    }
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
