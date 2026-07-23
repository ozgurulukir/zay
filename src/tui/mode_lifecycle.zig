//! Command menu, mode synchronization, and command resolution logic.
//! Free functions taking `*App` — extracted from `tui.zig`.

const std = @import("std");
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");
const provider_model = @import("provider_model.zig");
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
        app.provider_key_input.clearRetainingCapacity();
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
            .open_form => |provider| provider_model.openProviderForm(app, provider),
            .open_dynamic => |provider| provider_model.openDynamicProviderForm(app, provider),
        }
        return true;
    }
    if (app.mode == .model_picker) {
        provider_model.applySelectedModel(app) catch |err| try app.reportConnectionError(err);
        return true;
    }
    if (app.mode == .session_picker) {
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
                .timeline => provider_model.openTimelineSelector(app) catch |err| try app.reportSessionSwitchError(err),
                .connect => try provider_model.openProviderPicker(app),
                .model => provider_model.openModelPicker(app) catch |err| try app.reportConnectionError(err),
                .mcp => tui.openMcp(app),
                .settings => tui.openSettings(app),
                .diff => provider_model.openDiffViewer(app) catch |err| try provider_model.reportDiffError(app, err),
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
                    _ = try app.thread.transcript.append(app.gpa, .notice, "compaction", "Compacting session conversation context...");
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
                    app.nav.quit_requested = true;
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
        .session_picker, .model_picker, .tree_picker => app.inputs.palette.buf.realLength() == 0,
        .provider_picker => app.pickers.provider.stage == .list and app.inputs.palette.buf.realLength() == 0,
        // Settings has its own navigation: '/' is not a command shortcut there.
        .settings, .command, .diff_viewer, .save_message, .lanes, .help, .mcp => false,
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
