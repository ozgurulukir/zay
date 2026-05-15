const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
const openai_mod = @import("ai/openai.zig");
const thread_mod = @import("thread.zig");
const tools_mod = @import("tools.zig");

const Render = thread_mod.Render;

/// TUI display policy for a tool — Expand-by-default + Render mode.
/// Lives here, *not* in the tool layer: the agent and the tools know
/// nothing about how the TUI draws their results.
const ToolPolicy = struct {
    expand_by_default: bool,
    render: Render,
};

/// One entry per tool in the **Tool registry**. The comptime block below
/// asserts the table covers exactly the registry — no missing tools, no
/// orphan entries. Adding a tool requires explicitly choosing a display
/// policy here; forgetting is a build error, not a silent fall-back to
/// "plain, collapsed."
const tool_policies = [_]struct { name: []const u8, policy: ToolPolicy }{
    .{ .name = "bash", .policy = .{ .expand_by_default = false, .render = .plain } },
    .{ .name = "read", .policy = .{ .expand_by_default = false, .render = .plain } },
    .{ .name = "search_codebase", .policy = .{ .expand_by_default = false, .render = .plain } },
    .{ .name = "write_file", .policy = .{ .expand_by_default = true, .render = .plain } },
    .{ .name = "edit_file", .policy = .{ .expand_by_default = true, .render = .diff } },
};

comptime {
    // Every tool in the registry has a policy entry.
    for (tools_mod.registry) |tool| {
        var found = false;
        for (tool_policies) |p| if (std.mem.eql(u8, p.name, tool.name)) {
            found = true;
        };
        if (!found) @compileError("missing TUI policy for tool: " ++ tool.name);
    }
    // Every policy entry maps to a registry tool — no orphans.
    for (tool_policies) |p| {
        var found = false;
        for (tools_mod.registry) |tool| if (std.mem.eql(u8, p.name, tool.name)) {
            found = true;
        };
        if (!found) @compileError("orphan TUI policy entry: " ++ p.name);
    }
}

fn policyFor(name: []const u8) ToolPolicy {
    for (tool_policies) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.policy;
    }
    unreachable; // guaranteed by the comptime check above
}

