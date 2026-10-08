# GitNexus Engineering Plan

> Task: Stop Zay from repeatedly loading skill bodies by making skill context explicit, durable, and idempotent across turns, pruning, compaction, and resume.
> Evidence version: commit `4d6031c754e564b7fd3d7c58617f1f511f81ce9c`; GitNexus 1.6.12 index is up to date at that commit; working tree has unrelated dirty paths recorded in §11.

## 1. Objective

Make a skill activation a conversation-scoped fact rather than an ordinary, repeatedly reloaded tool result. A skill requested by `$name` or the model's `skill` tool must be available in full for the remainder of the active branch, must not be injected twice, must survive request-time tool pruning and compaction/resume, and must preserve the provider protocol requirement that every assistant tool call receives one tool result. Existing sessions and old serialized messages must continue to load.

Acceptance criteria:

- A repeated model call for the same skill returns a short deterministic already-loaded observation and does not append a second full body to the ledger.
- A skill body remains available in model context after it becomes older than the normal four-tool-turn / 1,024-byte pruning window.
- Repeated `$skill` mentions do not grow the user message with duplicate skill blocks; the existing user-message persistence and transcript behavior remain compatible.
- Compaction, branch reload, fresh resume, and legacy sessions reconstruct the same activated-skill set or degrade safely when the source skill no longer exists.
- Tool-call/result wire ordering and session serialization remain valid for all providers.
- Tests cover OOM/failure rollback and no-source/legacy fallback paths.

## 2. Current Behaviour

`Skill.body` is loaded once during discovery and the system prompt only publishes skill metadata (`src/skill.zig:159-185`). `$name` expansion is performed in `Agent.addUserPrompt` / `prependSkillBlocks` (`src/agent.zig:329-415`) and the expanded user message is persisted. The model-facing `skill` tool returns the complete cached body (`src/tools/skill.zig:61-108`); `Agent.run` executes a tool batch and `takeToolResults` appends each result as an ordinary `.tool` message (`src/agent.zig:542-724,1293-1319`). Each request reuses the complete cached history, but `pruneHistoricalToolResultsViewsCached` truncates old `.tool` messages (`src/context/assembly.zig:431-489,905-943`) after four tool-result turns by default (`src/context/assembly.zig:76-82`, `src/config/config.zig:149-164`). There is no activated-skill ledger or repeated-call guard.

On resume/runtime reload, persisted messages are projected back into the in-memory `ContextManager` (`src/runtime.zig:320-325,549-559`, `src/context/manager.zig:54-123`); system messages are replaced separately and are not persisted. Session message JSON currently stores only role, call id, display label, failure, and content (`src/session/serialize.zig:17-68`), so a rehydrated tool message does not retain `ToolResult.name`.

## 3. Relevant Architecture

- `Agent` owns the live model loop, skill slice, context manager, pruning cache, and compaction callbacks. It is the narrow runtime owner for activation state, but state must be rebuilt at every projection boundary.
- `ContextManager` owns the cached message projection and dual-writes admitted conversation messages through `SessionWriter`; session history is the durable source of truth.
- `Session` stores branch entries (`message`, `compaction`, and informational kinds). `appendProjectedEntry` turns message entries into `ChatMessage` values and compaction into a summary; a new skill-context entry must be branch-visible without masquerading as a provider message.
- `ToolResult` still carries the tool name until `takeToolResults`; this is the safest current recognition seam and avoids immediately widening `ChatMessage.tool`, which would affect all serializers/providers.
- Generic request views are intentionally borrowed except for pruned historical tool copies. Skill context needs a dedicated retention path, not a larger global cap.

## 4. GitNexus Findings

- `[graph] impact(takeToolResults, upstream, depth=3)` reports 12 impacted symbols, CRITICAL risk, 9 affected processes, and TUI/agent consumers. Edit only with focused tests and rerun detect-changes.
- `[graph] impact(appendPersisted, upstream, depth=3)` reports 35 impacted symbols, CRITICAL risk, 12 affected processes, and six affected modules. Do not change its ordering or persistence-before-cache contract casually.
- `[graph] impact(messageToJson, upstream, depth=3)` reports 27 impacted symbols, HIGH risk; `jsonToMessage` reports 16, HIGH risk. Any compatibility field must be optional and tested against old payloads.
- `[graph] impact(prependSkillBlocks, upstream)` reports HIGH risk and three affected processes; `addUserPrompt` reports CRITICAL risk and 13 processes. Keep the public prompt path and existing ownership semantics stable.
- `[graph] impact(pruneSingleToolMessage, upstream)` reports 21 impacted symbols, CRITICAL risk, and nine affected processes. Prefer a separate skill-aware view/ledger seam over changing generic pruning semantics.
- `[graph] context(Agent.run)` shows the loop builds pruned request views immediately before each provider prompt, so retention must be applied there or in the view builder, not by mutating durable messages.
- `[graph] context(AgentRuntime.reloadMessages)` shows project-first / swap-second rehydration; ledger rebuild must follow the same failure-safe ordering.

