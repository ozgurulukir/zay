# Nova Guidelines

This project uses Zig version 0.16

Always consult the tigerstyle skill when writing code.

## Setup

- `code-tandem` lives at `/home/aristo/.local/bin/code-tandem`; server stays active for code search/coupling analysis.
- The project is indexed with ~1404 symbols; use `index_workspace` then `semantic_search` for conceptual queries, `grep` for exact patterns.
- After cloning, vendor `fff` (build into `vendor/fff/libfff_c.so`) and the ModernBERT ONNX model. Both are gitignored.
- Use `OMP_WAIT_POLICY=passive` at runtime to avoid MKL/CPU spin in the embedding worker.

## Building the TUI

We use libvaxis vxfw for building the TUI. The source code for this library is inside zig-pkg.

Prefer to use the primitives provided by the framework as much as possible.

**vxfw gotcha:** widget methods like `TextField.widget()` are *mutating* — they take `*Self`, not `*const Self`. Accessors that return `*TextField` from a struct must be declared on `*App`, not `*const App`, or the call site fails to type-check.

## TUI Module Split (in progress)

`src/tui.zig` is a monolith (~8500 lines) and is being split into per-feature files under `src/tui/`. See `_pm/Projects/tui-split/` for the roadmap.

**Pattern for extracted modules:**

- Module takes typed `*App` and `*RootWidget` parameters; the boundary in `tui.zig` does `@ptrCast` from anyopaque.
- Modules call `pub` methods and `pub` accessors on `App`/`RootWidget` — they do not access fields directly.
- New `pub const` for top-level types that other modules need (`RootWidget` was `const` before R1).
- Bulk-add `pub` to existing struct methods with sed, e.g. `sed -i -E 's/^    fn (METHOD1|METHOD2)\(/\1(/' src/tui.zig` (verify with `--debug=s` to confirm no false positives).

**Strangler Fig rule for test compatibility:** `RootWidget.captureEvent` is called directly from inline tests at `src/tui.zig:6520-7462`. When extracting, keep the original method on `RootWidget` as a one-line delegate to the new module — do not remove it.

**Helper rule:** Small unrelated helpers used by the extracted code (e.g. `shouldOpenCommandMenuForSlash`, `ChipRect.contains`) stay in `tui.zig` but their visible members must be marked `pub`.

**Accessor rule:** When a struct already has a field named `X`, the accessor cannot be `X()` — name it `getX()`. (Field vs. method name collision is a Zig 0.16 compile error: "duplicate struct member name 'X'".)

## Zig Development

Use `zigdoc` to discover current APIs for the Zig standard library and any third-party dependencies before coding.

Examples:

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

**HashMap/StringHashMap (default to unmanaged):**

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
- keep tests inline with the code they cover; register them in `src/main.zig`

## Safety

- Add assertions at API boundaries and state transitions; avoid trivial assertions.
- Keep functions small and push pure computation into helpers.
- Comments should explain why, not what.

## Verifying

Run the following:

- `zig fmt`

- `zig build test`

## Known Issues

- **High CPU usage from spinlocks.** `std.atomic.Mutex` busy-waits and pegs the CPU on multi-core. Use `std.Io.Mutex` and `std.Io.Condition` instead (paired via `static_thread_pool` or similar). Symptom: 80% CPU at idle, drops to ~2% after the fix. Files affected: `lib/logger.zig`, `src/agent.zig`, `src/background.zig`, `src/session.zig`.
- **`tui.zig` is too large.** The monolith was 8586 lines (28× over the 300-line split threshold). `handleCommandKey` is a hub function with cycles=true in the call graph (882 nodes, 12491 edges). The TUI Module Split project is incrementally extracting these.
