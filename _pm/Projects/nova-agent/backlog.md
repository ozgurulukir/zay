# backlog

- [ ] MCP SSE transport — remote `url`-based MCP server'lar için HTTP/SSE transport.
  Stdio transport tamamlandı (bkz. [mcp-integration](../../Archives/mcp-integration/)).
  Kalan: HTTP client + SSE event stream + JSON-RPC POST.

- [ ] Zig 0.17+ yükseltmesinde `GeneralPurposeAllocator` kullan.
  - Zig 0.16'da `SmpAllocator` multi-threaded free-list corruption hatası ("incorrect alignment" panic) geçici olarak `PageAllocator` ile bypass edildi.
  - 0.17+ yükseltmesinde `std.heap.GeneralPurposeAllocator` ile değiştir: thread-safe, memory free eder, bucket-based allocasyon yapar, `SmpAllocator` bug'ını içermez.
  - Etkilenen dosyalar: `src/main.zig`, `src/root.zig`, `src/tui.zig`, `src/arena_gpa.zig` (silinecek).
