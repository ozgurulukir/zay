# tui-split — Backlog

## Refactor targets

R1–R7.5 landed (42 atomic commits, `tui.zig` 8586 → 5100, -40.6%). 18 new modules.

All planned refactors completed. Remaining items deferred:

- **`submitMode`** — stays (R6.0 audit: ~25 private promotions not worth it)
- **`inputChanged` / `paletteInputChanged`** — vxfw callback adapters
- **RootWidget delegate stubs** — 1-line pass-throughs, negligible value

## Spotted but not in scope

- Cycle in `handleCommandKey` exhaustive graph — investigated during R2, resolved
  by the struct-per-mode refactor (edge count dropped significantly)
- `src/config.zig` 1206 lines — separate sub-project if recurring pain
- `src/session.zig` 1519 lines — same
- Test coverage for split modules — separate work item after refactor

