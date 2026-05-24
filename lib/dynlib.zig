const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const DynLib = std.DynLib;

const HMODULE = *anyopaque;
const FARPROC = *anyopaque;

extern "kernel32" fn LoadLibraryExW(
    lpLibFileName: [*:0]const u16,
    hFile: ?*anyopaque,
    dwFlags: u32,
) callconv(.winapi) ?HMODULE;

extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(.winapi) i32;
extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?FARPROC;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

lib: Lib,

const os = builtin.os.tag;
const LOAD_LIBRARY_SEARCH_DEFAULT_DIRS: u32 = 0x1000;

const Self = @This();
const Lib = if (os == .windows) HMODULE else DynLib;
pub const Error = error{
    UnsupportedOS,
    LoadFailed,
    OutOfMemory,
};

/// Open a shared library. If `path` is empty the platform's library-search
/// path is used (LD_LIBRARY_PATH / DYLD_LIBRARY_PATH / PATH); otherwise
/// the lib is loaded from `<path>/<platform-prefix><name><platform-suffix>`.
pub fn open(alloc: Allocator, path: []const u8, name: []const u8) Error!Self {
    const file_name = try libName(alloc, name);
    defer alloc.free(file_name);

    const full_path = if (path.len == 0)
        alloc.dupe(u8, file_name) catch return error.OutOfMemory
    else
        std.fs.path.join(alloc, &.{ path, file_name }) catch return error.OutOfMemory;
    defer alloc.free(full_path);

    const lib_handle = switch (os) {
        .windows => win: {
            var path_utf16: [std.fs.max_path_bytes:0]u16 = undefined;
            const n = std.unicode.utf8ToUtf16Le(&path_utf16, full_path) catch return error.LoadFailed;
            if (n >= path_utf16.len) return error.LoadFailed;
            path_utf16[n] = 0;
            break :win LoadLibraryExW(
                @ptrCast(path_utf16[0..n :0].ptr),
                null,
                LOAD_LIBRARY_SEARCH_DEFAULT_DIRS,
            ) orelse return error.LoadFailed;
        },
        else => DynLib.open(full_path) catch return error.LoadFailed,
    };

    return .{ .lib = lib_handle };
}

fn libName(alloc: Allocator, name: []const u8) Error![]const u8 {
    return switch (os) {
        .linux => std.fmt.allocPrint(alloc, "lib{s}.so", .{name}) catch error.OutOfMemory,
        .macos => std.fmt.allocPrint(alloc, "lib{s}.dylib", .{name}) catch error.OutOfMemory,
        .windows => std.fmt.allocPrint(alloc, "{s}.dll", .{name}) catch error.OutOfMemory,
        else => error.UnsupportedOS,
    };
}

pub fn lookup(self: *Self, T: type, name: [:0]const u8) ?T {
    return switch (os) {
        .windows => @ptrCast(GetProcAddress(self.lib, name.ptr) orelse return null),
        else => self.lib.lookup(T, name),
    };
}

pub fn close(self: *Self) void {
    switch (os) {
        .windows => _ = FreeLibrary(self.lib),
        else => self.lib.close(),
    }
}
