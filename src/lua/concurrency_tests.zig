//! Deterministic real-worker coverage of plugin state and generation ownership.
const std = @import("std");
const c = @import("c");
const manager_mod = @import("manager.zig");
const registry_bridge = @import("registry_bridge.zig");
const bridge = @import("bridge.zig");
const sandbox = @import("sandbox.zig");
const snapshot_mod = @import("tool_snapshot.zig");
const ai = @import("../ai.zig");
const agent_mod = @import("../agent.zig");
const worker = @import("../tui/agent_worker.zig");
const test_helpers = @import("../tui/test_helpers.zig");
const tools = @import("../tools.zig");
const testing = std.testing;

const Gate = struct {
    io: std.Io,
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    active: std.atomic.Value(u32) = .init(0),
    maximum: std.atomic.Value(u32) = .init(0),
    callbacks: std.atomic.Value(u32) = .init(0),
    overlap: std.atomic.Value(bool) = .init(false),

    fn block(L: ?*c.lua_State) callconv(.c) c_int {
        const gate: *Gate = @ptrCast(@alignCast(c.lua_touserdata(L.?, c.lua_upvalueindex(1)).?));
        const active = gate.active.fetchAdd(1, .acq_rel) + 1;
        _ = gate.maximum.fetchMax(active, .acq_rel);
        gate.entered.set(gate.io);
        gate.release.wait(gate.io) catch {};
        _ = gate.active.fetchSub(1, .acq_rel);
        return 0;
    }

    fn observe(L: ?*c.lua_State) callconv(.c) c_int {
        const gate: *Gate = @ptrCast(@alignCast(c.lua_touserdata(L.?, c.lua_upvalueindex(1)).?));
        if (gate.active.load(.acquire) != 0) gate.overlap.store(true, .release);
        _ = gate.callbacks.fetchAdd(1, .acq_rel);
        return 0;
    }

    fn install(self: *Gate, instance: *manager_mod.PluginInstance) void {
        const L = instance.state.handle;
        c.lua_pushlightuserdata(L, self);
        c.lua_pushcclosure(L, block, 1);
        c.lua_setglobal(L, "host_gate");
        c.lua_pushlightuserdata(L, self);
        c.lua_pushcclosure(L, observe, 1);
        c.lua_setglobal(L, "host_observe");
    }
};

fn wait(event: *std.Io.Event) !void {
    try event.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
}

fn writePlugin(dir: std.Io.Dir, name: []const u8, plugin_source: []const u8) !void {
    const manifest = try std.fmt.allocPrint(testing.allocator, "return {{name='{s}',version='1'}}", .{name});
    defer testing.allocator.free(manifest);
    try dir.writeFile(testing.io, .{ .sub_path = "plugin.lua", .data = manifest });
    try dir.writeFile(testing.io, .{ .sub_path = "init.lua", .data = plugin_source });
}

fn tmpPath(gpa: std.mem.Allocator, tmp: *testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(testing.io, gpa);
    defer gpa.free(cwd);
    return std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
}

const source =
    \\local n=0
    \\function get_state() return tostring(n) end
    \\function set_state(s) n=tonumber(s); error('restore diagnostic') end
    \\zay.register_tool({name='test',description='test',parameters={block={type='boolean',optional=true}},handler=function(p)
    \\  if p.block then host_gate() end
    \\  n=n+1
    \\  return zay.get_cwd()
    \\end})
    \\zay.register_tool({name='late',description='late',parameters={},handler=function()
    \\  local ok,err=zay.register_tool({name='extra',description='extra',handler=function() return 'x' end})
    \\  return ok and 'unexpected' or err
    \\end})
    \\zay.register_tool({name='fail',description='fail',parameters={},handler=function() error('expected failure') end})
    \\zay.register_tool({name='loop',description='loop',parameters={},handler=function() while true do end end})
    \\zay.on('tool_call_started',function() host_observe(); assert(zay.write_file('event.txt',zay.get_cwd())) end)
;

