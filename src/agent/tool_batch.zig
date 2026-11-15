//! Tool-batch seam, extracted from agent.zig (issue #367 slice 7). Hand the
//! LLM's tool_calls to the ExecutorService, bridge its ToolCallObserver
//! callbacks into the agent's Event stream, and move the LLM channel of each
//! ToolResult into history.
//!
//! Spoke pattern (runtime/connection.zig, mcp/wire.zig): free functions over
//! `*Agent`; all state stays on `Agent` — this file imports agent.zig only
//! for the `Agent` type. Mutual import terminates at the type level
//! (executor.zig already imports agent.zig for rerootFromRequester).
//!
//! Invariants that live here:
//! - tool_index alignment: `ExecutorBridge` tracks the batch position so the
//!   `tool_call_finished` events line up with the tool_indexes the TUI saw
//!   during deltas (`StreamContext.toolDeltaSeen` synthesises a tool_delta
//!   for calls some servers emit in one shot).
//! - results ownership: `Agent.takeToolResults` owns cleanup for a partial
//!   persistence failure and marks every moved result undefined on success;
//!   `runToolBatch` must not add an errdefer over `results` (listener errors
//!   arrive after the move and would deinitialize already-moved fields).

const std = @import("std");

const agent_mod = @import("../agent.zig");
const ai = @import("../ai.zig");
const executor_mod = @import("../executor.zig");
const session_mod = @import("../session.zig");
const skill_mod = @import("../skill.zig");
const tools = @import("../tools.zig");
const stream_context_mod = @import("stream_context.zig");

const Agent = agent_mod.Agent;
const StreamContext = stream_context_mod.StreamContext;

/// Build the ExecutorService for a tool batch. Called only from the
/// worker-thread batch path (`runToolBatch`): `effectiveCwd()` briefly
/// takes the workspace scope's mutex, which is fine on the worker but would contend
/// with the UI-thread lock users if this were constructed from the main
/// thread. Every field is either a direct Agent mirror or derived exactly
/// as the batch path needs — `toolExecutor bindings mirror the Agent
/// fields they read` and the runtime parity test guard that wiring.
pub fn toolExecutor(self: *Agent, turn_allocator: std.mem.Allocator) executor_mod.ExecutorService {
    return executor_mod.ExecutorService.init(.{
        .gpa = self.gpa,
        .scratch_allocator = turn_allocator,
        .io = self.io,
        .cwd = self.effectiveCwd(),
        .contained = self.contained,
        .bash_classifier_url = self.bash_classifier_url,
        .background = if (self.background_manager) |manager|
            .{ .manager = manager, .owner_generation = self.lane_generation }
        else
            null,
        .mcp_manager = self.mcp_manager,
        .tool_registry = self.tool_registry,
        .tool_output_cap_bytes = self.compaction_settings.tool_output_cap_bytes,
        .plugin_manager = self.plugin_manager,
        .lane_bridge = self.lane_bridge,
        .lane_requester = self,
        .skills = self.skills,
        .database_server_url = self.database_server_url,
        .database_auth_token = self.database_auth_token,
        .session_backend = if (self.context_manager.session_writer) |sw| &sw.manager.backend else null,
        .session_id = if (self.context_manager.session_writer) |sw| sw.session.id.slice() else null,
        .session_writer = if (self.context_manager.session_writer) |sw| sw else null,
        .cancel_requested = self.cancel_requested,
        .result_cache = &self.result_cache,
    });
}

/// Hand the batch of tool_calls to the ExecutorService, bridge its
/// ToolCallObserver callbacks into the agent's Event stream, and move
/// the LLM-channel of each ToolResult into history.
pub fn runToolBatch(
    comptime L: type,
    self: *Agent,
    tool_calls: []const ai.ToolCall,
    stream_context: *const StreamContext(L),
    listener: L,
    turn_allocator: std.mem.Allocator,
) !bool {
    var bridge: ExecutorBridge(L) = .{
        .agent = self,
        .listener = listener,
        .stream_context = stream_context,
    };
    var executor = toolExecutor(self, turn_allocator);
    const results = executor.runAll(tool_calls, bridge.observer()) catch |err| {
        if (err == error.Canceled) {
            if (self.cancel_requested) |flag| {
                if (flag.load(.acquire)) return error.TurnCancelled;
            }
        }
        return err;
    };
    defer self.gpa.free(results);
    var end_turn = false;
    for (results) |result| {
        if (result.end_turn) {
            end_turn = true;
            break;
        }
    }
    // `takeToolResults` owns cleanup for a partial persistence failure and
    // marks every moved result undefined on success. Do not add an
    // errdefer over `results` here: listener errors arrive after the move
    // and would otherwise deinitialize already-moved fields.
    try agent_mod.takeToolResults(self, results);
    snapshotAfterBatch(self);
    try listener.emit(.tool_batch_finished);
    return end_turn;
}

