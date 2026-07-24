# Nova Guidelines

This project uses Zig version 0.16

Always consult the tigerstyle skill when writing code.

## Setup

- After cloning, vendor `fff` (build into `vendor/fff/libfff_c.so`) and the ModernBERT ONNX model (`vendor/local-models/ModernBERT-bash-classifier`). Both are gitignored.
- Use `OMP_WAIT_POLICY=passive` at runtime to avoid MKL/CPU spin in the embedding worker.
- `zig build install -Doptimize=ReleaseFast --prefix $HOME/.local` installs to `~/.local/bin/`.

## Building the TUI

TUI built with libvaxis vxfw (source in zig-pkg). Prefer framework primitives.

**vxfw gotcha:** widget methods like `TextField.widget()` are _mutating_ — they take `*Self`, not `*const Self`. Accessors returning `*TextField` must be declared on `*App`, not `*const App`, or the call site fails to type-check.

**Zig 0.16 field rule:** `pub` cannot precede a field declaration — only functions/variables. Cross-module field access goes through `pub fn` accessors (`getX()` form, never `X()`, because of the field-vs-method name collision).

**TUI module split.** `src/tui.zig` holds the `App` lifecycle and the top-level `RootWidget`; the rest of `src/tui/` is split by concern. See `README.md` Architecture for the current module list (kept in sync as `tui.zig` shrinks).

**Domain extraction pattern.** Isolated domain clusters (lane lifecycle, diff lifecycle, session switching, at-search, transcript navigation, permission, event callbacks, queue, settings lifecycle, clipboard helper) live under `src/tui/` as free-function modules. Each module imports `const tui = @import("../tui.zig")` and defines `pub fn` taking `*App` as the first parameter. The original App method stays as a 1-line delegate (Strangler Fig) so inline tests in `tui.zig` resolve via the struct. When a private App method is needed from the new module, promote it to `pub` — not `pub const` (that is for module-level re-exports of nested types).

**Widget extraction pattern.** Isolated widgets live under `src/tui/widgets/`. A new widget file declares the outer border widget as `pub const NameWidget = struct { app: *App, pub fn widget(...) vxfw.Widget { ... } }` and a private `Inner` struct built inside `draw()` from a `vxfw.DrawContext`. The file imports `const tui = @import("../../tui.zig");`, `const tui_style = @import("../style.zig");`, `const panel = @import("panel.zig");` and re-aliases `const App = tui.App;`. Nested types from other modules (e.g. `BackgroundManager.JobView`, `ApprovalSnapshot`, `settings_widget.State`, `mcp_status.State`) are re-exported through `pub const` in `tui.zig` so widget files can reach them as `tui.<module>.<Type>`.

**Per-mode command routing.** `src/tui/command_router.zig` holds one struct per `App.Mode` variant. Each struct owns a `handle` method that used to be a private method on `App`; the dispatcher is a free function delegating to the right struct. Add new per-mode logic here — don't reintroduce private methods on `App` for key handling.

**Viewport scrolling pattern.** Standardize overlay list viewports using `panel.ViewportWindow.compute(selection, total_count, surface.size.height)` in `src/tui/widgets/panel.zig`. Use `viewport.screenRow(i)` for row rendering calculations.

**Provider polymorphism pattern.** Unify static builtin `config_mod.Provider` and dynamic `modelsdev.Provider` handles using `ProviderHandle = union(enum) { builtin: config_mod.Provider, dynamic: modelsdev.Provider }` in `src/tui/widgets/provider_picker.zig`.

**System clipboard pattern.** `src/clipboard.zig` handles OS clipboard reading/writing via terminal OSC 52 sequences (`\x1b]52;c;<base64>\x07`) with OS-native execution fallback (`wl-copy`/`xclip`/`pbcopy`/`powershell` via `bash.zig`). `clipboard_helper.zig` routes clipboard data dynamically to focused input fields and transcript message blocks.

**Settings lifecycle pattern.** `src/tui/settings_lifecycle.zig` manages pending tabbed form edits, syncs values to `app.cached_config` in real-time, and serializes user settings on `Ctrl+S`. `saveSettings` writes only settings-managed fields (`enable_thinking`, `use_responses_endpoint`, `system_prompt`, `bash_classifier_url`) — never provider/model. If a project config exists (`.nova/config.json`), settings are written to both global and project configs; otherwise global only. This prevents project-level provider/model overrides from leaking into global config.

