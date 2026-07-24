# Model Context Protocol (MCP) Integration Guide

Nova Agent features production-grade support for the **Model Context Protocol (MCP)**,
allowing your LLM models to dynamically discover and invoke external tools, databases,
APIs, and file services.

---

## 1. Overview & Transports

Nova Agent supports two standard MCP transports:

1. **Stdio (`stdio`)**: Child processes launched locally by Nova Agent (e.g. via `npx`,
   `python`, `uv`, or precompiled binaries). **Implemented.**
2. **HTTP/SSE (`sse`)**: Remote MCP server connections communicating via Server-Sent
   Events and HTTP POST JSON-RPC 2.0 requests. **Not yet implemented** — `url`-based
   servers are parsed from config but not connected.

---

## 2. Configuration (`config.json` / `mcpServers` or `mcp_servers`)

MCP servers are configured inside global `~/.config/nova/config.json` or project-local
`<cwd>/.nova/config.json` under the `"mcpServers"` (Claude Desktop / Cursor format) or
`"mcp_servers"` key.

### Example Configuration (Claude Desktop Format)

```json
{
  "version": 1,
  "mcpServers": {
    "codebase-memory-mcp": {
      "command": "/path/to/codebase-memory-mcp",
      "args": []
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "enabled": true
    },
    "remote-db": {
      "url": "https://mcp.internal.dev/sse",
      "enabled": true
    }
  }
}
```

### Server Configuration Options

| Field     | Type       | Description                                                                                     |
| --------- | ---------- | ----------------------------------------------------------------------------------------------- |
| `command` | `string`   | Binary / CLI command to execute for stdio servers (e.g. `npx`, `python`).                       |
| `args`    | `string[]` | Command line arguments passed to the stdio child process.                                       |
| `url`     | `string`   | Endpoint URL for remote HTTP/SSE servers (e.g. `https://mcp.dev/sse`). SSE not yet implemented. |
| `enabled` | `boolean`  | `true` (default) to connect and expose tools; `false` to disable.                               |

---

## 3. Connection Lifecycle

MCP server connections follow a three-phase lifecycle:

### Phase A — Registration (app startup, no I/O)

`McpManager.syncFromConfig()` creates `McpClient` objects from config. No subprocess
is spawned — the client is marked as `[CONNECTING]`. This phase is instant and never
blocks the TUI.

### Phase B — Connection (provider connect or `/mcp` open)

`McpManager.syncFromConfigEx()` performs real I/O for each enabled server:

1. **Spawn**: Subprocess launched via `command` + `args` with stdin/stdout pipes.
2. **Handshake**: JSON-RPC `initialize` request → server responds with protocol version
   and capabilities → client sends `notifications/initialized`.
3. **Discovery**: JSON-RPC `tools/list` request → server returns tool schemas →
   parsed into `tools_common.Schema` format.

Each step has a **30-second timeout** via `std.posix.poll`. If a server doesn't respond
within that window, it's marked as `[FAILED]` with an error message.

### Phase C — Tool injection (provider connect)

When the user connects to an AI provider, `buildMcpToolSchemas()` collects all
discovered MCP tools from `.connected` servers and injects them into the AI config's
`tools` array alongside built-in tools (bash). The model sees them as regular
function-calling tools with namespaced names (`mcp__<server>__<tool>`).

### Phase D — Execution (agent turn)

When the model calls an MCP tool:

1. Executor parses `mcp__<server>__<tool>` to extract server and tool name.
2. Finds the connected `McpClient` by server name.
3. Sends `tools/call` JSON-RPC request with the tool name and arguments.
4. Parses the response `content` array (text blocks) and returns the result to the
   model.

---

## 4. Dynamic Tool Discovery & Namespacing

- When Nova Agent starts or when the MCP overlay is opened, `McpManager` spawns each
  stdio server subprocess, performs the MCP `initialize` handshake, and queries
  `tools/list` via JSON-RPC.
- Exposed MCP tools are automatically namespaced as:
  `mcp__<server_name>__<tool_name>`
  _(Example: `mcp__memory__create_entities`)_
- Tool schemas (`inputSchema`) are parsed from JSON Schema into Nova's internal
  `tools_common.Schema` format, preserving property types, descriptions, and
  required fields.
- Discovered tools are injected into the AI provider's `tools` array alongside
  built-in tools (bash), so the model can call them directly.
- **Planned**: `notifications/tools/list_changed` for real-time tool catalog updates
  without restarting the session.

---

## 5. Real-Time TUI Monitoring (`/mcp` Command)

Nova Agent includes a dedicated TUI monitoring screen:

- Run `/mcp` in chat to bring up the MCP Status Overlay.
- View connection badges: `[CONNECTED]`, `[CONNECTING]`, `[FAILED]`, `[DISABLED]`.
- View **tool count** per server (number of tools discovered via `tools/list`).
- View **ping latency** in milliseconds (from the `initialize` handshake round-trip).
- View **error messages** for failed servers (e.g. "Handshake failed: Timeout").
- Controls:
  - **Space**: Toggle enable / disable status. On a failed server, toggling
    triggers a reconnect attempt.
  - **Ctrl+R** / **r**: Reconnect the selected server (stop + restart + re-discover).
  - **Esc** / **q**: Close overlay.

---

## 6. Crash Isolation & Security

> [!IMPORTANT]
> **Fault Isolation**: If a local stdio MCP child process crashes or terminates
> unexpectedly, Nova Agent catches the signal, flags the server as `[FAILED]`, and
> isolates the fault. Nova Agent TUI and agent reasoning loop continue running
> without interruption.

---

## 7. Known Limitations

- **SSE transport**: Remote `url`-based MCP servers are not yet supported. Only
  stdio (`command` + `args`) servers work.
- **Auto-connect**: When Nova Agent auto-connects to a saved provider at startup,
  MCP tools are not yet available. Reconnect the provider after MCP servers are
  connected to include MCP tools.
- **`notifications/tools/list_changed`**: Not yet handled. Tool catalog is static
  after initial discovery.
- **Server names with underscores**: The `mcp__server__tool` namespace uses `__` as
  separator. Server names containing `_` will be incorrectly parsed. Use hyphens
  instead.
