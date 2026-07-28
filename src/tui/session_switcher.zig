//! Session switching: resume-picker state management, session creation, and
//! timeline navigation. Free functions taking `*App` — extracted from `tui.zig`
//! (Phase 3 of `_pm/Projects/tui-domain-extract`).

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const config_mod = @import("../config/config.zig");
const resume_picker = @import("widgets/resume_picker.zig");
const runtime_mod = @import("../runtime.zig");
const session_mod = @import("../session.zig");
const vcs = @import("../vcs.zig");

const App = tui.App;

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn resumeFoldIndex(app: *const App, cwd: []const u8) ?usize {
    for (app.resume_folded_projects.items, 0..) |folded, index| {
        if (std.mem.eql(u8, folded, cwd)) return index;
    }
    return null;
}

/// Build a cwd → max_updated_at_ms map for O(1) project-lookup in the sort
/// comparator. Caller owns the map and its backing allocator.
fn buildProjectMaxMap(gpa: std.mem.Allocator, summaries: []const session_mod.SessionSummary) !std.StringHashMap(i64) {
    var map = std.StringHashMap(i64).init(gpa);
    errdefer map.deinit();
    for (summaries) |summary| {
        const entry = try map.getOrPut(summary.cwd);
        if (!entry.found_existing) {
            entry.key_ptr.* = summary.cwd;
            entry.value_ptr.* = summary.updated_at_ms;
        } else {
            entry.value_ptr.* = @max(entry.value_ptr.*, summary.updated_at_ms);
        }
    }
    return map;
}

/// Sort comparator that uses a precomputed cwd → max_updated_at_ms map for O(1)
/// project lookups instead of scanning all summaries per comparison.
fn resumeSummaryLessThanWithMap(map: *const std.StringHashMap(i64), left: session_mod.SessionSummary, right: session_mod.SessionSummary) bool {
    if (std.mem.eql(u8, left.cwd, right.cwd)) return left.updated_at_ms > right.updated_at_ms;

    const left_project_updated_at_ms = map.get(left.cwd) orelse std.math.minInt(i64);
    const right_project_updated_at_ms = map.get(right.cwd) orelse std.math.minInt(i64);
    if (left_project_updated_at_ms != right_project_updated_at_ms) {
        return left_project_updated_at_ms > right_project_updated_at_ms;
    }

    return std.mem.lessThan(u8, left.cwd, right.cwd);
}

/// Legacy comparator (O(n) per comparison). Kept for the cross-module test in
/// tui.zig. Prefer `resumeSummaryLessThanWithMap` for production use.
pub fn resumeSummaryLessThan(summaries: []const session_mod.SessionSummary, left: session_mod.SessionSummary, right: session_mod.SessionSummary) bool {
    if (std.mem.eql(u8, left.cwd, right.cwd)) return left.updated_at_ms > right.updated_at_ms;

    const left_project_updated_at_ms = resumeProjectUpdatedAtMax(summaries, left.cwd);
    const right_project_updated_at_ms = resumeProjectUpdatedAtMax(summaries, right.cwd);
    if (left_project_updated_at_ms != right_project_updated_at_ms) {
        return left_project_updated_at_ms > right_project_updated_at_ms;
    }

    return std.mem.lessThan(u8, left.cwd, right.cwd);
}

fn resumeProjectUpdatedAtMax(summaries: []const session_mod.SessionSummary, cwd: []const u8) i64 {
    var updated_at_ms: i64 = std.math.minInt(i64);
    for (summaries) |summary| {
        if (!std.mem.eql(u8, summary.cwd, cwd)) continue;
        updated_at_ms = @max(updated_at_ms, summary.updated_at_ms);
    }
    return updated_at_ms;
}

