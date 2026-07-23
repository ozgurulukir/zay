# MCP İyileştirme Önerileri

Bu doküman `src/mcp/` paketi ve `executor.runMcpTool` üzerinden tool execution
akışı için geliştirici-seviyesinde iyileştirme önerilerini içerir. Öneriler
`codebase-memory-mcp` üzerinden yapılan statik analiz ve kod incelemesi ile
üretilmiştir.

> **Kapsam:** `src/mcp/transport.zig`, `src/mcp/client.zig`,
> `src/mcp/manager.zig`, `src/executor.zig` (MCP branch).

---

## Önceliklendirme özeti

| #   | Konu                                          | Etki | Efor | Öncelik |
| --- | --------------------------------------------- | ---- | ---- | ------- |
| 1   | `sendRequest` concurrency/framing             | Yüksek | Orta | 🔴 P0  |
| 2   | `syncFromConfigEx` state machine              | Orta  | Düşük | 🟠 P1 |
| 5   | `McpClient` ownership/RAII                    | Orta  | Orta | 🟠 P1  |
| 4   | `schemaFromJsonSchema` edge cases             | Yüksek | Yüksek | 🟠 P1 |
| 7   | Error mesajları                               | Orta  | Düşük | 🟡 P2 |
| 3   | `callTool` refactor                           | Düşük | Düşük | 🟡 P2 |
| 8   | Validation                                    | Orta  | Düşük | 🟡 P2 |
| 6   | Transport test coverage                       | Düşük | Düşük | 🟢 P3 |
| 9   | Tool discovery token cost                     | Düşük | Yüksek | 🟢 P3 |
| 10  | TUI graceful shutdown                         | Düşük | Orta | 🟢 P3  |

---

## 1. `sendRequest` — concurrency & framing sınırları (P0)

### Kanıt
`src/mcp/client.zig:145-182` (47 satır, complexity 3):

```zig
const id = self.next_request_id;
self.next_request_id += 1;
try stdin.writeStreamingAll(io, request);

var poll_fds: [1]std.posix.pollfd = .{.{ .fd = stdout.handle, .events = .POLLIN }};
_ = std.posix.poll(&poll_fds, 30_000) catch return error.Timeout;

var buf: [64 * 1024]u8 = undefined;
var reader = stdout.reader(io, &buf);
_ = reader.interface.streamDelimiterEnding(&line_writer.writer, '\n') catch ...;
```

### Problemler
- **Id race condition'ı.** `next_request_id` lock'suz artırılıyor. Manager
  seviyesinde `McpClient` paylaşımlı kullanılıyor; executor bugün serial
  çalışıyor ama gelecekte paralel tool çağrılarına geçiş anında bu sessizce
  bozulur.
- **64KB satır sınırı.** `streamDelimiterEnding('\n')` 64KB'lık buffer'a
  sığmayan response'lar kesilir. MCP standardı `Content-Length` framing'i
  opsiyonel olarak tanıyor; line-delimited yetersiz kalıyor.
- **30s timeout hardcoded.** Yorum niteliğinde timeout, tool bazlı
  configure edilebilir olmalı.
- **Pipe handling eksik.** MCP server erken kapanırsa
  `streamDelimiterEnding` `error.ReadFailed` döner — ama bu hata sadece
  generic `error.ReadFailed` olarak propagate ediliyor, "server crashed"
  sinyali kayboluyor.

### Öneriler
1. `Mutex` (veya `std.Io.Mutex`) ile `next_request_id`'yi koru, veya
   atomik ile monotonically-unique id üret.
2. Framing'i **Content-Length** destekleyecek şekilde genişlet; framing
   mode'u `startStdio`'da server'la negotiate et (MCP `initialize`
   response'unda `capabilities` kontrolü).
3. Timeout'ı `McpClient` field'ı yap, `manager.connectAndDiscover`'da
   tool kategorisine göre ayarla.
4. `process.kill()` + `error.McpServerCrashed` ayrımı ekle — generic
   `error.ReadFailed`'dan daha bilgilendirici.