const Call = struct {
    manager: *manager_mod.PluginManager,
    plugin_name: []const u8 = "concurrent",
    params: []const u8 = "{}",
    flag: ?*const std.atomic.Value(bool) = null,
    started: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    err: ?anyerror = null,
    result: ?@import("plugin_api.zig").ToolHandlerResult = null,

    fn run(self: *Call) void {
        bridge.cancel_requested_slot = self.flag;
        defer bridge.cancel_requested_slot = null;
        self.started.set(testing.io);
        self.result = self.manager.callTool(self.plugin_name, "test", self.params) catch |err| blk: {
            self.err = err;
            break :blk null;
        };
        self.done.set(testing.io);
    }

    fn deinit(self: *Call) void {
        if (self.result) |*result| result.deinit(self.manager.allocator);
    }
};

fn awaitUsers(manager: *manager_mod.PluginManager, count: u32) !void {
    var attempts: u32 = 0;
    while (manager.lifecycle.load(.acquire) < count) : (attempts += 1) {
        try testing.expect(attempts < 5000);
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "Lua concurrency: handlers serialize, snapshots stay independent, and canceled waiters never enter Lua" {
    var allocator: test_helpers.LockedAllocator = .{ .child = testing.allocator, .io = testing.io };
    const gpa = allocator.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePlugin(tmp.dir, "concurrent", source);
    const path = try tmpPath(gpa, &tmp);
    defer gpa.free(path);
    var manager = manager_mod.PluginManager.init(gpa, testing.io, "", "");
    defer manager.deinit();
    const instance = try manager.loadOne(path, false);
    var gate: Gate = .{ .io = testing.io };
    gate.install(instance);
    const top = instance.state.getTop();
    var first: Call = .{ .manager = &manager, .params = "{\"block\":true}" };
    defer first.deinit();
    var task = try testing.io.concurrent(Call.run, .{&first});
    defer task.await(testing.io);
    defer gate.release.set(testing.io); // release before join on every error
    try wait(&gate.entered);
    var canceled: std.atomic.Value(bool) = .init(false);
    var second: Call = .{ .manager = &manager, .flag = &canceled };
    defer second.deinit();
    var other_task = try testing.io.concurrent(Call.run, .{&second});
    defer other_task.await(testing.io);
    defer canceled.store(true, .release);
    try wait(&second.started);
    try awaitUsers(&manager, 2);
    try testing.expectEqual(@as(u32, 1), gate.maximum.load(.acquire));
    try testing.expectError(error.InFlightTurn, manager.reload("concurrent"));
    try testing.expectError(error.InFlightTurn, manager.unload("concurrent"));
    try testing.expectError(error.InFlightTurn, manager.loadOne(path, false));
    try testing.expectError(error.InFlightTurn, manager.repointProjectDir(path));
    // No Lua API or execution lock is touched by metadata reads on UI.
    const descriptors = try registry_bridge.buildPluginToolDescriptors(gpa, &manager);
    defer {
        for (descriptors) |tool| {
            tool.userdata_free.?(gpa, tool.userdata);
            gpa.free(tool.name);
            gpa.free(tool.description);
        }
        gpa.free(descriptors);
    }
    try testing.expectEqual(@as(usize, 4), descriptors.len);
    canceled.store(true, .release);
    try wait(&second.done);
    try testing.expectEqual(error.Canceled, second.err.?);
    try testing.expect(second.result == null);
    other_task.await(testing.io);
    // Headless SDK callers use Io cancellation without a UI atomic flag.
    var io_waiter: Call = .{ .manager = &manager };
    defer io_waiter.deinit();
    var io_task = try testing.io.concurrent(Call.run, .{&io_waiter});
    defer io_task.await(testing.io);
    try awaitUsers(&manager, 2);
    io_task.cancel(testing.io);
    try testing.expectEqual(error.Canceled, io_waiter.err.?);
    try testing.expect(io_waiter.result == null);
    gate.release.set(testing.io);
    try wait(&first.done);
    try testing.expect(first.err == null);
    task.await(testing.io);
    other_task.await(testing.io);
    try testing.expectEqual(top, instance.state.getTop());
    var result = try manager.callTool("concurrent", "late", "{}");
    defer result.deinit(gpa);
    try testing.expectEqualStrings("tools may only be registered during plugin initialization", result.text);
    try testing.expectError(error.ToolNotFound, manager.callTool("concurrent", "extra", "{}"));
    // An SDK turn lease rejects mutation even between tool calls.
    try manager.beginUse();
    try testing.expectError(error.InFlightTurn, manager.unload("concurrent"));
    manager.endUse();
    try manager.reload("concurrent");
    try testing.expectEqual(@as(c_int, 0), manager.get("concurrent").?.state.getTop());
    try manager.unload("concurrent");
    // Registry owns deep copies, not borrows of an unloaded instance.
    try testing.expectEqualStrings("block", descriptors[0].schema.properties[0].name);
}

test "Lua concurrency: two scripted lane workers serialize events and keep their own cwd" {
    var allocator: test_helpers.LockedAllocator = .{ .child = testing.allocator, .io = testing.io };
    const gpa = allocator.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "a", .default_dir);
    try tmp.dir.createDir(testing.io, "b", .default_dir);
    try writePlugin(tmp.dir, "concurrent", source);
    const path = try tmpPath(gpa, &tmp);
    defer gpa.free(path);
    const cwd_a = try std.fs.path.join(gpa, &.{ path, "a" });
    defer gpa.free(cwd_a);
    const cwd_b = try std.fs.path.join(gpa, &.{ path, "b" });
    defer gpa.free(cwd_b);
    var manager = manager_mod.PluginManager.init(gpa, testing.io, "", "");
    defer manager.deinit();
    const instance = try manager.loadOne(path, false);
    var gate: Gate = .{ .io = testing.io };
    gate.install(instance);
    var registry = try tools.ToolRegistry.init(gpa, tools.builtinRegistry());
    defer registry.deinit(gpa);
    const descriptors = try registry_bridge.buildPluginToolDescriptors(gpa, &manager);
    defer gpa.free(descriptors);
    for (descriptors) |tool| try registry.addPluginTool(gpa, tool);
    var client_a = try ai.scripted_client.Client.init(gpa, testing.io, "a");
    defer client_a.deinit();
    try client_a.enqueue(.{ ai.scripted_client.step.toolCall("lua__concurrent__test", "{\"block\":true}"), ai.scripted_client.step.text("a done", .stop) });
    var client_b = try ai.scripted_client.Client.init(gpa, testing.io, "b");
    defer client_b.deinit();
    try client_b.enqueue(.{ ai.scripted_client.step.toolCall(tools.shellToolName, "{\"command\":\"echo builtin\"}"), ai.scripted_client.step.toolCall("lua__concurrent__test", "{}"), ai.scripted_client.step.text("b done", .stop) });
    var agent_a = agent_mod.Agent.init(gpa, testing.io, cwd_a, .{ .scripted = &client_a });
    defer agent_a.deinit();
    agent_a.plugin_manager = &manager;
    agent_a.tool_registry = &registry;
    var agent_b = agent_mod.Agent.init(gpa, testing.io, cwd_b, .{ .scripted = &client_b });
    defer agent_b.deinit();
    agent_b.plugin_manager = &manager;
    agent_b.tool_registry = &registry;
    try agent_a.addUserPrompt("a");
    try agent_b.addUserPrompt("b");
    var context_a: worker.Context = .{ .io = testing.io, .gpa = gpa };
    defer context_a.queue.deinit(testing.io, gpa);
    var context_b: worker.Context = .{ .io = testing.io, .gpa = gpa };
    defer context_b.queue.deinit(testing.io, gpa);
    var task_a = try testing.io.concurrent(worker.runAgentTurn, .{ &agent_a, null, &context_a, false });
    defer task_a.await(testing.io);
    defer gate.release.set(testing.io);
    try wait(&gate.entered);
    const callbacks_before = gate.callbacks.load(.acquire);
    var task_b = try testing.io.concurrent(worker.runAgentTurn, .{ &agent_b, null, &context_b, false });
    defer task_b.await(testing.io);
    defer gate.release.set(testing.io);
    try awaitUsers(&manager, 4); // two whole-turn and two dispatch leases
    try testing.expectEqual(callbacks_before, gate.callbacks.load(.acquire));
    try testing.expectError(error.InFlightTurn, manager.reload("concurrent"));
    try testing.expectEqual(@as(u32, 1), gate.maximum.load(.acquire));
    gate.release.set(testing.io);
    task_a.await(testing.io);
    task_b.await(testing.io);
    try testing.expect(!gate.overlap.load(.acquire));
    try testing.expectEqual(@as(u32, 3), gate.callbacks.load(.acquire));
    try testing.expectEqual(@as(c_int, 0), instance.state.getTop());
    try testing.expectEqual(@as(u32, 0), manager.lifecycle.load(.acquire));
    const event_a = try tmp.dir.readFileAlloc(testing.io, "a/event.txt", gpa, .limited(4096));
    defer gpa.free(event_a);
    const event_b = try tmp.dir.readFileAlloc(testing.io, "b/event.txt", gpa, .limited(4096));
    defer gpa.free(event_b);
    try testing.expectEqualStrings(cwd_a, event_a);
    try testing.expectEqualStrings(cwd_b, event_b);
    try expectToolCwd(&agent_a, cwd_a);
    try expectToolCwd(&agent_b, cwd_b);
}

fn expectToolCwd(agent: *agent_mod.Agent, cwd: []const u8) !void {
    var found = false;
    for (agent.messages()) |message| {
        if (message == .tool) {
            for (message.tool.content) |block| {
                if (block == .text) {
                    if (std.mem.eql(u8, cwd, block.text.text)) found = true;
                }
            }
        }
    }
    try testing.expect(found);
}

test "Lua concurrency: failures, timeout, reload failure and allocation errors leave a usable state" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePlugin(tmp.dir, "concurrent", source);
    const path = try tmpPath(gpa, &tmp);
    defer gpa.free(path);
    var manager = manager_mod.PluginManager.init(gpa, testing.io, "", "");
    defer manager.deinit();
    const instance = try manager.loadOne(path, false);
    const top = instance.state.getTop();
    for ([_][]const u8{ "fail", "loop", "test" }) |name| {
        var result = try manager.callTool("concurrent", name, "{}");
        defer result.deinit(gpa);
        try testing.expectEqual(@as(u8, if (std.mem.eql(u8, name, "test")) 0 else 1), result.code);
        try testing.expectEqual(top, instance.state.getTop());
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "init.lua", .data = "error('broken replacement')" });
    try testing.expectError(error.PluginInitFailed, manager.reload("concurrent"));
    try testing.expect(manager.get("concurrent").? == instance);
    var failed = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    {
        manager.allocator = failed.allocator();
        defer manager.allocator = gpa;
        try testing.expectError(error.OutOfMemory, manager.callTool("concurrent", "test", "{}"));
    }
    try testing.expectEqual(top, instance.state.getTop());
    var result = try manager.callTool("concurrent", "test", "{}");
    defer result.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), result.code);
}