const logo_bytes_max = 64 * 1024;
const loading_spinners = [4][]const u8{ "Firing Neurons", "Multiplying Matrices", "brr..brr...", "Warping" };
const loading_frames = [8][]const u8{ "⣼", "⣹", "⢻", "⠿", "⡟", "⣏", "⣧", "⣶" };
const loading_frame_ms = 40;
// TODO: Investigate jumpToItem as an alternative to handrolling logic
pub const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    agent: *agent_mod.Agent,
    thread: thread_mod.Thread = .{},
    input: vxfw.TextField,
    worker_context: AgentWorkerContext,
    turn_future: ?std.Io.Future(void) = null,
    in_flight: bool = false,
    loading_index: ?u32 = null,
    loading_frame: u8 = 0,
    loading_word_index: u8 = 0,
    loading_tick_active: bool = false,
    agent_index: ?u32 = null,
    thinking_index: ?u32 = null,
    tool_seen_in_response: bool = false,
    awaiting_tool_call: bool = false,
    pending_redraw: bool = false,
    thread_auto_scroll: bool = true,
    tool_indexes: std.ArrayList(?u32) = .empty,
    thread_list: vxfw.ListView = .{
        .children = .{ .slice = &.{} },
        .draw_cursor = false,
        .wheel_scroll = 4,
    },

    pub fn init(io: std.Io, gpa: std.mem.Allocator, agent: *agent_mod.Agent) App {
        return .{
            .io = io,
            .gpa = gpa,
            .agent = agent,
            .input = .init(gpa),
            .worker_context = .{
                .io = io,
                .gpa = agent.gpa,
                .agent = agent,
            },
        };
    }

    pub fn deinit(self: *App) void {
        self.awaitTurn();
        self.worker_context.queue.deinit(self.worker_context.io, self.worker_context.gpa);
        self.tool_indexes.deinit(self.gpa);
        self.thread.deinit(self.gpa);
        self.input.deinit();
        self.* = undefined;
    }

    fn awaitTurn(self: *App) void {
        if (self.turn_future) |*future| {
            future.await(self.io);
            self.turn_future = null;
        }
    }

    pub fn beginSubmit(self: *App) !?u32 {
        if (self.in_flight) return null;
        const prompt = try self.input.toOwnedSlice();
        defer self.gpa.free(prompt);
        if (prompt.len == 0) return null;

        self.resetTurnState();
        _ = try self.thread.append(self.gpa, .user, "you", prompt);
        try self.agent.addUser(prompt);
        try self.appendLoading();
        self.in_flight = true;
        return self.loading_index;
    }

    fn resetTurnState(self: *App) void {
        self.agent_index = null;
        self.thinking_index = null;
        self.loading_index = null;
        self.loading_frame = 0;
        self.loading_word_index = chooseLoadingWordIndex(self.io);
        self.tool_seen_in_response = false;
        self.awaiting_tool_call = true;
        self.pending_redraw = false;
        // Leave `thread_auto_scroll` alone — if the user has scrolled away
        // from the tail to read older context, submitting another message
        // should not yank them back. They can scroll down (or arrow-down)
        // to opt back into auto-follow.
        self.tool_indexes.clearRetainingCapacity();
    }

    pub fn startTurn(self: *App) !void {
        self.turn_future = try self.io.concurrent(runAgentTurn, .{
            self.agent,
            &self.worker_context,
        });
    }

    fn appendLoading(self: *App) !void {
        std.debug.assert(self.loading_index == null);
        std.debug.assert(self.loading_word_index < loading_spinners.len);
        self.loading_index = try self.thread.append(
            self.gpa,
            .status,
            loading_spinners[self.loading_word_index],
            "",
        );
    }

    fn removeLoading(self: *App) void {
        const index = self.loading_index orelse return;
        self.loading_index = null;
        if (index >= self.thread.messages.items.len) return;
        self.thread.remove(self.gpa, index);
        self.adjustIndexesAfterRemove(index);
    }

    fn adjustIndexesAfterRemove(self: *App, removed_index: u32) void {
        adjustOptionalIndex(&self.agent_index, removed_index);
        adjustOptionalIndex(&self.thinking_index, removed_index);
        for (self.tool_indexes.items) |*tool_index| adjustOptionalIndex(tool_index, removed_index);
    }

    fn advanceLoadingFrame(self: *App) void {
        std.debug.assert(loading_frames.len > 0);
        self.loading_frame +%= 1;
        if (self.loading_frame >= loading_frames.len) self.loading_frame = 0;
    }

    pub fn applyAgentEvent(self: *App, event: agent_mod.Agent.Event) !bool {
        switch (event) {
            .turn_started => return false,
            .response_delta => |delta| {
                self.removeLoading();
                if (delta.len == 0) return false;
                _ = try self.finishThinking();
                try self.applyContentDelta(delta);
                self.pending_redraw = true;
                return true;
            },
            .thinking_delta => |delta| {
                self.removeLoading();
                if (try self.applyReasoningDelta(delta)) {
                    self.pending_redraw = true;
                }
                return false;
            },
            .tool_delta => |tool| {
                const thinking_finished = try self.finishThinking();
                if (try self.applyToolDelta(tool)) {
                    self.pending_redraw = true;
                }
                if (thinking_finished) {
                    self.pending_redraw = true;
                }
                return false;
            },
            .delta_end => {
                const redraw = self.pending_redraw;
                self.pending_redraw = false;
                // Once the model has started streaming (reasoning, content, or
                // a tool call), we are committed to this turn — no need to put
                // the spinner back between chunks. The visible streaming text
                // is its own progress indicator, and any future "waiting" gap
                // (between tool batches, or before the next turn) is handled
                // by the explicit appendLoading sites.
                return redraw;
            },
            .tool_call_finished => |tool| {
                self.removeLoading();
                const thinking_finished = try self.finishThinking();
                return thinking_finished or try self.applyToolFinished(tool);
            },
            .tool_batch_finished => {
                self.removeLoading();
                const thinking_finished = try self.finishThinking();
                self.agent_index = null;
                self.thinking_index = null;
                self.tool_seen_in_response = false;
                self.awaiting_tool_call = false;
                self.tool_indexes.clearRetainingCapacity();
                try self.appendLoading();
                _ = thinking_finished;
                return true;
            },
            .turn_failed => |message| {
                self.removeLoading();
                _ = try self.thread.append(self.gpa, .agent, "agent", message);
                return true;
            },
            .turn_finished => {
                self.removeLoading();
                _ = try self.finishThinking();
                self.in_flight = false;
                self.awaitTurn();
                return true;
            },
        }
    }

    fn applyContentDelta(self: *App, delta: []const u8) !void {
        if (delta.len == 0) return;
        if (self.agent_index) |index| {
            try self.thread.appendAgentDelta(self.gpa, index, delta);
        } else {
            self.agent_index = try self.thread.append(self.gpa, .agent, "agent", delta);
        }
        if (!self.tool_seen_in_response) {
            self.selectGeneratedMessage(self.agent_index.?);
        }
    }

    fn finishThinking(self: *App) !bool {
        const index = self.thinking_index orelse return false;
        if (index >= self.thread.messages.items.len) return false;
        if (std.mem.eql(u8, self.thread.messages.items[index].title, "Thoughts")) return false;
        try self.thread.finishThinking(self.gpa, index);
        return true;
    }

    fn applyReasoningDelta(self: *App, delta: []const u8) !bool {
        if (delta.len == 0) return false;
        var visible_change = false;
        if (self.thinking_index) |index| {
            try self.thread.appendThinkingDelta(self.gpa, index, delta);
        } else if (self.agent_index) |agent_index| {
            self.thinking_index = try self.thread.insert(
                self.gpa,
                agent_index,
                .thinking,
                "Thinking...",
                delta,
            );
            self.agent_index = agent_index + 1;
            self.thread.select(self.thinking_index.?);
            visible_change = true;
        } else {
            self.thinking_index = try self.thread.append(self.gpa, .thinking, "Thinking...", delta);
            visible_change = true;
        }
        if (self.agent_index == null and !self.tool_seen_in_response) {
            self.selectGeneratedMessage(self.thinking_index.?);
        }
        return visible_change;
    }

    fn applyToolDelta(self: *App, tool: ai.ToolDelta) !bool {
        if (std.mem.eql(u8, tool.name, "bash")) {
            const command = agent_mod.parseCommand(self.gpa, tool.arguments) catch return false;
            self.gpa.free(command);
        }
        const title = try agent_mod.formatToolTitle(self.gpa, tool.name, tool.arguments);
        defer self.gpa.free(title);

        if (std.mem.eql(u8, tool.name, "bash")) self.removeLoading();

        var visible_change = false;
        if (self.toolThreadIndex(tool.index)) |index| {
            visible_change = !toolTitleMatchesCommand(self.thread.messages.items[index].title, title);
            try self.thread.updateTool(self.gpa, index, title);
        } else {
            const index = try self.thread.startTool(self.gpa, title);
            try self.putToolThreadIndex(tool.index, index);
            visible_change = true;
        }
        self.tool_seen_in_response = true;
        return visible_change;
    }

    fn applyToolFinished(self: *App, tool: agent_mod.Agent.Event.ToolCallFinished) !bool {
        const policy = policyFor(tool.name);
        const existing_index = self.toolThreadIndex(tool.index);
        const index = if (existing_index) |index| index else index: {
            const created = try self.thread.startTool(self.gpa, tool.display_label);
            try self.putToolThreadIndex(tool.index, created);
            break :index created;
        };

        const visible_before = self.toolFinishVisibleChange(index, tool.display_label);
        const was_expanded = self.thread.messages.items[index].expanded;
        try self.thread.updateTool(self.gpa, index, tool.display_label);
        try self.thread.finishTool(self.gpa, index, tool.display_body, tool.stderr, tool.failed);
        self.thread.messages.items[index].expanded = policy.expand_by_default;
        self.thread.messages.items[index].tool_render = policy.render;
        self.selectGeneratedMessage(index);
        self.tool_seen_in_response = true;
        return existing_index == null or visible_before or policy.expand_by_default != was_expanded;
    }

    fn selectGeneratedMessage(self: *App, index: u32) void {
        // Re-assert selection only when the user is already on this exact
        // message (or has no selection yet). A scrolled-up user, or a user
        // parked at the tail while an *earlier* message is being finished,
        // stays put.
        if (self.thread.selected) |selected| {
            if (selected != index) return;
        }
        self.thread.select(index);
    }

    fn toolFinishVisibleChange(self: *const App, index: u32, command: []const u8) bool {
        if (index >= self.thread.messages.items.len) return true;
        const message = self.thread.messages.items[index];
        if (message.kind != .tool) return true;
        if (message.expanded) return true;
        return !toolTitleMatchesCommand(message.title, command);
    }

    fn toolThreadIndex(self: *const App, tool_index: u32) ?u32 {
        if (tool_index >= self.tool_indexes.items.len) return null;
        return self.tool_indexes.items[tool_index];
    }

    fn putToolThreadIndex(self: *App, tool_index: u32, thread_index: u32) !void {
        while (self.tool_indexes.items.len <= tool_index) {
            try self.tool_indexes.append(self.gpa, null);
        }
        self.tool_indexes.items[tool_index] = thread_index;
    }

    pub fn handleCommandKey(self: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.up, .{})) {
            self.thread.moveSelection(.previous);
            self.thread_auto_scroll = false;
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            self.thread.moveSelection(.next);
            self.thread_auto_scroll = self.selectionIsLastMessage();
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            self.thread.toggleSelected();
            return true;
        }
        return false;
    }

    fn selectionIsLastMessage(self: *const App) bool {
        const selected = self.thread.selected orelse return false;
        if (self.thread.messages.items.len == 0) return false;
        return selected == self.thread.messages.items.len - 1;
    }
};

