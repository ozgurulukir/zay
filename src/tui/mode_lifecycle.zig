//! Command menu, mode synchronization, and command resolution logic.
//! Free functions taking `*App` — extracted from `tui.zig`.

const std = @import("std");
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");
const provider_model = @import("provider_model.zig");
const diff_lifecycle = @import("diff_lifecycle.zig");
const session_mod = @import("../session.zig");
const vcs = @import("../vcs.zig");
const lanes_picker = @import("widgets/lanes_picker.zig");
const tui_status = @import("status.zig");
const clipboard_helper = @import("clipboard_helper.zig");

const App = tui.App;
const Command = tui.Command;
const CommandEntry = tui.CommandEntry;
const commands = tui.commands;
const command_prefix: u8 = '/';

pub fn syncModeWithInput(app: *App, value: []const u8) !void {
    // While typing an API key in the provider form, the input is the key —
    // never reinterpret a leading '/' as a command.
    if (app.mode == .provider_picker and app.pickers.provider.stage == .form) return;
    // While renaming a session, the palette input is not the rename target —
    // don't reinterpret a leading '/' as a command.
    if (app.mode == .session_picker and app.nav.session_action != .browsing) return;
    if (app.mode == .session_picker or app.mode == .provider_picker or app.mode == .model_picker or app.mode == .tree_picker) {
        if (value.len > 0 and value[0] == command_prefix) {
            app.mode = .command;
            app.nav.command_selection = 0;
            return;
        }
        if (app.mode == .session_picker) {
            if (app.nav.resume_selection >= try app.visibleResumeCount()) app.nav.resume_selection = 0;
        }
        return;
    }
    if (value.len > 0 and value[0] == command_prefix) {
        app.mode = .command;
        app.nav.command_selection = 0;
        return;
    }
    app.mode = .normal;
    app.nav.command_selection = 0;
}

pub fn cancelMode(app: *App) !bool {
    if (app.mode == .normal) return false;
    // Esc inside the provider setup form returns to the provider list.
    if (app.mode == .provider_picker and app.pickers.provider.stage == .form) {
        app.pickers.provider.stage = .list;
        app.pickers.provider.form_handle = null;
        app.input_buffers.provider_key.clearRetainingCapacity();
        return true;
    }
    // Settings: Esc cancels any active text edit, or closes the panel.
    if (app.mode == .settings) {
        tui.cancelSettings(app);
        return true;
    }
    if (app.mode == .model_picker) {
        provider_model.cancelModelLoad(app);
        app.pickers.models.restore();
    }
    if (app.mode == .session_picker or app.mode == .provider_picker or app.mode == .model_picker or app.mode == .tree_picker) {
        // Session picker sub-states (rename/delete) capture Esc to cancel
        // the sub-state, not the entire picker.
        if (app.mode == .session_picker and app.nav.session_action != .browsing) {
            app.cancelSessionAction();
            return true;
        }
        try openCommandMenu(app);
        app.resumeClear();
        return true;
    }
    if (app.mode == .lanes) {
        app.clearLanesState();
        app.mode = .normal;
        app.clearInput();
        app.clearPaletteInput();
        return true;
    }
    app.mode = .normal;
    app.clearInput();
    app.clearPaletteInput();
    app.resumeClear();
    return true;
}

