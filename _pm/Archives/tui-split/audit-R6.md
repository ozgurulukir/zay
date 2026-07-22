# tui-split — R6.0 Boundary Audit

Prerequisite design step for R6. Maps every private `App`/`RootWidget` method
that R6.1/R6.2/R6.3 candidates call, then decides for each one whether to:

- **pub** — promote to `pub fn` (cheapest; default when the method has only
  a few callers in `tui.zig` itself),
- **move** — relocate into the new module or a sub-struct (when the method is
  cohesive with one),
- **keep** — leave private; the caller that needs it stays in `tui.zig`.

The goal is to make the diff for R6.1–R6.3 *mostly method moves*, not keyword
churn. Each decision below is paired with a one-sentence rationale.

## R6.1 — InputWidget family

Target: `tui/widgets/input.zig` with `InputWidget`, `CommandInputText`,
`WrappedInputDraw`, and the 8 draw helpers. Caller: `drawRoot` (via
`var input_view: InputWidget = .{ .app = self.app }`).

### Private helpers InputWidget uses

| Method / symbol | Site | Decision | Rationale |
| --- | --- | --- | --- |
| `inputHintText(app)` | tui.zig:4766 | **move** | Pure function of `app.mode`; moves with `InputWidget`. |
| `writeDiffCounts(...)` | tui.zig:4458 | **move** | Pure surface writer; only `drawDiffCounts` calls it. |
| `writeBorderLabelRight(...)` | tui.zig (pub since R5.1b) | already pub | No change. |
| `writeBorderTextEndingAt(...)` | tui.zig:4506 | **pub** | Used by `drawInputBorder` and one other border site in tui.zig. Cheaper to pub than move. |
| `tui_status.modelStatus` / `formatModelStatus` | lib/tui_status.zig | no change | Already external. |
| `App.inputTextRows(self, ctx, width)` | tui.zig:3221 | **pub** | Pure-ish helper (reads `app.inputs.input`); same R1 pattern (pub accessor). |
| `App.diffCountsVisible(self)` | tui.zig:3276 | **pub** | Same. |
| `App.runningBackgroundCount(self)` | tui.zig:843 | **pub** | Already used transitively elsewhere; pub. |

### Private helpers CommandInputText uses

`CommandInputText` (tui.zig:4786) is a separate widget nested inside the input
border. Its `drawMultiline` calls `drawInputWrapped` and `App.peekCommentInput`
(already pub via R5.1b diff work). Move `CommandInputText` and `drawInputWrapped`
together with InputWidget.

### Verdict for R6.1

- **pub**: `writeBorderTextEndingAt`, `App.inputTextRows`, `App.diffCountsVisible`, `App.runningBackgroundCount` (4 promotions)
- **move**: `inputHintText`, `writeDiffCounts`, `WrappedInputDraw`, `CommandInputText`, `InputWidget` + 8 draw methods
- **keep**: none

## R6.2 — `drawRoot`

