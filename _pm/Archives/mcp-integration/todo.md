# todo — mcp-integration

## Phase 1 — Process lifecycle & stdio transport

`src/mcp/client.zig`:

- [ ] 1.1 `McpClient.init` imzasina `args: []const []const u8` ekle
  - Su an: `init(gpa, name, command, url)` — args yok
  - `config.McpServerConfig.args` parse ediliyor ama hic kullanilmiyor
  - `manager.syncFromConfig` / `syncFromConfigEx` icinde `server_cfg.args`'i gec
- [ ] 1.2 `McpClient.process: ?std.process.Child` alani ekle
  - Subprocess'i `command` + `args` ile spawn et
  - stdin/stdout pipe'larini ac (`stdio` transport icin)
  - `stderr`'i log'la veya goredir (crash detection icin)
- [ ] 1.3 `McpClient.startStdio(gpa, io) !void` metodu
  - `std.process.Child.init` ile child process baslat
  - `.stdin_behavior = .Pipe`, `.stdout_behavior = .Pipe`
  - Process baslayamazsa `status = .failed` ata, hatayi log'la
- [ ] 1.4 `McpClient.sendRequest(method, params_json) ![]u8`
  - `transport.formatRequest` ile JSON-RPC frame olustur
  - stdin'e yaz
  - stdout'tan bir satir oku (line-delimited framing)
  - Response'u parse et, `result` veya `err` dondur
- [ ] 1.5 `McpClient.stop() void`
  - Subprocess'i kibarca sonlandir (`kill` → `wait`)
  - Pipe'lari kapat
  - `status = .disabled` ata

`src/mcp/transport.zig`:

- [ ] 1.6 `readLine(reader, gpa) ![]u8` — stdout'tan bir newline-delimited
      JSON-RPC mesaj oku (su an sadece format var, I/O yok)

Tests:

- [ ] 1.7 `echo` mock server ile `sendRequest` round-trip testi
  - Basit bir shell script: stdin oku, echo'la geri ver
  - `formatRequest` → `sendRequest` → response parse

## Phase 2 — MCP handshake & real tool discovery

`src/mcp/client.zig`:

- [ ] 2.1 `McpClient.initialize(gpa, io) !void` — MCP handshake
  - `initialize` request gonder: `{ protocolVersion, capabilities, clientInfo }`
  - Response'tan `serverInfo`, `capabilities` sakla
  - `notifications/initialized` notification gonder
  - `status = .connected` ata
- [ ] 2.2 `McpClient.listTools(gpa, io) ![]McpTool` — `tools/list` sorgusu
  - `tools/list` JSON-RPC request gonder
  - Response'tan her tool icin `name`, `description`, `inputSchema` cikar
  - `inputSchema`'yi `tools_common.Schema`'ya cevir (JSON Schema → Property list)
  - Her tool icin `addTool` cagir (`full_name = mcp__{server}__{tool}`)
- [ ] 2.3 `discoverToolsForClient`'i degistir — statik dosya taramasini kaldir,
      yerine `client.initialize()` + `client.listTools()` cagirisi koy
  - Su anki kod `~/.config/nova/mcp/<name>/` altinda JSON dosya ariyor —
    hicbir gercek MCP server bu dosyalari yazmiyor

`src/mcp/manager.zig`:

- [ ] 2.4 `syncFromConfigEx` icinde `discoverToolsForClient` cagirisini
      `client.initialize() catch { status = .failed }` + `client.listTools()`
      seklinde degistir
- [ ] 2.5 `inputSchema` → `Schema` donusum helper'i (`mcp/schema_convert.zig`)
  - JSON Schema `properties` object → `[]const Schema.Property`
  - `type: "string"` → `.string`, `"integer"` → `.integer`, `"object"` → `.object`
  - `required: []string` array → `Property.required = true/false`

Tests:

- [ ] 2.6 Mock MCP server ile full handshake + tools/list testi
  - Python/bash script: `initialize` ve `tools/list`'e sabit response ver

## Phase 3 — Tool injection into AI context

`src/ai.zig`:

- [ ] 3.1 `McptoolSchema` struct tanimla
  ```zig
  pub const McpToolSchema = struct {
      name: []const u8,       // mcp__server__tool
      description: []const u8,
      schema: tools_common.Schema,
  };
  ```
- [ ] 3.2 `Config.mcp_tools: []const McpToolSchema = &.{}` alani ekle (additive)

`src/ai/openai_compatible.zig`:

- [ ] 3.3 `buildToolsJson` imzasini degistir: hem `tools` hem `mcp_tools` al
  - Yada: `buildAllToolsJson(gpa, tools, mcp_tools)` — iki listeyi birlestirip
    tek JSON array uret
  - Her MCP tool icin ayni `writeToolDefinition` formatini kullan

`src/ai/openai_responses.zig` + `src/ai/codex_responses.zig`:

- [ ] 3.4 Ayni `buildToolsJson` degisikligini uygula (3 adapter var)

`src/runtime.zig`:

- [ ] 3.5 `connectXxxClient` metodlarina `mcp_tools: []const McpToolSchema`
      parametresi ekle
  - Veya: `AgentRuntime.mcp_manager: ?*McpManager` referansi tut, client
    baglanirken tool listesini dinamik olustur
- [ ] 3.6 `ai.Config` olustururken `.mcp_tools = ...` ata
  - `mcp_manager.totalActiveTools()` tool'larini `McptoolSchema`'ya project et

`src/tui.zig` (App → runtime baglantisi):

- [ ] 3.7 Provider baglandiginda `app.mcp_manager`'dan MCP tool listesi al,
      `runtime.connectXxxClient`'a gec

Tests:

- [ ] 3.8 `buildToolsJson` MCP tool'larini iceriyor — unit test
- [ ] 3.9 `writeRequestPayload` `"tools"` array'inde MCP tool'lari var — unit test

## Phase 4 — MCP tool execution

`src/executor.zig`:

- [ ] 4.1 `ExecutorService.mcp_manager: ?*mcp_mod.McpManager` alani ekle
  - Veya: `mcp_dispatch: ?*const fn(server, tool, args) Error!Output`
- [ ] 4.2 `runOne` icinde `mcp__` prefix kontrolu
  ```zig
  if (std.mem.startsWith(u8, call.name, "mcp__")) {
      return self.runMcpTool(call);
  }
  ```
- [ ] 4.3 `runMcpTool(call) !ToolResult`
  - Tool adindan server adini cikar: `mcp__server__tool` → `server`, `tool`
  - `mcp_manager`'dan ilgili `McpClient`'i bul
  - `client.callTool(tool_name, arguments)` cagir
  - Response'u `ToolResult`'a cevir

`src/mcp/client.zig`:

- [ ] 4.4 `McpClient.callTool(gpa, io, tool_name, args_json) ![]u8`
  - `tools/call` JSON-RPC request: `{ name, arguments }`
  - Response'tan `result.content` cikar (text content blocks)
  - Hata durumunda `isError: true` kontrol et

`src/agent.zig` (veya runtime):

- [ ] 4.5 ExecutorService olusturulurken `mcp_manager` referansini gec

Tests:

- [ ] 4.6 Mock MCP server ile `tools/call` round-trip testi
- [ ] 4.7 Bilinmeyen `mcp__` tool → graceful failure (not crash)

## Phase 5 — SSE transport (remote MCP)

`src/mcp/client.zig`:

- [ ] 5.1 `McpClient.connectSse(gpa, io, url) !void`
  - HTTP GET → SSE event stream (server → client)
  - HTTP POST → JSON-RPC request (client → server)
  - SSE endpoint URL'yi `initialize` response'undan al (MCP spec)
- [ ] 5.2 `startStdio` / `connectSse` — `command` varsa stdio, `url` varsa SSE

Tests:

- [ ] 5.3 Mock SSE server ile handshake testi

## Phase 6 — TUI polish

`src/tui/widgets/mcp_status.zig`:

- [ ] 6.1 Tool count'u gercek keşif sonrasinda goster (su an statik dosya
      taramasindan geliyor — Phase 2 sonrasi duzelecek)
- [ ] 6.2 Latency gosterimi (`initialize` response suresi)
- [ ] 6.3 Hata mesaji gosterimi (`status = .failed` icin neden)

`src/tui/command_router.zig` (`McpMode.handle`):

- [ ] 6.4 `Ctrl+R` / `r` reconnect — `client.stop()` + `client.startStdio()` +
      `client.initialize()` + `client.listTools()`
- [ ] 6.5 Space toggle — disable yapinca tool'lari `ai.Config.mcp_tools`'tan kaldir

`docs/MCP.md`:

- [ ] 6.6 Dokumani gercek implementasyonla senkronize et
  - Su an `tools/list` sorgulandigini iddia ediyor — Phase 2'ye kadar yalan