/// Restore the working tree to the snapshot bound to the now-active timeline
/// node — its own, or the nearest ancestor that has one (`snapshotAt`). HEAD
/// stays attached to the branch; `vcs.restore` rewrites tracked files to that
/// tree (adds/modifies/deletes). Best-effort: a node with no bound snapshot
/// (an early point, before any file change) or a git failure simply leaves
/// the working tree as-is.
fn restoreCheckpointForBranch(app: *App, rt: *runtime_mod.AgentRuntime) !void {
    const sha_raw = (try rt.session_writer.snapshotAt(app.gpa)) orelse return;
    defer app.gpa.free(sha_raw);
    const sha = vcs.ObjectId.parse(sha_raw) catch return;
    const index = vcs.indexPath(app.gpa, app.io, rt.cwd) catch return;
    defer app.gpa.free(index);
    vcs.restore(app.gpa, app.io, rt.cwd, index, sha) catch return;
}

// ---------------------------------------------------------------------------
// Delegated public functions
// ---------------------------------------------------------------------------

pub fn openResumePicker(app: *App) !void {
    app.closeAtSearch();
    try app.reloadResumeSessions();
    const summaries = app.resume_summaries.items;
    const filter = app.peekPaletteInput() catch "";
    defer if (filter.len > 0) app.gpa.free(filter);
    _ = resume_picker.visibleCount(summaries, filter, app.resume_folded_projects.items, app.nav.resume_global);
    app.nav.resume_selection = 0;
    app.nav.block_nav = false;
    app.mode = .session_picker;
    app.inputs.palette.clearRetainingCapacity();
    if (filter.len > 0) try app.inputs.palette.insertSliceAtCursor(filter);
    syncResumeListCursor(app);
}

pub fn reloadResumeSessions(app: *App) !void {
    resumeClear(app);
    var manager = try session_mod.SessionManager.initDefault(app.gpa, app.io, app.liveRuntime().?.home_dir);
    defer manager.deinit();
    const cwd = if (app.nav.resume_global) null else (app.repoRoot() orelse app.liveRuntime().?.cwd);
    const summaries = try manager.list(app.gpa, cwd);
    defer app.gpa.free(summaries);
    try app.resume_summaries.appendSlice(app.gpa, summaries);
    if (app.nav.resume_global) {
        var map = try buildProjectMaxMap(app.gpa, app.resume_summaries.items);
        defer map.deinit();
        std.mem.sort(
            session_mod.SessionSummary,
            app.resume_summaries.items,
            &map,
            struct {
                fn cmp(m: *const std.StringHashMap(i64), a: session_mod.SessionSummary, b: session_mod.SessionSummary) bool {
                    return resumeSummaryLessThanWithMap(m, a, b);
                }
            }.cmp,
        );
    }
    if (app.nav.resume_selection >= try visibleResumeCount(app)) app.nav.resume_selection = 0;
    syncResumeListCursor(app);
}

pub fn selectedResumeSummary(app: *App) !?*session_mod.SessionSummary {
    const filter = try app.peekPaletteInput();
    defer app.gpa.free(filter);
    return @constCast(resume_picker.selectedSummary(app.resume_summaries.items, filter, app.resume_folded_projects.items, app.nav.resume_selection, app.nav.resume_global));
}

pub fn visibleResumeCount(app: *App) !u32 {
    const filter = try app.peekPaletteInput();
    defer app.gpa.free(filter);
    return resume_picker.visibleCount(app.resume_summaries.items, filter, app.resume_folded_projects.items, app.nav.resume_global);
}

pub fn toggleSelectedResumeProject(app: *App) !void {
    const filter = try app.peekPaletteInput();
    defer app.gpa.free(filter);
    const cwd = resume_picker.selectedProject(app.resume_summaries.items, filter, app.resume_folded_projects.items, app.nav.resume_selection) orelse return;
    if (resumeFoldIndex(app, cwd)) |index| {
        app.gpa.free(app.resume_folded_projects.items[index]);
        _ = app.resume_folded_projects.orderedRemove(index);
    } else {
        try app.resume_folded_projects.append(app.gpa, try app.gpa.dupe(u8, cwd));
    }
    if (app.nav.resume_selection >= try visibleResumeCount(app)) app.nav.resume_selection = 0;
    syncResumeListCursor(app);
}

