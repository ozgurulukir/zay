---
description: Session-scoped file-operation tracking driven by tool-call events.
---

Use the `file-watcher` plugin to track and report file operations performed
during the current session. It subscribes to `tool_call_finished` events and
counts successful file-operation tool calls by kind (write/edit/delete/rename/
copy) in memory for the lifetime of the session. State is not persisted across
restarts.

## When to use each tool

- `lua__file-watcher__file_stats` — Report how many file operations have been
  tracked this session, broken down by kind. Use this to summarize activity.
- `lua__file-watcher__track_file_op` — Manually record a file operation
  (`read`, `write`, `delete`, `rename`) against a `path`. Use this for
  operations the event-driven counter can't see (e.g. reads, or bash-driven
  changes).

## How event tracking works

The `tool_call_finished` event payload carries only the tool `name`, `call_id`,
and `success` — **no arguments and no file paths**. So the plugin classifies
events purely by tool name:

- `lua__file-tools__write` → write
- `lua__file-tools__edit` → edit
- `lua__path-tools__delete_path` → delete
- `lua__path-tools__move_path` → rename
- `lua__path-tools__copy_path` → copy

Only successful calls are counted. Because the payload has no path data, the
event-derived counts cannot tell you *which* file changed — they are a
per-kind tally only. For actual paths, use `track_file_op` or `lua__git-tools__git_status`.

## Guidelines

- Tracking is **session-scoped and opt-in.** The plugin only counts the
  file-operation tools listed above; it does not observe bash or other tools.
- `file_stats` is a lightweight summary, not a diff or audit log — do not
  treat it as a source of truth for what changed in the repo; use
  `lua__git-tools__git_status` for that.
