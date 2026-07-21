# tui-split — In progress

One item at a time (Rule 9).

## Status

R1–R7.3 committed and pushed (37 atomic commits). `tui.zig`
8586 → 6143 lines (-2443, -28.5%). `zig build test` 2.3s, all 310 tests
pass.

### Shipped modules (17 new)

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
| `tui/lifecycle.zig` | R6.3–R7.3 | deinit, handleTick, createParallelLane, handleDiffBrowseKey/Search/Comment, closeDiff, syncFocus, submit, ensureTick, handleDiffViewerEvent |
| `tui/widgets/background_jobs.zig` | R5.1a | BackgroundJobsWidget |
| `tui/widgets/permission.zig` | R5.1a | PermissionWidget |
| `tui/widgets/diff.zig` | R5.1b | DiffBodyWidget + DiffCommentEditor + DiffSearchWidget |
| `tui/widgets/loading.zig` | R5.1c | LoadingWidget |
| `tui/widgets/transcript.zig` | R5.1d | TranscriptWidget + MessageListBuilder |
| `tui/widgets/input.zig` | R6.1 | InputWidget + 13 wrapping math helpers |
| `tui/widgets/overlay.zig` | R7.1 | OverlayWidget + OverlayInner |
| | | **~2450 total lines in new modules** |

### `submitMode` stays

`App.submitMode` (95 lines, ~25 private-method callers) was deemed not worth
extracting in the R6.0 audit — the promotion churn outweighs the move.

### Still in `tui.zig` (~6143 lines)

- `App` struct definition + field accessors
- All App business logic (~3800 lines: provider setup, session management,
  diff viewer, lane lifecycle, input handling, save, etc.)
- Inline test blocks (~200 lines)
- `submitMode` (stays)
- RootWidget delegate stubs (~30 lines, 1-line each)
- `RootWidget` struct definition + consts

Next: target ≤ 2500 lines. The remaining ~3500 diff is App-logic-heavy;
each move requires more prep (pub promotions) than the R5–R7 widget/handler
extractions did. Consider starting a separate sub-project or wrapping up
tui-split here.