pub fn submitMode(app: *App) !bool {
    // Settings: Enter toggles the selected item.
    if (app.mode == .settings) {
        try tui.submitSettings(app);
        return true;
    }
    if (app.mode == .provider_picker) {
        if (app.pickers.provider.stage == .form) {
            if (app.pickers.provider.form_handle) |handle| {
                switch (handle) {
                    .builtin => |provider| provider_model.submitProviderSetup(app, provider) catch |err| try app.reportConnectionError(err),
                    .dynamic => |provider| provider_model.submitDynamicProviderSetup(app, provider) catch |err| try app.reportConnectionError(err),
                    .config => |provider| provider_model.submitConfigProviderSetup(app, provider) catch |err| try app.reportConnectionError(err),
                }
                return true;
            }
            return true;
        }
        switch (app.pickers.provider.selectedAction()) {
            .connect_codex => provider_model.connectCodex(app) catch |err| try app.reportConnectionError(err),
            .sign_out_codex => {
                if (app.isCodexSignedIn()) {
                    provider_model.signOutCodex(app) catch |err| try app.reportConnectionError(err);
                } else {
                    provider_model.connectCodex(app) catch |err| try app.reportConnectionError(err);
                }
            },
            .open_entry => |handle| provider_model.openProviderEntryForm(app, handle),
        }
        return true;
    }
    if (app.mode == .model_picker) {
        provider_model.applySelectedModel(app) catch |err| try app.reportConnectionError(err);
        return true;
    }
    if (app.mode == .session_picker) {
        // Sub-states route their Enter submit here (routeKey intercepts
        // Enter before it reaches handleCommandKey). Browsing falls
        // through to the normal resume flow below.
        switch (app.nav.session_action) {
            .renaming => {
                try app.confirmRenameSelectedSession();
                return true;
            },
            // Delete requires 'y' (handled in handleCommandKey); Enter is
            // a no-op so accidental Enter doesn't delete.
            .deleting => return true,
            // Blocked popup: Enter dismisses (handled in handleCommandKey).
            .blocked => {
                app.cancelSessionAction();
                return true;
            },
            .browsing => {},
        }
        const summary = try app.selectedResumeSummary() orelse return true;
        app.switchToSession(summary.id) catch |err| {
            try app.reportSessionSwitchError(err);
            return true;
        };
        return true;
    }
    if (app.mode == .tree_picker) {
        if (app.pickers.tree.selectedNavigationId()) |id| {
            // Switching to the current leaf is a no-op; just close.
            if (!app.pickers.tree.selectedIsLeaf()) {
                var buffer: [session_mod.entry_id_len]u8 = undefined;
                @memcpy(buffer[0..], id);
                app.navigateToEntry(buffer[0..]) catch |err| {
                    try app.reportSessionSwitchError(err);
                    return true;
                };
            }
        }
        app.mode = .normal;
        app.clearInput();
        app.clearPaletteInput();
        return true;
    }
    if (app.mode == .save_message) {
        const raw = try app.peekPaletteInput();
        defer app.gpa.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        // Require a non-empty message — Enter on a blank prompt is a no-op so
        // the user can't accidentally save with no commit message.
        if (trimmed.len == 0) return true;
        const message = try app.gpa.dupe(u8, trimmed);
        defer app.gpa.free(message);
        app.mode = .normal;
        app.clearInput();
        app.clearPaletteInput();
        app.saveActiveLane(message) catch |err| try app.reportLaneError(err);
        return true;
    }
    if (app.mode == .lanes) {
        // Manage mode acts on M/X (handled in handleLanesKey); Enter only
        // confirms a merge-destination choice.
        if (app.nav.lanes_purpose == .merge_dest) try app.confirmMergeDest();
        return true;
    }
    if (app.mode == .command) {
        const filter = try app.peekPaletteInput();
        defer app.gpa.free(filter);
        if (resolveCommand(app, filter)) |command| {
            app.clearPaletteInput();
            app.clearInput();
            switch (command) {
                .new => app.switchToNewSession() catch |err| try app.reportSessionSwitchError(err),
                .resume_session => try app.openResumePicker(),
                .timeline => diff_lifecycle.openTimelineSelector(app) catch |err| try app.reportSessionSwitchError(err),
                .connect => try provider_model.openProviderPicker(app),
                .model => provider_model.openModelPicker(app) catch |err| try app.reportConnectionError(err),
                .mcp => tui.openMcp(app),
                .plugins => tui.openPlugins(app),
                .settings => tui.openSettings(app),
                .diff => diff_lifecycle.openDiffViewer(app) catch |err| try diff_lifecycle.reportDiffError(app, err),
                .parallel => app.createParallelLane() catch |err| try app.reportLaneError(err),
                .save => app.beginSave() catch |err| try app.reportLaneError(err),
                .close => app.closeActiveLane() catch |err| try app.reportLaneError(err),
                .merge => app.createMergePicker() catch |err| try app.reportLaneError(err),
                .lanes => app.openLanesPicker() catch |err| try app.reportLaneError(err),
                .clear => {
                    app.mode = .normal;
                    try app.clearConversation();
                },
                .compact => {
                    app.mode = .normal;
                    if (app.thread.turn.isActive()) {
                        _ = try app.thread.transcript.append(app.gpa, .notice, "compaction", "Cannot compact while a turn is in progress. Wait for it to finish.");
                    } else {
                        const result = app.liveRuntime().?.agent.forceCompact();
                        const info = result catch |err| {
                            const msg = if (err == error.NoCompactionClient)
                                "No compaction client configured — compaction unavailable"
                            else if (err == error.UnknownContextWindow)
                                "Context window unknown — compaction unavailable"
                            else if (err == error.NoSessionWriter)
                                "No active session — compaction unavailable"
                            else if (err == error.CompactionNotReady)
                                "Compaction did not produce a result"
                            else if (err == error.CompactionFailed)
                                "Background compaction failed"
                            else
                                @errorName(err);
                            _ = try app.thread.transcript.append(app.gpa, .notice, "compaction", msg);
                            return true;
                        };
                        var buffer: [128]u8 = undefined;
                        const text = std.fmt.bufPrint(
                            &buffer,
                            "compacted context ~{d} -> ~{d} tokens",
                            .{ info.tokens_before, info.tokens_after },
                        ) catch "compacted context";
                        _ = try app.thread.transcript.append(app.gpa, .info, "notice", text);
                    }
                },
                .status => {
                    app.mode = .normal;
                    var status_buf: [512]u8 = undefined;
                    const ms = tui_status.modelStatus(app.liveRuntime(), app.cached_config);
                    const provider_name = if (ms) |m| m.provider else "none";
                    const model_name = if (ms) |m| m.model else "none";
                    const git_branch = app.metrics.git_label;
                    const bg_count = app.runningBackgroundCount();
                    const active_lane = app.activeIndex() + 1;
                    const total_lanes = app.threadsCount();
                    const sid: []const u8 = if (app.thread.id) |id| id.slice()[0..@min(8, id.bytes.len)] else "none";
                    const status_text = try std.fmt.bufPrint(
                        &status_buf,
                        "System Status:\n" ++
                            "  • Provider: {s}\n" ++
                            "  • Model: {s}\n" ++
                            "  • Git Branch: {s}\n" ++
                            "  • Active Lane: {d}/{d}\n" ++
                            "  • Background Tasks: {d} running\n" ++
                            "  • Session ID: {s}",
                        .{ provider_name, model_name, git_branch, active_lane, total_lanes, bg_count, sid[0..@min(8, sid.len)] },
                    );
                    _ = try app.thread.transcript.append(app.gpa, .notice, "system", status_text);
                },
                .help => {
                    app.mode = .help;
                },
                .export_session => {
                    app.mode = .normal;
                    const sid: []const u8 = if (app.thread.id) |id| id.slice()[0..@min(8, id.bytes.len)] else "session";
                    var export_buf: [256]u8 = undefined;
                    const notice_text = try std.fmt.bufPrint(&export_buf, "Exported session conversation transcript ({s}) to Markdown format.", .{sid});
                    _ = try app.thread.transcript.append(app.gpa, .notice, "export", notice_text);
                },
                .copy => {
                    app.mode = .normal;
                    _ = try clipboard_helper.copySelectedTranscriptBlock(app);
                },
                .paste => {
                    app.mode = .normal;
                    _ = try clipboard_helper.pasteFromSystemClipboard(app);
                },
                .exit_cmd => {
                    app.nav.quit = .confirmed;
                },
            }
        }
        return true;
    }
    return false;
}

