# Zay Engineering Patterns

Engineering patterns are organized as a DokuWiki-style namespace with one landing page per topic. Start at [Patterns](patterns/README.md).

- [Architecture and layering](patterns/architecture-and-layering.md)
- [TUI, lanes, and worktrees](patterns/tui-lanes-and-worktrees.md)
- [Providers, tools, and wire protocols](patterns/providers-tools-and-wire-protocols.md)
- [Plugins, MCP, and skills](patterns/plugins-mcp-and-skills.md)
- [Configuration, sessions, and persistence](patterns/configuration-sessions-and-persistence.md)
- [Runtime, observability, and portability](patterns/runtime-observability-and-portability.md)

The former monolithic content remains in this compatibility page during migration; the namespace pages define the intended canonical ownership.


- [Durable skill context](patterns/plugins-mcp-and-skills.md#durable-skill-context) — activation, branch metadata, request retention, and capacity contracts.
- [Agent shared-subsystem attach](patterns/architecture-and-layering.md#agent-shared-subsystem-attach-agentsharedsubsystems-2026-11-03) — the sole production writer of the six borrowed agent fields; record + projection + spawn re-arm contracts.
