# CLI Command Reference

Complete reference for all `code-tandem` CLI commands.

## `init` — Session & Indexing

```bash
code-tandem init                  # Current directory, auto-waits for index
code-tandem init /path/to/project # Specific path
code-tandem init -f               # Force re-index (--force, tear down existing session)
```

Creates a session, extracts symbols via tree-sitter, builds inverted index. Auto-waits until indexing completes. Idempotent — skips if session already valid.

## `search` — Find Symbols

```bash
code-tandem search "handle_events"           # Fuzzy search across all symbols
code-tandem search "AppState::new"           # Qualified name search
code-tandem search "cache" --limit 10        # Max 10 results
code-tandem search "RAGChain|ChatService"    # Pipe/comma-separated multi-query (auto-split)
code-tandem search "foo,bar,baz"             # Comma also works as separator
code-tandem search "main" --component server # Filter by component
code-tandem search "init" --language rust   # Filter by language
```

Searches function/class/method/variable names across all indexed files. Language-aware, fuzzy matching with ranking boost (exact matches > definitions > documented symbols).

**Multi-query support:** Pipe (`|`) and comma (`,`) characters trigger automatic query splitting. Each part is searched independently, results are deduplicated and merged.

**Filters:** `--component <name>` filters by component prefix. `--language <lang>` filters by language (rust, crystal, python, etc.). `--kind` and `--file` work as before.

**`--limit` guidance:** Default 20. For discovery (broad search), use 5-10. For exhaustive analysis (find all callers of a utility), use 50-100. High limits (>200) may timeout on large projects.

## `impl` — Function Body Source

```bash
code-tandem impl "handle_events"                                    # By name
code-tandem impl "handle_events" --file server/src/index/watcher.rs # Disambiguate
```

Returns exact source body. Use `--file` when same-name symbols exist in multiple files.

## `callers` — Who Calls This?

```bash
code-tandem callers "bump_epoch" --depth 2              # Recursive callers, 2 hops
code-tandem callers "init" --depth 3 --format json      # JSON output, auto-resolves file
code-tandem callers "init" --file cli/src/client.cr --format dot | dot -Tpng > g.png
code-tandem callers "search" --component cli --depth 2  # Component-aware callers
```

Multi-hop reverse call graph. Shows every function that calls the target, recursively. Supports `--component` for component-scoped analysis. `--depth 1` uses direct callers endpoint (faster); `--depth > 1` uses `build_graph` (full graph, richer metadata).

## `graph` — Directed Call Graph

```bash
code-tandem graph "handle_events" --top 5                          # Top 5 hub functions by edge count
code-tandem graph "handle_events" --topo                           # Topological sort + cycle detection
code-tandem graph "init" --top 5 --topo --format json     # Full report: hubs + cycles + sorted
code-tandem graph "find_callees" --shortest "handle_events"     # BFS shortest path between two symbols
code-tandem graph "find_callees" --file server/src/ops/symbol_ops/callee.rs --depth 3 --exhaustive
code-tandem graph "handle_events" --format dot | dot -Tpng > g.png # Graphviz visualization
code-tandem graph "search" --component cli --topo         # Component-aware
code-tandem graph "search" --component cli --shortest "raw_get"
```

Combines hub detection (`--top`), topological sort (`--topo`), shortest path (`--shortest`), and exhaustive callee scanning (`--exhaustive`). Output formats: `compact` (default), `json`, `dot`.

**`--shortest` vs `flow --to`:** `graph --shortest <target>` finds the path within the already-built call graph (bounded by `--depth`). `flow "A" --to "B"` performs a dedicated bidirectional BFS (more precise). Prefer `flow` for point-to-point path tracing.

**Component-aware (`--component`):** Scopes search to a specific component tree. Requires `component_rules` in config. Discovery order: `--component` → `--file` → global.

## `flow` — Trace Execution Path

```bash
code-tandem flow "handle_events" --to "reindex_symbols" --depth 10
code-tandem flow "reindex_symbols" --to "extract_symbols_from_file" --depth 5 --format inline  # Reaches if path exists
code-tandem flow "A" --to "B" --exhaustive
code-tandem flow "A" --to "B" --from-file src/a.rs --to-file src/b.rs
code-tandem flow "A" --to "B" --verbose
code-tandem flow "batch_resolve" --to "find_callees" --format inline   # Known reachable in server
```

