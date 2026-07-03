//! The meta-tools: `search_tools` and `execute_tool`.
//!
//! These are the only tools the model calls directly; everything else (bash and
//! every generated tool) is reached *through* `execute_tool`. Their execution is
//! not performed here — the `ExecutorService` intercepts both by name, because
//! the real logic needs the runtime `Toolbox`, which the `Tool.run` signature
//! deliberately does not expose. The `run` bodies below are unreachable
//! fallbacks. These records exist so the LanguageModel adapters can render the
//! two schemas and the TUI can render their display rows.

const std = @import("std");

const common = @import("common.zig");

pub const search_tools: common.Tool = .{
    .name = "search_tools",
    .description =
    \\Search the available tool box for a tool that fits what you are about to do. The query matches tool names and their purpose. Returns matching tools with the arguments they take; call one with execute_tool. If nothing fits, fall back to running bash through execute_tool.
    ,
    .keywords = &.{ "discover", "find tool", "capability", "list tools" },
    .schema = .{ .properties = &.{.{
        .name = "query",
        .kind = .string,
        .description = "What you want to do, or a keyword (e.g. \"edit file\", \"run tests\").",
        .required = true,
    }} },
    .run = runStub,
    .display = displaySearch,
};

pub const execute_tool: common.Tool = .{
    .name = "execute_tool",
    .description =
    \\Invoke a tool by name. `name` is the tool (for example "bash", or any tool returned by search_tools) and `args` is that tool's own argument object. Use this to run bash: {"name": "bash", "args": {"command": "...", "reason": "..."}}.
    ,
    .keywords = &.{ "invoke", "run tool", "call", "dispatch" },
    .schema = .{ .properties = &.{ .{
        .name = "name",
        .kind = .string,
        .description = "Name of the tool to invoke.",
        .required = true,
    }, .{
        .name = "args",
        .kind = .object,
        .description = "The invoked tool's own argument object.",
        .required = false,
    } } },
    .run = runStub,
    .display = displayExecute,
};

/// Never reached in normal flow — the executor handles both meta-tools before
/// the registry dispatch. Present so a stray direct call fails loudly rather
/// than silently doing nothing.
fn runStub(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    _ = io;
    _ = cwd;
    _ = arguments;
    return common.fail(gpa, "internal: meta-tool must be handled by the executor", 2);
}

fn displaySearch(gpa: std.mem.Allocator, args: []const u8) std.mem.Allocator.Error!common.ToolDisplay {
    const query = try common.extractStringField(gpa, args, "query", "search_tools");
    return .{ .label = query };
}

fn displayExecute(gpa: std.mem.Allocator, args: []const u8) std.mem.Allocator.Error!common.ToolDisplay {
    const name = try common.extractStringField(gpa, args, "name", "execute_tool");
    return .{ .label = name };
}
