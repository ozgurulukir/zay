# _pm Index

Cross-linked index for project management artifacts.

## Projects (active)

- [tui-domain-extract](Projects/tui-domain-extract/) — Extract remaining domain clusters from `tui.zig`
  - State: Planned. `tui.zig` 5100 lines, 227 functions.
  - Created: 2026-07-22
  - Source: BFG analysis — coupling 85, code quality 70. `tui.zig` god object.
  - Result: 3 phases, `tui.zig` 5100 → **4409 (-13.5%)**, 3 new modules (910 lines).

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
