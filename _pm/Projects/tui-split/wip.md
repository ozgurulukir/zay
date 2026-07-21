# tui-split — In progress

One item at a time (Rule 9).

## Status

R1–R6 complete and pushed to `origin/main` (34 atomic commits). R7.1 (OverlayWidget
extraction) done but not yet pushed (1 local commit). `tui.zig`
8586 → ~5943 lines (-2643, -30.8%). `zig build test` 2.3s, all 310 tests
pass.

`submitMode` stays in `tui.zig`. Remaining large blocks:
- RootWidget event mechanics (`handleEvent`, `captureEvent` dispatcher)
- `handleDiffSearchKey`, `handleDiffCommentKey`
- `submit`, `syncFocus`, `ensureTick`
- Test blocks (~200 lines)

Next: pick up as a separate sub-project when the diff warrants it.
