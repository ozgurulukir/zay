---
name: architect
description: Sketch caller usage, types, module ownership, and invariants before non-trivial implementation.
disable-model-invocation: true
---

# Architect

Design before implementing when a change crosses modules, introduces a state machine, or alters an ownership boundary. Skip this workflow for a one-function fix.

## Steps

1. **Ground** — Trace every system the change touches.
2. **Sketch alternatives** — Draft 2–3 distinct shapes in one decision table.
3. **Choose** — Commit to the smallest shape that prevents invalid states.
4. **Implement** — Code against the chosen sketch and Zay invariants.
5. **Re-ground** — Stop and redesign if workarounds repeat or ownership leaks.

## Ground

Build a traced model of callers, ownership, lifecycle, error paths, persistence boundaries, and Windows/POSIX differences. Use `how` and `AGENTS.md` discovery rules (`docs/CODE_INTELLIGENCE.md` graph tools when available, alongside direct source reads, tests, and git history). Use `why` only when historical rationale or an existing constraint matters. Read the relevant topic page under `docs/patterns/README.md` before proposing a new seam.

## Sketch alternatives

Write two or three genuinely different shapes, not cosmetic variations. Derive each type/signature sketch from caller usage first, and compare them locally in one decision table covering:

- state and memory ownership;
- module boundaries and imports;
- success, failure, cancellation, and teardown paths;
- test reachability;
- preserved or changed invariants (use `find-invariants` to make them structural).

## Choose

Pick the smallest shape that makes invalid states unrepresentable and keeps the reader's path short. State each rejected alternative and why it loses (wrong owner, extra mutable state, cross-layer import, blocked render path, unsafe retry, or speculative compatibility code).

Proceed without a human checkpoint by default. Pause only when the user asks to review the design first or when a choice causes an irreversible external change.

## Implement

Treat the chosen sketch as a contract: if implementation needs a new parameter or escape hatch, update the sketch before stacking workarounds. Preserve Zay's core invariants:

- `lib/` leaves never import `src/` (`INV-LEAF-1`).
- TUI leaf widgets take props/view models, not `*App` (`INV-WIDGET-1`).
- `Job(T)` families arm first (`arm-first`), poll non-blockingly, adopt once, and cancel only at teardown.
- Remote multi-statement session writes use atomic batches (`INV-DB-BATCH`); session writes enqueue/persist before cache updates.
- Worktree/cwd comparisons use `src/paths.zig` (`pathsEqual` / `isSubpathOrEqual`), and heavy provisioning stays off the render path.

## Re-ground

Scrap and redesign when the same workaround appears twice, callers depend on abstraction internals, optional fields are always populated in practice, or a lock compensates for avoidable shared ownership. Re-run `how` over the implementation, subtract dead weight, and repeat the alternative comparison.

## Output

- **Small change**: one page with caller usage, type/signature sketch, module map, invariants, chosen shape, and rejected alternatives.
- **Larger change**: read [`references/rationale-template.md`](references/rationale-template.md) and write the design package using that structure.
