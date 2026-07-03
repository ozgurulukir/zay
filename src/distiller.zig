//! distiller.zig — the pure decisions behind procedural tool synthesis.
//!
//! After a turn, Nova shows a model the recent tool-call history and asks it to
//! distill any *recurring, worth-encoding* operation into a new generated tool
//! (see `prompts/distill.md`). The model's restraint is the whole point: most
//! turns it should propose nothing. Anything it does propose is validated here
//! and added to the `Toolbox`; the background orchestration (the worker thread,
//! the turn-boundary hooks, the reminder) lives in `agent.zig`, mirroring how
//! `compaction.zig` relates to the compactor.
//!
//! Everything here is a pure function of its inputs except `propose`, which
//! makes the one model call. `buildRequest` and `parseAndAdd` are pure and
//! tested directly.

const std = @import("std");

const logger = @import("logger");

const ai = @import("ai.zig");
const toolbox_mod = @import("toolbox.zig");

const assert = std.debug.assert;

/// Instruction sent to the distiller model. Combined with the tool-call history
/// and the existing tool names in `buildRequest`.
pub const distill_prompt = @embedFile("prompts/distill.md");

/// Restraint cap: never accept more than this many new tools from one analysis,
/// however many the model proposes.
pub const max_accepted_per_run: usize = 2;

/// Native tool names a generated tool may never shadow.
const reserved_names = [_][]const u8{ "bash", "search_tools", "execute_tool" };

/// Ask `client` for tool proposals given the recent tool-call log. Returns the
/// raw model text (caller owns it) for the worker thread to parse via
/// `parseAndAdd` — the model call happens off-thread, but all `Toolbox` mutation
/// stays on the worker thread. `existing_names` tell the model what already
/// exists so it doesn't re-propose it.
pub fn requestProposals(
    gpa: std.mem.Allocator,
    client: ai.LanguageModel,
    log_text: []const u8,
    existing_names: []const []const u8,
) ![]u8 {
    const request = try buildRequest(gpa, log_text, existing_names);
    const blocks = gpa.alloc(ai.ContentBlock, 1) catch |err| {
        gpa.free(request);
        return err;
    };
    blocks[0] = .{ .text = .{ .text = request } };
    var message: ai.ChatMessage = .{ .role = .user, .content = blocks };
    defer message.deinit(gpa);

    var turn = try client.prompt(&.{message}, ai.StreamObserver.noop);
    defer turn.deinit(gpa);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (turn.assistant.content) |block| {
        if (block == .text) try out.appendSlice(gpa, block.text.text);
    }
    return out.toOwnedSlice(gpa);
}

/// Build the distiller's user content: the instruction, the existing tool names
/// (so it doesn't re-propose them), and the recent tool-call history to mine.
/// Caller owns the result.
pub fn buildRequest(
    gpa: std.mem.Allocator,
    log_text: []const u8,
    existing_names: []const []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll(distill_prompt) catch return error.OutOfMemory;
    w.writeAll("\n\n<existing_tools>\n") catch return error.OutOfMemory;
    if (existing_names.len == 0) {
        w.writeAll("(none yet)\n") catch return error.OutOfMemory;
    } else for (existing_names) |name| {
        w.print("- {s}\n", .{name}) catch return error.OutOfMemory;
    }
    w.writeAll("</existing_tools>\n\n<recent_tool_calls>\n") catch return error.OutOfMemory;
    w.writeAll(log_text) catch return error.OutOfMemory;
    w.writeAll("\n</recent_tool_calls>") catch return error.OutOfMemory;
    return aw.toOwnedSlice() catch error.OutOfMemory;
}

/// Parse a model response into tool proposals, validate each, and add the
/// accepted ones to `box`. Returns the count added. Tolerant of prose or code
/// fences around the JSON. Invalid or duplicate proposals are skipped (logged),
/// never fatal.
pub fn parseAndAdd(
    gpa: std.mem.Allocator,
    box: *toolbox_mod.Toolbox,
    response: []const u8,
    existing_names: []const []const u8,
) !u32 {
    const json = extractJsonObject(response) orelse return 0;
    const parsed = std.json.parseFromSlice(Response, gpa, json, .{ .ignore_unknown_fields = true }) catch return 0;
    defer parsed.deinit();

    var added: u32 = 0;
    for (parsed.value.tools) |proposed| {
        if (added >= max_accepted_per_run) break;
        if (!accept(proposed, existing_names)) continue;

        const params = try gpa.alloc(toolbox_mod.Param, proposed.params.len);
        defer gpa.free(params);
        for (proposed.params, 0..) |p, i| params[i] = .{
            .name = p.name,
            .kind = toolbox_mod.kindFromString(p.kind),
            .description = p.description,
            .required = p.required,
        };
        box.add(.{
            .name = proposed.name,
            .description = proposed.description,
            .keywords = proposed.keywords,
            .params = params,
            .template = proposed.template,
        }) catch |err| {
            logger.log("distiller: add '{s}' failed: {s}", .{ proposed.name, @errorName(err) });
            continue;
        };
        logger.log("distiller: added tool '{s}'", .{proposed.name});
        added += 1;
    }
    return added;
}