pub fn resumeClearFolds(app: *App) void {
    for (app.resume_folded_projects.items) |folded| app.gpa.free(folded);
    app.resume_folded_projects.clearRetainingCapacity();
}

pub fn resumeClear(app: *App) void {
    for (app.resume_summaries.items) |*summary| summary.deinit(app.gpa);
    app.resume_summaries.clearRetainingCapacity();
}

pub fn syncResumeListCursor(app: *App) void {
    app.list_widgets.resume_list.cursor = app.nav.resume_selection;
    app.list_widgets.resume_list.ensureScroll();
}

pub fn reloadTreeNodes(app: *App) !void {
    const writer = &app.liveRuntime().?.session_writer;
    const records = try writer.entries(app.gpa);
    defer {
        for (records) |*record| record.deinit(app.gpa);
        app.gpa.free(records);
    }
    try app.pickers.tree.load(records, writer.leaf());
}

/// Switch the session leaf to `entry_id`, then rehydrate the agent's
/// conversation, the display transcript, AND the working copy from the new
/// branch. Refused mid-turn.
pub fn navigateToEntry(app: *App, entry_id: []const u8) !void {
    if (app.thread.turn.isActive()) return error.InFlightTurn;
    const rt = app.liveRuntime() orelse return error.NoActiveRuntime;
    try rt.session_writer.navigate(entry_id);
    try rt.reloadMessages();
    try app.rebuildTranscriptFromAgent();
    try restoreCheckpointForBranch(app, rt);
}

pub fn reportSessionSwitchError(app: *App, err: anyerror) !void {
    app.mode = .normal;
    app.clearInput();
    var buffer: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "Could not switch session: {s}", .{@errorName(err)}) catch "Could not switch session.";
    _ = try app.thread.transcript.append(app.gpa, .agent, "agent", message);
}

pub fn switchToNewSession(app: *App) !void {
    if (app.thread.turn.isActive()) return error.InFlightTurn;
    const runtime = try createRuntime(app, app.liveRuntime().?.cwd, app.repoRoot() orelse app.liveRuntime().?.cwd, null);
    errdefer {
        runtime.deinit();
        app.gpa.destroy(runtime);
    }
    try app.installRuntime(runtime);
    try app.clearConversation();
}

pub fn switchToSession(app: *App, session_id: []const u8) !void {
    if (app.thread.turn.isActive()) return error.InFlightTurn;
    const runtime = try createRuntime(app, app.liveRuntime().?.cwd, app.repoRoot() orelse app.liveRuntime().?.cwd, session_id);
    errdefer {
        runtime.deinit();
        app.gpa.destroy(runtime);
    }
    try app.installRuntime(runtime);
    try app.rebuildTranscriptFromAgent();
}

pub fn createRuntime(app: *App, cwd: []const u8, session_dir: []const u8, session_id: ?[]const u8) !*runtime_mod.AgentRuntime {
    const current = app.templateRuntime() orelse return error.NoActiveRuntime;
    const runtime = try app.gpa.create(runtime_mod.AgentRuntime);
    errdefer app.gpa.destroy(runtime);
    const diagnostics = try current.gpa.alloc(config_mod.Diagnostic, 0);
    errdefer current.gpa.free(diagnostics);
    if (session_id) |id| {
        try runtime.initResume(
            current.gpa,
            app.io,
            cwd,
            session_dir,
            current.home_dir,
            current.base_system_prompt,
            app.cached_config,
            diagnostics,
            id,
            current,
        );
    } else {
        try runtime.initNew(
            current.gpa,
            app.io,
            cwd,
            session_dir,
            current.home_dir,
            current.base_system_prompt,
            app.cached_config,
            diagnostics,
            current,
        );
    }
    runtime.agent.background_manager = app.background;
    runtime.agent.mcp_manager = &app.mcp_manager;
    runtime.agent.tool_registry = app.tool_registry;
    runtime.agent.plugin_manager = &app.plugin_manager;
    return runtime;
}
