//! Async model loading jobs, outcome installation, and disk cache persistence.

const std = @import("std");
const log = std.log.scoped(.tui);
const config_mod = @import("../config/config.zig");
const model_cache = @import("model_cache.zig");
const model_loader = @import("model_loader.zig");
const provider_model = @import("provider_model.zig");
const tui = @import("../tui.zig");

const App = tui.App;

pub fn cancelModelLoad(self: *App) void {
    if (self.pickers.models.load == .loading) {
        var future = self.pickers.models.load.loading.future;
        var outcome = future.cancel(self.io);
        outcome.deinit(self.gpa);
        self.pickers.models.load = .idle;
    }
}

/// Called from the tick handler. Polls the non-blocking `done` flag, and
/// only `await`s once the worker has signalled completion. Returns true
/// if a redraw is needed.
pub fn drainModelLoad(self: *App) !bool {
    if (self.pickers.models.load != .loading) return false;
    if (!self.pickers.models.load.loading.done.load(.acquire)) return false;

    var outcome = self.pickers.models.load.loading.future.await(self.io);
    self.pickers.models.load = .idle;
    defer outcome.deinit(self.gpa);

    switch (outcome) {
        .ready => |*result| try installModelLoadResult(self, result),
        .failed => |message| {
            self.pickers.models.load = .{ .failed = .{ .message = try self.gpa.dupe(u8, message) } };
        },
    }
    return true;
}

pub fn installModelLoadResult(self: *App, result: *model_loader.Result) !void {
    if (self.pickers.models.load == .loading and self.pickers.models.load.loading.merge) {
        // Incremental load: replace only the freshly-fetched providers'
        // models, leaving previously-cached providers untouched. Conn-bazlı
        // dedup: çoklu `.openai_compatible` provider'lar aynı enum değerini
        // paylaştığından `EnumSet` onları birleştirirdi — `auth_key_id` her
        // bağlantıyı benzersiz tanımlar.
        var refreshed = std.StringHashMap(void).init(self.gpa);
        defer refreshed.deinit();
        for (result.sources.items) |source| switch (source) {
            .openai_compatible => |conn| {
                if (refreshed.contains(conn.auth_key_id)) continue;
                try refreshed.put(conn.auth_key_id, {});
                dropModelsForConn(self, conn);
            },
            .openai_codex => {},
        };
    } else {
        provider_model.codexModelsClear(self);
    }
    // Move models in (the struct copies own their id/label); clearing the
    // result without freeing avoids a double-free. `models` and `sources`
    // are built in lockstep, so they zip into one entry each.
    std.debug.assert(result.models.items.len == result.sources.items.len);
    for (result.models.items, result.sources.items) |*model, source| {
        try self.pickers.models.append(self.gpa, model.*, source);
    }
    result.models.clearRetainingCapacity();
    result.sources.clearRetainingCapacity();
    // load was set to .idle by drainModelLoad before calling us; nothing
    // else to reset.
    // Same fetch that built the catalogue also tells us which providers are
    // reachable — drive the picker badges from it.
    provider_model.applyProviderOutcomes(self, result.outcomes.items);
    try provider_model.finishModelCatalogReload(self);
    try provider_model.snapshotModelPickerState(self);
    self.pickers.models.models_cached = true;
    saveModelCache(self) catch |err| log.warn("models.cache.save.failed err={s}", .{@errorName(err)});
}

/// Remove every cached model that came from `provider`. Builtin katalog
/// provider'ları için uygundur (her biri ayrı bir enum değeridir).
pub fn dropModelsForProvider(self: *App, provider: config_mod.Provider) void {
    self.pickers.models.dropProvider(self.gpa, provider);
}

/// Remove every cached model sourced from `conn`. Çoklu `.openai_compatible`
/// provider'lar aynı enum değerini paylaştığından, bunlar için enum-bazlı
/// `dropModelsForProvider` tüm provider'ları birleştirir — conn-bazlı bu
/// versiyon yalnızca verilen bağlantıya ait entry'leri düşürür.
pub fn dropModelsForConn(self: *App, conn: model_loader.Compatible) void {
    self.pickers.models.dropConn(self.gpa, conn);
}

pub fn restoreModelCache(self: *App) !bool {
    const runtime = self.liveRuntime() orelse return false;
    if (runtime.home_dir.len == 0) return false;

    var configured = try collectModelCacheConfigured(self);
    defer configured.deinit(self.gpa);

    var cached = model_cache.load(self.gpa, self.io, runtime.home_dir, configured.items) catch return false;
    defer cached.deinit(self.gpa);

    provider_model.codexModelsClear(self);
    for (cached.items.items) |*record| {
        try self.pickers.models.append(self.gpa, record.model, record.source);
        // Model ve source artık entry'ye taşındı (struct field'ları alias
        // ediyor); sahipliği devret ve cached.deinit'in onları tekrar free
        // etmesini önle.
        record.model = .{ .id = &.{}, .label = &.{} };
        record.source = .openai_codex;
    }
    if (self.isCodexSignedIn()) try provider_model.loadCodexStaticCatalog(self);
    if (self.pickers.models.len() == 0) return false;

    try provider_model.finishModelCatalogReload(self);
    try provider_model.snapshotModelPickerState(self);
    self.pickers.models.models_cached = true;
    return true;
}

