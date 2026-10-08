# PR review field report fixes — 2026-10-09

The implementation addresses F-01 through F-08 in Zay and Seek. Session evidence
was read from SQLite in read-only/query-only mode; no session records were changed.
Relevant review session: `1344e01449c6345df0c2a3f992ec9c35`.

| Finding | Diagnosis and change | Verification |
| --- | --- | --- |
| F-01 | Todo now creates `.zay/todos` recursively before its first write. Directory errors stop writes. | Clean-workspace and AccessDenied plugin regressions. |
| F-02 | Zay's model-facing optional-null encoding reached a non-nullable Seek parameter. MCP schema ingestion preserves explicit nullability; dispatch omits null only for optional, non-nullable known properties. Required non-nullable null is rejected; null is preserved when unsupported schema constraints leave nullability unknown. | Schema and argument-normalization regressions; full Zay tests. |
| F-03 | Missing embeddings are a capability limitation. Seek adds `seek_capabilities`, and an explicit vector request returns a structured `vector_unavailable` tool error with lexical retry arguments. No implicit downgrade of explicit vector requests. | In-memory MCP test: capability → vector error → successful lexical retry. |
| F-04 | `skill` accepts a relative `resource` path under the registered skill directory. The same opened file handle is checked and read, with traversal/symlink containment, a 256 KiB cap, and UTF-8 validation. Resource reads do not activate a skill or replace resource text with cached instructions. | Outside-workspace rubric, traversal, symlink, and history-reconstruction regressions. |
| F-05 | The session used an absent `text` column and a comma-joined string as one glob. Sitting-duck preserves more error detail, suggests `peek`/`ast_get_source`, and documents one glob per outline call. Commas are not silently reinterpreted. | Both recorded error cases reproduced in plugin tests. |
| F-06 | A terminal turn can still retain a live runtime during teardown. Lane status, resume, steer and await now derive the same snapshot and expose `finishing` instead of contradictory idle/running answers. Await does not acknowledge completion until teardown finishes; repeated await remains stable. | Terminal-transition regression and all lane tests. |
| F-07 | Seek's required `check-bundle` job was inside a PR path-filtered workflow. The workflow now runs on every PR; push filters remain. | Local bundle checker passes. Live required-check behavior is verified only after publishing the workflow. |
| F-08 | Bulk sync reports absent auto-discovered sources as skipped warnings. Explicitly selected missing sources, real indexing errors, and per-document failures still fail. `--json` exposes collection reports; `--strict` also fails on unavailable sources/embeddings. Intentional `--no-embed` remains valid. | Mixed available/missing source integration, JSON stdout validation, strict/explicit-target cases, and missing-source versus unmatched-version tests. |

F-02 evidence: `call_00dffc89894e4a61a7a96ac018384bac` sent `repo: null`
and other null optional filters. F-05 evidence:
`call_4b5ee6e3b50d42acbc9ccef5763cda72` selected `text`;
`call_a12a50770f5a4b01a26fb6839ed9d002` used a comma-joined outline glob.
These support an adapter/schema mismatch for F-02 and tool-use ergonomics for
F-05, rather than evidence of a changed AST column contract.

## Validation

- Zay: `zig build`, full `zig build test`, `zig build test-plugin`, focused MCP,
  skill and lane tests, Zig formatting, plugin catalog check, and diff whitespace
  checks passed. Socket tests required execution outside the filesystem sandbox.
  Zig's documented misleading `failed command` test-server lines were judged by
  process exit status, which was zero.
- Seek: real FTS5 build, full FTS5 test suite, final command/parser regressions,
  `go vet`, gofmt, bundle check and diff whitespace checks passed. Tested changes
  were applied from `/tmp/seek-field-fixes` to the original Seek working tree.
- GitNexus change analysis returned `partial=false`, `truncated=false` for both
  repositories. It classifies the aggregate change as critical because it spans
  shared skill/agent/lane and MCP/search/sync flows. Relevant focused regressions
  and full suites cover these flows. The Seek index is one commit behind HEAD,
  and graph results do not enumerate the newly added untracked symbols; graph
  analysis is not an exhaustive proof of safety.

## Publication boundary

Catalog hashes are checked against the committed bytes at their pinned URLs,
not unpublished worktree files. Local `sourceDir` installs use the edited packages.
Changes are implemented locally; installed binaries and global plugin copies
were not replaced. The required-check fix takes effect after the workflow is
published. Before publishing remote plugin metadata, publish the package commit
and run `python3 scripts/sync-plugin-catalog.py --write --ref <full-commit-SHA>`
so pinned URLs and file hashes refer to the same bytes. Checkout installs use
`sourceDir`; current remote URLs still point to the prior published revision.
Existing user modifications and untracked files were preserved.