fn snapshotAllocations(gpa: std.mem.Allocator, L: *c.lua_State) !void {
    const top = c.lua_gettop(L);
    const snapshots = snapshot_mod.capture(gpa, L) catch |err| {
        try testing.expectEqual(top, c.lua_gettop(L));
        return err;
    };
    defer snapshot_mod.deinit(gpa, snapshots);
    try testing.expectEqual(top, c.lua_gettop(L));
    var schema = try snapshots[0].schema.clone(gpa);
    defer schema.deinit(gpa);
}

test "Lua concurrency: snapshot and schema clones unwind every allocation failure" {
    var L = try sandbox.createSandboxedStateWithIo(.{}, testing.io);
    defer L.deinit();
    defer sandbox.freeHookData(L.handle);
    try testing.expect(L.doString(
        \\zay.register_tool({name='t',description='description',parameters={p={type='string',description='parameter',enum={'a','b'},default='a"b'}},handler=function() return 'ok' end})
    ));
    try testing.checkAllAllocationFailures(testing.allocator, snapshotAllocations, .{L.handle});
}

test "Lua concurrency: independent plugins run while another state is blocked and I/O cancellation releases its guard" {
    var allocator: test_helpers.LockedAllocator = .{ .child = testing.allocator, .io = testing.io };
    const gpa = allocator.allocator();
    var tmp_a = testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = testing.tmpDir(.{});
    defer tmp_b.cleanup();
    try writePlugin(tmp_a.dir, "concurrent", source);
    try writePlugin(tmp_b.dir, "independent", source);
    const path_a = try tmpPath(gpa, &tmp_a);
    defer gpa.free(path_a);
    const path_b = try tmpPath(gpa, &tmp_b);
    defer gpa.free(path_b);
    var manager = manager_mod.PluginManager.init(gpa, testing.io, "", "");
    defer manager.deinit();
    const instance = try manager.loadOne(path_a, false);
    _ = try manager.loadOne(path_b, false);
    // A quiescent by-value owner move preserves heap instance addresses.
    const moved = manager;
    manager = moved;
    try testing.expect(manager.get("concurrent").? == instance);
    var gate: Gate = .{ .io = testing.io };
    gate.install(instance);
    var canceled: std.atomic.Value(bool) = .init(false);
    var first: Call = .{ .manager = &manager, .params = "{\"block\":true}", .flag = &canceled };
    defer first.deinit();
    var task = try testing.io.concurrent(Call.run, .{&first});
    defer task.await(testing.io);
    defer gate.release.set(testing.io);
    try wait(&gate.entered);
    var other: Call = .{ .manager = &manager, .plugin_name = "independent" };
    defer other.deinit();
    var other_task = try testing.io.concurrent(Call.run, .{&other});
    defer other_task.await(testing.io);
    try wait(&other.done);
    try testing.expect(other.err == null);
    try testing.expect(!first.done.isSet());
    // Interrupt flag alone keeps generation pinned until the I/O task exits.
    canceled.store(true, .release);
    try testing.expectError(error.InFlightTurn, manager.unload("concurrent"));
    task.cancel(testing.io); // cancels the host bridge Event.wait
    try testing.expectEqual(error.Canceled, first.err.?);
    try testing.expect(first.result == null);
    try testing.expectEqual(@as(c_int, 0), instance.state.getTop());
    var next = try manager.callTool("concurrent", "test", "{}");
    defer next.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), next.code);
    other_task.await(testing.io);
    try manager.repointProjectDir(path_b);
    try manager.unload("concurrent");
}

