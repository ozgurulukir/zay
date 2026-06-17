//! The ExecutorService module: runs batches of ToolCalls and produces ToolResults.

const std = @import("std");

const ai = @import("ai.zig");
const tools = @import("tools.zig");

const assert = std.debug.assert;

/// The output of one ToolCall, carrying both the LLM channel (the terse
/// observation that flows into history) and the human channel (display
/// label/body for the TUI) in one record.
pub const ToolResult = struct {
    /// LLM channel — the id this result is responding to.
    call_id: []u8,
    /// LLM channel — the terse observation that flows into the assistant's
    /// next `tool` role message in history.
    content: []u8,
    /// Identity — the tool's name (e.g. "bash"). The TUI uses this to look
    /// up its display policy. Not strictly a channel — it's the same name
    /// the LM emitted.
    name: []u8,
    /// Human channel — the collapsed Display label.
    display_label: []u8,
    /// Human channel — label shown in place of `display_label` when expanded.
    display_expanded_label: ?[]u8,
    /// Human channel — the display body shown in the thread.
    display_body: []u8,
    /// Human channel — stderr text rendered in red below the body, or null.
    stderr: ?[]u8,
    /// Human channel — overrides body styling to red at draw time.
    failed: bool,

    pub fn deinit(self: *ToolResult, gpa: std.mem.Allocator) void {
        gpa.free(self.call_id);
        gpa.free(self.content);
        gpa.free(self.name);
        gpa.free(self.display_label);
        if (self.display_expanded_label) |label| gpa.free(label);
        gpa.free(self.display_body);
        if (self.stderr) |s| gpa.free(s);
        self.* = undefined;
    }
};

/// The narrow private callback interface ExecutorService uses to report
/// ToolCall lifecycle back to the agent. `on_finished` receives a const
/// pointer into the executor's already-allocated result slot — no
/// projection allocation.
pub const ToolCallObserver = struct {
    ptr: *anyopaque,
    on_started: *const fn (*anyopaque, ai.ToolCall) anyerror!void,
    on_finished: *const fn (*anyopaque, *const ToolResult) anyerror!void,

    pub const noop: ToolCallObserver = .{
        .ptr = undefined,
        .on_started = noopStarted,
        .on_finished = noopFinished,
    };

    pub fn noopStarted(_: *anyopaque, _: ai.ToolCall) anyerror!void {}
    pub fn noopFinished(_: *anyopaque, _: *const ToolResult) anyerror!void {}
};

pub const ExecutorService = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) ExecutorService {
        assert(cwd.len > 0);
        return .{ .gpa = gpa, .io = io, .cwd = cwd };
    }

    /// Run a batch of ToolCalls. For each call:
    ///   1. `observer.on_started(call)` fires.
    ///   2. The tool runs via the Tool registry.
    ///   3. A ToolResult is built with both channels.
    ///   4. `observer.on_finished(&result)` fires with a const pointer.
    /// Returns an owned slice. The agent moves the LLM-channel fields into
    /// history via `Agent.takeToolResults` and frees the rest.
    pub fn runAll(
        self: *ExecutorService,
        calls: []const ai.ToolCall,
        observer: ToolCallObserver,
    ) ![]ToolResult {
        const results = try self.gpa.alloc(ToolResult, calls.len);
        var initialized: usize = 0;
        errdefer {
            for (results[0..initialized]) |*r| r.deinit(self.gpa);
            self.gpa.free(results);
        }
        for (calls, 0..) |call, i| {
            try observer.on_started(observer.ptr, call);
            results[i] = try self.runOne(call);
            initialized = i + 1;
            try observer.on_finished(observer.ptr, &results[i]);
        }
        return results;
    }

    fn runOne(self: *ExecutorService, call: ai.ToolCall) !ToolResult {
        var output = tools.run(self.gpa, self.io, self.cwd, call.name, call.arguments) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return self.runFailure(call, err),
        };
        defer output.deinit(self.gpa);

        const call_id = try self.gpa.dupe(u8, call.call_id);
        errdefer self.gpa.free(call_id);
        const content = try formatLlmObservation(self.gpa, output);
        errdefer self.gpa.free(content);
        const name = try self.gpa.dupe(u8, call.name);
        errdefer self.gpa.free(name);
        var display = try makeDisplay(self.gpa, call.name, call.arguments);
        errdefer display.deinit(self.gpa);
        const display_body = try makeDisplayBody(self.gpa, output);
        errdefer self.gpa.free(display_body);
        const stderr = if (output.stderr.len > 0) try self.gpa.dupe(u8, output.stderr) else null;
        const failed = output.code != 0;
        return .{
            .call_id = call_id,
            .content = content,
            .name = name,
            .display_label = display.label,
            .display_expanded_label = display.expanded_label,
            .display_body = display_body,
            .stderr = stderr,
            .failed = failed,
        };
    }

    fn runFailure(self: *ExecutorService, call: ai.ToolCall, err: anyerror) !ToolResult {
        const call_id = try self.gpa.dupe(u8, call.call_id);
        errdefer self.gpa.free(call_id);
        const name = try self.gpa.dupe(u8, call.name);
        errdefer self.gpa.free(name);
        var display = try makeDisplay(self.gpa, call.name, call.arguments);
        errdefer display.deinit(self.gpa);
        const content = try std.fmt.allocPrint(self.gpa, "tool '{s}' failed to execute: {s}", .{ call.name, @errorName(err) });
        errdefer self.gpa.free(content);
        const display_body = try self.gpa.dupe(u8, content);
        return .{
            .call_id = call_id,
            .content = content,
            .name = name,
            .display_label = display.label,
            .display_expanded_label = display.expanded_label,
            .display_body = display_body,
            .stderr = null,
            .failed = true,
        };
    }
};

