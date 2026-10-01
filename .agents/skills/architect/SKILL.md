---
name: architect
description: Sketch types, signatures, and module structure before code, then stay in the loop while implementation fills in. Use for /architect, design-this requests, or non-trivial changes where the wrong shape would be expensive.
disable-model-invocation: true
---

# Architect

Design before implementing when the change crosses modules, introduces a new
state machine, or changes an ownership boundary. The output is a small,
reviewable contract: caller usage first, then types, signatures, module
ownership, invariants, and a decision record. Do not design ceremony for a
one-function fix.

## Start

Keep an explicit phase checklist:

1. Ground
2. Sketch alternatives
3. Choose
4. Implement
5. Re-ground if the shape fails

## Ground

Build a traced model of every system the change touches. Use the how skill and
the repository's own discovery instructions. Use any configured index or search
helper when available, but keep the design understandable and executable with
ordinary source reads, tests, and version-control history. Use why only when
existing rationale or a historical constraint matters.

Record the current caller usage, ownership, lifecycle, error paths, persistence
boundaries, and platform differences. Read the relevant docs/PATTERNS.md section
before proposing a new seam.

## Sketch alternatives

Write two or three genuinely different shapes, not cosmetic variations. For
each, derive the type/signature sketch from the caller's usage and show:

- state and ownership;
- module boundaries and imports;
- success, failure, cancellation, and teardown paths;
- how tests reach the new logic;
- which existing invariant it preserves or changes.

Use the principle-exhaust-the-design-space guidance, but compare the alternatives
locally in one decision table. Do not require a particular runner, model, or
external orchestration service.

## Choose

Pick the smallest shape that makes invalid states difficult to represent and
keeps the reader's path short. State the rejected alternatives and why they
lose: wrong owner, extra mutable state, cross-layer dependency, blocked render
path, unsafe retry, or unnecessary compatibility code.

Proceed without a human checkpoint by default. Pause only when the user
explicitly asks to see the design before implementation or when a choice would
cause an irreversible external change.

## Implement

Treat the chosen sketch as a contract, not a prison. If implementation needs a
new parameter or escape hatch, stop and decide whether the sketch missed a
requirement or the implementation is overreaching. Update the design before
stacking workarounds.

For Zay, preserve the relevant invariants: lib/ does not import src/; TUI leaf
widgets use props/view models; Job(T) owns App-level async families; remote
multi-statement session writes are atomic batches; persistence precedes cache
updates; worktree paths use pathsEqual; and heavy provisioning never blocks the
render loop.

## Re-ground when the shape fails

Scrap and redesign when the same workaround appears twice, callers understand
the abstraction's internals, optional fields are always populated in practice,
or a new lock is compensating for shared ownership that could be removed. First
re-run how over the implementation, subtract dead weight, then repeat the
alternative comparison with the new evidence.

## Output

For a small change, one page is enough: caller usage, type/signature sketch,
module map, invariants, chosen shape, and rejected alternative. For a larger
change, keep that package in the planning artifact or design document used by
the implementation.
