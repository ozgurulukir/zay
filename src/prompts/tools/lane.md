Drive Nova's parallel lane machinery: isolated git worktrees the TUI tiles side-by-side, each with its own branch. A lane is a real checkout of the repo — bash runs inside it with full access; the repo root outside it is out of reach.

## Calling the tool

Every call takes `command` (always required) naming the operation. Which other arguments a command needs:

| command | required args | what it does |
|---|---|---|
| `list` | — | every open lane (id, title, branch, status, activity), your workspace root, parked lanes |
| `create` | `purpose` | open a NEW idle lane for you to work in (the purpose becomes its title) |
| `enter` | `lane` | re-root your tools into that lane's worktree |
| `leave` | — | return your tools to the repo root |
| `merge` | `lane` | fold a finished lane's branch into the main tree and delete the lane |
| `spawn` | `task`, optionally `lane` | start an independent worker agent in a fresh lane, or in an existing idle lane if `lane` is given (the task is its first prompt) |
| `read` | `lane` | snapshot a worker lane's conversation tail + live activity (works on running and done lanes) |
| `cancel` | `lane` | stop a running worker lane immediately |
| `await` | `lane` | block until the worker lane is done (or resolves once if it stalls — no output for 3+ min), then return its transcript |
| `steer` | `lane`, `steer` | inject a short message into a running worker mid-turn |

Example — spawn a worker: `{"command":"spawn","task":"Review the diff in PR #57 and report findings."}`

## When to use which command

- `lane list` — always a good first step: shows every open lane (id, title, branch, status), your current workspace root, and any parked lanes on disk. `read` reports a running worker's activity (tool-call count, time since last output) so you can tell busy from stalled.
- `lane create` — open a NEW idle lane for you to work in. Use it when you need to edit/test/build in isolation without dirtying the main tree: create, `lane enter`, work, `lane leave`, then `lane merge` when done.
- `lane enter` — re-root your tools into that lane's worktree. After entering, bash/file calls run against the lane checkout and the `@file` mention reads files from the lane. `git` inside is on the lane's branch. The re-root applies from your next tool call — including calls later in the same batch as the `enter`.
- `lane leave` — return your tools to the repo root (workspace mode is tool scoping; your role is unchanged).
- `lane merge` — fold a finished lane's branch into the main tree and delete the lane. Merge refuses while you are still entered in it (`lane leave` first) and refuses if the main tree has uncommitted changes (commit or stash first — not a conflict). A merge conflict rolls back cleanly; the lane stays open so you can resolve.
- `lane spawn` — start an independent worker agent in a fresh lane with the given task. The worker runs on its own thread, concurrently with you; its result arrives as a message. Use it two ways: **fan out** (one lane per independent unit — PRs, candidates, scans) or **staged pipelines** (spawn stage 1, await its result, then spawn stage 2 with that result embedded in the task). If `lane` is given, the worker reuses that idle lane's worktree+branch instead of creating a new one — use it to re-task a lane you created with `lane create` or a worker that finished and rested. The lane keeps its transcript; the new turn appends. Every task must be self-contained — exact paths/branches, what to do, what to report — because the worker starts fresh and can't see your reasoning. After spawning, keep working: results arrive as messages, and `lane read` shows progress; only `lane await` when your next step actually needs that worker's result. Never redo a delegated task yourself — your work after spawning is orchestration: other independent units, integration, review. If nothing else remains, `lane await` the worker instead of duplicating its task in the main tree. Collect with `lane read {lane}` / `lane await {lane}`, then `lane merge {lane}`.
- `lane read` — snapshot the tail of a worker lane's conversation (works on running, done, and rested lanes). The status line shows how far a running worker has gotten and flags one silent for 3+ minutes as possibly stalled — cancel it or steer it rather than poll forever.
- `lane await` — block until the worker lane is done, then return its transcript. Use it when your next step depends on the worker's result. If the worker produces nothing for 3+ minutes the wait resolves once with a stall notice so you can `lane cancel` or `lane steer` instead of hanging.
- `lane cancel` — stop a running worker lane immediately.
- `lane steer` — inject a short message into a running worker mid-turn (e.g. "keep it small", "use the existing tests").

## Rules

- **Only the driver lane may `spawn`/`enter`/`merge`/`create`/`cancel`/`await`/`steer`.** If you are a spawned worker, you get `list`/`read` only — do your task and hand back a summary; never open lanes yourself.
- **Clean up every lane you spawn.** When a worker finishes — or fails — `lane read` its result, then fold it back with `lane merge`. A completion message that says **FAILED** means the worker did not finish: read the reason and salvage what's useful, but never leave the lane parked — parked lanes still count toward the 4-lane grid.
- **Never run `git worktree add`.** Lanes exist only via `lane create`/`lane spawn`; a worktree Nova does not track is invisible to merge and cleanup.
- **Max 4 lanes total — the driver's main lane plus 3 workers** (the split grid is 2×2). Fan out deliberately — one lane per independent unit, not a scattergun.
- **`lane merge` refuses while you are entered** in the target lane — `lane leave` first (the tool batch's working directory is still rooted there).
- `lane list` and the workspace ops (`create`/`enter`/`leave`/`merge`) state your current workspace root, so a context that pruned an earlier response cannot lose the fact — run `lane list` whenever unsure.
