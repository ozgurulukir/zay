# Nova Guidelines

This project uses Zig 0.16. Consult the tigerstyle skill before writing code.

## Setup

- Vendor `fff` (build into `vendor/fff/libfff_c.so`) and the ModernBERT ONNX model (`vendor/local-models/ModernBERT-bash-classifier`) after cloning. Both are gitignored.
- Set `OMP_WAIT_POLICY=passive` at runtime to avoid MKL/CPU spin in the embedding worker.
- `zig build install -Doptimize=ReleaseFast --prefix $HOME/.local` installs to `~/.local/bin/`.

## Building the TUI

TUI built with libvaxis vxfw (source in zig-pkg). Prefer framework primitives.

**vxfw gotcha:** `TextField.widget()` is _mutating_ — it takes `*Self`, not `*const Self`. Accessors returning `*TextField` must be declared on `*App`, not `*const App`, or the call site fails to type-check.

**Zig 0.16 field rule:** `pub` cannot precede a field declaration — only functions/variables. Cross-module field access goes through `pub fn` accessors (`getX()` form, never `X()`, because of the field-vs-method name collision).

**TUI module split.** `src/tui.zig` holds `App` lifecycle and `RootWidget`; `src/tui/` is split by concern. See `README.md` Architecture for the current module list.

**Domain extraction pattern.** Isolated domain clusters (lane lifecycle, diff lifecycle, session switching, at-search, transcript navigation, permission, event callbacks, queue, settings lifecycle, clipboard helper) live under `src/tui/` as free-function modules. Each module imports `const tui = @import("../tui.zig")` and defines `pub fn` taking `*App` as the first parameter. The original App method stays as a 1-line delegate (Strangler Fig) so inline tests in `tui.zig` resolve via the struct. When a private App method is needed, promote it to `pub` — not `pub const` (that is for module-level re-exports of nested types).

**Widget extraction pattern.** Isolated widgets live under `src/tui/widgets/`. A new widget file declares the outer border widget as:

```zig
pub const NameWidget = struct { app: *App, pub fn widget(...) vxfw.Widget { ... } }
```

with a private `Inner` struct built inside `draw()` from a `vxfw.DrawContext`. The file imports `const tui = @import("../../tui.zig");`, `const tui_style = @import("../style.zig");`, `const panel = @import("panel.zig");` and re-aliases `const App = tui.App;`. Nested types from other modules are re-exported through `pub const` in `tui.zig` so widget files reach them as `tui.<module>.<Type>`.

**Per-mode command routing.** `src/tui/command_router.zig` holds one struct per `App.Mode` variant, each owning a `handle` method migrated from `App`. The dispatcher is a free function delegating to the right struct. Add new per-mode logic here — don't reintroduce private methods on `App` for key handling.

**Viewport scrolling pattern.** Standardize overlay list viewports using `panel.ViewportWindow.compute(selection, total_count, surface.size.height)` in `src/tui/widgets/panel.zig`. Use `viewport.screenRow(i)` for row rendering calculations.

**Provider polymorphism pattern.** Unify static builtin `config_mod.Provider`, dynamic `modelsdev.Provider`, and user-defined `config_mod.ProviderConfig` handles using `ProviderHandle = union(enum) { builtin, dynamic, config }` in `src/tui/widgets/provider_picker.zig`. All three share the same accessor surface (`id()`, `displayName()`, `description()`, `defaultBaseUrl()`, `requiresApiKey()`, `catalogueIndex()`). The `/connect` picker builds a single merged list via `buildMergedProviderList` in `src/tui/provider_model.zig`: builtin catalogue → models.dev registry (overrides builtins with same id) → config providers (overrides everything with same name, **except** entries already covered by the models.dev registry — a `reg.lookup(cp.name)` guard prevents the persisted `ProviderConfig` entry from shadowing the `.dynamic` handle and converting the provider to a "custom" entry in the picker).

**System clipboard pattern.** `src/clipboard.zig` handles OS clipboard reading/writing via terminal OSC 52 sequences (`\x1b]52;c;<base64>\x07`) with OS-native execution fallback (`wl-copy`/`xclip`/`pbcopy`/`powershell` via `bash.zig`). `clipboard_helper.zig` routes clipboard data dynamically to focused input fields and transcript message blocks.

**Settings lifecycle pattern.** `src/tui/settings_lifecycle.zig` manages pending tabbed form edits, syncs values to `app.cached_config` in real-time, and serializes user settings on `Ctrl+S`. `saveSettings` writes only settings-managed fields (`enable_thinking`, `use_responses_endpoint`, `system_prompt`, `bash_classifier_url`) — never provider/model. If a project config exists (`.nova/config.json`), settings are written to both global and project configs; otherwise global only. This prevents project-level provider/model overrides from leaking into global config.

