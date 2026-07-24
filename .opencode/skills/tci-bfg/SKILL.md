---
name: tci-bfg
description: Big Fucking Gun — one skill to blast them all. Full-spectrum code-tandem analysis: stats, integration, hubs, cycles, tests, architecture, coupling, cognitive load, dependencies, coverage gaps, code quality, evo-loop status. Load when asked to analyze, audit, explore, or understand a codebase.
---

# TCI-BFG: Big Fucking Gun

> _"This is my BFG. There are many like it, but this one is mine."_
>
> One trigger pull — full-spectrum analysis. No more picking individual skills.
> Load this skill. Run the commands. Present the findings. Done.

Consolidates all sub-skills into one: `tci-analyze`, `tci-dependency`, `tci-coupling`, `tci-cognitive-load`, `tci-architecture`, `tci-test`. **Code quality (Phase 8) is embedded in this skill.**

**Critical: Adapt to target repo.** Symbols like `build_matrix`, `handle_events` are from code-tandem itself. Replace `<hub>`, `<symbol>`, `<component>` with values discovered from the target. First run `code-tandem search "build" --limit 5` to find real hub names, then use `graph "<hub>" --top 10`, `integration`, and `stats`.

**Noise identifiers** (same-name utilities to filter): `emit`, `save_output`, `epoch_info`, `parse_qualified`, `language_ext`, `make_key`, `to_json`, `clone`, `push`, `new`, `size`, `get`, `load`, `save`, `from`, `remove`, `clear`, `invalidate`, `peek`, `post`, `request`, `search`, `content`, `index`, `stats`, `symbol`, `symbols`.

**Auto-noise reflex:** After each `--apply-patterns`, immediately run `integration --learn` to check for remaining suspicious patterns. If same-name utility functions remain, extract and apply again.

**Output formats:** `--format json` for full detail, `--format compact` for summaries, `--format dot` for Graphviz. All commands auto-compress when piped — use `--compress never` (global flag, can be placed before or after subcommand) for raw JSON.

**`graph` flag order:** `--top N` must come AFTER the root symbol (e.g., `graph "hub" --top 5`). If `--top` appears before the symbol, it's parsed as a symbol name and fails with "Could not resolve '--top'".

**grep/rg with `->`:** Pattern starting with `-` triggers flag parsing. Use `grep -- '->'` or `rg -- '->'`. The `--` signals end-of-options. `rg` also needs `--` when pattern starts with `-` (e.g., `rg -- '->'`).

**code-tandem output işleme:** Compact format `name|kind|file|edges` — awk/grep ile pipe:

```bash
# awk -F'|' ile sütun bazlı analiz
# rg "pattern" ile satır filtreleme
# code-tandem query (JMESPath) ile JSON filtreleme
```

Detaylı örnekler Phase 8'de.

## Phase 0: Pre-flight

```bash
systemctl --user is-active code-tandem-server || systemctl --user start code-tandem-server
code-tandem health 2>&1
code-tandem init 2>&1
code-tandem stats 2>&1
```

Note `files`, `symbols`, `cache.hit_rate`. Low hit rate (<50%) = fresh index, results may be slower.

## Phase 1: Discover

```bash
code-tandem graph "handle_events" --top 10 --format compact 2>&1
code-tandem search "build" --limit 5 2>&1
code-tandem search "handle" --limit 5 2>&1
code-tandem search "process" --limit 5 2>&1
code-tandem strings "." --limit 5 2>&1
code-tandem imports "." --limit 5 2>&1
code-tandem annotations "." --limit 5 2>&1
code-tandem fields "." --limit 5 2>&1
code-tandem lint --limit 10 2>&1
code-tandem symbols 2>&1 | head -20
code-tandem ast "<file>" 2>&1
```

Pick top edge-count symbol as `<hub>` for subsequent phases.

## Phase 2: Overview (tci-analyze)

```bash
code-tandem integration 2>&1
code-tandem graph "<hub>" --top 5 --format compact 2>&1
code-tandem graph "<hub>" --topo 2>&1
code-tandem tests 2>&1
```

Check `generation: 0` → run evo-loop before continuing.

```text
STATS: <files> files, <symbols> symbols, <components> components, cache <hit_rate>
HUBS: <fn> (<N> edges, <kind>, <file>)
CYCLES: <root>: <cycles: bool>
TESTS: <N> files total
```

## Phase 3: Dependency (tci-dependency)

```bash
code-tandem graph "<hub>" --topo 2>&1
code-tandem graph "<hub>" --top 5 --format compact 2>&1
code-tandem integration --graph --compress never 2>&1
```

