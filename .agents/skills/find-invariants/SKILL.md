---
name: find-invariants
description: Use when designing a Zay feature or seam to discover, state, and encode ownership, lifecycle, persistence, concurrency, or boundary invariants before writing code (for Zig coding rules, use tigerstyle).
---

# Find Invariants

Make every load-bearing invariant explicit and structural before writing implementation code. Ground invariants in current callers, tests, source, `AGENTS.md`, and `docs/patterns/README.md` (using `docs/CODE_INTELLIGENCE.md` graph tools when available, with direct source and git history as the baseline).

## Required fields per invariant

Record all five fields for each invariant before concluding:

1. **Protected state or boundary** — what corruption, race, leak, or layer violation it prevents.
2. **Smallest owner** — the narrowest module or struct that can enforce it.
3. **Structural encoding** — how a `union(enum)`, branded/validated type, narrow context struct, or runtime `assert` makes invalid states unrepresentable or immediately caught.
4. **Failure and teardown behavior** — rollback, `errdefer`, cancellation, and cleanup guarantees.
5. **Proving regression test** — the test name and location that exercises both valid and invalid transitions.

## Existing Zay contracts to preserve

Check `docs/patterns/README.md` before inventing a new contract:

- `lib/` leaves never import `src/` (`INV-LEAF-1`).
- TUI leaf widgets take props/view models rather than `*App` (`INV-WIDGET-1`).
- `Job(T)` families are **arm-first** (assign the owning slot first, then arm through `&slot`), polled non-blockingly, adopted once, and joined only at teardown.
- Session persistence enqueues/persists before cache updates, and remote multi-statement writes use atomic batches (`INV-DB-BATCH`).
- Worktree and workspace comparisons use `src/paths.zig` (`pathsEqual` / `isSubpathOrEqual`).

Encode invariants in types and assertions that eliminate illegal branches rather than comments asking callers to remember rules.