Bidirectional BFS shortest path between two symbols. `--format inline` shows each node annotated with component. JSON output includes `path_components` and `nodes[].component`. Use `--exhaustive` for full-file callee detection. Use `--from-file`/`--to-file` to disambiguate same-name symbols.

**`--verbose`:** Show batch resolution warnings on STDERR (hidden by default). Applies to `flow`, `graph`, and `callers`.

## `integration` — Component Dependency Matrix

```bash
code-tandem integration                              # Scored component matrix
code-tandem integration --format json                # JSON output
code-tandem integration --raw                        # Raw refs with individual scores
code-tandem integration --learn                      # Generate learning data
code-tandem integration --learn --verbose            # Full cross-ref details
code-tandem integration --apply-patterns report.json # Apply LearningReport
code-tandem integration --apply-patterns --stdin     # Pipe JSON from stdin
code-tandem integration --graph                      # Component dependency graph (JSON)
code-tandem integration --graph --format dot          # DOT/Graphviz output
```

Cross-component dependency matrix. Built from `id_refs`, filtered through: stdlib filter → qualified symbol check → pattern scoring.

**`--graph`** — Component-level dependency graph using `petgraph`. Shows nodes (components with file/symbol counts, languages), edges (cross-component refs), and analysis (SCC, cycle detection, toposort). Use `--format dot` for Graphviz visualization.

**Graph caching:** Result is cached to `.code-tandem/graph.json`. Invalidated automatically when config or file system changes.

**`ignore_patterns`** — Parametric file filtering during indexing:

```bash
code-tandem integration --apply-patterns '{"ignore_patterns": ["__snapshots__", ".snap"]}'
```

**Manifest-based component detection:** `init` scans for `package.json`, `Cargo.toml`, `go.mod`, etc. and populates `manifest_cache` automatically. Cascade: `component_rules` > `manifest_cache` > `cluster_depth`.

```bash
# Check detected manifests
cat .code-tandem/config.json | jq '.manifest_cache'
```

**IMPORTANT:** `--apply-patterns` returns `{"status":"applied",...}`, NOT the matrix. Run `code-tandem integration` separately AFTER applying. `"patterns":[]` is valid.

## `tests` — Test Discovery

```bash
code-tandem tests                           # All test files and functions by component
code-tandem tests --component cli           # Scoped to a specific component
```

Heuristic test file detection. Discovers test files, test functions, groups by component. Requires `component_rules` for `--component`.

## `strings` — String Literal Search

```bash
code-tandem strings "error"                          # All occurrences of "error"
code-tandem strings "File not found" --exact          # Exact match
code-tandem strings "timeout" --file server/src/main.rs  # Specific file
code-tandem strings "debug" --limit 10                # Limit results
code-tandem strings "SELECT" --type template --file app.ts  # Template literals matching "SELECT"
```

AST-aware string literal search. Only matches actual string literals (not identifiers, comments, or code). Returns file, line, enclosing function, language, string_type.

**Use cases:** error messages (`strings "not found"`), API endpoints (`strings "/api/v1/"`), hardcoded values (`strings "localhost"`), template SQL/GraphQL (`strings "SELECT" --type template`).

**`--limit`:** Default 50. Discovery: 10-20. Exhaustive: 100-200.

**`--type`:** Filter by string type. `string` = regular literals (default). `template` = JS/TS template literals only. `${expr}` → `{expr}` placeholder.

## `imports` — Import Reference Search

```bash
code-tandem imports "HashMap"                        # Where is this symbol imported?
code-tandem imports "react" --file app.tsx            # Imports from "react"
code-tandem imports "serde" --limit 20                # All serde imports
```

Search import references across the codebase. Returns file, line, import source text, import kind (use/import/require/etc).

## `fields` — Struct/Class Field Search

```bash
code-tandem fields "name"                            # Find all fields named "name"
code-tandem fields "User" --file models.rs            # Fields in User struct
code-tandem fields "id" --limit 10                    # First 10 "id" fields
```