test "Lua concurrency: wall-clock timeout resets and leaves the execution mutex available" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePlugin(tmp.dir, "concurrent", source);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugin.lua", .data = "return {name='concurrent',version='1',permissions={instruction_limit=4294967295,timeout_ms=1}}" });
    const path = try tmpPath(gpa, &tmp);
    defer gpa.free(path);
    var manager = manager_mod.PluginManager.init(gpa, testing.io, "", "");
    defer manager.deinit();
    const instance = try manager.loadOne(path, false);
    var timeout = try manager.callTool("concurrent", "loop", "{}");
    defer timeout.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), timeout.code);
    try testing.expect(std.mem.indexOf(u8, timeout.text, "timeout exceeded") != null);
    try testing.expectEqual(@as(c_int, 0), instance.state.getTop());
    var next = try manager.callTool("concurrent", "test", "{}");
    defer next.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), next.code);
}

// Regression cases deliberately exercise protected calls, not only an
// unprotected `while true`; limits must escape every Lua recovery boundary.
test "lock architecture: protected calls and coroutines cannot swallow instruction limits" {
    const cases = [_][:0]const u8{
        "while true do pcall(function() while true do end end) end",
        "while true do xpcall(function() while true do end end,function(e) return e end) end",
        "while true do pcall(function() pcall(function() while true do end end) end) end",
        "while true do coroutine.resume(coroutine.create(function() while true do end end)) end",
        "while true do pcall(coroutine.wrap(function() while true do end end)) end",
        "while true do pcall(function() table.sort({2,1},function() while true do end end) end) end",
    };
    for (cases) |script| {
        var L = try sandbox.createSandboxedState(.{ .instruction_limit = 10, .timeout_ms = 1000 });
        defer L.deinit();
        defer sandbox.freeHookData(L.handle);
        try testing.expect(!L.doString(script));
        const err = L.getErrorMessage() orelse return error.MissingLimitError;
        try testing.expect(std.mem.indexOf(u8, err, "instruction limit exceeded") != null);
        L.pop(1);
        sandbox.resetInstructionBudget(L.handle);
        try testing.expect(L.doString("return pcall(function() return 'usable' end)"));
        try testing.expect(L.toBoolean(-2));
        try testing.expectEqualStrings("usable", L.toString(-1).?);
        L.pop(2);
    }
}

