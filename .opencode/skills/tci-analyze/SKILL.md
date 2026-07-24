---
name: tci-analyze
description: Run full project self-analysis. Execute when asked to analyze, understand, or explore a codebase. Produces stats, integration matrix, hub functions, cycles, and test coverage overview.
---

# TCI Project Analysis

Produce a full project overview: symbol counts, component boundaries, hub functions, cycles, test coverage, and component dependency graph.

## BEFORE YOU START: Adapt to the target repo

This skill is **project-agnostic**. The command examples use placeholder symbols from the code-tandem repo (`get_or_create_project`, `build_graph`, `main`). These likely do NOT exist in the target repo.

**Mandatory discovery step — run before any analysis:**

```bash
code-tandem init 2>&1
code-tandem stats 2>&1
code-tandem graph "main" --top 10 --format compact 2>&1
code-tandem search "build" 2>&1
code-tandem search "handle" 2>&1
code-tandem search "process" 2>&1
code-tandem integration --graph --compress never 2>&1
code-tandem strings "." --limit 5 2>&1
code-tandem imports "." --limit 5 2>&1
code-tandem annotations "." --limit 5 2>&1
code-tandem lint --limit 5 2>&1
code-tandem symbols 2>&1 | head -20
```

From the output:

- Pick the symbol with the **highest edge count** as your `<hub>`.
- Use real component names from `integration` output, not `cli`/`server`/`other`.
- Replace ALL placeholder symbol names in the workflow below.

**If `integration` returns `generation: 0`** (no config exists), run at least 2 evo-loop iterations first:

```
1. code-tandem integration --learn 2>&1
2. Extract noise_identifiers from suspicious_patterns
3. Check detected manifests (`cat .code-tandem/config.json | jq '.manifest_cache'`), define component_rules from directory structure if manifests insufficient
4. code-tandem integration --apply-patterns '{"component_suggestions":[...],"noise_identifiers":[...],"cluster_depth":1}'
5. code-tandem integration --learn 2>&1
6. Extract remaining noise, apply again
7. code-tandem integration --apply-patterns '{"noise_identifiers":[...]}'
8. code-tandem integration 2>&1  # verify
```

## Workflow

```bash
code-tandem stats 2>&1
code-tandem integration 2>&1
code-tandem graph "<hub>" --top 5 --format compact 2>&1
code-tandem graph "<hub>" --topo 2>&1
code-tandem tests 2>&1
```

## Present results in this structure

```
PROJECT SELF-ANALYSIS
<files> files, <symbols> symbols, <components> components

STATS:
  Files: <N>, Symbols: <N>, Cache: <hit_rate>

COMPONENTS + CROSS-REFS:
  <comp> -> <dest>: <N> refs (scored)

TOP 5 HUBS:
  <fn>  <N> edges  <kind>  <file>

CYCLES:
  <root>: <cycles: bool>

TESTS:
  <comp>: <N> files, <N> tests
  Total: <N> test files
```
