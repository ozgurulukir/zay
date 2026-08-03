//! The `lane` builtin tool — the model's handle on Nova's parallel-lane
//! machinery. Runs on the worker thread, so it cannot touch App-owned state
//! (threads, split, parked lanes) directly; every action is posted across the
//! `LaneBridge` and resolved by the UI on its tick (see `lane_bridge.zig`).
//!
//! Workspace scoping (S5/S6): `lane enter`/`leave` mutate `Agent.workspace`
//! on this worker thread, between tool batches — the next batch's executor is
//! rebuilt from `effectiveCwd()`, so the scoping is atomic per batch. `enter`
//! borrows the lane's path (owned by that lane's `Thread`), never copies it.

const std = @import("std");

const agent_mod = @import("../agent.zig");
const common = @import("common.zig");
const lane_bridge = @import("lane_bridge.zig");

pub const tool: common.Tool = .{
    .name = "lane",
    .description = @embedFile("../prompts/tools/lane.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "action",
                .kind = .string,
                .description = "Which lane operation to perform.",
                .required = true,
                .enum_values = &.{ "list", "create", "enter", "leave", "merge", "spawn", "read", "cancel", "await", "steer" },
            },
            .{
                .name = "purpose",
                .kind = .string,
                .description = "Human-readable description of what the lane is for (branch-naming context for create/spawn).",
                .required = false,
                .nullable = true,
            },
            .{
                .name = "task",
                .kind = .string,
                .description = "The worker agent's first prompt (spawn only). Make it self-contained — the worker starts with fresh context.",
                .required = false,
                .nullable = true,
            },
            .{
                .name = "lane",
                .kind = .string,
                .description = "Lane id (the hex id shown by `lane list`) for enter/leave/merge/read/cancel/await/steer.",
                .required = false,
                .nullable = true,
            },
            .{
                .name = "steer",
                .kind = .string,
                .description = "Short steering message to inject into a running worker lane (steer only).",
                .required = false,
                .nullable = true,
            },
        },
    },
    .run = runTool,
    .display = display,
};

const Args = struct {
    action: lane_bridge.Op,
    purpose: ?[]const u8 = null,
    task: ?[]const u8 = null,
    lane: ?[]const u8 = null,
    steer: ?[]const u8 = null,

    fn deinit(self: *Args, gpa: std.mem.Allocator) void {
        if (self.purpose) |s| gpa.free(s);
        if (self.task) |s| gpa.free(s);
        if (self.lane) |s| gpa.free(s);
        if (self.steer) |s| gpa.free(s);
        self.* = undefined;
    }
};

const JsonArgs = struct {
    action: ?[]const u8 = null,
    purpose: ?[]const u8 = null,
    task: ?[]const u8 = null,
    lane: ?[]const u8 = null,
    steer: ?[]const u8 = null,
};

const ParseError = error{ InvalidAction, OutOfMemory };

fn parseArgs(gpa: std.mem.Allocator, arguments: []const u8) ParseError!Args {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAction,
    };
    defer parsed.deinit();
    const action_str = parsed.value.action orelse return error.InvalidAction;
    const action = opFromString(action_str) orelse return error.InvalidAction;

    var out = Args{ .action = action };
    errdefer out.deinit(gpa);
    if (parsed.value.purpose) |s| out.purpose = try gpa.dupe(u8, s);
    if (parsed.value.task) |s| out.task = try gpa.dupe(u8, s);
    if (parsed.value.lane) |s| out.lane = try gpa.dupe(u8, s);
    if (parsed.value.steer) |s| out.steer = try gpa.dupe(u8, s);
    return out;
}

fn opFromString(s: []const u8) ?lane_bridge.Op {
    const ops = std.meta.tags(lane_bridge.Op);
    inline for (ops) |op| {
        if (std.mem.eql(u8, s, @tagName(op))) return op;
    }
    return null;
}

