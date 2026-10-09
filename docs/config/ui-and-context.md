### Context & Compaction Settings

The `context` object controls context window management and automatic summarization:

| Field                                 | Type      | Default  | Description                                                                                                                                                  |
| ------------------------------------- | --------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `context.overrideContextWindow`       | `integer` | _(auto)_ | Explicit context window in tokens. Overrides the model catalogue lookup — useful for local Ollama/LMStudio models with non-standard windows. Minimum 1024.   |
| `context.maxOutputTokens`             | `integer` | _(auto)_ | Maximum tokens per single model generation turn.                                                                                                             |
| `context.maxConcurrentRequests`       | `integer` | `2`      | Cap on LLM requests in flight across ALL lanes at once. Each lane runs its own worker + HTTP client, so without this cap N active lanes fire N independent requests at the provider, which degrades or rate-limits the burst (every lane slows down together). Minimum 1 — a value of 0 would deadlock every request. Set `1` to serialize requests; raise it only if your provider handles more concurrent streams without degrading. |
| `context.maxParallelToolCalls`        | `integer` | `16`     | Upper bound on parallel tool calls accepted from the model in one assistant batch. Providers exceeding this cap get a logged error and the excess calls are dropped. Accepted range 1–64; out-of-range values are dropped and the default is used. |
| `context.requestTimeoutSeconds`       | `integer` | `300`    | Socket read timeout in seconds for streaming responses. Prevents indefinite hangs when the server stops mid-stream. Minimum 1. |
| `context.disablePromptCache`          | `boolean` | `false`  | Disable provider prompt-caching fields entirely. When `true`, for OpenRouter neither the top-level `cache_control` (auto breakpoint) nor the native `session_id` (sticky routing) is emitted; for OpenAI, `prompt_cache_key` is suppressed — in BOTH the chat-completions and Responses API clients, regardless of the resolved wire dialect. Use this for OpenRouter `:free` / gateway-fronted models (kimi, inclusionai/ling) that reject these fields with HTTP 400 — a 400 there kills the whole turn and surfaces as "the model can't call any tools." Zay also auto-recovers once via a cache-stripped retry (C2) when the 400 body mentions "cache", so setting this flag is the durable fix for a known-bad model. |
| `context.toolCallLimitPerTurn`        | `integer` | `100`    | Shared upper bound on individual tool calls and model-response iterations within one turn. Every call in a parallel assistant batch counts toward the tool-call cap; an over-budget batch runs only the allowed prefix and records failed results for skipped calls. Accepted range 1–1000; out-of-range values are dropped and the default is used. Raise for deep refactors or long migration loops that legitimately need more calls. The legacy snake_case spelling `tool_call_limit_per_turn` is parsed for compat but not schema-valid. |
| `context.softStopOnToolCallLimit`     | `boolean` | `true`   | When `true`, reaching `toolCallLimitPerTurn` does NOT fail the turn: the loop exits cleanly, queued user messages are delivered into history (a queued "continue" is never swallowed), a `[zay]` continuation hint is left as a trailing user message so the next prompt resumes seamlessly, and the TUI renders a budget notice row. When `false`, behavior matches previous releases: the turn ends with a `ToolCallLimit` failure. Scripted/headless users who grep for that failure should pin `false`. |
| `context.autoContinueOnLengthCut`     | `boolean` | `true`   | When `true`, a response severed by the provider's output token cap (`finish_reason=length`, or the Responses API's `response.incomplete` with `incomplete_details.reason = max_output_tokens`) with no tool calls is continued ONCE automatically inside the same turn: a `[zay]` continuation hint is appended and the model re-requested. Guards against providers whose default completion budget cuts the tool_call section off after the prose (half-finished tool calls — the turn otherwise ends silently as a text-only message that looks complete). The cut always renders an amber "output" notice row; set `false` to only notify and never spend the extra request. The legacy snake_case spelling `auto_continue_on_length_cut` is parsed for compat but not schema-valid. |
| `context.compaction.auto`             | `boolean` | `true`   | Enable automatic context compaction before reaching limits.                                                                                                  |
| `context.compaction.threshold`        | `number`  | `0.75`   | Fraction of context window that triggers background summarization. Accepted when `0.1 ≤ t ≤ 1.0`; anything above `0.90` is clamped down to the `0.90` ceiling at parse time, and values outside the accepted band are **dropped** so the `0.75` default is used. The swap watermark is derived as `threshold + 0.20` (capped at 0.95), so clamping keeps it from falling below the start watermark. |
| `context.compaction.keepRecentTokens` | `integer` | `8000`   | Recent conversation tokens retained verbatim alongside the generated summary. Scaled down proportionally for small-context models (35% of window, min 1000). When real provider usage outruns the chars/4 estimate (CJK text), the budget is shrunk by the measured ratio so compaction still lands below the swap watermark. |
| `context.compaction.keepRecentToolTurns` | `integer` | `4`   | Number of most recent tool-result turns kept in full when assembling each prompt. Older tool results are pruned to `historicalToolCapBytes` with a `[... N of M bytes elided to save context ...]` notice. Raise this when an agentic turn needs earlier tool outputs in full (e.g. multi-phase skills like `tci-bfg` that fire dozens of commands). Minimum 1 — a value of 0 would prune every tool result and break tool-calling. |
| `context.compaction.historicalToolCapBytes` | `integer` | `1024` | Byte cap applied to tool results older than `keepRecentToolTurns` — a head+tail sandwich (first half + last half of the budget, joined by `common.elideMiddle`) keeps both the start and the load-bearing conclusion (errors, results, status) of a command output. Raise for large command outputs the model must re-read later in the same turn. |
| `context.compaction.evictHistoryImages` | `boolean` | `true` | Replace image blocks in OLDER user messages with a deterministic re-mention stub (`[image: photo.png (2.4 MB) — shown in an earlier turn; mention @photo.png to view it again]`) when assembling each request — only the newest user message keeps its images. Chat-completions APIs are stateless, so without eviction every historical image re-uploads its base64 on every follow-up turn; eviction removes that while keeping re-examination one `@`-mention away. Disable when every image must stay attached every turn (or for providers that hold server-side image state). |

