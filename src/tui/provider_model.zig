//! Provider connection, model catalogue loading, and model selection.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const ai = @import("../ai.zig");
const auth = @import("../auth.zig");
const bash_mod = @import("../bash.zig");
const codex = @import("../codex.zig");
const config_mod = @import("../config.zig");
const diff_viewer = @import("diff_viewer.zig");
const model_catalogue = @import("model_catalogue.zig");
const model_cache = @import("model_cache.zig");
const model_loader = @import("model_loader.zig");
const model_picker = @import("widgets/model_picker.zig");
const openai_compatible_mod = @import("../ai/openai_compatible.zig");
const provider_picker = @import("widgets/provider_picker.zig");
const runtime_mod = @import("../runtime.zig");
const session_mod = @import("../session.zig");
const tui_provider = @import("provider_controller.zig");
const tui_status = @import("status.zig");
const modelsdev = @import("../modelsdev.zig");

const App = tui.App;
const ModelCatalog = tui.App.ModelCatalog;
const ModelScope = model_catalogue.ModelScope;
const ModelSource = model_loader.ModelSource;
const DiffCounts = tui.DiffCounts;
pub fn openProviderPicker(self: *App) !void {
    self.mode = .provider_picker;
    self.pickers.provider.reset();
    self.clearInput();
    self.clearPaletteInput();
    try refreshProviderApiKeys(self);
    // Always refresh the models.dev registry so newly added providers
    // appear immediately instead of waiting for the 24h cache TTL.
    if (self.modelsdev_registry) |*r| {
        r.deinit(self.gpa);
        self.modelsdev_registry = null;
    }
    try ensureModelsDevRegistry(self);
    // Refresh the badges from a live model load (merge, so the catalogue isn't
    // cleared). The load's per-provider outcome drives `conn_status`, so the
    // badge reads the same source as the model picker and can't disagree.
    startModelLoad(self, .connected_provider, true) catch {};
}

pub fn ensureModelsDevRegistry(self: *App) !void {
    if (self.modelsdev_registry == null) {
        const home = if (self.liveRuntime()) |r| r.home_dir else "";
        self.modelsdev_registry = modelsdev.loadOrFetchRegistry(self.gpa, self.io, home);
    }
    if (self.modelsdev_registry) |*reg| {
        try buildMergedProviderList(self, reg.providers);
    }
}

/// Three-layer merge: builtin catalogue → models.dev (overrides) → config
/// (overrides). The result is a single `[]ProviderHandle` that the picker
/// renders uniformly.
fn buildMergedProviderList(self: *App, all_providers: []const modelsdev.Provider) !void {
    var entries: std.ArrayList(provider_picker.ProviderHandle) = .empty;
    defer entries.deinit(self.gpa);

    // Layer 1: builtin catalogue (lowest priority).
    for (config_mod.catalogueProviders()) |p| {
        try entries.append(self.gpa, .{ .builtin = p });
    }

    // Layer 2: models.dev registry (overrides builtins with same id).
    for (all_providers) |p| {
        if (std.mem.eql(u8, p.id, "openai")) continue;
        if (findEntryIndex(entries.items, p.id)) |idx| {
            entries.items[idx] = .{ .dynamic = p };
        } else {
            try entries.append(self.gpa, .{ .dynamic = p });
        }
    }

    // Layer 3: config providers (overrides everything with same name).
    // Skip entries already covered by the models.dev registry — those are
    // dynamic providers whose model selection is persisted in the providers
    // array but whose identity (name, base_url) comes from the registry.
    // Without this guard the config entry shadows the .dynamic handle and
    // the picker shows the provider as a custom/config provider.
    if (self.cached_config_owned) {
        for (self.cached_config.providers) |cp| {
            if (self.modelsdev_registry) |*reg| {
                if (reg.lookup(cp.name) != null) continue;
            }
            if (findEntryIndex(entries.items, cp.name)) |idx| {
                entries.items[idx] = .{ .config = cp };
            } else {
                try entries.append(self.gpa, .{ .config = cp });
            }
        }
    }

    if (self.entries_slice) |old| self.gpa.free(old);
    const owned = try entries.toOwnedSlice(self.gpa);
    self.entries_slice = owned;
    self.pickers.provider.entries = owned;
}

fn findEntryIndex(entries: []const provider_picker.ProviderHandle, id: []const u8) ?usize {
    for (entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.id(), id)) return i;
    }
    return null;
}

pub fn catalogueIndexById(id: []const u8) ?usize {
    for (config_mod.catalogueProviders(), 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate.label(), id)) return index;
    }
    return null;
}

/// Reload the cached provider API keys from `~/.config/nova/auth.json`. Drives the
/// picker badges and the multi-provider model catalogue.
pub fn refreshProviderApiKeys(self: *App) !void {
    const home = self.liveRuntime().?.home_dir;
    if (home.len == 0) return;
    var fresh = try auth.loadAllProviderApiKeys(self.gpa, self.io, home);
    auth.freeApiKeyMap(self.gpa, &self.provider_api_keys);
    self.provider_api_keys = fresh;
    fresh = .empty;
}

/// Index of `provider` within `catalogueProviders()` — the order `conn_status`
/// is keyed by. Null when it isn't a catalogue provider (no badge row).
pub fn catalogueIndex(provider: config_mod.Provider) ?usize {
    for (config_mod.catalogueProviders(), 0..) |candidate, index| {
        if (candidate == provider) return index;
    }
    return null;
}

/// Fold a finished model load's per-provider outcomes into the picker badges.
/// A full connected-provider sweep (`conn_recompute`) first clears every badge
/// to `.unknown`, so a provider dropped from the configured set (key removed)
/// stops reading connected; a single-provider load updates only what it
/// fetched.
pub fn applyProviderOutcomes(self: *App, outcomes: []const model_loader.ProviderOutcome) void {
    if (self.conn_recompute) self.conn_status = @splat(.unknown);
    for (outcomes) |outcome| {
        const index = catalogueIndex(outcome.provider) orelse continue;
        self.conn_status[index] = if (outcome.ok) .connected else .failed;
    }
}

pub fn openProviderEntryForm(self: *App, handle: provider_picker.ProviderHandle) void {
    self.pickers.provider.stage = .form;
    self.pickers.provider.form_handle = handle;
    self.pickers.provider.form_error = null;
    self.provider_key_input.clearRetainingCapacity();
    if (self.provider_api_keys.get(handle.id())) |existing| {
        self.provider_key_input.appendSlice(self.gpa, existing) catch {};
    }
}