fn adjustOptionalIndex(index: *?u32, removed_index: u32) void {
    const current = index.* orelse return;
    if (current == removed_index) {
        index.* = null;
    } else if (current > removed_index) {
        index.* = current - 1;
    }
}

fn toolTitleMatchesCommand(title: []const u8, command: []const u8) bool {
    const prefix = "$ ";
    return std.mem.startsWith(u8, title, prefix) and
        std.mem.eql(u8, title[prefix.len..], command);
}

fn chooseLoadingWordIndex(io: std.Io) u8 {
    std.debug.assert(loading_spinners.len > 0);
    const timestamp: std.Io.Timestamp = .now(io, .awake);
    const index = @mod(timestamp.nanoseconds, loading_spinners.len);
    return @intCast(index);
}

const AgentEventQueue = struct {
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(*agent_mod.Agent.Event) = .empty,

    fn push(
        self: *AgentEventQueue,
        io: std.Io,
        gpa: std.mem.Allocator,
        event: *agent_mod.Agent.Event,
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.items.append(gpa, event);
    }

    fn drainInto(
        self: *AgentEventQueue,
        io: std.Io,
        gpa: std.mem.Allocator,
        sink: *std.ArrayList(*agent_mod.Agent.Event),
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try sink.appendSlice(gpa, self.items.items);
        self.items.clearRetainingCapacity();
    }

    fn deinit(self: *AgentEventQueue, io: std.Io, gpa: std.mem.Allocator) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        for (self.items.items) |event_ptr| {
            event_ptr.deinit(gpa);
            gpa.destroy(event_ptr);
        }
        self.items.deinit(gpa);
    }
};

const AgentWorkerContext = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    agent: *agent_mod.Agent,
    queue: AgentEventQueue = .{},
};

fn runAgentTurn(agent: *agent_mod.Agent, worker_context: *AgentWorkerContext) void {
    agent.run(.{
        .ptr = worker_context,
        .on_event = postAgentEvent,
    }) catch |err| {
        const message = std.fmt.allocPrint(
            worker_context.gpa,
            "agent turn failed: {s}",
            .{@errorName(err)},
        ) catch return;
        postAgentEvent(worker_context, .{ .turn_failed = message }) catch {
            worker_context.gpa.free(message);
            return;
        };
    };
    postAgentEvent(worker_context, .turn_finished) catch {};
}

fn postAgentEvent(context: *anyopaque, event: agent_mod.Agent.Event) anyerror!void {
    const worker_context: *AgentWorkerContext = @ptrCast(@alignCast(context));
    var owned_event = event;
    errdefer owned_event.deinit(worker_context.gpa);
    const event_ptr = try worker_context.gpa.create(agent_mod.Agent.Event);
    errdefer worker_context.gpa.destroy(event_ptr);
    event_ptr.* = owned_event;
    owned_event = .delta_end;
    errdefer event_ptr.deinit(worker_context.gpa);
    try worker_context.queue.push(worker_context.io, worker_context.gpa, event_ptr);
}

pub fn run(init: std.process.Init, agent: *agent_mod.Agent) !void {
    const gpa = init.arena.allocator();
    var tty_buffer: [8192]u8 = undefined;
    var fw_app = try vxfw.App.init(init.io, gpa, init.environ_map, &tty_buffer);
    defer fw_app.deinit();

    var app = App.init(init.io, gpa, agent);
    defer app.deinit();

    const logo = try loadStartupLogo(init.io, gpa);
    defer gpa.free(logo);
    _ = try app.thread.append(gpa, .logo, "logo", logo);

    var root: RootWidget = .{ .app = &app };
    try fw_app.run(root.widget(), .{});
}

fn loadStartupLogo(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    var cwd = std.Io.Dir.cwd();
    return cwd.readFileAllocOptions(io, "src/assets/logo.txt", gpa, .limited(logo_bytes_max), .of(u8), 0);
}