test "lock architecture: ordinary protected errors, multiple results and coroutine yields remain usable" {
    var L = try sandbox.createSandboxedState(.{});
    defer L.deinit();
    defer sandbox.freeHookData(L.handle);
    try testing.expect(L.doString(
        \\local ok,err=pcall(function() error('ordinary') end)
        \\assert(not ok and string.find(err,'ordinary'))
        \\local ok,a,b=pcall(function(x) return x,'b' end,'a')
        \\assert(ok and a=='a' and b=='b')
        \\local ok,err=xpcall(function() error('ordinary') end,function() return 'handled' end)
        \\assert(not ok and err=='handled')
        \\local co=coroutine.create(function()
        \\  return pcall(function() coroutine.yield('pause');return 'done' end)
        \\end)
        \\local ok,v=coroutine.resume(co);assert(ok and v=='pause')
        \\local ok,a,b=coroutine.resume(co);assert(ok and a and b=='done')
        \\local f=coroutine.wrap(function() coroutine.yield('pause');return 'done' end)
        \\assert(f()=='pause' and f()=='done')
    ));
}

test "lock architecture: timeout-only and full-access states retain host execution limits" {
    for ([_]bool{ false, true }) |full_access| {
        var L = try sandbox.createSandboxedState(.{ .instruction_limit = 0, .memory_limit_mb = 0, .timeout_ms = 1, .full_access = full_access });
        defer L.deinit();
        defer sandbox.freeHookData(L.handle);
        try testing.expect(!L.doString("while true do pcall(function() while true do end end) end"));
        try testing.expect(std.mem.indexOf(u8, L.getErrorMessage().?, "timeout exceeded") != null);
        L.pop(1);
        sandbox.resetInstructionBudget(L.handle);
        try testing.expect(L.doString("return 1"));
        L.pop(1);
    }
}

