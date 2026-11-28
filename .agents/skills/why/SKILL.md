---
name: why
description: Use when the user asks why Zay works a certain way, or investigates design rationale, regressions, postmortems, or threshold choices via git history and docs (for current mechanics or placement, use how).
---

# Why

Investigate the motivation, constraints, and rejected alternatives behind current Zay code. Use `how` for mechanics; use `why` for history and rationale.

## Evidence order

Anchor the question in a concrete file, symbol, invariant, or behavior first, then gather evidence in order:

1. Project docs and inline comments — start at `AGENTS.md`, `docs/index.md`, `docs/patterns/README.md`, `docs/ARCHITECTURE.md`, and `docs/config/README.md`.
2. Git history:
   ```bash
   git log --follow --oneline -- <path>
   git log --follow -p -- <path>
   git blame -L <start>,<end> <path>
   git log -S"<symbol-or-text>" --all -- <path>
   git show <commit> --stat --oneline
   ```
3. Regression tests and fixtures encoding a motivating failure or compatibility rule.
4. Configured graph tools (`docs/CODE_INTELLIGENCE.md`) or connected sources placed in scope.

Use `gh` for PR context only when a commit or repo reference identifies a PR number. Cite only inspected sources, and list unavailable sources as explicit gaps.

## Codebase anchor

Record the inspection baseline before explaining intent:

- repository and worktree path;
- target paths and symbols;
- current branch and relevant commits;
- discovery method used (graph index status, or direct source reads and git history).

## Epistemic rules

- Separate direct repository evidence from inference.
- Cite every intent claim with a commit, doc section, test name, or comment.
- Use qualified phrasing (`appears to`, `suggests`, `likely`) for indirect links.
- Surface contradictions between older rationale and current code.
- Treat any active invariant as a live constraint even when its origin commit is missing.
- Label a behavior a performance optimization only when backed by measurements or a documented tradeoff.
- Treat a null search result as narrowing the record, never as proof no discussion existed.

## Output

Investigate directly from repository history and docs without spawning subagents by default. Include the sections that add value:

1. **Question and anchor** — target files, symbols, branch, commits.
2. **Direct evidence** — facts explicitly recorded in docs, comments, tests, or commits.
3. **Reasonable inferences** — evidence chain with confidence.
4. **Competing hypotheses** — only when evidence supports more than one explanation.
5. **Change constraints** — what to preserve, change, avoid, or watch if editing.
6. **Gaps and sources** — consulted sources and any unavailable optional sources.