const RootWidget = struct {
    app: *App,
    spinner_tick_accum: u32 = 0,

    fn widget(self: *RootWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .captureHandler = captureEvent,
            .eventHandler = handleEvent,
            .drawFn = drawRoot,
        };
    }

    fn captureEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                try ctx.requestFocus(self.app.input.widget());
                ctx.consumeAndRedraw();
            },
            .mouse => |mouse| {
                if (mouse.button == .wheel_up) self.app.thread_auto_scroll = false;
                if (mouse.button == .wheel_down) self.app.thread_auto_scroll = !self.app.thread_list.scroll.has_more;
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                    ctx.quit = true;
                    ctx.consume_event = true;
                    return;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    try self.submit(ctx);
                    return;
                }
                if (try self.app.handleCommandKey(key)) {
                    ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
    }

    fn handleEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        switch (event) {
            .tick => try self.handleTick(ctx),
            else => {},
        }
    }

    const drain_tick_ms: u32 = 30;
    const spinner_tick_threshold_ms: u32 = loading_frame_ms;

    fn handleTick(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        var visible_change = try self.drainAgentEvents(ctx);

        if (self.app.loading_index) |_| {
            self.spinner_tick_accum += drain_tick_ms;
            if (self.spinner_tick_accum >= spinner_tick_threshold_ms) {
                self.spinner_tick_accum = 0;
                self.app.advanceLoadingFrame();
                visible_change = true;
            }
        } else {
            self.spinner_tick_accum = 0;
        }

        const should_tick = self.app.in_flight or self.app.loading_index != null;
        if (should_tick) {
            try ctx.tick(drain_tick_ms, self.widget());
        } else {
            self.app.loading_tick_active = false;
        }

        if (visible_change) {
            ctx.consumeAndRedraw();
        } else {
            ctx.consumeEvent();
        }
    }

    fn startLoadingTick(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        if (self.app.loading_tick_active) return;
        self.app.loading_tick_active = true;
        self.spinner_tick_accum = 0;
        try ctx.tick(drain_tick_ms, self.widget());
    }

    fn submit(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        const loading_index = (try self.app.beginSubmit()) orelse return;
        _ = loading_index;
        try self.app.startTurn();
        try self.startLoadingTick(ctx);
        ctx.consumeAndRedraw();
    }

    fn drainAgentEvents(self: *RootWidget, ctx: *vxfw.EventContext) !bool {
        const worker_io = self.app.worker_context.io;
        const worker_gpa = self.app.worker_context.gpa;
        var batch: std.ArrayList(*agent_mod.Agent.Event) = .empty;
        defer batch.deinit(worker_gpa);
        try self.app.worker_context.queue.drainInto(worker_io, worker_gpa, &batch);

        var visible_change = false;
        for (batch.items) |event_ptr| {
            defer worker_gpa.destroy(event_ptr);
            defer event_ptr.deinit(worker_gpa);

            if (self.app.loading_index != null) try self.startLoadingTick(ctx);
            if (try self.app.applyAgentEvent(event_ptr.*)) visible_change = true;
            if (self.app.loading_index != null) try self.startLoadingTick(ctx);
        }
        return visible_change;
    }

    fn drawRoot(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        const input_height: u16 = @min(max_height, 3);
        const thread_height: u16 = max_height - input_height;

        var thread_view: ThreadWidget = .{ .app = self.app };
        var input_view: InputWidget = .{ .app = self.app };

        const thread_ctx = ctx.withConstraints(
            .{ .width = max_width, .height = thread_height },
            .{ .width = max_width, .height = thread_height },
        );
        const input_ctx = ctx.withConstraints(
            .{ .width = max_width, .height = input_height },
            .{ .width = max_width, .height = input_height },
        );

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try thread_view.widget().draw(thread_ctx),
            .z_index = 0,
        };
        children[1] = .{
            .origin = .{ .row = thread_height, .col = 0 },
            .surface = try input_view.widget().draw(input_ctx),
            .z_index = 0,
        };

        return .{
            .size = .{ .width = max_width, .height = max_height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

const ConversationLayout = struct {
    const left: u16 = 2;
    const right: u16 = 2;
    const top: u16 = 1;
    const bottom: u16 = 1;

    fn verticalPadding() @TypeOf(vxfw.Padding.vertical(0)) {
        return .{
            .top = top,
            .bottom = bottom,
        };
    }

    fn contentWidth(width: u16) u16 {
        return width -| left -| right;
    }
};

const ThreadWidget = struct {
    app: *App,

    fn widget(self: *ThreadWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawThread,
        };
    }

    fn drawThread(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *ThreadWidget = @ptrCast(@alignCast(ptr));
        const widgets = try self.messageWidgets(ctx);
        self.app.thread_list.children = .{ .slice = widgets };
        self.app.thread_list.item_count = @intCast(widgets.len);
        self.syncCursor(ctx);

        var list_padding: vxfw.Padding = .{
            .child = self.app.thread_list.widget(),
            .padding = ConversationLayout.verticalPadding(),
        };
        return list_padding.widget().draw(ctx);
    }

    fn messageWidgets(self: *ThreadWidget, ctx: vxfw.DrawContext) ![]vxfw.Widget {
        const messages = self.app.thread.messages.items;
        const widgets = try ctx.arena.alloc(vxfw.Widget, messages.len);
        const bodies = try ctx.arena.alloc(MessageWidget, messages.len);
        for (messages, 0..) |message, index| {
            const selected = if (self.app.thread.selected) |selected_index| selected_index == index else false;
            bodies[index] = .{ .message = message, .selected = selected, .loading_frame = self.app.loading_frame };
            widgets[index] = bodies[index].widget();
        }
        return widgets;
    }

    fn syncCursor(self: *ThreadWidget, ctx: vxfw.DrawContext) void {
        // Auto-scroll follows the actual tail of the thread, NOT the user's
        // selection. The user can wheel-scroll to the bottom (turning auto-
        // scroll on) while their selection still points at an earlier
        // message — in that case we must keep them at the tail and leave
        // the selection untouched. Tying the scroll cursor to `selected`
        // here used to make every keystroke (which triggers a redraw via
        // the focused TextField) snap the viewport up to the selection.
        const messages = self.app.thread.messages.items;
        if (messages.len == 0) return;
        if (self.app.thread_auto_scroll) {
            const tail_index: u32 = @intCast(messages.len - 1);
            const cursor = self.app.loading_index orelse tail_index;
            self.app.thread_list.cursor = cursor;
            self.scrollCursorToTail(ctx, cursor);
            return;
        }
        const cursor = self.app.thread.selected orelse self.app.loading_index orelse 0;
        const cursor_changed = self.app.thread_list.cursor != cursor;
        self.app.thread_list.cursor = cursor;
        if (cursor_changed) self.app.thread_list.ensureScroll();
    }

    fn scrollCursorToTail(self: *ThreadWidget, ctx: vxfw.DrawContext, cursor: u32) void {
        if (cursor >= self.app.thread.messages.items.len) return;
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        const list_height = max_height -| ConversationLayout.top -| ConversationLayout.bottom;
        const message = self.app.thread.messages.items[cursor];
        const message_height = messageRows(message, ConversationLayout.contentWidth(max_width));
        self.app.thread_list.scroll.top = cursor;
        self.app.thread_list.scroll.pending_lines = 0;
        self.app.thread_list.scroll.wants_cursor = false;
        if (message_height > list_height) {
            self.app.thread_list.scroll.offset = @intCast(message_height - list_height);
        } else {
            self.app.thread_list.scroll.offset = 0;
        }
    }
};

const MessageWidget = struct {
    message: thread_mod.Message,
    selected: bool,
    loading_frame: u8,

    fn widget(self: *MessageWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = draw,
        };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *MessageWidget = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse ctx.min.width;
        const height = messageRows(self.message, ConversationLayout.contentWidth(width));
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = width,
            .height = height,
        });
        self.drawBody(&surface, ctx);
        return surface;
    }

    fn drawBody(self: *MessageWidget, surface: *vxfw.Surface, ctx: vxfw.DrawContext) void {
        var row: u16 = 0;
        fillRow(surface, row, self.selected);
        row += 1;
        switch (self.message.kind) {
            .user => drawWrapped(surface, self.message.body, StylePalette.user, self.selected, &row, ctx, 2, StylePalette.user),
            .agent => drawWrapped(surface, self.message.body, .{}, self.selected, &row, ctx, 0, null),
            .logo => drawLogo(surface, self.message.body, &row, ctx),
            .tool => {
                drawWrapped(surface, self.message.title, StylePalette.tool, self.selected, &row, ctx, 0, null);
                if (self.message.expanded) drawToolBody(surface, self.message, self.selected, &row, ctx);
            },
            .thinking => {
                drawLine(surface, self.message.title, StylePalette.thinking_label, self.selected, &row, ctx, 2, StylePalette.thinking_bar);
                if (self.message.expanded) drawWrapped(surface, self.message.body, StylePalette.thinking_body, self.selected, &row, ctx, 2, StylePalette.thinking_bar);
            },
            .status => drawLoading(surface, self.message.title, self.loading_frame, &row, ctx),
        }
        fillRow(surface, row, self.selected);
    }

    fn drawLoading(
        surface: *vxfw.Surface,
        text: []const u8,
        loading_frame: u8,
        row: *u16,
        ctx: vxfw.DrawContext,
    ) void {
        std.debug.assert(loading_frame < loading_frames.len);
        if (row.* >= surface.size.height) return;
        fillRow(surface, row.*, false);
        writeText(surface, loading_frames[loading_frame], StylePalette.thinking_label, false, row.*, ctx, 0);
        writeText(surface, text, StylePalette.thinking_body, false, row.*, ctx, 2);
        row.* += 1;
    }

    fn drawLogo(surface: *vxfw.Surface, text: []const u8, row: *u16, ctx: vxfw.DrawContext) void {
        var line_start: usize = 0;
        while (line_start <= text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            writeGradient(surface, text[line_start..line_end], row.*, ctx);
            row.* += 1;
            if (line_end == text.len) break;
            line_start = line_end + 1;
        }
    }

    fn drawWrapped(
        surface: *vxfw.Surface,
        text: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: *u16,
        ctx: vxfw.DrawContext,
        indent: u16,
        bar_style: ?vaxis.Style,
    ) void {
        const content_width = ConversationLayout.contentWidth(surface.size.width);
        const width = @max(@as(usize, content_width -| indent), 1);
        if (text.len == 0) {
            drawLine(surface, "", style, selected, row, ctx, indent, bar_style);
            return;
        }

        var line_start: usize = 0;
        while (line_start <= text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            if (line_start == line_end) {
                drawLine(surface, "", style, selected, row, ctx, indent, bar_style);
            } else {
                var chunk_start = line_start;
                while (chunk_start < line_end) {
                    const chunk_end = @min(chunk_start + width, line_end);
                    drawLine(surface, text[chunk_start..chunk_end], style, selected, row, ctx, indent, bar_style);
                    chunk_start = chunk_end;
                }
            }
            if (line_end == text.len) break;
            line_start = line_end + 1;
        }
    }

    fn drawLine(
        surface: *vxfw.Surface,
        text: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: *u16,
        ctx: vxfw.DrawContext,
        indent: u16,
        bar_style: ?vaxis.Style,
    ) void {
        if (row.* >= surface.size.height) return;
        fillRow(surface, row.*, selected);
        if (bar_style) |active_bar_style| writeText(surface, "┃", active_bar_style, selected, row.*, ctx, 0);
        writeText(surface, text, style, selected, row.*, ctx, indent);
        row.* += 1;
    }

    fn fillRow(surface: *vxfw.Surface, row: u16, selected: bool) void {
        if (!selected) return;
        var col: u16 = 0;
        while (col < surface.size.width) : (col += 1) {
            surface.writeCell(col, row, .{ .style = StylePalette.selected });
        }
    }

    fn writeText(
        surface: *vxfw.Surface,
        text: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: u16,
        ctx: vxfw.DrawContext,
        start_col: u16,
    ) void {
        var col = ConversationLayout.left + start_col;
        const col_limit = surface.size.width -| ConversationLayout.right;
        var iter = ctx.graphemeIterator(text);
        while (iter.next()) |grapheme| {
            if (col >= col_limit) return;
            const bytes = grapheme.bytes(text);
            const width: u8 = @intCast(ctx.stringWidth(bytes));
            if (width == 0) continue;
            if (col + width > col_limit) return;
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = bytes, .width = width },
                .style = mergedSelectedStyle(style, selected),
            });
            col += width;
        }
    }

    fn writeGradient(surface: *vxfw.Surface, text: []const u8, row: u16, ctx: vxfw.DrawContext) void {
        const gradient_width: u16 = @max(@min(ctx.stringWidth(text), std.math.maxInt(u16)), 1);
        var col: u16 = ConversationLayout.left;
        const col_limit = surface.size.width -| ConversationLayout.right;
        var iter = ctx.graphemeIterator(text);
        while (iter.next()) |grapheme| {
            if (col >= col_limit) return;
            const bytes = grapheme.bytes(text);
            const width: u8 = @intCast(ctx.stringWidth(bytes));
            if (width == 0) continue;
            if (col + width > col_limit) return;
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = bytes, .width = width },
                .style = gradientStyle(col - ConversationLayout.left, gradient_width, false),
            });
            col += width;
        }
    }
};