**Example — local Ollama with aggressive compaction and lenient tool-result pruning:**

```json
{
  "context": {
    "overrideContextWindow": 8192,
    "maxConcurrentRequests": 2,
    "compaction": {
      "threshold": 0.6,
      "keepRecentTokens": 3000,
      "keepRecentToolTurns": 12,
      "historicalToolCapBytes": 8192
    }
  }
}
```

### Toast Settings

The `toast` object controls transient notifications shown stacked in the top-right corner of the TUI. With the TUI running, `warn`+ log output routes to the toast bus **instead of stderr** — stderr writes land in the alternate screen and tear the rendered frame, so the toast overlay is the intended surface for operational warnings. The bus is generic: any subsystem (MCP, lanes, background jobs) can push a toast.

| Field                | Type      | Default     | Description                                                                                                                                                                                                                  |
| -------------------- | --------- | ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `toast.enabled`      | `boolean` | `true`      | Master switch. When `false`, no toasts are shown — `warn`+ output is dropped from the TUI. Set `ZAY_LOG_STDERR_LEVEL` to route it back to stderr. Also toggled live from the `/settings` General tab.                       |
| `toast.durationMs`   | `integer` | `4000`      | Auto-dismiss delay in milliseconds. Out-of-range values are **dropped** (left null) at parse time, not clamped — a typo can't produce a toast that never dismisses. Config-file only.                                         |
| `toast.maxVisible`   | `integer` | `3`         | Maximum toasts stacked at once. Out-of-range values are dropped at parse time. Config-file only.                                                                                                                             |
| `toast.position`     | `string`  | `top-right` | Corner position. **Reserved for future use** — only `top-right` is rendered today; other values are parsed and persisted but have no effect yet.                                                                            |

> [!NOTE]
> **Restoring the stderr channel.** When the TUI is up, `warn`+ logs go to the toast, not stderr. To keep full stderr output (e.g. for `zay 2> err.log` diagnostics), set `ZAY_LOG_STDERR_LEVEL` explicitly (`err`/`warn`/`info`/`debug`) — an explicit value sends output to **both** stderr and the toast, while leaving it unset sends `warn`+ to the toast only. Headless/test runs have no toast sink installed and keep stderr as before.

