# Zay Guidelines

## Working in this repository

- This project uses Zig 0.16. Read the `tigerstyle` skill and [Development guide](docs/DEVELOPMENT.md) before writing Zig code.
- Use graph tools for code discovery; the codebase-memory project id is `home-aristo-Projects-zay`. Read [Code discovery](docs/CODE_INTELLIGENCE.md) before exploring or changing code.
- Read the relevant [Engineering patterns](docs/patterns/README.md) section before changing a subsystem. Keep detailed contracts and regression history in the wiki, with pointers here.
- After code changes, follow [Build verification](docs/BUILDING.md#verifying). When changing tests, read its test-runner quirks before interpreting results.
- The pinned libvaxis includes the upstream fixes; use the normal dependency fetch described in [Building](docs/BUILDING.md). The former local patch helpers were removed.

## Documentation routing

The [wiki index](docs/index.md) lists each document’s scope. Read the linked section when the task touches that area:

| Task | Reference |
| --- | --- |
| Module boundaries, widgets, protocol serializers | [Architectural invariants](docs/patterns/architecture-and-layering.md#architectural-layering--invariants), [wire decomposition](docs/patterns/architecture-and-layering.md#wire-protocol-decomposition-inv-resp-1) |
| Lane turns, workspace ownership, worktree provisioning or recovery | [Lane workspace](docs/patterns/tui-lanes-and-worktrees.md#lane-workspace-boundary), [worktree lifecycle](docs/patterns/tui-lanes-and-worktrees.md#worktree-hardening--lifecycle-architecture), [crash recovery](docs/patterns/tui-lanes-and-worktrees.md#lane-crash-recovery) |
| Provider clients, tool catalogs, streaming, reasoning or compaction | [Engineering patterns](docs/patterns/providers-tools-and-wire-protocols.md) |
| Session writes, roaming, project identity or resume | [Database guide](docs/database/README.md), [storage invariants](docs/patterns/configuration-sessions-and-persistence.md#external-database-service--roaming-session-backend-2026-09-28) |
| MCP lifecycle, schemas or tool injection | [MCP guide](docs/mcp/README.md), [MCP implementation](docs/patterns/plugins-mcp-and-skills.md#mcp-server--tool-discovery-pattern) |
| Lua bridges, sandboxing, plugin discovery or dispatch | [Plugin guide](docs/plugins/README.md), [plugin implementation](docs/patterns/plugins-mcp-and-skills.md#lua-plugin-system-pattern) |
| Skill loading or invocation | [Skills](docs/SKILLS.md), [loader invariants](docs/patterns/plugins-mcp-and-skills.md#skill-subsystem-pattern) |
| Shell execution, containment or classifier behavior | [Shared shell pipeline](docs/patterns/providers-tools-and-wire-protocols.md#shared-shell-tool-pipeline-pattern-shellzig--capture_sinkzig), [classifier guide](docs/wiki/SAFETY_CLASSIFIER.md) |
| Settings, environment variables, logging or toasts | [Configuration](docs/config/README.md), [logging implementation](docs/patterns/runtime-observability-and-portability.md#logging-implementation), [toast routing](docs/patterns/runtime-observability-and-portability.md#toast-notification-pattern) |
| Build, install, test fixtures or optimized-build debugging | [Building](docs/BUILDING.md), [Development guide](docs/DEVELOPMENT.md) |
| Version bump, tags, release assets or portability checks | [Releasing](docs/RELEASING.md) |

Wiki shorthand: `[[NAME]]` means `docs/NAME.md`; `[[NAME#Section]]` means the heading beginning with `Section` there. A wiki target that is not a documentation page is a repository-root path.

<!-- gitnexus:start -->
## GitNexus

Before code edits or commits, read and follow [GitNexus graph checks](docs/CODE_INTELLIGENCE.md#gitnexus--code-intelligence). This includes impact analysis, change analysis, and handling HIGH/CRITICAL/UNKNOWN risk. Refresh a stale index with `node .gitnexus/run.cjs analyze --index-only`.
<!-- gitnexus:end -->
