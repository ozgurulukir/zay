# Zay Documentation

Zay is the coding agent for shipping to the stars, built for deep human-in-the-loop coding.

This documentation is organized as a **wiki**: each topic lives in exactly **one** document. Where a concept is relevant to more than one document, it is **crosslinked** rather than restated — read the linked page once and you have the authoritative source.

## Document Index

| Document | Owns | Read it for |
|----------|------|-------------|
| [Philosophy](PHILOSOPHY.md) | Design philosophy | Why Zay is built the way it is — human-in-the-loop, the Trifecta (Bash, Worktrees, Tmux). |
| [Architecture](ARCHITECTURE.md) | High-level architecture | LLM Gateway, agent tools (`bash`/`lane`), steering, timeline, parallel lanes, bash auto-review, safety. |
| [Configuration](CONFIG.md) | Configuration | Layered config system, full setting table, environment variables, persistence & atomic writes, TUI management. |
| [MCP](MCP.md) | MCP integration | Model Context Protocol — transports, protocol versions, `{env:VAR}` security, async connects, tool injection. |
| [Patterns](PATTERNS.md) | Engineering reference | Hard-won implementation patterns for developers — TUI, type system, models.dev, config layering, reasoning, compaction, session resume, plugin internals. |
| [Plugins](plugins/README.md) | Lua plugin development | Writing Lua plugins — quick start, permissions, API reference, examples. |
| [Skills](SKILLS.md) | Skill discovery | Skill name charset, description cap, the `SKILL.md` convention, `$skill` invocation, `zay --strict` conformance scan. |
| [Database & Sessions](DATABASE.md) | Storage & Roaming | Local SQLite, Turso / LibSQL Cloud, Cloudflare D1, PostgreSQL service, multi-host roaming, fail-safe fallback. |
| [Development](DEVELOPMENT.md) | Zig development | Style, ownership, Zig 0.16 API recipes, and optimized-build debugging. |
| [Code Discovery](CODE_INTELLIGENCE.md) | Graph tooling | Codebase Memory project identity, GitNexus impact/change checks, and CLI routing. |
| [Building](BUILDING.md) | Source builds | Clone, fetch dependencies, build, test, and install. |
| [Releasing](RELEASING.md) | Release process | Cutting a release — tag & push, what the GitHub Actions workflow builds and attaches, `zay --version`. |
| [Command Safety & Classifier](wiki/SAFETY_CLASSIFIER.md) | Safety stack | Tier 1 deterministic matcher, optional Tier 2 ModernBERT classifier REST service, fallback semantics. |
| [Plugins API Reference](plugins/api-reference.md) | Lua bridge reference | The `zay.*` bridge function surface — parameters, return shapes, errors. |
| [Plugins Examples](plugins/examples.md) | Lua plugin walkthroughs | End-to-end example plugins. |

## Where does X live?

| Topic | Authoritative document |
|-------|------------------------|
| How to configure Zay (settings, env vars) | [Configuration](CONFIG.md) |
| Database backends (Turso, Cloudflare D1, PostgreSQL service, SQLite, roaming) | [Database & Sessions](DATABASE.md) |
| How MCP servers connect & work | [MCP](MCP.md) |
| How to write a Lua plugin | [Plugins](plugins/README.md) |
| Skill name rules / `--strict` scan | [Skills](SKILLS.md) |
| How to build Zay from source / interpret test results | [Building](BUILDING.md) |
| Zig conventions, API examples and memory safety | [Development](DEVELOPMENT.md) |
| Graph discovery / impact analysis / change checks | [Code Discovery](CODE_INTELLIGENCE.md) |
| Plugin `zay.*` bridge functions | [Plugins API reference](plugins/api-reference.md) |
| The `union(enum)` type-system discipline | [Patterns](PATTERNS.md) |
| Session persistence / reasoning-effort lifecycle | [Patterns](PATTERNS.md) |
| Parallel lanes, timeline, bash safety | [Architecture](ARCHITECTURE.md) |
| How to cut a release / how `zay --version` works | [Releasing](RELEASING.md) |
