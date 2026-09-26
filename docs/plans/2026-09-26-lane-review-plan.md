# Lane Review Feature Plan

## 1. Objective

Add a deterministic review workflow for a completed lane's changes. A review runs in a fresh session, evaluates one immutable source snapshot, returns a structured report to the driver, and never applies findings or merges code automatically. The driver can send findings to the original worker session or start a fresh fixer session on the same worktree.

Initial scope is committed changes only. The source lane must be idle and clean, and only one live runtime may use a given worktree at a time.

## 2. User Flow

Proposed model-facing command:

```text
lane review <lane-id> "Review correctness, regressions, and missing tests"
```

1. The driver requests review of an idle worker lane.
2. Zay validates the lane and captures the review target: repository identity, worktree path, branch, base commit, and head commit.
3. Zay persists a pending review run before starting reviewer work.
4. Zay attaches a fresh session to the same lane/worktree and starts the reviewer with the frozen commit range and review policy.
5. The reviewer returns a structured report. Zay validates and persists it, marks the run completed, parks the lane, and delivers the report to the driver.
6. The driver chooses whether to accept, dismiss, or route findings to a fixer. Fixing is a separate operation and does not mutate the review run.
7. Any changed head commit requires a new review run. A report for an older head remains available as historical evidence but is stale for the new tree.

The first version has no automatic fix, merge, approval, or release action.

## 3. Existing Architecture and Integration Points

- `src/tools/lane.zig` defines the model-facing lane command surface and request fields.
- `src/tools/lane_bridge.zig` transports lane requests to the UI thread and returns responses.
- `src/tui/lane_lifecycle.zig` owns lane operations, including spawn, wake, park, and completion delivery.
- `src/tui/session_switcher.zig` creates a runtime from a cwd and optional session ID. A null session ID starts a new session.
- `src/runtime.zig::initSession` loads persisted messages only when a session ID is supplied; a new session still receives system context and configured tools.
- `src/session/lane_manifest.zig` stores the durable lane-to-worktree/session association. Its current grain is one row per worktree, so it should remain lifecycle linkage rather than becoming the review-history store.
- `src/tui/lanes/recovery.zig` owns startup lane recovery and is the integration point for reconciling interrupted review activity.
- `src/tui/lanes/merge_flow.zig` and `src/tui/lane_lifecycle.zig::mergeLaneOp` require idle lanes and clean committed source trees before merge.

The review flow should reuse the existing fresh-runtime/session creation path and lane park/wake lifecycle. It must not create a second concurrent writer against the same worktree.

## 4. Invariants

1. **Snapshot identity:** every review names an immutable `base_oid..head_oid` range. Prompts, reports, retries, and status refer to that exact range.
2. **Committed input:** v1 refuses dirty source worktrees, including staged, unstaged, and untracked changes. It does not silently omit those changes from the target.
3. **Single worktree writer:** no two live runtimes may operate on the same worktree simultaneously. Reviewer/fixer transitions happen after the prior runtime is parked.
4. **Fresh reviewer history:** reviewer session starts with no source-worker conversation. It receives only the task, frozen snapshot identity, review instructions, and explicitly selected project context.
5. **Read-only review:** reviewer capabilities must not permit modifying the reviewed worktree. Prompt wording alone is not enforcement.
6. **No implicit action:** review completion never edits files, commits, merges, or marks findings accepted.
7. **Stale-result detection:** if the lane's current head differs from the run's `head_oid`, the report is stale for current code and cannot be represented as current approval.
8. **Durable lifecycle:** a crash cannot turn an incomplete run into a completed one or lose the mapping between the review, lane, worktree, and reviewer session.
9. **Historical runs:** rerunning the same range creates a new run ID; the previous report remains inspectable.
10. **Explicit session routing:** the driver chooses whether to resume the source session or create a new fixer session; reviewer conversation is not silently appended to either.

## 5. Data Model Sketch

Introduce a review-history record separate from the worktree-keyed lane manifest. Exact storage location and schema migration should be decided during implementation design.