Target: `tui/root_layout.zig` with `drawRoot` as a free function taking `*App`
and the outer `vxfw.Widget` handle (same pattern as R5.2b's `drawDiffViewer`).

### Private widgets / helpers drawRoot uses

| Symbol | Site | Decision | Rationale |
| --- | --- | --- | --- |
| `InputWidget` | tui.zig:5082 | **after R6.1** | Becomes `input.InputWidget`. R6.2 depends on R6.1. |
| `OverlayWidget` | tui.zig:4474 (approx) | **move** | Move alongside drawRoot — only drawRoot uses it. |
| `AtSearchWidget` | tui.zig:4453 | **keep + pub accessor** | At-search is itself a future extraction candidate; for R6.2 promote a `pub fn newAtSearchWidget(self: *App) AtSearchWidget` accessor (or pub the type). |
| `App.inputTextRows` | already pub from R6.1 | — | — |
| `rootLayout` | already external (R5.2c) | — | — |
| `tx_widget.TranscriptWidget` | already external (R5.1d) | — | — |
| `loading.LoadingWidget` | already external (R5.1c) | — | — |
| `permission.PermissionWidget` | already external (R5.1a) | — | — |
| `background_jobs.BackgroundJobsWidget` | already external (R5.1a) | — | — |
| `lane_column.drawLaneColumn` | already external (R5.2a) | — | — |
| `diff_viewer_overlay.drawDiffViewer` | already external (R5.2b) | — | — |

### Verdict for R6.2

- **after R6.1**: ordering constraint, no separate promotion
- **move**: `OverlayWidget`, `drawRoot`
- **pub + accessor**: `AtSearchWidget` (smallest change)

## R6.3 — Lifecycle methods

Target: `tui/lifecycle.zig` with 5 free functions taking `*App` / `*RootWidget`.

### Method-by-method dependencies

#### `App.deinit` (~57 lines)

Calls: `cancelLaneNaming`, `freeDelivery` (already pub), `cancelModelLoad`,
`resumeClear`, `resumeClearFolds` (already pub), `cancelDiffRefresh`,
`closeAtSearch` (already pub), `clearLanesState`.

| Method | Decision | Rationale |
| --- | --- | --- |
| `cancelLaneNaming(lane)` | **pub** | Called only by deinit + abandon flows; safe to pub. |
| `cancelModelLoad` | **pub** | Same. |
| `resumeClear` | **pub** | Same. |
| `cancelDiffRefresh` | **pub** | Same. |
| `clearLanesState` | **pub** | Same. |

5 promotions.

#### `RootWidget.handleTick` (~69 lines)

Calls: `drainAgentEvents`, `App.drainModelLoad`, `App.drainDiffRefresh`,
`App.drainLaneNaming`, `App.pollBackgroundJobs` (already pub via R4),
`App.deliverPendingBackground` (already pub via R4), `App.advanceLoadingFrame`,
`App.scheduleDiffRefresh` (already pub via R1), `App.advanceBlackholeFrame`,
`App.anyTurnActive`, `App.backgroundActive` (already pub via R4),
`App.namingActive`.

| Method | Decision | Rationale |
| --- | --- | --- |
| `RootWidget.drainAgentEvents` | **move** | Move with handleTick — only handleTick calls it. |
| `App.drainModelLoad` | **pub** | Same drain pattern as R4. |
| `App.drainDiffRefresh` | **pub** | Same. |
| `App.drainLaneNaming` | **pub** | Same. |
| `App.advanceLoadingFrame` | **pub** | Pure state mutator. |
| `App.advanceBlackholeFrame` | **pub** | Same. |
| `App.anyTurnActive` | **pub** | Read-only; useful externally. |
| `App.namingActive` | **pub** | Same. |

7 promotions + 1 move.

#### `App.submitMode` (~95 lines)

Calls **~25** private methods: `submitProviderSetup`, `connectCodex`,
`signOutCodex`, `openProviderForm`, `applySelectedModel`, `switchToSession`,
`selectedResumeSummary`, `navigateToEntry`, `saveActiveLane`, `peekPaletteInput`
(already pub), `clearPaletteInput`, `clearInput` (already pub via R1),
`resolveCommand` (free fn), `openResumePicker`, `openTimelineSelector`,
`openProviderPicker`, `openModelPicker`, `openDiffViewer`, `createParallelLane`
(R6.3 candidate), `beginSave`, `closeActiveLane`, `createMergePicker`,
`openLanesPicker`, `reportLaneError`, `reportConnectionError`,
`reportSessionSwitchError`, `reportDiffError`, `confirmMergeDest`.

| Decision | Rationale |
| --- | --- |
| **don't move `submitMode`** | 25+ promotions to move one 95-line function is a bad trade — keyword churn outweighs the move. Keep `submitMode` in `tui.zig`. R6.3 drops this candidate. |

#### `App.createParallelLane` (~60 lines)

Calls: `repoRoot`, `liveRuntime` (pub already?), `captureLaneContext`,
`createRuntime`, `clearInput` (pub), `resetTurnState`.

| Method | Decision | Rationale |
| --- | --- | --- |
| `repoRoot` | **pub** | Read-only; useful externally. |
| `captureLaneContext` | **pub** | Used by create + naming. |
| `createRuntime` | **pub** | Used by create + initRuntime. |
| `resetTurnState` | **pub** | Same. |

4 promotions.

#### `RootWidget.handleDiffBrowseKey` (~95 lines)

Calls: `closeDiff`, `syncFocus` (pub via R1), `App.clearPaletteInput`,
`App.diff.*` (all pub on the diff struct), `App.peekCommentInput` (pub via
R5.1b), `App.clearPaletteInput` (private), `App.gpa` (field).

| Method | Decision | Rationale |
| --- | --- | --- |
| `RootWidget.closeDiff` | **move** | Move with handleDiffBrowseKey. |
| `App.clearPaletteInput` | **pub** | Same pattern as `clearInput`. |

1 promotion + 1 move.

## Summary of promotions (R6.0 → R6.1/R6.2/R6.3 prep)

| Phase | Promotions | Moves |
| --- | --- | --- |
| **R6.1 prep** | `writeBorderTextEndingAt`, `App.inputTextRows`, `App.diffCountsVisible`, `App.runningBackgroundCount` (4) | `inputHintText`, `writeDiffCounts`, `WrappedInputDraw`, `CommandInputText`, `InputWidget` + 8 draw helpers |
| **R6.2 prep** | `AtSearchWidget` (pub or accessor) (1) | `OverlayWidget`, `drawRoot` |
| **R6.3 prep (deinit)** | `cancelLaneNaming`, `cancelModelLoad`, `resumeClear`, `cancelDiffRefresh`, `clearLanesState` (5) | `deinit` |
| **R6.3 prep (handleTick)** | `drainModelLoad`, `drainDiffRefresh`, `drainLaneNaming`, `advanceLoadingFrame`, `advanceBlackholeFrame`, `anyTurnActive`, `namingActive` (7) | `handleTick`, `drainAgentEvents` |
| **R6.3 prep (createParallelLane)** | `repoRoot`, `captureLaneContext`, `createRuntime`, `resetTurnState` (4) | `createParallelLane` |
| **R6.3 prep (handleDiffBrowseKey)** | `clearPaletteInput` (1) | `handleDiffBrowseKey`, `closeDiff` |
| **submitMode** | — | **don't move** (~25 promotions not worth it) |

**Total: 22 promotions, ~10 moves.** Each promotion is a single-keyword edit;
moves are the bulk-extraction work the original R5.2d/R5.3 plan was after.

## Recommended commit order

1. **R6.1 prep** — promote 4 helpers (single commit, ~10-line diff).
2. **R6.1** — move InputWidget family to `widgets/input.zig` (single commit).
3. **R6.2 prep** — pub `AtSearchWidget` (single commit, 1-2 lines).
4. **R6.2** — move OverlayWidget + drawRoot to `root_layout.zig` (single commit).
5. **R6.3 prep (deinit)** — promote 5 helpers (single commit).
6. **R6.3a** — move deinit (single commit).
7. **R6.3 prep (handleTick)** — promote 7 helpers (single commit).
8. **R6.3b** — move handleTick + drainAgentEvents (single commit).
9. **R6.3 prep (createParallelLane)** — promote 4 helpers (single commit).
10. **R6.3c** — move createParallelLane (single commit).
11. **R6.3 prep (handleDiffBrowseKey)** — promote 1 helper (single commit).
12. **R6.3d** — move handleDiffBrowseKey + closeDiff (single commit).

12 atomic commits. Each promotion batch is its own commit so reviewers see the
prep work separately from the move. `submitMode` stays in `tui.zig` — it is
the natural mode-dispatch companion to `handleCommandKey` (R2) and would
become a free function only after the App/private-method boundary is relaxed
in a future refactor (post-R6).