## 5. Statement-Level PDG Findings

No PDG layer is present in the pinned GitNexus index. `pdg_query` for `Agent.run` and `takeToolResults` returned `no PDG layer`; no statement-level control/data claims are used. Re-run `node .gitnexus/run.cjs analyze --index-only --pdg --repo .` before implementation if branch-sensitive statement evidence is required.

## 6. Proposed Changes

### 6.1 Add a dedicated skill-context ledger module

Create `src/context/skill_context.zig` as a deep module with a small interface:

- `SkillContext` owns ordered activated entries `{name, body}` and deinitializes all allocations.
- `activate(gpa, name, body)` returns an enum/result distinguishing `.inserted`, `.already_loaded`, and `.replaced` only if an explicit version/body policy requires it. Names compare case-insensitively, matching `skill.find`/`collectInvocations`.
- `contains(name)`, `body(name)`, `clear()`, and `rebuildFromMessages(...)` are the only Agent-facing operations.
- `formatLoadedNotice` creates a bounded deterministic tool observation for repeated calls; it never substitutes for the full ledger body in request assembly.
- `formatRequestViews`/`appendRetainedSkill` (or equivalent) exposes full skill bodies without changing ordinary tool pruning. Keep the model-facing representation protocol-valid and preserve the original `call_id`.

Use the existing `skill.Skill` slice as the canonical source for new activations. Store an owned body copy in the ledger so later discovery refreshes or project switches cannot invalidate an active conversation.

### 6.2 Persist activation state as branch-scoped session metadata

Add a `skill_context` entry kind to the session layer rather than adding `tool_name` to `ai.ChatMessage.tool` initially:

- Add a small JSON serializer/parser for `{ "skills": [{"name":"...", "body":"..."}] }` in `src/context/skill_context.zig` or `src/session/serialize.zig`; unknown fields are ignored and malformed metadata is skipped/reported without corrupting messages.
- Add `SessionWriter.appendSkillContext` that serializes the current ledger and enqueues a non-message entry. It must use the same queue/locking lifecycle as message/compaction writes.
- Add a `Session` active-path projection/read method returning the latest skill-context payload, respecting compaction boundaries and branch ancestry. Do not use whole-tree state: sibling branch activations must not leak into the active branch.
- `Session.messages`/runtime initialization should load the projected metadata alongside messages. `AgentRuntime.reloadMessages` must project both before swapping live state; if either projection fails, preserve the current agent state.
- If adding a new entry-kind query is too invasive, a first implementation may rebuild from active-path message records and persist metadata only at activation; the explicit acceptance test is branch isolation after switching.

Persist the full body, not only the name/path: a resume must work when the skill file is renamed/deleted, while the persisted payload remains bounded by the existing skill-file cap. Define a ledger byte cap and deterministic oldest-entry policy if the project can activate many skills; never silently exceed the cap.

### 6.3 Make model and inline activation idempotent

At the `Agent` seam:

- Add `skill_context: context.SkillContext` to `Agent`, initialize/deinit with Agent lifetime, and clear/rebuild it with `clearNonSystemMessages`, `replaceConversation`, runtime initialization, branch switching, and successful compaction reload.
- In `addUserPrompt`, collect `$name` tokens in order, activate each body once, and build the current user message from only newly activated names. Preserve the existing marker format so transcript resume/UI parsing remains compatible; repeated mentions may remain in raw text but must not duplicate full instruction blocks.
- In `takeToolResults`, inspect `ToolResult.name == "skill"` and parse the requested name from the tool call/result correlation available in the current batch. Activate the canonical skill body before moving the result; repeated calls get an already-loaded notice while the original full body remains in the ledger. If parsing/canonical lookup fails, retain the existing tool output and do not mark the skill loaded.
- Keep one `.tool` message per assistant call. Do not drop or merge repeated tool calls, because providers require call/result pairing and assistant history must remain replayable.
- Add a model-visible loaded-skill inventory to the base system prompt only if it is generated from the ledger at request time without duplicating bodies; otherwise the deterministic already-loaded observation is sufficient.

### 6.4 Make request assembly and compaction skill-aware

- Extend the request-view builder in `src/context/assembly.zig` with an optional skill ledger/recognizer. Ordinary `.tool` messages keep the existing cap and cache behavior.
- For a historical skill result, return either the original full body or a ledger-owned full replacement with the same tool identity/content shape. It must be released safely by `freePrunedViews`, and it must not mutate `ContextManager` history.
- Update `estimatePrunedTokensRange` to count retained skill bodies so automatic compaction does not undercount the request actually sent.
- Update `context/compaction.zig` serialization so a compaction summary records that a skill was activated and where its durable ledger entry lives, but does not duplicate every large body into the summary. The skill-context entry remains the source of full instructions.
- Do not change global defaults merely to mask this bug. `keepRecentToolTurns` and `historicalToolCapBytes` remain normal-tool controls.