```zig
const ReviewRun = struct {
    id: ReviewId,
    lane_id: LaneId,
    repo_key: []const u8,
    worktree_path: []const u8,
    branch: []const u8,
    base_oid: CommitId,
    head_oid: CommitId,
    reviewer_session_id: ?SessionId,
    status: enum { pending, running, completed, failed, stale },
    report: ?ReviewReport,
    created_at_ms: i64,
    updated_at_ms: i64,
};

const ReviewFinding = struct {
    severity: enum { blocker, high, medium, low, note },
    file: []const u8,
    line: ?u32,
    title: []const u8,
    explanation: []const u8,
    suggested_check: ?[]const u8,
};

const ReviewReport = struct {
    summary: []const u8,
    findings: []const ReviewFinding,
    checks_performed: []const []const u8,
};
```

`ReviewRun.status` is the durable operation state. `Thread.Engine` remains the live/idle runtime state and should not gain review-specific arms. Keep workflow orchestration out of leaf session/storage modules.

Review report parsing is a boundary: reject malformed or oversized reports, validate enum values and bounded paths/text, and preserve a clear failure state rather than accepting partial structured data as complete.

## 6. State Machine and Recovery

```text
pending → running → completed
                  ↘ failed
                  ↘ stale
```

- Persist `pending` with snapshot identity before attaching or starting the reviewer.
- Persist reviewer session ID and transition to `running` once runtime/session attachment succeeds.
- Persist the complete validated report before setting `completed` and before notifying the driver.
- On startup, a `running` run without a live runtime is reconciled to `failed` with an interruption reason. The same snapshot may be retried as a new run.
- Before delivering a completed report as current, compare the lane's current head to the recorded `head_oid`; if different, mark/report it as stale.
- Persistence errors must not be hidden behind a success response. Lane manifest writes remain best-effort for lane recovery, but review status/report durability is part of the feature contract.

## 7. Reviewer Contract and Tool Permissions

The reviewer should produce findings, not implement them. Its output schema must clearly distinguish:

- a confirmed issue from a question or suggestion;
- a finding's severity and exact location;
- an empty finding list from a failed/incomplete review;
- checks actually performed from checks merely recommended.

The current normal worker runtime exposes powerful tools, including shell execution. V1 must provide a review-specific restricted tool plan that can inspect the pinned diff and source but cannot write to the worktree, commit, spawn another lane, or trigger merge. If the existing executor cannot enforce that boundary cleanly, use a separate detached review checkout pinned to `head_oid` and still expose a restricted tool plan; do not claim a read-only guarantee based only on a system prompt.

Avoid passing the complete source worker transcript. Include a bounded diff/context packet and let the reviewer inspect only the pinned snapshot. Set explicit input/output limits and report truncation as a review failure or incomplete review, never as a clean pass.

## 8. Command/API Shape

### V1 operation

Extend the lane request protocol with a review operation carrying:

- target lane ID;
- review task/instructions;
- optional review profile, if profiles are included in v1.

The response should return a review run ID, pinned head, state, and report or a clear pending/running response. Keep session IDs internal unless existing user-facing conventions require them.

### Follow-up operations

Keep v1 follow-ups explicit and narrow:

- `lane review read <review-id>`: inspect the durable report.
- `lane review retry <review-id>`: create a new run for the same snapshot, if it still exists and is available.
- `lane spawn <task> --lane <id> --session fresh` (or equivalent): explicitly create a fresh fixer session on an existing idle worktree.
- Existing spawn/reuse without `--session fresh` continues to preserve current semantics.

Do not add broad approve/dismiss state until there is a concrete downstream behavior tied to it. Driver acceptance can initially remain a conversational decision.

## 9. Implementation Phases

### Phase 1: Pin down the snapshot contract

- Confirm the base commit definition: lane fork point from the primary branch versus a recorded lane-creation base.
- Confirm how branch renames and primary updates affect that base.
- Define dirty-tree detection for v1 and the error shown for dirty lanes.
- Define diff size and review context limits.

