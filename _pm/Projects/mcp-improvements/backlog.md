# backlog — mcp-improvements

Kaynak: `MCP-IMPROVEMENTS.md` (codebase-memory-mcp statik analizi + kod incelemesi).

## P0 — Kritik

- [ ] **#1** `sendRequest` concurrency & framing (`client.zig:145-182`).
  - `next_request_id` lock'suz artırılıyor — paralel tool çağrılarında race.
  - 64KB satır sınırı — büyük response'lar kesilir.
  - 30s timeout hardcoded — tool bazlı config edilebilir olmalı.
  - `error.ReadFailed` → `error.McpServerCrashed` ayrımı.
  - Content-Length framing negotiable.

## P1 — Önemli

- [ ] **#2** `syncFromConfigEx` reconciliation pattern (`manager.zig:57-104`, complexity 7).
  - Removed server'lar `clients`'ta zombie kalıyor — bellek leak + UX.
  - Reconciliation: desired ∖ current → add; current ∖ desired → remove; ∩ → reconcile.

- [ ] **#4** `schemaFromJsonSchema` edge cases (`client.zig:349-390`, complexity 8).
  - `$ref` / `oneOf` / `anyOf` desteği yok — GitHub MCP gibi serverlarda sessiz fail.
  - `enum` / `format` / `default` alanları düşüyor.
  - Fail-loud ol: `error.UnsupportedJsonSchemaFeature` fırlat.
  - 5-6 representative JSON Schema snapshot testleri.

- [ ] **#5** `McpClient` ownership & RAII (`deinit` fan-in 17).
  - `ScopedMcp` RAII guard helper.
  - `process != null` ise orphan child riski.
  - `deinit` fan-in 17 → 2-3'e indir.

## P2 — Orta

- [ ] **#3** `callTool` refactor (`client.zig:279-325`, complexity 11).
  - String escape yok — `std.json.Stringify.value` kullan.
  - 7 allocator call → tek `Writer.Allocating`.
  - Image/audio/resource content sessizce düşüyor.
  - Complexity 11 → 4-5'e indir.

- [ ] **#7** Error mesajları standardizasyonu.
  - `error.McpServerError: -32603` → "Internal server error".
  - `lastErrorFormatted()` helper.
  - ToolResult'a `display_kind = .error` ekle.

- [ ] **#8** Manager validation katmanı.
  - `command == null && url == null` → assert.
  - Server name uniqueness check.
  - `args` içinde boş string validation.

## P3 — Düşük

- [ ] **#6** Transport test coverage (`transport.zig`).
  - `parseMessage` test yok.
  - Roundtrip test: formatRequest → parse → verify.
  - Malformed input: `{malformed`, `""`, `not json`.
  - Nested JSON, escape, çok uzun satır.

- [ ] **#9** Tool discovery token cost.
  - 10 server × 20 tool = 200 schema → token maliyeti.
  - Server gruplama (system prompt'ta listele).
  - Tool adı çakışma kontrolü.
  - Lazy schema fetch.

- [ ] **#10** TUI graceful shutdown.
  - `disconnect` yok (sadece `disable`).
  - `pause()`/`resume()` — server çalışsın, tool çağrıları kuyrukta.
  - Status event-driven (polling kaldır).
  - SIGTERM → 5s → SIGKILL.
