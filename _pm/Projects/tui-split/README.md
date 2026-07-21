# tui-split

Refactor `src/tui.zig` into focused modules. Started 2026-07-21 from 8586 lines; down to ~5943 (-2643, -30.8%) after R1–R7 (35 atomic commits). Target ≤ 2500 lines.

## Why

BFG analysis (2026-07-21) flagged `src/tui.zig` as the worst coupling hotspot in the codebase:

- 8586 lines (Rule 10 limit: 200 ideal, 300 split threshold; this was 28× over)
- `captureEvent` 87 lines, 0.828 transform ratio (cognitive load)
- `handleCommandKey` exhaustive call graph: 882 nodes, 12491 edges, cycles=true
- 4 hubs >400 edges each (`captureEvent` 457, `handleCommandKey` 457, `cancelLaneNaming` 442, `freeDelivery` 441)
- Single change to TUI flow touches many of them — high blast radius

The file already imports 40+ submodules. It's not a monolith that knows nothing — it's a monolith that knows too much about each one.

## Approach

Strangler Fig (Rule 15):
1. Create new module file
2. Move related code
3. Update `tui.zig` to import + delegate
4. Build passes
5. Old code removed in same commit

No "compatibility shim" left behind (Rule 9 outcome-oriented).

## Modules shipped (R1–R7)

| File | Phase | Pulled from `tui.zig` |
| --- | --- | --- |
| `tui/event_router.zig` | R1 | `captureEvent` — key/mouse event dispatch |
| `tui/command_router.zig` | R2 | `handleCommandKey` mode switch (struct-per-mode) |
| `tui/app_state.zig` | R3 | `App` state grouped into 6 sub-structs |
| `tui/background_delivery.zig` | R4 | background-job poll/format/deliver |
| `tui/lane_column.zig` | R5.2a | `drawLaneColumn` |
| `tui/diff_viewer_overlay.zig` | R5.2b | `drawDiffViewer` |
| `tui/layout.zig` | R5.2c | `rootLayout` math |
| `tui/root_layout.zig` | R6.2 | `drawRoot` layout |
| `tui/lifecycle.zig` | R6.3–R7.3 | deinit, handleTick, createParallelLane, handleDiffBrowseKey/Search/Comment, closeDiff, syncFocus, submit, ensureTick, handleDiffViewerEvent |
| `tui/widgets/background_jobs.zig` | R5.1a | `BackgroundJobsWidget` |
| `tui/widgets/permission.zig` | R5.1a | `PermissionWidget` |
| `tui/widgets/diff.zig` | R5.1b | `DiffBodyWidget` + `DiffCommentEditor` + `DiffSearchWidget` |
| `tui/widgets/loading.zig` | R5.1c | `LoadingWidget` |
| `tui/widgets/transcript.zig` | R5.1d | `TranscriptWidget` + `MessageListBuilder` |
| `tui/widgets/input.zig` | R6.1 | `InputWidget` + 13 wrapping helpers |
| `tui/widgets/overlay.zig` | R7.1 | `OverlayWidget` + `OverlayInner` |

## Remaining candidates

| File | Source | Blocker |
| --- | --- | --- |
| — | RootWidget handlers (`handleEvent`, `handleDiffSearchKey`, `handleDiffCommentKey`, `submit`, `syncFocus`, `ensureTick`) | Small methods, low ROI per commit |
| — | `submitMode` (~95 lines) | stays in `tui.zig` (25+ private-method promotions not worth it) |

Target: ≤ 2500 lines. Remaining: `tui.zig` ~5943 → -3500 to go. Likely several more R7.x commits.

## What stays in `tui.zig`

- `App` struct (with state fields moved to sub-structs)
- `RootWidget` (top-level vxfw widget)
- `init` / `run` lifecycle (deinit may move to R6 lifecycle module)
- Cross-module glue (calls into the routers)

Target: ≤ 2500 lines.

## Non-goals

- No behaviour change
- No new features
- No test additions (out of scope for this refactor; tracked separately if needed)
- No rename of public App methods (just relocate)

## Risks

- `captureEvent` is the hot path on every keypress. Inlining decisions matter. (Mitigated by R1.)
- `App` fields are read by ~30 files. Splitting state into sub-structs touches every call site. (Mitigated by R3.)
- `handleCommandKey` switch arms have shared local state — pulling them apart requires care. (Mitigated by R2.)
- R6 lifecycle extraction is blocked on private App method promotion; doing it without rethinking the boundary just churns `pub` keywords. (Documented; pick up in a dedicated session.)

Mitigation: do it in small commits, run `zig build` after each, do a manual smoke test (launch, type, submit, switch modes).