pub fn openTimelineSelector(self: *App) !void {
    if (self.thread.turn.isActive()) return error.InFlightTurn;
    self.mode = .tree_picker;
    self.clearInput();
    try self.reloadTreeNodes();
}

/// Enter the full-screen diff viewer. Warm path: parse the cached diff
/// instantly. Cold path: navigate immediately and show "Loading diff…" while
/// a background refresh fetches it (never blocks on git).
pub fn openDiffViewer(self: *App) !void {
    if (self.liveRuntime() == null) return error.NoWorkingDirectory;
    enterDiffMode(
        self,
    );

    if (self.metrics.diff_cache()) |raw| {
        var state = try diff_viewer.fromRaw(self.gpa, raw);
        if (state.isEmpty()) {
            state.deinit(self.gpa);
            self.mode = .normal;
            _ = try self.thread.transcript.append(self.gpa, .agent, "agent", "No changes to review.");
            return;
        }
        self.diff.deinit(self.gpa);
        self.diff = state;
        return;
    }

    // Cold start: show the loading state and kick (or ride) a refresh.
    self.diff.deinit(self.gpa);
    self.diff = .{};
    if (self.metrics.diff_refresh_future() == null) try self.scheduleDiffRefresh();
}

pub fn enterDiffMode(self: *App) void {
    self.mode = .diff_viewer;
    // The diff viewer never draws the transcript, so the black-hole visibility
    // (recomputed only there) would stay stuck true and drive a pointless
    // continuous redraw/tick loop. Park it off while in the viewer.
    self.metrics.blackhole_visible = false;
    self.clearInput();
    self.clearPaletteInput();
    self.inputs.comment.clearRetainingCapacity();
}

pub fn reportDiffError(self: *App, err: anyerror) !void {
    const message = try std.fmt.allocPrint(self.gpa, "Couldn't open diff: {s}", .{@errorName(err)});
    defer self.gpa.free(message);
    _ = try self.thread.transcript.append(self.gpa, .agent, "agent", message);
    self.mode = .normal;
    self.clearInput();
    self.clearPaletteInput();
}

/// Leave the diff viewer. When `send` is set, composed review comments (if
/// any) are stuffed into the main input so the caller can run them through
/// the normal submit path; an Esc-style exit discards them. Returns true when
/// there is text queued to submit.
pub fn closeDiffViewer(self: *App, send: bool) !bool {
    const composed = if (send) try self.diff.composeMessage(self.gpa) else null;
    self.diff.deinit(self.gpa);
    self.mode = .normal;
    self.clearInput();
    self.clearPaletteInput();
    self.inputs.comment.clearRetainingCapacity();
    if (composed) |message| {
        defer self.gpa.free(message);
        try self.inputs.input.insertSliceAtCursor(message);
        return true;
    }
    return false;
}

pub fn openModelPicker(self: *App) !void {
    self.mode = .model_picker;
    tui.rebuildReasoningOptsCache(self);
    self.pickers.models.model_column = .model;
    self.pickers.models.model_selection = 0;
    self.pickers.models.model_scope = defaultModelScope(
        self,
    );
    self.clearInput();

    if (self.pickers.models.models_cached and self.pickers.models.len() > 0) {
        try finishModelCatalogReload(
            self,
        );
        try snapshotModelPickerState(
            self,
        );
        return;
    }

    if (try restoreModelCache(
        self,
    )) {
        // Stale-while-revalidate (same pattern as the diff cache): the disk
        // cache shows instantly, but it can predate a provider connected
        // since it was written — e.g. an Ollama Cloud key added or renewed
        // later, so the cache holds only the providers that were live then.
        // Refresh connected providers in the background and MERGE: present
        // providers update in place, newly-reachable ones appear, and any
        // that fail keep their cached entries.
        startModelLoad(self, .connected_provider, true) catch {};
        return;
    }

    // Cold path — clear stale state, kick off the async load.
    codexModelsClear(
        self,
    );
    self.pickers.models.reasoning_snapshot.clearRetainingCapacity();
    self.pickers.models.model_selection_snapshot = 0;
    try startModelLoad(self, .connected_provider, false);
}

pub fn snapshotModelPickerState(self: *App) !void {
    try self.pickers.models.snapshot(self.gpa);
}

pub fn startModelLoad(self: *App, catalog: ModelCatalog, merge: bool) !void {
    cancelModelLoad(self);
    // A connected-provider sweep fetches every configured provider, so its
    // result is authoritative for all badges; an openai_codex load touches no
    // catalogue providers and must not reset them.
    self.conn_recompute = catalog == .connected_provider;
    if (self.pickers.models.load == .failed) {
        self.gpa.free(self.pickers.models.load.failed.message);
        self.pickers.models.load = .idle;
    }

    const job = try self.gpa.create(model_loader.Job);
    errdefer self.gpa.destroy(job);

    const configured = try collectConfiguredProviders(self, catalog);
    errdefer {
        for (configured) |c| {
            self.gpa.free(c.base_url);
            self.gpa.free(c.api_key);
        }
        if (configured.len > 0) self.gpa.free(configured);
    }

    // Transition load to .loading. The job captures the address of the
    // union's `done` field; the union must stay in .loading (no other
    // writes to load) until drainModelLoad moves it out.
    self.pickers.models.load = .{
        .loading = .{
            .future = undefined, // set below
            .done = .init(false),
            .merge = merge,
        },
    };
    job.* = .{
        .gpa = self.gpa,
        .io = self.io,
        .catalog = switch (catalog) {
            .connected_provider => .connected_provider,
            .openai_codex => .openai_codex,
        },
        .configured = configured,
        .include_locals = catalog == .connected_provider,
        .codex_signed_in = self.isCodexSignedIn(),
        .done = &self.pickers.models.load.loading.done,
    };
    self.pickers.models.load.loading.future = try self.io.concurrent(model_loader.run, .{job});
}