AST-based struct/class field extraction. Returns field name, type annotation, parent struct, file, line. Macro-generated fields are invisible (only literal AST).

## `docs` — Doc Comment Search

```bash
code-tandem docs --symbol "handle_events"             # Doc comment for this symbol
code-tandem docs --query "cache"                      # Full-text search in docs
code-tandem docs --query "deprecated" --file lib.rs   # Scoped search
```

Search doc comments by symbol name or full-text substring (case-insensitive). Returns symbol, file, line, kind, doc content.

## `annotations` — Annotation/Decorator Search

```bash
code-tandem annotations "derive"                      # Find all #[derive] usage
code-tandem annotations "Override" --file UserService.java  # Find @Override
code-tandem annotations "test" --limit 20             # Find test annotations
```

AST-aware annotation/decorator/attribute search. Supports: Rust `#[derive]`, Python `@decorator`, Java `@Annotation`, TypeScript `@Decorator`, Crystal `@[Foo]`, Scala `@annotation`, C++ `[[attr]]`. Returns name, file, line, target_symbol, kind.

**Note:** `find_target_symbol` uses a ±3 line heuristic — may misalign on complex expressions.

## `lint` — Code Quality Warnings

```bash
code-tandem lint                                    # All warnings (production + test)
code-tandem lint --severity warning                 # Production code only (test warnings hidden)
code-tandem lint --severity info                    # All warnings including test code
code-tandem lint --kind unwrap_call --limit 50      # Filter by lint kind
code-tandem lint --file server/src/main.rs          # Warnings in specific file
```

Cross-language code quality warnings using tree-sitter queries + TLR rules. Detects: Rust `unwrap()`/`expect()`, Crystal `bare_rescue`/`not_nil!`, Python `bare_except`, Go silent error drops, TS/JS `bare_catch`, Java/Scala broad/empty catches, C/C++ void cast suppression.

**Severity filtering:**

- `--severity warning` (or no severity): shows all warnings
- `--severity warning`: shows only production-code warnings (test files filtered out)
- `--severity info`: shows all warnings including test code

**Test-file filtering:** Uses language-aware heuristics (`default_test_file_match`) to identify test files (e.g., `_spec.cr`, `/tests/`, `.test.ts`, `_test.go`). Test-code warnings are hidden by default when filtering by `--severity warning` to reduce noise.

## `unused-imports` — Unused Import Detection

```bash
code-tandem unused-imports                            # All files, top 100
code-tandem unused-imports --file server/src/main.rs   # Single file
code-tandem unused-imports --limit 500                 # Higher limit
```

Find import statements whose symbols don't appear in the file's source, symbols, or id_refs. Uses 3-layer check: symbol index → id_refs → file source text scan.

**`kind` field:**

- `"unused"` — high confidence. Name not found anywhere in file, parent path not found.
- `"indirect"` — medium confidence. Name not found but parent namespace/package IS found in source. Likely a trait/interface import needed for method resolution (e.g., Rust `use tree_sitter::StreamingIterator` where `tree_sitter` appears in code but `StreamingIterator` never does).

## `pseudocode` — LLM-Ready Summary

```bash
code-tandem pseudocode "handle_events"
code-tandem pseudocode "handle_events" --file server/src/index/watcher.rs
```

Structured summary: pseudocode (control-flow normalized), implementation body, local variables, callers, related test files.

**Output includes `quality` metadata:**

- `source`: `"ast_outline"` (server tree-sitter) or `"fallback"` (CLI regex)
- `transform_ratio`: fraction of lines transformed to pseudocode
- `coverage`: fraction of lines matched by any rule
- `untransformed_lines`: lines no rule matched — useful for improving patterns

**`impl` vs `pseudocode`:** `impl` = raw source. `pseudocode` = structured summary with control-flow normalization. Use `impl` for exact syntax; `pseudocode` for quick understanding.

## `export-docs` — Generate Markdown Documentation

```bash
code-tandem export-docs                            # Print Markdown to stdout
code-tandem export-docs --output API.md            # Write to file
```

