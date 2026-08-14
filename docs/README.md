# Nova Documentation

Nova is the coding agent for shipping to the stars, built for deep human-in-the-loop coding.

This documentation is organized as a **wiki**: each topic lives in exactly **one** document. Where a concept is relevant to more than one document, it is **crosslinked** rather than restated — read the linked page once and you have the authoritative source.

## Document Index

| Document | Owns | Read it for |
|----------|------|-------------|
| [Philosophy](PHILOSOPHY.md) | Design philosophy | Why Nova is built the way it is — human-in-the-loop, the Trifecta (Bash, Worktrees, Tmux). |
| [Architecture](ARCHITECTURE.md) | High-level architecture | LLM Gateway, agent tools (`bash`/`lane`), steering, timeline, parallel lanes, bash auto-review, safety. |
| [Configuration](CONFIG.md) | Configuration | Layered config system, full setting table, environment variables, persistence & atomic writes, TUI management. |
| [MCP](MCP.md) | MCP integration | Model Context Protocol — transports, protocol versions, `{env:VAR}` security, async connects, tool injection. |
| [Patterns](PATTERNS.md) | Engineering reference | Hard-won implementation patterns for developers — TUI, type system, models.dev, config layering, reasoning, compaction, session resume, plugin internals. |
| [Plugins](plugins/README.md) | Lua plugin development | Writing Lua plugins — quick start, permissions, API reference, examples. |
| [Releasing](RELEASING.md) | Release process | Cutting a release — tag & push, what the GitHub Actions workflow builds and attaches, `nova --version`. |

## Where does X live?

| Topic | Authoritative document |
|-------|------------------------|
| How to configure Nova (settings, env vars) | [Configuration](CONFIG.md) |
| How MCP servers connect & work | [MCP](MCP.md) |
| How to write a Lua plugin | [Plugins](plugins/README.md) |
| Plugin `nova.*` bridge functions | [Plugins API reference](plugins/api-reference.md) |
| The `union(enum)` type-system discipline | [Patterns](PATTERNS.md) |
| Session persistence / reasoning-effort lifecycle | [Patterns](PATTERNS.md) |
| Parallel lanes, timeline, bash safety | [Architecture](ARCHITECTURE.md) |
| How to cut a release / how `nova --version` works | [Releasing](RELEASING.md) |