const SpinningCall = struct {
    manager: *manager_mod.PluginManager,
    entered: std.Io.Event = .unset,
    err: ?anyerror = null,
    result: ?@import("plugin_api.zig").ToolHandlerResult = null,

    fn signal(L: ?*c.lua_State) callconv(.c) c_int {
        const self: *SpinningCall = @ptrCast(@alignCast(c.lua_touserdata(L.?, c.lua_upvalueindex(1)).?));
        self.entered.set(testing.io);
        return 0;
    }

    fn run(self: *SpinningCall) void {
        self.result = self.manager.callTool("concurrent", "spin", "{}") catch |err| blk: {
            self.err = err;
            break :blk null;
        };
    }
};

test "lock architecture: Io cancellation escapes a spinning protected handler and frees the Lua gate" {
    var allocator: test_helpers.LockedAllocator = .{ .child = testing.allocator, .io = testing.io };
    const gpa = allocator.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePlugin(tmp.dir, "concurrent",
        \\zay.register_tool({name='spin',description='spin',handler=function()
        \\  host_signal()
        \\  while true do pcall(function() while true do end end) end
        \\end})
        \\zay.register_tool({name='test',description='test',handler=function() return 'usable' end})
    );
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugin.lua", .data = "return {name='concurrent',version='1',permissions={instruction_limit=0,timeout_ms=0}}" });
    const path = try tmpPath(gpa, &tmp);
    defer gpa.free(path);
    var manager = manager_mod.PluginManager.init(gpa, testing.io, "", "");
    defer manager.deinit();
    const instance = try manager.loadOne(path, false);
    var call: SpinningCall = .{ .manager = &manager };
    defer if (call.result) |*result| result.deinit(gpa);
    c.lua_pushlightuserdata(instance.state.handle, &call);
    c.lua_pushcclosure(instance.state.handle, SpinningCall.signal, 1);
    c.lua_setglobal(instance.state.handle, "host_signal");
    var task = try testing.io.concurrent(SpinningCall.run, .{&call});
    defer task.cancel(testing.io);
    try wait(&call.entered);
    task.cancel(testing.io);
    try testing.expectEqual(error.Canceled, call.err.?);
    try testing.expect(call.result == null);
    try testing.expectEqual(@as(c_int, 0), instance.state.getTop());
    var next = try manager.callTool("concurrent", "test", "{}");
    defer next.deinit(gpa);
    try testing.expectEqualStrings("usable", next.text);
}