/// Every OpenAI-compatible provider to fetch for a full catalogue reload:
/// each catalogue provider with a stored key (or an anonymous tier), plus a
/// non-catalogue env/config provider when one is configured. Caller owns the slice.
pub fn collectConfiguredProviders(self: *App, catalog: ModelCatalog) ![]model_loader.Configured {
    var list: std.ArrayList(model_loader.Configured) = .empty;
    errdefer {
        for (list.items) |c| {
            self.gpa.free(c.base_url);
            self.gpa.free(c.api_key);
            if (c.display_name) |d| self.gpa.free(d);
        }
        list.deinit(self.gpa);
    }
    if (catalog == .connected_provider) {
        for (config_mod.catalogueProviders()) |provider| {
            const base_url = provider.defaultBaseUrl() orelse continue;
            // Stored key wins; otherwise an anonymous-tier provider (OpenCode
            // Zen) still loads via its `public` sentinel (free models only).
            const key = self.provider_api_keys.get(provider.label()) orelse anon: {
                break :anon provider.anonymousApiKey() orelse continue;
            };
            try appendConfigured(self, &list, provider, base_url, key);
        }
        if (self.modelsdev_registry) |*reg| {
            var it = self.provider_api_keys.iterator();
            while (it.next()) |entry| {
                const id = entry.key_ptr.*;
                if (catalogueIndexById(id) != null) continue;
                if (reg.lookup(id)) |dyn_p| {
                    try appendConfiguredDynamic(self, &list, dyn_p.base_url, entry.value_ptr.*, dyn_p.name);
                }
            }
        }
        if (shouldLoadConfiguredCompatibleCatalog(self)) {
            const ms = self.cached_config.model_selection orelse return list.toOwnedSlice(self.gpa);
            const provider = ms.provider;
            // Catalogue providers are covered by block 1; dynamic providers
            // with a stored key are covered by block 2 (models.dev registry).
            // Only add a block-3 entry for providers neither block handles
            // (e.g. a config-defined custom endpoint not in models.dev).
            const covered_by_registry = blk: {
                // After session resume dynamic_provider_id is null (runtime-only);
                // fall back to the serialized model_selection.provider_name.
                const id = self.cached_config.dynamic_provider_id orelse ms.provider_name;
                if (self.provider_api_keys.get(id) == null) break :blk false;
                if (self.modelsdev_registry) |*reg| {
                    if (reg.lookup(id) != null) break :blk true;
                }
                break :blk false;
            };
            if (!provider.isCatalogue() and !covered_by_registry) {
                // base_url may be "" when synthesized from session metadata or
                // legacy fields; resolve through the provider default.
                const base_url = if (ms.base_url.len > 0) ms.base_url else provider.defaultBaseUrl() orelse return list.toOwnedSlice(self.gpa);
                // ms.api_key is always "" (keys live in auth.json). Resolve
                // the stored key so the model fetch authenticates correctly.
                const api_key = if (ms.api_key.len > 0)
                    ms.api_key
                else if (self.cached_config.dynamic_provider_id) |id|
                    self.provider_api_keys.get(id) orelse ""
                else
                    self.provider_api_keys.get(ms.provider_name) orelse "";
                try appendConfigured(self, &list, provider, base_url, api_key);
            }
        }
    }
    return list.toOwnedSlice(self.gpa);
}

pub fn appendConfiguredDynamic(
    self: *App,
    list: *std.ArrayList(model_loader.Configured),
    base_url: []const u8,
    api_key: []const u8,
    display_name: []const u8,
) !void {
    const url = try self.gpa.dupe(u8, base_url);
    errdefer self.gpa.free(url);
    const key = try self.gpa.dupe(u8, api_key);
    errdefer self.gpa.free(key);
    const name = try self.gpa.dupe(u8, display_name);
    errdefer self.gpa.free(name);
    try list.append(self.gpa, .{
        .provider = .openai_compatible,
        .base_url = url,
        .api_key = key,
        .display_name = name,
    });
}

pub fn appendConfigured(
    self: *App,
    list: *std.ArrayList(model_loader.Configured),
    provider: config_mod.Provider,
    base_url: []const u8,
    api_key: []const u8,
) !void {
    const url = try self.gpa.dupe(u8, base_url);
    errdefer self.gpa.free(url);
    const key = try self.gpa.dupe(u8, api_key);
    errdefer self.gpa.free(key);
    try list.append(self.gpa, .{ .provider = provider, .base_url = url, .api_key = key });
}

pub const model_loader_job = @import("model_loader_job.zig");
pub const cancelModelLoad = model_loader_job.cancelModelLoad;
pub const drainModelLoad = model_loader_job.drainModelLoad;
pub const installModelLoadResult = model_loader_job.installModelLoadResult;
pub const dropModelsForProvider = model_loader_job.dropModelsForProvider;
pub const restoreModelCache = model_loader_job.restoreModelCache;
pub const saveModelCache = model_loader_job.saveModelCache;
pub const collectModelCacheConfigured = model_loader_job.collectModelCacheConfigured;

pub fn defaultModelScope(self: *App) ModelScope {
    const runtime = self.liveRuntime() orelse return .global;
    if (config_mod.projectConfigExists(self.gpa, self.io, runtime.cwd)) return .project;
    return .global;
}

pub fn connectCodex(self: *App) !void {
    if (self.thread.turn.isActive()) return error.InFlightTurn;
    var credentials = try codex.login(self.gpa, self.io, self.liveRuntime().?.home_dir);
    defer credentials.deinit(self.gpa);
    self.pickers.models.models_cached = false;
    try reloadModelCatalog(self, .openai_codex);
    const model = selectedCodexModel(
        self,
    ) orelse return error.NoModels;
    const effort = selectedReasoningEffort(
        self,
    );
    try connectCodexClient(self, credentials, model.id, effort);
    self.codex_signed_in = true;
    self.liveRuntime().?.codex_connection_expired = false;
    try persistModelSelection(self, .openai, model.id, effort, .global);
    self.mode = .normal;
    self.clearInput();
    _ = try self.thread.transcript.append(self.gpa, .agent, "agent", "Connected to OpenAI Codex.");
}

pub fn signOutCodex(self: *App) !void {
    if (self.thread.turn.isActive()) return error.InFlightTurn;
    // The naming client is about to be freed; no job may still borrow it.
    self.cancelLaneNaming(self.thread);
    try codex.signOut(self.gpa, self.io, self.liveRuntime().?.home_dir);
    self.liveRuntime().?.disconnectCodexClient();
    self.codex_signed_in = false;
    self.liveRuntime().?.codex_connection_expired = false;
    self.thread.agent.?.client = self.liveRuntime().?.client;
    codexModelsClear(
        self,
    );
    self.pickers.models.models_cached = false;
    self.mode = .normal;
    self.clearInput();
    _ = try self.thread.transcript.append(self.gpa, .agent, "agent", "Signed out from OpenAI Codex.");
}

