# GitNexus Engineering Plan

> Task: Resolve Zay issue #163 by excluding compacted-away session payloads from resume queries while preserving model-history projection.
> Evidence verified at commit `74859397831bc554d25710c33ce5907d571bca01`; GitNexus `zay` index is 2 commits behind. An isolated `gitnexus analyze --index-only --pdg` run left only parse caches; `gitnexus status` reported `not-indexed`, so no fresh graph/PDG was available.
> Evidence provenance schema 2; global dirty digest `0a9c85780067d9afcd0764f307b60891e3cee927ee11eaeb5ec7826d10fd82cd`; cited-path manifest 7 sorted entries; exact generated plan path excluded.

## 1. Objective

[verified] Keep `Session.messages` output identical while avoiding transfer and decoding of payloads for ancestors hidden by the active branch's latest compaction. Restrict the implementation to `src/session.zig` plus regression tests.

## 2. Current Behaviour

[verified] `Session.messages` (`src/session.zig:1066-1088`) calls `loadBranch`, finds a compaction boundary in the returned root-to-leaf path, emits its summary, then projects entries starting at `first_kept_index`.
[verified] `loadBranch` (`src/session.zig:1261-1292`) recursively selects `payload_json` for every active-branch entry before the projection discards the compacted prefix.
[verified] `findCompactionBoundary` (`src/session.zig:1316-1341`) considers the newest compaction, parses its `first_kept_id`, and returns no boundary when that ID is absent from the active path or lies after its summary. `EntryId` is an opaque fixed-width 8-byte value (`src/session/types.zig:12-36`), so boundary matching belongs in Zig rather than SQL substring assumptions.
[verified] `compactionFirstKeptId` (`src/session/serialize.zig:179-190`) rejects malformed JSON and invalid ID lengths; `Agent.reloadFromSession` projects before replacing live history (`src/agent.zig:1598-1624`).

## 3. Relevant Architecture

[verified] `SessionBackend.query` sends the SQL through local SQLite, the REST companion service, Turso, or D1 (`src/session/backend.zig:203-282`). The remote session backends use SQLite-compatible SQL; the companion can also use PostgreSQL (`docs/patterns/configuration-sessions-and-persistence.md:130-174`).
[verified] `loadBranch` is also used by skill-context and compaction-cut paths. Keep its full-ancestry contract and add a message-specific read path.
[verified] The agent swaps history only after the full conversation projection succeeds (`src/agent.zig:1602-1609`).

## 4. GitNexus Findings

[graph] `context({repo:"zay", name:"messages", file_path:"src/session.zig", kind:"Method"})` resolved `Session.messages`; its outgoing calls include `loadBranch`, `findCompactionBoundary`, and `appendProjectedEntry`. The index reports 2 commits behind HEAD; source was checked at current HEAD.
[graph] `impact({repo:"zay", target:"messages", file_path:"src/session.zig", direction:"upstream", maxDepth:3})` reports HIGH risk, 17 impacted symbols (d1=10, d2=4, d3=3), and a lower-bound result because 2 callers were unresolved. Direct dependents include the session projection tests, `SessionWriter.messages`, and `SessionWriter.conversation`; keep the public projection behavior unchanged.
[graph] The same impact reports 2 affected execution flows: session skill-context projection and session-writer skill-context projection. This reinforces keeping `loadBranch` unchanged for ancestry consumers.
[verified] `git diff 2df24f42955aa547716d57aa88f10f40288bc232..HEAD -- src/session.zig src/session/backend.zig src/session/serialize.zig src/agent.zig` is empty; the stale index's relevant source files match the pinned source, but graph completeness remains lower-bound.

## 5. Statement-Level PDG Findings

[graph] The indexed repository has no PDG layer. The isolated `--pdg` refresh did not produce an index, so statement-level graph claims are unavailable.
[verified] Source execution order is: query the active ancestry; determine the newest compaction boundary; build the summary and retained message list; return the completed projection; only then may the agent replace live history.
[inferred] The hot-path cost is the remote result's discarded `payload_json` bytes and JSON decoding; excluding those rows should reduce transfer for compacted sessions. No benchmark has independently measured the reported 12.9-second / 2.38-MB case.

## 6. Proposed Changes

- [verified] `src/session.zig`, `Session.messages` and a private message-projection loader: use a recursive metadata probe scoped by both `session_id` and entry `id`. When there is no compaction, return the full branch payloads in that query. When compacted, return all path IDs/kinds and only the newest compaction payload; validate it with the existing serializer.
- [inferred] For a valid boundary, issue a second recursive query from the leaf that stops at `first_kept_id` and returns only `message` and `branch_summary` payloads from that suffix. Emit the newest summary before those entries. This leaves `loadBranch` intact for skill context and compaction-cut callers and avoids JSON SQL extensions.
- [verified] For a malformed newest compaction payload, propagate the existing parse error. For an absent/off-path/after-summary boundary, use the existing full-branch read and projection behavior. Build results before callers replace live state.
- [verified] Both recursive queries and the payload join must include `session_id` and entry ID so identical entry IDs in separate sessions cannot cross-contaminate.