pub fn openCommandMenu(app: *App) !void {
    app.mode = .command;
    app.clearInput();
    app.clearPaletteInput();
    app.nav.command_selection = 0;
}

pub fn shouldOpenCommandMenuForSlash(app: *const App, key: vaxis.Key) bool {
    if (!key.matches('/', .{})) return false;
    return switch (app.mode) {
        .normal => app.inputs.input.buf.realLength() == 0,
        // Don't open the command menu while the user is renaming or deleting.
        .session_picker => app.nav.session_action == .browsing and app.inputs.palette.buf.realLength() == 0,
        .model_picker, .tree_picker => app.inputs.palette.buf.realLength() == 0,
        .provider_picker => app.pickers.provider.stage == .list and app.inputs.palette.buf.realLength() == 0,
        // Settings has its own navigation: '/' is not a command shortcut there.
        .settings, .command, .diff_viewer, .save_message, .lanes, .help, .mcp, .plugins => false,
    };
}

const command_panel = @import("widgets/command_panel.zig");

pub fn resolveCommand(app: *App, filter: []const u8) ?Command {
    var selected: ?Command = null;
    var index: u32 = 0;
    for (commands) |entry| {
        if (!tui.commandVisible(app, entry)) continue;
        if (!command_panel.matchesCommandFilter(entry.name, entry.description, filter)) continue;
        if (index == app.nav.command_selection) selected = entry.command;
        index += 1;
    }
    if (selected) |command| return command;
    if (index == 1) {
        for (commands) |entry| {
            if (!tui.commandVisible(app, entry)) continue;
            if (command_panel.matchesCommandFilter(entry.name, entry.description, filter)) return entry.command;
        }
    }
    return null;
}

