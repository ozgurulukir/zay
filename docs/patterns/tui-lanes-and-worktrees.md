### Concurrency and event ownership

- **`std.atomic.Mutex` is a spinlock.** In Zig 0.16, `std.atomic.Mutex` busy-waits and pegs the CPU on multi-core (80% at idle). Always use `std.Io.Mutex` / `std.Io.Condition` (paired via `static_thread_pool` or similar). All existing sites have been migrated — do not reintroduce `std.atomic.Mutex`.

- **`std.Io.Mutex` is not recursive — a function-scoped `defer unlock` plus a later re-lock deadlocks.** `BackgroundManager.start` hit this; fixed by unlocking immediately after `next_id += 1` (background.zig, `start`'s id-allocation critical section) — it guards only the id/job list. Lock only around the minimal critical section; never pair a function-scoped deferred unlock with a second `lock`. Related: `MultiReader.fill(timeout)` is an **idle** timeout, never a total cap; `bash_exec` converts once to an absolute deadline (`Io.Timeout.toDeadline`).

- **`postAgentEvent` owns the event.** It frees the event's data internally on error. Callers must NOT free `message_text` or `event_ptr` in catch blocks or before `return error.TurnCancelled` — doing so causes a double-free.

### TUI upstream fixes and input diagnostics

The pinned libvaxis revision includes the upstream fixes for issues #366, #367, and #368: FocusHandler recovery, Windows input-loop robustness, and bracketed paste handling. The former local patch manifest, build checks, and apply scripts were removed. Fetch the pinned dependency normally; no manual patch step is required. See [Building](../BUILDING.md).

For input failures, `routeKey` logs every key reaching the router and `handleTick` logs a roughly 1.5-second heartbeat. Keys present indicate a live reader/router; inspect the active mode. Missing keys point to the reader or event queue; missing heartbeats point to a wedged UI handler. Bare ESC matching is codepoint-based because Windows Terminal may deliver `cp=0x1b mods={alt=true}`. `routeKey` normalizes bare C0 codepoints (0x01–0x1a except backspace, tab, newline and enter) to `ctrl+letter` with clean modifiers, including mangled Ctrl+C/Ctrl+D. Regression: `"bare C0 codepoints (mangled Ctrl+C/Ctrl+D) still drive quit"`. Standalone Windows modifier records previously starved timers/redraws; that upstream fix is included in the pin.

### TUI module split

`src/tui.zig` holds `App` lifecycle and `RootWidget`; `src/tui/` is split by concern. See `docs/ARCHITECTURE.md` for the subsystem overview.

### App state grouping pattern

`App` struct fields are grouped into focused sub-structs defined in `src/tui/app_state.zig`: `InputState` (text fields), `PickerStates` (per-picker state), `NavState` (cursors + quit state machine + session action + resume group-by), `ListWidgets` (scrollable list views), `ProviderState` (API keys + registry + connectivity), `InputBuffers` (inline edit buffers), `AtSearchState` (`@`-mention search), `BackgroundModalState` (Ctrl+O modal), `MetricsState` (spinner + diff cache). Each sub-struct owns one concern; accessors on `*App` expose inner fields. When adding new App state, prefer extending an existing sub-struct or adding a new one rather than growing the flat struct.

### Domain extraction pattern

Isolated domain clusters (lane lifecycle, diff lifecycle, session switching, at-search, transcript navigation, permission, event callbacks, queue, settings lifecycle, clipboard helper, search lifecycle) live under `src/tui/` as free-function modules. Each module imports `const tui = @import("../tui.zig")` and defines `pub fn` taking `*App` as the first parameter. The original App method stays as a 1-line delegate (Strangler Fig) so tests in `src/tui/tests.zig` resolve via the struct. When a private App method is needed, promote it to `pub` — not `pub const` (that is for module-level re-exports of nested types). The TUI test blocks live in `src/tui/tests.zig`, wired into the test run by `_ = @import("tui/tests.zig")` in `root.zig`'s `test` block — a lazy `pub const tests` on `tui.zig` does NOT compile them (the file is never analyzed), so the reference must take the file's address.

The same extraction shape applies below the TUI: pure shared leaves get their own root/`src/ai` module with the old site re-exporting as a facade — `src/paths.zig` (path comparison, re-exported by `tui/lanes.zig`), `src/ai/model_compat.zig` (model/dialect quirks, re-exported by `openai_compatible.zig`), and `src/ai/openai_request.zig` (chat-completions payload serialization) alongside the existing `responses_request.zig`/`responses_events.zig`. Every new module needs an `_ = @import(...)` in `root.zig`'s `test` block — that is the load-bearing half that makes its inline tests run (a lazily-referenced file is never analyzed); a `pub const` in the decl list additionally exposes it through the module registry (`paths.zig` has both; the `ai/*` siblings are exposed via `ai.zig`'s re-exports instead).

