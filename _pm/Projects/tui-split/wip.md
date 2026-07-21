# tui-split — In progress

One item at a time (Rule 9).

## Status

R1–R7.5 committed and pushed (42 atomic commits). `tui.zig`
8586 → 5100 lines (-3486, -40.6%). `zig build test` 2.3s, all 310 tests
pass.

### Shipped modules (18 new)

| Module | Phase | Content |
| --- | --- | --- |
| `tui/event_router.zig` | R1 | `captureEvent` |
| `tui/command_router.zig` | R2 | `handleCommandKey` (struct-per-mode) |
| `tui/app_state.zig` | R3 | App state sub-structs |
| `tui/background_delivery.zig` | R4 | background plumbing |
| `tui/layout.zig` | R5.2c | `rootLayout` math |
| `tui/lane_column.zig` | R5.2a | `drawLaneColumn` |
| `tui/diff_viewer_overlay.zig` | R5.2b | `drawDiffViewer` |
| `tui/root_layout.zig` | R6.2 | `drawRoot` |
| `tui/lifecycle.zig` | R6.3–R7.3 | deinit, handleTick, createParallelLane, diff handlers, syncFocus, submit, ensureTick |
| `tui/diff_utils.zig` | R7.4 | pure diff-count parsers |
| `tui/lanes.zig` | R7.4 | MergeSource + lane helpers |
| `tui/provider_model.zig` | R7.5 | provider + model catalogue setup (~50 fns) |
| `tui/widgets/{9 files}` | R5–R6 | input, overlay, transcript, diff, loading, permission, background_jobs, + existing ones |
| | | **~3400 total lines in new modules** |

### `submitMode` stays

`App.submitMode` (~95 lines) stays in `tui.zig` per R6.0 audit.

### What's left in `tui.zig` (~5100 lines)

- `App` struct + accessors (~150 lines)
- `RootWidget` struct + consts + delegates (~100 lines)
- submitMode (~95 lines)
- Session management (selectedResumeSummary, visibleResumeCount, etc.)
- At-search (updateAtSearch, setMentionSearch, etc.)
- Queue management (enqueueSubmit, selectPrevQueued, etc.)
- Input helpers (peekInput, insertInputNewline, moveInputCursorVertical)
- Transcript navigation (navigateTranscript, scrollSelectedLongMessage, etc.)
- Lane lifecycle (scheduleLaneNaming, mergeLane, abandonLane, etc.)
- Diff lifecycle (scheduleDiffRefresh, refreshDiffCounts, etc.)
- Event callbacks (inputChanged, paletteInputChanged)
- test blocks (~200 lines)
- Module-level constants + type defs
- run() + init()

Recommenation: tui-split has reached diminishing returns. The remaining
~5100 lines are App business logic with high internal coupling. Each
move requires 5–15 pub promotions. Consider wrapping up tui-split here
and tackling the remaining clutter through focused feature work instead.