### TUI Theme

The `theme` field selects a runtime color theme for the TUI at startup. The builtin themes are compiled into the binary (`src/tui/style.zig`):

| Field   | Type     | Description                                                                                           |
| ------- | -------- | ----------------------------------------------------------------------------------------------------- |
| `theme` | `string` | `default` (classic look), `cappuccino` (Catppuccin Mocha), `tokyo_night` (Tokyo Night), `dracula` (Dracula), `nord` (Nord), `gruvbox_dark` (Gruvbox Dark), `okabe_ito` (Okabe–Ito color-vision-deficiency-friendly palette). Unknown or empty names fall back to `default` at resolve time; absent = `default`. |

When changing themes dynamically in the TUI via `/theme <name>` or the interactive `/theme` picker:
- If the active project configuration (`<cwd>/.zay/config.json`) defines a `theme`, the new choice persists to the project configuration via `mergeAndWriteProject`.
- Otherwise, the theme persists to the user's global configuration (`~/.config/zay/config.json`) via `mergeAndWriteGlobal`.
- Unknown, empty, or typoed theme names fall back to `default` and display a notice in the transcript (`Theme '<name>' not found; using default`). If writing configuration to disk fails, the live session still switches theme and a `(not saved)` notice is appended.

### TUI Theme & Search Ergonomics

The `tui` object controls live theme preview, custom-theme discovery, and fuzzy-match highlighting in the search pickers:

