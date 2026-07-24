---
name: tci-test
description: Discover test files and find coverage gaps for hub functions. Execute when asked about test coverage or untested code.
---

# TCI Test Analysis

Discover test files via heuristic, identify hub functions, and check if those hubs have test coverage.

## BEFORE YOU START: Adapt to the target repo

This skill is **project-agnostic**. The command examples use placeholder symbols from the code-tandem repo (`get_or_create_project`, etc.). These likely do NOT exist in the target repo.

**Mandatory discovery step — run before any analysis:**

```bash
code-tandem init 2>&1
code-tandem stats 2>&1
code-tandem graph "main" --top 10 --format compact 2>&1
code-tandem search "build" 2>&1
code-tandem search "handle" 2>&1
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
code-tandem tests 2>&1
code-tandem graph "<hub>" --top 5 --format compact 2>&1
code-tandem callers "<hub>" --depth 1 2>&1
```

## Score each finding (base 100)

For each finding, present: **Symptom -> Source -> Consequence -> Remedy**

- **Critical** (-15): uncovered hub function with high risk
- **Warning** (-5): partial coverage, missing edge cases
- **Suggestion** (-1): minor test gap, cosmetic issue
