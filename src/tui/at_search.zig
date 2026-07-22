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
    app.at_search.active = true;
    if (kind != app.at_search.kind or !std.mem.eql(u8, query, app.at_search.query)) {
        const owned: []u8 = if (query.len > 0) try app.gpa.dupe(u8, query) else "";
        if (app.at_search.query.len > 0) app.gpa.free(app.at_search.query);
        app.at_search.kind = kind;
        app.at_search.query = owned;
        app.at_search.selection = 0;
        try refreshAtResults(app);
    }
}

fn startAtSearchBackend(app: *App) void {
    const cwd = if (app.liveRuntime()) |runtime| runtime.cwd else ".";
    search_mod.start(std.heap.smp_allocator, app.io, cwd);
}

fn refreshAtResults(app: *App) !void {
    clearAtResults(app);
    app.at_search.indexing = false;
    switch (app.at_search.kind) {
        .file => try refreshFileResults(app),
        .skill => try refreshSkillResults(app),
    }
}

fn refreshFileResults(app: *App) !void {
    const search_query = if (app.at_search.query.len == 0) " " else app.at_search.query;
    var result = (try search_mod.runIfReady(app.gpa, app.io, .{
        .op = .find,
        .query = search_query,
    })) orelse {
        app.at_search.indexing = true;
        return;
    };
    defer result.deinit(app.gpa);
    try parseAtResults(app, result.stdout);
}

fn refreshSkillResults(app: *App) !void {
    const runtime = app.liveRuntime() orelse return;
    const names = try skill_mod.filterNames(app.gpa, runtime.skills, app.at_search.query);
    errdefer {
        for (names) |name| app.gpa.free(name);
        app.gpa.free(names);
    }
    for (names) |name| try app.at_search.results.append(app.gpa, name);
    app.gpa.free(names);
    if (app.at_search.selection >= app.at_search.results.items.len) app.at_search.selection = 0;
}

fn parseAtResults(app: *App, stdout: []const u8) !void {
    const max_results = 50;
    var iter = std.mem.splitScalar(u8, stdout, '\n');
    while (iter.next()) |line| {
        if (app.at_search.results.items.len >= max_results) break;
        if (line.len == 0) continue;
        if (isSearchFooter(line)) continue;
        if (line[line.len - 1] == '/') continue;
        const owned = try app.gpa.dupe(u8, line);
        errdefer app.gpa.free(owned);
        try app.at_search.results.append(app.gpa, owned);
    }
    if (app.at_search.selection >= app.at_search.results.items.len) app.at_search.selection = 0;
}

pub fn acceptAtSelection(app: *App) !void {
    if (app.at_search.selection >= app.at_search.results.items.len) return;
    const before = app.inputs.input.buf.firstHalf();
    const active_start = switch (app.at_search.kind) {
        .file => if (at_mention.activeQuery(before)) |active| active.start else return,
        .skill => if (skill_mod.activeQuery(before)) |active| active.start else return,
    };
    const value = app.at_search.results.items[app.at_search.selection];
    const sigil: u8 = if (app.at_search.kind == .file) '@' else '$';
    const insert = try std.fmt.allocPrint(app.gpa, "{c}{s} ", .{ sigil, value });
    defer app.gpa.free(insert);
    app.inputs.input.buf.growGapLeft(before.len - active_start);
    try app.inputs.input.insertSliceAtCursor(insert);
    closeAtSearch(app);
}

fn clearAtResults(app: *App) void {
    for (app.at_search.results.items) |path| app.gpa.free(path);
    app.at_search.results.clearRetainingCapacity();
}

pub fn closeAtSearch(app: *App) void {
    app.at_search.active = false;
    app.at_search.indexing = false;
    app.at_search.selection = 0;
    app.at_search.kind = .file;
    clearAtResults(app);
    if (app.at_search.query.len > 0) {
        app.gpa.free(app.at_search.query);
        app.at_search.query = "";
    }
}