/// Save the entered API key for a catalogue provider, then fetch just that
/// provider's models and merge them into the catalogue before handing off to
/// the model picker. A blank key is allowed only for providers that don't
/// require one (`requiresApiKey() == false`); all current ones do.
pub fn submitProviderSetup(self: *App, provider: config_mod.Provider) !void {
    if (self.thread.turn.isActive()) return error.InFlightTurn;
    var key = std.mem.trim(u8, self.provider_key_input.items, " \t\r\n");
    if (key.len == 0) {
        if (self.provider_api_keys.get(provider.label())) |existing| {
            key = existing;
        }
    }

    // A required key cannot be blank — keep the form open so the user can type.
    if (key.len == 0 and provider.requiresApiKey()) {
        self.pickers.provider.form_error = "API key is required to connect to this provider.";
        return;
    }

    const home = self.liveRuntime().?.home_dir;
    if (key.len > 0) {
        try auth.saveProviderApiKey(self.gpa, self.io, home, provider.label(), key);
    } else {
        // Anonymous free tier: drop any stale key so we connect without one.
        auth.removeProviderApiKey(self.gpa, self.io, home, provider.label()) catch {};
    }
    try refreshProviderApiKeys(
        self,
    );

    // Clear stale connection state when switching to a builtin. Without
    // this, legacy fields from a previous dynamic/config provider linger
    // and hasOpenAICompatibleCredentials (or any direct legacy reader)
    // sees the wrong provider's URL and key.
    if (self.cached_config_owned) {
        if (self.cached_config.dynamic_provider_name) |prev| self.gpa.free(prev);
        self.cached_config.dynamic_provider_name = null;
        if (self.cached_config.dynamic_provider_id) |prev| self.gpa.free(prev);
        self.cached_config.dynamic_provider_id = null;
        if (self.cached_config.base_url) |prev| self.gpa.free(prev);
        self.cached_config.base_url = null;
        if (self.cached_config.api_key) |prev| self.gpa.free(prev);
        self.cached_config.api_key = null;
        self.cached_config.provider = provider;
    }

    // With no key, connect via the provider's anonymous sentinel (e.g.
    // OpenCode Zen's `public`, which the gateway limits to free models).
    const connect_key = if (key.len > 0) key else (provider.anonymousApiKey() orelse key);
    // `connect_key` may alias the input buffer — fetch (which dupes it) first.
    try startProviderModelLoad(self, provider, connect_key);

    self.pickers.provider.stage = .list;
    self.pickers.provider.form_handle = null;
    self.provider_key_input.clearRetainingCapacity();

    self.mode = .model_picker;
    tui.rebuildReasoningOptsCache(self);
    self.pickers.models.model_column = .model;
    self.pickers.models.model_selection = 0;
    self.pickers.models.model_scope = defaultModelScope(
        self,
    );
    self.pickers.models.reasoning_snapshot.clearRetainingCapacity();
    self.pickers.models.model_selection_snapshot = 0;
    self.clearInput();
    self.clearPaletteInput();
}

pub fn submitDynamicProviderSetup(self: *App, provider: modelsdev.Provider) !void {
    if (self.thread.turn.isActive()) return error.InFlightTurn;
    var key = std.mem.trim(u8, self.provider_key_input.items, " \t\r\n");
    if (key.len == 0) {
        if (self.provider_api_keys.get(provider.id)) |existing| {
            key = existing;
        }
    }

    if (key.len == 0 and provider.requires_api_key) {
        self.pickers.provider.form_error = "API key is required to connect to this provider.";
        return;
    }

    const home = self.liveRuntime().?.home_dir;
    if (key.len > 0) {
        try auth.saveProviderApiKey(self.gpa, self.io, home, provider.id, key);
    } else {
        auth.removeProviderApiKey(self.gpa, self.io, home, provider.id) catch {};
    }
    try refreshProviderApiKeys(self);

    // Stash the dynamic provider's base_url and api_key into cached_config so
    // that applySelectedModel can resolve them via compatibleBaseUrl and
    // compatibleApiKey. Without this, both see .openai_compatible (which has no
    // default URL and no stored key) and return null/empty, yielding
    // NotConnected.
    if (self.cached_config_owned) {
        const owned_url = try self.gpa.dupe(u8, provider.base_url);
        if (self.cached_config.base_url) |prev| self.gpa.free(prev);
        self.cached_config.base_url = owned_url;

        const owned_key = try self.gpa.dupe(u8, key);
        if (self.cached_config.api_key) |prev| self.gpa.free(prev);
        self.cached_config.api_key = owned_key;

        self.cached_config.provider = .openai_compatible;

        // Stash the human-readable provider name for the status bar.
        if (self.cached_config.dynamic_provider_name) |prev| self.gpa.free(prev);
        self.cached_config.dynamic_provider_name = try self.gpa.dupe(u8, provider.name);

        // Stash the provider id (auth.json key, e.g. "stepfun-ai") so
        // model_selection.provider_name and auth lookups resolve correctly.
        if (self.cached_config.dynamic_provider_id) |prev| self.gpa.free(prev);
        self.cached_config.dynamic_provider_id = try self.gpa.dupe(u8, provider.id);
    }

    const connect_key = if (key.len > 0) key else (provider.anonymous_key orelse key);
    try startDynamicProviderModelLoad(self, provider, connect_key);

    self.pickers.provider.stage = .list;
    self.pickers.provider.form_handle = null;
    self.provider_key_input.clearRetainingCapacity();

    self.mode = .model_picker;
    tui.rebuildReasoningOptsCache(self);
    self.pickers.models.model_column = .model;
    self.pickers.models.model_selection = 0;
    self.pickers.models.model_scope = defaultModelScope(self);
    self.pickers.models.reasoning_snapshot.clearRetainingCapacity();
    self.pickers.models.model_selection_snapshot = 0;
    self.clearInput();
    self.clearPaletteInput();
}

