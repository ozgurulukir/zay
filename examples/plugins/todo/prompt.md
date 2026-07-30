---
description: todo.txt-format task tracker with detailed plans — plan, track, and complete multi-step work without polluting context.
---

Use the `todo` plugin to track multi-step work. The todo list lives in
`.nova/todos.txt` (todo.txt format) so it survives restarts and you can edit it
in any text editor. Detailed per-task plans live in a sidecar
`.nova/todos/plans.json`, keyed by a stable `id:N` tag, and are loaded lazily so
they never bloat the task list.

## When to use the todo tools

Use the todo tools **proactively** when the user's request requires 3 or more
distinct steps. A single conceptual step that needs a few tool calls does NOT
need a todo list. When in doubt, use it.

## Context hygiene (important)

The task list and the detailed plans are **deliberately separated**:

- `todo_list` stays compact: each task is one line, plus a `[plan:N steps]`
  marker when a plan exists. Plan bodies (summaries, checklists, notes) are
  NEVER included in `todo_list` output.
- Plan bodies are fetched on demand with `todo_get_plan`. Call it for the ONE
  task you are actively working on — not for every task.

This separation keeps context small: a 16-task list costs one short line each,
and you only pull a plan into context when you actually need its steps.

## Tools

### List operations

- `lua__todo__todo_list` — Show the current list (open tasks, sorted by
  priority then date, overdue items flagged, `[plan:N steps]` markers). Call
  this FIRST to see current state.
- `lua__todo__todo_add` — Add a new task. Use `+Project`, `@context`, and
  `due:YYYY-MM-DD` in the text. A stable `id:N` is assigned automatically.
- `lua__todo__todo_done` — Mark a task complete. **Only after the work is
  actually done and verified** — never based on intent.
- `lua__todo__todo_delete` — Remove a task permanently (for mistakes or
  irrelevant tasks; NOT for completed work).
- `lua__todo__todo_prioritize` — Set/change a task's priority (A=high through
  Z=low).
- `lua__todo__todo_write` — Replace the entire list at once (for bulk
  reordering). Existing `id:N` tags are preserved; tasks without one get fresh
  ids so plans stay addressable.

### Detailed plans (lazy-loaded)

- `lua__todo__todo_get_plan` — Fetch the full plan for one task: summary,
  checklist steps (with `[x]`/`[ ]` done state), and notes. Call this before
  starting work on a task whose `todo_list` line showed `[plan:N steps]`.
- `lua__todo__todo_set_plan` — Create or replace a task's plan. Write a
  one-line `summary`, break the work into newline-separated `steps`, and
  optionally add `notes`. Do this before starting multi-step work.
- `lua__todo__todo_check_step` — Toggle a step's completion in a plan
  checklist. Use right after finishing a planned step for granular progress.

## Behavioral rules

- **Plan before executing.** When the task has multiple steps, create todos
  for each step before diving in. For a task that is itself multi-step, write
  a detailed plan with `todo_set_plan` first.
- **Keep exactly one task `in_progress`** while work remains. Mark the current
  step's priority `(A)` or add it first; start it, do it, then `todo_done` it
  and move to the next.
- **Track sub-progress with the plan checklist.** As you finish each planned
  step, call `todo_check_step` to tick it off — this keeps a granular record
  without re-listing every task.
- **Mark `todo_done` only after verification.** Run tests, check output, or
  confirm the step worked before marking it done. If a step is blocked or
  partial, keep it open and note the blocker in the plan notes.
- **Update as the plan evolves.** If you discover new steps or realize a step
  is unnecessary, `todo_add` or `todo_delete` promptly — don't let the list go
  stale. Re-plan with `todo_set_plan` if the decomposition was wrong.
- **Summarize to the user.** The todo list is NOT directly visible to the user
  as a live panel; they see it only through your messages and tool results.
  When you finish, send a concise text summary of what was done.

## todo.txt format (quick reference)

Tasks follow the todo.txt standard so the list is portable:

```
(A) 2024-01-15 Call the client +backend @phone due:2024-01-20 id:1
x 2024-01-18 2024-01-15 Sent the invoice +backend id:2
```

- `(A)`–`(Z)` — priority (A = highest).
- `x ` — marks a completed task; the next date is the completion date.
- `YYYY-MM-DD` — creation date (auto-set by `todo_add`); for completed tasks a
  second date is the completion date (auto-set by `todo_done`).
- `+Project` — tags the task with a project.
- `@context` — tags the task with a context (e.g. `@phone`, `@code`).
- `key:value` — tags like `due:2024-02-01`. `due:` is rendered and used for
  overdue detection.
- `id:N` — stable numeric handle (auto-assigned by `todo_add`) used to key
  plans in `plans.json`. You do not need to write it manually.

You do not need to write raw todo.txt lines manually for single-task changes —
use the dedicated tools (`todo_add`, `todo_done`, etc.). Use `todo_write` only
when you need to replace or reorder the whole list.