const InputWidget = struct {
    app: *App,

    fn widget(self: *InputWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawInput,
        };
    }

    fn drawInput(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *InputWidget = @ptrCast(@alignCast(ptr));
        const max_width = ctx.max.width orelse 0;
        const height: u16 = 3;

        var prompt: vxfw.Text = .{
            .text = ">",
            .softwrap = false,
            .width_basis = .parent,
        };
        var prompt_box: vxfw.SizedBox = .{
            .child = prompt.widget(),
            .size = .{ .width = 2, .height = 1 },
        };
        var input_box: vxfw.SizedBox = .{
            .child = self.app.input.widget(),
            .size = .{ .width = max_width -| 2, .height = 1 },
        };
        var row: vxfw.FlexRow = .{
            .children = &.{
                .{ .widget = prompt_box.widget(), .flex = 0 },
                .{ .widget = input_box.widget(), .flex = 1 },
            },
        };
        var row_box: vxfw.SizedBox = .{
            .child = row.widget(),
            .size = .{ .width = max_width -| 2, .height = 1 },
        };
        var border: vxfw.Border = .{
            .child = row_box.widget(),
            .style = StylePalette.thinking_body,
            .labels = &.{.{ .text = "Paladin", .alignment = .top_left }},
        };
        var box: vxfw.SizedBox = .{
            .child = border.widget(),
            .size = .{ .width = max_width, .height = height },
        };
        return box.widget().draw(ctx);
    }
};

