Drive Nova's parallel lane machinery: isolated git worktrees the TUI tiles side-by-side, each with its own branch. A lane is a real checkout of the repo — bash runs inside it with full access; the repo root outside it is out of reach.

## When to use which action

- `lane list` — always a good first step: shows every open lane (id, title, branch, status), your current workspace root, and any parked lanes on disk.
- `lane create {purpose}` — open a NEW idle lane for you to work in. Use it when you need to edit/test/build in isolation without dirtying the main tree: create, `lane enter`, work, `lane leave`, then `lane merge` when done.
- `lane enter {lane}` — re-root your tools into that lane's worktree. After entering, bash/file calls run against the lane checkout and the `@file` mention reads files from the lane. `git` inside is on the lane's branch.
- `lane leave` — return your tools to the repo root (workspace mode is tool scoping; your role is unchanged).
- `lane merge {lane}` — fold a finished lane's branch into the main tree and delete the lane. Merge refuses while you are still entered in it (`lane leave` first) and refuses if the main tree has uncommitted changes (commit or stash first — not a conflict). A merge conflict rolls back cleanly; the lane stays open so you can resolve.
- `lane spawn {task}` — fan out: start an independent worker agent in a fresh lane with the given task. The worker runs on its own thread, concurrently with you; its result arrives as a message. Collect with `lane read {lane}` / `lane await {lane}`, then `lane merge {lane}`.
- `lane read {lane}` — snapshot the tail of a worker lane's conversation (works on running, done, and rested lanes).
- `lane await {lane}` — block until the worker lane is done, then return its transcript. Use it when your next step depends on the worker's result.
- `lane cancel {lane}` — stop a running worker lane immediately.
- `lane steer {lane} {steer}` — inject a short message into a running worker mid-turn (e.g. "keep it small", "use the existing tests").

## Rules

- **Only the driver lane may `spawn`/`enter`/`merge`/`create`/`cancel`/`await`/`steer`.** If you are a spawned worker, you get `list`/`read` only — do your task and hand back a summary; never open lanes yourself.
- **Never run `git worktree add`.** Lanes exist only via `lane create`/`lane spawn`; a worktree Nova does not track is invisible to merge and cleanup.
- **Max 4 lanes.** Spawn sparingly — each worker is a full model stream.
- **`lane merge` refuses while you are entered** in the target lane — `lane leave` first (the tool batch's working directory is still rooted there).
- `lane list` and the workspace ops (`create`/`enter`/`leave`/`merge`) state your current workspace root, so a context that pruned an earlier response cannot lose the fact — run `lane list` whenever unsure.