/// Delegate to the extracted git-shadow snapshotter (agent/snapshotter.zig).
pub fn snapshotAfterBatch(self: *Agent) void {
    if (self.snapshotter == null) self.snapshotter = .{ .gpa = self.gpa, .io = self.io };
    self.snapshotter.?.afterBatch(self.cwd, self.context_manager.session_writer);
}

/// Delegate to the extracted stream-context emitter
/// (agent/stream_context.zig); the allocator is the only Agent state
/// it needs.
pub fn emitToolDelta(
    comptime L: type,
    self: *Agent,
    listener: L,
    tool_index: u32,
    name: []const u8,
    arguments: []const u8,
) !void {
    return stream_context_mod.emitToolDelta(L, self.gpa, listener, tool_index, name, arguments);
}

pub fn emitToolCallFinished(
    comptime L: type,
    self: *Agent,
    listener: L,
    tool_index: u32,
    call_id: []const u8,
    name: []const u8,
    display_label: []const u8,
    display_expanded_label: ?[]const u8,
    display_body: []const u8,
    display_kind: tools.DisplayKind,
    stderr: ?[]const u8,
    failed: bool,
) !void {
    var transferred = false;
    const owned_id = try self.gpa.dupe(u8, call_id);
    errdefer if (!transferred) self.gpa.free(owned_id);
    const owned_name = try self.gpa.dupe(u8, name);
    errdefer if (!transferred) self.gpa.free(owned_name);
    const owned_label = try self.gpa.dupe(u8, display_label);
    errdefer if (!transferred) self.gpa.free(owned_label);
    const owned_expanded_label: ?[]u8 = if (display_expanded_label) |label|
        try self.gpa.dupe(u8, label)
    else
        null;
    errdefer if (!transferred) {
        if (owned_expanded_label) |label| self.gpa.free(label);
    };
    const owned_body = try self.gpa.dupe(u8, display_body);
    errdefer if (!transferred) self.gpa.free(owned_body);
    const owned_stderr: ?[]u8 = if (stderr) |s|
        try self.gpa.dupe(u8, s)
    else
        null;
    errdefer if (!transferred) {
        if (owned_stderr) |s| self.gpa.free(s);
    };

    // The listener takes ownership of the event and its owned fields; on error,
    // postAgentEvent deinitializes the event. Disarm local cleanup before emit.
    transferred = true;
    try listener.emit(.{
        .tool_call_finished = .{
            .index = tool_index,
            .call_id = owned_id,
            .name = owned_name,
            .display_label = owned_label,
            .display_expanded_label = owned_expanded_label,
            .display_body = owned_body,
            .display_kind = display_kind,
            .stderr = owned_stderr,
            .failed = failed,
        },
    });
}

/// Bridges ExecutorService's `ToolCallObserver` callbacks into the
/// agent's Event stream. Tracks tool_index across the batch so the
/// events line up with the tool_indexes the TUI saw during deltas.
fn ExecutorBridge(comptime L: type) type {
    return struct {
        agent: *Agent,
        listener: L,
        stream_context: *const StreamContext(L),
        tool_index: u32 = 0,

        fn onStarted(ctx: *@This(), call: ai.ToolCall) anyerror!void {
            // Synthesise a tool_delta for the TUI if the LM did not stream
            // one for this tool_call (some servers emit the whole call in
            // one shot without intermediate deltas).
            if (!ctx.stream_context.toolDeltaSeen(ctx.tool_index)) {
                try emitToolDelta(L, ctx.agent, ctx.listener, ctx.tool_index, call.name, call.arguments);
                try ctx.listener.emit(.delta_end);
            }
            // Notify plugins at the tool-call boundary — safe because the
            // plugin's own handler has not been entered yet on this thread.
            if (ctx.agent.plugin_manager) |pm| pm.emitEvent(.{
                .tool_call_started = .{ .name = call.name, .call_id = call.call_id.slice() },
            });
        }

        fn onFinished(ctx: *@This(), result: *const executor_mod.ToolResult) anyerror!void {
            // Notify plugins that the tool call completed.
            if (ctx.agent.plugin_manager) |pm| pm.emitEvent(.{
                .tool_call_finished = .{
                    .name = result.name,
                    .call_id = result.call_id.slice(),
                    .success = !result.failed,
                },
            });
            try emitToolCallFinished(
                L,
                ctx.agent,
                ctx.listener,
                ctx.tool_index,
                result.call_id.slice(),
                result.name,
                result.display_label,
                result.display_expanded_label,
                result.display_body,
                result.display_kind,
                result.stderr,
                result.failed,
            );
            ctx.tool_index += 1;
        }

        fn approveUnsafeBash(ctx: *@This(), call: ai.ToolCall, command: []const u8) anyerror!bool {
            _ = call;
            const approval = ctx.agent.bash_approval orelse return true;
            return approval.request(approval.ptr, command);
        }

        /// Build the executor's `ToolCallObserver` for this bridge. The
        /// observer's ctx is `*@This()` (the bridge itself), and the
        /// callbacks receive it typed — no `@ptrCast` at the seam.
        fn observer(self: *@This()) executor_mod.ToolCallObserver(@This()) {
            return .{
                .ctx = self,
                .on_started = onStarted,
                .on_finished = onFinished,
                .approve_unsafe_bash = approveUnsafeBash,
            };
        }
    };
}