const RowViewport = struct {
    first: u32,
    height: u16,
};

fn visibleRows(
    messages: []const thread_mod.Message,
    selected: ?u32,
    width: u16,
    height: u16,
) RowViewport {
    const total = threadRows(messages, width);
    if (total <= height) return .{ .first = 0, .height = height };

    const selected_index = selected orelse return .{
        .first = total - height,
        .height = height,
    };
    std.debug.assert(selected_index < messages.len);

    const last_index: u32 = @intCast(messages.len - 1);
    if (selected_index == last_index) {
        return .{ .first = total - height, .height = height };
    }

    const selected_start = messageStartRow(messages, selected_index, width);
    const selected_rows = messageRows(messages[selected_index], width);
    const selected_end = selected_start + selected_rows;
    if (selected_rows >= height) {
        return .{ .first = selected_start, .height = height };
    }
    if (selected_end <= height) {
        return .{ .first = 0, .height = height };
    }
    return .{ .first = selected_end - height, .height = height };
}

fn drawToolBody(
    surface: *vxfw.Surface,
    message: thread_mod.Message,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
) void {
    if (message.body.len > 0) {
        switch (message.tool_render) {
            .plain => MessageWidget.drawWrapped(surface, message.body, StylePalette.thinking_body, selected, row, ctx, 0, null),
            .diff => drawWrappedDiff(surface, message.body, selected, row, ctx),
        }
    }
    if (message.stderr_body) |stderr| {
        MessageWidget.drawWrapped(surface, stderr, StylePalette.tool_failed, selected, row, ctx, 0, null);
    }
}

fn drawWrappedDiff(
    surface: *vxfw.Surface,
    text: []const u8,
    selected: bool,
    row: *u16,
    ctx: vxfw.DrawContext,
) void {
    const content_width = ConversationLayout.contentWidth(surface.size.width);
    const width = @max(@as(usize, content_width), 1);
    if (text.len == 0) {
        MessageWidget.drawLine(surface, "", StylePalette.thinking_body, selected, row, ctx, 0, null);
        return;
    }

    var line_start: usize = 0;
    while (line_start <= text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        const style = diffLineStyle(line);
        if (line.len == 0) {
            MessageWidget.drawLine(surface, "", style, selected, row, ctx, 0, null);
        } else {
            var chunk_start: usize = 0;
            while (chunk_start < line.len) {
                const chunk_end = @min(chunk_start + width, line.len);
                MessageWidget.drawLine(surface, line[chunk_start..chunk_end], style, selected, row, ctx, 0, null);
                chunk_start = chunk_end;
            }
        }
        if (line_end == text.len) break;
        line_start = line_end + 1;
    }
}

fn diffLineStyle(line: []const u8) vaxis.Style {
    if (line.len == 0) return StylePalette.thinking_body;
    return switch (line[0]) {
        '+' => StylePalette.tool,
        '-' => StylePalette.tool_failed,
        else => StylePalette.thinking_body,
    };
}

const StylePalette = struct {
    const thinking_blue = .{ 96, 165, 250 };
    const user_yellow = .{ 212, 175, 55 };

    const selected: vaxis.Style = .{ .bg = .{ .rgb = .{ 38, 38, 38 } } };
    const user: vaxis.Style = .{ .fg = .{ .rgb = user_yellow }, .italic = true };
    const tool: vaxis.Style = .{ .fg = .{ .rgb = .{ 34, 197, 94 } } };
    const tool_failed: vaxis.Style = .{ .fg = .{ .rgb = .{ 239, 68, 68 } } };
    const thinking_label: vaxis.Style = .{ .fg = .{ .rgb = thinking_blue } };
    const thinking_body: vaxis.Style = .{ .fg = .{ .rgb = .{ 138, 138, 138 } } };
    const thinking_bar: vaxis.Style = .{ .fg = .{ .rgb = thinking_blue } };
};

fn mergedSelectedStyle(style: vaxis.Style, selected: bool) vaxis.Style {
    var merged = style;
    if (selected) merged.bg = StylePalette.selected.bg;
    return merged;
}

fn gradientStyle(col: u16, width: u16, selected: bool) vaxis.Style {
    std.debug.assert(width > 0);
    const denominator: u32 = @max(@as(u32, width) - 1, 1);
    const numerator: u32 = @min(@as(u32, col), denominator);
    const yellow = .{ 252, 211, 77 };
    const orange = .{ 249, 115, 22 };
    return mergedSelectedStyle(.{ .fg = .{ .rgb = .{
        gradientChannel(yellow[0], orange[0], numerator, denominator),
        gradientChannel(yellow[1], orange[1], numerator, denominator),
        gradientChannel(yellow[2], orange[2], numerator, denominator),
    } } }, selected);
}

fn gradientChannel(start: u8, end: u8, numerator: u32, denominator: u32) u8 {
    std.debug.assert(denominator > 0);
    const start_value: u32 = start;
    const end_value: u32 = end;
    if (end_value >= start_value) {
        return @intCast(start_value + ((end_value - start_value) * numerator) / denominator);
    }
    return @intCast(start_value - ((start_value - end_value) * numerator) / denominator);
}

fn firstVisibleMessage(
    messages: []const thread_mod.Message,
    selected: ?u32,
    width: u16,
    height: u16,
) u32 {
    const first_row = visibleRows(messages, selected, width, height).first;
    var row: u32 = 0;
    var index: u32 = 0;
    while (index < messages.len) : (index += 1) {
        const next = row + messageRows(messages[index], width);
        if (next > first_row) return index;
        row = next;
    }
    return 0;
}

fn threadRows(messages: []const thread_mod.Message, width: u16) u32 {
    var rows: u32 = 0;
    for (messages) |message| {
        rows += messageRows(message, width);
    }
    return rows;
}

fn messageStartRow(messages: []const thread_mod.Message, index: u32, width: u16) u32 {
    std.debug.assert(index < messages.len);
    var rows: u32 = 0;
    var current: u32 = 0;
    while (current < index) : (current += 1) {
        rows += messageRows(messages[current], width);
    }
    return rows;
}

