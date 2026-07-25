# Nova

The coding agent for shipping to the stars.

> Alpha software. Expect things to break.

## Quick Start

Git clone `fff` (used for file search) into `third_party/` and build it. Specific instructions
in [vendor/fff/README.md](vendor/fff/README.md).

Download `P0u4a/ModernBERT-bash-classifier` from huggingface (used for classifying the bash tool calls). Easiest way is with huggingface cli.

```bash
hf download P0u4a/ModernBERT-bash-classifier
```

And export the model to ONNX

```bash
cd vendor/local-models
uv run python export_onnx.py --model-dir /path/to/model
```

Then

```sh
zig build run
```

Add the binary (`zig-out/bin/nova`) to your PATH so you can invoke it from anywhere.

## Slash Commands & Key Features

- **`/connect`**: Configure AI providers, custom endpoints, and API key management.
- **`/model`**: Select LLM model & reasoning effort.
- **`/mcp`**: Real-time Model Context Protocol server status (stdio & remote transports), active tool counts, latency monitoring, server toggling (`Space`/`Enter`), schema re-syncing (`Ctrl+R`), and adding a remote server by URL (`a`, runtime-only).
- **`/settings`**: Interactive tabbed configuration panel (General, System Prompt, Advanced, About) with `Ctrl+S` instant save.
- **`/copy` & `/paste`**: Copy selected transcript message blocks or diff comments to the system clipboard; paste into prompt fields (`Ctrl+V` / `Shift+Insert`).
- **`/help`**: Scrollable quick reference guide with keyboard and mouse wheel navigation.
- **`/timeline`**: Interactive session tree browser for exploring branching conversation paths.
- **`/diff`**: Full-screen git diff viewer with inline commentary.
- **`/parallel` & `/lanes`**: Manage parallel worktree lanes and merge folded branches.
- **`/save`**: Commit git-shadow working copy snapshots.

## Architecture

The TUI is a vxfw application. `src/tui.zig` holds the `App` lifecycle;
the top-level `RootWidget` lives in `src/tui/root_widget.zig`. The rest
of `src/tui/` is split by concern:

- `event_router.zig` — top-level event entry (`captureEvent`), key/mouse dispatch, and modal focus routing.
- `command_router.zig` — per-mode key dispatch (one struct per `App.Mode`).
- `app_state.zig` — `App` state grouped into sub-structs (`InputState`, `PickerStates`, `NavState`).
- `settings_lifecycle.zig` — settings panel tabbed navigation, inline text editing, live config sync, and `Ctrl+S` disk save.
- `clipboard_helper.zig` — TUI integration for system clipboard operations (`copySelectedTranscriptBlock`, `copyDiffToClipboard`, `pasteToFocusedInput`).
- `background_delivery.zig` — background-job poll/format/deliver, modal toggling, job cancel.
- `turn_lifecycle.zig` — turn start, interrupt, event application, cancel/reset.
- `checkpoint.zig` — git-shadow checkpoint snapshotting, readiness checks, and `/save`.
- `mode_lifecycle.zig` — command matching, slash menu checks, mode switching.
- `input_lifecycle.zig` — input buffer peeking, clearing, vertical cursor navigation.
- `transcript_lifecycle.zig` — runtime installation and transcript rebuilding.
- `lane_lifecycle.zig` — lane naming, cycling, closing, merging, `/lanes` overlay.
- `diff_lifecycle.zig` — async diff refresh pipeline (DiffCounts, schedule/cancel/drain).
- `session_switcher.zig` — resume picker, session creation, timeline navigation.
- `at_search.zig` — `@` file / `$` skill mention popup.
- `transcript_nav.zig` — transcript scrolling, auto-scroll, long-message paging.
- `permission.zig` — tool-call approval/rejection overlay.
- `event_callbacks.zig` — vxfw input-change callbacks (`inputChanged`, `paletteInputChanged`).
- `queue.zig` — enqueue, flush, and navigate queued user messages.
- `layout.zig` — `rootLayout` math for `drawRoot` (transcript / loading / input row split).
- `lane_column.zig` — per-lane bordered transcript column (split view).
- `diff_viewer_overlay.zig` — full-screen `/diff` overlay.
- `root_layout.zig` — top-level `drawRoot` layout (tile grid, loading, input, overlay stack).
- `lifecycle.zig` — `deinit`, `handleTick`, `createParallelLane`, diff key handlers, `syncFocus`, `submit`, `ensureTick`.
- `diff_utils.zig` — pure diff-count stat/numstat parsers, git label loader.
- `lanes.zig` — `MergeSource` type + lane merge helpers (`workingLaneOf`, `laneErrorText`).
- `provider_model.zig` — provider connection, model catalogue loading, dynamic models.dev integration, provider setup forms, and ProviderHandle dispatch.
- `model_loader_job.zig` — async model loading background jobs, outcome installation, and disk cache persistence.
- `thread.zig` — `Thread` (lane) state, multi-lane state machine.
- `turn.zig` / `turn_view.zig` — turn lifecycle + render.
- `diff_viewer.zig` — `/diff` inline-diff helpers (used by `widgets/diff.zig`).
- `model_catalogue.zig` / `model_loader.zig` / `model_cache.zig` — model catalogue, async loader, cached model handles.
- `provider_controller.zig` — provider API controller.
- `agent_worker.zig` — agent worker plumbing.
- `blackhole.zig` — startup animation.
- `root_widget.zig` — top-level vxfw widget (delegates to per-concern modules).
- `metrics.zig` — runtime metrics.
- `naming.zig` / `style.zig` / `status.zig` / `tool_policy.zig` — shared helpers and policies.