### Widget extraction pattern

Isolated widgets live under `src/tui/widgets/`. A new widget file declares the outer border widget as:

```zig
pub const NameWidget = struct { app: *App, pub fn widget(...) vxfw.Widget { ... } }
```

with a private `Inner` struct built inside `draw()` from a `vxfw.DrawContext`. The file imports `const tui = @import("../../tui.zig");`, `const tui_style = @import("../style.zig");`, `const panel = @import("panel.zig");` and re-aliases `const App = tui.App;`. Nested types from other modules are re-exported through `pub const` in `tui.zig` so widget files reach them as `tui.<module>.<Type>`.

INV-WIDGET-1 scalarization contract (established by `transcript.zig`/`loading.zig`): a leaf widget that only draws values takes scalar fields instead of `app: *App` — the per-frame construction site (`root_layout.drawRoot`, `lane_column.drawLaneColumn`) computes them from `app` right before building the widget literal, so there is no staleness window. State the widget cannot own flows through pointers: `TranscriptWidget.blackhole_visible: *bool` writes back into `App.metrics` so the intro-animation tick can stop. `MessageListBuilder` (same file) is the isolated-view-model form for list building.

### Timeline overlay flatten pattern (`/timeline`)

`src/tui/widgets/tree_selector.zig` owns the full session tree (`TreeState.nodes`, rebuilt on `load`) and derives the visible layout on each `reflatten` from the filter mode, fold set, and search. Invariants worth preserving: legacy `checkpoint`-kind entries never render as rows (their descendants attach to the nearest visible ancestor); the conversation leaf is always visible (`is_leaf or kindPasses`, so the current row survives any filter); a snapshot-bearing entry hidden by filter/search migrates its ✦ to the nearest visible ancestor, with the deepest snapshot in a collapsed segment winning (`last-write` into `snap_id`); `reflattenKeepingSelection` restores selection by id and clamps to the last row when the selection is filtered out. `load` resolves the leaf to the nearest real message (checkpoint or `request_usage` metadata may be the leaf) so a row — not nothing — is selected on open.

### Per-mode command routing

`src/tui/command_router.zig` holds one struct per `App.Mode` variant, each owning a `handle` method migrated from `App`. The dispatcher is a free function delegating to the right struct. Add new per-mode logic here — don't reintroduce private methods on `App` for key handling.

### Viewport scrolling pattern

Standardize overlay list viewports using `panel.ViewportWindow.compute(selection, total_count, surface.size.height)` in `src/tui/widgets/panel.zig`. Use `viewport.screenRow(i)` for row rendering calculations.

### Provider polymorphism pattern

Unify static builtin `config_mod.Provider`, dynamic `modelsdev.Provider`, and user-defined `config_mod.ProviderConfig` handles using `ProviderHandle = union(enum) { builtin, dynamic, config }` in `src/tui/widgets/provider_picker.zig`. All three share the same accessor surface (`id()`, `displayName()`, `description()`, `defaultBaseUrl()`, `requiresApiKey()`, `catalogueIndex()`). Since the 2026-09-04 builtin-provider unification, `modelsdev.Provider` is a direct alias of `config_provider.ProviderDef` and the registry carries no local builtin table — the single compile-time catalogue is `builtin_providers` (18 entries) in `src/config/provider.zig`, and `loadBuiltins()` returns it zero-copy; keep new provider metadata in that table only. The `/connect` picker builds a single merged list via `buildMergedProviderList` in `src/tui/provider_model.zig`: builtin catalogue → models.dev registry (overrides builtins with same id) → config providers (overrides everything with same name, **except** entries already covered by the models.dev registry — a `reg.lookup(cp.name)` guard prevents the persisted `ProviderConfig` entry from shadowing the `.dynamic` handle and converting the provider to a "custom" entry in the picker).