### 6.5 Legacy and failure compatibility

- On old sessions without `skill_context`, rebuild a best-effort ledger by scanning active-path user text for `<skill name="...">` markers and scanning adjacent assistant tool calls/results where the tool name can be inferred from persisted display labels or the returned body. Resolve names against current loaded skills; use persisted body text only when a safe marker/body pair exists.
- If reconstruction is ambiguous, leave the legacy messages untouched and let the model call the skill once; never fabricate a skill name from arbitrary tool output.
- If skill-context persistence fails after the message is admitted, surface the session write failure using existing writer error behavior and keep the in-memory ledger consistent with the admitted conversation. Avoid a half-activated state by persisting metadata before the user/tool message only when the writer contract can roll back; otherwise mark metadata dirty and retry at the next safe boundary.
- Branch switches and compaction swaps must atomically replace message history and ledger state from the same active projection. A failed rebuild leaves both old projections intact.

## 7. Implementation Sequence

1. **Ledger seam and pure tests.** Add `src/context/skill_context.zig`; define ownership, case-insensitive names, deterministic ordering, byte cap, idempotent activation, repeated notice, serialization, and malformed-payload behavior. Do not touch provider code yet.
2. **Session metadata contract.** Add `skill_context` entry kind, serializer/parser, `SessionWriter.appendSkillContext`, active-path projection, and runtime initialization/reload plumbing. Add old-payload and branch-isolation tests before Agent integration.
3. **Agent activation.** Add the ledger to `Agent`; thread a stable skill-context pointer through `addUserPrompt`, `takeToolResults`, `takeMessage`, `clearNonSystemMessages`, and reload/compaction paths. Preserve persistence-before-cache ordering. This step has CRITICAL impact at `takeToolResults`; stop and inspect failures before proceeding.
4. **Tool-call correlation.** Add a narrow helper that maps a completed `skill` ToolResult to its requested name using the assistant tool call in the active batch. If correlation is not reliable, extend only the persisted metadata path—not `ChatMessage.tool`—and retain current tool output rather than guessing.
5. **Request/compaction retention.** Make `pruneHistoricalToolResultsViewsCached` and `estimatePrunedTokensRange` ledger-aware. Add retained skill views without changing ordinary tool behavior, cache invalidation, or provider serializer contracts. Include the ledger in compaction/reload tests.
6. **Inline `$skill` behavior and UI.** Ensure prompt-prefix generation accepts a set of already-activated names and does not duplicate bodies. Keep `collectInjectedSkillNames` and transcript reconstruction compatible; add a test that repeated resume rebuilds exactly one visible skill row per intended injection.
7. **Full verification and change gate.** Run `zig fmt` on changed Zig files, `zig build test`, focused tests if available, `node .gitnexus/run.cjs detect-changes --scope all --repo .`, and inspect every changed symbol/risk. Do not modify or stage the user’s unrelated dirty paths.

## 8. Test Strategy

Update/add tests in the nearest existing files:

- `src/context/skill_context.zig`: activate `name` twice → one entry and `.already_loaded`; body retained after ordinary cap; deterministic ordering; byte-cap rejection/eviction; malformed/unknown persisted payload; OOM leaves prior ledger intact.
- `src/skill.zig`: repeated `$how $HOW` in one prompt → one prefix body; pre-activated `how` → no duplicate body; disabled model-invocation behavior unchanged.
- `src/session/serialize.zig` or `src/context/skill_context.zig`: round-trip metadata JSON; old message JSON without metadata; unknown fields; malformed metadata errors are non-destructive.
- `src/session.zig` / `src/session/writer.zig`: latest metadata on active path wins; sibling branch metadata is excluded; compaction boundary projects the correct ledger; writer failure does not advance the in-memory projection.
- `src/agent.zig`: scripted model calls `skill` twice → two protocol tool results, first full body registered, second short already-loaded observation, one ledger entry, and full retained request view on later prompt.
- `src/context/assembly.zig`: old skill tool message under pruning cutoff remains full in request view; normal tool message is still capped; owned retained views are freed; token estimator includes retained body.
- `src/context/compaction.zig` / `src/agent.zig`: compaction summary plus skill metadata reload → skill remains available without reloading; failed compaction leaves old ledger/history untouched.
- `src/runtime.zig`, `src/tui/session_switcher.zig`, and `src/tui/transcript_lifecycle.zig`: resume/branch switch restores ledger and existing transcript rows; no duplicate skill UI rows.
- Failure paths: missing skill file, malformed old metadata, session writer error, OOM during activation/persistence, and provider cancellation all preserve protocol-valid history and do not falsely mark a skill active.

