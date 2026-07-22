# Architecture — ongoing area

Notes on module boundaries, layering, and the structural problems that recur.

## Current state (as of 2026-07-22, post-tui-domain-extract Phase 7)

- `src/tui.zig` 4141 lines (down from 8586, -4445 / -51.8% over 49 commits); still mixes remaining App business logic (submitMode, beginSubmit, queue, checkpoint), but event routing, command dispatch, draw, lifecycle, widgets, provider/model, lane lifecycle, diff lifecycle, session switching, at-search, transcript navigation, permission, and event callbacks are all in dedicated modules.
- Pre-R1 cycle in `handleCommandKey` exhaustive call graph (882 nodes, 12491 edges) was broken by R2 (struct-per-mode)
- 7 logical components in `code-tandem` (src, lib, py, root, tools, scripts, bench) but cross-component edges = 0 (Zig tree-sitter integration is partial)

## Recurring smells

- "Just one more field on App" — the central struct grows (R3 put state into 6 sub-structs; R6.0 will revisit)
- "Just one more mode in handleCommandKey" — the switch grows (R2 made each mode its own struct)
- Inline `if self.mode == .X` checks scattered across the file
- Helpers that exist solely to avoid touching `App` directly

## Rules of thumb

- New state on `App` → should go to a sub-struct (R3 of tui-split)
- New mode in `handleCommandKey` → should become a struct with a `handle` method (R2)
- File > 500 lines → split (Rule 10)
- Cyclic call graph → flag, don't paper over

## Active project

- [tui-split](../Archives/tui-split/) — applying the above to `src/tui.zig`; R1–R7.5 completed, 8586→4141 lines.
- [tui-domain-extract](../Archives/tui-domain-extract/) — Phase 1-7 domain cluster extraction, 5100→4141 lines.
- Both sub-projects complete and archived.
