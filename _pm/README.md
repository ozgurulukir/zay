# _pm Index

Cross-linked index for project management artifacts.

## Projects (active)

- [mcp-improvements](Projects/mcp-improvements/) — MCP hardening: transport tests, reconciliation, schema edge cases, RAII
  - State: Planning done. 10 items in backlog. Starting #6 (transport tests).
  - Created: 2026-07-23
  - Source: `MCP-IMPROVEMENTS.md` (codebase-memory-mcp analysis).

- [tui-domain-extract-2](Projects/tui-domain-extract-2/) — Continue Strangler Fig extraction from `tui.zig`
  - State: Phase 1 (queue) done. `tui.zig` 4141 → **4097**.
  - Created: 2026-07-22
  - Plan: background modal, checkpoint, turn lifecycle, agent event, save, command palette, RootWidget, init/deinit.

## Archives

- [mcp-integration](Archives/mcp-integration/) — Bridge MCP tool discovery to the AI tool pipeline
  - State: **Complete** (P1–P4, P6). P5 (SSE) deferred.
  - Created: 2026-07-23, Archived: 2026-07-23
  - 16 files, ~730 lines added. 4 bugs fixed (malformed JSON, no timeout, dangling ptr, false status).
  - Remaining: SSE transport for remote `url`-based MCP servers.

- [tui-split](Archives/tui-split/) — `tui.zig` 8586 → **4141** (-%51.8). Split into 21 modules.
  - R1–R7.5 (tui-split): 14 modules, 8586 → 5100
  - Phase 1-7 (tui-domain-extract): 7 domain modules, 5100 → 4141
  - 49 atomic commits total. All pushed to `origin/main`.

## Workflow

1. New work → `Projects/<name>/backlog.md`
2. Picked up → move items to `todo.md`
3. In progress → `wip.md` (one item at a time, Rule 9 KISS)
4. Done → `done.md`
5. Stale > 30d → `Archives/`