## 9. Risk and Impact Analysis

- `takeToolResults` — `[graph]` CRITICAL, 12 impacted symbols, nine processes. Direct consumers include the turn loop and tool-result event/history path; verify ownership and error cleanup after every change.
- `appendPersisted` — `[graph]` CRITICAL, 35 impacted symbols, 12 processes. Preserve writer-first admission and cache update ordering; do not make metadata writes bypass this contract.
- `messageToJson` / `jsonToMessage` — `[graph]` HIGH, 27 / 16 impacted symbols. Prefer a separate metadata payload; if message schema changes become unavoidable, add optional fields and backward-compatible parsing tests.
- `prependSkillBlocks` / `addUserPrompt` — `[graph]` HIGH / CRITICAL. Keep raw prompt, file expansion, and ownership behavior unchanged except for deduplication of skill blocks.
- `pruneSingleToolMessage` — `[graph]` CRITICAL. Avoid modifying its generic head/tail policy; add a narrow skill-aware branch in the view builder and test both categories.
- Existing working tree changes are unrelated (`AGENTS.md` and four `docs/plugins/*.md` files); the implementation must not overwrite, format, or include them in feature commits.
- Current index has no PDG layer, so branch/data-flow constraints are not statement-proven. The plan explicitly requires conservative source-level ownership and a post-change graph check.

## 10. Files Expected to Change

- `src/context/skill_context.zig` — new ledger, activation, serialization, request-retention helpers, and pure tests.
- `src/agent.zig` — Agent-owned ledger, inline/model activation, repeated notices, rebuild/reset hooks, and request-view integration.
- `src/skill.zig` — expose a safe canonical-name/body lookup and allow prompt-prefix generation to skip already active names.
- `src/tools/skill.zig` — add a bounded, stable already-loaded response contract only if Agent-side replacement cannot preserve output ownership; keep tool API/schema unchanged.
- `src/context/assembly.zig` — optional ledger-aware view retention and token estimation; preserve generic pruning cache.
- `src/context/compaction.zig` — summary/ledger boundary accounting without body duplication.
- `src/context/manager.zig` — projection/reset seam if ledger state is kept alongside the message cache.
- `src/runtime.zig` — load/reload ledger with messages and refresh it after project/session switches.
- `src/session/types.zig` — add metadata entry kind/record helper only if needed by the selected session API.
- `src/session/serialize.zig` — metadata payload round-trip helpers; message payload remains backward-compatible.
- `src/session.zig` — active-path `skill_context` projection and branch/compaction semantics.
- `src/session/writer.zig` — enqueue durable skill-context metadata with existing failure/quiesce semantics.
- `src/ai.zig` — only if request-view metadata needs a new explicit view variant; prefer no change.
- `src/tui/session_switcher.zig`, `src/tui/transcript_lifecycle.zig`, `src/tui/queue.zig` — only where reload/inline activation needs explicit ledger reset or duplicate-row tests; avoid UI behavior changes.
- `src/agent/compactor.zig`, `src/context/auto_compactor.zig` — only if compaction result needs explicit ledger transfer; prefer existing `swapHistory` seam.
- `docs/SKILLS.md`, `docs/config/ui-and-context.md`, and `docs/PATTERNS.md` — document idempotence, retention, persistence, and the distinction between normal tool pruning and skill context after implementation.

## 11. Reusable Implementation Context

