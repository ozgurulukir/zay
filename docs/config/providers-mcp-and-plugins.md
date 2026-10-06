### Provider Configuration

Each entry in `providers` is keyed by provider name. Builtin labels (`openai`, `openai_compatible`, `ollama`, `openrouter`, `cerebras`, `huggingface`, `nvidia_nim`, `opencode_zen`, `ollama_cloud`, `llama.cpp`, `deepseek`, `google`, `mistral`, `xai`, `perplexity`, `cohere`, `alibaba`, `anthropic`) are recognized and mapped to their typed enum. Any other key is treated as a **custom provider** using the OpenAI-compatible adapter — it appears in the `/connect` picker alongside builtins and models.dev providers.

| Field                          | Type       | Description                                                                                                                                                                                                                                                                                                                   |
| ------------------------------ | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `baseURL`                      | `string`   | Custom base URL for this provider. Legacy key `base_url` is parsed for backward compatibility but is not schema-valid; new configs must use `baseURL`.                                                                                                                                                                                                                                                    |
| `headers`                      | `object`   | Extra HTTP headers (string values) sent on every outbound request to this provider through the chat-completions and Responses-API clients (main turns, summarizer, branch naming) and on the model picker's `/v1/models` probes. Not applied to the Codex OAuth transport. Values support `{env:VAR}` placeholders, expanded once per client attach; see the notes below. A header with the same name as an auto-attached one (e.g. `x-opencode-session` for OpenCode Zen) **replaces** it. Reserved transport headers (`authorization`, `content-type`, `host`, `content-length`, `transfer-encoding`, `connection`) are rejected at parse — credentials belong in `auth.json`. Header names must be single-line tokens (no `:`, whitespace, or line breaks); values with line breaks are rejected. Max 8 entries. |
| `models`                       | `object`   | Per-model overrides keyed by model id.                                                                                                                                                                                                                                                                                        |
| `models.<id>.reasoningEffort`  | `string`   | One of `default`, `minimal`, `low`, `none`, `medium`, `high`, `xhigh`, `max`. `default` sends no reasoning parameter (model decides); `none` disables thinking explicitly; `max` is the OpenRouter-specific top level above `xhigh` (OpenAI-native dialects ignore it; Qwen/DashScope models clip it to `medium`). Internally stored as a `ReasoningSetting` union: when unset in a config layer, the lower layer's value is preserved during merge; when set, it overrides. |
| `models.<id>.contextWindow`    | `integer`  | Context window size in tokens. Overrides the catalogue lookup; falls back to `context.overrideContextWindow`. Minimum 1024.                                                                                                                                                                                                   |
| `models.<id>.maxOutputTokens`  | `integer`  | Maximum tokens per generation turn. Sent as `max_tokens` in the request body; falls back to `context.maxOutputTokens`. Minimum 1.                                                                                                                                                                                             |
| `models.<id>.reasoningOptions` | `string[]` | Reasoning efforts this model supports (same value set as `reasoningEffort`, including `max`). The TUI model picker filters its reasoning cycle to this list. Empty or absent means all efforts are available.                                                                                                                 |

**Example — custom provider with per-model limits:**

```json
{
  "defaultModel": "qwen-cloud/qwen3.7-plus",
  "providers": {
    "qwen-cloud": {
      "baseURL": "https://dashscope.aliyuncs.com/compatible-mode/v1",
      "models": {
        "qwen3.7-plus": {
          "contextWindow": 131072,
          "maxOutputTokens": 16384
        }
      }
    }
  }
}
```

**Provider merge order in `/connect`:** builtin catalogue → models.dev registry (overrides builtin picker entries with the same id; `openai` is explicitly skipped) → config providers (overrides everything with the same name, **except** entries already covered by the models.dev registry). All three sources share the same display surface.

> [!NOTE]
> **Custom provider session persistence**: Custom provider names (e.g., `"qwen-cloud"`) are preserved in `config.json` via the `defaultModel` field (e.g., `"qwen-cloud/qwen3.7-plus"`) and the `providers` map. On restart, Zay resolves the provider from `defaultModel`, hydrates `baseURL` from the `providers` map via `hydrateActiveModel`, and looks up the API key in `auth.json` using the provider name.
>
> **Dynamic providers (models.dev)** persist their identity through `defaultModel: "provider-id/model-id"` (e.g., `"stepfun-ai/step-3.7-flash"`). The `providers` map stores the `baseURL` and per-model metadata. Runtime-only fields (`dynamic_provider_id`, `dynamic_provider_name`) are never serialized; after restart, all rehydration paths fall back to the serialized `provider_name` from `defaultModel` and the `providers` map. `hydrateActiveModel` includes a recovery fallback for configs written before the `provider_name` serialization fix (where `provider_name` was the generic `"openai_compatible"` label).

**Example — provider with custom headers:**

```json
{
  "defaultModel": "my-gateway/qwen3.7-plus",
  "providers": {
    "my-gateway": {
      "baseURL": "https://gw.internal.example.com/v1",
      "headers": {
        "x-gateway-tenant": "acme",
        "x-gateway-token": "{env:GATEWAY_TOKEN}"
      }
    }
  }
}
```