test "lock architecture: busy tools time out, unrelated events skip Lua, and subscribed waits are bounded" {
    var allocator: test_helpers.LockedAllocator = .{ .child = testing.allocator, .io = testing.io };
    const gpa = allocator.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePlugin(tmp.dir, "concurrent", source);
    const path = try tmpPath(gpa, &tmp);
    defer gpa.free(path);
    var manager = manager_mod.PluginManager.init(gpa, testing.io, "", "");
    defer manager.deinit();
    manager.execution_policy = .{ .tool_wait_ms = 20, .event_budget_ms = 20 };
    const instance = try manager.loadOne(path, false);
    var gate: Gate = .{ .io = testing.io };
    gate.install(instance);
    var first: Call = .{ .manager = &manager, .params = "{\"block\":true}" };
    defer first.deinit();
    var task = try testing.io.concurrent(Call.run, .{&first});
    defer task.await(testing.io);
    defer gate.release.set(testing.io);
    try wait(&gate.entered);
    const start = std.Io.Timestamp.now(testing.io, .awake).nanoseconds;
    try testing.expectError(error.PluginBusy, manager.callTool("concurrent", "test", "{}"));
    const elapsed = std.Io.Timestamp.now(testing.io, .awake).nanoseconds - start;
    try testing.expect(elapsed >= 20 * std.time.ns_per_ms);
    try testing.expect(elapsed < std.time.ns_per_s);
    // A zero delivery budget still allows an immediate lookup-free skip.
    manager.execution_policy.event_budget_ms = 0;
    manager.emitEvent(.{ .response_received = {} });
    manager.execution_policy.event_budget_ms = 20;
    manager.emitEvent(.{ .tool_call_started = .{ .name = "builtin", .call_id = "other" } });
    try testing.expectEqual(@as(u32, 0), gate.callbacks.load(.acquire));
    try testing.expect(!first.done.isSet());
    gate.release.set(testing.io);
    task.await(testing.io);
    try testing.expect(first.err == null);
    const previous_cwd = bridge.plugin_cwd_slot;
    bridge.plugin_cwd_slot = path;
    defer bridge.plugin_cwd_slot = previous_cwd;
    manager.emitEvent(.{ .tool_call_started = .{ .name = "builtin", .call_id = "after" } });
    try testing.expectEqual(@as(u32, 1), gate.callbacks.load(.acquire));
}

test "lock architecture: runtime event registration updates the host subscription snapshot" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePlugin(tmp.dir, "concurrent",
        \\zay.register_tool({name='subscribe',description='subscribe',handler=function()
        \\  assert(zay.on('response_received',function() host_observe() end));return 'ok'
        \\end})
    );
    const path = try tmpPath(gpa, &tmp);
    defer gpa.free(path);
    var manager = manager_mod.PluginManager.init(gpa, testing.io, "", "");
    defer manager.deinit();
    const instance = try manager.loadOne(path, false);
    var gate: Gate = .{ .io = testing.io };
    gate.install(instance);
    manager.emitEvent(.{ .response_received = {} });
    try testing.expectEqual(@as(u32, 0), gate.callbacks.load(.acquire));
    var result = try manager.callTool("concurrent", "subscribe", "{}");
    defer result.deinit(gpa);
    manager.emitEvent(.{ .response_received = {} });
    try testing.expectEqual(@as(u32, 1), gate.callbacks.load(.acquire));
}

test "lock architecture: slow shell and permitted os.execute share the Lua deadline" {
    const gpa = testing.allocator;
    const cmd = if (@import("../os.zig").is_windows) "Start-Sleep -Seconds 10" else "sleep 10";
    for ([_]bool{ false, true }) |use_os| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const init = try std.fmt.allocPrint(gpa, "zay.register_tool({{name='slow',description='slow',handler=function() pcall(function() {s}('{s}') end);return 'unexpected' end}});zay.register_tool({{name='test',description='test',handler=function() return 'usable' end}})", .{ if (use_os) "os.execute" else "zay.run_shell", cmd });
        defer gpa.free(init);
        try writePlugin(tmp.dir, "concurrent", init);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugin.lua", .data = "return {name='concurrent',version='1',permissions={timeout_ms=200,allow_os_execute=true}}" });
        const path = try tmpPath(gpa, &tmp);
        defer gpa.free(path);
        var manager = manager_mod.PluginManager.init(gpa, testing.io, "", "");
        defer manager.deinit();
        const instance = try manager.loadOne(path, false);
        const start = std.Io.Timestamp.now(testing.io, .awake).nanoseconds;
        var result = try manager.callTool("concurrent", "slow", "{}");
        defer result.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), result.code);
        try testing.expect(std.mem.indexOf(u8, result.text, "timeout exceeded") != null);
        try testing.expect(std.Io.Timestamp.now(testing.io, .awake).nanoseconds - start < 3 * std.time.ns_per_s);
        try testing.expectEqual(@as(c_int, 0), instance.state.getTop());
        var next = try manager.callTool("concurrent", "test", "{}");
        defer next.deinit(gpa);
        try testing.expectEqualStrings("usable", next.text);
    }
}

