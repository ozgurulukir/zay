# Nova Guidelines

This project uses Zig version 0.16

Always consult the tigerstyle skill when writing code.

## Setup

- After cloning, vendor `fff` (build into `vendor/fff/libfff_c.so`) and the ModernBERT ONNX model (`vendor/local-models/ModernBERT-bash-classifier`). Both are gitignored.
- Use `OMP_WAIT_POLICY=passive` at runtime to avoid MKL/CPU spin in the embedding worker.
- `zig build install -Doptimize=ReleaseFast --prefix $HOME/.local` produces an installable binary under `~/.local/bin/`.

## Building the TUI

We use libvaxis vxfw for building the TUI. The source code for this library is inside zig-pkg.

Prefer to use the primitives provided by the framework as much as possible.

**vxfw gotcha:** widget methods like `TextField.widget()` are *mutating* — they take `*Self`, not `*const Self`. Accessors that return `*TextField` from a struct must be declared on `*App`, not `*const App`, or the call site fails to type-check.

**Zig 0.16 field rule:** `pub` cannot precede a field declaration — only functions/variables. Cross-module field access goes through `pub fn` accessors (`getX()` form, never `X()`, because of the field-vs-method name collision).

**TUI module split.** `src/tui.zig` holds the `App` lifecycle and the top-level
`RootWidget`; the rest of `src/tui/` is split by concern. See `README.md`
Architecture for the current module list (kept in sync as `tui.zig` shrinks).

**Domain extraction pattern.** Isolated domain clusters (lane lifecycle, diff
lifecycle, session switching) live under `src/tui/` as free-function modules.
Each module imports `const tui = @import("../tui.zig")` and defines `pub fn`
taking `*App` as the first parameter. The original App method stays as a
1-line delegate (Strangler Fig) so inline tests in `tui.zig` resolve via the
struct. When a private App method is needed from the new module, promote it to
`pub` — not `pub const` (that is for module-level re-exports of nested types).

**Widget extraction pattern.** Isolated widgets live under `src/tui/widgets/`.
A new widget file declares the outer border widget as
`pub const NameWidget = struct { app: *App, pub fn widget(...) vxfw.Widget { ... } }`
and a private `Inner` struct built inside `draw()` from a `vxfw.DrawContext`.
The file imports `const tui = @import("../../tui.zig");`,
`const tui_style = @import("../style.zig");`, `const panel = @import("panel.zig");`
and re-aliases `const App = tui.App;`. Nested types from other modules
(e.g. `BackgroundManager.JobView`, `ApprovalSnapshot`) are re-exported through
`pub const` in `tui.zig` so widget files can reach them as `tui.<module>.<Type>`.

**Per-mode command routing.** `src/tui/command_router.zig` holds one struct per
`App.Mode` variant. Each struct owns a `handle` method that used to be a private
method on `App`; the dispatcher is a free function delegating to the right
struct. This is the place to add new per-mode logic — don't reintroduce
private methods on `App` for key handling.

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
