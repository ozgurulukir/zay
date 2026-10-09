### Schema v2 (current)

Chat-completions providers and individual models can declare `responsePolicy`
to describe proxy-specific inbound fields. For example,
`"responsePolicy":{"thinking":"text"}` treats that field as an answer.
Supported fields are `reasoning`, `reasoning_content`, `reasoning_details`, and `thinking`; each maps
to `text`, `reasoning`, or `ignore`. Unspecified fields inherit lower config
layers and provider defaults, with model settings taking precedence. This is
independent of `reasoningEffort` and applies when attaching or switching models.
Use an override only when the provider's response schema gives that field a
different meaning. Ordinary `content` always remains answer text.

JSON keys are **camelCase**. Legacy snake_case keys from schema v1 are still accepted at parse time for backward compatibility; `serialize` always writes camelCase.

```json
{
  "version": "2.0.0",
  "defaultModel": "ollama/llama3.1:8b",
  "baseURL": "http://localhost:11434",
  "useResponsesEndpoint": false,
  "strictOutputs": false,
  "systemPrompt": "Custom system prompt for this project...",
  "bashClassifierUrl": "http://localhost:8000/classify",
  "theme": "cappuccino",
  "context": {
    "overrideContextWindow": 32000,
    "maxOutputTokens": 4096,
    "compaction": {
      "auto": true,
      "threshold": 0.75,
      "keepRecentTokens": 8000,
      "keepRecentToolTurns": 12,
      "toolOutputCapBytes": 8192
    }
  },
  "toast": {
    "enabled": true,
    "durationMs": 4000,
    "maxVisible": 3
  },
  "providers": {
    "openai": {
      "baseURL": "https://api.openai.com/v1",
      "models": {
        "gpt-4o": { "reasoningEffort": "high" }
      }
    },
    "ollama": {
      "baseURL": "http://localhost:11434",
      "models": {
        "llama3.1:8b": {}
      }
    }
  },
  "mcpServers": {
    "memory": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-memory"],
      "enabled": true
    }
  }
}
```

### Supported Fields