Cycle/scc analizi—DOT edges pipe ile:

```bash
# Bidirectional edge'leri bul (cycle indicator)
code-tandem integration --graph --format dot 2>&1 | grep -- '->' | sed 's/.*"\(.*\)" -> "\(.*\)" .*/\1\t\2/' | sort | awk -F'\t' '{if(seen[$2,$1]) print $1" ↔ "$2; seen[$1,$2]=1}'
# SCC listesi (JSON analysis.sccs)
code-tandem integration --graph --compress never 2>&1 | code-tandem query 'analysis.sccs[?length(@) > `1`]' --stdin
```

Base 100. **-15**: cycles or SCC in component graph. **-5**: DIP violations. **-1**: minor.

## Phase 4: Coupling (tci-coupling)

```bash
code-tandem graph "<hub>" --top 5 --format compact 2>&1
code-tandem callers "<hub>" --depth 1 2>&1
```

Base 100. **-15**: change touches >5 files. **-5**: 3-5 files. **-1**: minor.
Note: cross-language (CLI↔server via HTTP) callers are invisible — 0 nodes is expected.

## Phase 5: Cognitive Load (tci-cognitive-load)

```bash
code-tandem graph "<hub>" --top 5 --format compact --exhaustive 2>&1
code-tandem pseudocode "<hub>" 2>&1
code-tandem pseudocode "<hub2>" 2>&1
```

Base 100. **-15**: function >50 lines, chain >5 levels, or pseudocode `transform_ratio < 0.5`. **-5**: 20-50 lines, nesting 4-5. **-1**: minor.

## Phase 6: Architecture (tci-architecture)

```bash
code-tandem integration 2>&1
code-tandem integration --learn 2>&1
code-tandem integration --graph --format dot 2>&1
```

Base 100. **-15**: domain depends on infrastructure, conceptual inconsistency. **-5**: mild violations. **-1**: single crossing.

## Phase 7: Test Coverage (tci-test)

```bash
code-tandem tests 2>&1
code-tandem callers "<hub>" --depth 1 2>&1
code-tandem search "test" --limit 10 2>&1
```

Base 100. **-15**: uncovered hub with high risk. **-5**: partial coverage. **-1**: minor gap.
`search "test"` catches `#[cfg(test)]` inline modules missed by `tests`.

## Phase 8: Code Quality (tci-code-quality)

```bash
# Largest files (split candidates)
find . -name "*.rs" -not -path "*/target/*" -exec wc -l {} \; 2>/dev/null | sort -rn | head -5
find . -name "*.cr" -not -path "*/lib/*" -exec wc -l {} \; 2>/dev/null | sort -rn | head -5

# Unwrap density — via lint engine
code-tandem lint --kind unwrap_call --severity warning --limit 5 2>&1

# Long functions — fn başlangıç satırlarını bul
rg -n '^\s{0,4}(pub\s+|fn |def |async fn )' --type rust -g '!target/' server/src/ 2>/dev/null | head -20
```

**code-tandem çıktılarını pipe ile analiz etme:**

```bash
# Edge count toplama (compact format: name|kind|file|edges)
code-tandem graph "handle_events" --top 10 --format compact 2>&1 | rg '^\w' | awk -F'|' '{s+=$4} END{print s " total edges"}'

# Lint warning summary
code-tandem lint --severity warning --limit 99999 2>&1 | code-tandem query 'total' --stdin
code-tandem lint --kind unwrap_call --limit 99999 2>&1 | code-tandem query 'total' --stdin

# Test coverage gap — inline test modülü olmayan hub'lar
code-tandem search "test" --limit 100 2>&1 | rg "module\|function" | awk '{print $3}' > /tmp/tested.txt
code-tandem graph "handle_events" --top 20 --format compact 2>&1 | rg '^\w' | awk -F'|' '{print $1}' | grep -v -f /tmp/tested.txt | head -5

# Bir fonksiyonun body satır sayısı (pseudocode quality.lines_total kullan)
code-tandem pseudocode "<symbol>" 2>&1 | code-tandem query 'quality.lines_total' --stdin

# Unwrap yoğun dosyalar (per-file sıralı, lint engine ile)
code-tandem lint --kind unwrap_call --file server/src/index/watcher.rs 2>&1 | code-tandem query 'total' --stdin

# Lint warning per-kind breakdown (JMESPath + --raw for line-per-value)
code-tandem lint --limit 99999 --compress never 2>&1 | code-tandem query 'results[].lint_kind' --stdin --raw | sort | uniq -c | sort -rn

# JMESPath ile JSON filtreleme (query command)
code-tandem integration --graph --compress never 2>&1 | code-tandem query 'edges[?ref_count > `10`]' --stdin
code-tandem integration --compress never 2>&1 | code-tandem query "metrics.above_threshold" --stdin
```