---

## 2. `manager.syncFromConfigEx` — state machine'e böl (P1)

### Kanıt
`src/mcp/manager.zig:57-104` (48 satır, **complexity 7**).

### Problemler
- 4 farklı durum dalı (yeni ekle / var olan enabled / var olan disabled
  / değişiklik var) tek fonksiyonda, comment yok.
- **Removed server'lar ne oluyor?** `syncFromConfigEx` sadece
  `config.mcp_servers`'ta olanları dolaşıyor; config'den çıkarılan
  server'lar `manager.clients`'ta zombi olarak kalıyor. Hem bellek hem
  de "feature toggle" UX'i olarak yanlış.
- `reconnectClient` zaten ayrı bir fonksiyon; ama `syncFromConfigEx`
  onu çağırmıyor — diff detection'ı re-implement etmiş.

### Öneriler
1. **Reconciliation pattern'i uygula** (Kubernetes controller tarzı):
   ```
   desired = config.mcp_servers
   current = self.clients
   for d in desired \\ current: add(d)
   for c in current \\ desired: remove(c)        // deinit + free
   for d in desired ∩ current:  reconcile(d, c)  // toggle/reconnect
   ```
2. Set theory farklarını gerçek `StringHashMap` ile yap (linear scan
   O(n²) yerine, nadir önemli ama okunabilirlik için).
3. `syncFromConfig` ve `syncFromConfigEx` çiftinin sebebini netleştir;
   gerekmiyorsa tek fonksiyona indir.

---

## 3. `client.callTool` — complexity 11, manuel JSON birleştirme (P2)

### Kanıt
`src/mcp/client.zig:279-325` (47 satır, **complexity 11**):

```zig
var params: std.ArrayList(u8) = .empty;
defer params.deinit(self.gpa);
try params.appendSlice(self.gpa, "{\"name\":\"");
try params.appendSlice(self.gpa, tool_name);
try params.appendSlice(self.gpa, "\",\"arguments\":");
try params.appendSlice(self.gpa, arguments_json);
try params.append(self.gpa, '}');
```

### Problemler
- **String escape yapılmıyor.** `tool_name` JSON'a direkt concatenate
  ediliyor. MCP standardı tool adlarında `[a-zA-Z0-9_-]` zorunlu kılıyor
  ama defensive programming adına `std.json.Stringify.value` kullan.
- **Allocation sayısı:** 6 ayrı `appendSlice` + 1 `append` = 7 allocator
  call. Tek `std.Io.Writer.Allocating` ile tek seferde yaz.
- **Image content ignore:** `callTool` response'da sadece `text` tipini
  destekliyor — `image`/`audio`/`resource` sessizce düşüyor. Bu
  bilinçliyse yorum yok, değilse TODO.

### Öneriler
1. `transport.formatRequest` gibi `formatCallToolParams` helper'ı yaz,
   `std.json.Stringify.value` ile.
2. `arguments_json` zaten JSON string — direkt embed et; aynısını `name`
   için de yap, `std.json.Stringify.value` ile escape ederek.
3. `callTool` complexity 11'i 4-5'e indir: parse → build params → send
   → extract content → return. Her adım helper.

---

## 4. `schemaFromJsonSchema` — complexity 8, edge cases (P1)

### Kanıt
`src/mcp/client.zig` (42 satır, **complexity 8**).

### Problemler
- **Graf indeksinde gözükmüyor** detayı, ama complexity 8 yüksek —
  muhtemelen nested type/array/union handling'i tek yerde.
- **`$ref` / `oneOf` / `anyOf` desteği?** MCP serverları bunları yaygın
  kullanıyor (örn. GitHub MCP). Bunlar handle edilmiyorsa tool
  çağrıları sessizce başarısız oluyor.
- **`default` / `enum` / `format` / `description` alanları** schema'da
  var ama `tools_common.Schema` yapısı bunları destekliyor mu belirsiz.

