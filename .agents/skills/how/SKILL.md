---
name: how
description: Use for how-does-X-work questions, code walkthroughs before changing something, and placement, ownership, or layering questions in the Zay codebase. Follow repository instructions and verify behavior in source.
---

# How

Explain runtime behavior and architecture from evidence. Produce a mental model
that lets a maintainer decide where to edit and what contracts must remain true.
Use why for motivation and history; use this skill for mechanics, ownership, and
flow.

## Discovery order

Read user- and project-level instructions first. If they configure a repository
index, search service, or other discovery helper, use it according to those
instructions. Otherwise use standard source search, direct file reads, tests,
and version-control history. Prefer symbol-aware navigation when available, but
never make an optional discovery service a prerequisite for answering.

Use literal search for strings, error messages, config keys, and non-code files.
If an index is stale, unavailable, or incomplete, continue with direct source
inspection and state the limitation. Never treat a missing indexed result as
proof that code does not exist.

## Explain workflow

1. Interpret the question and state a best-guess scope when it is ambiguous.
2. Identify the actual trigger, state owner, and terminal effect. Start at a
   public command, route, tool, tick, or test rather than a convenient helper.
3. Trace the path through types and boundaries. Confirm each important step in
   source; do not infer behavior from file names.
4. Mark concurrency, ownership, persistence, and platform transitions. In Zay,
   check the relevant invariants in docs/PATTERNS.md, especially:
   - lib/ leaves do not import src/.
   - execution/AI adapters do not depend on the TUI.
   - TUI leaf widgets receive props/view models, not App pointers.
   - Job(T) async families are polled from ticks and joined only at teardown.
   - session writes persist before cache updates.
   - lane cwd/worktree comparisons use the shared path helpers.
5. Present the shortest useful explanation with source paths and symbols.

For Zay, the broad map is lib/ leaves, src/tools and src/ai adapters,
src/agent orchestration, src/session persistence, and src/tui presentation.
Confirm the map against docs/ARCHITECTURE.md for the subsystem in question.

## Placement questions

When asked where code should live, decide in this order:

- Is it pure, reusable, and presentation-free? Prefer lib/ or a narrow leaf.
- Is it protocol, shell, schema, or external-I/O adaptation? Keep it at the
  relevant src/ai, src/tools, src/mcp, src/config, or src/db boundary.
- Is it turn/session orchestration? Keep it in src/agent or src/session.
- Is it user interaction, render state, or lifecycle? Keep it in src/tui; leaf
  widgets should take view models and lifecycle modules should take narrow ctx.
- Is the proposed module crossing a lower-to-higher layer? Treat that as a
  design smell and check the documented invariant before editing.

## Critique mode

When the user asks whether the architecture is good, explain the current flow
first, then evaluate it against explicit invariants and observed call paths.
Separate:

- Act on: a concrete contract violation, cycle, race, leak, or wrong owner.
- Consider: a real tradeoff with measurable cost but no clear violation.
- Noted: a valid observation that does not justify a change.
- Dismissed: a claim not supported by the code or current docs.

Do not manufacture parallel model opinions or depend on a particular vendor
workflow. If independent comparison is valuable, make two bounded hypotheses
and test each against the same source evidence.

## Output shape

- Overview: what the subsystem does and why the reader should care.
- Key concepts: only the types and owners needed for the explanation.
- Flow: trigger to effect, including decisions and async boundaries.
- Where things live: a short file map with symbols.
- Gotchas: non-obvious invariants, platform behavior, and failure modes.
- Evidence note: repository/index freshness and any coverage or fallback limits.

Use exact names and paths. Prefer a compact flow diagram only when it makes
three or more dependent stages easier to follow.
