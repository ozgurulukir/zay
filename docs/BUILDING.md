# Building Zay from source

This guide is for compiling Zay locally. For normal use, prefer a release
binary or one of the installers in the root README.

## Requirements

- Zig 0.16.0
- Git 2.20 or newer
- Network access for the first dependency fetch

## Clone, fetch, build, and install

```bash
git clone https://github.com/ozgurulukir/zay.git
cd zay
zig build --fetch
zig build
zig build test
zig build install -Doptimize=ReleaseFast --prefix "$HOME/.local"
```

The pinned libvaxis revision includes the upstream fixes for the Windows input
loop, bracketed paste handling, and FocusHandler recovery. No local vaxis patch
application step is required.

On Windows PowerShell:

```powershell
git clone https://github.com/ozgurulukir/zay.git
Set-Location zay
zig build --fetch
zig build
zig build test
zig build install -Doptimize=ReleaseFast --prefix "$HOME/.local"
```

## Troubleshooting

If dependency fetching fails, resolve the network or Git error and rerun
`zig build --fetch`. The dependency is fetched into Zig's package cache; it
does not need to be modified in the Zay checkout.

## Verifying

Run after code changes:

- `zig fmt` on the changed Zig files
- `zig build test`
- `zig build test-plugin` — runs the example Lua plugins' `test.lua` suites. Its exit code is the gate: must be 0. `test_runner.run()` is idempotent; `test_runner.zig` logs at `warn` (not `err`) so the intentional syntax-error test doesn't fail the build. Add a new plugin's `test.lua` to the `test-plugin` arg list in `build.zig`. The Zig runner auto-runs `return test_runner.run()` after loading each file and **fails on 0 tests** — a test file with no `it` blocks is a failure.

### Test runner quirks (read before debugging a failure)

The authoritative signal for a test run is `zig build test`'s **exit code**, not its printed output:

