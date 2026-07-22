# tui-split — Todo

Items committed to, not yet started.

## Status

R1–R7.5 completed and pushed (42 atomic commits). `tui.zig` 8586 → 5100 lines (-40.6%).
`zig build test` 2.3s, all 310 tests pass. 18 new modules shipped.

The remaining ~5100 lines are App business logic with high internal coupling
(provider setup, session management, lane lifecycle, etc.). Each extraction
requires 5–15 pub promotions per move — ROI has diminished significantly.

## Candidates for future work (all deferred)

- **RootWidget delegate stubs** (~50 lines) — 1-line pass-throughs, can fold into lifecycle.zig
- **`submitMode`** — stays (R6.0 audit: ~25 private promotions not worth it)
- **`inputChanged` / `paletteInputChanged`** — vxfw callback adapters, tightly coupled to App
- **Test blocks** (~200 lines) — belong with tested code

## Done

- [x] R1 → R4 — see `done.md`
- [x] R5.1a–d — see `done.md`
- [x] R5.2a–c — see `done.md`
- [x] R6.0 boundary audit — see `audit-R6.md`
- [x] R6.1 InputWidget → `widgets/input.zig`
- [x] R6.2 drawRoot → `tui/root_layout.zig`
- [x] R6.3a–d lifecycle methods → `tui/lifecycle.zig`
- [x] R7.1 OverlayWidget → `widgets/overlay.zig`
- [x] R7.2 diff key handlers → `lifecycle.zig`
- [x] R7.3 RootWidget handlers → `lifecycle.zig`
- [x] R7.4 diff_utils, lanes, MessageListBuilder cleanup
- [x] R7.5 provider_model → `tui/provider_model.zig`
