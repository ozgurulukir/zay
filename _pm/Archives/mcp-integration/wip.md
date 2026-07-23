# wip — mcp-integration

## Status

Phase 1 (process lifecycle & stdio transport) **complete**.
Phase 2 (MCP handshake & real tool discovery) **complete**.
Phase 3 (Tool injection into AI context) **complete**.
Phase 4 (MCP tool execution) **complete**.
Phase 5 (SSE transport) **not started**.
Phase 6 (TUI polish) **complete**. `zig build && zig build test` pass.

### Phase 6 delivered

- `McpClient.error_message: ?[]u8` — human-readable error from last failure
- `McpClient.setError(comptime fmt, args)` — set error message, frees previous
- `connectAndDiscover` now captures errors per step (spawn, handshake, discovery)
- `McpManager.reconnectClient(io, index)` — stop + clear + re-discover a single client
- `mcp_status` widget: shows tool count per server, error messages inline
- `command_router` McpMode:
  - `Space` on failed server → reconnect attempt
  - `Ctrl+R` / `r` → reconnect selected server (not full resync)
- `docs/MCP.md` updated: accurate descriptions of what's implemented vs planned

### Remaining

Phase 5: SSE transport (remote `url`-based MCP servers).