### Phase 2: Add review record and persistence

- Add `ReviewId`, review status, snapshot identity, report types, and storage operations.
- Add schema migration and bounded serialization/deserialization.
- Ensure writes are ordered so report data is durable before completion is visible.
- Add recovery reconciliation for interrupted runs.

### Phase 3: Enforce read-only reviewer capability

- Define a review-specific attach/tool plan, derived from the normal runtime configuration but with a narrow read-only surface.
- Verify tools cannot write, spawn, merge, or alter global plugin/MCP state.
- Ensure project/lane context reflects the pinned worktree and snapshot.
- Preserve the existing invariant that one live runtime owns a worktree at a time.

### Phase 4: Orchestrate `lane review`

- Add the bridge request and user-facing tool schema.
- Validate target is a worker lane, idle, clean, and has a valid committed range.
- Persist `pending`, create a fresh reviewer session, persist reviewer session ID, and start the turn.
- On completion, parse/validate the report, check staleness, persist the result, park the lane, and notify the driver.
- Handle all startup/runtime/turn failures as durable failed runs with useful reasons.

### Phase 5: Route findings to a fixer

- Add an explicit fresh-session option for reusing an idle worktree.
- Ensure the new session is associated with the existing worktree without overwriting the prior session's history.
- Pass the structured review report and pinned source head to the fixer.
- Preserve the original worker session as a separate resume option.

### Phase 6: Recovery and user experience

- Expose review status and history through lane listing/detail or a focused review-read command.
- Ensure startup recovery identifies abandoned `running` records and retains reports for older snapshots.
- State clearly when a report is stale, incomplete, failed, or has no findings.

## 10. Verification Plan

Add focused tests for:

- dirty lane refusal and deterministic base/head capture;
- fresh reviewer session with no source transcript messages;
- runtime exclusivity for a worktree across review/fix transitions;
- reviewer tool permissions rejecting write/commit/lane/merge actions;
- report schema validation, empty findings, malformed output, and size caps;
- completed report persistence before driver delivery;
- head changes causing stale status;
- failures at every attach/start/finish persistence boundary;
- startup recovery of pending/running runs;
- retry creating a distinct run ID for the same snapshot;
- fresh fixer session preserving the original session and worktree association;
- existing lane spawn/reuse and merge behavior remaining unchanged.

Run the relevant lane/session tests and formatting checks during implementation, followed by the repository's required Zig verification. This plan itself makes no code changes and runs no tests.

## 11. Risks and Decisions

| Risk / decision | Proposed direction |
|---|---|
| Exact base commit is currently not represented by the lane runtime contract | Record the fork base at lane creation; do not infer it later from a moving primary branch. If this requires manifest evolution, make it explicit in the migration. |
| Reviewer can mutate source through shell or plugin tools | Enforce a review-specific restricted tool set; prompt-only restrictions are insufficient. |
| Session and review lifetimes differ | Keep review history separate from the one-current-session lane manifest row; retain reviewer session ID on the run. |
| Existing lane cap is driver plus three workers | V1 reuses the target lane slot sequentially; it does not require a fourth lane. |
| Session IDs may be deleted while review records remain | Treat the report and snapshot identity as durable history; nullable reviewer session link is acceptable. |
| Review output may be large or malformed | Apply explicit caps and strict validation; never convert parse failure to an empty/clean report. |
| Lane may be changed after review | Mark the report stale against the new head; do not mutate its original snapshot identity. |

## 12. Definition of Done

- `lane review` reviews one recorded commit range in a fresh reviewer session.
- The reviewer cannot modify the reviewed worktree through the exposed tool surface.
- Review state and report survive restart and interrupted review is not reported as completed.
- Driver receives a structured report associated with the exact base/head snapshot.
- Review never edits, commits, merges, or approves automatically.
- Findings can be routed to the original session or a new session on the same worktree without simultaneous live access.
- A subsequent code change makes the earlier review stale for current HEAD and requires a new review to cover the new snapshot.