**MCP Server & Tool Discovery pattern.** `src/mcp/manager.zig` merges `mcp_servers` configuration across global/project layers (supporting `mcp_servers`, `mcpServers`, and `mcp` JSON aliases) and scans Nova standard directories (`~/.config/nova/mcp/`, `<cwd>/.nova/mcp/`) for tool schema discovery. `McpMode.handle` in `command_router.zig` routes `Up`/`Down`/`j`/`k` list navigation, `Space`/`Enter` server toggling, `Ctrl+R`/`r` re-syncing, and `Esc`/`q` closing.

**Type System Discipline pattern.** Use `union(enum)` instead of flat structs with optional fields whenever a value can be in one of several mutually-exclusive states. This makes illegal combinations unrepresentable at compile time. Current types following this pattern:

- `ai.ChatMessage` — `union(enum) { system, user, assistant, tool }`. The `tool` variant carries `call_id` (non-optional); other variants cannot. `role()` and `text()` are cross-variant accessors.
- `transcript.Message` — `union(enum)` with 10 variants (`user`/`agent`/`skill`/`logo`/`thinking`/`status`/`notice`/`success`/`info`/`tool`). `Basic` and `ToolView` payload structs group fields by category. `kind()` bridges the loose `MessageKind` enum; `mirror()` is a test-only flat view.
- `tools.Output.display` — `Display` union with `none`/`text`/`diff` variants. Replaces the old `?[]u8 + DisplayKind` pair that allowed `null` with `.diff`.
- `config.McpServerConfig.transport` — `union(enum) { stdio, sse }`. A server is either stdio (command+args) or sse (url), never both or neither. Misconfigured entries caught at parse time.
- `mcp.McpClient` — `transport: union(enum) { stdio, sse }` (static config) + `lifecycle: union(enum) { disabled, stdio, sse, failed }` (runtime state). `status()` maps lifecycle to the legacy `ServerStatus` enum.
- `config.Config.model_selection: ?ModelSelection` — typed view replacing 9 loose optional fields. `ModelSelection` has non-optional `provider`/`model`/`base_url`/`api_key` (use `""` not null for `base_url`/`api_key` — `replaceOptionalSlice` cannot be used on non-optional `[]u8` fields). `base_url` may be `""` when `model_selection` is synthesized from session metadata or legacy fields; callers must resolve it via `provider.defaultBaseUrl()` before passing it to client init. `applyConfigOverlay` treats `model_selection` as canonical: if present it wins; if absent, legacy fields apply and `syncModelSelectionFromLegacy` mirrors them back into `model_selection`. `parseObject` only populates `model_selection` when ALL four fields are non-null, so disk-loaded configs rarely have it — it's bootstrapped in memory by `updateCachedModelSelection`.
- `tui.AtSearchState` — `union(enum) { closed, indexing, open }` with `IndexingPayload` and `OpenPayload` structs. `kind()`/`results()`/`close()` helpers bridge callers.
- `tui.NavState.quit` — `QuitState = union(enum) { none, pending, confirmed }` replacing `?Timestamp + bool`.
- `tui.ModelCatalogue.load` — `LoadState = union(enum) { idle, loading, failed }`.
- `search.Backend.state` — `State = union(enum) { idle, loading, ready, failed }`. `handle: *anyopaque` stays opaque (fff C FFI standard).
- `tui.MetricsState.diff` — `DiffState = union(enum) { idle, loading, ready, refreshing }`. The `refreshing` arm keeps the old cache while a new fetch is in flight.
- `config.ProviderModel = Model` — type alias removing duplicate struct drift.
- `session.SessionSummary.leaf_entry_id: ?EntryId` — branded `EntryId` (fixed-size `[entry_id_len]u8`) instead of loose `[]u8`.