pub fn submitConfigProviderSetup(self: *App, provider: config_mod.ProviderConfig) !void {
    if (self.thread.turn.isActive()) return error.InFlightTurn;
    var key = std.mem.trim(u8, self.provider_key_input.items, " \t\r\n");
    if (key.len == 0) {
        if (self.provider_api_keys.get(provider.name)) |existing| {
            key = existing;
        }
    }

    if (key.len == 0) {
        self.pickers.provider.form_error = "API key is required to connect to this provider.";
        return;
    }

    const home = self.liveRuntime().?.home_dir;
    try auth.saveProviderApiKey(self.gpa, self.io, home, provider.name, key);
    try refreshProviderApiKeys(self);

    // Resolve the base URL: explicit custom URL wins, otherwise fall back
    // to the provider enum's default (e.g. openai_compatible has none).
    const base_url: []const u8 = switch (provider.base_url) {
        .custom => |url| url,
        .default => provider.provider.defaultBaseUrl() orelse "",
    };

    if (self.cached_config_owned) {
        const owned_url = try self.gpa.dupe(u8, base_url);
        if (self.cached_config.base_url) |prev| self.gpa.free(prev);
        self.cached_config.base_url = owned_url;

        const owned_key = try self.gpa.dupe(u8, key);
        if (self.cached_config.api_key) |prev| self.gpa.free(prev);
        self.cached_config.api_key = owned_key;

        self.cached_config.provider = .openai_compatible;

        if (self.cached_config.dynamic_provider_name) |prev| self.gpa.free(prev);
        self.cached_config.dynamic_provider_name = try self.gpa.dupe(u8, provider.name);

        // For config providers, the auth.json key equals the config map key.
        if (self.cached_config.dynamic_provider_id) |prev| self.gpa.free(prev);
        self.cached_config.dynamic_provider_id = try self.gpa.dupe(u8, provider.name);
    }

    try startOpenAiCompatibleModelLoad(self, base_url, key, provider.name);

    self.pickers.provider.stage = .list;
    self.pickers.provider.form_handle = null;
    self.provider_key_input.clearRetainingCapacity();

    self.mode = .model_picker;
    tui.rebuildReasoningOptsCache(self);
    self.pickers.models.model_column = .model;
    self.pickers.models.model_selection = 0;
    self.pickers.models.model_scope = defaultModelScope(self);
    self.pickers.models.reasoning_snapshot.clearRetainingCapacity();
    self.pickers.models.model_selection_snapshot = 0;
    self.clearInput();
    self.clearPaletteInput();
}

pub fn startDynamicProviderModelLoad(self: *App, provider: modelsdev.Provider, key: []const u8) !void {
    try startOpenAiCompatibleModelLoad(self, provider.base_url, key, provider.name);
}

/// Shared model-load path for any OpenAI-compatible endpoint (models.dev
/// dynamic providers and user-defined config providers).
pub fn startOpenAiCompatibleModelLoad(self: *App, base_url: []const u8, key: []const u8, display_name: []const u8) !void {
    cancelModelLoad(self);
    self.conn_recompute = false;
    if (self.pickers.models.load == .failed) {
        self.gpa.free(self.pickers.models.load.failed.message);
        self.pickers.models.load = .idle;
    }

    var configured = try self.gpa.alloc(model_loader.Configured, 1);
    errdefer self.gpa.free(configured);

    const url = try self.gpa.dupe(u8, base_url);
    errdefer self.gpa.free(url);
    const k = try self.gpa.dupe(u8, key);
    errdefer self.gpa.free(k);
    const name = try self.gpa.dupe(u8, display_name);
    errdefer self.gpa.free(name);

    configured[0] = .{
        .provider = .openai_compatible,
        .base_url = url,
        .api_key = k,
        .display_name = name,
    };

    const job = try self.gpa.create(model_loader.Job);
    errdefer self.gpa.destroy(job);

    self.pickers.models.load = .{ .loading = .{
        .future = undefined,
        .done = .init(false),
        .merge = false,
    } };
    job.* = .{
        .gpa = self.gpa,
        .io = self.io,
        .catalog = .single_provider,
        .configured = configured,
        .include_locals = false,
        .codex_signed_in = false,
        .done = &self.pickers.models.load.loading.done,
    };
    self.pickers.models.load.loading.future = try self.io.concurrent(model_loader.run, .{job});
}

/// Incremental, merge-on-arrival load of a single provider's `/models`.
pub fn startProviderModelLoad(self: *App, provider: config_mod.Provider, key: []const u8) !void {
    cancelModelLoad(self);
    // Single provider: its outcome updates only this provider's badge, never
    // a full recompute that would wipe the others.
    self.conn_recompute = false;
    if (self.pickers.models.load == .failed) {
        self.gpa.free(self.pickers.models.load.failed.message);
        self.pickers.models.load = .idle;
    }

    const base_url_default = provider.defaultBaseUrl() orelse return error.NotConnected;

    const job = try self.gpa.create(model_loader.Job);
    errdefer self.gpa.destroy(job);

    const configured = try self.gpa.alloc(model_loader.Configured, 1);
    errdefer self.gpa.free(configured);
    const base_url = try self.gpa.dupe(u8, base_url_default);
    errdefer self.gpa.free(base_url);
    const api_key = try self.gpa.dupe(u8, key);
    errdefer self.gpa.free(api_key);
    configured[0] = .{ .provider = provider, .base_url = base_url, .api_key = api_key };

    self.pickers.models.load = .{ .loading = .{
        .future = undefined,
        .done = .init(false),
        .merge = true,
    } };
    job.* = .{
        .gpa = self.gpa,
        .io = self.io,
        .catalog = .single_provider,
        .configured = configured,
        .include_locals = false,
        .codex_signed_in = self.isCodexSignedIn(),
        .done = &self.pickers.models.load.loading.done,
    };
    self.pickers.models.load.loading.future = try self.io.concurrent(model_loader.run, .{job});
}

pub fn applySelectedModel(self: *App) !void {
    if (self.thread.turn.state == .interrupting) self.discardAbandonedTurn();
    if (self.thread.turn.isActive()) return error.InFlightTurn;
    const model = selectedCodexModel(
        self,
    ) orelse return error.NoModels;
    const effort = selectedReasoningEffort(
        self,
    );

    const source = selectedModelSource(
        self,
    ) orelse return error.NoModels;
    switch (source) {
        .openai_codex => {
            const loaded = try codex.load(self.gpa, self.io, self.liveRuntime().?.home_dir);
            if (loaded) |codex_creds| {
                var credentials = codex_creds;
                defer credentials.deinit(self.gpa);
                try connectCodexClient(self, credentials, model.id, effort);
                self.codex_signed_in = true;
                try persistModelSelection(self, .openai, model.id, effort, self.pickers.models.model_scope);
            } else {
                return error.NotConnected;
            }
        },
        .openai_compatible => |provider| {
            const base_url = compatibleBaseUrl(self, provider) orelse return error.NotConnected;
            const api_key = compatibleApiKey(self, provider);
            if (api_key.len == 0 and provider.requiresApiKey()) return error.NotConnected;
            try attachOpenAiCompatibleClient(self, base_url, api_key, model.id, effort);
            try persistModelSelection(self, provider, model.id, effort, self.pickers.models.model_scope);
        },
    }
    self.mode = .normal;
    self.clearInput();
}

