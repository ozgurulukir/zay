# Zay Development Guide

Read this guide before writing Zig code. Use the repository’s `tigerstyle` skill for the full coding discipline and [Building](BUILDING.md#verifying) for verification and test-runner behavior. Subsystem contracts live in [Engineering patterns](PATTERNS.md).

## Zig Development

Use `zigdoc` to discover APIs before coding.

```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc vaxis.Window
```

## Current Zig Patterns

**ArrayList:**

```zig
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);
```

**HashMap/StringHashMap:**

```zig
var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(allocator);
try map.put(allocator, "key", 42);
```

**stdout/stderr writer:**

```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};
try writer.interface.print("hello {s}\n", .{"world"});
```

**build.zig executable:**

```zig
b.addExecutable(.{
    .name = "foo",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

**JSON writing:**

```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};

var jw: std.json.Stringify = .{
    .writer = &writer.interface,
    .options = .{ .whitespace = .indent_2 },
};
try jw.write(my_struct);
```

**Allocating writer:**

```zig
var writer: std.Io.Writer.Allocating = .init(allocator);
defer writer.deinit();
try writer.writer.print("hello {s}", .{"world"});
const output = try writer.toOwnedSlice();
```

## Zig Style

- `camelCase` for functions and methods
- lower-case `snake_case` for variables, parameters, and constants
- `PascalCase` for types, structs, and enums
- prefer `const foo: Type = .{ .field = value };` over `const foo = Type{ .field = value };`
- preferred file order: `//!` module doc comment, `const Self = @This();`, imports, `const log = std.log.scoped(...)`
- pass allocators explicitly; use `errdefer` for cleanup on error
- keep tests inline with the code they cover; a new file's tests only run once the file is reachable from the `src/root.zig` test root (its `refAllDecls`) — see [Test runner quirks](BUILDING.md#test-runner-quirks-read-before-debugging-a-failure)

## Ownership and API safety

- Add assertions at API boundaries and state transitions; avoid trivial assertions.

- Keep functions small; push pure computation into helpers.

- Comments explain why, not what.

- **`readSliceShort` vs `readSliceAll`.** `readSliceShort` returns the actual byte count and never `error.EndOfStream`; `readSliceAll` returns `error.EndOfStream` when the buffer can't fill. Use `readSliceShort` when truncating oversized inputs (e.g. project rule files capped at 64KB) and shrink the slice on a short read. Also: a `return null` inside a `catch` block does **not** fire an `errdefer` — free the buffer explicitly before returning.

- **Epoch date math for `todayUtc`.** `std.Io.Timestamp.now(io, .real)` → `EpochSeconds.getEpochDay()` → `EpochDay.calculateYearDay()` → `YearAndDay.calculateMonthDay()` → `MonthAndDay`. `month.numeric()` is 1-based; `day_index` is 0-based (add 1).

## Zig 0.16 API gaps

- **Zig 0.16 std API gaps.** Use C shims or `std.Io` equivalents: no `std.fs.realpathAlloc` → `std.c.realpath` (returns null on ENOENT); no `std.posix.symlink` → `std.c.symlink`; no `std.fs.makeDirAbsolute` → `std.Io.Dir.cwd().createDirPath`; no `std.time.nanoTimestamp` → `std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts)` (instruction hook has no `Io` handle; fall back to 0 = no timeout on failure).

## Debugging optimized builds

- **Debug prints masking segfaults.** Adding `std.debug.print` can change a segfault into a downstream error (e.g. `session.resume.failed err=Sqlite`). Suspect use-after-free or double-free between the crash site and the new error.

- **ReleaseFast debugging.** Use `std.debug.print` not `std.log.debug` — ReleaseFast strips log levels, so `std.log.debug` is a no-op.
