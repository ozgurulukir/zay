# todo — mcp-improvements

Remaining items (by priority):

- [ ] **#1** `sendRequest` concurrency & framing (P0, high effort)
  - next_request_id mutex (race condition for parallel tool calls)
  - Content-Length framing (64KB line limit)
  - Configurable timeout (currently hardcoded 30s)
  - error.McpServerCrashed vs generic error.ReadFailed

- [ ] **#4** `schemaFromJsonSchema` edge cases (P1)
  - $ref / oneOf / anyOf support
  - enum / format / default fields
  - Fail-loud: error.UnsupportedJsonSchemaFeature

- [ ] **#5** `McpClient` RAII helper (P1)
  - ScopedMcp guard for test standardization
  - Orphan child prevention

- [ ] **#7** Error message standardization (P2)
  - Error code → human-readable mapping
  - lastErrorFormatted() helper

- [ ] **#9** Tool discovery token cost (P3)
- [ ] **#10** TUI graceful shutdown (P3)
