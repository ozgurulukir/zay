---
name: tci-architecture
description: Detect architecture violations — cross-boundary leaks, domain-infrastructure coupling, missing abstractions. Execute when asked about module boundaries or layering.
---

# TCI Architecture Analysis

Detect architecture violations by analyzing the integration matrix and learning data: domain depending on infrastructure, cross-boundary leaks, and missing abstractions.

## BEFORE YOU START: Adapt to the target repo

This skill is **project-agnostic**. The command examples use placeholder symbols from the code-tandem repo. These likely do NOT exist in the target repo.

**Mandatory discovery step — run before any analysis:**

```bash
code-tandem init 2>&1
code-tandem stats 2>&1
code-tandem graph "main" --top 10 --format compact 2>&1
code-tandem search "build" 2>&1
```

From the output:

- Use real component names from `integration` output, not `cli`/`server`/`other`.
- Replace ALL placeholder names in the workflow below.

**If `integration` returns `generation: 0`** (no config exists), run at least 2 evo-loop iterations first:

```text
1. code-tandem integration --learn 2>&1
2. Extract noise_identifiers from suspicious_patterns
3. Define component_rules from directory structure
4. code-tandem integration --apply-patterns '{"component_suggestions":[...],"noise_identifiers":[...],"cluster_depth":1}'
5. code-tandem integration --learn 2>&1
6. Extract remaining noise, apply again
7. code-tandem integration --apply-patterns '{"noise_identifiers":[...]}'
8. code-tandem integration 2>&1  # verify
```

## Workflow

```bash
code-tandem integration 2>&1
code-tandem integration --learn 2>&1
code-tandem stats 2>&1
```

## Score each finding (base 100)

For each finding, present: **Symptom -> Source -> Consequence -> Remedy**

- **Critical** (-15): domain layer depends on infrastructure, conceptual inconsistency
- **Warning** (-5): mild SDP/DIP violations, mixed patterns
- **Suggestion** (-1): single boundary crossing or naming inconsistency
