const std = @import("std");

const config_mod = @import("../config.zig");
const os = @import("../os.zig");
const runtime_mod = @import("../runtime.zig");

pub const ModelStatus = struct {
    provider: []const u8,
    model: []const u8,
};

pub fn modelStatus(runtime: ?*const runtime_mod.AgentRuntime, config: config_mod.Config) ?ModelStatus {
    if (runtime) |rt| {
        switch (rt.clientState()) {
            .disconnected => return null,
            .connected => |language_model| switch (language_model) {
                .codex_responses => |client| return .{
                    .provider = "openai",
                    .model = client.core_client.config.model,
                },
                .openai_responses => |client| return .{
                    .provider = providerLabel(config) orelse "openai",
                    .model = client.core_client.config.model,
                },
                .openai_compatible => |client| return .{
                    .provider = providerLabel(config) orelse "openai_compatible",
                    .model = client.config.model,
                },
                .none => unreachable,
            },
        }
    }

    const model = if (config.model) |m| m.id else return null;
    return .{
        .provider = providerLabel(config) orelse return null,
        .model = model,
    };
}

pub fn formatModelStatus(gpa: std.mem.Allocator, status: ModelStatus) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ status.provider, status.model });
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
    const provider = config.provider orelse return null;
    return provider.label();
}

test "model status formats as provider/model" {
    const gpa = std.testing.allocator;
    const text = try formatModelStatus(gpa, .{ .provider = "ollama", .model = "llama" });
    defer gpa.free(text);
    try std.testing.expectEqualStrings("ollama/llama", text);
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
