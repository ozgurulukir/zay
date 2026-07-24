# Tandem Code Intelligence — Usage instructions

> Tree-sitter-backed structural code analysis. Call graphs, dependency analysis, flow tracing, test discovery — from the terminal.

**CRITICAL: Use `code-tandem` for ALL source code analysis because `code-tandem` gives byte-exact, AST-aware answers in a single command..** Unless for text only jobs (markdown, config, JSON, YAML) or when `code-tandem` returns insufficient results. Try to find entrance points with semantic_search tool.

```text
Agent → code-tandem (Crystal CLI) → code-tandem-server (Rust, port 3000)
```

## Quick Start

```bash
code-tandem init                  # Create/index project (auto-waits for index)
code-tandem stats                 # Symbol count, file count
code-tandem integration           # Component matrix
code-tandem integration --graph   # Component dependency graph
code-tandem search "symbol"       # Find symbols [--component name] [--language lang] [--kind kind] [--file path] [--limit N]
code-tandem graph "handle_events" --top 5  # Hub functions (entry points may show 0 edges — use a hub from search)
code-tandem flow "A" --to "B"     # Trace execution path
code-tandem tests                 # Test discovery
code-tandem strings "error"       # String literal search
code-tandem strings "SELECT" --type template --file app.ts  # Template literals only
code-tandem annotations "derive"  # Find annotation/decorator usage
code-tandem unused-imports        # Find unused imports in project
code-tandem lint                  # Find code quality warnings [--severity warning|info] [--kind unwrap_call|bare_rescue|not_nil_call|silent_drop|bare_catch|broad_catch|empty_catch|void_cast_suppression] [--limit N] (NOTE: --limit 0 = 0 results, not "unlimited")
code-tandem symbols               # List all symbols with file location [--kind kind] [--file path]
code-tandem ast <file>             # Get S-Expression AST representation
code-tandem export-docs           # Generate Markdown documentation [--format markdown] [--output file]
code-tandem export-component-docs # Generate per-component READMEs [--output-dir DIR]
code-tandem test-coverage         # Analyze test coverage [--limit N] [--component name]
```

**First run (gen 0) — define component boundaries:**

```bash
code-tandem integration --learn --verbose
code-tandem integration --apply-patterns '{
  "patterns": [],
  "component_suggestions": [
    {"pattern": "server/", "name": "server", "language": "rust", "confidence": 0.95},
    {"pattern": "cli/src/", "name": "cli", "language": "crystal", "confidence": 0.95},
    {"pattern": "cli/spec/", "name": "other", "language": "crystal", "confidence": 0.9}
  ],
  "noise_identifiers": ["search", "get", "size", "emit", "save_output", "epoch_info", "parse_qualified", "language_ext", "make_key", "to_json", "clone", "push", "new", "load", "save", "from", "remove", "clear", "invalidate", "peek", "post", "request", "content", "index", "stats", "symbol", "symbols"],
  "cluster_depth": 1
}'
code-tandem integration  # verify
```

No `code-tandem config` command exists. Config is at `.code-tandem/config.json`, created only via `--apply-patterns`.

**Symbol names are project-specific.** Discover your project's structure: `code-tandem stats`, `graph "handle_events" --top 5`, `search "build"`. Symbols like `handle_events`, `build_graph` are from this repo and may not exist in yours.

## Command Quick Reference