fn messageRows(message: thread_mod.Message, width: u16) u16 {
    return messageContentRows(message, width) + 2;
}

fn messageContentRows(message: thread_mod.Message, width: u16) u16 {
    return switch (message.kind) {
        .user => textRows(message.body, width -| 2),
        .agent => textRows(message.body, width),
        .logo => logoRows(message.body),
        .thinking => if (message.expanded)
            1 + textRows(message.body, width -| 2)
        else
            1,
        .status => 1,
        .tool => if (message.expanded)
            textRows(message.title, width) + toolBodyRows(message, width)
        else
            textRows(message.title, width),
    };
}

fn toolBodyRows(message: thread_mod.Message, width: u16) u16 {
    var rows: u16 = 0;
    if (message.body.len > 0) rows += textRows(message.body, width);
    if (message.stderr_body) |stderr| rows += textRows(stderr, width);
    return rows;
}

fn logoRows(text: []const u8) u16 {
    if (text.len == 0) return 1;
    var rows: u16 = 1;
    for (text) |byte| {
        if (byte == '\n') rows += 1;
    }
    return rows;
}

fn textRows(text: []const u8, width: u16) u16 {
    if (text.len == 0) return 1;
    const row_width = @max(@as(usize, width), 1);
    var rows: u16 = 1;
    var col: usize = 0;
    for (text) |byte| {
        if (byte == '\n') {
            rows += 1;
            col = 0;
            continue;
        }

        if (col >= row_width) {
            rows += 1;
            col = 0;
        }
        col += 1;
    }
    return rows;
}

test "begin submit clears input and appends loading row before agent turn" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    const loading_index = (try app.beginSubmit()).?;

    try std.testing.expectEqual(@as(usize, 0), app.input.buf.firstHalf().len);
    try std.testing.expectEqual(@as(usize, 0), app.input.buf.secondHalf().len);
    try std.testing.expectEqualStrings("hello", app.thread.messages.items[0].body);
    try std.testing.expectEqual(.status, app.thread.messages.items[loading_index].kind);
    try std.testing.expect(isLoadingWord(app.thread.messages.items[loading_index].title));
    try std.testing.expectEqual(@as(u16, 3), messageRows(app.thread.messages.items[loading_index], 80));
    try std.testing.expectEqual(@as(u32, 0), app.thread.selected.?);
}

fn isLoadingWord(text: []const u8) bool {
    for (loading_spinners) |loading_spinner| {
        if (std.mem.eql(u8, text, loading_spinner)) return true;
    }
    return false;
}

test "empty text deltas do not create selectable messages" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .response_delta = "" }));
    try std.testing.expectEqual(@as(usize, 1), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);

    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = "" }));
    try std.testing.expectEqual(@as(usize, 1), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
}

test "agent app events update thread on the ui side" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = "checking" }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = " files" }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\n\nstderr:\n",
    } }));

    try std.testing.expectEqual(@as(usize, 3), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.thinking, app.thread.messages.items[1].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[2].kind);
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);
    try std.testing.expectEqualStrings("checking files", app.thread.messages.items[1].body);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[2].title);
}

test "user can navigate away from a streaming thinking block" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    _ = try app.applyAgentEvent(.{ .thinking_delta = "first chunk" });
    try std.testing.expectEqual(.thinking, app.thread.messages.items[app.thread.selected.?].kind);

    app.thread.moveSelection(.previous);
    try std.testing.expectEqual(.user, app.thread.messages.items[app.thread.selected.?].kind);

    _ = try app.applyAgentEvent(.{ .thinking_delta = " more" });
    try std.testing.expectEqual(.user, app.thread.messages.items[app.thread.selected.?].kind);
}

test "user can navigate away from a streaming agent message" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    _ = try app.applyAgentEvent(.{ .response_delta = "first chunk" });
    try std.testing.expectEqual(.agent, app.thread.messages.items[app.thread.selected.?].kind);

    app.thread.moveSelection(.previous);
    try std.testing.expectEqual(.user, app.thread.messages.items[app.thread.selected.?].kind);

    _ = try app.applyAgentEvent(.{ .response_delta = " more" });
    try std.testing.expectEqual(.user, app.thread.messages.items[app.thread.selected.?].kind);
}

test "empty content delta does not finalize thinking" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    _ = try app.applyAgentEvent(.{ .thinking_delta = "thinking" });
    const thinking_index = app.thinking_index.?;
    try std.testing.expectEqualStrings("Thinking...", app.thread.messages.items[thinking_index].title);

    _ = try app.applyAgentEvent(.{ .response_delta = "" });
    try std.testing.expectEqualStrings("Thinking...", app.thread.messages.items[thinking_index].title);

    _ = try app.applyAgentEvent(.{ .thinking_delta = " more" });
    try std.testing.expectEqualStrings("Thinking...", app.thread.messages.items[thinking_index].title);

    _ = try app.applyAgentEvent(.{ .response_delta = "answer" });
    try std.testing.expectEqualStrings("Thoughts", app.thread.messages.items[thinking_index].title);
}

test "content deltas do not override user scroll state" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    _ = try app.applyAgentEvent(.{ .response_delta = "first" });
    try std.testing.expect(app.thread_auto_scroll);

    app.thread_auto_scroll = false;
    _ = try app.applyAgentEvent(.{ .response_delta = " second" });
    try std.testing.expect(!app.thread_auto_scroll);
}

test "loading does not appear during final answer after tool batch" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("inspect");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    try std.testing.expectEqual(.status, app.thread.messages.items[2].kind);

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "Final answer" }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(usize, 3), app.thread.messages.items.len);
    try std.testing.expectEqual(.agent, app.thread.messages.items[2].kind);
}

test "loading does not reappear between content chunks" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("implement dijkstra");
    _ = (try app.beginSubmit()).?;

    // Once a content delta has arrived we are committed to streaming. The gap
    // between chunks must NOT bring the spinner back — the streaming text is
    // its own progress indicator.
    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "Here's the implementation plan:" }));
    _ = try app.applyAgentEvent(.delta_end);
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.agent, app.thread.messages.items[1].kind);
}

test "structured tool keeps loading status while arguments stream" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("write file");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "write_file",
        .arguments = "{\"path\":\"main.zig\",\"content\":\"const std = @import(\\\"std\\\");",
    } }));
    try std.testing.expectEqual(@as(usize, 3), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.status, app.thread.messages.items[1].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[2].kind);

    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "write_file",
        .display_label = "write_file {\"path\":\"main.zig\",\"content\":\"const std = @import(\\\"std\\\");\"}",
        .display_body = "Successfully wrote 27 bytes to main.zig\n",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
}