```yaml
implementation_context:
  task_summary: >-
    Add a durable Agent-owned skill-context ledger and session metadata projection;
    make `$skill` and model `skill` activation idempotent; retain full activated
    bodies outside generic historical tool pruning; preserve protocol pairing,
    compaction, branch reload, resume, legacy sessions, and existing UI behavior.
  acceptance_criteria:
    - repeated model skill calls produce one full ledger entry and short repeat notices
    - old skill context remains full after normal tool pruning
    - repeated inline mentions do not duplicate injected bodies
    - compaction, resume, reload, and branch switches preserve the active ledger
    - old sessions and message payloads remain readable
    - every tool call still has exactly one protocol result
    - OOM and persistence failures leave consistent state
  evidence_provenance: {
  "schema_version": 2,
  "head_commit": "4d6031c754e564b7fd3d7c58617f1f511f81ce9c",
  "generated_plan_path": "docs/plans/2026-10-07-gitnexus-plan-skill-context-retention.md",
  "global_dirty_digest": {
    "algorithm": "sha256",
    "canonicalization": "gitnexus-evidence-provenance-v2 NUL-framed UTF-8 records",
    "value": "cf95744e96db8566afd13f031eb8b7a3452a75ac7b13468a4645e7e432f7ae65"
  },
  "cited_path_manifest": [
    {
      "path": "AGENTS.md",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "unstaged",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:6f549eb9d24250309eade7ea84b881749225703afbbd527686a20f84c4de7ef5",
      "index_digest": "sha256:6f549eb9d24250309eade7ea84b881749225703afbbd527686a20f84c4de7ef5",
      "worktree_digest": "sha256:057e253402ebe1259f6d833935b60844420115b32a205c28ecf545f7a4f2d824",
      "untracked_digest": "absent"
    },
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
      "path": "docs/PATTERNS.md",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:14bf22a7660547a6f862bf39f4a5fca3c9f05d994fafa7d78b48793e5e4feae0",
      "index_digest": "sha256:14bf22a7660547a6f862bf39f4a5fca3c9f05d994fafa7d78b48793e5e4feae0",
      "worktree_digest": "sha256:14bf22a7660547a6f862bf39f4a5fca3c9f05d994fafa7d78b48793e5e4feae0",
      "untracked_digest": "absent"
    },
    {
      "path": "docs/SKILLS.md",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:b1369c32c315ea4bc63320420522d74e50f574d353e803ac31d1e427e6979cc4",
      "index_digest": "sha256:b1369c32c315ea4bc63320420522d74e50f574d353e803ac31d1e427e6979cc4",
      "worktree_digest": "sha256:b1369c32c315ea4bc63320420522d74e50f574d353e803ac31d1e427e6979cc4",
      "untracked_digest": "absent"
    },
    {
      "path": "docs/config/ui-and-context.md",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:4830dbdc83944f27ba8d13bfb07493f8d57deec9ba715cae94945e2195a6a86a",
      "index_digest": "sha256:4830dbdc83944f27ba8d13bfb07493f8d57deec9ba715cae94945e2195a6a86a",
      "worktree_digest": "sha256:4830dbdc83944f27ba8d13bfb07493f8d57deec9ba715cae94945e2195a6a86a",
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
      "head_digest": "sha256:ebeae71df550b68813fdb2bb5912337e6bd7aa553af51f72c42454415ac72e90",
      "index_digest": "sha256:ebeae71df550b68813fdb2bb5912337e6bd7aa553af51f72c42454415ac72e90",
      "worktree_digest": "sha256:ebeae71df550b68813fdb2bb5912337e6bd7aa553af51f72c42454415ac72e90",
      "untracked_digest": "absent"
    },
    {
      "path": "src/ai.zig",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:19e1d9114fb92e831ff05124fa6bcd7ac27bb584ef1750c790fe0f90e1a49728",
      "index_digest": "sha256:19e1d9114fb92e831ff05124fa6bcd7ac27bb584ef1750c790fe0f90e1a49728",
      "worktree_digest": "sha256:19e1d9114fb92e831ff05124fa6bcd7ac27bb584ef1750c790fe0f90e1a49728",
      "untracked_digest": "absent"
    },
    {
      "path": "src/context/assembly.zig",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:5b3b577475f07bf9249f97afa2f7b62ade3186d671a2d6ae00c2611e6a897192",
      "index_digest": "sha256:5b3b577475f07bf9249f97afa2f7b62ade3186d671a2d6ae00c2611e6a897192",
      "worktree_digest": "sha256:5b3b577475f07bf9249f97afa2f7b62ade3186d671a2d6ae00c2611e6a897192",
      "untracked_digest": "absent"
    },
    {
      "path": "src/context/compaction.zig",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:b049badc5c90bad8bbb79a347e505aeae669732b0051fa85a35c3f5b706c5a55",
      "index_digest": "sha256:b049badc5c90bad8bbb79a347e505aeae669732b0051fa85a35c3f5b706c5a55",
      "worktree_digest": "sha256:b049badc5c90bad8bbb79a347e505aeae669732b0051fa85a35c3f5b706c5a55",
      "untracked_digest": "absent"
    },
    {
      "path": "src/context/manager.zig",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:cc2e225f53dfe51451ddebd00848021dd0855aa1cba8ec503594ab2a05f452e7",
      "index_digest": "sha256:cc2e225f53dfe51451ddebd00848021dd0855aa1cba8ec503594ab2a05f452e7",
      "worktree_digest": "sha256:cc2e225f53dfe51451ddebd00848021dd0855aa1cba8ec503594ab2a05f452e7",
      "untracked_digest": "absent"
    },
    {
      "path": "src/executor.zig",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:7eca3d7feee5a607a42859d913d838393048c2962292202a06ac79b7bcc29ad9",
      "index_digest": "sha256:7eca3d7feee5a607a42859d913d838393048c2962292202a06ac79b7bcc29ad9",
      "worktree_digest": "sha256:7eca3d7feee5a607a42859d913d838393048c2962292202a06ac79b7bcc29ad9",
      "untracked_digest": "absent"
    },
    {
      "path": "src/runtime.zig",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:f2ef402d442ad538e425e67864a8a8d2108587f479b7f9b2d225742a2d916c2d",
      "index_digest": "sha256:f2ef402d442ad538e425e67864a8a8d2108587f479b7f9b2d225742a2d916c2d",
      "worktree_digest": "sha256:f2ef402d442ad538e425e67864a8a8d2108587f479b7f9b2d225742a2d916c2d",
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
      "head_digest": "sha256:9a66c92c591309b8da72e88662690ffc73999e0547975b7866a3328ab5738cff",
      "index_digest": "sha256:9a66c92c591309b8da72e88662690ffc73999e0547975b7866a3328ab5738cff",
      "worktree_digest": "sha256:9a66c92c591309b8da72e88662690ffc73999e0547975b7866a3328ab5738cff",
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
    },
    {
      "path": "src/session/writer.zig",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:658244bf6438c1f45294c65cdd3762ae5258825818a1d86b6e2436cf27785730",
      "index_digest": "sha256:658244bf6438c1f45294c65cdd3762ae5258825818a1d86b6e2436cf27785730",
      "worktree_digest": "sha256:658244bf6438c1f45294c65cdd3762ae5258825818a1d86b6e2436cf27785730",
      "untracked_digest": "absent"
    },
    {
      "path": "src/skill.zig",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:3907aa2168e45583466d990fdde44a012f36a565c889109ee717eae0dc7a922c",
      "index_digest": "sha256:3907aa2168e45583466d990fdde44a012f36a565c889109ee717eae0dc7a922c",
      "worktree_digest": "sha256:3907aa2168e45583466d990fdde44a012f36a565c889109ee717eae0dc7a922c",
      "untracked_digest": "absent"
    },
    {
      "path": "src/tools/skill.zig",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:61b491c3acbbc2f42f6a5ac6d98d2df7bd643e0b06051a022849feecb8cb06ae",
      "index_digest": "sha256:61b491c3acbbc2f42f6a5ac6d98d2df7bd643e0b06051a022849feecb8cb06ae",
      "worktree_digest": "sha256:61b491c3acbbc2f42f6a5ac6d98d2df7bd643e0b06051a022849feecb8cb06ae",
      "untracked_digest": "absent"
    },
    {
      "path": "src/tui/agent_worker.zig",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:b83ba797b938ad4a4b96ae5cb119d5c66f8698c043beb2f99de0c74c08d65bbb",
      "index_digest": "sha256:b83ba797b938ad4a4b96ae5cb119d5c66f8698c043beb2f99de0c74c08d65bbb",
      "worktree_digest": "sha256:b83ba797b938ad4a4b96ae5cb119d5c66f8698c043beb2f99de0c74c08d65bbb",
      "untracked_digest": "absent"
    },
    {
      "path": "src/tui/queue.zig",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:89ddaad98b478c80183f1b4b28cd425bb5a8341d1cc428ad751b93a3fac2520d",
      "index_digest": "sha256:89ddaad98b478c80183f1b4b28cd425bb5a8341d1cc428ad751b93a3fac2520d",
      "worktree_digest": "sha256:89ddaad98b478c80183f1b4b28cd425bb5a8341d1cc428ad751b93a3fac2520d",
      "untracked_digest": "absent"
    },
    {
      "path": "src/tui/session_switcher.zig",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:6ced07fb1d9501d64c6188e5885d90539ef49455da8be7d946c8810fd0a59b96",
      "index_digest": "sha256:6ced07fb1d9501d64c6188e5885d90539ef49455da8be7d946c8810fd0a59b96",
      "worktree_digest": "sha256:6ced07fb1d9501d64c6188e5885d90539ef49455da8be7d946c8810fd0a59b96",
      "untracked_digest": "absent"
    },
    {
      "path": "src/tui/transcript_lifecycle.zig",
      "object_kind": {
        "head": "regular",
        "index": "regular",
        "worktree": "regular",
        "untracked": "absent"
      },
      "state": "clean",
      "rename_from": null,
      "rename_to": null,
      "head_digest": "sha256:63a2bb90bb1fdabdd5a08a8604812b11b735325bfb3ed1c1284fa293ae0fc227",
      "index_digest": "sha256:63a2bb90bb1fdabdd5a08a8604812b11b735325bfb3ed1c1284fa293ae0fc227",
      "worktree_digest": "sha256:63a2bb90bb1fdabdd5a08a8604812b11b735325bfb3ed1c1284fa293ae0fc227",
      "untracked_digest": "absent"
    }
  ]
}
  primary_symbols:
    - symbol: Agent.takeToolResults
      file: src/agent.zig
      lines: "1293-1319"
      role: recognize skill results and admit protocol messages
    - symbol: Agent.addUserPrompt
      file: src/agent.zig
      lines: "329-415"
      role: inline activation and prompt-prefix ownership
    - symbol: Agent.run
      file: src/agent.zig
      lines: "542-724"
      role: request loop and pruned view boundary
    - symbol: pruneHistoricalToolResultsViewsCached
      file: src/context/assembly.zig
      lines: "431-489"
      role: normal tool pruning and skill-retention seam
    - symbol: Session.messages
      file: src/session.zig
      lines: "1040-1130"
      role: active-path message projection
    - symbol: AgentRuntime.reloadMessages
      file: src/runtime.zig
      lines: "549-559"
      role: failure-safe history reload
  related_symbols:
    - symbol: ToolResult
      relationship: CALLS/data source
      relevance: retains tool name before conversion to ChatMessage
    - symbol: SessionWriter.append
      relationship: persistence contract
      relevance: writer-first message admission
    - symbol: messageToJson/jsonToMessage
      relationship: serialization
      relevance: preserve old message payloads; avoid widening unless necessary
    - symbol: ContextManager.replaceConversation
      relationship: reload/compaction
      relevance: atomic cache replacement
    - symbol: skill.promptPrefix
      relationship: CALLS
      relevance: inline body insertion and duplicate suppression
  execution_path:
    - worker turn calls AgentRuntime.refreshSystemPrompt before user history changes
    - Agent.addUserPrompt expands files and currently prepends every `$skill` body
    - Agent.run builds request views and calls the provider
    - tool calls execute through ExecutorService and produce ToolResult.name/content
    - Agent.takeToolResults persists each `.tool` result and currently discards tool-name identity
    - later request views prune old tool results to the generic configured cap
    - session/runtime reload projects messages but has no skill ledger today
  pdg_constraints:
    - description: No PDG layer exists in the pinned index; no CDG or reaching-definition evidence was available.
      affected_statements: []
      implementation_consequence: Re-verify ownership and ordering with source/tests; optionally re-index with --pdg before implementation.
  architectural_patterns:
    - pattern: persistence precedes cache update
      example_location: src/context/manager.zig:appendPersisted
      usage_guidance: metadata admission must not leave cache ahead of durable state
    - pattern: project first, swap second
      example_location: src/runtime.zig:AgentRuntime.reloadMessages
      usage_guidance: rebuild messages and ledger before replacing live state
    - pattern: borrowed request views with owned pruned copies
      example_location: src/context/assembly.zig:PrunedToolCache
      usage_guidance: retain skill bodies without mutating durable messages; free owned views exactly once
    - pattern: union(enum) protocol messages
      example_location: src/ai.zig:ChatMessage
      usage_guidance: avoid adding a new message variant unless provider serializers and resume projection are updated together
  files_to_modify:
    - file: src/context/skill_context.zig
      symbols: [SkillContext]
      intended_change: New deep ledger module, bounded owned entries, idempotent activation, metadata serialization, and tests.
    - file: src/agent.zig
      symbols: [Agent.addUserPrompt, Agent.takeToolResults, Agent.run, Agent.takeMessage, Agent.clearNonSystemMessages]
      intended_change: Own/rebuild ledger, recognize activations, deduplicate, persist metadata, and pass retention state to request assembly.
    - file: src/skill.zig
      symbols: [promptPrefix, collectInvocations, find]
      intended_change: Canonical lookup and skip-already-active prefix support.
    - file: src/context/assembly.zig
      symbols: [pruneHistoricalToolResultsViewsCached, estimatePrunedTokensRange, freePrunedViews]
      intended_change: Preserve full skill observations separately from normal tool pruning.
    - file: src/session/serialize.zig
      symbols: [skillContextToJson, jsonToSkillContext]
      intended_change: Optional metadata payload serializer/parser; keep message JSON compatible.
    - file: src/session/writer.zig
      symbols: [SessionWriter.appendSkillContext]
      intended_change: Durable queued metadata entry using existing writer lifecycle.
    - file: src/session.zig
      symbols: [Session.messages, active-path projection helpers]
      intended_change: Project latest branch-scoped skill metadata and honor compaction boundaries.
    - file: src/runtime.zig
      symbols: [AgentRuntime.initSession, AgentRuntime.reloadMessages]
      intended_change: Load/swap ledger together with message history.
    - file: src/context/manager.zig
      symbols: [ContextManager.replaceConversation, clearNonSystem]
      intended_change: Reset/invalidation seam if ledger cache is colocated with projection.
    - file: src/skill.zig
      symbols: [tests]
      intended_change: Regression tests for repeated inline expansion.
  tests:
    - file: src/context/skill_context.zig
      scenarios: ["activate same name twice -> one full body and already_loaded", "serialize/parse -> same ordered ledger", "malformed/oversized input -> old ledger unchanged", "OOM -> no partial activation"]
    - file: src/agent.zig
      scenarios: ["scripted skill call twice -> two tool results, one ledger entry, second short notice", "old skill result beyond cutoff -> later request still sees full body", "inline $skill twice -> one injected body"]
    - file: src/context/assembly.zig
      scenarios: ["skill tool result before cutoff -> full retained view", "ordinary old tool -> existing cap", "owned retained views free without mutating history"]
    - file: src/session.zig
      scenarios: ["active branch metadata wins over sibling", "compaction boundary retains ledger", "legacy session without metadata reconstructs safely"]
    - file: src/session/serialize.zig
      scenarios: ["metadata round-trip", "old message JSON remains readable", "unknown metadata fields ignored"]
    - file: src/runtime.zig
      scenarios: ["reload failure preserves old messages and ledger", "successful resume restores persisted body"]
    - file: src/tui/session_switcher.zig
      scenarios: ["branch switch does not leak skill activation or duplicate transcript rows"]
  verification_commands:
    - zig fmt src/context/skill_context.zig src/agent.zig src/skill.zig src/context/assembly.zig src/context/compaction.zig src/context/manager.zig src/runtime.zig src/session.zig src/session/serialize.zig src/session/types.zig src/session/writer.zig src/tools/skill.zig
    - zig build test
    - node .gitnexus/run.cjs detect-changes --scope all --repo .
    - node .gitnexus/run.cjs status
  risks:
    - takeToolResults and appendPersisted are CRITICAL graph-impact seams; preserve ownership and persistence ordering.
    - message serializers are HIGH impact; prefer separate metadata entries and optional parsing.
    - a skill tool call name is not retained in ChatMessage.tool after persistence; correlate before conversion or use explicit metadata.
    - no PDG layer is available in the pinned index.
  assumptions:
    - skill bodies are bounded by the existing 256 KiB loader cap and can be persisted with an explicit aggregate ledger cap.
    - metadata entry projection can be made branch-scoped without changing the existing message protocol.
    - current skill discovery remains available for new activations; persisted bodies cover missing-source resumes.
  open_questions:
    - choose the exact aggregate skill-context byte cap and eviction/error policy.
    - choose whether repeated model calls return a short notice at execution time or are represented as a retained full view while preserving tool history.
    - decide whether legacy reconstruction can safely infer model-loaded skills or should only trust explicit inline markers.
  avoid:
    - do not alter generic historical tool pruning defaults to mask skill loss
    - do not drop repeated tool calls or violate one-call/one-result protocol pairing
    - do not extend ChatMessage.tool or provider serializers unless a separate metadata entry cannot meet branch/resume requirements
    - do not overwrite or stage AGENTS.md or the unrelated docs/plugins files
    - do not run worker lanes; implement in the primary workspace only
  generated_plan_path: docs/plans/2026-10-07-gitnexus-plan-skill-context-retention.md
```