### Lane workspace boundary

Model lane operations derive their activity snapshot from `Thread` on the UI
thread. `running` means an active turn, `cancelling` includes asynchronous
cancel teardown, and `finishing` means the terminal turn event arrived but the
spawned worker still owns its runtime or future. `idle` is reported only after
that ownership has ended. Runtime attachment and completion delivery are
separate fields: an idle user lane can retain its runtime, and a parked worker
can have a pending, consumed, or delivered completion. `list`, `read`, `resume`,
`steer`, and `await` use the same derived snapshot. `await` does not acknowledge
a finishing worker; repeated completed awaits return the retained result.

The model-facing `lane` tool is orchestration-only: the primary driver
supervises workers with `spawn`, `read`, `await`, `steer`, `cancel`, `merge`,
and `delete`. Internal workspace state (`Agent.workspace` and executor
`effectiveCwd` re-rooting) remains for lifecycle compatibility and tests, but
is not reachable through the model parser. This prevents driver tool calls from
running in a worker worktree while preserving the existing cleanup path.

`/parallel` creates a live user-selected lane. `drawLaneColumn`
(`src/tui/lane_column.zig`) renders activity from that lane's own turn state,
so prompts submitted in `grid` or `tab` run in the selected lane's worktree.
`dual` keeps the primary as the input target. After the lane is idle and clean,
the user can open `/merge` directly from the selected lane, or the primary
driver can merge/delete it by lane id. See issue #23 for the original activity
visibility analysis.

- **Internal lane re-rooting takes effect from the next tool call, not the next batch.** The following `enter`/`leave` behavior describes lifecycle compatibility and tests; these operations are not exposed by the current model parser. `ExecutorService.cwd` starts as a per-batch snapshot from `agent.effectiveCwd()` (`runToolBatch`, agent.zig), but `runAll` calls `rerootFromRequester()` after every `lane` call (executor.zig) — so a `lane enter`/`leave` mid-batch re-roots the *remaining* calls in the same batch, matching what the `enter` response already claims. `rerootFromRequester` re-reads `effectiveCwd()` off the `lane_requester` (`*Agent`); it is a no-op when no requester is attached (headless/tests) or the workspace didn't change. Contained workers never change workspace (`enter` is driver-only), so the refresh is inert there. The `executor → agent` import is safe — the cycle already exists via `executor → tools → lane → agent`.

- **`Agent.workspace` is cross-thread, mutex-guarded (fixed 2026-08-05).** Compatibility paths write it through `setWorkspace` (defined in `src/agent.zig` with call sites in `tools/lane.zig`); the UI thread reads it (`driverWorkspace`, `listLanes`, `clearWorkspaceBorrowForPath`, `lane_column`). A 16-byte slice store can tear, so the field is guarded by `workspace_mutex` and accessed only through `setWorkspace`/`workspaceBorrow`/`effectiveCwd` — never directly. The lock is never held across tool dispatch. The precondition (no by-value copies of a live `Agent` after init) was verified before adding the mutex; `AgentRuntime.agent` is the single owner, and `Agent` already held a `message_queue_mutex`.

### Windows portability pattern

The app compiles on Windows (Zig 0.16) without breaking Linux. `lib/platform.zig` centralizes the OS-adaptive helpers so the rest of the codebase stays clean of `builtin.os.tag` switches:

- Use `platform.getEnvMap` instead of raw `std.c.environ` reads.
- Use `platform.writeToFd` instead of `std.c.write`.
- Use `platform.realtimeNowNs` / `platform.monotonicNowNs` instead of `std.c.clock_gettime`.

Guard POSIX-only syscalls behind `if (!os.is_windows)` at their call sites: `std.posix.kill`, `std.posix.poll`, `setsockopt`, `std.c.realpath`.

**`zeroedChild()` helper (`src/mcp/client.zig`):** `std.mem.zeroes(std.process.Child)` is a compile error on Windows because `Child.thread_handle` is a non-nullable `HANDLE`. Use the `zeroedChild()` helper to construct a zeroed `Child` portably instead of calling `std.mem.zeroes` directly.