pub fn persistModelSelection(
    self: *App,
    provider: config_mod.Provider,
    model_id: []const u8,
    effort: ai.ReasoningEffort,
    scope: ModelScope,
) !void {
    try updateCachedModelSelection(self, provider, model_id, effort);
    if (scope == .session) return;

    var updates = try modelSelectionUpdates(self, provider, model_id, effort);
    defer updates.deinit(self.gpa);
    switch (scope) {
        .global => config_mod.mergeAndWriteGlobal(self.gpa, self.io, self.liveRuntime().?.home_dir, updates) catch |err| {
            std.log.warn("config.write.failed err={s}", .{@errorName(err)});
        },
        .project => config_mod.mergeAndWriteProject(self.gpa, self.io, self.liveRuntime().?.cwd, updates) catch |err| {
            std.log.warn("project.config.write.failed err={s}", .{@errorName(err)});
        },
        .session => unreachable,
    }
}

pub fn updateCachedModelSelection(
    self: *App,
    provider: config_mod.Provider,
    model_id: []const u8,
    effort: ai.ReasoningEffort,
) !void {
    const new_id = try self.gpa.dupe(u8, model_id);
    errdefer self.gpa.free(new_id);
    if (self.cached_config_owned) {
        if (self.cached_config.model_selection) |*ms| {
            ms.model.deinit(self.gpa);
            ms.provider = provider;
            ms.model = .{ .id = new_id, .reasoning = .{ .effort = effort } };
            try updateCachedProviderConnection(self, provider);
        } else {
            // No selection yet — bootstrap a minimal one. base_url and
            // api_key come from the provider's defaults.
            const base_url = provider.defaultBaseUrl() orelse "";
            self.cached_config.model_selection = .{
                .provider = provider,
                .provider_name = try self.gpa.dupe(u8, provider.label()),
                .model = .{ .id = new_id, .reasoning = .{ .effort = effort } },
                .base_url = try self.gpa.dupe(u8, base_url),
                .api_key = try self.gpa.dupe(u8, ""),
            };
            try updateCachedProviderConnection(self, provider);
        }
    } else {
        self.gpa.free(new_id);
    }
}

pub fn updateCachedProviderConnection(self: *App, provider: config_mod.Provider) !void {
    if (provider == .openai_compatible) {
        // Dynamic/custom providers stash their connection in cached_config's
        // legacy fields. Mirror them into model_selection so applyFromConfig
        // resolves the correct endpoint and auth.json key on resume.
        if (self.cached_config.base_url) |url| try replaceCachedBaseUrl(self, url);
        if (self.cached_config.dynamic_provider_id) |id| try replaceCachedProviderName(self, id);
        return;
    }
    if (provider.defaultBaseUrl()) |base_url| try replaceCachedBaseUrl(self, base_url);
    clearCachedApiKey(
        self,
    );
}

pub fn replaceCachedBaseUrl(self: *App, base_url: []const u8) !void {
    const owned = try self.gpa.dupe(u8, base_url);
    errdefer self.gpa.free(owned);
    if (self.cached_config.model_selection) |*ms| {
        self.gpa.free(ms.base_url);
        ms.base_url = owned;
    } else {
        self.gpa.free(owned);
    }
}

pub fn replaceCachedProviderName(self: *App, name: []const u8) !void {
    const owned = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(owned);
    if (self.cached_config.model_selection) |*ms| {
        self.gpa.free(ms.provider_name);
        ms.provider_name = owned;
    } else {
        self.gpa.free(owned);
    }
}

pub fn clearCachedApiKey(self: *App) void {
    if (self.cached_config.model_selection) |*ms| {
        // Replace with empty string (api_key is non-optional in
        // ModelSelection; clearing means the user will be prompted
        // again). The previous key is freed.
        const new_key = self.gpa.dupe(u8, "") catch return;
        self.gpa.free(ms.api_key);
        ms.api_key = new_key;
    }
}

pub fn modelSelectionUpdates(
    self: *App,
    provider: config_mod.Provider,
    model_id: []const u8,
    effort: ai.ReasoningEffort,
) !config_mod.Config {
    const model_id_copy = try self.gpa.dupe(u8, model_id);
    errdefer self.gpa.free(model_id_copy);
    var provider_model_id_moved = false;
    const provider_model_id = try self.gpa.dupe(u8, model_id);
    errdefer if (!provider_model_id_moved) self.gpa.free(provider_model_id);
    var models_moved = false;
    var models = try self.gpa.alloc(config_mod.ProviderModel, 1);
    errdefer if (!models_moved) self.gpa.free(models);
    models[0] = .{ .id = provider_model_id, .reasoning = .{ .effort = effort } };
    provider_model_id_moved = true;
    var providers = try self.gpa.alloc(config_mod.ProviderConfig, 1);
    errdefer {
        for (providers) |*entry| entry.deinit(self.gpa);
        self.gpa.free(providers);
    }
    // For dynamic/custom providers the config-map key and auth.json key is
    // the stashed provider id (e.g. "stepfun-ai"), NOT the enum label
    // ("openai_compatible"). Using the label would make resume look up the
    // wrong auth.json entry and connect with an empty API key.
    // After session resume dynamic_provider_id is null (runtime-only);
    // fall back to the serialized model_selection.provider_name.
    const resolved_name: []const u8 = if (provider == .openai_compatible)
        self.cached_config.dynamic_provider_id orelse
            (if (self.cached_config.model_selection) |ms| ms.provider_name else provider.label())
    else
        provider.label();

    providers[0] = .{ .name = try self.gpa.dupe(u8, resolved_name), .provider = provider, .models = models };
    models_moved = true;
    if (provider != .openai) {
        if (compatibleBaseUrl(self, provider)) |base_url| providers[0].base_url = .{ .custom = try self.gpa.dupe(u8, base_url) };
    }

    const base_url_slice: ?[]u8 = switch (providers[0].base_url) {
        .custom => |base_url| try self.gpa.dupe(u8, base_url),
        .default => null,
    };
    errdefer if (base_url_slice) |s| self.gpa.free(s);

    const ms_model_id = try self.gpa.dupe(u8, model_id);
    errdefer self.gpa.free(ms_model_id);

    const ms_base_url = if (base_url_slice) |s| try self.gpa.dupe(u8, s) else try self.gpa.dupe(u8, "");
    errdefer self.gpa.free(ms_base_url);

    const ms_api_key = try self.gpa.dupe(u8, "");
    errdefer self.gpa.free(ms_api_key);

    return .{
        .provider = provider,
        .base_url = base_url_slice,
        .model = .{ .id = model_id_copy, .reasoning = .{ .effort = effort } },
        .providers = providers,
        .model_selection = .{
            .provider = provider,
            .provider_name = try self.gpa.dupe(u8, resolved_name),
            .model = .{ .id = ms_model_id, .reasoning = .{ .effort = effort } },
            .base_url = ms_base_url,
            .api_key = ms_api_key,
        },
    };
}

