//! Lua test runner for Nova plugins.
//!
//! Loads the test_runner.lua library, then loads and runs Lua test files.
//! Each test file is executed in a sandboxed Lua state with the test_runner
//! module pre-set as the global `test_runner` (not via `require`). After the
//! file chunk runs, `test_runner.run()` is auto-invoked and its boolean
//! verdict is the pass/fail gate — a file with zero tests fails.

const std = @import("std");
const log = std.log.scoped(.lua);
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
    return runTestSource(gpa, io, content);
}

/// Run a Lua test file's source in a fresh sandboxed state and report whether
/// every assertion passed. The test_runner module is pre-loaded as a global;
/// the file chunk is executed, then `test_runner.run()` is auto-invoked and its
/// boolean result is the pass/fail verdict. A file passes iff the chunk runs
/// cleanly AND run() returns true (which is false for zero tests).
fn runTestSource(gpa: std.mem.Allocator, io: std.Io, content: []const u8) !bool {
    var L = try sandbox.createSandboxedStateWithIo(.{ .full_access = true }, io);
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
        log.warn("lua.test_runner.load_failed err={s}", .{err orelse "unknown"});
        return false;
    }

    // The test_runner module is now in the global table as the return value.
    // Store it as a global so test files can reference it.
    _ = c.lua_setglobal(L.handle, "test_runner");

    // Load and execute the test file
    const null_term_test = try std.fmt.allocPrintSentinel(gpa, "{s}", .{content}, 0);
    defer gpa.free(null_term_test);

    // Load the test file as a function
    L.loadString(null_term_test) catch {
        const err = L.getErrorMessage();
        log.warn("lua.test_file.load_failed err={s}", .{err orelse "unknown"});
        L.pop(1);
        return false;
    };

    // Call it — the test file registers suites (it may also call test.run()
    // itself; run() is idempotent so a later auto-run is a no-op).
    const rc = L.pcall(0, 0);
    if (rc != c.LUA_OK) {
        const err = L.getErrorMessage();
        log.warn("lua.test_file.run_failed err={s}", .{err orelse "unknown"});
        L.pop(1);
        return false;
    }

    // Auto-run: load `return test_runner.run()` and read the boolean verdict.
    // This is load-bearing — a file that never calls test.run() still gets its
    // suites executed and its pass/fail propagated, and an empty file (zero
    // `it` blocks) fails.
    const auto_run = "return test_runner.run()";
    L.loadString(auto_run) catch {
        const err = L.getErrorMessage();
        log.warn("lua.test_runner.autorun_load_failed err={s}", .{err orelse "unknown"});
        L.pop(1);
        return false;
    };
    const run_rc = L.pcall(0, 1);
    if (run_rc != c.LUA_OK) {
        const err = L.getErrorMessage();
        log.warn("lua.test_runner.autorun_failed err={s}", .{err orelse "unknown"});
        L.pop(1);
        return false;
    }
    const passed = L.toBoolean(-1);
    L.pop(1);
    return passed;
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

// ── Tests ────────────────────────────────────────────────────────────
//
// runTestSource is exercised directly with source slices so the tests don't
// touch the filesystem. The state is created without Io (full-access sandbox),
// so it can run inline.

test "test runner: passing assertion reports true" {
    const src =
        \\local test = test_runner
        \\test.describe("s", function()
        \\  test.it("passes", function() test.assert.equal(4, 2 + 2) end)
        \\end)
    ;
    try std.testing.expect(try runTestSource(std.testing.allocator, src));
}

test "test runner: failing assertion reports false (the regression)" {
    const src =
        \\local test = test_runner
        \\test.describe("s", function()
        \\  test.it("fails", function() test.assert.equal(4, 5) end)
        \\end)
    ;
    try std.testing.expect(!(try runTestSource(std.testing.allocator, src)));
}

test "test runner: file that never calls test.run() still reports correctly" {
    const src =
        \\local test = test_runner
        \\test.describe("s", function()
        \\  test.it("passes", function() test.assert.equal(1, 1) end)
        \\end)
        \\-- no explicit test.run() — the Zig runner auto-runs it
    ;
    try std.testing.expect(try runTestSource(std.testing.allocator, src));
}

test "test runner: empty file (zero it blocks) reports false" {
    const src =
        \\local test = test_runner
        \\test.describe("s", function()
        \\  -- no tests
        \\end)
    ;
    try std.testing.expect(!(try runTestSource(std.testing.allocator, src)));
}

test "test runner: explicit test.run() then auto-run does not double-execute" {
    const src =
        \\local test = test_runner
        \\test.describe("s", function()
        \\  test.it("passes", function() test.assert.equal(2, 2) end)
        \\end)
        \\test.run()
    ;
    try std.testing.expect(try runTestSource(std.testing.allocator, src));
}

test "test runner: syntax error in file reports false" {
    const src = "this is not lua @@@";
    try std.testing.expect(!(try runTestSource(std.testing.allocator, src)));
}