## 7. Implementation Sequence

1. Add the message-specific branch probe and suffix projection in `src/session.zig`; preserve `loadBranch` and its other callers.
2. Add focused coverage for no compaction, single and multiple compactions, omitted prefix payloads, post-compaction appends, branch switching/stale boundaries, and colliding IDs.
3. Add malformed-boundary coverage proving projection returns an error before any partial result is available; retain fallback behavior for a missing/off-path boundary.
4. Run `zig fmt src/session.zig`, `zig build test`, and `zig build test-plugin`; inspect the complete diff.
5. Run GitNexus staged-change analysis and review the final diff, then commit, push to Zay's `origin`, and open a PR against Zay's `main`.

## 8. Test Strategy

- Existing `src/session.zig` tests already cover plain message loading, one compaction, entries appended after compaction, and IDs colliding across sessions.
- Add a query-result regression that calls the message-specific loader and confirms compacted-away IDs/payloads are absent while the current summary and retained suffix remain.
- Add a second compaction and assert only the newest summary plus its retained suffix are projected.
- Add branch-switch coverage where the newest compaction boundary is no longer on the active path; expect the full active branch projection.
- Corrupt the newest compaction payload and expect the existing error; verify the method returns no partial projection. `Agent.reloadFromSession` remains project-first/swap-second.
- Run repository-required verification: `zig fmt src/session.zig`; `zig build test`; `zig build test-plugin` (`docs/BUILDING.md:50-67`). Tests exercise the shared SQL on local SQLite; no live Turso, D1, or REST service credentials are available for integration runs.

## 9. Risk and Impact Analysis

[graph] `Session.messages` is HIGH blast radius with 10 direct dependents and 2 unresolved incoming call sites in the 2-commit-stale index. Keep its signature and output unchanged; review session and writer callers.
[verified] The storage invariant is that failed database projections do not replace live history (`docs/patterns/configuration-sessions-and-persistence.md:136-147`; `src/agent.zig:1602-1609`). The new helper is read-only and returns an owned result only after both stages succeed.
[inferred] A compacted read adds one remote query roundtrip. It should save payload bytes when the discarded prefix is large; measure remote latency before claiming a wall-clock improvement.
[verified] Use common recursive CTE, CASE, EXISTS, and parameterized SQL constructs; do not add schema changes or backend-specific JSON operators. PostgreSQL companion behavior remains a compatibility concern because the current path query already orders by `rowid`; no new PostgreSQL-specific claim is made.

## 10. Files Expected to Change

| File | Symbols | Reason |
| ---- | ------- | ------ |
| `src/session.zig` | `Session.messages`, private message projection loader, session tests | Exclude unprojected ancestor payloads and cover projection equivalence. |
| `docs/plans/2026-10-21-gitnexus-plan-compacted-session-resume.md` | full plan | Preserve the evidence and implementation context required by the GitNexus workflow. |

## 11. Reusable Implementation Context

