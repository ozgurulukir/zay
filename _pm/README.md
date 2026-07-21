# _pm Index

Cross-linked index for project management artifacts.

## Projects (active)

- [tui-split](Projects/tui-split/) — Split `src/tui.zig` into focused modules
  - State: R1–R7.3 pushed (37 commits). `tui.zig` 8586 → **6143 (-28.5%)**.
  - Created: 2026-07-21
  - Source: BFG analysis (cycles, coupling, 30x file size over limit)
  - Result: 17 new modules, all tests pass (2.3s, 310/310). Remaining ~5800 lines
    are App methods, inline tests, and `submitMode` (stays per R6.0 audit).

## Areas (ongoing)

- [architecture](Areas/architecture/) — Codebase structure, module boundaries, layering
  - See tci-bfg skill output and `src/tui.zig` as canonical examples of where it breaks

## Resources (reference)

- AGENTS.md — top-level rules
- `src/` — current code

## Workflow

1. New work → `Projects/<name>/backlog.md`
2. Picked up → move items to `todo.md`
3. In progress → `wip.md` (one item at a time, Rule 9 KISS)
4. Done → `done.md`
5. Stale > 30d → `Archives/`