Header values keep their `{env:VAR}` placeholders on disk (a settings save never writes a resolved secret back); expansion happens once per client attach, with the same mechanics and secrets invariant as MCP server values — see the [MCP Integration Guide](../mcp/README.md#environment-variable-expansion-envvar). An unset variable expands to an empty string (with a warning), and a header whose expanded value is empty is skipped rather than sent empty-valued.

**Auto-attached provider headers.** Some providers require routing/identity headers that Zay attaches automatically — no configuration needed:

- **OpenCode Zen** (any base URL under `opencode.ai/zen`, e.g. the builtin `opencode_zen` provider and the models.dev `opencode` / `opencode-go` entries): `x-opencode-session` (the stable per-conversation session id — improves token-cache locality and is required by the provider since 2026-09-05) and `x-opencode-client: zay`, on every outbound request including the model picker's `/v1/models` probe. These are routing identity, not cache hints: `context.disablePromptCache` does **not** suppress them.
- **OpenRouter**: the `X-Title: Zay` app-attribution header.

A user-configured header with the same (case-insensitive) name replaces the auto-attached value — e.g. pinning `x-opencode-session` to a fixed value, or overriding `x-opencode-client` for a gateway front. The merge policy lives in one place (`src/ai/provider_headers.zig`); see [Patterns — Outbound provider headers pattern](../patterns/README.md) for the full data flow.

### MCP Server Configuration

Each entry in `mcpServers` is keyed by server name:

| Field     | Type       | Description                                                                                                        |
| --------- | ---------- | ------------------------------------------------------------------------------------------------------------------ |
| `command` | `string`   | Executable for stdio transport.                                                                                    |
| `args`    | `string[]` | Command arguments for stdio transport.                                                                             |
| `url`     | `string`   | Endpoint URL for remote Streamable HTTP transport.                                                                 |
| `headers` | `object`   | Extra HTTP headers for remote servers (string values), e.g. API keys for header-auth servers like Context7.        |
| `type`    | `string`   | Optional transport discriminator (`"stdio"`/`"remote"`) for compatibility with other MCP clients; Zay ignores it. |
| `enabled` | `boolean`  | Whether this server is active (default `true`).                                                                    |
| `requestTimeoutMs` | `integer` | Per-server request timeout in milliseconds (default `30000`). Applied to the stdio read poll and the remote HTTP socket timeouts; values below 1 are clamped to 1 at use. |

A server is either stdio (`command` + `args`) or remote (`url`), never both. Misconfigured entries are caught at parse time.

`command`, `args`, `url`, and `headers` values support `{env:VAR}` placeholders, expanded against the process environment at connect time. Because an unset variable expands to an empty string (with a warning), this is how you keep API keys and tokens out of `config.json`. The expansion mechanics and the secrets invariant are the authoritative subject of the [MCP Integration Guide](../mcp/README.md#environment-variable-expansion-envvar).

> [!NOTE]
> **Adding servers from the TUI**: the `/mcp` overlay's `a` (add) key connects a remote server by URL immediately and persists only that new entry to the global `config.json` on a best-effort basis. A successful write survives restart; a failed write leaves the server live for the current session and logs `mcp.add.persist.failed`. Toggling the server off only changes the current process — delete its entry from `config.json` to remove it permanently. See [MCP Integration](../mcp/README.md) for details.

> [!IMPORTANT]
> **API Keys Security Invariant**: API keys (`api_key`) are **NEVER** serialized into `config.json`. API keys are stored separately in `~/.config/zay/auth.json` with strict file permissions (`0o600`).

### Plugin Configuration

Each entry in `plugins` is keyed by plugin name (matching the plugin's manifest `name` field):

| Field      | Type                | Description                                                                                              |
| ---------- | ------------------- | -------------------------------------------------------------------------------------------------------- |
| `enabled`  | `boolean`           | Whether this plugin is loaded (default `true`). Applied at App start — restart Zay to change it.        |
| `settings` | `string` or `object`| Plugin-specific settings as a JSON object — either an escaped JSON string or an inline JSON object (normalized to its canonical compact JSON string at parse). Serialized settings are capped at **65 536 bytes**; oversized settings are dropped with a `config_parse_error` diagnostic and the plugin loads unconfigured. The plugin's Lua code reads it via `plugin.get_config()`. |

**Example — inline-object form (preferred for readability):**

```json
{
  "plugins": {
    "my-search": {
      "enabled": true,
      "settings": { "max_results": 20, "case_sensitive": true, "default_pattern": "*.zig" }
    }
  }
}
```

**Example — escaped-string form (equivalent):**

```json
{
  "plugins": {
    "my-search": {
      "enabled": true,
      "settings": "{\"max_results\":20,\"case_sensitive\":true,\"default_pattern\":\"*.zig\"}"
    }
  }
}
```

Both forms reach the plugin identically. Settings are opaque to the config
system — the plugin's Lua code is responsible for validating its own settings
via `plugin.get_config()`, which returns a fresh table per call (or `nil`
when unconfigured). `enabled: false` skips loading the plugin entirely.
Plugin config is read once at App start; there is no hot reload — restart
Zay to apply changes. See `docs/plugins/` for the full plugin development guide.
