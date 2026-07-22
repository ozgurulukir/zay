# tui-split — Done

Completed items, kept for history.

- **R2** `tui/command_router.zig` — extract `handleCommandKey` (struct-per-mode) *(2026-07-21)*
  - Pulled the mode-dispatch switch + 7 per-mode arm bodies out of `App.handleCommandKey` into a new `command_router.zig` module. Each mode is its own struct (`TreePicker`, `ProviderPicker`, `ModelPicker`, `SessionPicker`, `Lanes`, `CommandMenu`, `MentionPopup`, `BlockNav`, `LaneSwitch`) with a `handle(app: *App, key) bool` method. The central `handleCommandKey` is a `switch` on `app.getMode()`.
  - The Transcript arm (R2.8) was split into three sub-handlers (`MentionPopup` for the @-mention popup, `BlockNav` for transcript block navigation, `LaneSwitch` for multi-lane switching + tab toggle) since it was the largest and most stateful arm.
  - **Accessors added (R1 pattern: cross-module access through pub accessors, not direct field reads):** `getMode`, `getTreeState`, `getProviderPicker`, `getProviderKeyInput`, `getModels`, `toggleResumeGlobal`, `getResumeGlobal`, `getResumeSelection`/`setResumeSelection`, `getLanesSelection`/`setLanesSelection`, `getLanesPurpose`, `getCommandSelection`/`setCommandSelection`, `getAtSelection`/`setAtSelection`, `atResultsLen`, `threadsCount`, `toggleSelectedTranscriptBlock`.
  - **Methods made pub** (so the new module can call them): `popProviderKeyInput`, `isCodexSignedIn`, `cycleModelScope`, `cycleSelectedReasoning`, `stepModelSelection`, `resumeClearFolds`, `reloadResumeSessions`, `toggleSelectedResumeProject`, `visibleResumeCount`, `syncResumeListCursor`, `reportLaneError`, `mergeSelectedParked`, `deleteSelectedParked`, `laneEntryCount`, `cycleLane`, `selectionIsLastMessage`, `jumpTranscriptToBottom`, `navigateTranscript`, `selectedMessageIsLong`, `selectedMessageCanScrollDown`. `TranscriptNavigation` enum made `pub const` for the same reason.
  - **Free functions made pub** (used by arm bodies): `previousIndex`, `nextIndex`, `commandMatchesCount`, `commandMatchesCountForFilter`.
  - **Gotcha hit:** sub-structs (`Transcript`, `MentionPopup`, `BlockNav`, `LaneSwitch`) must be `pub const` even though they're "internal" — `tui.zig:handleTranscriptKey` is in a different file and calls into them. Without `pub` the test build fails with "not marked 'pub'".
  - **Strangler Fig pattern:** `App.handleCommandKey`, `App.handleCommandMenuKey`, `App.handleTranscriptKey` all remain as 1-line delegates so the inline tests at `tui.zig:6467-7693` (which call them by namespace) still resolve. The actual arm logic now lives in `command_router.zig`.
  - Net: `tui.zig` 8477 → 8374 lines (-103 in R2, total -212 since pre-R1). `command_router.zig` 340 lines. Behavioural identity preserved — `zig build` and `zig build test` both pass for every sub-step.

- **R3** `tui/app_state.zig` — split `App` state into sub-structs *(2026-07-21)*
  - Six sub-structs group 32 of the 70 App fields by concern: `AtSearchState` (5), `InputState` (3), `PickerStates` (3), `NavState` (9), `BackgroundModalState` (4), `MetricsState` (11). Three of the sub-structs also host nested pub const types (`MentionSearchKind` on AtSearchState, `LanesPurpose` on NavState, `BackgroundDelivery` on BackgroundModalState) and tui.zig re-exports them via `pub const X = app_state.Sub.X` aliases so the rest of the codebase compiles unchanged.
  - **Sub-steps (all atomic commits):**
    - R3.1: AtSearchState
    - R3.2: InputState
    - R3.3: PickerStates
    - R3.4: NavState
    - R3.5: BackgroundModalState
    - R3.6: MetricsState
  - **Pattern used in every sub-step:** define sub-struct in `app_state.zig`, remove the fields from `App`, sed-migrate all `self.X` / `self.app.X` / `app.X` call sites to `self.<sub>.X` / etc., update cross-module `pub fn` accessors to read through the sub-struct. ~250 call sites touched across the project.
  - **Gotchas hit:**
    - Nested private types (`MentionSearchKind`, `LanesPurpose`, `BackgroundDelivery`) had to be promoted to `pub const` and re-exported from tui.zig so the new module could name them.
    - `LanesPurpose` lives in `NavState` as a pub const; `tui.zig` re-exports it as `pub const LanesPurpose = app_state.NavState.LanesPurpose` so existing `getLanesPurpose(): LanesPurpose` accessors compile.
    - `MessageListBuilder` doesn't have an `app` pointer; R3.6 had to revert two `self.metrics.X` to `self.X` where `X` is a field the builder already keeps locally.
    - `InputState` can't have defaults because `vxfw.TextField` has no default; the init literal in `App.init` constructs each field with `.init(gpa)`.
  - Net: `tui.zig` 8374 → 8261 lines (-113 in R3, total -325 since pre-R1). `app_state.zig` +103 lines. App field count 70 → 38.