test "tool row persists through finish and turn completion" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run ls");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[1].title);

    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[1].title);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[1].title);

    try std.testing.expect(try app.applyAgentEvent(.turn_finished));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[1].title);
}

test "partial tool arguments do not create visible tool rows" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run ls");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.status, app.thread.messages.items[1].kind);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[1].title);
}

test "tool finish creates row if no complete streamed arguments appeared" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run ls");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));

    try std.testing.expectEqual(@as(usize, 2), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[1].title);
}

test "new tool response index creates a new thread row" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run tools");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));

    try std.testing.expectEqual(@as(usize, 3), app.thread.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[2].kind);
    try std.testing.expectEqualStrings("$ ls", app.thread.messages.items[1].title);
    try std.testing.expectEqualStrings("$ pwd", app.thread.messages.items[2].title);
}

test "late tool finish does not move selection upward" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run tools");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expectEqual(@as(u32, 1), app.thread.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 1,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "done" }));
    try std.testing.expectEqual(@as(u32, 3), app.thread.selected.?);
}

test "loading does not resume after post-tool thinking delta" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("inspect");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));

    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = "checking output" }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));

    try std.testing.expectEqual(@as(usize, 3), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[1].kind);
    try std.testing.expectEqual(.thinking, app.thread.messages.items[2].kind);
    try std.testing.expectEqualStrings("Thinking...", app.thread.messages.items[2].title);
}

test "agent response after tool batch appears below tool rows" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("inspect");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "I will check." }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "The repo is in /tmp." }));

    try std.testing.expectEqual(@as(usize, 4), app.thread.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.messages.items[0].kind);
    try std.testing.expectEqual(.agent, app.thread.messages.items[1].kind);
    try std.testing.expectEqual(.tool, app.thread.messages.items[2].kind);
    try std.testing.expectEqual(.agent, app.thread.messages.items[3].kind);
    try std.testing.expectEqualStrings("I will check.", app.thread.messages.items[1].body);
    try std.testing.expectEqualStrings("$ pwd", app.thread.messages.items[2].title);
    try std.testing.expectEqualStrings("The repo is in /tmp.", app.thread.messages.items[3].body);
    try std.testing.expectEqual(@as(u32, 3), app.thread.selected.?);
}

test "content delta after tool preview does not move selection away from tool row" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("inspect");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "I will check." }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(u32, 1), app.thread.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = " Still checking." }));
    _ = try app.applyAgentEvent(.delta_end);
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = "bash",
        .display_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.thread.selected.?);
    try std.testing.expectEqualStrings("I will check. Still checking.", app.thread.messages.items[1].body);
    try std.testing.expectEqualStrings("$ pwd", app.thread.messages.items[2].title);
}

test "collapsed thinking and tool rows have stable heights" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    const thinking_index = try thread.append(gpa, .thinking, "Thinking...", "short");
    try std.testing.expectEqual(@as(u16, 3), messageRows(thread.messages.items[thinking_index], 80));

    try thread.appendThinkingDelta(gpa, thinking_index, " ");
    try thread.appendThinkingDelta(gpa, thinking_index, "this is a much longer thinking body that should not change the collapsed row height");
    try std.testing.expectEqual(@as(u16, 3), messageRows(thread.messages.items[thinking_index], 80));

    const tool_index = try thread.startTool(gpa, "pwd");
    try std.testing.expectEqual(@as(u16, 3), messageRows(thread.messages.items[tool_index], 80));
}

test "first visible message tracks bottom viewport row" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    _ = try thread.append(gpa, .user, "you", "one");
    _ = try thread.append(gpa, .agent, "agent", "two");
    _ = try thread.append(gpa, .agent, "agent", "three");

    try std.testing.expectEqual(
        @as(u32, 1),
        firstVisibleMessage(thread.messages.items, thread.selected, 80, 6),
    );
}

test "latest tall message scrolls by rows instead of message boundaries" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    _ = try thread.append(gpa, .agent, "agent", "one");
    _ = try thread.append(gpa, .agent, "agent", "line1\nline2\nline3\nline4\nline5\nline6");

    const viewport = visibleRows(thread.messages.items, thread.selected, 80, 4);
    try std.testing.expectEqual(@as(u32, 7), viewport.first);
    try std.testing.expectEqual(@as(u32, 11), threadRows(thread.messages.items, 80));
}

test "collapsed tool title wraps to visible rows" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    const index = try thread.startTool(gpa, "edit_file {\"input\":\"a very long patch document\"}");
    try std.testing.expect(!thread.messages.items[index].expanded);
    try std.testing.expect(messageRows(thread.messages.items[index], 12) > 3);
}

test "collapsed tool messages render no body text" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    const index = try thread.startTool(gpa, "printf hello");
    try thread.finishTool(gpa, index, "hello", null, false);

    try std.testing.expect(!thread.messages.items[index].expanded);
    try std.testing.expectEqual(@as(u16, 3), messageRows(thread.messages.items[index], 80));
    thread.toggleSelected();
    try std.testing.expect(thread.messages.items[index].expanded);
    try std.testing.expectEqualStrings("hello", thread.messages.items[index].body);
}

test "selected collapsed tools stay visible for tight viewport heights" {
    const gpa = std.testing.allocator;
    var thread: thread_mod.Thread = .{};
    defer thread.deinit(gpa);

    _ = try thread.append(gpa, .agent, "agent", "one two three four five six seven eight nine ten");
    const tool_index = try thread.startTool(gpa, "zig build test");
    _ = try thread.append(gpa, .agent, "agent", "done");

    thread.selected = tool_index;
    var height: u16 = 1;
    while (height <= 8) : (height += 1) {
        const first = firstVisibleMessage(thread.messages.items, thread.selected, 12, height);
        try std.testing.expect(first <= tool_index);
        try std.testing.expect(selectedRowFits(thread.messages.items, thread.selected.?, 12, height));
    }
}

fn selectedRowFits(
    messages: []const thread_mod.Message,
    selected: u32,
    width: u16,
    height: u16,
) bool {
    const viewport = visibleRows(messages, selected, width, height);
    const selected_start = messageStartRow(messages, selected, width);
    const selected_end = selected_start + messageRows(messages[selected], width);
    const viewport_end = viewport.first + viewport.height;
    return selected_start < viewport_end and selected_end > viewport.first;
}