- **Windows test-server hang (#80 resolved 2026-09-21).** Zig 0.16's Windows `--listen=-` test-server transport can wait forever after a test process exits. `build.zig::addTestRun` now runs test executables directly on Windows and checks their exit codes; non-Windows builds retain `b.addRunArtifact`. Verified on Windows with `zig build test`: exit code 0, 1,588 passed, 63 skipped, 0 failed (about 4.5 minutes). This fixes the prior ~8-minute hang; the example 3-minute target in #80 was not met and remains a possible performance improvement, not a correctness failure.
- **Build-server false failures on non-Windows.** On hosts that still use Zig's build-server test runner, `zig build test` may print a `failed command: ... zig test ...` line despite passing tests. The process exit code is authoritative; if `EXIT=0`, the run passed. Filter it out when needed: `zig build test 2>&1 | grep -v '^failed command'`.
- **Test output is on stderr.** Both the `zig build test` step and the standalone `test` binary write their results to STDERR, so `2>/dev/null` hides everything and `2>&1 >/dev/null` reveals it. The standalone binary is authoritative when you need a real count: `ls -t .zig-cache/o/*/test | head -1 | xargs -I{} sh -c '{} 2>&1 >/dev/null | tail -3'` (expect `All N tests passed.`).
- **Stale cache with `-Dtest-filter`.** The `addTest` cache key does not distinguish `-Dtest-filter` filters, and `ls -t .zig-cache/o/*/test` can surface an older binary. After changing filters or code, trust `zig build test`'s exit code or the freshly built standalone binary — never a cached artifact's count.
- **Silent test discovery.** The test root is `src/root.zig`, which ends with `std.testing.refAllDecls(@This())` — only `test` blocks in files reachable through its `pub const` imports are compiled. A new file that nothing imports compiles fine but its tests **silently never run**. Wire the file into the module graph — add a `pub const` in `root.zig`, or import it from a module already in the graph — to make its tests appear.
- **A lazy `pub const tests = @import("tui/tests.zig")` on `tui.zig` is NOT enough.** `refAllDecls` only takes the address of the *referencing* module's own decls; nothing takes the address of `tui.tests`, so `tests.zig` is never analyzed and its test blocks silently vanish. The TUI tests are wired with `_ = @import("tui/tests.zig")` **inside `root.zig`'s `test` block** — reference the moved file's address directly, don't re-export it lazily. Verify any moved test file by strings-scanning the fresh binary for its test names, not by the suite exit code.
- **`ai.scripted_client.Client` is the socket-free `LanguageModel` test seam (2026-09-18, `src/ai/scripted_client.zig`).** It replays a bounded script of `Step`s (`.text`, `.tool_calls`, `.truncated_tool_calls` count, `.fail`) through the same three-method contract, selected via the `LanguageModel` tag `.{ .scripted = &client }`. It enables full begin→`runAgentTurn`→converge agent-level and TUI tests with no sockets — the portable complement to the #32 SkipZigTest-gated truncation suites, which keep owning SSE/wire-shape coverage. Steps are owned by the client until `deinit`; every returned `Turn` follows the normal `Turn.deinit`/`takeAssistantMessage` contract. Regression tests: `"run completes a scripted text turn and streams deltas through the observer"`, `"run retries once when the provider truncates tool-call arguments (scripted, socket-free)"` (agent.zig).
- **Test-fixture lifetime pitfalls:**
  - A helper that dupes its inputs leaks the temp: `appendViolation` dupes `got`/`expected`, so a caller passing `valueShortRepr(...)` / `toOwnedSlice(...)` results must `defer gpa.free` those temps, or DebugAllocator reports a leak at teardown.
  - A `&.{…}` compound literal with runtime elements lives on the **current frame's stack**. If later teardown dereferences the schema after the helper returned, the free hits garbage. Test fixtures that outlive the helper must `gpa.alloc` the backing array; empty `&.{}` literals are fine because they live in read-only memory.
  - **`FailingAllocator` with an explicit `fail_index` beats `checkAllAllocationFailures` for OOM tests.** `checkAllAllocationFailures` requires the test fn to take the allocator as its first arg and fails when the *input construction* also allocates with the failing allocator. When building inputs with the real allocator and failing only inside the code-under-test, use `FailingAllocator` and set `fail_index` directly, then assert the expected error path and that no partial copies leak.
  - **`test_helpers.LockedAllocator` for tests that run a real worker thread** (`src/tui/test_helpers.zig`). The raw testing allocator is not thread-safe, and scripted-turn tests run `runAgentTurn` on a worker thread while the UI thread allocates; the facade wraps a child allocator in `std.Io.Mutex` via `lockUncancelable` (never `std.atomic.Mutex` — spinlock; see [Concurrency and event ownership](PATTERNS.md#concurrency-and-event-ownership); there is no `ThreadSafeAllocator` in Zig 0.16). Both sides — UI thread AND the spawned worker — must share the ONE facade; two facades serialize on separate mutexes and still race.

- **Windows socket-test gates (#32).** Real-socket tests that rely on *abrupt truncation* (server closes mid-response / close-without-response / connection poke with no bytes) hang on Windows: the close does not surface as a client read error and the test client (no socket timeout in test configs) blocks forever. The retry / 429 / gzip-error-body socket suites DO run on Windows — only the truncation class is gated with `if (os.is_windows) return error.SkipZigTest;` (openai_compatible "stream-phase ReadFailed", responses_core head/stream-phase ReadFailed, agent "length-cut stream", codex watchdog poke). Gate new truncation-style socket tests the same way; keep raw-request/response suites unguarded.

## Installed artifact verification

- **Stale `zig build install` artifact can silently ship old code.** `zig build install` copies the cached executable to the prefix; a stale `.zig-cache` artifact is copied verbatim, so the installed binary may keep running pre-fix code even after the source is changed — `zig build install` exits 0 and the file timestamp does not move. If a fix appears to have no effect on the installed binary, verify the binary actually contains it (`nm ~/.local/bin/zay | grep <symbol>`) and its mtime advanced; when in doubt, `rm -rf .zig-cache && rm -f <prefix>/bin/zay` then rebuild and install.

`vendor/fzy/` is the vendored MIT fuzzy matcher and is compiled directly into the binary by `build.zig`; no separate build step is required.