**Foreground teardown kills the whole process tree (Windows):** an ESC interrupt during command execution must terminate the entire foreground tree, not just the pwsh process — surviving grandchildren hold the stdout/stderr pipe handles open and keep `drainChild`'s `MultiReader` blocked past its idle timeout (perceived as a ~30s freeze on every ESC). Every foreground capture child is attached at spawn to a Win32 Job Object with `KILL_ON_JOB_CLOSE`; interrupt teardown calls `TerminateJobObject` — one kernel call closes every handle and EOF arrives immediately (POSIX already signals the process group with SIGTERM→SIGKILL escalation). The Job handle is closed after the child is reaped (529098c). Never reintroduce a bare `child.kill` on the Windows interrupt path.

Note: Windows is now **daily-driver ready** (lanes/worktrees/background jobs run natively, the shell tool is `pwsh`, and MCP stdio/HTTP/SSE operations have bounded deadlines) — this section covers compilation + the remaining runtime hardening: #32 (deferred Windows test variants). The #80 Windows test-harness hang is resolved; see [Building — Test runner quirks](../BUILDING.md#test-runner-quirks-read-before-debugging-a-failure) for the direct-runner behavior and verification result.

- **POSIX Environment Access:** Never index `std.c.environ` directly in loops. In Zig 0.16 on POSIX, `std.c.environ` is `[*:null]?[*:0]u8`. Use `const env_slice = std.mem.span(std.c.environ);` and pass to `std.process.Environ.createMap(.{ .block = .{ .slice = env_slice } }, gpa)` to prevent null-pointer segfaults in multi-threaded contexts.

### Git command ownership

- **`vcs.runOut` must not errdefer over a struct it deinits explicitly (2026-09-14).** The non-zero-exit path used BOTH `out.deinit(gpa)` and an `errdefer out.deinit(gpa)` — the error return re-fired the errdefer on the already-`undefined` struct, double-freeing garbage pointers: **any git subcommand exiting non-zero segfaulted at BOOT** (repro: `rev-parse HEAD` in a commitless `git init` — every scratch-dir launch crashed). Rule: when a failure path deinits by hand before `return error`, there must be no errdefer over the same value. Regression test: `"runOut on a failing git command errors without crashing"`.

### Worktree Hardening & Lifecycle Architecture

Worktrees isolate parallel worker agents and user lanes from the primary repository tree. Five architectural pillars ensure robust, cross-platform stability:

1. **Path Normalization (`src/paths.zig::pathsEqual`):**
   Path equality checks for workspace borrows, worktree directories, and lane commands use `pathsEqual` from the root leaf `src/paths.zig` (re-exported as `lanes_util.pathsEqual` by `src/tui/lanes.zig` for in-TUI callers; the execution layer imports the leaf directly). This helper operates with zero dynamic allocations, collapses redundant and trailing slashes (`/` vs `\`), and applies ASCII case-folding on Windows (`C:\foo` == `c:/foo/`). Never compare file or worktree paths with byte-level `std.mem.eql`.

2. **Shell Containment Parity:**
   Worker agents are strictly root-contained. On POSIX, `bash.zig` validates directory navigation. On Windows, `src/tools/pwsh.zig` injects pre-command function overrides (`cd`, `Set-Location`, `chdir`, `sl`) that resolve target paths with `[System.IO.Path]::GetFullPath`, check boundaries with `$root.TrimEnd('\', '/')`, and reject directory-stack escapes (`Push-Location`, `Pop-Location`).

3. **Windows File Locking & Teardown Protocol:**
   Deleting worktrees on Windows is subject to asynchronous file lock retention by child processes or Windows Defender. All teardown paths (`abandonLane`, `mergeLane`, `deleteSelectedParked`, `rollbackLaneWorktree`, `deleteLaneOp`) call `lane_lifecycle.cleanupLaneWorktreeAndBranch`:
   - Drops the manifest row **FIRST** (`lane_recovery.syncLaneDeletedByPath`, best-effort) — see "Lane Crash Recovery" below for why this order is load-bearing.
   - Synchronously terminates all child background processes running in or below the worktree (`background.terminateJobsInCwd` via `terminateTreeSync`).
   - Executes `vcs.worktreeRemove`, which on **Windows only** retries up to 4 times with backoff (50ms, 150ms, 300ms); on POSIX it is a single attempt with no backoff (`max_attempts = if (os.is_windows) 4 else 1`).
   - Falls back to `vcs.worktreePrune` (`git worktree prune --expire now`) **only when `worktreeRemove` failed**, to purge administrative metadata in `.git/worktrees`.

4. **Startup Orphan Garbage Collection:**
   Global worktree checkouts reside at `<home>/.config/zay/worktrees/<id>` (resolved portably via `vcs.globalWorktreesDir`). During startup hygiene in `src/root.zig:run()`, `vcs.gcOrphanedWorktrees` scans this directory and removes abandoned checkouts older than 7 days (`vcs.worktree_retention_ns = 7d`). Since b621439 the hygiene runs OFF the critical path on a background thread (`runWorktreeHygiene`, spawned before `tui.run`, joined before the borrowed `home_dir`/`cwd` buffers are freed; inline fallback when the thread cannot spawn). When launched in a Git repository, `vcs.worktreePrune` synchronizes `.git/worktrees` metadata before any session or lane initializes. Since the lane crash-recovery feature, `gcOrphanedWorktrees`/`gcWorktreesDir` take a `keep` skip-list of worktree directory names (case-insensitive match): `root.run` claims crash-recovery targets BEFORE spawning the hygiene thread and passes the claimed names, so the 7-day TTL can never delete a worktree the launch is about to restore (see "Lane Crash Recovery" below).

5. **Asynchronous Non-Blocking Worktree Provisioning:**
   In large repositories, `git worktree add` can block the host process for 2–5 seconds. `spawnLane` offloads worktree creation to a background worker thread (`WorktreeJob`) and returns `null` on the first tick, keeping the request queued in `LaneBridge.pending`. The TUI event loop continues ticking at 30ms, while `advanceAnimations` and `decideShouldTick` query `lane_lifecycle.anyAsyncWorktreeActive` to drive loading spinners smoothly until provisioning completes.

- **Parallel lanes & worktree architecture.** Key files: `src/tools/lane.zig` (tool side, workspace borrow), `src/tools/lane_bridge.zig` (request/response bridge), `src/tui/lane_lifecycle.zig` (all lane ops + teardown; the worktree-job/teardown impl lives in `src/tui/lanes/worktree_job.zig`, re-exported here), `src/tui/lifecycle.zig` (`handleTick` order: `drainAgentEvents` → `serviceLaneBridge` → `drainLaneNaming` → `deliverPendingLaneCompletions`; `createParallelLane` user flow). Limits: max 4 threads (driver + 3 lanes); global worktrees at `<home>/.config/zay/worktrees/<id>` resolved via `vcs.globalWorktreesDir`, branch `zay/<id>`; `worker_stall_ms = 180s`. User-facing model: [[ARCHITECTURE]].

- **Lane bridge request lifetime:** `service` holds its mutex across the handler because `Request` lives on the worker stack. The handler must not outlive the lock: an unlocked two-phase handler could access a request after worker cancellation. Heavy worktree provisioning runs on `WorktreeJob` and is polled across ticks as described above.

### Lane Crash Recovery

A hard crash (segfault, abort, kill — anything that skips defers) used to lose the lane↔session linkage entirely: worktrees and lane conversations survived on disk, but nothing mapped one to the other, and startup auto-resume could even pick a lane's session as the driver's (`findLatest` orders by `updated_at_ms`, and a busy lane writes more often than the driver). Since 4a325d5 the linkage is durable, with a strict division of truth:

- **Git is the existence authority; sqlite only enriches.** `git worktree list` decides whether a worktree exists. The schema-v6 `lanes` table in the global `sessions.sqlite` (`worktree_path` PK, `repo_key`, nullable `session_id` FK `on delete set null`, `title`, `state` ∈ {`open`, `parked`}) only enriches it with the session link, title, and lifecycle state. **Every manifest write is best-effort (`void` + `log.warn`)** — a lost row degrades to today's parked-lane behavior, never fails a lane operation. The storage leaf lives in `src/session/lane_manifest.zig` (imports only `db`/`session`); all orchestration lives in `src/tui/lanes/recovery.zig`.
- **Path keys are normalized at the SQL boundary.** SQLite matches `worktree_path` byte-exactly, but the key's two producers disagree on separators: lanes store the native form (`std.fs.path.join`, backslashes on Windows) while `git worktree list --porcelain` prints forward slashes. `lane_manifest.pathKey` rewrites `\` → `/` on every bind so both producers address the same row; `repo_key` is deliberately NOT normalized because both of its producers use the same launch-cwd string. This was a real P1: without it, git-form lookups missed native-form rows, producing duplicate `open` rows for one worktree (two restored panes on one worktree) and resurrection of deliberately closed lanes.
- **`state='open'` means exactly "open when the crash hit."** Startup arms the per-repo crash marker (`crash-<fnv1a64(repo_key)>.marker` under the config dir, content = the repo key, verified on read against hash collisions) and a `defer` deletes it on ANY normal unwind — so only a hard crash leaves one behind. A clean exit runs `parkAllOpenBestEffort` after `tui.run` returns. `/close` flips its row to parked **before** lane teardown: the lane's strings are still alive there (a flip after `lane.deinit` was a real use-after-free), and a crash in the teardown window leaves row-parked + worktree-on-disk — the correct outcome for a lane being closed. Conversely `cleanupLaneWorktreeAndBranch` deletes the row FIRST, so a crash in the git teardown leaves "row gone + worktree exists" — a parked lane, correct for a lane being removed.
- **Claim before GC; git failure is not authority.** `root.run` claims the repo's open rows BEFORE spawning the hygiene thread and passes the claimed worktree names as `gcOrphanedWorktrees`' `keep` skip-list (a fixed `restore_lane_cap` buffer borrowing the claimed strings — freed only after the join defer, LIFO). Classification: a row whose worktree git no longer lists is reconciled away; rows beyond the 3-worker grid cap are parked, not deleted; **a `worktree list` FAILURE aborts the claim before any deletion** (git being unreachable is not evidence a worktree is gone), and claim-side OOM leaves rows open for the next launch to retry.
- **The driver pin fixes auto-resume.** `driver_pins(repo_key PK, session_id)` records the driver's current session at startup and on every `installRuntime` of the driver arm. `resolveStartupDriverPin` resolves the pin at startup — validating it through `manager.resume()` and falling through when it dangles — as the first step of `root.run`'s auto-resume order (driver pin → `findLatestByProject` when the launch root is already bound → legacy `findLatest`). The older `resolveStartupResumeId` (pin → `findLatest`) survives only as a legacy helper and has no callers. The FK `set null` clears pins whose session is deleted.
- **Restore is idle-only and honest.** `restoreIntoApp` (called from `tui.run` right after the intro logo) builds idle Threads with git-derived branch/path (never the row's — a `zay/<hex>` → `zay/<slug>` rename before the crash would restore stale), the manifest title, and `SessionId.fromSlice` of the linked session; caps at the grid's worker capacity; posts ONE transcript notice. Nothing auto-attaches runtimes. `/lanes` gained the `o` key: parked entries first, then open idle working lanes (`buildLaneEntries`, `laneEntryCount`, and `recovery.idleLaneAt` must walk the identical filter); `openSelectedLane` resumes the linked session via `createLaneRuntime` (a worktree of the current repo is NOT a cross-project resume — bypasses config reload, plugin repoint, and the `InFlightTurn` refusal) through `wakeIdleLane`'s optional `session_id` parameter, which always binds `Thread.id`. When the row read FAILED (vs absent), the post-wake upsert is skipped — overwriting a row we could not read could permanently unlink its conversation.

Accepted limitations: two concurrent zay instances in one repo break the marker protocol in both directions (single marker, no pid); a subdir launch sees no rows (byte-exact `repo_key` — the same launch-dir convention as `sessions.cwd`/`findLatest`); a detached-HEAD worktree still restores (row matching is path-only by design). Regression tests live in `lane_manifest.zig` and `recovery.zig` (referenced from `root.zig`'s test block).
