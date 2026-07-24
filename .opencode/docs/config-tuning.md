# Config Tuning

## Integration Config

**There is no `code-tandem config` command.** Configuration is stored in `.code-tandem/config.json`. To view: `cat .code-tandem/config.json | jq`. To modify: `integration --apply-patterns` with a LearningReport. File created on first apply.

All tunables in `IntegrationConfig` at `project-root/.code-tandem/config.json`:

| Config Key                          | Default | Controls                                                                         |
| ----------------------------------- | ------- | -------------------------------------------------------------------------------- |
| `min_confidence`                    | 0.5     | Minimum score for above-threshold refs                                           |
| `cluster_depth`                     | 1       | Directory depth for auto-clustering                                              |
| `sample_limit`                      | 50      | Max symbols per component in matrix                                              |
| `component_rules`                   | []      | Explicit component patterns, used by graph/flow/callers too                      |
| `noise_identifiers`                 | []      | Filtered from id_refs in graph/flow/callers callee resolution                    |
| `ignore_patterns`                   | []      | Substring patterns for file filtering during indexing (`__snapshots__`, `.snap`) |
| `manifest_cache`                    | {}      | Auto-detected component boundaries from package.json/Cargo.toml etc.             |
| `patterns`                          | []      | Pattern list for scoring refs                                                    |
| `whitelist`                         | []      | True-positive ref keys (always score ≥ confidence)                               |
| `blacklist`                         | []      | False-positive ref keys (always score < confidence)                              |
| `default_callers_depth`             | 1       | Default `callers` depth                                                          |
| `default_graph_depth`               | 2       | Default `graph` depth                                                            |
| `default_flow_depth`                | 5       | Default `flow` depth                                                             |
| `cache_full_invalidation_threshold` | 50      | Files changed before full cache clear                                            |
| `cache_validation_interval_secs`    | 30      | Seconds between epoch checks                                                     |
| `memory_cache_ttl_minutes`          | 5       | MemoryCache entry expiry                                                         |
| `graph_cache_ttl_minutes`           | 30      | GraphCache entry expiry                                                          |
| `test_name_patterns`                | {}      | Per-language test name prefix overrides                                          |
| `extra_test_framework_ids`          | []      | IDs bypassing stdlib filter                                                      |

## Pseudocode Config

Separate config at `.code-tandem/pseudocode_config.json`. Server-independent, evaluated CLI-side only.

| Config Key            | Default       | Controls                                       |
| --------------------- | ------------- | ---------------------------------------------- |
| `version`             | 1             | Config schema version                          |
| `body_rules`          | []            | Override regex rules for `transform_body_line` |
| `type_strip_rules`    | []            | Override regex rules for `strip_types`         |
| `signature_rules`     | []            | Override regex rules for `transform_signature` |
| `visibility_keywords` | ["pub ", ...] | Keywords stripped from function signatures     |
| `closing_tokens`      | ["}", ...]    | Lines matching these are skipped               |
| `comment_prefixes`    | ["#", ...]    | Lines starting with these are skipped          |
| `skip_tokens`         | ["pass", ...] | Lines matching these exactly are skipped       |

**Rule precedence:** Config rules run **before** hardcoded regex. If a config rule matches, hardcoded is skipped. If config is empty, hardcoded fallback runs.

**TransformRule structure:**

```json
{
  "pattern": "^go\\s+(.+)$",
  "replacement": "",
  "output_prefix": "SPAWN ",
  "lang": ["go"],
  "strip_suffix": null,
  "priority": 50
}
```

**TypeStripRule structure:**

```json
{
  "pattern": "\\b(int|int8|int16)\\b",
  "replacement": "",
  "lang": ["go"],
  "cleanup": true
}
```

**SignatureRule structure:**

```json
{
  "match_prefix": "func ",
  "output_keyword": "FUNCTION",
  "lang": ["go"],
  "is_method_check": null,
  "method_keyword": null,
  "name_capture": 1
}
```

## Pseudocode Quality Feedback Loop

Use `pseudocode` quality metadata to iteratively improve transformation rules:

1. Run `code-tandem pseudocode "funcName"` → check `quality.coverage`
2. If `coverage < 0.7`, examine `quality.untransformed_lines` for patterns
3. Add new `body_rules` to `pseudocode_config.json` matching those patterns
4. Re-run pseudocode → verify coverage improved
5. Record: `code-tandem note add "lang=X coverage=0.55→0.82" -t experiment --param lang=X --param coverage=0.82`

**Config file location:** `.code-tandem/pseudocode_config.json` (gitignored, runtime-only).

## Dynamic AST Query Config (.tsq)

Tree-sitter queries can be dynamically customized by placing a `.tsq` file in `.code-tandem/queries/` within the project root:

```
.code-tandem/queries/<language>.tsq
```

Supported headers for language query blocks:
*   `[symbols]`: Matches symbols. Captures `@symbol.name` and `@symbol.def`.
*   `[callers]`: Matches callee call expressions. Captures `@callee`.
*   `[id_refs]`: Matches identifier references for inverted indexing. Captures `@callee`.
*   `[variables]`: Matches local variables for scope filtering. Captures `@var.name`.
*   `[string]`: Matches string literals. Captures `@string_content`.
*   `[template_string]`: Matches template string literals. Captures `@string_content`.
*   `[imports]`: Matches imports/requires. Captures `@import.source` and `@import.def`.
*   `[fields]`: Matches struct/class fields. Captures `@field.name` and `@field.type`.
*   `[annotations]`: Matches annotations/decorators. Captures `@annotation.name`.

The server hot-reloads these queries dynamically when the `.tsq` files are modified (monitored via `mtime` modification timestamps).

### Use Cases (Usage Scenarios)
1.  **Targeted Symbol Extraction (Noise Reduction):** For large projects, reduce index size by targeting only core definitions (e.g., matching only `(struct_item)` and `(impl_item)` under `[symbols]`), ignoring constants, local imports, and inline helper functions.
2.  **Custom Macro/Router Parsing:** Capture framework-specific handler dispatches or macros (e.g., custom HTTP handlers, logging hooks) as valid callees under `[callers]` that the standard parser misses.
3.  **Specific String Literal Scoping:** Filter string references by customizing the `[string]` and `[template_string]` patterns to only index specific string types (e.g. matching SQL blocks or configuration keys).
4.  **Special Annotation Mapping:** Track custom framework attributes (e.g. TS `@Injectable()` or Python `@route`) under `[annotations]` to trace decorator dependency trees.

### Benefits
*   **Zero Downtime Hot-Reloading:** The server automatically monitors file modification timestamps (`mtime`) and dynamically reloads modified `.tsq` rules on the next query without requiring a server restart.
*   **Token & Memory Savings:** Filtering out noisy AST nodes at extraction time drastically reduces database footprint and improves LLM token efficiency during graph representation.
*   **Localized & Safe:** Configured under the `.code-tandem/queries/` directory (which is gitignored), keeping project-specific rules sandboxed and out of the main codebase repository.