**Models.dev provider filtering pattern.** `parseModelsDevJson` in `src/modelsdev.zig` includes any provider with a non-empty `api` field and ≥1 model — npm package identity is irrelevant. The `api` field is the ground-truth signal that the endpoint can be driven by Nova's `openai_compatible` adapter. This means `@ai-sdk/anthropic` providers with custom `api` endpoints (kimi-for-coding, minimax, etc.) are included, while `@ai-sdk/openai` providers without `api` (openai, perplexity-agent) are excluded because `Provider.base_url` is non-optional. Providers without an `api` field (`@ai-sdk/google`, `@ai-sdk/azure`, etc.) are correctly excluded.

**Models.dev network-first loading pattern.** `loadOrFetchRegistry` tries sources in order: (1) network fetch from `https://models.dev/api.json` with User-Agent `nova-agent/1.0`, (2) fresh cache (within 24h TTL), (3) stale cache (ignoring TTL), (4) vendored snapshot at `<exe_dir>/../share/nova/api.json` (installed by `zig build install`), (5) builtins-only fallback. The vendored snapshot also seeds the cache directory (`~/.config/nova/cache/models.dev/api.json`) so subsequent starts skip the file read. This ensures newly added providers appear immediately when online and 145+ dynamic providers are always available offline. `openProviderPicker` in `src/tui/provider_model.zig` deinits and reloads `modelsdev_registry` every time the picker opens, so fresh data is always available. Diagnostic logging at each stage (`modelsdev.fetch.ok`, `modelsdev.fetch.failed`, `modelsdev.cache.fresh`, `modelsdev.cache.stale`, `modelsdev.vendored`, `modelsdev.registry.fallback`) helps diagnose empty provider lists.

**Dynamic provider connection pattern.** When a models.dev dynamic provider is selected, `submitDynamicProviderSetup` stashes the provider's `base_url` and the user's API key into `cached_config` before entering the model picker. This is necessary because `applySelectedModel` resolves the connection URL and key through `compatibleBaseUrl`/`compatibleApiKey`, which check `cached_config.base_url` and `cached_config.api_key` — but the `ModelSource` tag is `.openai_compatible` (which has `defaultBaseUrl() = null` and no stored key). Without this stash, both return null/empty and the connection fails with `NotConnected`. The stash also sets `cached_config.provider = .openai_compatible` so `compatibleProviderFromBaseUrl` matches the URL to the correct provider tag.

**Typed callback pattern.** `agent.Listener(Ctx)` and `executor.ToolCallObserver(Ctx)` are generic over the consumer's context type. The `*anyopaque` + `@ptrCast` vtable is replaced by `*Ctx` + typed callback functions. `StreamContext(L)` and `ExecutorBridge(L)` are generic over the listener type. The sole remaining `@ptrCast` is `BashApproval` (1 site, deferred because making it generic would require `Agent` itself to be generic).

**Manual compaction trigger pattern.** `Agent.forceCompact()` is a synchronous public method that runs the full compaction cycle (snapshot → summarize → swap) and returns `!Event.HistoryCompacted` with token counts before/after. Unlike the automatic path (which runs between turns inside `agent.run()`), this is callable from the TUI command handler. The caller is responsible for turn-safety: check `app.thread.turn.isActive()` before calling. Errors are surfaced to the user via transcript notices rather than swallowed in logs.