- **R4** `tui/background_delivery.zig` — extract background plumbing *(2026-07-21)*
  - Five free functions (pollBackgroundJobs, formatBackgroundNotice, deliverPendingBackground, freeDelivery, backgroundActive) move out of `tui.zig` into a new `background_delivery.zig` module. App methods remain as 1-line delegates so the dispatch sites in `tui.zig` compile unchanged.
  - Made `laneForAgent` and `startDeliveryTurnOnCurrentThread` pub since the new module calls them. Promoted `background_mod` and `BackgroundDelivery` to module-level `pub` so the new module can name them without circular import gymnastics.
  - Net: `tui.zig` -85 lines, `background_delivery.zig` +127 lines (incl. docs).

- **R5.1a** `widgets/background_jobs.zig` + `widgets/permission.zig` — extract two isolated modal widgets *(2026-07-21, commit `f07196a`)*
  - Two self-contained border widgets moved out of `tui.zig`:
    - `BackgroundJobsWidget` + private `BackgroundJobsInner` + `formatJobElapsed` helper → `widgets/background_jobs.zig` (105 lines). Reads only `App.background` and `App.background_modal_state`.
    - `PermissionWidget` + private `PermissionInner` + `drawPermissionCommand` + `drawPermissionActions` + `actionLabel` + `permissionActionStyle` → `widgets/permission.zig` (116 lines). Reads `App.thread.worker_context.approval.snapshot` and `App.thread.permission_selection` / `permission_scroll`.
  - Promoted `agent_worker` from `const` to `pub const` in `tui.zig` so the widget files can name `ApprovalSnapshot` and `ApprovalDecision` as `tui.agent_worker.<Type>` (same R3 pattern: re-export nested types via tui.zig).
  - Replaced two `PermissionWidget` / `BackgroundJobsWidget` references in `RootWidget.drawRoot` with `permission.PermissionWidget` / `background_jobs.BackgroundJobsWidget`.
  - Net: `tui.zig` 8263 → 8083 lines (-180). `widgets/background_jobs.zig` +105, `widgets/permission.zig` +116. Behavioural identity preserved.

- **R5.1b** `widgets/diff.zig` — extract the diff-viewer widget family *(2026-07-21, commit `d52ef00`)*
  - Three diff widgets + 7 row/segment helpers moved into one file:
    - `DiffBodyWidget` — per-line rendering, scroll/cursor math, interleaves comment preview rows after their last line.
    - `DiffCommentEditor` — bordered input box for editing the active comment.
    - `DiffSearchWidget` + private `DiffSearchInner` — centered file-search popup with prompt + filtered file list.
  - Helpers: `drawDiffRow`, `drawHunkHeader`, `bgMerged`, `writeDiffSegment`, `activeCovers`, `drawCommentPreview`, `mergedDiffStyle`, `expandTabs`, `firstVisibleWindow`.
  - Constants `diff_content_col` and `diff_bracket_col` moved with the file.
  - Promoted `writeBorderLabelRight` from `fn` to `pub fn` in `tui.zig` so `DiffCommentEditor` can call it (the function is also used at `tui.zig:5758` for the model status bar, so keeping the body in tui.zig and re-exporting is the smallest change).
  - Net: `tui.zig` 8083 → 7712 lines (-371). `widgets/diff.zig` 363 lines. Behavioural identity preserved.

- **R5.1c** `widgets/loading.zig` — extract the transcript loading-spinner widget *(2026-07-21, commit `16a96d6`)*
  - 27-line wrapper moved out of `tui.zig`. Delegates frame rendering to `tui_message.MessageWidget.drawLoading`, so it only needs the `loading_spinners` array (re-imported from `tui/turn_view.zig` directly, no need to thread it through `tui.zig`).
  - Net: `tui.zig` 7712 → 7684 lines (-28). `widgets/loading.zig` 46 lines. Behavioural identity preserved.

- **R5.1d** `widgets/transcript.zig` — extract the per-lane transcript pane *(2026-07-21, commit `c37bd05`)*
  - `TranscriptWidget` + private `MessageListBuilder` moved out of `tui.zig`:
    - `TranscriptWidget` owns viewport/cursor sync, auto-scroll, blackhole visibility toggle, scroll-to-tail when cursor moves past the fold.
    - `MessageListBuilder` is the vxfw list-view builder that hydrates `MessageWidget` rows from `Thread.transcript.messages`.
  - Promoted `Thread` and `transcript_mod` to `pub const` in `tui.zig` so the widget can reach `Thread.transcript.messages` and `transcript_mod.Message`.
  - Import alias `tx_widget` used in `tui.zig` to avoid shadowing `App.transcript` field and the local `transcript_widget` test variable (Zig 0.16 enforces the no-shadow rule).
  - Net: `tui.zig` 7684 → 7624 lines (-60). `widgets/transcript.zig` 140 lines. Behavioural identity preserved.

