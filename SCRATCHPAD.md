# Scratchpad 

TODOs and ideas for features to add to Nova coding agent.

## TODOs

- Support skills in `.agents/`
- MCP (special via some kind of executor)
- Subagents
- Support AGENTS.md
- Support steering messages (sent as either a subagent call alongisde the conversation so far which then consolidates back into the main thread OR just sent to the model after the tool call response)

Handle edge cases where selected content when expanded goes out of bounds. Forcing a mouse scroll. Could somehow initiate a scroll via keyboard. 

Snap back to bottom shortcut.

Fix wrapping of text leading to dangling characters (Just need to word-break).

Markdown formatting.

Generally should explore libvaxis more and use more of its capabilities.

Tightening the human-agent loop.

Something like:

- Human initiates new feature/bugfix
- Back and forth occurs (how to make this smooth? grill-me)
- Agent goes to work
- Human steers as needed (notifiations could be useful here or some kind of observability on where the agent is up to, via the TUI)
- Hunk style review of code with agent notes


## Ideas