fn parseError(gpa: std.mem.Allocator, err: ParseError) common.Error!common.Output {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAction => common.failFmt(
            gpa,
            1,
            "lane: invalid arguments — action must be one of: list, create, enter, leave, merge, spawn, read, cancel, await, steer\n",
            .{},
        ),
    };
}

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
    userdata: *anyopaque,
) common.Error!common.Output {
    _ = cwd;
    _ = userdata;
    // Null slot is defined behavior: headless/tests have no bridge.
    const slot = lane_bridge.lane_bridge_slot;
    const bridge = slot.bridge orelse return common.failFmt(gpa, 1, "lane: lanes are unavailable in this context\n", .{});
    const requester = slot.requester orelse return common.failFmt(gpa, 1, "lane: no lane requester attached\n", .{});

    var parsed = parseArgs(gpa, arguments) catch |err| return parseError(gpa, err);
    defer parsed.deinit(gpa);

    var req = lane_bridge.Request{
        .op = parsed.action,
        .purpose = parsed.purpose,
        .task = parsed.task,
        .lane = parsed.lane,
        .steer = parsed.steer,
        .requester = requester,
    };
    defer req.deinit(gpa);

    const resp = bridge.request(io, &req) catch |err| switch (err) {
        // `request` only yields `error.Canceled` (the owning future was
        // cancelled); the tool degrades to a terse observation.
        error.Canceled => return common.failFmt(gpa, 1, "lane: interrupted\n", .{}),
    };
    // `text` is owned by the UI; everything else in the response is borrowed.
    defer gpa.free(resp.text);

    // Workspace scoping is a worker-thread write, read by the next batch's
    // executor (H4). `enter` borrows the lane's path; `leave` drops the
    // borrow. The lane Thread owns the path and is guaranteed alive (S17).
    // Only enter/leave touch the agent — list/read/etc. skip the cast.
    if (parsed.action == .enter or parsed.action == .leave) {
        const agent: *agent_mod.Agent = @ptrCast(@alignCast(requester));
        switch (parsed.action) {
            .enter => {
                if (resp.path) |path| agent.workspace = path;
            },
            .leave => agent.workspace = null,
            else => {},
        }
    }

    const stdout = try gpa.dupe(u8, resp.text);
    const stderr = try gpa.alloc(u8, 0);
    return .{ .stdout = stdout, .stderr = stderr, .code = resp.code };
}

fn display(gpa: std.mem.Allocator, args: []const u8, userdata: *anyopaque) std.mem.Allocator.Error!common.ToolDisplay {
    _ = userdata;
    const Probe = struct { action: ?[]const u8 = null, lane: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(Probe, gpa, args, .{ .ignore_unknown_fields = true }) catch {
        return .{ .label = try gpa.dupe(u8, "lane") };
    };
    defer parsed.deinit();
    const action = parsed.value.action orelse return .{ .label = try gpa.dupe(u8, "lane") };
    if (parsed.value.lane) |lane_id| {
        return .{ .label = try std.fmt.allocPrint(gpa, "lane {s} {s}", .{ action, lane_id }) };
    }
    return .{ .label = try std.fmt.allocPrint(gpa, "lane {s}", .{action}) };
}

test "lane parses a full argument set" {
    const gpa = std.testing.allocator;
    var args = try parseArgs(gpa, "{\"action\":\"spawn\",\"purpose\":\"evaluate PR #82\",\"task\":\"Review the diff\",\"lane\":\"abc123\"}");
    defer args.deinit(gpa);
    try std.testing.expectEqual(lane_bridge.Op.spawn, args.action);
    try std.testing.expectEqualStrings("evaluate PR #82", args.purpose.?);
    try std.testing.expectEqualStrings("Review the diff", args.task.?);
    try std.testing.expectEqualStrings("abc123", args.lane.?);
}

test "lane rejects a missing or unknown action" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidAction, parseArgs(gpa, "{}"));
    try std.testing.expectError(error.InvalidAction, parseArgs(gpa, "{\"action\":\"nope\"}"));
}

test "lane opFromString round-trips every op" {
    const ops = std.meta.tags(lane_bridge.Op);
    inline for (ops) |op| {
        try std.testing.expectEqual(op, opFromString(@tagName(op)).?);
    }
    try std.testing.expect(opFromString("bogus") == null);
}

test "lane run without a bridge slot reports lanes unavailable" {
    const gpa = std.testing.allocator;
    const prev = lane_bridge.lane_bridge_slot;
    defer lane_bridge.lane_bridge_slot = prev;
    lane_bridge.lane_bridge_slot = .{};
    var output = try runTool(gpa, std.testing.io, ".", "{\"action\":\"list\"}", undefined);
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "lanes are unavailable") != null);
}

