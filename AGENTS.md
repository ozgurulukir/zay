# Nova Guidelines

This project uses Zig version 0.16

Always consult the tigerstyle skill when writing code.

## Setup

- After cloning, vendor `fff` (build into `vendor/fff/libfff_c.so`) and the ModernBERT ONNX model (`vendor/local-models/ModernBERT-bash-classifier`). Both are gitignored.
- Use `OMP_WAIT_POLICY=passive` at runtime to avoid MKL/CPU spin in the embedding worker.
- `zig build install -Doptimize=ReleaseFast --prefix $HOME/.local` produces an installable binary under `~/.local/bin/`.

## Building the TUI

TUI built with libvaxis vxfw (source in zig-pkg). Prefer framework primitives.

**vxfw gotcha:** widget methods like `TextField.widget()` are *mutating* — they take `*Self`, not `*const Self`. Accessors returning `*TextField` must be declared on `*App`, not `*const App`, or the call site fails to type-check.

**Zig 0.16 field rule:** `pub` cannot precede a field declaration — only functions/variables. Cross-module field access goes through `pub fn` accessors (`getX()` form, never `X()`, because of the field-vs-method name collision).

**TUI module split.** `src/tui.zig` holds the `App` lifecycle and the top-level
`RootWidget`; the rest of `src/tui/` is split by concern. See `README.md`
Architecture for the current module list (kept in sync as `tui.zig` shrinks).

**Domain extraction pattern.** Isolated domain clusters (lane lifecycle, diff
lifecycle, session switching, at-search, transcript navigation, permission,
event callbacks, queue) live under `src/tui/` as free-function modules.
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

**Viewport scrolling pattern.** Standardize overlay list viewports using `panel.ViewportWindow.compute(selection, total_count, surface.size.height)` in `src/tui/widgets/panel.zig`. Use `viewport.screenRow(i)` for row rendering calculations.

**Provider polymorphism pattern.** Unify static builtin `config_mod.Provider` and dynamic `modelsdev.Provider` handles using `ProviderHandle = union(enum) { builtin: config_mod.Provider, dynamic: modelsdev.Provider }` in `src/tui/widgets/provider_picker.zig`.

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
- Keep functions small; push pure computation into helpers.
- Comments should explain why, not what.
- **POSIX Environment Access:** Never index `std.c.environ` directly in loops (`while (std.c.environ[i]) |e|`). In Zig 0.16 on POSIX, `std.c.environ` is `[*:null]?[*:0]u8`. Use `const env_slice = std.mem.span(std.c.environ);` and pass to `std.process.Environ.createMap(.{ .block = .{ .slice = env_slice } }, gpa)` to prevent null-pointer segfaults in multi-threaded contexts.
- **Models.dev Registry Allocations:** `modelsdev.Registry` string storage uses an `ArrayList(u8)`. To prevent dangling slice pointers when building or merging providers, accumulate string offsets via `StringRef` (`start`, `len`) and resolve slice pointers only after all string appends complete.
- **Dynamic Context Compaction:** Never hardcode fixed context retention budgets (e.g. 20,000 tokens) when compacting history. Use `compaction.keepRecentTokens(context_window)` so small-context models (8K/16K/32K) keep a scaled history window (%35 max 20,000) and can always compact below their swap watermark.

## Verifying

Run:

- `zig fmt`
- `zig build test`

## Known Issues

- **Session resume shows blank TUI (fixed).** When the app resumes the last session at
  startup (`root.zig` → `initResume`), the agent is rehydrated with messages from the
  session DB but the TUI transcript was never populated — only the logo animation was
  appended. Fix: call `app.rebuildTranscriptFromAgent()` in `tui.run()` before deciding
  whether to show the logo. For a resumed session the transcript is populated from the
  agent's message history; for a new session the transcript stays empty and the logo
  falls through as before.

- **High CPU usage from spinlocks.** `std.atomic.Mutex` busy-waits and pegs the CPU on multi-core. Use `std.Io.Mutex` and `std.Io.Condition` instead (paired via `static_thread_pool` or similar). Symptom: 80% CPU at idle, drops to ~2% after the fix. Files affected: `lib/logger.zig`, `src/agent.zig`, `src/background.zig`, `src/session.zig`.

- **Double-free in `postAgentEvent` / `postTurnFailed` / `runAgentTurn` (fixed).** `postAgentEvent` takes ownership of the event — on error it frees the event's data internally. The callers' catch blocks were freeing `message_text` again (double-free), and the QueueFull handler in `postAgentEvent` was manually cleaning up `event_ptr` before `return error.TurnCancelled`, which triggered errdefer to repeat the same cleanup. Pattern: caller allocates `message_text`, passes it into `.{ .turn_failed = message_text }`, `postAgentEvent` frees it on error, caller's catch block frees it again. Fix: remove `worker_context.gpa.free(message_text)` from catch blocks in `runAgentTurn` and `postTurnFailed`; remove manual `event_ptr.deinit`+`destroy` before `return error.TurnCancelled` in `postAgentEvent`.