| Command                 | Purpose                     | Key flags                                                                                                                                                                  |
| ----------------------- | --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `init`                  | Project init & indexing     | `-f` force re-index                                                                                                                                                        |
| `search`                | Find symbols                | `--limit N`, supports `\|`/`,` multi-query                                                                                                                                 |
| `impl`                  | Function body source        | `--file` disambiguate                                                                                                                                                      |
| `callers`               | Reverse call graph          | `--depth N`, `--component`, `--format dot`                                                                                                                                 |
| `graph`                 | Directed call graph         | `--top N`, `--topo`, `--shortest`, `--exhaustive`, `--component`, `--format dot`                                                                                           |
| `flow`                  | Trace execution path        | `--to`, `--from-file`/`--to-file`, `--exhaustive`, `--format inline`                                                                                                       |
| `integration`           | Component matrix            | `--learn`, `--apply-patterns`, `--raw`, `--graph [--format json\|dot]`                                                                                                     |
| `tests`                 | Test discovery              | `--limit N`                                                                                                                                                                |
| `strings`               | String literal search       | `--exact`, `--file`, `--limit`, `--type string\|template`                                                                                                                  |
| `pseudocode`            | LLM-ready summary           | takes symbol name, returns `quality` metadata                                                                                                                              |
| `peek`                  | View source lines           | `--symbol`, `--expand`, `--outline`, `--blame`, `--format raw`                                                                                                             |
| `query`                 | JMESPath filtering          | `<expr> --json 'inline'`, `--file path`, pipe stdin (implicit), `--raw`                                                                                                    |
| `output`                | Cache management            | `list`, `read`, `delete`, `clean`                                                                                                                                          |
| `note`                  | Agent scratchpad            | `add`, `list`, `read`, `edit`, `delete`, `clean`                                                                                                                           |
| `imports`               | Import reference search     | `--file`, `--limit`                                                                                                                                                        |
| `fields`                | Struct/class field search   | `--file`, `--limit`                                                                                                                                                        |
| `docs`                  | Doc comment search          | `--symbol`, `--query`, `--file`                                                                                                                                            |
| `annotations`           | Annotation/decorator search | `--file`, `--limit`                                                                                                                                                        |
| `unused-imports`        | Find unused imports         | `--file`, `--limit` (returns `kind: "unused"`/`"indirect"`)                                                                                                                |
| `lint`                  | Code quality warnings       | `--file`, `--limit`, `--severity warning\|info`, `--kind unwrap_call\|bare_rescue\|not_nil_call\|silent_drop\|bare_catch\|broad_catch\|empty_catch\|void_cast_suppression` |
| `symbols`               | List all symbols            | `--kind kind`, `--file path`, `--limit N` (auto-paginates)                                                                                                                 |
| `ast`                   | Get S-Expression AST        | —                                                                                                                                                                          |
| `export-docs`           | Generate Markdown docs      | `--format markdown`, `--output file`                                                                                                                                       |
| `export-component-docs` | Per-component READMEs       | `--output-dir DIR`                                                                                                                                                         |
| `test-coverage`         | Test coverage report        | `--limit N`, `--component name`                                                                                                                                            |
| `health`                | Server status               | —                                                                                                                                                                          |
| `help`                  | Show usage                  | —                                                                                                                                                                          |

Full command details: [cli-reference.md](docs/cli-reference.md)

## Analysis Workflows

**Recommended sequence:**

```text
1. Stats + integration          → 10,000-foot view
2. Graph + flow                 → trace specific paths
3. Impl + callers               → byte-exact code
4. Tests + search               → find gaps
5. Init --force + re-query      → verify changes
```

**When to use which:**

| Question                                  | Command                                        |
| ----------------------------------------- | ---------------------------------------------- |
| "What's in this codebase?"                | `stats` + `integration`                        |
| "List every symbol in the project"        | `symbols` (or `symbols --kind function`)       |
| "Where do I start?"                       | `graph "handle_events" --top 5`                |
| "How does A reach Z?"                     | `flow "A" --to "Z"`                            |
| "Is there a cycle?"                       | `graph "X" --topo`                             |
| "Show me the code"                        | `impl "func"` + `peek --file path --line N`    |
| "What's untested?"                        | `tests` + `search` for gaps                    |
| "Where is this string?"                   | `strings "pattern" [--type template]`          |
| "What annotations does this file use?"    | `annotations "derive" --file path`             |
| "Are there unused imports?"               | `unused-imports --file path`                   |
| "Are there unwrap() calls in production?" | `lint --kind unwrap_call --severity warning`   |
| "Did my fix break anything?"              | `init --force` + `impl`/`integration`/`tests`  |
| "Generate project documentation"          | `export-docs [--output file]`                  |
| "Generate component READMEs"              | `export-component-docs [--output-dir DIR]`     |
| "Set up CI analysis"                      | `.github/workflows/ci-analysis.yml`            |
| "Analyze test coverage"                   | `test-coverage [--limit N] [--component name]` |

## Code Navigation Hierarchy

| Priority | Tool                                                                                                  | When                                                                           |
| -------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| 1st      | `integration` / `stats`                                                                               | Broad view: component matrix, counts                                           |
| 2nd      | `callers` / `flow` / `graph`                                                                          | Call chains, paths, dependency structure                                       |
| 3rd      | `search` / `impl` / `peek` / `symbols`                                                                | Symbol discovery, function bodies, source, full symbol dump                    |
| 4th      | `tests` / `test-coverage` / `strings` / `imports` / `fields` / `docs` / `annotations` / `export-docs` | Test coverage, string/import/field/doc/annotation search, documentation export |
| 5th      | `unused-imports` / `lint`                                                                             | Dependency health — find imports with no file usage, code quality warnings     |
| Last     | `rg` / `grep` / `find`                                                                                | Comments, non-code files                                                       |

## Evo-Loop (Pattern Engine)

Iterative agent-driven loop for reducing false cross-refs: learn → classify → apply → verify. Repeat until `converged=true`.

**On gen 0:** Run at least 2 iterations. Set `component_suggestions` via `--apply-patterns` before using `--component`. Apply `noise_identifiers` for same-name utility functions. After each `--apply-patterns`, run `--learn` to check for remaining noise.

Full details: [evo-loop.md](docs/evo-loop.md)

## Server

