# tui-domain-extract — Done

Completed items, kept for history.

- **Phase 1** `tui/lane_lifecycle.zig` — extract lane lifecycle *(2026-07-22, commit `6c38502`)*
  - 19 pub functions + 4 internal helpers moved. Strangler Fig pattern.
  - `tui.zig` 5100 → **4728** (-372, -7.3%). `lane_lifecycle.zig` +491 lines.
  - `zig build` and `zig build test` pass.

- **Phase 2** `tui/diff_lifecycle.zig` — extract diff lifecycle *(2026-07-22, commit `8867b57`)*
  - 3 structs (DiffCounts, DiffRefreshJob, DiffRefreshOutcome), 1 command const,
    8 App methods, 1 private free function moved. Re-exported as `tui.DiffCounts`
    / `tui.DiffRefreshOutcome` for backward compat.
  - `tui.zig` 4728 → **4571** (-157, -3.3%). `diff_lifecycle.zig` +193 lines.
  - `zig build` and `zig build test` pass.

- **Phase 3** `tui/session_switcher.zig` — extract session switching *(2026-07-22, commit `c9b7a5c`)*
  - 14 App methods + 2 private helpers + 2 free functions moved. Covers resume
    picker (openResumePicker, reloadResumeSessions, etc.), session creation
    (switchToSession, switchToNewSession, createRuntime), timeline navigation
    (navigateToEntry, restoreCheckpointForBranch, reloadTreeNodes).
  - Promotions: `templateRuntime`, `installRuntime`, `clearConversation`,
    `rebuildTranscriptFromAgent` made `pub` (were `fn` private, now called from
    `session_switcher.zig`). `resumeSummaryLessThan` made `pub`.
  - `tui.zig` 4571 → **4409** (-162, -3.5%). `session_switcher.zig` +226 lines.
  - `zig build` and `zig build test` pass.

## Total impact (all 3 phases)

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| `tui.zig` lines | 5100 | **4409** | **-691 (-13.5%)** |
| New modules | — | 3 (491 + 193 + 226 = **910 lines**) | |
| Functions moved | — | 28 lane + 11 diff + 18 session = **57** | |
| Promotions to `pub` | — | activeIndex, templateRuntime, installRuntime, clearConversation, rebuildTranscriptFromAgent, resumeSummaryLessThan | |
| `zig build` | ✓ | ✓ | |
| `zig build test` | ✓ | ✓ | |
| Commits | — | 3 (`6c38502`, `8867b57`, `c9b7a5c`) | |