## 12. Assumptions and Open Questions

Assumptions:

- The session tree can represent a new informational `skill_context` entry without changing database schema; existing `kind` is string-valued and compaction already uses non-message kinds. `[verified] src/session/types.zig:217-229`, `[verified] src/session.zig:1284-1293`
- Skill bodies remain bounded by the current loader cap, but an aggregate ledger cap is still required to prevent a conversation from growing without bound. `[verified] src/skill.zig:31-33,506-511`, `[inferred]`
- Persisted metadata can be projected branch-scoped using the existing active-path entry walk. `[verified] src/session.zig:1225-1239,1284-1319`, `[inferred]`

Open questions:

- Should the ledger persist every activated body or only names plus a content digest, with current files as the source? The plan chooses full bodies for robust resume, but implementation should measure payload limits and define an aggregate cap.
- How should a repeated model call be represented? Preferred behavior is one protocol result per call with a short already-loaded observation, while full instructions stay in the ledger-aware request view.
- Can legacy model-loaded skills be inferred safely? Only explicit inline markers and strongly correlated `skill` calls should activate; ambiguous historical tool text must not.
- Should metadata persistence happen before or after the corresponding message? The existing writer is asynchronous and append-only, so implementation must define a recovery order and test writer failure rather than assuming rollback.

## 13. Definition of Done

- [ ] Ledger module and tests exist with explicit ownership, cap, idempotence, and serialization contracts.
- [ ] New and resumed sessions persist/project skill context branch-locally.
- [ ] `$skill` and model `skill` activation are idempotent and do not duplicate full bodies.
- [ ] Full activated bodies survive ordinary pruning and compaction/reload.
- [ ] Provider tool-call/result pairing remains valid.
- [ ] Legacy sessions and missing-skill files degrade safely.
- [ ] `zig fmt` and `zig build test` pass.
- [ ] GitNexus detect-changes is complete/non-truncated and reviewed.
- [ ] Unrelated pre-existing worktree changes remain untouched.