pub fn reloadModelCatalog(self: *App, catalog: ModelCatalog) !void {
    codexModelsClear(
        self,
    );
    switch (catalog) {
        .connected_provider => {
            if (shouldLoadConfiguredCompatibleCatalog(
                self,
            )) {
                loadCompatibleCatalog(
                    self,
                ) catch |err| {
                    if (!self.isCodexSignedIn()) return err;
                    std.log.warn("compatible.models.failed err={s}", .{@errorName(err)});
                };
            }
            try loadLocalCompatibleCatalogs(
                self,
            );
            if (self.isCodexSignedIn()) try loadCodexStaticCatalog(
                self,
            );
        },
        .openai_codex => try loadCodexStaticCatalog(
            self,
        ),
    }
    try finishModelCatalogReload(
        self,
    );
}

pub fn finishModelCatalogReload(self: *App) !void {
    self.pickers.models.resetReasoning();
}

pub fn activeModelId(self: *const App) ?[]const u8 {
    const status = tui_status.modelStatus(self.liveRuntime(), self.cached_config) orelse return null;
    return status.model;
}

pub fn loadCodexStaticCatalog(self: *App) !void {
    const models = try codex.loadStaticModels(self.gpa);
    defer self.gpa.free(models);
    for (models) |*model| {
        try self.pickers.models.append(self.gpa, model.*, .openai_codex);
        model.* = .{ .id = &.{}, .label = &.{} };
    }
    for (models) |*model| {
        if (model.id.len == 0) continue;
        model.deinit(self.gpa);
    }
}

pub fn loadCompatibleCatalog(self: *App) !void {
    if (!self.pickers.models.compatible_models_fetched) try fetchCompatibleCatalog(
        self,
    );
    const provider = tui_provider.compatibleProviderFromBaseUrl(self.cached_config.base_url.?);
    for (self.pickers.models.compatible_models.items) |model| {
        const id = try self.gpa.dupe(u8, model.id);
        errdefer self.gpa.free(id);
        const label = try self.gpa.dupe(u8, model.label);
        errdefer self.gpa.free(label);
        try self.pickers.models.append(self.gpa, .{ .id = id, .label = label }, .{ .openai_compatible = provider });
    }
}

pub fn loadLocalCompatibleCatalogs(self: *App) !void {
    loadLocalCompatibleCatalog(self, .ollama) catch {};
    loadLocalCompatibleCatalog(self, .llama_cpp) catch {};
}

pub fn loadLocalCompatibleCatalog(self: *App, provider: config_mod.Provider) !void {
    const base_url = provider.defaultBaseUrl() orelse return;
    const api_key = providerLocalApiKey(provider);
    const fetched = try openai_compatible_mod.listModels(self.gpa, self.io, base_url, api_key);
    defer {
        for (fetched) |*entry| entry.deinit(self.gpa);
        self.gpa.free(fetched);
    }
    for (fetched) |entry| {
        if (!includeLocalModel(provider, entry.id)) continue;
        const id = try self.gpa.dupe(u8, entry.id);
        errdefer self.gpa.free(id);
        const label = try localModelLabel(self.gpa, provider, entry.id);
        errdefer self.gpa.free(label);
        try self.pickers.models.append(self.gpa, .{ .id = id, .label = label }, .{ .openai_compatible = provider });
    }
}

pub fn fetchCompatibleCatalog(self: *App) !void {
    std.debug.assert(!self.pickers.models.compatible_models_fetched);
    const base_url = self.cached_config.base_url.?;
    const api_key = self.cached_config.api_key.?;
    const provider = self.cached_config.provider orelse tui_provider.compatibleProviderFromBaseUrl(base_url);
    const fetched = try openai_compatible_mod.listModels(self.gpa, self.io, base_url, api_key);
    defer {
        for (fetched) |*entry| entry.deinit(self.gpa);
        self.gpa.free(fetched);
    }
    errdefer compatibleModelsCacheClear(
        self,
    );
    for (fetched) |entry| {
        if (!includeLocalModel(provider, entry.id)) continue;
        const id = try self.gpa.dupe(u8, entry.id);
        errdefer self.gpa.free(id);
        const label = try self.gpa.dupe(u8, entry.id);
        errdefer self.gpa.free(label);
        try self.pickers.models.compatible_models.append(self.gpa, .{ .id = id, .label = label });
    }
    self.pickers.models.compatible_models_fetched = true;
}

pub fn compatibleModelsCacheClear(self: *App) void {
    for (self.pickers.models.compatible_models.items) |*model| model.deinit(self.gpa);
    self.pickers.models.compatible_models.clearRetainingCapacity();
    self.pickers.models.compatible_models_fetched = false;
}

pub fn hasOpenAICompatibleCredentials(self: *const App) bool {
    return tui_provider.hasOpenAICompatibleCredentials(self.cached_config);
}

pub fn shouldLoadConfiguredCompatibleCatalog(self: *const App) bool {
    if (!hasOpenAICompatibleCredentials(
        self,
    )) return false;
    const base_url = self.cached_config.base_url orelse return false;
    const provider = self.cached_config.provider orelse tui_provider.compatibleProviderFromBaseUrl(base_url);
    if (provider == .ollama) return false;
    if (provider == .llama_cpp) return false;
    return true;
}

pub fn compatibleBaseUrl(self: *const App, provider: config_mod.Provider) ?[]const u8 {
    if (self.cached_config.base_url) |base_url| {
        const url_provider = tui_provider.compatibleProviderFromBaseUrl(base_url);
        if (url_provider == provider) return base_url;
    }
    return provider.defaultBaseUrl();
}

