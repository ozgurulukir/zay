const std = @import("std");
const dynlib = @import("dynlib");
const bash = @import("bash.zig");

const c = @cImport({
    @cInclude("fff.h");
});

const assert = std.debug.assert;

const page_size: u32 = 50;
const grep_max_file_size: u64 = 10 * 1024 * 1024;

pub const Op = enum {
    find,
    grep,

    pub fn name(self: Op) []const u8 {
        return ops_names[@intFromEnum(self)];
    }
};

const ops_names = [_][]const u8{ "find", "grep" };

pub const ops_by_name = std.StaticStringMap(Op).initComptime(.{
    .{ "find", .find },
    .{ "grep", .grep },
});

pub const Request = struct {
    op: Op,
    query: []const u8,
    cursor: ?[]const u8 = null,
};

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }
};

const Cursor = struct {
    op: Op,
    offset: u32,
    query_hash: u64,
};

const CreateInstanceFn = *const fn ([*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, bool, bool, bool, bool, bool, ?[*:0]const u8, ?[*:0]const u8, u64, u64, u64) callconv(.c) *c.FffResult;
const DestroyFn = *const fn (?*anyopaque) callconv(.c) void;
const FreeResultFn = *const fn (*c.FffResult) callconv(.c) void;
const FreeGrepResultFn = *const fn (*c.FffGrepResult) callconv(.c) void;
const FreeMixedSearchResultFn = *const fn (*c.FffMixedSearchResult) callconv(.c) void;
const LiveGrepFn = *const fn (?*anyopaque, [*:0]const u8, u8, u64, u32, bool, u32, u32, u64, u32, u32, bool) callconv(.c) *c.FffResult;
const SearchMixedFn = *const fn (?*anyopaque, [*:0]const u8, ?[*:0]const u8, u32, u32, u32, i32, u32) callconv(.c) *c.FffResult;
const IsScanningFn = *const fn (?*anyopaque) callconv(.c) bool;

const Api = struct {
    lib: dynlib,
    create_instance2: CreateInstanceFn,
    destroy: DestroyFn,
    free_result: FreeResultFn,
    free_grep_result: FreeGrepResultFn,
    free_mixed_search_result: FreeMixedSearchResultFn,
    live_grep: LiveGrepFn,
    search_mixed: SearchMixedFn,
    is_scanning: IsScanningFn,

    fn close(self: *Api) void {
        self.lib.close();
        self.* = undefined;
    }
};

const BackendState = enum {
    unstarted,
    starting,
    ready,
    failed,
};

const Backend = struct {
    mutex: std.atomic.Mutex = .unlocked,
    state: BackendState = .unstarted,
    api: ?Api = null,
    handle: ?*anyopaque = null,
    thread: ?std.Thread = null,
    failure_message: []u8 = &.{},

    fn markFailed(self: *Backend, gpa: std.mem.Allocator, message: []const u8) void {
        assert(message.len > 0);
        lockBackend();
        defer self.mutex.unlock();
        self.markFailedLocked(gpa, message);
    }

    fn markFailedLocked(self: *Backend, gpa: std.mem.Allocator, message: []const u8) void {
        assert(message.len > 0);
        if (self.failure_message.len > 0) gpa.free(self.failure_message);
        self.failure_message = gpa.dupe(u8, message) catch &.{};
        self.state = .failed;
    }
};

var backend: Backend = .{};

pub fn start(gpa: std.mem.Allocator, cwd: []const u8) void {
    assert(cwd.len > 0);
    lockBackend();
    defer backend.mutex.unlock();
    if (backend.state != .unstarted) return;

    const cwd_owned = gpa.dupe(u8, cwd) catch {
        backend.state = .failed;
        return;
    };
    backend.state = .starting;
    backend.thread = std.Thread.spawn(.{}, startThread, .{ gpa, cwd_owned }) catch {
        gpa.free(cwd_owned);
        backend.state = .failed;
        return;
    };
}

pub fn deinit(gpa: std.mem.Allocator) void {
    if (backend.thread) |thread| {
        thread.join();
        backend.thread = null;
    }

    lockBackend();
    defer backend.mutex.unlock();
    if (backend.api) |*api| {
        if (backend.handle) |handle| api.destroy(handle);
        api.close();
    }
    if (backend.failure_message.len > 0) gpa.free(backend.failure_message);
    backend.state = .unstarted;
    backend.api = null;
    backend.handle = null;
    backend.failure_message = &.{};
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, request: Request) !Result {
    assert(cwd.len > 0);
    assert(request.query.len > 0);

    if (try runReadyBackend(gpa, request)) |result| return result;

    lockBackend();
    const state = backend.state;
    backend.mutex.unlock();
    return runFallback(gpa, io, cwd, request, state);
}

fn runReadyBackend(gpa: std.mem.Allocator, request: Request) !?Result {
    assert(request.query.len > 0);

    lockBackend();
    defer backend.mutex.unlock();
    if (backend.state != .ready) return null;

    const api = if (backend.api) |*api| api else return null;
    const handle = backend.handle orelse return null;
    if (api.is_scanning(handle)) return null;
    return runFff(gpa, request, api, handle) catch |err| switch (err) {
        error.OutOfMemory, error.InvalidCursor => err,
        else => {
            backend.markFailedLocked(gpa, @errorName(err));
            return null;
        },
    };
}

fn lockBackend() void {
    while (!backend.mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

fn startThread(gpa: std.mem.Allocator, cwd_owned: []u8) void {
    defer gpa.free(cwd_owned);
    assert(cwd_owned.len > 0);

    var api = loadApi(gpa) catch |err| {
        backend.markFailed(gpa, @errorName(err));
        return;
    };
    errdefer api.close();

    const cwd_c = toCString(gpa, cwd_owned) catch {
        backend.markFailed(gpa, "out of memory");
        return;
    };
    defer gpa.free(cwd_c);

    const create_result = api.create_instance2(cwd_c.ptr, null, null, false, true, true, true, true, null, null, 0, 0, 0);
    if (!create_result.success) {
        const message = resultErrorMessage(create_result);
        backend.markFailed(gpa, message);
        api.free_result(create_result);
        return;
    }
    const handle = create_result.handle orelse {
        api.free_result(create_result);
        backend.markFailed(gpa, "fff returned no handle");
        return;
    };
    api.free_result(create_result);

    lockBackend();
    defer backend.mutex.unlock();
    backend.api = api;
    backend.handle = handle;
    backend.state = .ready;
}

fn loadApi(gpa: std.mem.Allocator) !Api {
    const search_dirs: []const []const u8 = &.{
        "vendor/fff",
        "third_party/fff/target/release",
        "", // falls back to the OS library search path.
    };
    for (search_dirs) |dir| {
        var lib = dynlib.open(gpa, dir, "fff_c") catch continue;
        errdefer lib.close();
        return .{
            .lib = lib,
            .create_instance2 = lib.lookup(CreateInstanceFn, "fff_create_instance2") orelse return error.MissingSymbol,
            .destroy = lib.lookup(DestroyFn, "fff_destroy") orelse return error.MissingSymbol,
            .free_result = lib.lookup(FreeResultFn, "fff_free_result") orelse return error.MissingSymbol,
            .free_grep_result = lib.lookup(FreeGrepResultFn, "fff_free_grep_result") orelse return error.MissingSymbol,
            .free_mixed_search_result = lib.lookup(FreeMixedSearchResultFn, "fff_free_mixed_search_result") orelse return error.MissingSymbol,
            .live_grep = lib.lookup(LiveGrepFn, "fff_live_grep") orelse return error.MissingSymbol,
            .search_mixed = lib.lookup(SearchMixedFn, "fff_search_mixed") orelse return error.MissingSymbol,
            .is_scanning = lib.lookup(IsScanningFn, "fff_is_scanning") orelse return error.MissingSymbol,
        };
    }
    return error.LibraryNotFound;
}

fn runFff(gpa: std.mem.Allocator, request: Request, api: *Api, handle: *anyopaque) !Result {
    assert(request.query.len > 0);
    return switch (request.op) {
        .find => runFffFind(gpa, request, api, handle),
        .grep => runFffGrep(gpa, request, api, handle),
    };
}

fn runFffGrep(gpa: std.mem.Allocator, request: Request, api: *Api, handle: *anyopaque) !Result {
    const cursor = try parseCursorForRequest(request);
    const query_c = try toCString(gpa, request.query);
    defer gpa.free(query_c);

    const ffi_result = api.live_grep(handle, query_c.ptr, 1, grep_max_file_size, 0, true, cursor.offset, page_size, 0, 0, 0, true);
    const grep_result = try unwrapHandle(c.FffGrepResult, api, ffi_result);
    defer api.free_grep_result(grep_result);

    if (grep_result.regex_fallback_error) |message| {
        return fail(gpa, std.mem.span(message));
    }
    if (grep_result.count == 0) return okText(gpa, "0 matches.\n");
    return formatGrep(gpa, request, grep_result);
}

fn runFffFind(gpa: std.mem.Allocator, request: Request, api: *Api, handle: *anyopaque) !Result {
    const cursor = try parseCursorForRequest(request);
    const query_c = try toCString(gpa, request.query);
    defer gpa.free(query_c);

    const ffi_result = api.search_mixed(handle, query_c.ptr, null, 0, cursor.offset, page_size, 100, 3);
    const mixed_result = try unwrapHandle(c.FffMixedSearchResult, api, ffi_result);
    defer api.free_mixed_search_result(mixed_result);
    return formatFind(gpa, request, mixed_result);
}

fn formatGrep(gpa: std.mem.Allocator, request: Request, result: *c.FffGrepResult) !Result {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;

    var index: u32 = 0;
    while (index < result.count) : (index += 1) {
        const item = &result.items[index];
        try writer.print("{s}:{}:{s}\n", .{
            spanOrEmpty(item.relative_path),
            item.line_number,
            spanOrEmpty(item.line_content),
        });
    }
    if (result.next_file_offset > 0) {
        const cursor = try encodeCursor(gpa, .{ .op = .grep, .offset = result.next_file_offset, .query_hash = hashQuery(request.query) });
        defer gpa.free(cursor);
        try writer.print("\nMore results available. Pass cursor=\"{s}\" to continue.\n", .{cursor});
    }
    return okOwned(gpa, try out.toOwnedSlice());
}

fn formatFind(gpa: std.mem.Allocator, request: Request, result: *c.FffMixedSearchResult) !Result {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;
    if (result.count == 0) try writer.writeAll("0 results.\n");
    var index: u32 = 0;
    while (index < result.count) : (index += 1) {
        const item = &result.items[index];
        const suffix: []const u8 = if (item.item_type == 1) "/" else "";
        try writer.print("{s}{s}\n", .{ spanOrEmpty(item.relative_path), suffix });
    }
    const total = result.total_matched;
    const cursor = try parseCursorForRequest(request);
    const next_offset = cursor.offset + result.count;
    if (result.count > 0 and next_offset < total) {
        const more_count = total - next_offset;
        const next_cursor = try encodeCursor(gpa, .{ .op = .find, .offset = next_offset, .query_hash = hashQuery(request.query) });
        defer gpa.free(next_cursor);
        try writer.print("\n+{} more results. Pass cursor=\"{s}\" to continue.\n", .{ more_count, next_cursor });
    }
    return okOwned(gpa, try out.toOwnedSlice());
}

fn runFallback(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, request: Request, state: BackendState) !Result {
    assert(cwd.len > 0);
    assert(request.query.len > 0);
    _ = state;
    const command = try fallbackCommand(gpa, request.op, request.query);
    defer gpa.free(command);

    var result = bash.run(gpa, io, cwd, command) catch |err| return fail(gpa, @errorName(err));
    defer result.deinit(gpa);
    if (result.code == 0) return formatFallbackSuccess(gpa, result.stdout);
    if (result.code == 1) return formatFallbackSuccess(gpa, result.stdout);
    return .{
        .stdout = try gpa.alloc(u8, 0),
        .stderr = try std.fmt.allocPrint(gpa, "search fallback failed:\n{s}", .{result.stderr}),
        .code = result.code,
    };
}

fn fallbackCommand(gpa: std.mem.Allocator, op: Op, query: []const u8) ![]u8 {
    const quoted = try quoteShell(gpa, query);
    defer gpa.free(quoted);
    return switch (op) {
        .grep => std.fmt.allocPrint(gpa,
            \\set -o pipefail; if command -v rg >/dev/null 2>&1; then rg --line-number --color never --no-heading -- {s} . | head -n 50; else grep -RInE --exclude-dir=.git -- {s} . | head -n 50; fi
        , .{ quoted, quoted }),
        .find => std.fmt.allocPrint(gpa,
            \\set -o pipefail; {{ find . -mindepth 1 -type f -not -path './.git/*' 2>/dev/null; find . -mindepth 1 -type d -not -path './.git/*' 2>/dev/null | sed 's|$|/|'; }} | grep -F -- {s} | head -n 50
        , .{quoted}),
    };
}

fn formatFallbackSuccess(gpa: std.mem.Allocator, stdout: []const u8) !Result {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("Search index is unavailable or still starting; used shell fallback. Pagination unavailable.\n\n");
    if (stdout.len == 0) {
        try out.writer.writeAll("0 results.\n");
    } else {
        try out.writer.writeAll(stdout);
        if (stdout[stdout.len - 1] != '\n') try out.writer.writeByte('\n');
    }
    return okOwned(gpa, try out.toOwnedSlice());
}

fn parseCursorForRequest(request: Request) !Cursor {
    assert(request.query.len > 0);
    if (request.cursor) |raw| {
        const cursor = decodeCursor(raw) orelse return error.InvalidCursor;
        if (cursor.op != request.op) return error.InvalidCursor;
        if (cursor.query_hash != hashQuery(request.query)) return error.InvalidCursor;
        return cursor;
    }
    return .{ .op = request.op, .offset = 0, .query_hash = hashQuery(request.query) };
}

fn encodeCursor(gpa: std.mem.Allocator, cursor: Cursor) ![]u8 {
    assert(cursor.offset > 0);
    return std.fmt.allocPrint(gpa, "nova-search-v2:{s}:{}:{x}", .{
        cursor.op.name(),
        cursor.offset,
        cursor.query_hash,
    });
}

fn decodeCursor(raw: []const u8) ?Cursor {
    if (raw.len == 0) return null;
    var iter = std.mem.splitScalar(u8, raw, ':');
    const prefix = iter.next() orelse return null;
    if (!std.mem.eql(u8, prefix, "nova-search-v2")) return null;
    const op = ops_by_name.get(iter.next() orelse return null) orelse return null;
    const offset = std.fmt.parseInt(u32, iter.next() orelse return null, 10) catch return null;
    const query_hash = std.fmt.parseInt(u64, iter.next() orelse return null, 16) catch return null;
    if (iter.next() != null) return null;
    if (offset == 0) return null;
    return .{ .op = op, .offset = offset, .query_hash = query_hash };
}

fn hashQuery(query: []const u8) u64 {
    assert(query.len > 0);
    return std.hash.Wyhash.hash(0x6e6f76615f736561, query);
}

fn quoteShell(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    assert(value.len > 0);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeByte('\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.writer.writeAll("'\\''");
        } else {
            try out.writer.writeByte(byte);
        }
    }
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}

fn toCString(gpa: std.mem.Allocator, value: []const u8) ![:0]u8 {
    assert(value.len > 0);
    return gpa.dupeZ(u8, value);
}

fn unwrapHandle(comptime T: type, api: *Api, result: *c.FffResult) !*T {
    if (!result.success) {
        api.free_result(result);
        return error.FffFailed;
    }
    const handle = result.handle orelse {
        api.free_result(result);
        return error.FffFailed;
    };
    api.free_result(result);
    return @ptrCast(@alignCast(handle));
}

fn resultErrorMessage(result: *c.FffResult) []const u8 {
    if (@field(result, "error")) |ptr| return std.mem.span(ptr);
    return "fff failed";
}

fn spanOrEmpty(ptr: ?[*:0]u8) []const u8 {
    return if (ptr) |value| std.mem.span(value) else "";
}

fn okText(gpa: std.mem.Allocator, text: []const u8) !Result {
    return okOwned(gpa, try gpa.dupe(u8, text));
}

fn okOwned(gpa: std.mem.Allocator, stdout: []u8) !Result {
    return .{ .stdout = stdout, .stderr = try gpa.alloc(u8, 0), .code = 0 };
}

fn fail(gpa: std.mem.Allocator, message: []const u8) !Result {
    assert(message.len > 0);
    return .{ .stdout = try gpa.alloc(u8, 0), .stderr = try gpa.dupe(u8, message), .code = 2 };
}

test "cursor validates op and query" {
    const gpa = std.testing.allocator;
    const cursor = try encodeCursor(gpa, .{ .op = .grep, .offset = 50, .query_hash = hashQuery("abc") });
    defer gpa.free(cursor);
    const parsed = decodeCursor(cursor) orelse return error.TestFailed;
    try std.testing.expectEqual(Op.grep, parsed.op);
    try std.testing.expectEqual(@as(u32, 50), parsed.offset);
    try std.testing.expectEqual(hashQuery("abc"), parsed.query_hash);
}

test "shell quoting handles single quotes" {
    const gpa = std.testing.allocator;
    const quoted = try quoteShell(gpa, "can't");
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings("'can'\\''t'", quoted);
}
