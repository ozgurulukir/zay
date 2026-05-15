const std = @import("std");
const builtin = @import("builtin");
const bash = @import("bash.zig");

const c = @cImport({
    @cInclude("fff.h");
});

const assert = std.debug.assert;

const page_size: u32 = 50;
const fuzzy_suggestions_count: u32 = 3;
const grep_max_file_size: u64 = 10 * 1024 * 1024;

pub const Mode = enum {
    file_content,
    file_names,
    directories,

    pub fn parse(raw: []const u8) ?Mode {
        assert(raw.len > 0);
        if (std.mem.eql(u8, raw, "file_content")) return .file_content;
        if (std.mem.eql(u8, raw, "file_names")) return .file_names;
        if (std.mem.eql(u8, raw, "directories")) return .directories;
        return null;
    }

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .file_content => "file_content",
            .file_names => "file_names",
            .directories => "directories",
        };
    }
};

pub const Request = struct {
    mode: Mode,
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

const Phase = enum {
    primary,
};

const Cursor = struct {
    mode: Mode,
    phase: Phase,
    offset: u32,
    query_hash: u64,
};

const CreateInstanceFn = *const fn ([*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, bool, bool, bool, bool, bool, ?[*:0]const u8, ?[*:0]const u8, u64, u64, u64) callconv(.c) *c.FffResult;
const DestroyFn = *const fn (?*anyopaque) callconv(.c) void;
const FreeResultFn = *const fn (*c.FffResult) callconv(.c) void;
const FreeStringFn = *const fn (?[*:0]u8) callconv(.c) void;
const FreeSearchResultFn = *const fn (*c.FffSearchResult) callconv(.c) void;
const FreeGrepResultFn = *const fn (*c.FffGrepResult) callconv(.c) void;
const FreeDirSearchResultFn = *const fn (*c.FffDirSearchResult) callconv(.c) void;
const LiveGrepFn = *const fn (?*anyopaque, [*:0]const u8, u8, u64, u32, bool, u32, u32, u64, u32, u32, bool) callconv(.c) *c.FffResult;
const SearchFn = *const fn (?*anyopaque, [*:0]const u8, ?[*:0]const u8, u32, u32, u32, i32, u32) callconv(.c) *c.FffResult;
const SearchDirectoriesFn = *const fn (?*anyopaque, [*:0]const u8, ?[*:0]const u8, u32, u32, u32) callconv(.c) *c.FffResult;
const WaitForScanFn = *const fn (?*anyopaque, u64) callconv(.c) *c.FffResult;

const Api = struct {
    lib: std.DynLib,
    create_instance2: CreateInstanceFn,
    destroy: DestroyFn,
    free_result: FreeResultFn,
    free_string: FreeStringFn,
    free_search_result: FreeSearchResultFn,
    free_grep_result: FreeGrepResultFn,
    free_dir_search_result: FreeDirSearchResultFn,
    live_grep: LiveGrepFn,
    search: SearchFn,
    search_directories: SearchDirectoriesFn,
    wait_for_scan: WaitForScanFn,

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

    const snapshot = snapshotBackend();
    defer snapshot.deinit();

    return switch (snapshot.state) {
        .ready => runFff(gpa, request, snapshot.api.?, snapshot.handle.?) catch |err| switch (err) {
            error.OutOfMemory, error.InvalidCursor => err,
            else => fallbackAfterFffFailure(gpa, io, cwd, request, err),
        },
        .unstarted, .starting, .failed => runFallback(gpa, io, cwd, request, snapshot.state),
    };
}

fn fallbackAfterFffFailure(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, request: Request, err: anyerror) !Result {
    assert(cwd.len > 0);
    assert(request.query.len > 0);
    backend.markFailed(gpa, @errorName(err));
    return runFallback(gpa, io, cwd, request, .failed);
}

const Snapshot = struct {
    state: BackendState,
    api: ?*Api,
    handle: ?*anyopaque,

    fn deinit(_: Snapshot) void {}
};

fn snapshotBackend() Snapshot {
    lockBackend();
    defer backend.mutex.unlock();
    return .{
        .state = backend.state,
        .api = if (backend.api) |*api| api else null,
        .handle = backend.handle,
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

    var api = loadApi() catch |err| {
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

    const wait_result = api.wait_for_scan(handle, 30_000);
    if (!wait_result.success) {
        const message = resultErrorMessage(wait_result);
        api.destroy(handle);
        backend.markFailed(gpa, message);
        api.free_result(wait_result);
        return;
    }
    const ready = wait_result.int_value == 1;
    api.free_result(wait_result);
    if (!ready) {
        api.destroy(handle);
        backend.markFailed(gpa, "fff initial scan timed out");
        return;
    }

    lockBackend();
    defer backend.mutex.unlock();
    backend.api = api;
    backend.handle = handle;
    backend.state = .ready;
}

fn loadApi() !Api {
    const paths = libraryPaths();
    for (paths) |path| {
        var lib = std.DynLib.open(path) catch continue;
        errdefer lib.close();
        return .{
            .lib = lib,
            .create_instance2 = lib.lookup(CreateInstanceFn, "fff_create_instance2") orelse return error.MissingSymbol,
            .destroy = lib.lookup(DestroyFn, "fff_destroy") orelse return error.MissingSymbol,
            .free_result = lib.lookup(FreeResultFn, "fff_free_result") orelse return error.MissingSymbol,
            .free_string = lib.lookup(FreeStringFn, "fff_free_string") orelse return error.MissingSymbol,
            .free_search_result = lib.lookup(FreeSearchResultFn, "fff_free_search_result") orelse return error.MissingSymbol,
            .free_grep_result = lib.lookup(FreeGrepResultFn, "fff_free_grep_result") orelse return error.MissingSymbol,
            .free_dir_search_result = lib.lookup(FreeDirSearchResultFn, "fff_free_dir_search_result") orelse return error.MissingSymbol,
            .live_grep = lib.lookup(LiveGrepFn, "fff_live_grep") orelse return error.MissingSymbol,
            .search = lib.lookup(SearchFn, "fff_search") orelse return error.MissingSymbol,
            .search_directories = lib.lookup(SearchDirectoriesFn, "fff_search_directories") orelse return error.MissingSymbol,
            .wait_for_scan = lib.lookup(WaitForScanFn, "fff_wait_for_scan") orelse return error.MissingSymbol,
        };
    }
    return error.LibraryNotFound;
}

fn libraryPaths() []const []const u8 {
    return switch (builtin.os.tag) {
        .macos => &.{
            "vendor/fff/libfff_c.dylib",
            "third_party/fff/target/release/libfff_c.dylib",
            "libfff_c.dylib",
        },
        .linux => &.{
            "vendor/fff/libfff_c.so",
            "third_party/fff/target/release/libfff_c.so",
            "libfff_c.so",
        },
        .windows => &.{
            "vendor\\fff\\fff_c.dll",
            "third_party\\fff\\target\\release\\fff_c.dll",
            "fff_c.dll",
        },
        else => &.{"libfff_c"},
    };
}

fn runFff(gpa: std.mem.Allocator, request: Request, api: *Api, handle: *anyopaque) !Result {
    assert(request.query.len > 0);
    return switch (request.mode) {
        .file_content => runFffContent(gpa, request, api, handle),
        .file_names => runFffFiles(gpa, request, api, handle),
        .directories => runFffDirectories(gpa, request, api, handle),
    };
}

fn runFffContent(gpa: std.mem.Allocator, request: Request, api: *Api, handle: *anyopaque) !Result {
    const cursor = try parseCursorForRequest(request, .primary);
    const query_c = try toCString(gpa, request.query);
    defer gpa.free(query_c);

    const ffi_result = api.live_grep(handle, query_c.ptr, 1, grep_max_file_size, 0, true, cursor.offset, page_size, 0, 0, 0, true);
    const grep_result = try unwrapHandle(c.FffGrepResult, api, ffi_result);
    defer api.free_grep_result(grep_result);

    if (grep_result.regex_fallback_error) |message| {
        return fail(gpa, std.mem.span(message));
    }
    if (grep_result.count > 0) return formatGrep(gpa, request, grep_result, false);
    if (request.cursor != null) return okText(gpa, "0 matches.\n");

    if (std.mem.indexOfScalar(u8, request.query, '/') != null) {
        if (try formatPathSuggestion(gpa, request.query, api, handle)) |result| return result;
    }
    return formatFuzzySuggestions(gpa, request.query, api, handle);
}

fn runFffFiles(gpa: std.mem.Allocator, request: Request, api: *Api, handle: *anyopaque) !Result {
    const cursor = try parseCursorForRequest(request, .primary);
    const query_c = try toCString(gpa, request.query);
    defer gpa.free(query_c);

    const ffi_result = api.search(handle, query_c.ptr, null, 0, cursor.offset, page_size, 100, 3);
    const search_result = try unwrapHandle(c.FffSearchResult, api, ffi_result);
    defer api.free_search_result(search_result);
    return formatFiles(gpa, request, search_result);
}

fn runFffDirectories(gpa: std.mem.Allocator, request: Request, api: *Api, handle: *anyopaque) !Result {
    const cursor = try parseCursorForRequest(request, .primary);
    const query_c = try toCString(gpa, request.query);
    defer gpa.free(query_c);

    const ffi_result = api.search_directories(handle, query_c.ptr, null, 0, cursor.offset, page_size);
    const dir_result = try unwrapHandle(c.FffDirSearchResult, api, ffi_result);
    defer api.free_dir_search_result(dir_result);
    return formatDirectories(gpa, request, dir_result);
}

fn formatGrep(gpa: std.mem.Allocator, request: Request, result: *c.FffGrepResult, approximate: bool) !Result {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;
    if (approximate) try writer.writeAll("No results found for regex. Showing fuzzy matches:\n\n");

    const count = @min(result.count, if (approximate) fuzzy_suggestions_count else page_size);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const item = &result.items[index];
        try writer.print("{s}:{}:{s}\n", .{
            spanOrEmpty(item.relative_path),
            item.line_number,
            spanOrEmpty(item.line_content),
        });
    }
    if (!approximate) {
        if (result.next_file_offset > 0) {
            const cursor = try encodeCursor(gpa, .{ .mode = request.mode, .phase = .primary, .offset = result.next_file_offset, .query_hash = hashQuery(request.query) });
            defer gpa.free(cursor);
            try writer.print("\nMore results available. Pass cursor=\"{s}\" to continue.\n", .{cursor});
        }
    }
    return okOwned(gpa, try out.toOwnedSlice());
}

fn formatFiles(gpa: std.mem.Allocator, request: Request, result: *c.FffSearchResult) !Result {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;
    if (result.count == 0) try writer.writeAll("0 results.\n");
    var index: u32 = 0;
    while (index < result.count) : (index += 1) {
        try writer.print("{s}\n", .{spanOrEmpty(result.items[index].relative_path)});
    }
    try appendCursorHint(gpa, writer, request, result.count, result.total_matched);
    return okOwned(gpa, try out.toOwnedSlice());
}

fn formatDirectories(gpa: std.mem.Allocator, request: Request, result: *c.FffDirSearchResult) !Result {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;
    if (result.count == 0) try writer.writeAll("0 results.\n");
    var index: u32 = 0;
    while (index < result.count) : (index += 1) {
        try writer.print("{s}\n", .{spanOrEmpty(result.items[index].relative_path)});
    }
    try appendCursorHint(gpa, writer, request, result.count, result.total_matched);
    return okOwned(gpa, try out.toOwnedSlice());
}

fn appendCursorHint(gpa: std.mem.Allocator, writer: *std.Io.Writer, request: Request, count: u32, total: u32) !void {
    if (count == 0) return;
    const cursor = try parseCursorForRequest(request, .primary);
    const next_offset = cursor.offset + count;
    if (next_offset >= total) return;
    const more_count = total - next_offset;
    const next_cursor = try encodeCursor(gpa, .{ .mode = request.mode, .phase = .primary, .offset = next_offset, .query_hash = hashQuery(request.query) });
    defer gpa.free(next_cursor);
    try writer.print("\n+{} more results. Pass cursor=\"{s}\" to continue.\n", .{ more_count, next_cursor });
}

fn formatPathSuggestion(gpa: std.mem.Allocator, query: []const u8, api: *Api, handle: *anyopaque) !?Result {
    const query_c = try toCString(gpa, query);
    defer gpa.free(query_c);

    const ffi_result = api.search(handle, query_c.ptr, null, 0, 0, 1, 100, 3);
    const search_result = try unwrapHandle(c.FffSearchResult, api, ffi_result);
    defer api.free_search_result(search_result);
    if (search_result.count == 0) return null;

    const text = try std.fmt.allocPrint(gpa, "No results found for regex. Did you mean this file?\n\n{s}\n", .{
        spanOrEmpty(search_result.items[0].relative_path),
    });
    return try okOwned(gpa, text);
}

fn formatFuzzySuggestions(gpa: std.mem.Allocator, query: []const u8, api: *Api, handle: *anyopaque) !Result {
    const cleaned = try cleanFuzzyQuery(gpa, query);
    defer gpa.free(cleaned);
    if (cleaned.len == 0) return okText(gpa, "0 matches.\n");

    const query_c = try toCString(gpa, cleaned);
    defer gpa.free(query_c);

    const ffi_result = api.live_grep(handle, query_c.ptr, 2, grep_max_file_size, 0, true, 0, fuzzy_suggestions_count, 0, 0, 0, true);
    const grep_result = try unwrapHandle(c.FffGrepResult, api, ffi_result);
    defer api.free_grep_result(grep_result);
    if (grep_result.count == 0) return okText(gpa, "0 matches.\n");
    return formatGrep(gpa, .{ .mode = .file_content, .query = query }, grep_result, true);
}

fn runFallback(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, request: Request, state: BackendState) !Result {
    assert(cwd.len > 0);
    assert(request.query.len > 0);
    _ = state;
    const command = try fallbackCommand(gpa, request.mode, request.query);
    defer gpa.free(command);

    var result = bash.run(gpa, io, cwd, command) catch |err| return fail(gpa, @errorName(err));
    defer result.deinit(gpa);
    if (result.code == 0) return formatFallbackSuccess(gpa, result.stdout);
    if (result.code == 1) return formatFallbackSuccess(gpa, result.stdout);
    return .{
        .stdout = try gpa.alloc(u8, 0),
        .stderr = try std.fmt.allocPrint(gpa, "search_codebase fallback failed:\n{s}", .{result.stderr}),
        .code = result.code,
    };
}

fn fallbackCommand(gpa: std.mem.Allocator, mode: Mode, query: []const u8) ![]u8 {
    const quoted = try quoteShell(gpa, query);
    defer gpa.free(quoted);
    return switch (mode) {
        .file_content => std.fmt.allocPrint(gpa,
            \\set -o pipefail; if command -v rg >/dev/null 2>&1; then rg --line-number --color never --no-heading -- {s} . | head -n 50; else grep -RInE --exclude-dir=.git -- {s} . | head -n 50; fi
        , .{ quoted, quoted }),
        .file_names => std.fmt.allocPrint(gpa,
            \\set -o pipefail; if command -v rg >/dev/null 2>&1; then rg --files | rg -- {s} | head -n 50; else find . -type f | grep -E -- {s} | head -n 50; fi
        , .{ quoted, quoted }),
        .directories => std.fmt.allocPrint(gpa,
            \\set -o pipefail; find . -type d | grep -E -- {s} | head -n 50
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

fn parseCursorForRequest(request: Request, phase: Phase) !Cursor {
    assert(request.query.len > 0);
    if (request.cursor) |raw| {
        const cursor = decodeCursor(raw) orelse return error.InvalidCursor;
        if (cursor.mode != request.mode) return error.InvalidCursor;
        if (cursor.phase != phase) return error.InvalidCursor;
        if (cursor.query_hash != hashQuery(request.query)) return error.InvalidCursor;
        return cursor;
    }
    return .{ .mode = request.mode, .phase = phase, .offset = 0, .query_hash = hashQuery(request.query) };
}

fn encodeCursor(gpa: std.mem.Allocator, cursor: Cursor) ![]u8 {
    assert(cursor.offset > 0);
    return std.fmt.allocPrint(gpa, "nova-search-v1:{s}:primary:{}:{x}", .{
        cursor.mode.name(),
        cursor.offset,
        cursor.query_hash,
    });
}

fn decodeCursor(raw: []const u8) ?Cursor {
    if (raw.len == 0) return null;
    var iter = std.mem.splitScalar(u8, raw, ':');
    const prefix = iter.next() orelse return null;
    if (!std.mem.eql(u8, prefix, "nova-search-v1")) return null;
    const mode = Mode.parse(iter.next() orelse return null) orelse return null;
    const phase_raw = iter.next() orelse return null;
    if (!std.mem.eql(u8, phase_raw, "primary")) return null;
    const offset = std.fmt.parseInt(u32, iter.next() orelse return null, 10) catch return null;
    const query_hash = std.fmt.parseInt(u64, iter.next() orelse return null, 16) catch return null;
    if (iter.next() != null) return null;
    if (offset == 0) return null;
    return .{ .mode = mode, .phase = .primary, .offset = offset, .query_hash = query_hash };
}

fn hashQuery(query: []const u8) u64 {
    assert(query.len > 0);
    return std.hash.Wyhash.hash(0x6e6f76615f736561, query);
}

fn cleanFuzzyQuery(gpa: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (query) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            try out.writer.writeByte(std.ascii.toLower(byte));
        } else {
            if (byte == ' ') try out.writer.writeByte(' ');
        }
    }
    return out.toOwnedSlice();
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

test "cursor validates mode and query" {
    const gpa = std.testing.allocator;
    const cursor = try encodeCursor(gpa, .{ .mode = .file_content, .phase = .primary, .offset = 50, .query_hash = hashQuery("abc") });
    defer gpa.free(cursor);
    const parsed = decodeCursor(cursor) orelse return error.TestFailed;
    try std.testing.expectEqual(Mode.file_content, parsed.mode);
    try std.testing.expectEqual(@as(u32, 50), parsed.offset);
    try std.testing.expectEqual(hashQuery("abc"), parsed.query_hash);
}

test "clean fuzzy query removes regex punctuation" {
    const gpa = std.testing.allocator;
    const cleaned = try cleanFuzzyQuery(gpa, "Tool.*registry(foo_bar)");
    defer gpa.free(cleaned);
    try std.testing.expectEqualStrings("toolregistryfoobar", cleaned);
}

test "shell quoting handles single quotes" {
    const gpa = std.testing.allocator;
    const quoted = try quoteShell(gpa, "can't");
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings("'can'\\''t'", quoted);
}