### Öneriler
1. `Schema` struct'ına `oneOf`/`anyOf`/`enum` field'ları ekle, veya
   dönüşüm sırasında bilinen sınırlı küme için yeterli olduğunu test et.
2. En az 5-6 representative JSON Schema örneğiyle (nested object, array
   of objects, enum, optional field, $ref) snapshot testleri yaz.
3. Schema dönüşümünde **fail-loud** ol — sessizce boş schema dönmektense
   `error.UnsupportedJsonSchemaFeature` fırlat ki kullanıcı server'ı
   disable edebilsin.

---

## 5. `McpClient` ownership & deinit — fan-in 17 (P1)

### Kanıt
- `mcp.client.deinit` fan-in: 17 (graph indeksi)
- `mcp.client.init` fan-in: 11
- `mcp.client.stop` fan-in: 7

### Problemler
- 17 ayrı test veya owner — her test bir `McpClient` alloc/dealloc
  ediyor. Test fixture standardizasyonu eksik.
- `McpClient` struct'ında 9+ `gpa.dupe(u8, ...)` allocation var (init
  içinde). Test helper'ı bu duplication'ı soyutlamalı.
- `deinit` çağrılmadan struct drop edilirse **child process orphan**
  kalır — `process` field'ı `?std.process.Child` ama destructor yok.
  `defer` zinciri her yerde tutulmalı.

### Öneriler
1. `McpClient` için **RAII guard** benzeri bir `ScopedMcp` helper yaz:
   ```zig
   pub fn scoped(self: *McpClient, io: std.Io) ScopedMcp {
       return .{ .client = self, .io = io };
   }
   // ScopedMcp.deinit() → client.stop(io)
   ```
   Testlerde `defer scoped.deinit()` standardı.
2. `process != null` ise otomatik kill eden bir `childWatcher` thread
   veya signal handler ekle — orphan process'leri engelle.
3. `mcp.client.deinit` çağrılarını 17 → 2-3'e indir (manager üzerinden
   tek nokta).

---

## 6. `mcp.transport` — gözlem/test coverage (P3)

### Kanıt
- `formatRequest` 3 test var, `formatNotification` 1 test, `parseMessage`
  test yok.
- Transport katmanı 5 satırla çalışıyor ama sınır durumları test
  edilmemiş: nested JSON, escape, boş params, malformed response, çok
  uzun satır.

### Öneriler
- Property-based test: `formatRequest(id, method, params)` → parse →
  roundtrip eşitliği.
- Malformed input testleri: `parseMessage("{malformed")`,
  `parseMessage("")`, `parseMessage("not json at all")`.
- Bu katman sıfır `McpClient` bağımlılığıyla test edilebilir, hızlı
  feedback.

---

## 7. Error set'leri — error passthrough kaosa yol açıyor (P2)

