const std = @import("std");

const codex = @import("../codex.zig");
const config_mod = @import("../config.zig");

pub fn detectCodexSignIn(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) bool {
    if (home_dir.len == 0) return false;
    var credentials = (codex.load(gpa, io, home_dir) catch null) orelse return false;
    credentials.deinit(gpa);
    return true;
}

pub fn compatibleProviderFromBaseUrl(base_url: []const u8) config_mod.Provider {
    std.debug.assert(base_url.len > 0);
    if (std.mem.indexOf(u8, base_url, "localhost:11434") != null) return .ollama;
    if (std.mem.indexOf(u8, base_url, "127.0.0.1:11434") != null) return .ollama;
    if (std.mem.indexOf(u8, base_url, "localhost:8080") != null) return .llama_cpp;
    if (std.mem.indexOf(u8, base_url, "127.0.0.1:8080") != null) return .llama_cpp;
    return .openai_compatible;
}

pub fn hasOpenAICompatibleCredentials(config: config_mod.Config) bool {
    const base_url = config.base_url orelse return false;
    const api_key = config.api_key orelse return false;
    if (base_url.len == 0) return false;
    if (api_key.len == 0) return false;
    return true;
}

test "compatible provider is inferred from base url" {
    try std.testing.expectEqual(config_mod.Provider.ollama, compatibleProviderFromBaseUrl("http://localhost:11434/v1"));
    try std.testing.expectEqual(config_mod.Provider.ollama, compatibleProviderFromBaseUrl("http://127.0.0.1:11434/v1"));
    try std.testing.expectEqual(config_mod.Provider.llama_cpp, compatibleProviderFromBaseUrl("http://localhost:8080/v1"));
    try std.testing.expectEqual(config_mod.Provider.openai_compatible, compatibleProviderFromBaseUrl("https://example.com/v1"));
}
