Drive Nova's parallel lane machinery: isolated git worktrees the TUI tiles side-by-side, each with its own branch. A lane is a real checkout of the repo — bash runs inside it with full access; the repo root outside it is out of reach.

## Calling the tool

Every call takes `command` (always required) naming the operation. Which other arguments a command needs:

| command | required args | what it does |
|---|---|---|
| `list` | — | every open lane (lane id, title, branch, status, activity), your workspace root, parked lanes |
| `create` | `purpose` | open a NEW idle lane for you to work in (the purpose becomes its title) |
| `enter` | `lane` | re-root your tools into that lane's worktree |
| `leave` | — | return your tools to the repo root |
| `merge` | `lane` | fold a finished lane's branch into the main tree and delete the lane |
| `spawn` | `task`, optionally `lane` | start an independent worker agent in a fresh lane, or in an existing idle lane if `lane` is given (the task is its first prompt) |
| `read` | `lane` | snapshot a worker lane's conversation tail + live activity (works on running and done lanes) |
| `cancel` | `lane` | stop a running worker lane immediately |
| `await` | `lane` | block until the worker lane is done (or resolves once if it stalls — no output for 3+ min), then return its transcript |
| `steer` | `lane`, `steer` | inject a short message into a running worker mid-turn |
| `delete` | `lane` | delete an idle or parked lane entirely (worktree + branch) without merging |

The lane id always goes in the `lane` field — `lane list` prints the hex id (e.g. `e1e94861c257`) for each open lane. This tool has no `id` parameter.

Example — spawn a worker: `{"command":"spawn","task":"Review the diff in PR #57 and report findings."}`

## When to use which command

- `lane list` — always a good first step: shows every open lane (lane id, title, branch, status), your current workspace root, and any parked lanes on disk. `read` reports a running worker's activity (tool-call count, time since last output) so you can tell busy from stalled.
- `lane create` — open a NEW idle lane for you to work in. Use it when you need to edit/test/build in isolation without dirtying the main tree: create, `lane enter`, work, `lane leave`, then `lane merge` when done.
- `lane enter` — re-root your tools into that lane's worktree. After entering, bash/file calls run against the lane checkout and the `@file` mention reads files from the lane. `git` inside is on the lane's branch. The re-root applies from your next tool call — including calls later in the same batch as the `enter`.
- `lane leave` — return your tools to the repo root (workspace mode is tool scoping; your role is unchanged).
- `lane merge` — fold a finished lane's branch into the main tree and delete the lane. Merge refuses while you are still entered in it (`lane leave` first) and refuses if the main tree has uncommitted changes (commit or stash first — not a conflict). It also refuses if the lane's own working tree is dirty: commit the lane's work with a real message (`git_commit` or `bash git commit`) before merging. Nova will not fabricate a placeholder commit for you. A merge conflict rolls back cleanly; the lane stays open so you can resolve.
- `lane spawn` — start an independent worker agent in a fresh lane with the given task. The worker runs on its own thread, concurrently with you; its result arrives as a message. Use it two ways: **fan out** (one lane per independent unit — PRs, candidates, scans) or **staged pipelines** (spawn stage 1, await its result, then spawn stage 2 with that result embedded in the task). If `lane` is given, the worker reuses that idle lane's worktree+branch instead of creating a new one — use it to re-task a lane you created with `lane create` or a worker that finished and rested. The lane keeps its transcript; the new turn appends. Every task must be self-contained — exact paths/branches, what to do, what to report — because the worker starts fresh and can't see your reasoning. After spawning, keep working: results arrive as messages, and `lane read` shows progress; only `lane await` when your next step actually needs that worker's result. Never redo a delegated task yourself — your work after spawning is orchestration: other independent units, integration, review. If nothing else remains, `lane await` the worker instead of duplicating its task in the main tree. Collect with `lane read` and `lane await` passing the lane id, then `lane merge` with that id.
- `lane read` — snapshot the tail of a worker lane's conversation (works on running, done, and rested lanes). The status line shows how far a running worker has gotten and flags one silent for 3+ minutes as possibly stalled — cancel it or steer it rather than poll forever.
- `lane await` — block until the worker lane is done, then return its transcript. Use it when your next step depends on the worker's result. If the worker produces nothing for 3+ minutes the wait resolves once with a stall notice so you can `lane cancel` or `lane steer` instead of hanging.
- `lane cancel` — stop a running worker lane immediately.
- `lane steer` — inject a short message into a running worker mid-turn (e.g. "keep it small", "use the existing tests").
- `lane delete` — completely discard an idle or parked lane and its worktree without merging it. Use this when a spawned worker failed and you do not want to keep its work.

