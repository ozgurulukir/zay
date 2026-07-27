//! Lua plugin test runner entry point.
//!
//! Built by `zig build test-plugin`. Takes Lua test file paths as
//! command-line arguments and runs them through the Nova Lua sandbox.
//! Each test file uses the test_runner module (describe/it/assert).

const std = @import("std");
const lua_test_runner = @import("nova").lua_test_runner;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect test file paths from args (skip argv[0])
    var test_files: std.ArrayList([]const u8) = .empty;
    defer test_files.deinit(allocator);

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();

    // Skip argv[0]
    _ = args_iter.next();

    while (args_iter.next()) |arg| {
        try test_files.append(allocator, arg);
    }

    if (test_files.items.len == 0) {
        std.debug.print("Usage: lua-test-runner <test-file.lua> [test-file.lua ...]\n", .{});
        std.process.exit(0);
    }

    const all_passed = try lua_test_runner.runTestFiles(allocator, init.io, test_files.items);

    if (!all_passed) {
        @import("std").process.exit(1);
    }
}