| Field                     | Type      | Default    | Description                                                                                                                                                                                                                                                        |
| ------------------------- | --------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `tui.themeLivePreview`    | `boolean` | `true`     | Recolor the UI live while browsing themes in the `/theme` picker. `Esc` reverts to the pre-open theme; `Enter` commits and persists.                                                                                                                               |
| `tui.customThemesDir`     | `string`  | _(none)_   | Optional directory containing user theme JSON files. When set, it **replaces** the default scan of `~/.config/zay/themes/` and `.zay/themes/` — only this directory is scanned.                                                                                  |
| `tui.fuzzyHighlight`      | `boolean` | `true`     | Highlight matching characters in the search pickers (`@` mention, `/model`, `/resume`, `/theme`, `/command`).                                                                                                                                                      |
| `tui.fuzzyHighlightStyle` | `string`  | `accent`   | Style of matched runes: `accent` (the theme's accent orange), `bold`, or `underline`.                                                                                                                                                                              |
| `theme`                   | `string`  | `default`  | Active theme name. Any custom theme slug loaded from the themes directory resolves at startup and in the `/theme` picker. See [TUI Theme](#tui-theme).                                                                                                              |

### TUI Layout & Telemetry

The `tui` object also controls the multi-lane split layout and the status-bar token-velocity / context-meter telemetry:

| Field                        | Type      | Default | Description                                                                                                                                                                                                                                                           |
| ---------------------------- | --------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tui.splitMode`              | `string`  | `dual`  | Split layout mode when multiple lanes are open: `"dual"` (1:1 full-height driver + focused worker), `"grid"` (2x2 tile of all lanes), `"tab"` (single active-lane pane).                                                                                              |
| `tui.minSplitWidth`          | `integer` | `140`   | Minimum terminal column width required to trigger a split layout. Below this, the layout collapses to a single pane. Accepted range `[80, 500]`; out-of-band values are dropped at parse and the default is used.                                                                                                                 |
| `tui.highlightFocusedBorder` | `boolean` | `true`  | Render a high-contrast accent border around the focused split column.                                                                                                                                                                                                 |
| `tui.showTokenVelocity`      | `boolean` | `true`  | Show the real-time streaming token velocity gauge (`⚡ 58.4 tok/s`) in the status bar. **This is a `chars/4` byte estimate**, not an exact token count — it undercounts CJK (~1.5 chars/token) and overcounts punctuation.                                              |
| `tui.showContextMeter`       | `boolean` | `true`  | Display the visual context-window capacity meter (`[███████░░░] 75% (96.0k/128k)`) in the status bar, colored green/amber/red by usage.                                                                                                                                |
| `tui.velocitySmoothingAlpha` | `number`  | `0.35`  | Exponential-moving-average smoothing coefficient for the token velocity gauge. Accepted range `[0.05, 1.0]`; out-of-band values are dropped at parse and the default is used.                                                                                                                                                     |
| `tui.contextThresholdWarn`   | `number`  | `0.70`  | Context usage fraction that transitions the meter to amber warning. Accepted range `[0.1, 0.9]`; out-of-band values are dropped at parse and the default is used.                                                                                                                                                                |
| `tui.contextThresholdAlert`  | `number`  | `0.85`  | Context usage fraction that transitions the meter to red alert. Accepted range `[0.2, 0.99]`; out-of-band values are dropped at parse and the default is used.                                                                                                                                                                   |

**Keybindings:**

| Keybinding            | Scope            | Action                                                                                                    |
| --------------------- | ---------------- | --------------------------------------------------------------------------------------------------------- |
| `Ctrl+W`              | Global (normal)  | Cycle split layout: `dual` → `grid` → `tab` → `dual`.                                                     |
| `Ctrl+L`              | Split Mode       | Cycle which worker lane occupies the right pane in `dual`; falls back to the mode cycle in `grid`/`tab`.   |
| `Alt+Right` / `Alt+Left` | Split Mode (`dual`) | Cycle which worker lane occupies the right pane: `Alt+Right` = next, `Alt+Left` = previous (wrapping within the worker lanes). The driver is always the left pane; input routing stays with it. |
| Mouse click on a pane | Split Mode (`dual`) | Focus the clicked worker column (sets the focused worker in `dual`).                                        |

> [!NOTE]
> `Alt+Tab` is **not** a Zay binding — terminals never deliver the OS-level window-switch key. Per-pane `PageUp`/`PageDown` transcript scrolling is **deferred** (per-lane scroll state does not exist yet). The velocity gauge is a `chars/4` **estimate** (the compaction SSOT heuristic), not an exact token count.

**Custom theme JSON format.** Drop a `*.json` file into `~/.config/zay/themes/` (or `.zay/themes/`, or the directory named by `tui.customThemesDir`). Each file is a flat object with a `name` plus the 18 `Rgb` `[r,g,b]` arrays matching the builtin theme slots (`thinking_blue`, `user_yellow`, `success_green`, `failure_red`, `accent_orange`, `skill_purple`, `lane_pink`, `muted_gray`, `selection_bg`, `amber_yellow`, `white`, `code_blue`, `faint_add_bg`, `faint_del_bg`, `body`, `background`, `blackhole_orange`, `markdown_heading`):

```json
{
  "name": "my_theme",
  "thinking_blue": [96, 165, 250],
  "user_yellow": [212, 175, 55],
  "success_green": [34, 197, 94],
  "failure_red": [239, 68, 68],
  "accent_orange": [249, 115, 22],
  "skill_purple": [168, 85, 247],
  "lane_pink": [244, 114, 182],
  "muted_gray": [138, 138, 138],
  "selection_bg": [38, 38, 38],
  "amber_yellow": [245, 158, 11],
  "white": [255, 255, 255],
  "code_blue": [147, 197, 253],
  "faint_add_bg": [22, 43, 30],
  "faint_del_bg": [52, 27, 27],
  "body": [255, 255, 255],
  "background": [17, 17, 20],
  "blackhole_orange": [255, 106, 61],
  "markdown_heading": [252, 211, 77]
}
```

A theme is rejected (and skipped) if it fails validation parity with the builtin suite: body/background WCAG contrast below 4.5:1, or a `selection_bg`/`background` channel delta below 20 (a selected picker row must stay visible against a coincident card). Missing themes directories are a no-op, not an error.

> [!NOTE]
> **`tui.customThemesDir` replaces the default scan.** When set, only that directory is scanned for custom themes; `~/.config/zay/themes/` and `.zay/themes/` are ignored. An explicitly-set path means "use this location", not "also scan the defaults".

Activated skill instructions are retained in full independently of `keepRecentToolTurns` and `historicalToolCapBytes`. Compaction summarizes activation notices and keeps the full bodies in branch-scoped session metadata; request assembly supplies those bodies after the original messages are removed. These bytes are included in context estimates. Repeated skill mentions and calls do not add another full body.