### Kanıt
- `executor.runMcpTool` `client.callTool(...) catch |err| { return
  self.runFailure(call, err); }` — MCP error'ları generic `ToolResult
  { failed = true, content = err }` olarak dönüyor.
- MCP `parseResponse`'da error code → Zig error set dönüşümü var ama
  **error code → kullanıcı-okunabilir mesaj** mapping'i yok.

### Problemler
- Model `error.McpServerError: -32603` alıyor, bunun anlamı "internal
  server error" — modele yardımcı olmuyor.
- `error_message: ?[]u8` field'ı `McpClient`'da var ama kullanıcıya
  hiçbir yerde gösterilmiyor (graph'ta `McpStatus` widget'ı var ama
  sadece status label gösteriyor olabilir).

### Öneriler
1. `McpClient`'a `lastErrorFormatted()` helper'ı ekle, error code →
   string.
2. ToolResult'a `display_body` olarak `lastErrorFormatted()` yaz
   (`display_kind = .error` ekle).
3. TUI'da `McpStatus` widget'ı bu mesajı gösterebilsin.

---

## 8. Manager'ın sıfır validasyon katmanı (P2)

### Kanıt
`syncFromConfig` server_cfg.command, args, url alanlarını doğrulamadan
`McpClient.init`'e geçiriyor.

### Problemler
- `command = null` ve `url = null` aynı anda olan server config →
  `McpClient.init` `error.NoCommand` fırlatır ama bu ancak `startStdio`
  çağrılınca ortaya çıkar.
- `args` içinde boş string olabilir. `argv.items`'a direkt geçiyor
  (`spawn`), güvenli ama yine de validation iyi olur.
- **Server name unique mi?** Config'de iki aynı isimli server varsa
  `syncFromConfig` sadece ilkini tutar, sessizce.

### Öneriler
1. `syncFromConfig`'a validation pass'ı ekle, validation hatalarını
   ayrı listede topla ve `error_message`'a yaz.
2. Server name uniqueness check.
3. `McpClient.init` içinde `command == null && url == null` ise assert
   veya `error.McpServerMisconfigured`.

---

## 9. MCP tool'larının modele sunumu — discoverability (P3)

### Kanıt
- `buildMcpToolSchemas` tüm connected tool'ları düz liste olarak döner.
- `full_name = "mcp__<server>__<tool>"` (örn.
  `mcp__github__create_issue`).

### Problemler
- Model için context window'a tüm tool'ların schema'sı gönderiliyor. 10
  server × 20 tool = 200 schema → token cost.
- Prefix `mcp__` zorunlu ama **server adının** ne olduğu tool adından
  çıkarılamıyor (örn. `mcp__fs__read_file` vs
  `mcp__filesystem__read_file` — hangisi?).

### Öneriler
1. **Server gruplama:** System prompt'ta "available MCP servers" ayrı
   bir blok olarak listele, sonra tool'ları referansla. Bu token'ı
   azaltır.
2. **Tool adı çakışma kontrolü:** Aynı tool adını iki farklı server
   sunuyorsa, `full_name` çakışır. Manager bunu validate etmeli.
3. **Lazy schema fetch:** Tool adı bilinmeden tüm schema'lar yükleniyor
   — büyük serverlarda pahalı. `tools/list` zaten destekliyor; sadece
   modelin ihtiyaç duyduğu tool'ları yükleme opsiyonu eklenebilir.

---

## 10. TUI ile MCP bağlantısı — UX (P3)

### Kanıt
- `McpMode.handle` command_router'da Up/Down/j/k, Space/Enter, Ctrl+R/r,
  Esc/q routing'i var.
- `reconnectClient` var ama **disconnect** yok (sadece `disable`).

### Problemler
- Kullanıcı bir server'ı "durdur" isteyebilir ama sadece `disable` var.
  Process hala arka planda zombi olabilir.
- Server status güncellemesi event-driven değil, polling gerekebilir.
  TUI'da stale status gösterme riski.
- `reconnectClient` her şeyi durdurup yeniden başlatıyor — uzun süren
  bir tool çağrısını yarıda keser.

### Öneriler
1. `McpClient`'a `pause()`/`resume()` ekle (server çalışsın ama tool
   çağrılarını kuyruğa al).
2. Status değişikliklerini event olarak yay, TUI subscribe etsin —
   polling kaldırılsın.
3. Graceful shutdown: `stop()` SIGTERM gönderip 5s sonra SIGKILL,
   sıralı kapatma.

---

## Önerilen uygulama sırası

Hızlı kazanç için **#2** (`syncFromConfigEx` refactor) veya **#6**
(transport tests) önerilir — ikisi de küçük efor, temiz etki. En
kritik teknik borç ise **#1** (`sendRequest` concurrency).

1. **#6** — Transport test coverage (hızlı feedback kur)
2. **#2** — `syncFromConfigEx` reconciliation pattern'i
3. **#3** — `callTool` refactor (küçük, okunabilirlik)
4. **#8** — Manager validation
5. **#5** — `ScopedMcp` RAII helper
6. **#4** — Schema edge case testleri + fail-loud
7. **#7** — Error mesaj standardizasyonu
8. **#1** — `sendRequest` Content-Length + mutex (büyük refactor)
9. **#10** — TUI pause/resume
10. **#9** — Token cost optimizasyonu
