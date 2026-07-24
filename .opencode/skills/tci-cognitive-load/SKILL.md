---
name: tci-cognitive-load
description: Find cognitively complex functions — deep call chains, high fan-out, long functions. Execute when asked about code complexity or maintainability.
---

# TCI Cognitive Load Analysis

Identify functions that are hard to understand or maintain by analyzing call depth, edge count, and exhaustive callee resolution.

## BEFORE YOU START: Adapt to the target repo

This skill is **project-agnostic**. The command examples use placeholder symbols from the code-tandem repo (`build_graph`, etc.). These likely do NOT exist in the target repo.

**Mandatory discovery step — run before any analysis:**

```bash
code-tandem init 2>&1
code-tandem stats 2>&1
code-tandem graph "main" --top 10 --format compact 2>&1
code-tandem search "build" 2>&1
code-tandem search "handle" 2>&1
code-tandem search "process" 2>&1
```

From the output:
- Pick the symbol with the **highest edge count** as your `<hub>`.
- Use real component names from `integration` output, not `cli`/`server`/`other`.
- Replace ALL placeholder symbol names in the workflow below.

**If `integration` returns `generation: 0`** (no config exists), run at least 2 evo-loop iterations first:

```
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
code-tandem graph "<hub>" --top 5 --format compact --exhaustive 2>&1
```

## Score each finding (base 100)

For each finding, present: **Symptom -> Source -> Consequence -> Remedy**

- **Critical** (-15): function >50 lines or deep call chain >5 levels
- **Warning** (-5): function 20-50 lines, nesting 4-5
- **Suggestion** (-1): minor naming issues, single magic number