/// Resolve the API key for an OpenAI-compatible provider: a key stored in
/// auth.json wins, then the env/config key, then the provider's anonymous
/// sentinel (e.g. OpenCode Zen's `public`), then the local-daemon sentinel.
/// For dynamic/custom providers (.openai_compatible), the auth.json key is
/// the stashed provider id (e.g. "stepfun-ai"), not the enum label.
pub fn compatibleApiKey(self: *const App, provider: config_mod.Provider) []const u8 {
    // Dynamic/custom providers: auth.json key is the stashed provider id.
    if (provider == .openai_compatible) {
        if (self.cached_config.dynamic_provider_id) |id| {
            if (self.provider_api_keys.get(id)) |key| return key;
        }
        // After session resume dynamic_provider_id is null (runtime-only).
        // Fall back to model_selection.provider_name which IS serialized.
        if (self.cached_config.model_selection) |ms| {
            if (self.provider_api_keys.get(ms.provider_name)) |key| return key;
        }
    } else {
        if (self.provider_api_keys.get(provider.label())) |key| return key;
    }
    if (self.cached_config.api_key) |key| return key;
    if (provider.anonymousApiKey()) |anon| return anon;
    return providerLocalApiKey(provider);
}

pub fn providerLocalApiKey(provider: config_mod.Provider) []const u8 {
    return switch (provider) {
        .ollama => "ollama",
        .llama_cpp => "llama.cpp",
        else => "",
    };
}

pub fn providerModelLabel(provider: config_mod.Provider) []const u8 {
    return switch (provider) {
        .ollama => "Ollama",
        .llama_cpp => "llama.cpp",
        else => provider.label(),
    };
}

pub fn localModelLabel(gpa: std.mem.Allocator, provider: config_mod.Provider, model_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} · {s}", .{ providerModelLabel(provider), model_id });
}

pub fn includeLocalModel(provider: config_mod.Provider, model_id: []const u8) bool {
    if (provider == .ollama) {
        if (std.mem.endsWith(u8, model_id, "-cloud")) return false;
    }
    return true;
}

pub fn selectedReasoningIndex(self: *const App) u32 {
    if (self.pickers.models.model_selection >= self.pickers.models.len()) return 0;
    return self.pickers.models.entries.items[self.pickers.models.model_selection].reasoning_index;
}

pub fn selectedReasoningEffort(self: *const App) ai.ReasoningEffort {
    const opts = tui.activeReasoningOptions(self);
    const idx = selectedReasoningIndex(self);
    if (idx >= opts.len) return .medium;
    return opts[idx].effort;
}

pub fn cycleModelScope(self: *App) void {
    self.pickers.models.model_scope = switch (self.pickers.models.model_scope) {
        .global => .project,
        .project => .session,
        .session => .global,
    };
}

pub fn cycleSelectedReasoning(self: *App) !void {
    if (self.pickers.models.model_selection >= self.pickers.models.len()) return;
    const entry = &self.pickers.models.entries.items[self.pickers.models.model_selection];
    const opts = tui.activeReasoningOptions(self);
    entry.reasoning_index = tui.nextIndex(entry.reasoning_index, @intCast(opts.len));
}

pub fn selectedCodexModel(self: *App) ?codex.Model {
    if (self.pickers.models.model_selection >= self.pickers.models.len()) return null;
    const active_storage_idx = self.pickers.models.activeStorageIdx(activeModelId(
        self,
    ));
    const idx = model_picker.displayToStorage(active_storage_idx, self.pickers.models.model_selection);
    return self.pickers.models.entries.items[idx].model;
}

pub fn modelDisplayMatches(self: *const App, display_pos: u32, filter: []const u8) bool {
    const count: u32 = self.pickers.models.len();
    if (display_pos >= count) return false;
    const active = self.pickers.models.activeStorageIdx(activeModelId(
        self,
    ));
    const storage = model_picker.displayToStorage(active, display_pos);
    if (storage >= count) return false;
    return model_picker.matches(self.pickers.models.entries.items[storage].model, filter);
}

pub fn firstMatchingModelDisplay(self: *const App, filter: []const u8) ?u32 {
    const count: u32 = self.pickers.models.len();
    var d: u32 = 0;
    while (d < count) : (d += 1) {
        if (modelDisplayMatches(self, d, filter)) return d;
    }
    return null;
}

pub fn stepModelSelection(self: *App, forward: bool) !void {
    const count: u32 = self.pickers.models.len();
    if (count == 0) return;
    const filter = try self.peekPaletteInput();
    defer self.gpa.free(filter);
    var next = self.pickers.models.model_selection;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        next = if (forward) tui.nextIndex(next, count) else tui.previousIndex(next, count);
        if (modelDisplayMatches(self, next, filter)) {
            self.pickers.models.model_selection = next;
            return;
        }
    }
}

pub fn selectedModelSource(self: *const App) ?ModelSource {
    if (self.pickers.models.model_selection >= self.pickers.models.len()) return null;
    const active_storage_idx = self.pickers.models.activeStorageIdx(activeModelId(
        self,
    ));
    const idx = model_picker.displayToStorage(active_storage_idx, self.pickers.models.model_selection);
    if (idx >= self.pickers.models.len()) return null;
    return self.pickers.models.entries.items[idx].source;
}

pub fn codexModelsClear(self: *App) void {
    self.pickers.models.clearEntries(self.gpa);
}

pub fn connectCodexClient(
    self: *App,
    credentials: codex.Credentials,
    model: []const u8,
    effort: ai.ReasoningEffort,
) !void {
    // The naming client is about to be replaced; no job may still borrow it.
    self.cancelLaneNaming(self.thread);
    const runtime = self.liveRuntime().?;
    // Actually connect MCP servers before collecting tool schemas.
    self.mcp_manager.syncFromConfigEx(self.gpa, self.io, &self.cached_config, runtime.home_dir, runtime.cwd);
    const mcp_schemas = try self.mcp_manager.buildMcpToolSchemas(self.gpa);
    defer self.gpa.free(mcp_schemas);
    runtime.mcp_tools = mcp_schemas;
    try runtime.connectCodexClient(credentials, model, effort);
    self.thread.agent.?.client = runtime.client;
}

pub fn attachOpenAiCompatibleClient(
    self: *App,
    base_url: []const u8,
    api_key: []const u8,
    model_id: []const u8,
    effort: ai.ReasoningEffort,
) !void {
    // The naming client is about to be replaced; no job may still borrow it.
    self.cancelLaneNaming(self.thread);
    const runtime = self.liveRuntime().?;
    // Actually connect MCP servers before collecting tool schemas.
    self.mcp_manager.syncFromConfigEx(self.gpa, self.io, &self.cached_config, runtime.home_dir, runtime.cwd);
    const mcp_schemas = try self.mcp_manager.buildMcpToolSchemas(self.gpa);
    defer self.gpa.free(mcp_schemas);
    runtime.mcp_tools = mcp_schemas;
    try runtime.attachOpenAiCompatibleClient(base_url, api_key, model_id, effort);
    self.thread.agent.?.client = runtime.client;
}
