# done — mcp-integration

## Summary

MCP tool keşfi, AI pipeline entegrasyonu ve TUI görselleştirmesi tamamlandı.
Kalan tek iş: SSE transport (remote `url`-based MCP servers).

## Delivered

### Phase 1 — Process lifecycle & stdio transport
- `McpClient.init` accepts `args: []const []const u8` — `McpServerConfig.args` artık kullanılıyor
- `McpClient.process: ?std.process.Child` — subprocess handle
- `McpClient.startStdio(io)` — spawns child with stdin/stdout pipes
- `McpClient.sendRequest(io, method, params_json)` — writes JSON-RPC to stdin, reads response line from stdout
- `McpClient.sendNotification(io, method, params_json)` — JSON-RPC notification (no response)
- `McpClient.stop(io)` — closes pipes, kills child
- `McpManager.deinit(io)` / `McpClient.deinit(io)` — `io` parametresi eklendi

### Phase 2 — MCP handshake & real tool discovery
- `McpClient.initialize(io)` — MCP handshake: `initialize` request → `notifications/initialized`
  - Records `latency_ms` from handshake round-trip
  - Sets `status = .connected` on success, `.failed` on error
- `McpClient.listTools(io)` — `tools/list` JSON-RPC → parses `inputSchema` → populates `client.tools`
- `schemaFromJsonSchema(gpa, value)` — JSON Schema → `tools_common.Schema` converter
- `connectAndDiscover(io, client)` — orchestrates: startStdio → initialize → listTools
- `syncFromConfigEx` rewritten: spawns subprocess, does real handshake, discovers tools
  - Removed static JSON file scanning (`discoverToolsForClient`, `scanSchemaDir`, `parseAndAddToolSchema`)
  - `syncFromConfigEx` now returns `void` (errors caught internally, status set to `.failed`)
- `McpTool.deinit` now frees `schema.properties` (fixes memory leak)

### Phase 3 — Tool injection into AI context
- `ai.McpToolSchema` — schema-only tool type (no `run`/`display` function pointers)
- `ai.Config.mcp_tools: []const McpToolSchema` — additive field, `tools` untouched
- `openai_compatible.buildAllToolsJson(gpa, tools, mcp_tools)` — serializes both lists
- `responses_core.buildAllToolsJson(gpa, tools, mcp_tools)` — same for Responses API
- `writeToolDefinition` refactored: takes `name`, `description`, `schema` instead of `Tool`
- `writeParameters` refactored: takes `Schema` instead of `Tool`
- `AgentRuntime.mcp_tools` — runtime holds MCP tool schemas
- `McpManager.buildMcpToolSchemas(gpa)` — builds `[]McpToolSchema` from connected clients
- `provider_model.connectCodexClient` / `attachOpenAiCompatibleClient` — sets `runtime.mcp_tools` before connecting

### Phase 4 — MCP tool execution
- `McpClient.callTool(io, tool_name, arguments_json)` — `tools/call` JSON-RPC
  - Parses response `content` array, extracts text blocks
  - Handles `isError` flag
- `ExecutorService.mcp_manager: ?*McpManager` — optional MCP dispatch reference
- `ExecutorService.runMcpTool(call)` — parses `mcp__server__tool` name, finds client, calls tool
- `Agent.mcp_manager: ?*McpManager` — passes through to executor at tool batch time
- `tui.zig` / `session_switcher.zig` — wire `app.mcp_manager` into `agent.mcp_manager`

### Phase 6 — TUI polish
- `McpClient.error_message: ?[]u8` — human-readable error from last failure
- `McpClient.setError(comptime fmt, args)` — set error message, frees previous
- `connectAndDiscover` now captures errors per step (spawn, handshake, discovery)
- `McpManager.reconnectClient(io, index)` — stop + clear + re-discover a single client
- `mcp_status` widget: shows tool count per server, error messages inline
- `command_router` McpMode:
  - `Space` on failed server → reconnect attempt
  - `Ctrl+R` / `r` → reconnect selected server (not full resync)

### Bug fixes (found during testing)
- **Malformed JSON** (`transport.zig`): `"}}\n"` → `"}\n"` — `formatRequest`/`formatNotification` produced invalid JSON with extra `}`. Real MCP servers rejected it and never responded → app hang.
- **No read timeout** (`client.zig`): `sendRequest` blocked forever on `streamDelimiterEnding`. Added `std.posix.poll` with 30s timeout.
- **Dangling pointer** (`tui.zig`): `&app.mcp_manager` taken from stack-local `app` before return-by-value move. Moved pointer assignment to caller after `app` settles in final stack frame → segfault fix.
- **False `.connected` status** (`manager.zig`): `syncFromConfig` set `status = .connected` without spawning subprocess. Changed to `.connecting`. Real connection happens in `syncFromConfigEx` at provider connect time.

## Files changed

16 files, ~730 lines added, ~145 removed across all phases.

## Remaining

Phase 5: SSE transport (remote `url`-based MCP servers). See `_pm/Projects/nova-agent/backlog.md`.