## Rules

- **Only the driver lane may `spawn`/`enter`/`merge`/`create`/`cancel`/`await`/`steer`/`delete`.** If you are a spawned worker, you get `list`/`read` only — do your task and hand back a summary; never open lanes yourself.
- **Clean up every lane you spawn.** When a worker finishes — or fails — `lane read` its result, then fold it back with `lane merge`. A completion message that says **FAILED** means the worker did not finish: read the reason and salvage what's useful, then fold it back with `lane merge` if safe, or discard it entirely with `lane delete`. Never leave the lane parked — parked lanes still count toward the 4-lane grid.
- **Never run `git worktree add`.** Lanes exist only via `lane create`/`lane spawn`; a worktree Nova does not track is invisible to merge and cleanup.
- **Max 4 lanes total — the driver's main lane plus 3 workers** (the split grid is 2×2). Fan out deliberately — one lane per independent unit, not a scattergun.
- **`lane merge` refuses while you are entered** in the target lane — `lane leave` first (the tool batch's working directory is still rooted there).
- **Commit lane work before `lane merge`.** A lane with uncommitted changes is refused at merge so Nova never fabricates a placeholder commit. Use `git_commit` (or `bash git commit`) with a meaningful message while entered in the lane, then `lane leave` and `lane merge`.
- `lane list` and the workspace ops (`create`/`enter`/`leave`/`merge`) state your current workspace root, so a context that pruned an earlier response cannot lose the fact — run `lane list` whenever unsure.


## Strategic Workflows (Golden Paths)

Use these patterns to ensure high-quality, low-context-bloat results:

### Scenario A: The "Discovery & Synthesis" (Broad Analysis)
*Goal: Understand a new subsystem without choking your context.*
1. `lane list` $\rightarrow$ Check available slots.
2. `lane spawn` $\rightarrow$ Worker 1: "Analyze module X and list key functions/types."
3. `lane spawn` $\rightarrow$ Worker 2: "Analyze module Y and identify dependencies on X."
4. `lane read` $\rightarrow$ Monitor progress.
5. `lane await` $\rightarrow$ Collect both summaries.
6. **Synthesis:** Combine reports in your main context to form a plan.
7. `lane merge` $\rightarrow$ Clean up.

### Scenario B: The "Safe Iteration" (Critical Change)
*Goal: Implement a feature that requires multiple build/test cycles without dirtying the main branch.*
1. `lane create` (purpose: "feature-x-impl") $\rightarrow$ `lane enter`.
2. **Iterative Loop:** Edit $\rightarrow$ `bash { run_in_background: true }` $\rightarrow$ inspect with `background` tool / await completion $\rightarrow$ Fix.
3. `lane leave` $\rightarrow$ Verify root is clean.
4. `lane merge` $\rightarrow$ Fold verified changes into main.

### Scenario C: The "Review Pipeline" (High Assurance)
*Goal: Ensure code quality before merging.*
1. `lane spawn` $\rightarrow$ Worker 1: "Implement the fix for issue #123 in this branch."
2. `lane await` $\rightarrow$ Get implementation.
3. `lane spawn` $\rightarrow$ Worker 2: "Review the changes made by Worker 1 for edge cases and style."
4. `lane await` $\rightarrow$ Get review.
5. **Final Polish:** Apply review feedback in the isolated lane before the final `lane merge`.
