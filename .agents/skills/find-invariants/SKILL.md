---
name: find-invariants
description: Use when architecting a Zay feature and need to discover, state, and encode its ownership, lifecycle, persistence, concurrency, or boundary invariants.
---

The goal is to make the solution's invariants explicit before implementation.
Ground them in current callers, tests, source, and project instructions. Use a
configured code index if one is available, but do not require an external
discovery service to identify or verify an invariant.

For each invariant, record:

- the state or boundary it protects;
- the smallest owner that can enforce it;
- whether a union(enum), branded/validated value, narrow context struct, or
  runtime assertion makes it structural;
- the failure and teardown behavior;
- the regression test that proves it.

Check the repository's existing contracts before inventing a new one:
lib/ leaves do not import src/, TUI leaf widgets take view models rather than
App pointers, Job(T) families are polled and arm-last, session persistence
precedes cache updates, remote multi-statement writes are atomic batches, and
worktree paths use pathsEqual. Prefer an invariant that removes branches and
illegal states over a comment that merely asks callers to remember a rule.