Base 100. **-15**: file >500 lines, >20 unwrap calls in production, silent IO drops. **-5**: 300-500 lines, 10-20 unwraps. **-1**: 200-300 lines.

## Phase 9: Evo-Loop Verification

Check generation (integration output shows `generation: N`):

```bash
code-tandem integration 2>&1 | rg "generation"
```

If gen 0 or generation hasn't changed after apply-patterns, run evo-loop iterations.
After each `--apply-patterns`, verify convergence:

```bash
code-tandem integration --apply-patterns '<json>' --compress never 2>&1 | rg "converged"
```

`converged: true` means matrix is stable.

**Iteration 1** — component boundaries + noise:

```bash
code-tandem integration --apply-patterns --compress never '{
  "component_suggestions": [{"pattern": "server/", "name": "server", "language": "rust", "confidence": 0.95}, ...],
  "noise_identifiers": ["<extracted>"],
  "cluster_depth": 1
}' 2>&1 | rg "converged|patterns_applied"
code-tandem integration 2>&1
```

**Iteration 2** — pattern-based scoring:

```bash
code-tandem integration --learn 2>&1
code-tandem integration --apply-patterns --compress never '{"noise_identifiers": ["<remaining>"], "patterns": [...]}' 2>&1 | rg "converged|patterns_applied"
code-tandem integration 2>&1
```

Repeat until `converged=true` or diminishing returns.

## BFG Scorecard

| Phase          | Base    | Deductions | Score |
| -------------- | ------- | ---------- | ----- |
| Dependency     | 100     |            |       |
| Coupling       | 100     |            |       |
| Cognitive Load | 100     |            |       |
| Architecture   | 100     |            |       |
| Test Coverage  | 100     |            |       |
| Code Quality   | 100     |            |       |
| **Overall**    | **avg** |            |       |

Persist for trend tracking:

```bash
code-tandem note add "BFG: <N>/100 [dep=<D>, coup=<C>, cog=<C>, arch=<A>, test=<T>, qual=<Q>]" --tag bfg
```

## Output Format

**Symptom → Source → Consequence → Remedy** for all findings.

**Component graph** — `integration --graph` uses petgraph for SCC/cycle detection, toposort. `--format dot` for Graphviz.
**Manifest cascade** — `component_rules` > `manifest_cache` > `cluster_depth`. Check: `cat .code-tandem/config.json | jq '.manifest_cache'`.
**ignore_patterns** — filter files during indexing: `--apply-patterns '{"ignore_patterns": ["__snapshots__"]}'`.

## Known Limitations

- **Cross-language HTTP boundary**: CLI↔server calls invisible to static analysis. `callers` returning 0 for server hubs is expected.
- **Inline tests**: `#[cfg(test)]` modules in `server/src/` not detected by `tests`. Use `rg "cfg\\(test\\)"`.
- **`flow` unreachable**: Seeds `max_nodes: 50` + `file:` restriction. Cross-language and framework dispatch (axum handlers) always unreachable.
- **`graph "main"` 0 nodes**: Symbols like `main` are entry points with no callees (normal). Pick a real hub from `search` output.
- **Experimental commands**: `strings`, `imports`, `annotations`, `fields`, `docs`, `unused-imports`, `lint` are approximate/heuristic. FP matrix in `README.md` under "Experimental Feature Limitations". `symbols` is exact (server-side `all_symbols()`).
- **Lint engine**: 8 language lint rules (Rust unwrap, Crystal bare rescue, Python bare except, Go \_ :=, TS/JS bare catch, Java broad catch, Scala bare catch, C/C++ void cast). Some warnings in test code — use `lint --severity warning` to filter production code.
- **`--limit 0` returns 0 results**: `0` is NOT a sentinel for "unlimited". Server default is 100 when no limit is passed. Use `--limit 99999` for effectively unbounded results.
- **Piped output compression**: Commands piped (non-TTY) auto-compress. `format_integration` in `compress.cr` handles both matrix (`components,matrix,refs,metrics`) and graph (`nodes,edges,analysis`) keys. Use `--compress never` for raw JSON.
- **`grep` with `->`**: Pattern `->` starts with `-`, interpreted as flag. Use `grep -- '->'` or `rg -- '->'`.
- **`rg --type rust`**: Only available when `rg` is installed. Falls back to `grep -r --include='*.rs'` otherwise.