| Field                  | Type      | Description                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ---------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `version`              | `string`  | Semver schema version (currently `"2.0.0"`). Legacy integer `1` is normalized to `"1.0.0"` at parse time; a bare major (`"2"`) is also accepted. A major version above 2 is reported by `Config.validate` as an `unsupported schema version` diagnostic — note that `validate` is not part of the normal load path today, so the diagnostic surfaces through the validator rather than automatically on startup.                                                                                                                                                                                                                                                                                                                             |
| `defaultModel`         | `string`  | Model selection in `<provider>/<model-id>` format (e.g., `"openai/gpt-5.5"`, `"ollama/llama3.1:8b"`, `"qwen-cloud/qwen3.7-plus"`). The provider part is split on the first `/`; model ids may contain further slashes (e.g., `"huggingface/meta-llama/Llama-3.1-8B"`). Both parts may contain `:`, `+`, `.`, `_`, and `-`. Custom provider names are supported. This is the **single source of truth** for provider identity — there is no separate `provider` field. Legacy key `model` is parsed for backward compatibility but is not schema-valid; new configs must use `defaultModel`. |
| `baseURL`              | `string`  | Custom API endpoint base URL. Should start with `http://` or `https://` — `Config.validate` reports a non-http(s) scheme, but `validate` is not run on the normal load path today, so nothing rejects such a value at startup. In memory, this may be `""` when synthesized from session metadata or legacy fields; it is resolved through the provider's default before any network request. Legacy key `base_url` is parsed for backward compatibility but is not schema-valid; new configs must use `baseURL`.                                                                                                                                                                          |
| `useResponsesEndpoint` | `boolean` | `true` to route via OpenAI Responses API instead of ChatCompletions. Legacy key `use_responses_endpoint` is parsed for backward compatibility but is not schema-valid; new configs must use `useResponsesEndpoint`.                                                                                                                                                                                                                                                                                                                             |
| ~~`enableThinking`~~   | ~~`boolean`~~ | **Removed.** Reasoning is controlled per-model via `providers.<name>.models.<id>.reasoningEffort` (see [Provider configuration](#provider-configuration)). The legacy key (`enableThinking` / `enable_thinking`) is still accepted at parse time but silently ignored, and dropped on the next save.                                                                                                                                                                                                                                   |
| `strictOutputs`        | `boolean` | `true` to send OpenAI strict structured-outputs mode (`"strict":true`, `additionalProperties:false`, all properties in `required`) in tool definitions. **Only works against the OpenAI API** — gateways (OpenRouter/Ollama/vLLM/Together) reject or silently break it, which disables function-calling (the model then emits tool calls as plain text). Defaults to `false` so tool-calling works everywhere. Enable only when talking directly to OpenAI. Legacy key `strict_outputs` is parsed for backward compatibility but is not schema-valid; new configs must use `strictOutputs`. |
| `systemPrompt`         | `string`  | Base system prompt template. Values over **10 000 chars** are dropped at parse with a `config_parse_error` diagnostic — the field is never silently truncated. An **empty string** is treated as absent (dropped at parse) — clear the field via `/settings` (Del) or by removing the key. Legacy key `system_prompt` is parsed for backward compatibility but is not schema-valid; new configs must use `systemPrompt`.                                                                                                                                                                                                                                                                                                                                                           |
| `bashClassifierUrl`    | `string`  | External classifier endpoint for shell command safety check (e.g. `http://127.0.0.1:8765/classify`). When omitted, null, or empty, Zay uses its built-in safety rules. Legacy key `bash_classifier_url` is parsed for backward compatibility but is not schema-valid; new configs must use `bashClassifierUrl`. |
| `databaseServerUrl`    | `string`  | Base URL for the external database companion service (e.g. `"http://127.0.0.1:8766"`). When set, Zay delegates session persistence to this external REST service for cross-machine roaming, and exposes the built-in `database` tool to the agent. When omitted, empty, or offline at boot, Zay falls back to the local embedded `sessions.sqlite` (platform config dir; `%APPDATA%\zay\sessions.sqlite` on Windows). Legacy key `database_server_url` is parsed for backward compatibility but is not schema-valid; new configs must use `databaseServerUrl`. |
| `databaseAuthToken`    | `string`  | Optional bearer authentication token or API key for the external database service. Sent in the `Authorization: Bearer <token>` header. Legacy key `database_auth_token` is parsed for backward compatibility but is not schema-valid; new configs must use `databaseAuthToken`. |
| `theme`                | `string`  | Name of the color theme for the TUI. `default` preserves the classic look; other builtin themes are `cappuccino` (Catppuccin Mocha), `tokyo_night` (Tokyo Night), `dracula` (Dracula), `nord` (Nord), `gruvbox_dark` (Gruvbox Dark), and `okabe_ito` (Okabe–Ito color-vision-deficiency-friendly palette). Custom theme slugs loaded from the themes directory are also valid. Unknown or empty names fall back to `default` at resolve time; absent = `default`. The builtin themes are compiled in — a new builtin theme is added to `src/tui/style.zig`. No legacy snake_case key or environment variable exists for this field. |
| `tui`                  | `object`  | TUI appearance, live preview, picker, multi-lane split layout, and status-bar telemetry settings. See [TUI Theme & Search Ergonomics](#tui-theme--search-ergonomics) and [TUI Layout & Telemetry](#tui-layout--telemetry).                                                                                                                                                                                                        |
| `toast`                | `object`  | Transient toast notifications (top-right TUI notices). See [Toast settings](#toast-settings).                                                                                                                                                                                                                                                                                                                                                          |
| `context`              | `object`  | Context window management and compaction policy. See [Context & Compaction settings](#context--compaction-settings).                                                                                                                                                                                                                                                                                                                                    |
| `mcpServers`           | `object`  | MCP server configurations (Claude Desktop format compatible). Legacy keys `mcp_servers` and `mcp` are parsed for backward compatibility but are not schema-valid; new configs must use `mcpServers`.                                                                                                                                                                                                                                                                                                                                   |
| `plugins`              | `object`  | Lua plugin configuration keyed by plugin name. Each entry controls whether the plugin is enabled and its custom settings (JSON string). Settings are passed to the plugin's Lua code via `plugin.get_config()`.                                                                                                                                                                                                                                        |
| `providers`            | `object`  | Per-provider configuration keyed by provider name. Accepts builtin labels and custom provider names (see below).                                                                                                                                                                                                                                                                                                                                       |
