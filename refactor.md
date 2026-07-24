# Nova Refactor Planı

## Hedef: Kod tabanını tigerstyle prensiplerine göre iyileştirmek

### ✅ Adım 1: Testleri `tui.zig`'den ilgili modüllere taşı (TAMAMLANDI)
- `parseDiffCounts` testi → `src/tui/diff_utils.zig`
- `diffCountLabels` testi → `src/tui/diff_utils.zig`
- `diffCountLabelRightAligned` testi → `src/tui/widgets/input.zig`
- `inputWrapping` testi → `src/tui/widgets/input.zig`
- 4 layout testi → `src/tui/layout.zig`
- Taşınan testler `tui.zig`'den kaldırıldı (~96 satır azaldı)

### ✅ Adım 2: Delegate metotları kaldır (KISMİ TAMAMLANDI)
- **permission_mod** (3 delegate): `permissionPending`, `handlePermissionKey`, `resolvePermission` → kaldırıldı
- **at_search_mod** (3 delegate): `updateAtSearch`, `acceptAtSelection`, `closeAtSearch` → kaldırıldı
- Tüm call siteleri güncellendi, import'lar eklendi
- Toplam: 6 delegate kaldırıldı, ~30 satır azaldı
- Kalan ~75 delegate: testler `tui.zig` içinde olduğu için toplu kaldırma kırılıyor. Her modül tek tek ele alınmalı.

### ⏳ Adım 3: RootWidget'ı `tui/root_widget.zig`'e çıkar
- `captureEvent`, `handleEvent`, `handleTick`, `drainAgentEvents`
- `drawRoot`, diff key handler'ları, `closeDiff`

### ⏳ Adım 4: Komut çözümleme + yardımcı fonksiyonları ayır
- `AtSearchWidget` → `src/tui/widgets/at_search.zig`
- `writeBorderTextEndingAt`, `writeBorderLabelRight` → `panel.zig` (zaten var)
- `modelPickerScope`, `reasoningOptions` → uygun modüllere

### ⏳ Adım 5: `agent.zig`'i parçala
- `Compactor` → `src/agent/compactor.zig` (oluşturuldu, entegrasyon bekliyor)
- `MessageQueue` + `QueuedUserMessage` → `src/agent/queue.zig`
- `ToolBatch` → `src/agent/tool_batch.zig`

### ⏳ Adım 6: `session.zig`'i parçala
- `EntryId`, `SessionId` → `src/session/types.zig`
- `SessionWriter` → `src/session/writer.zig`
- `SessionManager` → `src/session/manager.zig`
- Migrasyon mantığı → `src/session/migration.zig`

### ⏳ Adım 7: Assertion'ları güçlendir
- Her `pub fn` girişinde parametre assert'leri
- State geçişlerinde assertion
- İki yönlü assertion (yazma öncesi + okuma sonrası)

### ⏳ Adım 8: İsimlendirme düzeltmeleri
- Birim/sıfat sıralaması
- Kısaltmalar
- Değişken isimlerinde birim ekleme

---

# Persistence İyileştirmeleri

## Hedef: Kullanıcı deneyimini iyileştirmek için kalıcılığı artırmak

### ✅ Adım P1: Session listesinin `/resume`'de görünmemesi (DÜZELTİLDİ)
- `openResumePicker()` içinde `reloadResumeSessions()` çağrılmıyordu
- Düzeltme: `src/tui/session_switcher.zig`'e `try app.reloadResumeSessions()` eklendi

### ✅ Adım P2: Prompt History Persistence (TAMAMLANDI)
- `prompt_history` tablosu eklendi (session DB'sinde, schema v2→v3)
- `Session.savePromptHistory()` / `Session.loadPromptHistory()` eklendi
- `SessionWriter.savePromptHistory()` / `SessionWriter.loadPromptHistory()` eklendi
- `beginSubmit()` içinde her prompt DB'ye yazılıyor
- `installRuntime()` içinde session resume'da prompt history yükleniyor
- Dosyalar: `src/session.zig`, `src/session/migration.zig`, `src/tui/turn_lifecycle.zig`, `src/tui/transcript_lifecycle.zig`

### ✅ Adım P3: Son Aktif Session'a Otomatik Resume (TAMAMLANDI)
- `SessionManager.findLatest()` eklendi — cwd'ye göre en son güncellenen session'ı bulur
- `root.zig`'de startup'ta `findLatest()` çağrılıyor, varsa `initResume()` ile devam ediliyor
- Yoksa normal `initNew()` ile yeni session açılıyor
- Dosyalar: `src/session.zig`, `src/root.zig`

### ✅ Adım P4: Session Export (Gerçek Dosyaya Yazma) (TAMAMLANDI)
- `/export_session` → `~/.nova/exports/<session_id>-<timestamp>.md`
- Transcript mesajları Markdown formatında yazılıyor (user/agent/tool/notice ayrımı)
- Başarılı export mesajı dosya yoluyla birlikte gösteriliyor
- Dosya: `src/tui/mode_lifecycle.zig`

### ⏳ Adım P5: Diff Yorumlarının Session'a Kaydedilmesi (ERTELENDİ)
- Diff comment'leri session entry olarak kaydetmek için `diff_viewer.State`'in
  `session_writer` referansına ihtiyacı var — bu mevcut mimaride temiz bir
  bağlantı gerektiriyor. Ayrı bir PR'da ele alınmalı.
