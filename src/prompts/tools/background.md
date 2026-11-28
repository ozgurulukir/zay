Query and manage long-running background jobs started with `run_in_background: true` on the shell tool (`bash`/`pwsh`).

## Calling the tool

Every call takes `command` (always required) naming the operation.

| command | required args | optional args | what it does |
|---|---|---|---|
| `list` | — | — | List all currently active/running background jobs (id, label, elapsed duration, command, log path) |
| `status` | `id` | — | Query detailed status, elapsed duration, and recent log output of a currently running background job |
| `cancel` | `id` | — | Request process-tree termination of a running background job |
| `tail` | `id` | `lines` | Read the last output lines from a running job's log file (default 50, capped at 200) |

## Important lifecycle

A successful shell call with `run_in_background: true` is a detached launch, not a request to wait. Zay ends the current turn immediately and automatically injects one completion message (exit status, bounded final tail, and full-log path) when the process exits or is cancelled.

**Wait for the automatic completion message instead of polling with `status`, `list`, or `tail` in the same turn.** Use `status` or `tail` only for an explicit interim inspection requested by the user, or when diagnosing an active job before completion arrives.

## Operational notes

- `list`, `status`, and `tail` inspect active jobs only; completed jobs are removed from the active list once their completion message is queued.
- `tail` is bounded to 200 lines and 64 KiB for interim inspection; use `cancel` when a background build, server, or watcher is no longer needed.
