# _pm Index

Cross-linked index for project management artifacts.

## Projects (active)

- [tui-split](Projects/tui-split/) — Split `src/tui.zig` into focused modules
  - State: R1–R7.5 pushed (42 commits). `tui.zig` 8586 → **5100 (-40.6%)**.
  - Created: 2026-07-21
  - Source: BFG analysis (cycles, coupling, 30x file size over limit)
  - Result: 18 new modules, 42 atomic commits, all tests pass (2.3s, 310/310).
    Remaining ~5100 lines are App business logic with diminishing ROI per extraction.
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