**Config layering pattern.** Nova merges global (`~/.config/nova/config.json`), project (`.nova/config.json`), and env-var overlays into `cached_config`. `applyConfigOverlay` uses an if/else structure: `model_selection` is the canonical form; legacy fields (`default_provider`, `default_model`, etc.) are fallback. `syncModelSelectionFromLegacy` mirrors legacy field changes back to `target.model_selection` using `|*ms|` pointer capture (not `const ms = … orelse return`) to allow mutation. `modelSelectionUpdates` in `provider_model.zig` sets both legacy fields AND `model_selection` for self-consistency on disk (with `api_key=""` — never serialized — and `base_url` from the provider). `serialize` skips `api_key` entirely (lives in `auth.json`) and skips `base_url` when `model_selection` is present (rehydrated from providers at load time). `saveSettings` writes only settings-managed fields (`enable_thinking`, `use_responses_endpoint`, `system_prompt`, `bash_classifier_url`) — never provider/model. If a project config exists, settings are written to both global and project configs; otherwise global only. `defaultModelScope` returns `.project` if a project config exists, `.global` otherwise. At connection time, `tryAttachOpenAiCompatibleFromConfig` and `tryAttachOpenAiResponsesFromConfig` resolve a possibly-empty `ms.base_url` through `provider.defaultBaseUrl()` so client `init` never sees an empty URL.

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
- **POSIX Environment Access:** Never index `std.c.environ` directly in loops (`while (std.c.environ[i]) |e|`). In Zig 0.16 on POSIX, `std.c.environ` is `[*:null]?[*:0]u8`. Use `const env_slice = std.mem.span(std.c.environ);` and pass to `std.process.Environ.createMap(.{ .block = .{ .slice = env_slice } }, gpa)` to prevent null-pointer segfaults in multi-threaded contexts.
- **Models.dev Registry Allocations:** `modelsdev.Registry` string storage uses an `ArrayList(u8)`. To prevent dangling slice pointers when building or merging providers, accumulate string offsets via `StringRef` (`start`, `len`) and resolve slice pointers only after all string appends complete.
- **Dynamic Context Compaction:** Never hardcode fixed context retention budgets (e.g. 20,000 tokens) when compacting history. Use `compaction.keepRecentTokens(context_window)` so small-context models (8K/16K/32K) keep a scaled history window (%35 max 20,000) and can always compact below their swap watermark.
- **Streaming SSE Tool Call Deduplication & Parallel Remap:** In `src/ai/openai_compatible.zig`, tool call names and IDs are atomic in streaming — first complete value wins. Subsequent name/ID deltas are ignored. This deduplicates repeated names (the `bashbash` fix) and prevents cross-tool concatenation. Some providers reuse `index: 0` for all parallel tool calls; `ToolCallStream` detects this by comparing tool-call IDs (always unique). When a new ID arrives at an occupied logical index, the call is forked into a new physical builder slot. Argument continuation deltas (no ID) route through the remap to the correct slot. Limitation: if the provider omits IDs entirely, collision detection is impossible and the second call is lost (first writer wins for the name).

## Verifying

Run:

- `zig fmt`
- `zig build test`

## Known Issues

- **Session resume shows blank TUI (fixed).** At startup (`root.zig` → `initResume`), the agent is rehydrated from the session DB but the TUI transcript was never populated — only the logo animation was appended. Fix: call `app.rebuildTranscriptFromAgent()` in `tui.run()` before deciding whether to show the logo. For a resumed session the transcript is populated from the agent's message history; for a new session the transcript stays empty and the logo falls through as before.

- **High CPU usage from spinlocks.** `std.atomic.Mutex` busy-waits and pegs the CPU on multi-core. Use `std.Io.Mutex` and `std.Io.Condition` instead (paired via `static_thread_pool` or similar). Symptom: 80% CPU at idle, drops to ~2% after the fix. Files affected: `lib/logger.zig`, `src/agent.zig`, `src/background.zig`, `src/session.zig`.

- **Double-free in `postAgentEvent` / `postTurnFailed` / `runAgentTurn` (fixed).** `postAgentEvent` takes ownership of the event — on error it frees the event's data internally. Callers' catch blocks were freeing `message_text` again (double-free), and the QueueFull handler in `postAgentEvent` was manually cleaning up `event_ptr` before `return error.TurnCancelled`, which triggered errdefer to repeat the same cleanup. Fix: remove `worker_context.gpa.free(message_text)` from catch blocks in `runAgentTurn` and `postTurnFailed`; remove manual `event_ptr.deinit`+`destroy` before `return error.TurnCancelled` in `postAgentEvent`.

- **Session resume panics on empty `base_url` (fixed).** When resuming a session with no `model_selection` in config, `initSession` synthesized one with `.base_url = ""`. That empty string reached `openai_compatible.Client.init`, which asserts `base_url.len > 0`. Fix: initialize `model_selection.base_url` from `provider.defaultBaseUrl()` instead of `""`, and add fallback resolution in `tryAttachOpenAiCompatibleFromConfig` / `tryAttachOpenAiResponsesFromConfig` so client `init` never sees an empty URL.
