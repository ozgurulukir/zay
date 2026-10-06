## 4. Dynamic Tool Discovery & Namespacing

- On startup and whenever the MCP overlay is opened, `McpManager` connects each enabled
  server (spawning stdio subprocesses or POSTing to remote endpoints), performs the MCP
  `initialize` handshake, and queries `tools/list` via JSON-RPC.
- Exposed MCP tools are automatically namespaced as:
  `mcp__<server_name>__<tool_name>`
  _(Example: `mcp__tavily__tavily_search`)_
- Tool schemas (`inputSchema`) are parsed from JSON Schema into Zay's internal
  `tools_common.Schema` format, preserving property types, descriptions, and required
  fields.
- Discovered tools are injected into the AI provider's `tools` array alongside all
  builtin tools, so the model can call them directly.
- **`notifications/tools/list_changed`**: Handled for servers that advertise
  `capabilities.tools.listChanged`. The notification sets `pending_tools_refresh` on the
  client; the TUI tick's `drainMcpNotifications` polls it, re-runs `tools/list`, and
  re-injects the refreshed schemas automatically. (The notification is captured when it
  arrives during a request read; reopen `/mcp` or press `r` to force a re-sync any time.)

---

## 5. Real-Time TUI Monitoring (`/mcp` Command)

Zay Agent includes a dedicated TUI monitoring screen:

- Run `/mcp` in chat to bring up the MCP Status Overlay.
- View connection badges: `[CONNECTED]`, `[CONNECTING]`, `[FAILED]`, `[DISABLED]`.
- View the **transport** per server: `(stdio)` or `(remote)`.
- View **tool count** per server (number of tools discovered via `tools/list`).
- View **ping latency** in milliseconds (from the `initialize` handshake round-trip).
- View **error messages** for failed servers (e.g. "Handshake failed: Timeout").
- Controls:
  - **Space**: Toggle enable / disable status. On a failed server, toggling triggers a
    reconnect attempt.
  - **a**: Add a remote server by URL (opens a single-line input form; paste is
    supported). See below.
  - **Ctrl+R** / **r**: Reconnect the selected server (stop + restart + re-discover).
  - **d**: Disconnect the selected server.
  - **Esc** / **q**: Close overlay.

### Adding a remote server by URL (`a`)

Press `a` in the overlay to open a URL input form. Type or paste a remote MCP endpoint
(`{env:VAR}` placeholders are expanded), then press **Enter** to connect it immediately
or **Esc** to cancel. The server name is derived from the URL host.

> [!NOTE]
> **Persisted to global config**: a server added with `a` is appended to the live
> `cached_config`, connected immediately, and written to the **global**
> `config.json` — so it survives a restart and is available in future sessions.
> Only the single new entry is written, which keeps project- and env-scoped
> servers from leaking into the global file. The write is best-effort: a failure
> leaves the server live in the running session and logs `mcp.add.persist.failed`.
> To remove it permanently, delete its `mcpServers` entry from
> `~/.config/zay/config.json` by hand. Toggling it off in the overlay only disables
> the server for the current process and does not rewrite the persisted entry.

---

## 6. Crash Isolation & Security

> [!IMPORTANT]
> **Fault Isolation**: A server that fails to connect (or is explicitly disconnected) is
> flagged `[FAILED]` in the `/mcp` overlay. If a local stdio MCP child process crashes
> or terminates unexpectedly **after** a successful connect, or a remote server errors
> or drops its session (a `404` is treated as an expired session), the failure surfaces
> as an error on the individual tool call while the overlay badge keeps its last
> lifecycle state — the agent loop and the rest of the app continue without
> interruption. Use the overlay's reconnect key (`Ctrl+R`/`r`) to relaunch a crashed
> server.

---