/// InitOptions field name → Agent field path for every `toolExecutor`
/// binding taken straight from an Agent field. Derived bindings (cwd via
/// `effectiveCwd`, scratch_allocator from the turn, the session_writer
/// triple, the null background path, lane_requester = the Agent itself,
/// result_cache = an address-of) are covered by the runtime parity test
/// below — it exercises `background_manager == null` only, so a live
/// manager's `owner_generation` wiring is not asserted there. The record
/// splits along where ExecutorService stores the value: top-level fields
/// versus `ctx` (tools.ToolContext).
const tool_executor_service_bindings = .{
    .gpa = "gpa",
    .io = "io",
    .contained = "contained",
    .tool_registry = "tool_registry",
    .tool_output_cap_bytes = "compaction_settings.tool_output_cap_bytes",
};
const tool_executor_ctx_bindings = .{
    .bash_classifier_url = "bash_classifier_url",
    .mcp_manager = "mcp_manager",
    .plugin_manager = "plugin_manager",
    .lane_bridge = "lane_bridge",
    .skills = "skills",
    .database_server_url = "database_server_url",
    .database_auth_token = "database_auth_token",
    .cancel_requested = "cancel_requested",
};

/// Resolve a dotted Agent field path ("compaction_settings.tool_output_cap_bytes")
/// to its field type, for the comptime binding-parity test.
fn agentFieldTypeAtPath(comptime T: type, comptime path: []const u8) type {
    comptime {
        @setEvalBranchQuota(10_000);
        const head_end = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
        var found: ?type = null;
        for (std.meta.fields(T)) |field| {
            if (std.mem.eql(u8, field.name, path[0..head_end])) {
                found = field.type;
                break;
            }
        }
        if (head_end == path.len) return found.?;
        return agentFieldTypeAtPath(found.?, path[head_end + 1 ..]);
    }
}

/// Resolve a dotted Agent field path to its runtime value. Accepts the Agent
/// by pointer or value; `@field` auto-dereferences either way.
fn agentFieldValueAtPath(obj: anytype, comptime path: []const u8) agentFieldTypeAtPath(
    switch (@typeInfo(@TypeOf(obj))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(obj),
    },
    path,
) {
    if (comptime std.mem.indexOfScalar(u8, path, '.')) |dot| {
        return agentFieldValueAtPath(@field(obj, path[0..dot]), path[dot + 1 ..]);
    }
    return @field(obj, path);
}

test "toolExecutor bindings mirror the Agent fields they read" {
    // Compile-time parity: every binding-record entry must name an
    // InitOptions field and an Agent field path of the same type, so the
    // hand-built literal and the Agent fields it reads cannot drift apart.
    // No runtime assertions — compiling IS the assertion.
    inline for (.{ tool_executor_service_bindings, tool_executor_ctx_bindings }) |bindings| {
        inline for (std.meta.fields(@TypeOf(bindings))) |binding| {
            const path = @field(bindings, binding.name);
            const option_type = comptime blk: {
                for (std.meta.fields(executor_mod.ExecutorService.InitOptions)) |option_field| {
                    if (std.mem.eql(u8, option_field.name, binding.name)) {
                        break :blk option_field.type;
                    }
                }
                @compileError("toolExecutor binding." ++ binding.name ++ " is not an InitOptions field");
            };
            if (option_type != agentFieldTypeAtPath(Agent, path)) {
                @compileError("Agent." ++ path ++
                    " type diverged from InitOptions." ++ binding.name);
            }
        }
    }
}

