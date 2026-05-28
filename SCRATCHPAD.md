# Scratchpad

TODOs and ideas for features to add to Nova coding agent.

## TODOs

- Support skills in `.agents/`
- Support referencing files and symbols via `$`
- MCP (special via some kind of executor)
- Subagents
- Support AGENTS.md
- Support steering messages (sent as either a subagent call alongisde the conversation so far which then consolidates back into the main thread OR just sent to the model after the tool call response)
- Wire ability to add images to input in the UI
- improve logger and make it more useful
- add docs on `.nova/auth.json`
- Save auth tokens and api keys in keyring by default and only auth.json via setting
- Vim-ish movements like jump 3 message up
- /tree from pi
- progressive disclosure of tool guides
- API for model capability detection

Generally should explore libvaxis more and use more of its capabilities.

Tightening the human-agent loop.

Something like:

- Human initiates new feature/bugfix
- Back and forth occurs (how to make this smooth? grill-me)
- Agent goes to work
- Human steers as needed (notifiations could be useful here or some kind of observability on where the agent is up to, via the TUI)
- Hunk style review of code with agent notes