test "lock architecture: one event budget stops protected callbacks and the next tool remains usable" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePlugin(tmp.dir, "concurrent",
        \\zay.on('response_received',function() while true do pcall(function() while true do end end) end end)
        \\zay.on('response_received',function() error('must not run after resource stop') end)
        \\zay.register_tool({name='test',description='test',handler=function() return 'usable' end})
    );
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugin.lua", .data = "return {name='concurrent',version='1',permissions={instruction_limit=0}}" });
    const path = try tmpPath(gpa, &tmp);
    defer gpa.free(path);
    var manager = manager_mod.PluginManager.init(gpa, testing.io, "", "");
    defer manager.deinit();
    manager.execution_policy.event_budget_ms = 20;
    const instance = try manager.loadOne(path, false);
    const start = std.Io.Timestamp.now(testing.io, .awake).nanoseconds;
    manager.emitEvent(.{ .response_received = {} });
    try testing.expect(std.Io.Timestamp.now(testing.io, .awake).nanoseconds - start < std.time.ns_per_s);
    try testing.expectEqual(@as(c_int, 0), instance.state.getTop());
    try testing.expect(@import("execution.zig").budget(instance.state.handle).?.stop_reason == .timeout);
    var next = try manager.callTool("concurrent", "test", "{}");
    defer next.deinit(gpa);
    try testing.expectEqualStrings("usable", next.text);
}

test "lock architecture: filesystem read rejects blocking devices before open" {
    if (@import("../os.zig").is_windows) return error.SkipZigTest;
    try testing.expectError(error.UnsupportedFileType, @import("bridges/fs_ops.zig").readFileBytes(testing.io, "/dev/null", 1024));
}

test "lock architecture: coroutine budget survives finalizers during Lua close" {
    var gate: Gate = .{ .io = testing.io };
    var L = try sandbox.createSandboxedStateWithIo(.{}, testing.io);
    c.lua_pushlightuserdata(L.handle, &gate);
    c.lua_pushcclosure(L.handle, Gate.observe, 1);
    c.lua_setglobal(L.handle, "host_observe");
    const loaded = L.doString(
        \\local co=coroutine.create(function() for i=1,10000 do end;return 'ok' end)
        \\held=setmetatable({}, {__gc=function()
        \\  local ok,res=coroutine.resume(co)
        \\  if ok and res=='ok' then host_observe() end
        \\end})
    );
    sandbox.freeHookData(L.handle);
    L.deinit();
    try testing.expect(loaded);
    try testing.expectEqual(@as(u32, 1), gate.callbacks.load(.acquire));
}

test "lock architecture: main-thread finalizer cannot swallow execution limits" {
    for ([_]u32{ 1, 0 }) |instruction_limit| {
        var gate: Gate = .{ .io = testing.io };
        var L = try sandbox.createSandboxedStateWithIo(.{ .instruction_limit = instruction_limit, .memory_limit_mb = 0, .timeout_ms = 0 }, testing.io);
        c.lua_pushlightuserdata(L.handle, &gate);
        c.lua_pushcclosure(L.handle, Gate.observe, 1);
        c.lua_setglobal(L.handle, "host_observe");
        const loaded = L.doString(
            \\held=setmetatable({}, {__gc=function()
            \\  host_observe()
            \\  while true do pcall(function() while true do end end) end
            \\end})
        );
        const start = std.Io.Timestamp.now(testing.io, .awake).nanoseconds;
        sandbox.freeHookData(L.handle);
        L.deinit();
        try testing.expect(std.Io.Timestamp.now(testing.io, .awake).nanoseconds - start < 3 * std.time.ns_per_s);
        try testing.expect(loaded);
        try testing.expectEqual(@as(u32, 1), gate.callbacks.load(.acquire));
    }
}