**MCP Server & Tool Discovery pattern.** `src/mcp/manager.zig` merges `mcp_servers` configuration across global/project layers (supporting `mcp_servers`, `mcpServers`, and `mcp` JSON aliases) and scans Nova standard directories (`~/.config/nova/mcp/`, `<cwd>/.nova/mcp/`) for tool schema discovery. `McpMode.handle` in `command_router.zig` routes `Up`/`Down`/`j`/`k` navigation, `Space`/`Enter` toggling, `Ctrl+R`/`r` re-syncing, and `Esc`/`q` closing.

**Type System Discipline pattern.** Use `union(enum)` instead of flat structs with optional fields whenever a value can be in one of several mutually-exclusive states. This makes illegal combinations unrepresentable at compile time. Current types following this pattern:

- `ai.ChatMessage` — `union(enum) { system, user, assistant, tool }`. The `tool` variant carries non-optional `call_id`; other variants cannot. `role()` and `text()` are cross-variant accessors.
- `transcript.Message` — `union(enum)` with 10 variants (`user`/`agent`/`skill`/`logo`/`thinking`/`status`/`notice`/`success`/`info`/`tool`). `Basic` and `ToolView` payload structs group fields by category. `kind()` bridges the loose `MessageKind` enum; `mirror()` is test-only flat view.
- `tools.Output.display` — `Display` union with `none`/`text`/`diff` variants, replacing the old `?[]u8 + DisplayKind` pair that allowed `null` with `.diff`.
- `config.McpServerConfig.transport` — `union(enum) { stdio, sse }`. A server is either stdio (command+args) or sse (url), never both or neither.
- `mcp.McpClient` — `transport: union(enum) { stdio, sse }` (static config) + `lifecycle: union(enum) { disabled, stdio, sse, failed }` (runtime state). `status()` maps lifecycle to the legacy `ServerStatus` enum.
- `config.Config.model_selection: ?ModelSelection` — typed view replacing 9 loose optional fields. `ModelSelection` has non-optional `provider`/`model`/`base_url`/`api_key` (use `""` not null for `base_url`/`api_key`). `base_url` may be `""` when synthesized from session metadata or legacy fields; callers must resolve it via `provider.defaultBaseUrl()` before client init. `applyConfigOverlay` treats `model_selection` as canonical and propagates `provider_name` to the target's legacy field; `syncModelSelectionFromLegacy` mirrors legacy changes back into it. `parseObject` only populates `model_selection` when all four fields are non-null — since `api_key` is never serialized (lives in `auth.json`), disk-loaded configs **never** have it. Callers that need `model_selection` after a fresh load must fall back to legacy fields (`config.provider`, `config.model`, `config.base_url`, `config.provider_name`), which ARE populated from `defaultModel` and `hydrateActiveModel`.
- `tui.AtSearchState` — `union(enum) { closed, indexing, open }` with `IndexingPayload` and `OpenPayload` structs. `kind()`/`results()`/`close()` helpers bridge callers.
- `tui.NavState.quit` — `QuitState = union(enum) { none, pending, confirmed }` replacing `?Timestamp + bool`.
- `tui.ModelCatalogue.load` — `LoadState = union(enum) { idle, loading, failed }`.
- `search.Backend.state` — `State = union(enum) { idle, loading, ready, failed }`. `handle: *anyopaque` stays opaque (fff C FFI standard).
- `tui.MetricsState.diff` — `DiffState = union(enum) { idle, loading, ready, refreshing }`. The `refreshing` arm keeps the old cache while a new fetch is in flight.
- `config.ProviderModel = Model` — type alias removing duplicate struct drift.
- `config.BaseUrl` — `union(enum) { default, custom: []u8 }`. In overlay merges, `.default` means "don't override"; at final resolution it falls through to `Provider.defaultBaseUrl()`.
- `config.ReasoningSetting` — `union(enum) { unset, effort: ai.ReasoningEffort }`. Follows `BaseUrl`'s overlay-merge pattern: `.unset` means "not specified in this layer, don't override"; `.effort` carries an explicit level (including `.default` which omits the `reasoning_effort` request parameter). `resolve()` falls back to `.medium` for `.unset`.
- `session.SessionSummary.leaf_entry_id: ?EntryId` — branded `EntryId` (fixed-size `[entry_id_len]u8`) instead of loose `[]u8`.