`src/tui/widgets/` holds the per-widget draw code (`message`, `command_panel`, `at_search`, `background_jobs`, `permission`, `diff`, `loading`, `transcript`, `input`, `overlay`, `lanes_picker`, `model_picker`, `provider_picker`, `resume_picker`, `help_picker`, `mcp_status`, `settings`, `tree_selector`, `panel`, `tree_art`).

### Core Systems & Engine

- **`mcp/manager.zig` & `mcp/client.zig`**: Multi-server Model Context Protocol supervisor with layer-merged `mcp_servers` configuration (`mcp_servers`, `mcpServers`, `mcp` aliases) and automatic tool schema discovery across Nova standard directories (`~/.config/nova/mcp/`, `<cwd>/.nova/mcp/`). `McpServerConfig.transport` is a `union(enum) { stdio, sse }` — a server is either stdio (command+args) or remote Streamable HTTP (url), never both; `{env:VAR}` placeholders in command/args/url expand from the environment. `McpClient` carries a `lifecycle: union(enum) { disabled, stdio, sse, failed }` for runtime state. Discovered tools are re-injected into the live AI client (`updateMcpTools`) on startup and whenever the server set changes, so the model sees `mcp__<server>__<tool>` definitions without a provider reconnect.
- **`clipboard.zig`**: Cross-platform system clipboard interface supporting OSC 52 terminal escape sequences (`\x1b]52;c;<base64>\x07`) with OS-native execution fallback (`wl-copy`/`xclip`/`pbcopy`/`powershell` via Nova's `bash` subsystem).
- **`config.zig`**: System configuration parser and disk serializer (`~/.config/nova/config.json`). Controls system prompt, thinking/reasoning toggles, MCP servers, and classifier parameters. `Config.model_selection: ?ModelSelection` is the typed view replacing 9 loose optional fields — `ModelSelection` carries non-optional `provider`/`model`/`base_url`/`api_key`.
- **`modelsdev.zig`**: Provider registry integration combining built-in static providers with dynamic data from `https://models.dev/api.json`. Supports local disk caching at `~/.config/nova/cache/models.dev/api.json` and safe string arena management (`StringRef` / `UnresolvedProvider`).
- **`compaction.zig`**: Pure decisions for automatic context window compaction. Calculates dynamic retention budgets (`keepRecentTokens`) scaled to the model's context window (%35 max 20,000) so small-context models (e.g. 8K/16K/32K) can always compact cleanly below their swap watermarks.
- **`agent.zig`**: Autonomous loop orchestrating LLM tool execution, background/synchronous context compaction, and VCS git-shadow checkpointing (`snapshotAfterBatch`). `Listener(Ctx)` is a generic typed callback seam — callers pass their own context type instead of `*anyopaque` + `@ptrCast`.
- **`ai/openai_compatible.zig`**: OpenAI-compatible API client with SSE stream parsing and tool-call delta deduplication (prevents tool name corruption when providers stream repeated tool names). `ChatMessage` is a `union(enum) { system, user, assistant, tool }` — illegal combinations (e.g. `.user` with `call_id`) are unrepresentable.
- **`runtime.zig`**: Dual client lifecycle (primary turn client + compaction/naming secondary clients), context usage tracking reset on model switch, and robust session initialization/resume error recovery.
- **`session.zig`**: SQLite-backed session persistence (`sessions.sqlite`). Tolerant payload decoding handles both standard text strings and byte array JSON encodings. `SessionSummary.leaf_entry_id` is branded as `?EntryId` (fixed-size `[entry_id_len]u8`) enforcing the DB length invariant at compile time.