```bash
# Stateless — no sessions, no recovery needed
code-tandem init                    # Create/index project (idempotent)
code-tandem init -f                 # Force re-index
rm ~/.code-tandem/project.json      # Clear cached project root

Server: `127.0.0.1:3000`. Project root: `~/.code-tandem/project.json`.
Max 10 projects (LRU eviction, idle > 30 min auto-evicted).
```

## Architecture Rules

- **Evo-loop** primarily affects `integration` matrix scoring. But `noise_identifiers` and `component_rules` also affect `graph`/`flow`/`callers` (callee resolution + component scoping).
- **Bidirectional evo-loop pruning:** `remove_noise_identifiers`, `remove_patterns`, and `remove_component_rules` fields remove entries before additions. Use to shrink bloated lists without replacing the entire array.
- **`ref_key`** format: `symbol_name@dest_file` (NOT `symbol -> source -> dest`).
- **`--apply-patterns`** accepts inline JSON, stdin (`--stdin`), or file path. Updates memory atomically.
- **Cache invalidation:** epoch-based (poll every 30s) + tag-based delta for ≤50 files, full flush for >50.
- **Component filter:** `--component <name>` scopes to that component tree. Requires `component_rules`. `flow` has no `--component` — use `--from-file`/`--to-file` instead.
- **Keyword filtering:** `find_callees` filters language keywords via exact-match. 12 languages supported. Functions containing keyword substrings (e.g., `perform_match`) are NOT filtered.
- **Lexical Scope Reference Filtering**: Call expressions are checked against local variables defined in enclosing lexical scopes (`variables_query`). References resolving to local variables are filtered out of tree-sitter callee resolution.
- **Dynamic Language Queries (.tsq Rules)**: Parser queries can be overridden dynamically by creating `.code-tandem/queries/<lang>.tsq` at the project root with section headers like `[symbols]`, `[callers]`, `[id_refs]`, `[variables]`, etc. Loaded configurations are cached thread-safely in `TSQ_CACHE` and hot-reloaded automatically via file modification timestamp (`mtime`) checks.
- **AST S-Expression**: S-Expression representations of files parsed by tree-sitter are exposed via the `/project/ast` endpoint and CLI `ast` command.

## Config

All config via `integration --apply-patterns`. No `config` command exists.

| Config Key                | Default | Controls                                               |
| ------------------------- | ------- | ------------------------------------------------------ |
| `min_confidence`          | 0.5     | Minimum score for above-threshold refs                 |
| `cluster_depth`           | 1       | Directory depth for auto-clustering                    |
| `sample_limit`            | 50      | Max symbols per component in matrix                    |
| `component_rules`         | []      | Explicit component patterns                            |
| `noise_identifiers`       | []      | Filtered from id_refs                                  |
| `ignore_patterns`         | []      | Substring patterns for file filtering during indexing  |
| `manifest_cache`          | {}      | Auto-detected component boundaries from manifest files |
| `patterns`                | []      | Pattern list for scoring refs                          |
| `whitelist` / `blacklist` | []      | Per-ref overrides                                      |

Full config reference: [config-tuning.md](docs/config-tuning.md)

## Supported Languages

Rust, Python, TypeScript, JavaScript, Go, Java, Scala, Vue, Crystal, C, C++, Zig.

## Component Graph

Component-level dependency graph using `petgraph`. Shows how components connect via cross-component references.

```bash
code-tandem integration --graph                    # JSON: nodes, edges, analysis (SCC, cycles)
code-tandem integration --graph --format dot        # DOT/Graphviz output
code-tandem integration --graph --format dot | dot -Tpng > graph.png
```

**Graph analysis (petgraph::algo):**

- SCC (Tarjan): strongly connected components → cycle detection
- Toposort: topological ordering (acyclic graphs only)

**ignore_patterns** — parametric file filtering during indexing:

```bash
code-tandem integration --apply-patterns '{"ignore_patterns": ["__snapshots__", ".snap"]}'
```

**manifest_cache** — automatic component detection from manifest files:

```bash
# Check detected manifests
cat .code-tandem/config.json | jq '.manifest_cache'
```

**Manifest-based component detection** (cascade priority):

1. `component_rules` — manual override (highest)
2. `manifest_cache` — automatic from `package.json`, `Cargo.toml`, `go.mod`, etc.
3. `cluster_depth` — directory-based fallback (lowest)

```bash
# Override manifest component
code-tandem integration --apply-patterns '{"component_suggestions": [{"pattern": "packages/reactivity/", "name": "reactivity", "language": "typescript", "confidence": 0.95}]}'
```

## External References

Load these on-demand when the task requires deep knowledge:

- [cli-reference.md](docs/cli-reference.md) — Full command details, flags, examples, output compression
- [evo-loop.md](docs/evo-loop.md) — Pattern engine deep dive, LearningReport format, experiment tracking
- [config-tuning.md](docs/config-tuning.md) — All config tables, pseudocode config, quality feedback loop
- [self-analysis.md](../../docs/self-analysis.md) — Full BFG self-analysis report (FP table, code quality, findings)