/// The LLM-facing observation: stdout if non-empty, else stderr if
/// non-empty, else the literal "empty". When both are non-empty (typical
/// for bash commands writing to both) concatenate so we don't drop signal.
fn formatLlmObservation(gpa: std.mem.Allocator, result: tools.Output) ![]u8 {
    if (result.observation) |observation| return observation.render(gpa);
    if (result.stdout.len > 0 and result.stderr.len > 0) {
        return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ result.stdout, result.stderr });
    }
    if (result.stdout.len > 0) return gpa.dupe(u8, result.stdout);
    if (result.stderr.len > 0) return gpa.dupe(u8, result.stderr);
    return gpa.dupe(u8, "empty");
}

/// Look up the tool in the registry and delegate to its display formatter.
/// Falls back to the tool name itself when unknown — shouldn't happen
/// outside test code, since callers source the name from a `ToolCall`
/// that the LM emitted.
fn makeDisplay(gpa: std.mem.Allocator, name: []const u8, args: []const u8) !tools.ToolDisplay {
    const tool = tools.lookup(name) orelse return .{ .label = try gpa.dupe(u8, name) };
    return tool.display(gpa, args);
}

/// The human-facing body. Each tool owns its own display: when it sets a
/// `display`, that is the body. Otherwise the body is the raw stdout, or a
/// sentinel when there is none. The executor passes through; it knows nothing
/// tool-specific.
fn makeDisplayBody(gpa: std.mem.Allocator, result: tools.Output) ![]u8 {
    if (result.display) |display| return gpa.dupe(u8, display);
    if (result.stdout.len == 0) {
        if (result.stderr.len > 0) return gpa.alloc(u8, 0);
        return gpa.dupe(u8, "no output");
    }
    return gpa.dupe(u8, result.stdout);
}

test "ExecutorService runs bash and returns both channels" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var executor = ExecutorService.init(gpa, std.testing.io, cwd);

    const calls = [_]ai.ToolCall{
        .{
            .call_id = try gpa.dupe(u8, "call_0"),
            .name = try gpa.dupe(u8, "bash"),
            .arguments = try gpa.dupe(u8, "{\"command\":\"printf hello\",\"reason\":\"Print hello\"}"),
        },
    };
    defer for (calls) |c| {
        gpa.free(c.call_id);
        gpa.free(c.name);
        gpa.free(c.arguments);
    };

    const results = try executor.runAll(&calls, ToolCallObserver.noop);
    defer {
        for (results) |*r| r.deinit(gpa);
        gpa.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("call_0", results[0].call_id);
    try std.testing.expectEqualStrings("hello", results[0].content);
    try std.testing.expectEqualStrings("Print hello", results[0].display_label);
    try std.testing.expectEqualStrings("printf hello", results[0].display_expanded_label.?);
    try std.testing.expect(!results[0].failed);
}

test "executor converts a tool execution error into a failed result" {
    const gpa = std.testing.allocator;
    var executor = ExecutorService.init(gpa, std.testing.io, "/tmp");
    const call: ai.ToolCall = .{
        .call_id = try gpa.dupe(u8, "call_x"),
        .name = try gpa.dupe(u8, "bash"),
        .arguments = try gpa.dupe(u8, "{\"command\":\"rg foo\",\"reason\":\"search\"}"),
    };
    defer {
        gpa.free(call.call_id);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runFailure(call, error.Unexpected);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    try std.testing.expectEqualStrings("call_x", result.call_id);
    try std.testing.expectEqualStrings("search", result.display_label);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "failed to execute") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Unexpected") != null);
}
