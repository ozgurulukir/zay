//! Queue management: enqueue, flush, and navigate queued user messages.
//! Free functions taking `*App` — extracted from `tui.zig`.

const std = @import("std");

const tui = @import("../tui.zig");
const skill_mod = @import("../skill.zig");

const App = tui.App;
const Thread = tui.Thread;

fn appendMessageQueueFullNotice(app: *App) !void {
    _ = try app.thread.transcript.append(app.gpa, .notice, "notice", "MessageQueueFull");
}

pub fn appendSkillInvocationsToTranscript(app: *App, prompt: []const u8) !void {
    const runtime = app.liveRuntime() orelse return;
    const names = try skill_mod.collectInvocations(app.gpa, runtime.skills, prompt);
    defer app.gpa.free(names);
    for (names) |name| {
        const title = try std.fmt.allocPrint(app.gpa, "[SKILL] {s}", .{name});
        defer app.gpa.free(title);
        _ = try app.thread.transcript.append(app.gpa, .skill, title, "");
    }
}

pub fn enqueueSubmit(app: *App) !bool {
    const prompt = try app.inputs.input.buf.dupe();
    errdefer app.gpa.free(prompt);
    if (prompt.len == 0) {
        app.gpa.free(prompt);
        return false;
    }
    app.thread.agent.?.enqueueUser(prompt) catch |err| switch (err) {
        error.QueueFull => {
            app.gpa.free(prompt);
            try appendMessageQueueFullNotice(app);
            return false;
        },
        else => return err,
    };
    try app.thread.queued.append(app.gpa, .{ .text = prompt });
    app.nav.queued_selection = app.thread.queued.items.len - 1;
    app.clearInput();
    return false;
}

pub fn selectPrevQueued(app: *App) void {
    if (app.thread.queued.items.len == 0) return;
    if (app.nav.queued_selection > 0) app.nav.queued_selection -= 1;
}

pub fn selectNextQueued(app: *App) void {
    const len = app.thread.queued.items.len;
    if (len == 0) return;
    if (app.nav.queued_selection + 1 < len) app.nav.queued_selection += 1;
}

pub fn steerSelectedQueued(app: *App) void {
    const items = app.thread.queued.items;
    if (items.len == 0) return;
    const index = @min(app.nav.queued_selection, items.len - 1);
    items[index].steer = true;
    app.thread.agent.?.setQueuedSteer(@intCast(index));
}

pub fn flushQueuedUserMessagesToTranscript(app: *App, count: u32) !void {
    const flush_count: usize = @min(count, app.thread.queued.items.len);
    for (app.thread.queued.items[0..flush_count]) |message| {
        _ = try app.thread.transcript.append(app.gpa, .user, "you", message.text);
        try appendSkillInvocationsToTranscript(app, message.text);
        app.gpa.free(message.text);
    }
    std.mem.copyForwards(Thread.QueuedMessage, app.thread.queued.items[0 .. app.thread.queued.items.len - flush_count], app.thread.queued.items[flush_count..]);
    app.thread.queued.shrinkRetainingCapacity(app.thread.queued.items.len - flush_count);
    app.nav.queued_selection -|= flush_count;
}

pub fn clearQueuedUserMessages(app: *App) void {
    for (app.thread.queued.items) |message| app.gpa.free(message.text);
    app.thread.queued.clearRetainingCapacity();
    app.nav.queued_selection = 0;
}
