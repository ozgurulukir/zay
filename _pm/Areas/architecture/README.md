# Architecture — ongoing area

Notes on module boundaries, layering, and the structural problems that recur.

## Current state (as of 2026-07-21, post-R5)

- `src/tui.zig` 7504 lines (down from 8586, -1082 / -12.6% over R1–R5); still mixes event routing, command dispatch, state, draw, lifecycle
- Pre-R1 cycle in `handleCommandKey` exhaustive call graph (882 nodes, 12491 edges) was broken by R2 (struct-per-mode)
- Top hubs by edge count pre-R1: `captureEvent` 457, `handleCommandKey` 457, `cancelLaneNaming` 442, `freeDelivery` 441 — R1/R2/R4 cut these down
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

- [tui-split](../Projects/tui-split/) — applying the above to `src/tui.zig`; R6 queued
