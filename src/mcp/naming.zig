//! Single source of truth for the `mcp__<server>__<tool>` wire-name
//! convention. The producer (`McpClient.addTool`), the dispatch parser
//! (`ExecutorService.runMcpTool`), and the schema resolver
//! (`executor_validation.resolveSchema`) all go through this module so the
//! convention cannot drift between writer and readers.
//!
//! Parsing splits at the FIRST `__` sequence, so server names containing a
//! single underscore (`codebase_memory_mcp`) parse exactly. The only
//! ambiguity is a `__` inside a server name — `validServerName` rejects
//! those at config load so they can never reach the wire.

const std = @import("std");

pub const prefix = "mcp__";
pub const separator = "__";

pub const ParsedName = struct {
    server: []const u8,
    tool: []const u8,
};

/// Split a full wire name into server and tool names, or null when the name
/// does not follow the convention (missing prefix/separator, empty tool).
pub fn parse(full_name: []const u8) ?ParsedName {
    if (!std.mem.startsWith(u8, full_name, prefix)) return null;
    const rest = full_name[prefix.len..];
    const sep = std.mem.indexOf(u8, rest, separator) orelse return null;
    const server_name = rest[0..sep];
    const tool_name = rest[sep + separator.len ..];
    if (server_name.len == 0 or tool_name.len == 0) return null;
    return .{ .server = server_name, .tool = tool_name };
}

/// Server names become part of the `mcp__<server>__<tool>` wire name, which
/// `parse` splits at the first `__`. A `__` inside the server name would make
/// that split ambiguous, so config load rejects such names (skipping the
/// server with a diagnostic); empty names are rejected for the same reason.
pub fn validServerName(name: []const u8) bool {
    if (name.len == 0) return false;
    return std.mem.indexOf(u8, name, separator) == null;
}

/// Build the full wire name from a server name and a tool name. Returns an
/// owned slice; the caller frees it.
pub fn toolFullName(gpa: std.mem.Allocator, server_name: []const u8, tool_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, prefix ++ "{s}" ++ separator ++ "{s}", .{ server_name, tool_name });
}

test "parse splits at the first separator and keeps underscore server names" {
    const parsed = parse("mcp__codebase_memory_mcp__search").?;
    try std.testing.expectEqualStrings("codebase_memory_mcp", parsed.server);
    try std.testing.expectEqualStrings("search", parsed.tool);
}

test "parse keeps the rest of the tool name when it contains a separator" {
    const parsed = parse("mcp__a__b__c").?;
    try std.testing.expectEqualStrings("a", parsed.server);
    try std.testing.expectEqualStrings("b__c", parsed.tool);
}

test "parse rejects malformed names" {
    try std.testing.expect(parse("mcp__server") == null); // no separator
    try std.testing.expect(parse("mcp__server__") == null); // empty tool
    try std.testing.expect(parse("mcp____tool") == null); // empty server
    try std.testing.expect(parse("bash") == null); // no prefix
}

test "validServerName rejects empty and separator-bearing names" {
    try std.testing.expect(validServerName("codebase-memory-mcp"));
    try std.testing.expect(validServerName("mock_server")); // single `_` is fine
    try std.testing.expect(!validServerName(""));
    try std.testing.expect(!validServerName("a__b")); // ambiguous on the wire
}
