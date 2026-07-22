//! Transcript and session conversation rebuilding logic.
//! Free functions taking `*App` — extracted from `tui.zig`.

const std = @import("std");
const tui = @import("../tui.zig");
const ai = @import("../ai.zig");
const agent_mod = @import("../agent.zig");
const transcript_mod = @import("../transcript.zig");
const runtime_mod = @import("../runtime.zig");

const App = tui.App;

pub fn installRuntime(app: *App, runtime: *runtime_mod.AgentRuntime) !void {
    if (app.thread.turn.isActive()) return error.InFlightTurn;
    app.cancelLaneNaming(app.thread);
    if (app.liveRuntime()) |old| {
        old.deinit();
        app.gpa.destroy(old);
    }
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = runtime, .owns = true } };
    app.thread.agent = &runtime.agent;
    app.thread.id = runtime.session_writer.session.id;
    // The label belongs to the departed session; the next first prompt
    // re-derives it.
    if (app.thread.title) |title| app.gpa.free(title);
    app.thread.title = null;
    // Load prompt history from the session DB.
    app.thread.prompt_history_index = null;
    app.thread.prompt_history.deinit(app.gpa);
    app.thread.prompt_history = .empty;
    if (runtime.session_writer.loadPromptHistory(app.gpa)) |prompts| {
        // loadPromptHistory returns newest-first; reverse to oldest-first.
        var i: usize = prompts.len;
        while (i > 0) {
            i -= 1;
            app.thread.prompt_history.append(app.gpa, prompts[i]) catch {};
        }
        app.gpa.free(prompts);
    } else |_| {}
    app.mode = .normal;
    app.clearInput();
    app.resetTurnState();
}

pub fn clearConversation(app: *App) !void {
    if (app.thread.transcript.messages.items.len > 0) {
        try app.retired_transcripts.append(app.gpa, app.thread.transcript);
    }
    app.thread.transcript = .{};
    app.thread.transcript_list.scroll = .{};
}

pub fn rebuildTranscriptFromAgent(app: *App) !void {
    try clearConversation(app);
    for (app.thread.agent.?.messages()) |message| {
        if (message.role == .system) continue;
        const text = message.text();
        if (message.role == .user) {
            _ = try app.thread.transcript.append(app.gpa, .user, "you", text);
        } else if (message.role == .assistant) {
            if (text.len > 0) _ = try app.thread.transcript.append(app.gpa, .agent, "agent", text);
        } else if (message.role == .tool) {
            const title = try resumedToolTitle(app, message);
            defer app.gpa.free(title);
            const index = try app.thread.transcript.append(app.gpa, .tool, title, text);
            app.thread.transcript.messages.items[index].failed = message.tool_failed;
        }
    }
    if (app.thread.transcript.messages.items.len > 0) app.thread.transcript.selected = @intCast(app.thread.transcript.messages.items.len - 1);
    // A freshly installed (resumed) session left the label unset; re-derive
    // it from the conversation's first user message.
    if (app.thread.title == null) {
        for (app.thread.agent.?.messages()) |message| {
            if (message.role != .user) continue;
            try app.setLaneTitleIfUnset(message.text());
            break;
        }
    }
}

pub fn resumedToolTitle(app: *App, message: ai.ChatMessage) ![]u8 {
    if (message.tool_display_label) |label| return transcript_mod.toolTitle(app.gpa, label);
    const id = message.call_id orelse return transcript_mod.toolTitle(app.gpa, "tool");
    for (app.thread.agent.?.messages()) |candidate| {
        for (candidate.content) |block| {
            if (block != .tool_call) continue;
            if (!std.mem.eql(u8, block.tool_call.call_id, id)) continue;
            var display = try agent_mod.formatToolDisplay(app.gpa, block.tool_call.name, block.tool_call.arguments);
            defer display.deinit(app.gpa);
            return transcript_mod.toolTitle(app.gpa, display.label);
        }
    }
    return transcript_mod.toolTitle(app.gpa, id);
}