/// Whether a proposed tool passes validation: a valid, non-reserved, not-already
/// existing identifier name, a non-empty template, and valid identifier param
/// names (they become shell variables).
fn accept(proposed: ProposedTool, existing_names: []const []const u8) bool {
    if (!isIdentifier(proposed.name)) return false;
    if (proposed.template.len == 0) return false;
    for (reserved_names) |r| if (std.mem.eql(u8, r, proposed.name)) return false;
    for (existing_names) |e| if (std.mem.eql(u8, e, proposed.name)) return false;
    for (proposed.params) |p| if (!isIdentifier(p.name)) return false;
    return true;
}

/// A C-style identifier: `[A-Za-z_][A-Za-z0-9_]*`. Keeps tool names dispatchable
/// and param names bindable as shell variables.
fn isIdentifier(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name, 0..) |c, i| {
        const ok = c == '_' or std.ascii.isAlphabetic(c) or (i > 0 and std.ascii.isDigit(c));
        if (!ok) return false;
    }
    return true;
}

/// Slice from the first `{` to the last `}` (inclusive), so a JSON object
/// wrapped in prose or ```json fences still parses. Null when there is no brace pair.
fn extractJsonObject(text: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, text, '{') orelse return null;
    const end = std.mem.lastIndexOfScalar(u8, text, '}') orelse return null;
    if (end < start) return null;
    return text[start .. end + 1];
}

const Response = struct {
    tools: []const ProposedTool = &.{},
};

const ProposedTool = struct {
    name: []const u8,
    description: []const u8 = "",
    keywords: []const []const u8 = &.{},
    params: []const ProposedParam = &.{},
    template: []const u8 = "",
};

const ProposedParam = struct {
    name: []const u8,
    kind: []const u8 = "string",
    description: []const u8 = "",
    required: bool = false,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testBox(gpa: std.mem.Allocator) !toolbox_mod.Toolbox {
    return .{
        .gpa = gpa,
        .io = std.testing.io,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .path = try std.fmt.allocPrint(gpa, ".zig-cache/distiller-test-{d}/tools.json", .{std.testing.random_seed}),
    };
}

test "buildRequest embeds prompt, existing names, and the log" {
    const gpa = std.testing.allocator;
    const req = try buildRequest(gpa, "bash {\"command\":\"grep -rn TODO\"}", &.{ "count_todos", "run_tests" });
    defer gpa.free(req);
    try std.testing.expect(std.mem.indexOf(u8, req, "count_todos") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "grep -rn TODO") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "<recent_tool_calls>") != null);
}

test "parseAndAdd accepts a valid tool wrapped in prose and fences" {
    const gpa = std.testing.allocator;
    var box = try testBox(gpa);
    defer box.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, box.path) catch {};

    const response =
        \\Sure, here's a useful tool:
        \\```json
        \\{"tools":[{"name":"count_todos","description":"Count TODOs","keywords":["todo","grep"],
        \\ "params":[{"name":"path","kind":"string","required":true}],
        \\ "template":"grep -rc TODO \"$path\""}]}
        \\```
    ;
    const added = try parseAndAdd(gpa, &box, response, &.{});
    try std.testing.expectEqual(@as(u32, 1), added);
    try std.testing.expect(box.find("count_todos") != null);
}

test "parseAndAdd rejects reserved, duplicate, and malformed proposals" {
    const gpa = std.testing.allocator;
    var box = try testBox(gpa);
    defer box.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, box.path) catch {};

    const response =
        \\{"tools":[
        \\ {"name":"bash","template":"echo hi"},
        \\ {"name":"already","template":"echo hi"},
        \\ {"name":"bad name","template":"echo hi"},
        \\ {"name":"empty_template","template":""},
        \\ {"name":"bad_param","template":"echo hi","params":[{"name":"has space"}]}
        \\]}
    ;
    const added = try parseAndAdd(gpa, &box, response, &.{"already"});
    try std.testing.expectEqual(@as(u32, 0), added);
}

test "parseAndAdd honours the acceptance cap" {
    const gpa = std.testing.allocator;
    var box = try testBox(gpa);
    defer box.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, box.path) catch {};

    const response =
        \\{"tools":[
        \\ {"name":"t1","template":"echo 1"},
        \\ {"name":"t2","template":"echo 2"},
        \\ {"name":"t3","template":"echo 3"}
        \\]}
    ;
    const added = try parseAndAdd(gpa, &box, response, &.{});
    try std.testing.expectEqual(@as(u32, max_accepted_per_run), added);
}

test "parseAndAdd tolerates a no-op response" {
    const gpa = std.testing.allocator;
    var box = try testBox(gpa);
    defer box.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, box.path) catch {};

    try std.testing.expectEqual(@as(u32, 0), try parseAndAdd(gpa, &box, "{\"tools\":[]}", &.{}));
    try std.testing.expectEqual(@as(u32, 0), try parseAndAdd(gpa, &box, "no json here", &.{}));
}

test "isIdentifier accepts snake_case and rejects the rest" {
    try std.testing.expect(isIdentifier("edit_file"));
    try std.testing.expect(isIdentifier("_x9"));
    try std.testing.expect(!isIdentifier("9leading"));
    try std.testing.expect(!isIdentifier("has space"));
    try std.testing.expect(!isIdentifier(""));
}