```json
{
  "task_summary": "Optimize compacted session resume while preserving Session.messages output and active-branch semantics.",
  "acceptance_criteria": [
    "Plain, single-compaction, and multiple-compaction histories project the same messages.",
    "Compacted-away ancestor payloads are not returned by the remote resume queries.",
    "Every recursive ancestry step and payload join is scoped by session_id and entry id.",
    "SQLite, Turso, D1, and REST companion backends use the same portable SQL behavior.",
    "Missing/off-path boundaries retain full-branch fallback; malformed summaries fail before live history is replaced."
  ],
  "evidence_provenance": {
    "schema_version": 2,
    "head_commit": "74859397831bc554d25710c33ce5907d571bca01",
    "generated_plan_path": "docs/plans/2026-10-21-gitnexus-plan-compacted-session-resume.md",
    "global_dirty_digest": {
      "algorithm": "sha256",
      "canonicalization": "gitnexus-evidence-provenance-v2 NUL-framed UTF-8 records",
      "value": "0a9c85780067d9afcd0764f307b60891e3cee927ee11eaeb5ec7826d10fd82cd"
    },
    "cited_path_manifest": [
      {
        "path": "docs/BUILDING.md",
        "object_kind": {
          "head": "regular",
          "index": "regular",
          "worktree": "regular",
          "untracked": "absent"
        },
        "state": "clean",
        "rename_from": null,
        "rename_to": null,
        "head_digest": "sha256:2bf173628a53e1618864fdaf7ca089c5b5fbfd14ac1f87f0150d61ffb2274ea6",
        "index_digest": "sha256:2bf173628a53e1618864fdaf7ca089c5b5fbfd14ac1f87f0150d61ffb2274ea6",
        "worktree_digest": "sha256:2bf173628a53e1618864fdaf7ca089c5b5fbfd14ac1f87f0150d61ffb2274ea6",
        "untracked_digest": "absent"
      },
      {
        "path": "docs/patterns/configuration-sessions-and-persistence.md",
        "object_kind": {
          "head": "regular",
          "index": "regular",
          "worktree": "regular",
          "untracked": "absent"
        },
        "state": "clean",
        "rename_from": null,
        "rename_to": null,
        "head_digest": "sha256:e16c4993809f9d957f69f2f1d65dde25afd3fdf25314ff850846ae027a6368c4",
        "index_digest": "sha256:e16c4993809f9d957f69f2f1d65dde25afd3fdf25314ff850846ae027a6368c4",
        "worktree_digest": "sha256:e16c4993809f9d957f69f2f1d65dde25afd3fdf25314ff850846ae027a6368c4",
        "untracked_digest": "absent"
      },
      {
        "path": "src/agent.zig",
        "object_kind": {
          "head": "regular",
          "index": "regular",
          "worktree": "regular",
          "untracked": "absent"
        },
        "state": "clean",
        "rename_from": null,
        "rename_to": null,
        "head_digest": "sha256:ba8d9efc2a01f8d35e1a27d9e2e271e1d08b1de090f71ce15c26c42ccb3bccc3",
        "index_digest": "sha256:ba8d9efc2a01f8d35e1a27d9e2e271e1d08b1de090f71ce15c26c42ccb3bccc3",
        "worktree_digest": "sha256:ba8d9efc2a01f8d35e1a27d9e2e271e1d08b1de090f71ce15c26c42ccb3bccc3",
        "untracked_digest": "absent"
      },
      {
        "path": "src/session.zig",
        "object_kind": {
          "head": "regular",
          "index": "regular",
          "worktree": "regular",
          "untracked": "absent"
        },
        "state": "clean",
        "rename_from": null,
        "rename_to": null,
        "head_digest": "sha256:313f75c2585a5b0a3537f769b2a81e8562ca6af5fca17058ad65d3233bd495bd",
        "index_digest": "sha256:313f75c2585a5b0a3537f769b2a81e8562ca6af5fca17058ad65d3233bd495bd",
        "worktree_digest": "sha256:313f75c2585a5b0a3537f769b2a81e8562ca6af5fca17058ad65d3233bd495bd",
        "untracked_digest": "absent"
      },
      {
        "path": "src/session/backend.zig",
        "object_kind": {
          "head": "regular",
          "index": "regular",
          "worktree": "regular",
          "untracked": "absent"
        },
        "state": "clean",
        "rename_from": null,
        "rename_to": null,
        "head_digest": "sha256:ac18a8cefd8217fb04eb851a466824f255d25dc6a480663598a3639062df8ed1",
        "index_digest": "sha256:ac18a8cefd8217fb04eb851a466824f255d25dc6a480663598a3639062df8ed1",
        "worktree_digest": "sha256:ac18a8cefd8217fb04eb851a466824f255d25dc6a480663598a3639062df8ed1",
        "untracked_digest": "absent"
      },
      {
        "path": "src/session/serialize.zig",
        "object_kind": {
          "head": "regular",
          "index": "regular",
          "worktree": "regular",
          "untracked": "absent"
        },
        "state": "clean",
        "rename_from": null,
        "rename_to": null,
        "head_digest": "sha256:625a9b695f42c997bc09a4d176d257cf6f726dc27fb1d72c4f65488d75b1b752",
        "index_digest": "sha256:625a9b695f42c997bc09a4d176d257cf6f726dc27fb1d72c4f65488d75b1b752",
        "worktree_digest": "sha256:625a9b695f42c997bc09a4d176d257cf6f726dc27fb1d72c4f65488d75b1b752",
        "untracked_digest": "absent"
      },
      {
        "path": "src/session/types.zig",
        "object_kind": {
          "head": "regular",
          "index": "regular",
          "worktree": "regular",
          "untracked": "absent"
        },
        "state": "clean",
        "rename_from": null,
        "rename_to": null,
        "head_digest": "sha256:57cfa838bfceaf9d32b7e813107541462a45eef18534411a59499f5105fa90f9",
        "index_digest": "sha256:57cfa838bfceaf9d32b7e813107541462a45eef18534411a59499f5105fa90f9",
        "worktree_digest": "sha256:57cfa838bfceaf9d32b7e813107541462a45eef18534411a59499f5105fa90f9",
        "untracked_digest": "absent"
      }
    ]
  },
  "primary_symbols": [
    {"symbol": "Session.messages", "file": "src/session.zig", "lines": "1066-1088", "role": "Build the model-visible session projection."},
    {"symbol": "Session.loadBranch", "file": "src/session.zig", "lines": "1261-1292", "role": "Current full-payload ancestry load; preserve for other callers."},
    {"symbol": "findCompactionBoundary", "file": "src/session.zig", "lines": "1316-1341", "role": "Current boundary validation/fallback semantics."}
  ],
  "related_symbols": [
    {"symbol": "Session.skillContext", "relationship": "CALLS loadBranch", "relevance": "Still needs full ancestry."},
    {"symbol": "Session.compactionCut", "relationship": "CALLS loadBranch", "relevance": "Still folds the full prefix during compaction."},
    {"symbol": "SessionBackend.query", "relationship": "backend boundary", "relevance": "Executes the same SQL on supported session backends."},
    {"symbol": "Agent.reloadFromSession", "relationship": "consumer", "relevance": "Projects before replacing live history."}
  ],
  "execution_path": [
    "Session.messages probes active ancestry scoped by session_id and leaf entry id.",
    "No compaction: consume full payload rows from the probe result.",
    "Compaction: parse newest summary and validate first_kept_id against active ancestry.",
    "Valid boundary: query projected message kinds from first_kept_id through leaf; emit summary first.",
    "Missing/off-path boundary: fall back to the established full-branch projection; malformed payload returns its existing error."
  ],
  "pdg_constraints": [],
  "architectural_patterns": [
    {"pattern": "Keep full ancestry readers unchanged when one consumer needs a narrower projection.", "example_location": "src/session.zig::Session.skillContext", "usage_guidance": "Add a message-specific read path; do not narrow loadBranch globally."},
    {"pattern": "Project durable history before replacing live state.", "example_location": "src/agent.zig::Agent.reloadFromSession", "usage_guidance": "Return errors before exposing partial projected history."}
  ],
  "files_to_modify": [
    {"file": "src/session.zig", "symbols": ["Session.messages", "private message projection loader", "tests"], "intended_change": "Avoid fetching compacted-away payloads while preserving emitted messages and fallback semantics."}
  ],
  "tests": [
    {"file": "src/session.zig", "scenarios": [
      "No compaction → all existing messages are projected.",
      "One compaction → summary and suffix are projected; compacted-away payload rows are absent.",
      "Multiple compactions → newest summary and retained suffix are projected.",
      "Boundary on an abandoned branch → full active branch fallback is projected.",
      "Colliding entry IDs across sessions → no foreign rows are read.",
      "Malformed newest compaction payload → existing error and no partial result."
    ]}
  ],
  "verification_commands": ["zig fmt src/session.zig", "zig build test", "zig build test-plugin"],
  "risks": [
    "Session.messages is a high-impact shared method; its index is 2 commits stale and omits 2 unresolved callers.",
    "Compacted reads add a remote query roundtrip; payload reduction is expected but wall-clock improvement needs measurement.",
    "Live remote backend integration is not available in this environment."
  ],
  "assumptions": [
    "The existing recursive CTE and CASE/EXISTS SQL surface is accepted by the active remote session backends; verify with repository tests and backend adapter contract."
  ],
  "open_questions": ["The issue reporter's 12.9-second and 2.38-MB measurements have not been independently reproduced."],
  "avoid": [
    "Do not change loadBranch behavior for skillContext or compactionCut.",
    "Do not change Session.messages public signature or its message ordering.",
    "Do not add SQL JSON functions, migrations, or unrelated backend changes."
  ]
}
```

## 12. Assumptions and Open Questions

- **Assumption:** The remote query adapters accept the existing SQLite-compatible recursive CTE and standard CASE/EXISTS constructs. Confirm with `zig build test` and preserve the current backend API.
- **Open:** The reported 12.9-second and 2.38-MB performance numbers have not been reproduced. The code change proves result-shape reduction in local SQLite tests, not remote elapsed-time improvement.
- **Open:** No live Turso, D1, or REST credentials are available for cross-provider integration checks.
- **Open:** GitNexus PDG is unavailable because the MCP index has no PDG layer and the isolated refresh did not finalize an index; source reads remain authoritative.

## 13. Definition of Done

[verified] `Session.messages` keeps the same projection for no, one, or multiple compactions and for branch navigation, while valid compacted reads exclude discarded ancestor payloads from query results.
[verified] Session scoping, malformed-boundary errors, missing-boundary fallback, and project-before-swap behavior remain covered.
[verified] `zig fmt src/session.zig`, `zig build test`, and `zig build test-plugin` pass; GitNexus change analysis and final diff review are complete; the fix is pushed to Zay `origin` and an issue-linked PR is open.
