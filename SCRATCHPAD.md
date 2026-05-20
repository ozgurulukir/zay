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
- Do not show openai models if not signed in with codex
- Create OpenAI Compatible provider UI with API key and base URL inputs. Then auto-fetch and cache /models from that endpoint.
- Handle edge cases where selected content when expanded goes out of bounds. Forcing a mouse scroll. Vim like line-by-line navigation (fall back to select on collapsed blocks)

A bit of y spacing to the session list.

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
