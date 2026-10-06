## 3. Connection Lifecycle

MCP server connections follow a multi-phase lifecycle:

### Phase A — Registration (app startup, no I/O)

`McpManager.syncFromConfig()` creates `McpClient` objects from config. No subprocess is
spawned and no network call is made — the client is marked as `[CONNECTING]`. This phase
is instant and never blocks the TUI.

### Phase B — Connection (async; startup, provider connect, or `/mcp` open)

Connects are **asynchronous** — they never block the TUI. `McpManager.syncFromConfigEx()`
(and `reconnectClient`) launch one `io.concurrent` worker per enabled server instead of
doing I/O inline: a `ConnectJob` (kept in `pending_connects`) whose worker spawns,
handshakes, and discovers tools on a **private transport clone**
(`McpClient.cloneForConnect`) — the live client list is only ever mutated on the main
thread. Each TUI tick, `McpManager.drainConnects` polls the worker's `done` flag, awaits
the finished future (instant), and installs the completed client into the list by name
(`installConnectResult`); `provider_model.drainMcpConnects` then re-injects the freshly
discovered tool schemas. A slow or unreachable server stays `[CONNECTING]` without
freezing the UI, and a disconnect during the handshake discards the outcome instead of
resurrecting the server.

Per server:

- **Stdio**: subprocess launched via `command` + `args` with stdin/stdout pipes.
- **Streamable HTTP**: connectionless — nothing is spawned; each JSON-RPC call is a fresh
  `POST`.

Then, for both transports:

1. **Handshake**: JSON-RPC `initialize` request → server responds with protocol version
   and capabilities → client sends `notifications/initialized`.
2. **Discovery**: JSON-RPC `tools/list` request → server returns tool schemas → parsed
   into `tools_common.Schema` format.

**Timeouts** — a server that doesn't respond in time is marked `[FAILED]` with an error
message:

- Stdio reads use a **30-second** default timeout (`McpClient.read_timeout_ms`); override it per server with the `requestTimeoutMs` config field (clamped to ≥ 1 ms), see [../config/README.md](../config/README.md). POSIX polls the pipe and
  Windows uses `PeekNamedPipe` in short slices, so a stalled or abruptly closed server
  cannot wedge the handshake worker.
- Remote requests apply a socket-level send/recv timeout on POSIX
  (`SO_RCVTIMEO`/`SO_SNDTIMEO`). Windows races the complete `std.http.Client` operation —
  connect, response head, JSON body or SSE stream — against the same deadline using
  `std.Io.Select`; session DELETE during teardown uses it too. A timeout cancels and joins
  the in-flight operation before its owned buffers are released.

**Testing the async path** — `src/mcp/manager.zig`'s async tests mock a stdio MCP server
with a `bash -c` script that `read`s each request line and `echo`s a canned JSON-RPC
response (initialize → initialized notification → tools/list), then poll `drainConnects`
the way the TUI tick does (`drainUntilConnected` helper). Coverage: successful
discovery+install, handshake failure against a dead server, malformed `tools/list`
response, disconnect-mid-flight (the outcome is discarded, never resurrecting the
client), and the single-pending-job launch guard.

### Phase C — Tool injection (startup and on every MCP change)

The AI client serializes its tool list (`tools_json`) once, at attach time. Because the
client is attached during session init — before the MCP manager exists — Zay rebuilds
and re-injects the serialized tools whenever the MCP tool set changes:

- **On startup** (`run()`), after configured servers connect.
- **On `/mcp` open** and after **toggle / reconnect / disconnect** in the overlay.
- **On provider connect** (the interactive `/connect` flow).
- **On session switch / resume / lane spawn** (`createRuntime`): after wiring the
  App's `tool_registry` onto the new runtime, `provider_model.injectToolsInto`
  pushes the merged builtin + plugin + MCP list so the new session's first turn
  carries every tool definition.
- **On a cross-project resume**, `provider_model.refreshAllLaneTools` additionally
  re-syncs the registry's MCP records and pushes the merged list into EVERY live,
  turn-free lane client — background lanes used to keep the previous project's
  tool set until respawn (2026-09-24).

Remaining timing limitation: these rebuilds are snapshots. Servers still connecting
at switch time contribute tools only via the later MCP tick, and mid-session MCP/plugin
changes reach only newly-created or live-viewed clients — a background lane's
`tools_json` reflects the moment its client was last pushed. A stale-advertised tool
degrades in-band (`MCP server not found` / a failed tool result), never dangles.

`buildMcpToolSchemas()` collects all discovered tools from `.connected` servers and
`updateTools()` rebuilds the client's serialized tool list in place (driven by
`AgentRuntime.syncToolJson` — see AGENTS.md), alongside the
built-in tools. The model sees them as regular function-calling tools with namespaced
names (`mcp__<server>__<tool>`).

### Phase D — Execution (agent turn)

When the model calls an MCP tool:

1. Executor parses `mcp__<server>__<tool>` to extract server and tool name.
2. Finds the connected `McpClient` by server name.
3. Sends `tools/call` JSON-RPC request with the tool name and arguments.
4. Parses the response `content` array (text blocks) and returns the result to the model.

---