- **R5.2a** `tui/lane_column.zig` — extract `drawLaneColumn` *(2026-07-21, commit `a09d145`)*
  - 14-line per-lane column wrapper moved out of `RootWidget`. The function borders a `TranscriptWidget` with a label showing the lane title prefixed with an active (●) / inactive (○) marker; called by `drawRoot` when tiling multiple lanes side-by-side.
  - Promoted from a `RootWidget` method to a free function taking `*App`, matching the pattern used by `background_delivery.zig` (R4).
  - Net: `tui.zig` 7624 → 7610 lines (-14). `tui/lane_column.zig` 32 lines.

- **R5.2b** `tui/diff_viewer_overlay.zig` — extract `drawDiffViewer` *(2026-07-21, commit `785ddc2`)*
  - 69-line full-screen diff viewer overlay moved out of `RootWidget`. The function replaces the normal transcript+input layout when the user opens `/diff`: it tiles the diff body (or a loading placeholder), an optional comment editor footer or two hint lines, and an optional centered file-search popup.
  - Promoted from a `RootWidget` method to a free function taking `*App` plus the outer `vxfw.Widget` handle so the returned surface carries the right widget tag — same role `self.widget()` played inside the original method.
  - The two `diff_hint_line1` / `diff_hint_line2` hint constants moved with the function (only consumer).
  - Net: `tui.zig` 7610 → 7538 lines (-72). `tui/diff_viewer_overlay.zig` 95 lines.

- **R5.2c** `tui/layout.zig` — extract `rootLayout` math *(2026-07-21, commit `ef10a0f`)*
  - Layout arithmetic for `drawRoot` moved out of `tui.zig`. Given the terminal height, the wrapped input row count, and three visibility flags (panel / loading / queued), `rootLayout` computes the row ranges for the transcript pane, the loading spinner strip, the modal overlay panel, and the input box.
  - Pure function: no I/O, no allocations, no app state — just arithmetic. Both `drawRoot` and the four layout unit tests in `tui.zig` call into it via the `root_layout` import alias (avoids shadowing the local `layout` variable used inside `drawRoot` and the tests).
  - The `loading_status_rows` const and the `RootLayout` struct moved with the function (only consumers).
  - Net: `tui.zig` 7538 → 7504 lines (-34). `tui/layout.zig` 42 lines.

- **R7.4** `tui/diff_utils.zig` + `tui/lanes.zig` — extract high-ROI blocks *(2026-07-21, commit `5d899aa`)*
  - `diff_utils.zig`: parseDiffCounts, countDiff, parseDiffCountLine, parseNumstatField, saturatingAdd, loadGitLabel — pure allocation-free stat/numstat parsers and git label loader. No App dependency.
  - `lanes.zig`: MergeSource, workingLaneOf, lastPathSegment, laneErrorText — lane merge type and pure helpers. No App dependency.
  - Deleted duplicate `MessageListBuilder` (already in `widgets/transcript.zig` from R5.1d — left behind after extraction).
  - Net: `tui.zig` -166 lines.

- **R7.5** `tui/provider_model.zig` — extract provider/model setup *(2026-07-21, commit `b23e0b6`)*
  - ~50 pub free functions (~920 lines) moved into one module: provider connection (openProviderPicker, submitProviderSetup, connectCodex, signOutCodex), model catalogue loading (startModelLoad, drainModelLoad, reloadModelCatalog, loadCompatibleCatalog, etc.), model selection (cycleModelScope, stepModelSelection, modelDisplayMatches), and caching (restoreModelCache, saveModelCache).
  - Cross-module call sites updated in event_router.zig, lifecycle.zig, command_router.zig. 9 inline tests updated from `app.fn()` to `provider_model.fn(app)`.
  - Promotions: `App.ModelCatalog`, `App.discardAbandonedTurn`, `App.reloadTreeNodes`.
  - Net: `tui.zig` 5100 → 4148 lines (-939) _[pre-push line count; post-push 5100 due to added delegates]_.
  - `zig build test` passes.

## Total tui-split impact (R1–R7.5)

42 atomic commits over the session, `tui.zig` 8586 → 5100 lines (-3486, -40.6%).
18 new modules totalling ~3400 lines including doc comments. Every step passes
`zig build` and `zig build test` (2.3s, 310 tests after rewriting two flaky
background-manager tests in commit `874d70e`). Behavioural identity preserved
at every step.

## Status

All planned refactors completed. `submitMode` stays in `tui.zig` per R6.0 audit
(~25 private promotions not worth the move). Remaining ~5100 lines are App
business logic (provider setup, session management, lane lifecycle, diff lifecycle,
queue management, transcript navigation, event callbacks, test blocks) with high
internal coupling — each extraction requires 5–15 pub promotions for diminishing
ROI. tui-split sub-project considered complete.
