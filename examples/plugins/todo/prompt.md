---
description: todo.txt-format task tracker — plan, track, and complete multi-step work.
---

Use the `todo` plugin to track multi-step work. The todo list lives in
`.nova/todos.txt` (todo.txt format) so it survives restarts and you can edit it
in any text editor.

## When to use the todo tools

Use the todo tools **proactively** when the user's request requires 3 or more
distinct steps. A single conceptual step that needs a few tool calls does NOT
need a todo list. When in doubt, use it.

- `lua__todo__todo_list` — Show the current list (open tasks, sorted by
  priority then date, overdue items flagged). Call this FIRST to see current
  state before adding/changing tasks.
- `lua__todo__todo_add` — Add a new task. Use `+Project`, `@context`, and
  `due:YYYY-MM-DD` in the text for organization.
- `lua__todo__todo_done` — Mark a task complete. **Only after the work is
  actually done and verified** — never based on intent.
- `lua__todo__todo_delete` — Remove a task permanently (for mistakes or
  irrelevant tasks; NOT for completed work).
- `lua__todo__todo_prioritize` — Set/change a task's priority (A=high through
  Z=low).
- `lua__todo__todo_write` — Replace the entire list at once (for bulk
  reordering).

## Behavioral rules

- **Plan before executing.** When the task has multiple steps, create todos
  for each step before diving in. This keeps you (and the user) oriented.
- **Keep exactly one task `in_progress`** while work remains. Mark the current
  step's priority `(A)` or add it first; start it, do it, then `todo_done` it
  and move to the next.
- **Mark `todo_done` only after verification.** Run tests, check output, or
  confirm the step worked before marking it done. If a step is blocked or
  partial, keep it open and note the blocker in the task text.
- **Update as the plan evolves.** If you discover new steps or realize a step
  is unnecessary, `todo_add` or `todo_delete` promptly — don't let the list go
  stale.
- **Summarize to the user.** The todo list is NOT directly visible to the user
  as a live panel; they see it only through your messages and tool results.
  When you finish, send a concise text summary of what was done.

## todo.txt format (quick reference)

Tasks follow the todo.txt standard so the list is portable:

```
(A) 2024-01-15 Call the client +backend @phone due:2024-01-20
x 2024-01-18 2024-01-15 Sent the invoice +backend
```

- `(A)`–`(Z)` — priority (A = highest).
- `x ` — marks a completed task; the next date is the completion date.
- `YYYY-MM-DD` — creation date (auto-set by `todo_add`); for completed tasks a
  second date is the completion date (auto-set by `todo_done`).
- `+Project` — tags the task with a project.
- `@context` — tags the task with a context (e.g. `@phone`, `@code`).
- `key:value` — tags like `due:2024-02-01`. `due:` is rendered and used for
  overdue detection.

You do not need to write raw todo.txt lines manually for single-task changes —
use the dedicated tools (`todo_add`, `todo_done`, etc.). Use `todo_write` only
when you need to replace or reorder the whole list.
