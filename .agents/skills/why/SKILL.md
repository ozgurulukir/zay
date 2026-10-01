---
name: why
description: Use for design rationale, regressions, postmortems, threshold choices, or questions about why Zay works a certain way. Combine git history, project docs, tests, and codebase evidence; label inference and gaps.
---

# Why

Investigate motivation, constraints, and rejected alternatives behind the current
code. Use how for mechanics. The code proves what the program does; history,
tests, comments, docs, and review records are the evidence for why it has that
shape.

## Evidence order

Anchor the question in a concrete file, symbol, invariant, or behavior first.
Then gather evidence in this order:

1. Current project docs and comments, especially docs/PATTERNS.md,
   docs/ARCHITECTURE.md, docs/CONFIG.md, and subsystem docs.
2. Git history: git log --follow, git blame, git show, and searches by symbol,
   error text, invariant name, or threshold.
3. Tests and fixtures that encode a motivating failure or compatibility rule.
4. Any repository-provided index or connected source explicitly placed in scope
   by the user or project instructions.

Do not pretend a missing connector was searched. Record unavailable sources as
gaps instead of inventing a narrative.

## Codebase anchor

Before explaining intent, record:

- the repository and worktree being inspected;
- the target paths and symbols;
- the current branch and relevant recent commits;
- any configured discovery/index status, or the fact that the investigation
  used direct source reads and repository history.

For structural anchoring, use the repository's configured navigation tools when
present. Otherwise use source search, direct reads, tests, and history. Check
the limits of the chosen discovery method before claiming that a symbol, caller,
or path is absent.

Useful git commands include:

  git log --follow --oneline -- path
  git log --follow -p -- path
  git blame -L start,end path
  git log -S"symbol-or-text" --all -- path
  git show COMMIT --stat --oneline

Use gh for a PR only when the commit or repository context actually identifies
one; do not fetch unrelated external discussions merely to fill a checklist.

## Epistemic rules

- State direct evidence separately from inference.
- Cite every intent claim with a commit, doc section, test name, comment, or
  connected-source link.
- Prefer appears to, suggests, or likely when the source is indirect.
- Surface contradictions between an old rationale and the current behavior.
- Treat a current invariant as a constraint even when its original motivation
  is unknown.
- Do not call a behavior a performance optimization without measurements or a
  documented tradeoff.
- A null search result narrows the record but does not prove that no discussion
  ever existed.

## Output

Adapt the output to the question, but keep these sections when they add value:

1. The question and code anchor.
2. Direct evidence: what the repository explicitly records.
3. Reasonable inferences: the evidence chain and confidence.
4. Competing hypotheses: only when the evidence supports more than one.
5. Preserve/change/avoid/risk constraints if the user is deciding whether to
   edit the code.
6. Gaps and sources consulted, including unavailable optional sources.

Keep the answer useful to a maintainer. Explain the tradeoff, not just the
timeline. Do not spawn investigators by default or require a particular
subagent workflow; the repository's own history and docs are the primary
evidence.
