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

A successful shell call with `run_in_background: true` is a detached launch, not a request to wait. Zay ends the current model turn immediately after the launch result is recorded. When the process exits, Zay automatically injects one completion message containing the exit status and bounded output (plus the full-log path) into the owning lane's context and starts the next turn.

**Do not call `background` with `status`, `list`, or `tail` to wait for a detached job in the same turn.** Do not build a polling loop. The completion message is the source of truth and will arrive automatically. Use `status` or `tail` only for an explicit interim inspection requested by the user, or when diagnosing a job before its completion arrives. Use `cancel` when the user asks to stop the job.

## Operational notes

- Completed jobs are removed from the active-job list after their completion message is queued; a later `status` call may correctly report that no running job exists.
- `tail` is bounded to 200 lines and 64 KiB, and is for interim inspection only; the completion message already includes the bounded final tail.
- Cancelled jobs are also reported through the automatic completion message.

## Best practices

- **Active-only inspection:** `list`, `status`, and `tail` inspect only active jobs. They are not synchronization primitives.
- **Clean termination:** When a background build, server, or watcher is no longer needed, use `cancel` rather than repeatedly checking `status`.
