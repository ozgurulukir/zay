# Human-only display body for tool results

`edit_file` and `write_file` need to show the user a rich rendered body — a diff or the full new file content — that would be wasteful to feed back into the LLM's context on every turn. The model authored the change; re-reading its own output verbatim inflates context for marginal correction value. So we introduce a side channel: an optional `display: ?[]u8` field on `common.Output` and on the `ToolFinished` stream event. The tool's `stdout` stays terse (e.g. `"Edit applied to {path} (first changed line: N)"`) and continues to flow into the LLM's history as the tool observation. The `display` field is consumed only by the TUI, replacing the body shown in the thread when present.

The alternative we rejected was making `stdout` carry the diff and letting the LLM re-read it. That's simpler in plumbing but ties human-facing rendering choices (context size, elision, intra-line highlighting, future click-to-expand) to the LLM's observation channel — choices that should be free to evolve. The cost of the side channel is one optional field threaded through `common.Output → tools.run → agent.StreamEvent.ToolFinished → tui.applyToolFinished`, which is modest and self-contained.

Tools that have no rich body to show simply leave `display = null` and the TUI falls back to rendering `stdout` as today.
