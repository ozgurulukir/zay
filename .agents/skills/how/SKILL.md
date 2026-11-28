---
name: how
description: Use when the user asks how a Zay subsystem works, needs a code walkthrough before editing, or asks where code belongs across layers (for design rationale or git history, use why).
---

# How

Explain runtime behavior and architecture from source evidence so a maintainer knows where to edit and which contracts hold. Use `how` for mechanics, ownership, and flow; use `why` for design motivation and git history.

## Discovery order

1. Read `AGENTS.md` and `docs/CODE_INTELLIGENCE.md`. When graph tools (Codebase Memory / GitNexus) are indexed and available, use them for symbol discovery; otherwise inspect source, tests, and git history directly.
2. Use literal search (`rg`) for strings, error messages, config keys, and docs.
3. Verify negative index results with literal search and direct reads before concluding code is absent; note any index staleness or fallback limits.

## Explain workflow

1. **Scope** — State the question and best-guess scope if ambiguous.
2. **Anchor** — Find the real trigger, state owner, and terminal effect (CLI entry, command, tool, tick, or test), not just an internal helper.
3. **Trace** — Follow types and boundaries in source; confirm behavior from code rather than file names.
4. **Check invariants** — Consult the relevant page under `docs/patterns/README.md` (especially `architecture-and-layering.md` and `tui-lanes-and-worktrees.md`):
   - `lib/` leaves never import `src/` (`INV-LEAF-1`).
   - `src/tools/` and `src/ai/` adapters have zero TUI dependencies.
   - TUI leaf widgets take props/view models, not `*App` (`INV-WIDGET-1`).
   - `Job(T)` families are **arm-first**, polled from ticks, and joined only at teardown.
   - Session writes enqueue/persist before cache updates.
   - Lane cwd and worktree comparisons use `src/paths.zig`.
5. **Synthesize** — Present the shortest useful explanation with exact file paths and symbol names.

Broad Zay layer map (confirm against `docs/ARCHITECTURE.md` and `docs/index.md`): `lib/` pure leaves; `src/tools/`, `src/ai/`, `src/config/`, `src/db/`, `src/mcp/`, `src/lua/` adapters and boundaries; `src/agent/` and `src/session/` orchestration and persistence; `src/tui/` presentation and lifecycle.

## Placement questions

Decide where new code belongs in this order:

1. Pure, reusable, presentation-free utility → `lib/` or a narrow leaf module.
2. Protocol, shell, schema, or external I/O adaptation → `src/ai/`, `src/tools/`, `src/mcp/`, `src/config/`, `src/db/`, or `src/lua/`.
3. Turn, context, or session orchestration → `src/agent/` or `src/session/`.
4. User interaction, render state, or UI lifecycle → `src/tui/` (leaf widgets under `src/tui/widgets/` take view models; lifecycle modules take narrow contexts).

Treat any lower-to-higher layer import as a design smell and check `docs/patterns/architecture-and-layering.md` before editing.

## Critique mode

When asked whether an architecture is sound, trace the current flow first, then evaluate it using [`references/critique-rubric.md`](references/critique-rubric.md). Classify findings into:

- **Act on** — concrete contract violation, cycle, race, leak, or wrong owner.
- **Consider** — real tradeoff with measurable cost but no clear violation.
- **Noted** — valid observation that does not justify a change.
- **Dismissed** — claim unsupported by code or current docs.

Work directly from source evidence; when comparing alternatives, test at most two bounded hypotheses against the same code.

## Output

Adapt to the question, covering exact paths and symbols:

- **Overview** — what the subsystem does and why it matters.
- **Key concepts** — central types and state owners only.
- **Flow** — trigger to terminal effect, including async/thread boundaries (add a compact diagram only for 3+ dependent stages).
- **Where things live** — short file/symbol map.
- **Gotchas** — non-obvious invariants, platform differences, and failure modes.
- **Evidence note** — index status and any coverage/fallback limits.
