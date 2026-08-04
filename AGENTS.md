# Nova Guidelines

This project uses Zig 0.16. Consult the tigerstyle skill before writing code.

## Setup

- Vendor `fff` (build into `vendor/fff/libfff_c.so`) and the ModernBERT ONNX model (`vendor/local-models/ModernBERT-bash-classifier`) after cloning. Both are gitignored.
- Set `OMP_WAIT_POLICY=passive` at runtime to avoid MKL/CPU spin in the embedding worker.
- `zig build install -Doptimize=ReleaseFast --prefix $HOME/.local` installs to `~/.local/bin/`.

## Patterns & Engineering Notes

The codebase patterns (TUI architecture, MCP, Lua plugins, AI tool schema, type system, models.dev, config layering, reasoning, compaction, session resume) and the vxfw build gotchas live in `docs/PATTERNS.md`. Read the relevant section when working on a subsystem — they are intentionally not ingested into the system prompt.

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
- keep tests inline with the code they cover; a new file's tests only run once the file is reachable from the `src/root.zig` test root (its `refAllDecls`) — see **Test runner quirks**

## Safety

- Add assertions at API boundaries and state transitions; avoid trivial assertions.
- Keep functions small; push pure computation into helpers.
- Comments should explain why, not what.
- **POSIX Environment Access:** Never index `std.c.environ` directly in loops. In Zig 0.16 on POSIX, `std.c.environ` is `[*:null]?[*:0]u8`. Use `const env_slice = std.mem.span(std.c.environ);` and pass to `std.process.Environ.createMap(.{ .block = .{ .slice = env_slice } }, gpa)` to prevent null-pointer segfaults in multi-threaded contexts.
- **Models.dev Registry Allocations:** `modelsdev.Registry` string storage uses an `ArrayList(u8)`. To prevent dangling slice pointers when building or merging providers, accumulate string offsets via `StringRef` (`start`, `len`) and resolve slice pointers only after all string appends complete.
- **Dynamic Context Compaction:** Never hardcode fixed context retention budgets (e.g. 20,000 tokens) when compacting history. Use `compaction.keepRecentTokens(context_window)` so small-context models (8K/16K/32K) keep a scaled history window (35% of window, capped at the config `keepRecentTokens` default 8,000) and can always compact below their swap watermark. When a real usage anchor is available, `compaction.calibrateKeepBudget(base, real, estimated)` shrinks the budget by the measured ratio so chars/4 undercounts (CJK ≈ 1.5 chars/token) still land the cut below swap; it never grows the budget.
- **Streaming SSE Tool Call Deduplication & Parallel Remap:** In `src/ai/openai_compatible.zig`, tool call names and IDs are atomic in streaming — first complete value wins; subsequent deltas are ignored. This deduplicates repeated names (the `bashbash` fix) and prevents cross-tool concatenation. Some providers reuse `index: 0` for all parallel tool calls; `ToolCallStream` detects this by comparing tool-call IDs (always unique). When a new ID arrives at an occupied logical index, the call is forked into a new physical builder slot. Argument continuation deltas (no ID) route through the remap to the correct slot. Limitation: if the provider omits IDs entirely, collision detection is impossible and the second call is lost (first writer wins for the name).
- **Bash tool safety:** `validateCwd` (`src/tools/bash.zig`) keeps the cwd inside the project root, comparing against a **normalized** root (trailing slash can't defeat it) plus a best-effort realpath re-check so a symlink escaping the root is caught (realpath failure → lexical verdict). The destructive-command gate is **always armed**: `bash_safety.classify` takes an optional URL and runs the local matcher when none is configured. Temp files use hex-only names; stale `nova-bash-*` / `nova-bg_*` files older than 24h are pruned at startup; spills cap at 10MB.
- **Lua C-stack manipulation:** When building a Lua table of results from Zig (e.g. `walkAndSearch` in `plugin_api.zig`), the results table must stay on top of the stack across every entry. The correct idiom is `newTable()` (push table) → push entry fields + `lua_setfield(L, -2, ...)` → `lua_rawseti(L, -2, n)` (pops the entry, leaving the table on top). A stray extra push before `lua_rawseti` with the wrong table index (`-3` instead of `-2`) writes the bare integer into `results[n]` instead of the entry table and **leaks one table per match** onto the stack. Annotate the expected stack layout (`[ ... | results_table ]`, `[ ... | results_table | entry ]`) at each push/pop site so the balance is auditable.
- **Glob/pattern slicing:** Never unconditionally slice byte 0 off a user-supplied pattern (`fp[1..]`). When the pattern is empty, `fp[1..0]` is an out-of-bounds slice → Zig panic → `SIGABRT`. Lua treats `""` as truthy, so a plugin forwarding `file_pattern = ""` (e.g. `project-info`'s `list_project_files({ pattern = "" })`) reaches this path directly. Extract suffix logic into a pure `fileNameMatches(name, pattern)` helper that handles empty (match-all), `"*x"` (strip leading star), and bare-suffix cases, and unit-test the empty case explicitly.
- **Skill buffers freed on every path.** `loadOne` and `appendSkillBlock` (`src/skill.zig`) both use a plain `defer gpa.free(raw)` registered immediately after the alloc — never `errdefer` (which leaks on the success path). The buffer is read from disk (up to 256KB per skill) and only the frontmatter values are duped into the returned `Skill`/written into the prompt; without the defer, loading N skills leaks N×256KB per runtime creation and each `$skill` invocation leaks per turn. Registered *before* the `try readSliceAll`, the defer also covers a failed read.
- **Skill invocation dedup must match `find`'s case sensitivity.** `find` is case-insensitive (`eqlIgnoreCase`), so `collectInvocations`'s `contains` helper must also be case-insensitive. If `contains` uses exact `mem.eql`, a prompt like `$Tiger and $tiger` passes both tokens through (they look distinct to `contains`), and `promptPrefix` injects the same skill body twice — wasting tokens and confusing the model. Keep `contains` and `find` in lockstep.
- **Skill name validation rejects XML-special chars.** `isValidSkillName` rejects `"`, `'`, `&`, `<`, `>` in addition to whitespace and `$`. This is not just cosmetic: `appendSkillBlock` escapes these via `writeXmlEscaped`, but `collectInjectedSkillNames` (resume path) parses `<skill name="…">` without unescaping. If a name contained `"`, the escaped `&quot;` would be returned verbatim on resume, showing the wrong skill name in the `[SKILL]` transcript row. Rejecting XML-special chars at load makes the "no unescaping needed" invariant (TD-14) hold.
- **`McpClient.stop()` must free a `.failed` reason.** `stop` clobbers `lifecycle` to `.disabled`; if the client carries an owned failure reason (set via `setError` — e.g. the async connect worker's `runConnect` catch sets one on its clone before tearing it down), free `lifecycle.failed.reason` **before** overwriting the lifecycle, or the reason leaks silently (`deinit` calls `stop` before its `failed`-arm switch, so the switch can never see it). This was a real leak in the MCP failure path, caught by the async-connect tests.
- **Historical tool-result pruning must never prune everything when no turn exceeds budget.** `computeCutoff` (assembly.zig) counts a contiguous `.tool` run as **one turn** (increments only at run end), so a parallel batch of 8 tools counts as 1 turn — the direction is "keep more". When `cutoff_index == messages.len` (no turn exceeds the keep budget), the old code pruned the entire history; guard with `pruning_active = cutoff_index < messages.len` in `pruneHistoricalToolResultsViews`. Keep `estimatePrunedTokensRange` in lockstep by reusing `computeCutoff` over the full slice.
- **Persist before caching — the tree is the source of truth.** `appendPersisted` (manager.zig) writes to the DB first, then updates the cache. Cache-behind is healable on restart; cache-ahead is not. The session serializer maps OOM to `error.WriteFailed` (not `error.OutOfMemory`), so tests must expect that.
- **`readSliceShort` vs `readSliceAll`.** `readSliceShort` returns the actual byte count and never `error.EndOfStream`; `readSliceAll` returns `error.EndOfStream` when the buffer can't fill. Use `readSliceShort` when truncating oversized inputs (e.g. project rule files capped at 64KB) and shrink the slice on a short read. Also: a `return null` inside a `catch` block does **not** fire an `errdefer` — free the buffer explicitly before returning.
- **Mention/image ingestion caps.** `at_mention.zig` caps a single file mention at 64KB (`per_file_mention_max_bytes`), an aggregate of 256KB per turn (`turn_mention_aggregate_max_bytes`), and 4 images per message (`max_images_per_message`). Oversized files are head-truncated with a visible `[file truncated: {n} bytes, first {cap} inlined]` notice; over-cap images are skipped, not truncated.
- **Epoch date math for `todayUtc`.** `std.Io.Timestamp.now(io, .real)` → `EpochSeconds.getEpochDay()` → `EpochDay.calculateYearDay()` → `YearAndDay.calculateMonthDay()` → `MonthAndDay`. `month.numeric()` is 1-based; `day_index` is 0-based (add 1).
- **Lua sandbox instruction budget is per-dispatch, not per-session.** `resetInstructionBudget(L)` (`src/lua/sandbox.zig`) zeroes the instruction count and re-arms the timeout deadline before each tool call / event dispatch (`callToolHandler` in `plugin_api.zig`, `drainEventCallbacks` in `manager.zig`). Without it the count is a session accumulator and a busy plugin eventually fails every call with "instruction limit exceeded" for the rest of the session. The hook reads its state via `lua_getextraspace` hook data; the timeout check runs every 1000 instructions (coarse granularity, by design).
- **Bridge integer-clamp idiom.** When a Lua-supplied integer flows into a `u32` field, clamp on the `i64` *before* the `@intCast` so a negative value (a model-supplied `-1` or a manifest typo) can't wrap to ~4e9: `@intCast(@max(v, 1))` for positive-only params, `@intCast(@max(v, 0))` for "0 = unlimited" params. For capped params, wrap the clamp in `@min(..., cap)`. See `searchFiles`/`findFiles`/`runBash` (`plugin_api.zig`) and `parsePermissions` (`manifest.zig`).
- **`sanitizePath` realpath re-check mirrors `validateCwd`.** `sanitizePath` (`plugin_api.zig`) does a lexical `startsWith(cwd)` check, then a best-effort `std.c.realpath` re-check so a symlink escaping the project root is caught. `realpath` returns null on ENOENT (a new file being written), so fall back to the lexical verdict on null — never reject a legitimately-new path. This mirrors the bash tool's `validateCwd` (AGENTS.md §Safety).

## Verifying

Run:

- `zig fmt`
- `zig build test`
- `zig build test-plugin` — runs the example Lua plugins' `test.lua` suites (via `src/lua/test_runner.zig` + `src/lua/test_runner.lua`). Its exit code is the gate: it must be 0 (green). `test_runner.run()` is idempotent — it caches the first verdict (`_has_run`/`_last_result`) so the explicit `test.run()` call and the Zig auto-run both return the same pass/fail. `test_runner.zig` logs at `warn` (not `err`) so the intentional syntax-error test doesn't fail the build. Add a new plugin's `test.lua` to the `test-plugin` arg list in `build.zig`. The Zig runner auto-runs `return test_runner.run()` after loading each file and **fails on 0 tests** — a test file with no `it` blocks is a failure, so a file that forgets `describe` entirely is caught.

### Test runner quirks (read before debugging a failure)

The authoritative signal for a test run is `zig build test`'s **exit code**, not its printed output:

- **`--listen=-` false failures.** `zig build test` drives the build-server protocol and intermittently prints `failed command: /usr/lib/zig/... zig test ...` with a red Build Summary even when every test passes (pre-existing environmental flakiness, reproducible on a clean baseline). If `EXIT=0` the run passed — ignore that line. Filter it out: `zig build test 2>&1 | grep -v '^failed command'`.
- **Test output is on stderr.** Both the `zig build test` step and the standalone `test` binary write their results to STDERR, so `2>/dev/null` hides everything and `2>&1 >/dev/null` reveals it. The standalone binary is authoritative when you need a real count: `ls -t .zig-cache/o/*/test | head -1 | xargs -I{} sh -c '{} 2>&1 >/dev/null | tail -3'` (expect `All N tests passed.`).
- **Stale cache with `-Dtest-filter`.** The `addTest` cache key does not distinguish `-Dtest-filter` filters, and `ls -t .zig-cache/o/*/test` can surface an older binary. After changing filters or code, trust `zig build test`'s exit code or the freshly built standalone binary — never a cached artifact's count.
- **Silent test discovery.** The test root is `src/root.zig`, which ends with `std.testing.refAllDecls(@This())` — only `test` blocks in files reachable through its `pub const` imports are compiled. A new file that nothing imports compiles fine but its tests **silently never run** (the count doesn't move, no error). Wire the file into the module graph — add a `pub const` in `root.zig`, or import it from a module already in the graph (e.g. the executor importing `tools/schema.zig` pulls its tests in) — to make its tests appear.
- **A lazy `pub const tests = @import("tui/tests.zig")` on `tui.zig` is NOT enough.** `refAllDecls` only takes the address of the *referencing* module's own decls; nothing takes the address of `tui.tests`, so `tests.zig` is never analyzed and its test blocks silently vanish (reproduced: the standalone binary dropped 690 → 601 after the §3.1 move with zero errors). The TUI tests are wired with `_ = @import("tui/tests.zig")` **inside `root.zig`'s `test` block** — reference the moved file's address directly, don't re-export it lazily. Verify any moved test file by strings-scanning the fresh binary for its test names, not by the suite exit code (which stays 0 on a silent drop).
- **Test-fixture lifetime pitfalls** (crash modes surfaced by running the tests, both caught by `std.testing.allocator`):
  - A helper that dupes its inputs leaks the temp: `appendViolation` dupes `got`/`expected`, so a caller passing `valueShortRepr(...)` / `toOwnedSlice(...)` results must `defer gpa.free` those temps, or DebugAllocator reports a leak at teardown.
  - A `&.{…}` compound literal with runtime elements lives on the **current frame's stack**. If later teardown (e.g. `McpManager.deinit` → `McpTool.deinit`) dereferences the schema after the helper returned, the free hits garbage → "General protection exception" at `gpa.free`. Test fixtures that outlive the helper must `gpa.alloc` the backing array; empty `&.{}` literals are fine because they live in read-only memory.
  - **`FailingAllocator` with an explicit `fail_index` beats `checkAllAllocationFailures` for OOM tests.** `checkAllAllocationFailures` requires the test fn to take the allocator as its first arg and fails when the *input construction* also allocates with the failing allocator. When building inputs with the real allocator and failing only inside the code-under-test, use `FailingAllocator` and set `fail_index` directly, then assert the expected error path and that no partial copies leak.

## Gotchas

- **`std.atomic.Mutex` is a spinlock.** In Zig 0.16, `std.atomic.Mutex` busy-waits and pegs the CPU on multi-core (80% at idle). Always use `std.Io.Mutex` / `std.Io.Condition` (paired via `static_thread_pool` or similar). All existing sites have been migrated — do not reintroduce `std.atomic.Mutex`.

- **`std.Io.Mutex` is not recursive — a function-scoped `defer unlock` plus a later re-lock deadlocks.** `BackgroundManager.start` hit this; fixed by unlocking immediately after `next_id += 1` (background.zig:135) — it guards only the id/job list. Lock only around the minimal critical section; never pair a function-scoped deferred unlock with a second `lock`. Related: `MultiReader.fill(timeout)` is an **idle** timeout, never a total cap; `bash_exec` converts once to an absolute deadline (`Io.Timeout.toDeadline`).

- **`postAgentEvent` owns the event.** It frees the event's data internally on error. Callers must NOT free `message_text` or `event_ptr` in catch blocks or before `return error.TurnCancelled` — doing so causes a double-free (errdefer repeats the cleanup).

- **Zig 0.16 std API gaps.** Several APIs from earlier Zig versions do not exist in 0.16.0 — use the C shims or `std.Io` equivalents instead: no `std.fs.realpathAlloc` → `std.c.realpath` (returns null on ENOENT); no `std.posix.symlink` → `std.c.symlink`; no `std.fs.makeDirAbsolute` → `std.Io.Dir.cwd().createDirPath`; no `std.time.nanoTimestamp` → `std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts)` (the instruction hook has no `Io` handle, so it reads the OS clock directly; fall back to 0 = no timeout on failure).

## Known Issues

- **Session resume segfault (null `model_id`).** Crash at `src/ai/openai_compatible.zig:59` (`gpa.dupe(u8, config.model)`) when `summary.model_id` is null and flows into `ModelSelection.custom.model.id` (non-optional `[]u8`). Resume chain: `root.run` → `initResume` → `initSession` → `applyFromConfig` → `tryAttachOpenAiCompatibleFromConfig` → `attachOpenAiCompatibleClient` → `Client.init`. Guarded at two entry points: `runtime.applyFromConfig` skips attachment when `model_id.len == 0`, and `tui.applySelectedModel` returns `error.EmptyModelId` before constructing the selection. Always use a real early return for these guards, never `std.debug.assert` — `unreachable` is UB in ReleaseFast (the install target) and would not protect that build. Previous fix: `da7c761` ("guard empty model_id on resume").

- **Debug prints masking segfaults.** Adding `std.debug.print` can change failure mode from segfault to a downstream error (e.g., `session.resume.failed err=Sqlite`), suggesting heap corruption or memory layout sensitivity. When this happens, suspect use-after-free or double-free in the path between the original crash site and the new error.

- **ReleaseFast debugging.** Use `std.debug.print` instead of `std.log.debug` — ReleaseFast strips log levels, so `std.log.debug` calls are no-ops.

- **Session config copy semantics.** `session_config` is a value-copy of `config`; union fields are shallow-copied. Mutating a union field on the copy does not affect the original.

- **vxfw FocusHandler crash on empty `path_to_focused` (LOCAL VENDOR PATCH REQUIRED).** Resume/session-switch crashes with SIGSEGV (ReleaseFast) or assert panic (Debug) at `vxfw/App.zig:590` (`FocusHandler.handleEvent`, `for (path) |widget|`). Root cause: `installRuntime` (transcript_lifecycle.zig) deinits the old runtime, but vxfw's `focused_widget` still points at a TextField whose userdata lived in that destroyed runtime. The next frame's `update()` can't find it in the surface tree, leaves the focus path empty, and the next key event dereferences it. Confirmed via core dump: fresh session + turn + keys does NOT crash; only resume + turn + keys does — the runtime swap is the trigger. The bug exists upstream (verified: upstream HEAD `cca454be` has identical `update()`/`handleEvent()`), so a vaxis bump does NOT fix it. **Two guards are applied manually** to `zig-pkg/vaxis-<hash>/src/vxfw/App.zig` (search for `NOVA-LOCAL-PATCH`): (1) `update()` falls back to `self.root` when `childHasFocus` leaves the path empty; (2) `handleEvent()` returns early instead of `assert(path.len > 0)` (stripped in ReleaseFast). **Re-apply after every `zig build --fetch` / vaxis bump** — the vendor dir is `.gitignore`d, so a fresh fetch overwrites the patch. Nova also defensively resets `fw_app.wants_focus = root` in `installRuntime` before `old.deinit()`, but that alone is insufficient because `wants_focus` is processed only at frame end (App.zig:160) while the crash happens during event drain (App.zig:134). Remove both guards once the upstream PR lands and the pinned commit is bumped past it.

  To re-apply the patch on a freshly-fetched vendor:
  1. In `FocusHandler.update`, replace the single `if (!self.root.eql(surface.widget)) { ... }` block with a guard that first checks `if (self.path_to_focused.items.len == 0)` and appends `self.root`, else falls through to the original `else if`.
  2. In `FocusHandler.handleEvent`, replace `assert(path.len > 0);` with `if (path.len == 0) return;`.
  Verify with: build ReleaseFast, then run `python3` the PTY repro (open `/resume`, select a session, type a prompt, press keys) — must NOT signal 11.

- **`run_in_background` deadlock on first use (fixed 2026-08-03).** `BackgroundManager.start` re-locked its non-recursive `Io.Mutex` after a function-scoped `defer unlock` — every launch hung in `futexWait`. Fixed by unlocking right after `next_id += 1`; details in §Gotchas `std.Io.Mutex`.

- **Bash `timeout_seconds` was an idle timeout, not a total runtime cap (fixed 2026-08-03).** `bash_exec` passed `options.timeout` to every `fill()`, so the deadline reset on every byte (a command printing every 100 ms ran 6061 ms under `timeout=2s`). Fixed via `Io.Timeout.toDeadline` + a 3600s clamp (`timeout_seconds_max`); details in §Gotchas.
