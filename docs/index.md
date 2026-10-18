# Zay Documentation

Zay is a fast, single-binary terminal coding agent. This documentation is organized as a
**wiki**: each topic lives in exactly **one** document. Where a concept is relevant to
more than one document, it is **crosslinked** rather than restated.

Start here, then follow the links. For project overview, installation, and features see the
[root README](../README.md).

## Document Index

| Document | Owns | Read it for |
|---|---|---|
| [Philosophy](PHILOSOPHY.md) | Design philosophy | Why Zay is built the way it is — human-in-the-loop, the Trifecta (Bash, Worktrees, Tmux). |
| [Architecture](ARCHITECTURE.md) | High-level architecture | LLM Gateway, agent tools (`bash`/`lane`), steering, timeline, parallel lanes, bash auto-review, safety. |
| [Configuration namespace](config/README.md) | Configuration | Layered config system, setting references, environment variables, persistence, troubleshooting. |
| [Response Classification](RESPONSE_CLASSIFICATION.md) | Inbound LLM semantics | Answer/reasoning classification, provider/model policy overrides, structured content and Responses item routing. |
| [MCP namespace](mcp/README.md) | MCP integration | Model Context Protocol transports, versions, security, async connects, tool injection. |
| [Patterns namespace](patterns/README.md) | Engineering reference | Implementation patterns and invariants, split by subsystem. |
| [Plugins namespace](plugins/README.md) | Lua plugin development | Plugin quick start, permissions, API reference, examples, testing. |
| [Skills](SKILLS.md) | Skill discovery | Skill name charset, `SKILL.md` convention, invocation, conformance scanning. |
| [Database namespace](database/README.md) | Storage and roaming | SQLite, cloud backends, PostgreSQL service, multi-host roaming, fallback. |
| [Development](DEVELOPMENT.md) | Zig development | Style, ownership, Zig 0.16 API recipes, optimized-build debugging. |
| [Code Discovery](CODE_INTELLIGENCE.md) | Graph tooling | Codebase Memory identity, GitNexus impact/change checks, CLI routing. |
| [Building](BUILDING.md) | Source builds | Clone, fetch dependencies, build, test, install. |
| [Releasing](RELEASING.md) | Release process | Tags, GitHub Actions artifacts, `zay --version`. |

## Task-Based Reading Routes

- **Change a subsystem:** start with [Patterns](patterns/README.md), then its topic page.
- **Change configuration:** use the [Configuration namespace](config/README.md).
- **Work on MCP:** use the [MCP namespace](mcp/README.md).
- **Work on persistence:** use the [Database namespace](database/README.md).
- **Develop a plugin:** start with the [Plugins namespace](plugins/README.md).
- **Build from source:** [Building](BUILDING.md).

## Where does X live?

| Topic | Authoritative document |
|---|---|
| How to configure Zay | [Configuration namespace](config/README.md) |
| Database backends and roaming | [Database namespace](database/README.md) |
| How MCP servers connect and work | [MCP namespace](mcp/README.md) |
| How to write a Lua plugin | [Plugins namespace](plugins/README.md) |
| Skill name rules / `--strict` scan | [Skills](SKILLS.md) |
| How to build Zay from source | [Building](BUILDING.md) |
| Zig conventions, API examples, memory safety | [Development](DEVELOPMENT.md) |
| Graph discovery / impact analysis | [Code Discovery](CODE_INTELLIGENCE.md) |
| Plugin `zay.*` bridge functions | [Plugins API reference](plugins/api-reference.md) |
| Session persistence / reasoning-effort lifecycle | [Patterns](patterns/README.md) |
| Parallel lanes, timeline, bash safety | [Architecture](ARCHITECTURE.md) |
| How to cut a release | [Releasing](RELEASING.md) |

## Contributing

See [CONTRIBUTING.md](../CONTRIBUTING.md) and [AGENTS.md](../AGENTS.md). Security issues: [SECURITY.md](../SECURITY.md).