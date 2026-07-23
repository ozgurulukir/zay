# Model Context Protocol (MCP) Integration Guide

Nova Agent features production-grade support for the **Model Context Protocol (MCP)**, allowing your LLM models to dynamically discover and invoke external tools, databases, APIs, and file services.

---

## 1. Overview & Transports

Nova Agent supports two standard MCP transports:
1. **Stdio (`stdio`)**: Child processes launched locally by Nova Agent (e.g. via `npx`, `python`, `uv`, or precompiled binaries).
2. **HTTP/SSE (`sse`)**: Remote MCP server connections communicating via Server-Sent Events and HTTP POST JSON-RPC 2.0 requests.

---

## 2. Configuration (`config.json` / `mcpServers` or `mcp_servers`)

MCP servers are configured inside global `~/.config/nova/config.json` or project-local `<cwd>/.nova/config.json` under the `"mcpServers"` (Claude Desktop / Cursor format) or `"mcp_servers"` key.

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
      "args": [
        "-y",
        "@modelcontextprotocol/server-github"
      ],
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

| Field | Type | Description |
|---|---|---|
| `command` | `string` | Binary / CLI command to execute for stdio servers (e.g. `npx`, `python`). |
| `args` | `string[]` | Command line arguments passed to the stdio child process. |
| `url` | `string` | Endpoint URL for remote HTTP/SSE servers (e.g. `https://mcp.dev/sse`). |
| `enabled` | `boolean` | `true` (default) to connect and expose tools; `false` to disable. |

---

## 3. Dynamic Tool Discovery & Namespacing

- When Nova Agent starts or when configuration updates occur, `McpManager` initializes connections and queries `tools/list`.
- Exposed MCP tools are automatically namespaced as:
  `mcp__<server_name>__<tool_name>`
  *(Example: `mcp__memory__create_entities`)*
- If an MCP server emits `notifications/tools/list_changed`, Nova Agent updates its active tool catalog in real time without restarting the session.

---

## 4. Real-Time TUI Monitoring (`/mcp` Command)

Nova Agent includes a dedicated TUI monitoring screen:
- Run `/mcp` in chat to bring up the MCP Status Overlay.
- View connection badges: `[CONNECTED]`, `[CONNECTING]`, `[FAILED]`, `[DISABLED]`.
- View live **ping latency** in milliseconds.
- Controls:
  - **Space**: Toggle enable / disable status.
  - **Ctrl+R**: Reconnect a disconnected or failed server.
  - **Esc**: Close overlay.

---

## 5. Crash Isolation & Security

> [!IMPORTANT]
> **Fault Isolation**: If a local stdio MCP child process crashes or terminates unexpectedly, Nova Agent catches the signal, flags the server as `[FAILED]`, and isolates the fault. Nova Agent TUI and agent reasoning loop continue running without interruption.
