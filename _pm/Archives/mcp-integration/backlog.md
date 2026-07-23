# backlog — mcp-integration

MCP tool keşfi ve AI tool pipeline'ı arasında köprü eksik. MCP server'lar
TUI'de goruntuleniyor ama tool sayısı 0 cunku:

1. Tool keşfi statik JSON dosya taraması yapıyor (gercek `tools/list`
   JSON-RPC cagrisi yok)
2. Kesfedilen `McpTool` tipi `tools_common.Tool` tipine donusturulmuyor
3. `ai.Config.tools` sadece `tools_mod.registry` (bash) alicek sekilde
   hardcode edilmis — MCP tool'lari hicbir zaman model'e gonderilmiyor
4. Executor `mcp__` prefix'li tool cagrilarini tanimiyor
5. `McpServerConfig.args` parse ediliyor ama `McpClient.init`'e gecilmiyor
6. Hicbir gercek subprocess/HTTP transport katmani yok

## Architectural decision

`tools_common.Tool` comptime bilinen `run`/`display` fonksiyon pointer'lari
tasiyor. MCP tool'lari runtime'da keşfediliyor ve fonksiyon pointer'lari yok.
Cozum: `ai.Config`'e `mcp_tools: []const McpToolSchema` alani ekle
(additive — mevcut `tools` alani dokunulmuyor). Her adapter her iki listeyi de
serialize eder. Executor `mcp__` prefix'ine gore dispatch eder.

## Phases

- [ ] Phase 1 — Process lifecycle & stdio transport
- [ ] Phase 2 — MCP handshake & real tool discovery (`tools/list`)
- [ ] Phase 3 — Tool injection into AI context (`ai.Config.mcp_tools`)
- [ ] Phase 4 — MCP tool execution (`tools/call` dispatch in executor)
- [ ] Phase 5 — SSE transport (remote `url`-based MCP servers)
- [ ] Phase 6 — TUI polish (live tool counts, latency, reconnect, errors)

## Future / nice-to-have

- [ ] `notifications/tools/list_changed` ile canli tool guncellemesi
- [ ] MCP resource ve prompt destegi (su an sadece tools)
- [ ] MCP server logging (stderr → debug log)