test "lane run against a stub bridge resolves a request end-to-end" {
    const gpa = std.testing.allocator;
    var bridge: lane_bridge.LaneBridge = .{};
    // A requester aligned like `*Agent` (the tool never dereferences it for
    // `list`, but the @alignCast in the enter/leave path must be satisfiable).
    const AgentAligned = struct { _: u8 align(@alignOf(agent_mod.Agent)) };
    var dummy: AgentAligned = .{ ._ = 0 };

    const Handler = struct {
        fn handle(_: *anyopaque, req: *const lane_bridge.Request) ?lane_bridge.Response {
            std.debug.assert(req.op == .list);
            return lane_bridge.response(std.testing.allocator, "one lane\n", .{}, null, null) catch unreachable;
        }
    };

    const prev = lane_bridge.lane_bridge_slot;
    defer lane_bridge.lane_bridge_slot = prev;
    lane_bridge.lane_bridge_slot = .{ .bridge = &bridge, .requester = &dummy };

    const Worker = struct {
        fn run(b: *lane_bridge.LaneBridge, allocator: std.mem.Allocator, out: *common.Output) void {
            _ = b;
            out.* = runTool(allocator, std.testing.io, ".", "{\"action\":\"list\"}", undefined) catch |err| {
                std.debug.print("runTool failed: {s}\n", .{@errorName(err)});
                return;
            };
        }
    };
    var result: common.Output = undefined;
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &bridge, gpa, &result });
    var spins: u32 = 0;
    while (spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
        bridge.mutex.lock(std.testing.io) catch continue;
        const posted = bridge.pending != null;
        bridge.mutex.unlock(std.testing.io);
        if (posted) break;
    }
    try std.testing.expect(bridge.pending != null);
    bridge.service(std.testing.io, undefined, &Handler.handle);
    thread.join();
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqualStrings("one lane\n", result.stdout);
}

test "lane enter/leave write the agent workspace via the bridge" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var bridge: lane_bridge.LaneBridge = .{};

    const Handler = struct {
        const path = "THE_LANE_PATH";
        fn handle(_: *anyopaque, req: *const lane_bridge.Request) ?lane_bridge.Response {
            _ = req;
            return lane_bridge.response(std.testing.allocator, "ok\n", .{}, null, path) catch unreachable;
        }
    };

    const Worker = struct {
        fn run(b: *lane_bridge.LaneBridge, a: *agent_mod.Agent, action: []const u8) void {
            const args = std.fmt.allocPrint(std.testing.allocator, "{{\"action\":\"{s}\"}}", .{action}) catch unreachable;
            defer std.testing.allocator.free(args);
            var output = runTool(std.testing.allocator, std.testing.io, ".", args, undefined) catch |err| {
                std.debug.print("runTool failed: {s}\n", .{@errorName(err)});
                return;
            };
            output.deinit(std.testing.allocator);
            _ = b;
            _ = a;
        }
    };

    const prev = lane_bridge.lane_bridge_slot;
    defer lane_bridge.lane_bridge_slot = prev;
    lane_bridge.lane_bridge_slot = .{ .bridge = &bridge, .requester = &agent };

    // ── enter: the tool borrows the returned path as the workspace.
    const thread1 = try std.Thread.spawn(.{}, Worker.run, .{ &bridge, &agent, "enter" });
    var spins: u32 = 0;
    while (spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
        bridge.mutex.lock(std.testing.io) catch continue;
        const posted = bridge.pending != null;
        bridge.mutex.unlock(std.testing.io);
        if (posted) break;
    }
    try std.testing.expect(bridge.pending != null);
    bridge.service(std.testing.io, undefined, &Handler.handle);
    thread1.join();
    try std.testing.expectEqualStrings(Handler.path, agent.workspace.?);
    try std.testing.expectEqualStrings(Handler.path, agent.effectiveCwd());

    // ── leave: the tool clears the borrow.
    const thread2 = try std.Thread.spawn(.{}, Worker.run, .{ &bridge, &agent, "leave" });
    spins = 0;
    while (spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
        bridge.mutex.lock(std.testing.io) catch continue;
        const posted = bridge.pending != null;
        bridge.mutex.unlock(std.testing.io);
        if (posted) break;
    }
    try std.testing.expect(bridge.pending != null);
    bridge.service(std.testing.io, undefined, &Handler.handle);
    thread2.join();
    try std.testing.expect(agent.workspace == null);
    try std.testing.expectEqualStrings(".", agent.effectiveCwd());
}