**Models.dev provider filtering pattern.** `parseModelsDevJson` in `src/modelsdev.zig` includes any provider with a non-empty `api` field and ≥1 model — npm package identity is irrelevant. The `api` field is the ground-truth signal for Nova's `openai_compatible` adapter. `@ai-sdk/anthropic` providers with custom `api` endpoints (kimi-for-coding, minimax, etc.) are included; `@ai-sdk/openai` providers without `api` (openai, perplexity-agent) are excluded because `Provider.base_url` is non-optional. Providers without an `api` field (`@ai-sdk/google`, `@ai-sdk/azure`, etc.) are correctly excluded.

**Models.dev network-first loading pattern.** `loadOrFetchRegistry` tries sources in order: (1) network fetch from `https://models.dev/api.json` with User-Agent `nova-agent/1.0`, (2) fresh cache (within 24h TTL), (3) stale cache (ignoring TTL), (4) vendored snapshot at `<exe_dir>/../share/nova/api.json` (installed by `zig build install`), (5) builtins-only fallback. The vendored snapshot seeds the cache directory (`~/.config/nova/cache/models.dev/api.json`) so subsequent starts skip the file read, ensuring 145+ dynamic providers are always available offline. `openProviderPicker` in `src/tui/provider_model.zig` deinits and reloads `modelsdev_registry` every time the picker opens. Diagnostic logging at each stage (`modelsdev.fetch.ok`, `modelsdev.fetch.failed`, `modelsdev.cache.fresh`, `modelsdev.cache.stale`, `modelsdev.vendored`, `modelsdev.registry.fallback`) helps diagnose empty provider lists.

**HTTP fetch decompression pattern.** `fetchApiJson` in `src/modelsdev.zig` must honor `response.head.content_encoding`: gzip/deflate/zstd responses from Cloudflare-backed hosts (models.dev) are decompressed via `response.readerDecompressing` before caching; identity responses pass through unchanged. Using a plain `response.reader` stores compressed bytes in the cache, which `parseModelsDevJson` rejects, silently falling back to builtins-only (14 providers). `listModels` in `src/ai/openai_compatible_models.zig` already follows this pattern; `fetchApiJson` must match it.

**Dynamic provider connection pattern.** When a models.dev dynamic provider is selected, `submitDynamicProviderSetup` stashes the provider's `base_url` and the user's API key into `cached_config` before entering the model picker. It also stores two identity fields: `dynamic_provider_name` (human-readable, e.g. "StepFun AI", used by the status bar) and `dynamic_provider_id` (the auth.json key, e.g. "stepfun-ai", used for session resume and API key lookup). Both are **runtime-only** — never serialized to config.json. `applySelectedModel` resolves the connection URL and key through `compatibleBaseUrl`/`compatibleApiKey`, which check `cached_config.base_url` and `cached_config.api_key` — but the `ModelSource` tag is `.openai_compatible` (which has `defaultBaseUrl() = null` and no stored key). Without this stash, both return null/empty and the connection fails with `NotConnected`. The stash also sets `cached_config.provider = .openai_compatible` so `compatibleProviderFromBaseUrl` matches the URL to the correct provider tag. On selection, `updateCachedProviderConnection` mirrors `dynamic_provider_id` into `model_selection.provider_name` so session resume resolves the auth.json entry correctly; `compatibleApiKey` uses `dynamic_provider_id` directly for the lookup instead of falling back to the stash.

**Dynamic provider persistence pattern.** `serialize` writes `defaultModel: "provider_name/model_id"` as the single source of truth for provider identity — there is no separate `"provider"` field. `parseModelSelection` splits on the first `/` to recover `provider_name` and `model_id`. After restart, `model_selection` is always null (because `api_key` is never serialized), so all rehydration paths fall back to legacy fields: `tryAttachOpenAiCompatibleFromConfig` resolves `base_url` from `config.base_url` (hydrated from the `providers[]` map by `hydrateActiveModel`), `model_id` from `config.model`, and the API key from `auth.json` via `config.provider_name`. `hydrateActiveModel` includes a recovery fallback: when `provider_name` is the generic enum label (`"openai_compatible"`) — e.g. from configs written before the `provider_name` serialization fix — it matches `.openai_compatible` entries in the `providers[]` map by enum and repairs `provider_name` to the actual id. `providerDisplayName` and `providerLabel` in `status.zig` fall back to `config.provider_name` / `config.provider` when `model_selection` is null. `buildMergedProviderList` Layer 3 skips config entries covered by the models.dev registry (`reg.lookup(cp.name)`) to prevent the persisted `ProviderConfig` from shadowing the `.dynamic` handle. `collectConfiguredProviders` block 3 uses a `covered_by_registry` guard (with `ms.provider_name` fallback for resume) and resolves the API key from `provider_api_keys` instead of the always-empty `ms.api_key`.

