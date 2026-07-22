# tui-domain-extract — Backlog

## Refactor targets

Extract remaining domain clusters from `tui.zig` (5100 lines → target ~3000).
Discovered by BFG analysis: `tui.zig` god object at 5.100 lines with 227
functions is the #1 coupling hotspot (BFG coupling score 85, code quality 70).

### Phase 1: Lane lifecycle → `tui/lane_lifecycle.zig` (~400 lines)

28 functions: lane naming, cycling, closing, merging, fullscreen toggle,
lanes picker, parked-lane management.

Functions to move:
- captureLaneContext, scheduleLaneNaming, drainLaneNaming, renameLaneBranch
- cancelLaneNaming, namingActive, reportLaneError, activeIndex
- anyTurnActive, cycleLane, switchToNextLane, toggleLaneFullscreen
- closeActiveLane, abandonLane, laneMergeDir, mergeLane
- createMergePicker, confirmMergeDest, openLanesPicker
- collectParkedLanes, laneOpenAtPath, reloadParkedLanes
- mergeSelectedParked, deleteSelectedParked, laneEntryCount
- clearLanesState, buildLaneEntries, handleLanesKey

### Phase 2: Diff lifecycle → `tui/diff_lifecycle.zig` (~110 lines)

Types + helpers for the async diff refresh pipeline.

Items to move:
- DiffCounts, DiffRefreshJob, DiffRefreshOutcome structs
- runDiffRefresh, diffCountCommand
- refreshDiffCounts, installDiffCounts, scheduleDiffRefresh
- cancelDiffRefresh, drainDiffRefresh, populateDiffFromCache
- diffCountsVisible

### Phase 3: Session switching → `tui/session_switcher.zig` (~140 lines)

Resume picker state management + session creation/switching.

Functions to move:
- openResumePicker, reloadResumeSessions, selectedResumeSummary
- visibleResumeCount, toggleSelectedResumeProject, resumeFoldIndex
- resumeClearFolds, resumeClear, syncResumeListCursor
- reloadTreeNodes, navigateToEntry, restoreCheckpointForBranch
- switchToSession, switchToNewSession, createRuntime
- reportSessionSwitchError

### Spotted but deferred

- submitMode / cancelMode (~125 lines) — stays per tui-split R6.0 audit
- At-search (~110 lines) — tightly coupled to input, low ROI
- Transcript navigation (~100 lines) — spread across metrics + lifecycle
- Queue management (~80 lines) — tightly coupled to beginSubmit
- test blocks (~200 lines) — belong with tested code