pub fn saveModelCache(self: *App) !void {
    const runtime = self.liveRuntime() orelse return;
    if (runtime.home_dir.len == 0) return;

    var configured = try collectModelCacheConfigured(self);
    defer configured.deinit(self.gpa);
    if (configured.items.len == 0) return;

    const records = try self.gpa.alloc(model_cache.Record, self.pickers.models.entries.items.len);
    defer self.gpa.free(records);
    for (self.pickers.models.entries.items, 0..) |entry, index| {
        records[index] = .{ .model = entry.model, .source = entry.source };
    }
    try model_cache.save(self.gpa, self.io, runtime.home_dir, records, configured.items);
}

pub fn collectModelCacheConfigured(self: *App) !std.ArrayList(model_cache.Configured) {
    var list: std.ArrayList(model_cache.Configured) = .empty;
    errdefer list.deinit(self.gpa);

    for (config_mod.catalogueProviders()) |provider| {
        const base_url = provider.defaultBaseUrl() orelse continue;
        const auth_mode: model_cache.AuthMode = if (self.provider_state.api_keys.get(provider.label())) |_|
            .keyed
        else if (provider.anonymousApiKey() != null)
            .anonymous
        else
            continue;
        try list.append(self.gpa, .{
            .provider = provider,
            .base_url = base_url,
            .auth_mode = auth_mode,
            .auth_key_id = provider.label(),
        });
    }

    // Dynamic/config OpenAI-uyumlu provider'lar. Online `collectConfiguredProviders`
    // iki kolla toplar (BLOCK 2: models.dev registry, BLOCK 3: config providers[]
    // map); disk cache burada aynı iki kolu toplar ki restart sonrası bağlı
    // tüm provider'ların modelleri restore edilsin. Önceki kod yalnızca
    // `model_selection`'daki tek aktif provider'ı yazıyordu, bu yüzden bir
    // oturumda birden çok provider bağlansa bile restart'ta yalnızca
    // `defaultModel`'in provider'ı geri geliyordu — diğerleri kayboluyordu.
    //
    // (a) Config `providers[]` map'inde özel URL'si olan her
    // `.openai_compatible` provider (kullanıcı tarafından config.json'da
    // tanımlanan özel endpoint'ler).
    for (self.cached_config.providers) |pc| {
        if (pc.provider != .openai_compatible) continue;
        // Katalog provider'ları BLOCK 1 tarafından zaten toplandı.
        if (pc.provider.isCatalogue()) continue;
        const base_url = switch (pc.base_url) {
            .custom => |url| url,
            // URL yoksa cache'e yazılamaz (online yol da default'a düşer ama
            // `.openai_compatible`'ın default URL'i olmadığından atlanır).
            .default => continue,
        };
        // auth.json'da bu provider için key yoksa fetch de yapamaz, atla.
        if (self.provider_state.api_keys.get(pc.name) == null) continue;
        try list.append(self.gpa, .{
            .provider = .openai_compatible,
            .base_url = base_url,
            .auth_mode = .keyed,
            // Config map key == auth.json key, böylece restart'ta doğru
            // bağlantıya eşleşir.
            .auth_key_id = pc.name,
        });
    }

    // (b) models.dev registry'de tanımlı dynamic provider'lar (auth.json'da
    // key'i olan her provider). Online `collectConfiguredProviders` BLOCK 2'nin
    // birebir muadili.
    if (self.provider_state.modelsdev_registry) |*reg| {
        var it = self.provider_state.api_keys.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            // Katalog label'ları BLOCK 1 tarafından toplandı.
            if (provider_model.catalogueIndexById(id) != null) continue;
            if (reg.lookup(id)) |dyn_p| {
                try list.append(self.gpa, .{
                    .provider = .openai_compatible,
                    .base_url = dyn_p.base_url,
                    .auth_mode = .keyed,
                    .auth_key_id = id,
                });
            }
        }
    }

    if (config_mod.Provider.ollama.defaultBaseUrl()) |base_url| {
        try list.append(self.gpa, .{
            .provider = .ollama,
            .base_url = base_url,
            .auth_mode = .anonymous,
            .auth_key_id = "ollama",
        });
    }

    return list;
}