Generates project documentation from indexed symbols and the integration matrix. Paginated symbol fetch (500 per page, 50k ceiling). Gracefully degrades to symbols-only when integration matrix is unavailable.

**Output sections:**

1. **Header** — project name, symbol count, file count, language list
2. **Components** — component names from integration matrix (if available)
3. **Component Dependencies** — cross-component refs sorted by count descending
4. **API Reference** — symbols grouped by kind (Functions, Structs, Traits, etc.), sorted by file+line

**Use cases:** project onboarding docs, API reference generation, component overview for READMEs, architecture documentation.

## `export-component-docs` — Generate Per-Component READMEs

```bash
code-tandem export-component-docs                            # Write to .code-tandem/component-docs/
code-tandem export-component-docs --output-dir ./docs        # Custom directory
```

Generates one `README.md` per component from the integration graph, matrix, and symbol index. Each README includes: component stats (files, symbols, languages), cross-component dependencies, and key symbols grouped by kind.

**Output sections per component:**

1. **Header** — component name, file count, symbol count, languages
2. **Dependencies** — cross-component refs sorted by count descending
3. **Key Symbols** — grouped by kind (Functions, Structs, Traits, etc.), sorted by file+line

**Symbol grouping:** Symbols are assigned to components using file path prefix matching against component names (e.g., `cli/` → `cli` component). Unmatched symbols go to `other.md`.

**Use cases:** component onboarding docs, architecture overview for each module, automated README generation for microservices.

## `test-coverage` — Analyze Test Coverage

```bash
code-tandem test-coverage                            # All components
code-tandem test-coverage --component cli            # Single component
code-tandem test-coverage --limit 200                # Limit symbol scan
```

Analyzes which production files have tests and which don't. Reuses existing test discovery heuristics + `references()` API.

**Output sections:**

1. **Overall** — total production files, covered count, uncovered count, coverage %
2. **Per-component** — file counts, coverage %, list of uncovered files (up to 20)

**Methodology:** For each test symbol, `references()` finds production files it touches. Inverted map shows which production files lack test coverage.

**Use cases:** Identify coverage gaps before release, prioritize testing effort, component health assessment.

## `peek` — View Source Lines

```bash
code-tandem peek --file server/src/index/watcher.rs --line 79
code-tandem peek --file server/src/index/watcher.rs --start 79 --end 120
code-tandem peek -f cli/src/client.cr --line 1

# Format modes
code-tandem peek -f cli/src/client.cr --start 130 --end 150 --format raw      # Clean source
code-tandem peek -f cli/src/client.cr --start 130 --end 150 --format display   # Line-numbered
code-tandem peek -f cli/src/client.cr --start 130 --end 150                    # JSON (pipe default)

# Symbol-aware
code-tandem peek -f server/src/ops/content.rs --symbol peek          # Entire function body
code-tandem peek -f server/src/ops/content.rs --line 250 --expand   # Expand to enclosing symbol

# Rich metadata
code-tandem peek -f server/src/ops/content.rs --start 1 --end 20 --outline   # File symbol outline
code-tandem peek -f server/src/ops/content.rs --start 1 --end 20 --blame     # Git blame
```

**Format modes:** `display` (TTY default), `json` (pipe default), `raw` (clean source).

**Key flags:** `--symbol <name>`, `--expand`, `--outline`, `--blame`, `--format raw`.

## `help` / `--version`

```bash
code-tandem help          # Show all commands and options
code-tandem <cmd> --help  # Per-command help
code-tandem -v            # Show version
```

## `stats` / `health` — Server Status

```bash
code-tandem stats       # Symbol count, file count, cache stats, uptime
code-tandem health      # Connectivity check
```

## `query` — JMESPath JSON Filtering

```bash
code-tandem query 'length(components)' --json '{"components":["server","cli"]}'
code-tandem graph "handle_events" --top 3 --format json | code-tandem query 'top_nodes[0:2].{name: name, edges: edges}' --stdin
code-tandem query 'length(topological_sort.sorted)' --file /tmp/r.json
```

Always use `--json` for inline data (most reliable). Use `--stdin` when piping. Use `--raw` for line-by-line output.

## `symbols` — List All Symbols

