//! Plugin configuration types for Zay's layered config system.
//!
//! Mirrors the MCP server config pattern: a `PluginConfig` struct with
//! name, enabled flag, and plugin-specific settings stored as a JSON
//! string. Settings are opaque to the config system — the plugin's Lua
//! code parses its own settings via `plugin.get_config()`.
//!
//! Self-contained: no dependency on Provider, Config, or the parse
//! pipeline. Imported by `config.zig` (which re-exports the public
//! surface) and directly by the plugin manager.

const std = @import("std");

/// Configuration for a single Lua plugin.
pub const PluginConfig = struct {
    /// Plugin name (matches manifest name, e.g. "syntax_highlighter")
    name: []u8,
    /// Whether this plugin is active
    enabled: bool = true,
    /// Tracks whether the config layer explicitly supplied `enabled` (#447).
    /// Parse sets it only when the JSON key was present; the merge overlay
    /// applies `enabled` only when the flag is set, so a layer that re-lists
    /// a plugin without the key no longer resets it to the parse default
    /// (true) and can no longer clobber a lower layer's disabled plugin.
    /// Hand-built toggle-style updates set the flag explicitly.
    enabled_is_set: bool = false,
    /// Plugin-specific settings as a JSON object string (e.g. `{"theme":"dark"}`).
    /// Empty string means no settings. The plugin's Lua code parses this.
    settings: []u8 = "",

    pub fn deinit(self: *PluginConfig, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.settings.len > 0) gpa.free(self.settings);
        self.* = undefined;
    }

    pub fn clone(self: PluginConfig, gpa: std.mem.Allocator) !PluginConfig {
        var out: PluginConfig = .{
            .name = try gpa.dupe(u8, self.name),
            .enabled = self.enabled,
            .enabled_is_set = self.enabled_is_set,
        };
        // A failing settings dupe must not leak the already-duped name —
        // `PluginManager.syncPluginConfig` loops this over N entries, so the
        // partial-clone leak would multiply.
        errdefer gpa.free(out.name);
        out.settings = if (self.settings.len > 0) try gpa.dupe(u8, self.settings) else "";
        return out;
    }
};