**Typed callback pattern.** `agent.Listener(Ctx)` and `executor.ToolCallObserver(Ctx)` are generic over the consumer's context type. The `*anyopaque` + `@ptrCast` vtable is replaced by `*Ctx` + typed callback functions. `StreamContext(L)` and `ExecutorBridge(L)` are generic over the listener type. The sole remaining `@ptrCast` is `BashApproval` (1 site, deferred because making it generic would require `Agent` itself to be generic).

**Manual compaction trigger pattern.** `Agent.forceCompact()` is a synchronous public method that runs the full compaction cycle (snapshot → summarize → swap) and returns `!Event.HistoryCompacted` with token counts before/after. Unlike the automatic path (which runs between turns inside `agent.run()`), this is callable from the TUI command handler. The caller is responsible for turn-safety: check `app.thread.turn.isActive()` before calling. Errors are surfaced to the user via transcript notices rather than swallowed in logs.

**Config layering pattern.** Nova merges global (`~/.config/nova/config.json`), project (`.nova/config.json`), and env-var overlays into `cached_config`. **Schema v2**: JSON keys are camelCase (`defaultModel`, `baseURL`, `mcpServers`, `useResponsesEndpoint`, `enableThinking`, `systemPrompt`, `bashClassifierUrl`); legacy snake_case keys are accepted at parse time for backward compatibility. `version` is a semver string (`"2.0.0"`); legacy integer `1` normalizes to `"1.0.0"`. `applyConfigOverlay` uses an if/else structure: `model_selection` is canonical; legacy fields are fallback. `syncModelSelectionFromLegacy` mirrors legacy changes back into `target.model_selection` via `|*ms|` pointer capture. `serialize` skips `api_key` (lives in `auth.json`) and writes camelCase keys. `saveSettings` writes only settings-managed fields — never provider/model. At connection time, `tryAttachOpenAiCompatibleFromConfig` and `tryAttachOpenAiResponsesFromConfig` resolve an empty `ms.base_url` through `provider.defaultBaseUrl()` so client `init` never sees an empty URL.

**Context & compaction config pattern.** `Config.context: ContextSettings` carries `overrideContextWindow`, `maxOutputTokens`, and `compaction: CompactionSettings` (auto, threshold, bufferTokens, keepRecentTokens). The runtime stores `context_settings` and passes `override_context_window` to `compaction.contextWindowTokens()` at client attach time. The agent stores `compaction_settings` and passes `threshold` to `shouldStartSummary`/`shouldSwap` and `keep_recent_tokens` to `keepRecentTokens`. When `auto` is false, `maybeCompact` returns immediately. The swap watermark is `threshold + 0.20` (capped at 0.95). JSON Schema for editor autocompletion lives at `schema/config.schema.json`.

## Zig Development

Use `zigdoc` to discover APIs before coding.

```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc vaxis.Window
```

## Current Zig Patterns

**ArrayList:**

```zig
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);
```

**HashMap/StringHashMap:**

```zig
var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(allocator);
try map.put(allocator, "key", 42);
```

**stdout/stderr writer:**

```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};
try writer.interface.print("hello {s}\n", .{"world"});
```

**build.zig executable:**

```zig
b.addExecutable(.{
    .name = "foo",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

**JSON writing:**

```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};

var jw: std.json.Stringify = .{
    .writer = &writer.interface,
    .options = .{ .whitespace = .indent_2 },
};
try jw.write(my_struct);
```

**Allocating writer:**

```zig
var writer: std.Io.Writer.Allocating = .init(allocator);
defer writer.deinit();
try writer.writer.print("hello {s}", .{"world"});
const output = try writer.toOwnedSlice();
```

## Zig Style

- `camelCase` for functions and methods
- lower-case `snake_case` for variables, parameters, and constants
- `PascalCase` for types, structs, and enums
- prefer `const foo: Type = .{ .field = value };` over `const foo = Type{ .field = value };`
- preferred file order: `//!` module doc comment, `const Self = @This();`, imports, `const log = std.log.scoped(...)`
- pass allocators explicitly; use `errdefer` for cleanup on error
- keep tests inline with the code they cover; register them in `src/main.zig`

## Safety

