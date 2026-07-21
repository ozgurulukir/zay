# tui-split — Todo

Items committed to, not yet started.

## R6 — finish shrinking `tui.zig`

R1–R5 shipped 26 atomic commits bringing `tui.zig` from 8586 → 7504 lines
(-1082, -12.6%). R6 picks up the three extractions R5 deferred because they
were blocked on the App/private-method boundary. R6's first job is to
rethink that boundary, then extract.

### R6.0 — App/private-method boundary audit (prerequisite)

✅ **Done** — see `audit-R6.md` for the full table.

Result: 22 promotions, ~10 moves across 12 atomic commits. `submitMode`
stays in `tui.zig` (~25 promotions not worth it; it is the natural
mode-dispatch companion to `handleCommandKey` from R2).

### R6.1 — InputWidget family → `tui/widgets/input.zig`

- [ ] **R6.1 prep**: promote `writeBorderTextEndingAt`,
  `App.inputTextRows`, `App.diffCountsVisible`, `App.runningBackgroundCount`.
- [ ] **R6.1**: move `InputWidget`, `CommandInputText`, `WrappedInputDraw`,
  `inputHintText`, `writeDiffCounts`, and the 8 draw helpers
  (`drawInput`, `drawInputText`, `drawInputWrapped`, `drawInputBorder`,
  `drawQueuedMessage`, `drawInputHint`, `drawLanesBadge`, `drawBackgroundBadge`,
  `drawDiffCounts`).

### R6.2 — `drawRoot` → `tui/root_layout.zig`

- [ ] **R6.2 prep**: pub `AtSearchWidget` (or add a `newAtSearchWidget`
  accessor).
- [ ] **R6.2**: move `OverlayWidget` + `drawRoot` as a free function taking
  `*App` + the outer widget handle (R5.2b pattern).

### R6.3 — Lifecycle → `tui/lifecycle.zig`

- [ ] **R6.3 prep (deinit)**: promote `cancelLaneNaming`, `cancelModelLoad`,
  `resumeClear`, `cancelDiffRefresh`, `clearLanesState`.
- [ ] **R6.3a**: move `App.deinit`.
- [ ] **R6.3 prep (handleTick)**: promote `drainModelLoad`, `drainDiffRefresh`,
  `drainLaneNaming`, `advanceLoadingFrame`, `advanceBlackholeFrame`,
  `anyTurnActive`, `namingActive`.
- [ ] **R6.3b**: move `RootWidget.handleTick` + `drainAgentEvents`.
- [ ] **R6.3 prep (createParallelLane)**: promote `repoRoot`,
  `captureLaneContext`, `createRuntime`, `resetTurnState`.
- [ ] **R6.3c**: move `App.createParallelLane`.
- [ ] **R6.3 prep (handleDiffBrowseKey)**: promote `clearPaletteInput`.
- [ ] **R6.3d**: move `RootWidget.handleDiffBrowseKey` + `closeDiff`.

### Out of scope for R6

- **`App.submitMode`** — would need ~25 private-method promotions to move; bad
  trade. Stays in `tui.zig` as the natural mode-dispatch companion to
  `handleCommandKey` (R2).

### Done

- [x] R1 → R4 — see `done.md`
- [x] R5.1a–d (4 commits) — see `done.md`
- [x] R5.2a–c (3 commits) — see `done.md`
- [x] R6.0 boundary audit — see `audit-R6.md`
