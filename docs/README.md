# Zay Documentation

Zay is the coding agent for shipping to the stars, built for deep human-in-the-loop coding.

This documentation is organized as a **wiki**: each topic lives in exactly **one** document. Where a concept is relevant to more than one document, it is **crosslinked** rather than restated — read the linked page once and you have the authoritative source.

## Document Index

| Namespace / document | Owns | Read it for |
|---|---|---|
| [Philosophy](PHILOSOPHY.md) | Design philosophy | Why Zay is built the way it is — human-in-the-loop, the Trifecta (Bash, Worktrees, Tmux). |
| [Architecture](ARCHITECTURE.md) | High-level architecture | LLM Gateway, agent tools (`bash`/`lane`), steering, timeline, parallel lanes, bash auto-review, safety. |
| [Configuration namespace](config/README.md) | Configuration | Layered config system, setting references, environment variables, persistence, and troubleshooting. |
| [Response Classification](RESPONSE_CLASSIFICATION.md) | Inbound LLM semantics | Answer/reasoning classification, provider/model policy overrides, structured content and Responses item routing. |
| [MCP namespace](mcp/README.md) | MCP integration | Model Context Protocol transports, versions, security, async connects, and tool injection. |
| [Patterns namespace](patterns/README.md) | Engineering reference | Implementation patterns and invariants, split by subsystem for targeted reading. |
| [Plugins namespace](plugins/README.md) | Lua plugin development | Plugin quick start, permissions, API reference, examples, and testing. |
| [Skills](SKILLS.md) | Skill discovery | Skill name charset, `SKILL.md` convention, invocation, and conformance scanning. |
| [Database namespace](database/README.md) | Storage and roaming | SQLite, cloud backends, PostgreSQL service, multi-host roaming, and fallback behavior. |
| [Development](DEVELOPMENT.md) | Zig development | Style, ownership, Zig 0.16 API recipes, and optimized-build debugging. |
| [Code Discovery](CODE_INTELLIGENCE.md) | Graph tooling | Codebase Memory identity, GitNexus impact/change checks, and CLI routing. |
| [Building](BUILDING.md) | Source builds | Clone, fetch dependencies, build, test, and install. |
| [Releasing](RELEASING.md) | Release process | Tags, GitHub Actions artifacts, and `zay --version`. |
| [Command Safety & Classifier](wiki/SAFETY_CLASSIFIER.md) | Safety stack | Deterministic matching, optional classifier service, and fallback semantics. |

## Task-Based Reading Routes

- **Change a subsystem:** start with [Patterns](patterns/README.md), then follow its topic page.
- **Change configuration:** use the [Configuration namespace](config/README.md) and its schema or troubleshooting pages.
- **Work on MCP:** use the [MCP namespace](mcp/README.md) for lifecycle and protocol guidance.
- **Work on persistence:** use the [Database namespace](database/README.md) for backend and roaming details.
- **Develop a plugin:** start with the [Plugins namespace](plugins/README.md), then use its API and examples pages.

## Where does X live?

| Topic | Authoritative document |
|---|---|
| How to configure Zay | [Configuration namespace](config/README.md) |
| Database backends and roaming | [Database namespace](database/README.md) |
| How MCP servers connect and work | [MCP namespace](mcp/README.md) |
| How to write a Lua plugin | [Plugins namespace](plugins/README.md) |
| Skill name rules / `--strict` scan | [Skills](SKILLS.md) |
| How to build Zay from source / interpret test results | [Building](BUILDING.md) |
| Zig conventions, API examples, and memory safety | [Development](DEVELOPMENT.md) |
| Graph discovery / impact analysis / change checks | [Code Discovery](CODE_INTELLIGENCE.md) |
| Plugin `zay.*` bridge functions | [Plugins API reference](plugins/api-reference.md) |
| The `union(enum)` type-system discipline | [Patterns](patterns/README.md) |
| Session persistence / reasoning-effort lifecycle | [Patterns](patterns/README.md) |
| Parallel lanes, timeline, and bash safety | [Architecture](ARCHITECTURE.md) |
| How to cut a release | [Releasing](RELEASING.md) |
