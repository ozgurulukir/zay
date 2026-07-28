---
description: Session-scoped file-operation tracking driven by tool-call events.
---

Use the `file-watcher` plugin to track and report file operations performed
during the current session. It subscribes to `tool_call_finished` events and
records file operations in memory for the lifetime of the session. State is
not persisted across restarts.

## When to use each tool

- `lua__file-watcher__track_file_op` — Manually record a file operation
  (`read`, `write`, `delete`, `rename`) against a `path`. Call this when you
  perform or observe a notable file operation you want counted.
- `lua__file-watcher__file_stats` — Report how many file operations have been
  tracked this session. Use this to summarize activity.

## Guidelines

- Tracking is **session-scoped and opt-in.** The plugin listens for
  `tool_call_finished` events to observe bash tool calls, but operations are
  only counted if someone calls `track_file_op` — the event hook records
  context, it does not auto-classify every operation.
- Use `track_file_op` after performing a file write/edit/delete/rename so the
  session log reflects what actually happened.
- `file_stats` returns a simple count. It is a lightweight summary, not a diff
  or audit log — do not treat it as a source of truth for what changed in the
  repo; use `lua__git-tools__git_status` for that.
