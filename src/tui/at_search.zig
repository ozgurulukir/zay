//! At-search (`@` file / `$` skill mention popup). Free functions taking
//! `*App` — extracted from `tui.zig`.

const std = @import("std");

const tui = @import("../tui.zig");
const at_mention = @import("../at_mention.zig");
const search_mod = @import("../search.zig");
const skill_mod = @import("../skill.zig");

const App = tui.App;

pub const MentionSearchKind = enum { file, skill };

fn isSearchFooter(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "+") or
        std.mem.eql(u8, line, "0 results.");
}

pub fn updateAtSearch(app: *App) !void {
    const before = app.inputs.input.buf.firstHalf();
    if (at_mention.activeQuery(before)) |active| {
        try setMentionSearch(app, .file, active.query);
        return;
    }
    if (skill_mod.activeQuery(before)) |active| {
        try setMentionSearch(app, .skill, active.query);
        return;
    }
    closeAtSearch(app);
}

fn setMentionSearch(app: *App, kind: MentionSearchKind, query: []const u8) !void {
    if (kind == .file) startAtSearchBackend(app);
    // Already open with the same kind+query: nothing to do.
    if (app.at_search == .open and app.at_search.open.kind == kind and
        std.mem.eql(u8, query, app.at_search.open.query)) return;
    // Otherwise: close whatever's there and start fresh in .open.
    app.at_search.close(app.gpa);
    const owned: []u8 = if (query.len > 0) try app.gpa.dupe(u8, query) else "";
    app.at_search = .{ .open = .{ .kind = kind, .query = owned } };
    try refreshAtResults(app);
}

fn startAtSearchBackend(app: *App) void {
    const cwd = if (app.liveRuntime()) |runtime| runtime.cwd else ".";
    search_mod.start(app.gpa, app.io, cwd);
}

fn refreshAtResults(app: *App) !void {
    // Caller ensures we're in .open (or transitioning to .indexing).
    if (app.at_search != .open) return;
    clearAtResults(app);
    switch (app.at_search.open.kind) {
        .file => try refreshFileResults(app),
        .skill => try refreshSkillResults(app),
    }
}

fn refreshFileResults(app: *App) !void {
    if (app.at_search != .open) return;
    const o = &app.at_search.open;
    const search_query = if (o.query.len == 0) " " else o.query;
    var result = (try search_mod.runIfReady(app.gpa, app.io, .{
        .op = .find,
        .query = search_query,
    })) orelse {
        // Backend still indexing — transition open -> indexing,
        // preserving the query+results+selection.
        const kind = o.kind;
        const query = o.query;
        const results_list = o.results;
        const selection = o.selection;
        app.at_search = .{ .indexing = .{ .kind = kind, .results = results_list } };
        // The query and selection aren't valid in .indexing — we'd
        // lose them. Stash by carrying the query into the indexing
        // payload's result-list header... actually the plan's union
        // doesn't carry query in indexing. So when indexing completes,
        // refreshAtResults is re-called and the open state is rebuilt
        // from the cached query in the input buffer. For now we leak
        // the query string here; closeAtSearch frees it. But we just
        // moved results_list out, so the original .open payload is
        // gone. To keep the query alive, free it explicitly here.
        app.gpa.free(query);
        _ = selection;
        return;
    };
    defer result.deinit(app.gpa);
    try parseAtResults(app, result.stdout);
}

fn refreshSkillResults(app: *App) !void {
    if (app.at_search != .open) return;
    const o = &app.at_search.open;
    const runtime = app.liveRuntime() orelse return;
    const names = try skill_mod.filterNames(app.gpa, runtime.skills, o.query);
    errdefer {
        for (names) |name| app.gpa.free(name);
        app.gpa.free(names);
    }
    for (names) |name| try o.results.append(app.gpa, name);
    app.gpa.free(names);
    if (o.selection >= o.results.items.len) o.selection = 0;
}

fn parseAtResults(app: *App, stdout: []const u8) !void {
    if (app.at_search != .open) return;
    const o = &app.at_search.open;
    const max_results = 50;
    var iter = std.mem.splitScalar(u8, stdout, '\n');
    while (iter.next()) |line| {
        if (o.results.items.len >= max_results) break;
        if (line.len == 0) continue;
        if (isSearchFooter(line)) continue;
        if (line[line.len - 1] == '/') continue;
        const owned = try app.gpa.dupe(u8, line);
        errdefer app.gpa.free(owned);
        try o.results.append(app.gpa, owned);
    }
    if (o.selection >= o.results.items.len) o.selection = 0;
}

pub fn acceptAtSelection(app: *App) !void {
    if (app.at_search != .open) return;
    const o = &app.at_search.open;
    if (o.selection >= o.results.items.len) return;
    const before = app.inputs.input.buf.firstHalf();
    const active_start = switch (o.kind) {
        .file => if (at_mention.activeQuery(before)) |active| active.start else return,
        .skill => if (skill_mod.activeQuery(before)) |active| active.start else return,
    };
    const value = o.results.items[o.selection];
    const sigil: u8 = if (o.kind == .file) '@' else '$';
    const insert = try std.fmt.allocPrint(app.gpa, "{c}{s} ", .{ sigil, value });
    defer app.gpa.free(insert);
    app.inputs.input.buf.growGapLeft(before.len - active_start);
    try app.inputs.input.insertSliceAtCursor(insert);
    closeAtSearch(app);
}

fn clearAtResults(app: *App) void {
    switch (app.at_search) {
        .open => |*o| {
            for (o.results.items) |path| app.gpa.free(path);
            o.results.clearRetainingCapacity();
        },
        .indexing => |*i| {
            for (i.results.items) |path| app.gpa.free(path);
            i.results.clearRetainingCapacity();
        },
        .closed => {},
    }
}

pub fn closeAtSearch(app: *App) void {
    app.at_search.close(app.gpa);
}

/// Promote an indexing state back to open when the backend completes.
/// Re-runs refreshAtResults against the current input-buffer query.
pub fn onSearchBackendReady(app: *App) !void {
    if (app.at_search != .indexing) return;
    // Recover the query from the input buffer — the indexing variant
    // doesn't carry it.
    const before = app.inputs.input.buf.firstHalf();
    const active = blk: {
        if (at_mention.activeQuery(before)) |q| break :blk .{ .kind = .file, .query = q.query };
        if (skill_mod.activeQuery(before)) |q| break :blk .{ .kind = .skill, .query = q.query };
        closeAtSearch(app);
        return;
    };
    // Drop the indexing results — refreshAtResults repopulates from
    // the now-ready backend.
    clearAtResults(app);
    const kind_mention: MentionSearchKind = active.kind;
    const owned: []u8 = if (active.query.len > 0) try app.gpa.dupe(u8, active.query) else "";
    app.at_search.close(app.gpa);
    app.at_search = .{ .open = .{ .kind = kind_mention, .query = owned } };
    try refreshAtResults(app);
}