```bash
code-tandem symbols                            # All symbols in project
code-tandem symbols --kind function            # Functions only
code-tandem symbols --file server/src/main.rs  # Symbols in specific file
code-tandem symbols --limit 100                # Page size (auto-paginates)
```

Lists every indexed symbol with `name`, `kind`, `file`, `line`, and `signature`. Auto-paginates through all results via server cursor.

Output: `{count: N, symbols: [{name, kind, file, line, signature}]}`.

## `ast` — Get S-Expression AST Representation

```bash
code-tandem ast server/src/main.rs             # Get S-Expression representation of a file
```

Parses the file using the tree-sitter parser configured for its language and returns the AST as a parenthesized S-expression.

Output: `{ "path": "server/src/main.rs", "sexp": "(source_file ...)" }`.

## `output` — Cache Management

```bash
code-tandem output list                     # List all cached outputs
code-tandem output read "init" --command init # Read specific cached output
code-tandem output delete "main" --command graph  # Delete specific entry
code-tandem output clean                    # Clean stale entries
code-tandem output clean --all              # Clean everything
```

Use `--output` / `-o` on supported commands (`graph`, `flow`, `callers`, `search`, `tests`, `integration`, `stats`, `peek`, `strings`) to cache results.

**Cache invalidation:** Epoch-based + tag-based delta. Each entry stores `tags` (file paths), `epoch`, and `argv`. Stale if epoch mismatch or tagged file changed. `output clean` removes stale entries.

**Faulty commands are never cached.** `emit()` only runs on success path.

**Agent cleanup:** Use `output delete <symbol> [--command X]` to remove entries. Never delete files or edit index directly.

## `note` — Agent Scratchpad

```bash
# General notes
code-tandem note add "finding" -t insight
code-tandem note add "bug desc" -t bug
code-tandem note add "done" -t done

# Experiments (structured params)
code-tandem note add "cluster_depth=2: more edges" -t experiment --param cluster_depth=2 --param edges=12

# Browse
code-tandem note list                     # All notes
code-tandem note list -t experiment       # Experiments with params inline
code-tandem note read <id>                # Read specific note

# Manage
code-tandem note edit <id> "updated" -t insight
code-tandem note delete <id>
code-tandem note clean                    # Remove stale notes
code-tandem note clean --all              # Remove all
```

Stored in `.code-tandem/notes/`. LRU eviction at 1000 entries / 1 MB. Tags: `insight`, `bug`, `done`, `finding`, `experiment`. Survive server restarts.

## Global Options

| Option                             | Description                                                                                                                                                                                                                                                                  |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--output` / `-o`                  | Cache result to `.code-tandem/output/`. Supports: graph, flow, callers, search, tests, integration, stats, peek, strings, imports, fields, docs, annotations, unused-imports, symbols. **Note:** `export-docs` uses `--output` for its own file path, not cache persistence. |
| `--pretty` / `-p`                  | Force pretty-printed JSON even when piped                                                                                                                                                                                                                                    |
| `--compress <auto\|always\|never>` | LLM-readable lossless compression (default: `auto`). Can be placed before or after subcommand.                                                                                                                                                                               |
| `--verbose`                        | Show batch resolution warnings on STDERR. Applies to: graph, flow, callers                                                                                                                                                                                                   |
| `--help` / `-h`                    | Per-command help                                                                                                                                                                                                                                                             |
| `--raw`                            | `query`: line-by-line output. `integration`: raw refs with scores                                                                                                                                                                                                            |

## Output Compression

When piped to another process, code-tandem automatically compresses large outputs. Typically **30-75%** token reduction, zero information loss.

**Default (`--compress=auto`):**

- **TTY** → pretty-printed JSON
- **Pipe** + ≤1KB → compact JSON
- **Pipe** + >1KB → compressed columnar format

**Excluded commands** (always JSON): `stats`, `health`, `impl`, `peek`, `pseudocode`, `note`, `output`, `query`, `init`.

**Compressed format:** `#` metadata lines, `|` delimiter, `# --- section` separators, `# prefix: file=` path factoring, `||` empty values. Non-tabular sections stay as inline JSON.
