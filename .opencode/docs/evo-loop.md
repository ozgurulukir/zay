# Evo-Loop: Pattern Engine Deep Dive

The `integration` command uses an iterative agent-driven loop for reducing false cross-refs. Each iteration: learn → classify → apply → verify. Repeat until converged.

**Config persistence:** Config changes are saved to `.code-tandem/config.json` only when you run `integration --apply-patterns`. The `init` command does NOT create a config file. This gives the agent explicit control over configuration changes and ensures config is never modified without approval.

## Prerequisites

**On first run (gen 0), set up `component_rules` before using `graph --component`.** The cascade now works: `component_rules` > `manifest_cache` > `cluster_depth`. If manifests are present (package.json, Cargo.toml, etc.), `init` auto-detects components. Use `--learn` to verify.

**Convergence:** After each `--apply-patterns`, check `converged` in the response. When `true`, the matrix is stable — stop iterating. Only re-run when the codebase changes significantly. Detect changes by comparing `stats` (files/symbols count).

**Auto-noise reflex:** After each `--apply-patterns`, immediately run `integration --learn` to check for remaining suspicious patterns. If `suspicious_patterns` contains false positives (same-name utility functions, generic names), extract their symbol names and apply:

```bash
code-tandem integration
code-tandem integration --learn
code-tandem integration --apply-patterns '{
  "patterns": [],
  "noise_identifiers": ["emit", "save_output", "raw_get", "epoch_info"]
}'
code-tandem integration --learn  # verify
```

Repeat until `--learn` shows only legitimate cross-language contracts (DTOs, API endpoints).

**Meta-parameter exploration:** Matrix quality depends on `cluster_depth`, `sample_limit`, `min_confidence`. Try different values and track with `note --param`.

**Gen 0 workflow:** `integration` (see heuristic) → `integration --learn --verbose` (get suspicious patterns) → `--apply-patterns` (set `component_rules` + `noise_identifiers`) → `integration` (verify) → `graph --component <name>` (scoped analysis works now).

## Step 1: Learn — Generate Learning Data

```bash
code-tandem integration --learn              # Suspicious patterns summary
code-tandem integration --learn --verbose    # Full cross-ref details with components
```

## Step 2: Classify — Build LearningReport

Classify each cross-ref as true/false positive. Define patterns to filter noise. Add noise identifiers.

**Ref key format:** `symbol_name@dest_file` (NOT `symbol -> source -> dest`).

**Scoring:** base 0.5 per ref. `confidence_penalty` subtracts, `confidence_boost` adds. Clamped to [0.0, 1.0]. Ref score = maximum of all matching pattern scores.

**Minimum working LearningReport:**

```json
{
  "patterns": [
    {
      "id": "test-spec-skip",
      "pattern_type": "file_pattern",
      "file_pattern": "/spec/",
      "confidence_penalty": 1.0,
      "confidence_boost": 0.0,
      "fitness": 10.0,
      "rationale": "Test specs are not cross-component dependencies",
      "generated_by": "agent",
      "is_active": true,
      "created_at": "2026-05-09T20:00:00Z"
    }
  ],
  "classification": [
    {"ref_key": "BatchError@server/src/ops/symbol_ops/batch.rs", "is_true_positive": true, "reason": "Serialized type between CLI and server"}
  ],
  "noise_identifiers": ["to_json", "clone", "push"]
}
```

**All Pattern fields:** `id` (required), `pattern_type` (required: `file_pattern` or `name_pattern`), `name_pattern`?, `file_pattern`?, `source_file_pattern`?, `component_from`?, `component_to`?, `min_ref_count`?, `max_ref_count`?, `confidence_penalty` (required), `confidence_boost` (required), `fitness` (required), `rationale` (required), `generated_by` (required), `is_active` (required), `created_at` (required), `last_evaluated_at`?.

**Other LearningReport fields:** `component_suggestions`?, `min_confidence`?, `noise_identifiers`?, `test_name_patterns`?, `test_file_contains`?, `extra_test_framework_ids`?, `cluster_depth`?, `sample_limit`?.

**Pruning fields:** `remove_noise_identifiers`?, `remove_patterns`?. Remove entries before additions. Use to shrink bloated lists.

## Step 3: Apply — Commit the Report

```bash
code-tandem integration --apply-patterns report.json          # From file
code-tandem integration --apply-patterns '{"patterns":[...]}' # Inline JSON
echo '{"patterns":[...]}' | code-tandem integration --apply-patterns --stdin  # Via stdin
```

Returns `{"status":"applied","generation":1,...}` — NOT the matrix. Run `code-tandem integration` separately to verify. `"patterns":[]` is valid.

Config stored at `.code-tandem/config.json`. Applied atomically into memory — no server restart needed.

## Step 4: Verify

```bash
code-tandem integration              # Check improved matrix
code-tandem integration --learn       # See what's left to clean up
```

## Experiment Tracking with Notes

`note add --param key=value --tag experiment` saves structured experiments. `note list --tag experiment` shows params inline.

**At start of session** (especially after `init --force`), check previous experiments:

```bash
code-tandem note list --tag experiment -p
```

Pick the best experiment, re-apply its config:

```bash
code-tandem integration --apply-patterns '{...}'
code-tandem integration   # Verify
```

**During tuning**, save each iteration:

```bash
code-tandem integration --apply-patterns '{"cluster_depth": 2}'
code-tandem integration
code-tandem note add "cluster_depth=2: more cross-refs" -t experiment \
  --param cluster_depth=2 --param edges=12 --param refs=22
```

**On re-init (`init -f`), always restore best config:**

```bash
code-tandem note list --tag experiment -p
code-tandem integration --apply-patterns '{...}'
code-tandem integration
```