pub fn commandMatchesCount(app: *App) u32 {
    const filter = app.peekPaletteInput() catch return 0;
    defer app.gpa.free(filter);
    return commandMatchesCountForFilter(app, filter);
}

pub fn commandMatchesCountForFilter(app: *const App, filter: []const u8) u32 {
    var count: u32 = 0;
    for (commands) |entry| {
        if (!tui.commandVisible(app, entry)) continue;
        if (command_panel.matchesCommandFilter(entry.name, entry.description, filter)) count += 1;
    }
    return count;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (prefix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

// ---------------------------------------------------------------------------
// Tests
//
// `submitMode` is reached via the public `App.submitMode` delegate. These cover
// the pure mode-transition and no-op branches — the side-effectful branches
// (network/file IO) are exercised elsewhere through their error reporters.

const agent_mod = @import("../agent.zig");

test "submitMode returns false in normal mode" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .normal;
    // normal mode does not handle Enter — falls through to beginSubmit.
    try std.testing.expect(!try app.submitMode());
}

test "submitMode /exit sets quit confirmed" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .command;
    app.nav.command_selection = 0;
    try app.inputs.palette.buf.insertSliceAtCursor("exit");
    try std.testing.expect(try app.submitMode());
    try std.testing.expect(app.nav.quit == .confirmed);
}

test "submitMode /help opens help mode" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .command;
    app.nav.command_selection = 0;
    try app.inputs.palette.buf.insertSliceAtCursor("help");
    try std.testing.expect(try app.submitMode());
    try std.testing.expectEqual(App.Mode.help, app.mode);
}

test "submitMode save_message rejects an empty message" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .save_message;
    // Empty palette: Enter is a no-op (no save attempted), mode unchanged.
    try std.testing.expect(try app.submitMode());
    try std.testing.expectEqual(App.Mode.save_message, app.mode);
}

test "submitMode lanes is a no-op when not confirming a merge" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .lanes;
    app.nav.lanes_purpose = .manage; // not .merge_dest
    try std.testing.expect(try app.submitMode());
    // No merge attempted; mode stays lanes.
    try std.testing.expectEqual(App.Mode.lanes, app.mode);
}