test "toolExecutor projected fields match the hand-built InitOptions wiring" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".config/zay");
    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var writer: session_mod.SessionWriter = undefined;
    try session_mod.SessionWriter.initDefault(&writer, gpa, std.testing.io, home_dir, "/tmp");
    defer writer.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.attachSessionWriter(&writer);
    agent.contained = true;
    agent.setWorkspace("/tmp");
    agent.bash_classifier_url = try gpa.dupe(u8, "http://127.0.0.1:9");
    agent.database_server_url = try gpa.dupe(u8, "http://127.0.0.1:10");
    agent.database_auth_token = try gpa.dupe(u8, "token");
    agent.compaction_settings.tool_output_cap_bytes = 4096;
    agent.lane_generation = 7;
    const fixture: skill_mod.Skill = .{
        .name = @constCast("how"),
        .description = @constCast("Test"),
        .path = @constCast("/missing/SKILL.md"),
        .base_dir = @constCast("/missing"),
        .body = @constCast("Parity"),
    };
    agent.skills = &.{fixture};
    var cancel_flag: std.atomic.Value(bool) = .init(false);
    agent.cancel_requested = &cancel_flag;

    const options = toolExecutor(&agent, gpa);

    // Derived bindings: the turn scratch allocator, the workspace-projected
    // cwd, and the session_writer triple.
    try std.testing.expectEqual(@as(std.mem.Allocator, gpa), options.scratch_allocator);
    try std.testing.expectEqualStrings(agent.effectiveCwd(), options.cwd);
    const sw = agent.context_manager.session_writer.?;
    try std.testing.expectEqual(&sw.manager.backend, options.ctx.session_backend.?);
    try std.testing.expectEqualStrings(sw.session.id.slice(), options.ctx.session_id.?);
    try std.testing.expectEqual(sw, options.session_writer.?);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&agent)), options.ctx.lane_requester);
    try std.testing.expect(agent.background_manager == null and options.ctx.background_manager == null);
    try std.testing.expectEqual(&agent.result_cache, options.result_cache.?);

    // Direct mirrors, driven by the shared binding records.
    inline for (std.meta.fields(@TypeOf(tool_executor_service_bindings))) |binding| {
        try std.testing.expectEqual(
            agentFieldValueAtPath(&agent, @field(tool_executor_service_bindings, binding.name)),
            @field(options, binding.name),
        );
    }
    inline for (std.meta.fields(@TypeOf(tool_executor_ctx_bindings))) |binding| {
        try std.testing.expectEqual(
            agentFieldValueAtPath(&agent, @field(tool_executor_ctx_bindings, binding.name)),
            @field(options.ctx, binding.name),
        );
    }
}

test "snapshotAfterBatch: disabled snapshots return without touching git" {
    // The `disabled` latch is the early return before any vcs call, so this
    // exercises the no-git-available branch without needing a repo.
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    agent.snapshotter = .{ .gpa = gpa, .io = std.testing.io, .disabled = true };
    snapshotAfterBatch(&agent); // must not error or allocate

    try std.testing.expect(agent.snapshotter.?.disabled);
    try std.testing.expect(agent.snapshotter.?.index_path == null);
    try std.testing.expect(agent.snapshotter.?.last_tree == null);
}

test "snapshotAfterBatch: no session writer short-circuits silently" {
    // Without a session_writer the function returns at the second guard, also
    // never touching git — confirming the best-effort contract holds even when
    // git IS available but no session is attached.
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // The latch stays false, but no session_writer is attached.
    snapshotAfterBatch(&agent);

    // No panic, no error; the latch was untouched because the short-circuit
    // never reached the git-availability probe.
    try std.testing.expect(!agent.snapshotter.?.disabled);
}

test "emitToolCallFinished transfers ownership to listener and cleans up on error" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    const FailingListener = struct {
        allocator: std.mem.Allocator,
        fn emit(self: @This(), event: Agent.Event) !void {
            var ev = event;
            ev.deinit(self.allocator);
            return error.SimulatedListenerFailure;
        }
    };
    const listener: FailingListener = .{ .allocator = gpa };

    const err = emitToolCallFinished(
        FailingListener,
        &agent,
        listener,
        0,
        "call_123",
        "bash",
        "Run bash",
        "bash: echo 1",
        "stdout output",
        .text,
        "stderr output",
        false,
    );
    try std.testing.expectError(error.SimulatedListenerFailure, err);
}