- Add assertions at API boundaries and state transitions; avoid trivial assertions.
- Keep functions small; push pure computation into helpers.
- Comments should explain why, not what.
- **POSIX Environment Access:** Never index `std.c.environ` directly in loops. In Zig 0.16 on POSIX, `std.c.environ` is `[*:null]?[*:0]u8`. Use `const env_slice = std.mem.span(std.c.environ);` and pass to `std.process.Environ.createMap(.{ .block = .{ .slice = env_slice } }, gpa)` to prevent null-pointer segfaults in multi-threaded contexts.
- **Models.dev Registry Allocations:** `modelsdev.Registry` string storage uses an `ArrayList(u8)`. To prevent dangling slice pointers when building or merging providers, accumulate string offsets via `StringRef` (`start`, `len`) and resolve slice pointers only after all string appends complete.
- **Dynamic Context Compaction:** Never hardcode fixed context retention budgets (e.g. 20,000 tokens) when compacting history. Use `compaction.keepRecentTokens(context_window)` so small-context models (8K/16K/32K) keep a scaled history window (%35 max 20,000) and can always compact below their swap watermark.
- **Streaming SSE Tool Call Deduplication & Parallel Remap:** In `src/ai/openai_compatible.zig`, tool call names and IDs are atomic in streaming — first complete value wins; subsequent deltas are ignored. This deduplicates repeated names (the `bashbash` fix) and prevents cross-tool concatenation. Some providers reuse `index: 0` for all parallel tool calls; `ToolCallStream` detects this by comparing tool-call IDs (always unique). When a new ID arrives at an occupied logical index, the call is forked into a new physical builder slot. Argument continuation deltas (no ID) route through the remap to the correct slot. Limitation: if the provider omits IDs entirely, collision detection is impossible and the second call is lost (first writer wins for the name).

## Verifying

Run:
- `zig fmt`
- `zig build test`

## Known Issues

- **Session resume shows blank TUI (fixed).** At startup (`root.zig` → `initResume`), the agent is rehydrated from the session DB but the TUI transcript was never populated — only the logo animation was appended. Fix: call `app.rebuildTranscriptFromAgent()` in `tui.run()` before deciding whether to show the logo. For a resumed session the transcript populates from the agent's message history; for a new session it stays empty and the logo falls through as before.

- **High CPU usage from spinlocks.** `std.atomic.Mutex` busy-waits and pegs the CPU on multi-core. Use `std.Io.Mutex` and `std.Io.Condition` instead (paired via `static_thread_pool` or similar). Symptom: 80% CPU at idle, drops to ~2% after the fix. Files affected: `lib/logger.zig`, `src/agent.zig`, `src/background.zig`, `src/session.zig`.

- **Double-free in `postAgentEvent` / `postTurnFailed` / `runAgentTurn` (fixed).** `postAgentEvent` takes ownership of the event — on error it frees the event's data internally. Callers' catch blocks were freeing `message_text` again (double-free), and the QueueFull handler was manually cleaning up `event_ptr` before `return error.TurnCancelled`, which triggered errdefer to repeat the same cleanup. Fix: remove `worker_context.gpa.free(message_text)` from catch blocks in `runAgentTurn` and `postTurnFailed`; remove manual `event_ptr.deinit`+`destroy` before `return error.TurnCancelled` in `postAgentEvent`.

- **Session resume panics on empty `base_url` (fixed).** When resuming a session with no `model_selection` in config, `initSession` synthesized one with `.base_url = ""`. That empty string reached `openai_compatible.Client.init`, which asserts `base_url.len > 0`. Fix: initialize `model_selection.base_url` from `provider.defaultBaseUrl()` instead of `""`, and add fallback resolution in `tryAttachOpenAiCompatibleFromConfig` / `tryAttachOpenAiResponsesFromConfig` so client `init` never sees an empty URL.

- **Dynamic provider identity lost across restart (fixed).** Three independent bugs: (1) `buildMergedProviderList` Layer 3 overrode models.dev `.dynamic` handles with persisted `ProviderConfig` entries, converting dynamic providers to "custom" in the picker. (2) `applyConfigOverlay` didn't propagate `ms.provider_name` to `target.provider_name`, so `serialize`'s legacy path wrote `"provider": "openai_compatible"` instead of the actual id. (3) `tryAttachOpenAiCompatibleFromConfig` returned early when `model_selection` was null (always, since `api_key` is never serialized) and `defaultBaseUrl()` was null for `.openai_compatible`. Fix: Layer 3 registry guard, `provider_name` propagation + `serialize` uses `provider_name`, legacy field fallback in `tryAttachOpenAiCompatibleFromConfig`, `hydrateActiveModel` recovery for broken configs, and removal of the redundant `"provider"` field from `serialize` (the `"provider"` field was write-only — `parseObject` only reads `defaultModel`).
