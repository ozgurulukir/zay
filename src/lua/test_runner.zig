//! Lua test runner for Nova plugins.
//!
//! Loads the test_runner.lua library, then loads and runs Lua test files
//! from the specified directory. Each test file is executed in a sandboxed
//! Lua state with the test_runner module available via `require("test_runner")`.

const std = @import("std");
const c = @import("c");
const State = @import("../lua/state.zig").State;
const sandbox = @import("../lua/sandbox.zig");

/// Run Lua test files. Each file is loaded into a fresh sandboxed state
/// with the test_runner module pre-loaded. Returns true if all tests pass.
pub fn runTestFiles(gpa: std.mem.Allocator, io: std.Io, file_paths: []const []const u8) !bool {
    var all_passed = true;
    for (file_paths) |path| {
        const passed = try runSingleTestFile(gpa, io, path);
        if (!passed) all_passed = false;
    }
    return all_passed;
}

/// Run a single Lua test file.
fn runSingleTestFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    // Read the test file
    const content = try readFile(gpa, io, path);
    defer gpa.free(content);

    // Create a sandboxed state with full access (tests need io for output)
    var L = try sandbox.createSandboxedState(.{ .full_access = true });
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    // Pre-load the test_runner module
    const runner_src = @embedFile("test_runner.lua");
    const null_term_runner = try std.fmt.allocPrintSentinel(gpa, "{s}", .{runner_src}, 0);
    defer gpa.free(null_term_runner);

    // Load and execute the test runner library
    if (!L.doString(null_term_runner)) {
        const err = L.getErrorMessage();
        std.log.err("lua.test_runner.load_failed err={s}", .{err orelse "unknown"});
        return false;
    }

    // The test_runner module is now in the global table as the return value
    // Store it as a global so test files can require it
    _ = c.lua_setglobal(L.handle, "test_runner");

    // Load and execute the test file
    const null_term_test = try std.fmt.allocPrintSentinel(gpa, "{s}", .{content}, 0);
    defer gpa.free(null_term_test);

    // Load the test file as a function
    L.loadString(null_term_test) catch {
        const err = L.getErrorMessage();
        std.log.err("lua.test_file.load_failed path={s} err={s}", .{ path, err orelse "unknown" });
        L.pop(1);
        return false;
    };

    // Call it — the test file calls test.run() and prints results
    const rc = L.pcall(0, 0);
    if (rc != c.LUA_OK) {
        const err = L.getErrorMessage();
        std.log.err("lua.test_file.run_failed path={s} err={s}", .{ path, err orelse "unknown" });
        L.pop(1);
        return false;
    }

    return true;
}

/// Read a file's contents into an owned slice.
fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const bytes = try gpa.alloc(u8, @intCast(stat.size));
    errdefer gpa.free(bytes);
    var reader = file.reader(io, &.{});
    try reader.interface.readSliceAll(bytes);
    return bytes;
}
