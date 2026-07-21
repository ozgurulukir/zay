# tui-split — Backlog

## Refactor targets

R1–R5 landed 2026-07-21 (26 atomic commits, `tui.zig` 8586 → 7504). R6 queued.

- [x] **R1** `tui/event_router.zig` — extract `captureEvent` *(2026-07-21)*
- [x] **R2** `tui/command_router.zig` — extract `handleCommandKey` (struct-per-mode) *(2026-07-21)*
- [x] **R3** `tui/app_state.zig` — split `App` state into sub-structs *(2026-07-21)*
- [x] **R4** `tui/background_delivery.zig` — extract background plumbing *(2026-07-21)*
- [x] **R5** widgets + draw + layout
  - R5.1a–d isolated widgets → `src/tui/widgets/{background_jobs,permission,diff,loading,transcript}.zig`
  - R5.2a–c draw methods → `tui/{lane_column,diff_viewer_overlay,layout}.zig`
- [ ] **R6** finish shrinking `tui.zig` — R6.0 audit done (see `audit-R6.md`); see `todo.md` for R6.1/R6.2/R6.3 with the prep-move cadence
  - R6.1 `InputWidget` family → `tui/widgets/input.zig`
  - R6.2 `drawRoot` → `tui/root_layout.zig`
  - R6.3 Lifecycle methods → `tui/lifecycle.zig` (deinit, handleTick, createParallelLane, handleDiffBrowseKey; **`submitMode` stays**)

## Spotted but not in scope

- Cycle in `handleCommandKey` exhaustive graph — investigate after R2 (may resolve naturally; revisit during R6.0)
- `src/config.zig` 1206 lines — separate sub-project if recurring pain
- `src/session.zig` 1519 lines — same
- Test coverage for split modules — separate work item after refactor

