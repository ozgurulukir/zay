# Nova Agent Configuration Architecture & Guide

Nova Agent employs a layered, type-safe, XDG-compliant configuration system written in Zig 0.16. Configuration is stored as human-readable JSON files and supports field-level merging across four priority layers.

---

## Configuration Layer Hierarchy

Configuration values are resolved by merging four layers in order of increasing specificity (later layers override earlier layers):

```text
┌─────────────────────────────────────────────────────────────┐
│ 1. Built-in Defaults                                        │
└──────────────────────────────┬──────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Global Configuration                                     │
│    • ~/.config/nova/config.json  (XDG Standard)            │
└──────────────────────────────┬──────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Project-Local Configuration                              │
│    • <cwd>/.nova/config.json                                │
└──────────────────────────────┬──────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Environment Variables                                    │
│    • OPENAI_MODEL, OPENAI_BASE_URL, OPENAI_API_KEY, etc.    │
└─────────────────────────────────────────────────────────────┘
```

1. **Built-in Defaults**: Fallback defaults compiled into the binary.
2. **Global Config**: User-wide preferences at `~/.config/nova/config.json` (or `$XDG_CONFIG_HOME/nova/config.json`).
3. **Project Config**: `<cwd>/.nova/config.json` for repository-specific overrides (e.g. project system prompt or local Ollama endpoints).
4. **Environment Variables**: Runtime overrides (e.g. `OPENAI_MODEL`, `OPENAI_API_KEY`, `NOVA_ENABLE_THINKING`).

---

## File Format & JSON Schema

All `config.json` files use formatted, 2-space indented JSON with semver version tagging. A machine-readable JSON Schema (Draft 2020-12) for editor autocompletion lives at [`schema/config.schema.json`](../schema/config.schema.json).

### Schema v2 (current)

JSON keys are **camelCase**. Legacy snake_case keys from schema v1 are still accepted at parse time for backward compatibility; `serialize` always writes camelCase.

```json
{
  "version": "2.0.0",
  "defaultModel": "ollama/llama3.1:8b",
  "baseURL": "http://localhost:11434",
  "useResponsesEndpoint": false,
  "enableThinking": true,
  "systemPrompt": "Custom system prompt for this project...",
  "bashClassifierUrl": "http://localhost:8000/classify",
  "context": {
    "overrideContextWindow": 32000,
    "maxOutputTokens": 4096,
    "compaction": {
      "auto": true,
      "threshold": 0.75,
      "bufferTokens": 20000,
      "keepRecentTokens": 8000
    }
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

| Field | Type | Description |
| --- | --- | --- |
| `version` | `string` | Semver schema version (currently `"2.0.0"`). Legacy integer `1` is normalized to `"1.0.0"` at parse time. |
| `defaultModel` | `string` | Model selection in `<provider>/<model-id>` format (e.g., `"openai/gpt-5.5"`, `"ollama/llama3.1:8b"`, `"qwen-cloud/qwen3.7-plus"`). The provider part is split on the first `/`; model ids may contain further slashes (e.g., `"huggingface/meta-llama/Llama-3.1-8B"`). Custom provider names are supported. This is the **single source of truth** for provider identity — there is no separate `provider` field. Legacy key `model` is also accepted. |
| `baseURL` | `string` | Custom API endpoint base URL. Must start with `http://` or `https://`. In memory, this may be `""` when synthesized from session metadata or legacy fields; it is resolved through the provider's default before any network request. Legacy key `base_url` is also accepted. |
| `useResponsesEndpoint` | `boolean` | `true` to route via OpenAI Responses API instead of ChatCompletions. Legacy key `use_responses_endpoint` is also accepted. |
| `enableThinking` | `boolean` | `true` to enable extended reasoning for supported models. Legacy key `enable_thinking` is also accepted. |
| `systemPrompt` | `string` | Base system prompt template (max 10 000 chars). Legacy key `system_prompt` is also accepted. |
| `bashClassifierUrl` | `string` | ModernBERT classifier endpoint for shell command safety check. Legacy key `bash_classifier_url` is also accepted. |
| `context` | `object` | Context window management and compaction policy (see below). |
| `mcpServers` | `object` | MCP server configurations (Claude Desktop format compatible). Legacy keys `mcp_servers` and `mcp` are also accepted. |
| `providers` | `object` | Per-provider configuration keyed by provider name. Accepts builtin labels and custom provider names (see below). |

### Context & Compaction Settings

The `context` object controls context window management and automatic summarization:

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `context.overrideContextWindow` | `integer` | _(auto)_ | Explicit context window in tokens. Overrides the model catalogue lookup — useful for local Ollama/LMStudio models with non-standard windows. Minimum 1024. |
| `context.maxOutputTokens` | `integer` | _(auto)_ | Maximum tokens per single model generation turn. |
| `context.compaction.auto` | `boolean` | `true` | Enable automatic context compaction before reaching limits. |
| `context.compaction.threshold` | `number` | `0.75` | Fraction of context window (0.1–1.0) that triggers background summarization. The swap watermark is derived as `threshold + 0.20` (capped at 0.95). |
| `context.compaction.bufferTokens` | `integer` | `20000` | Reserve token buffer for compaction preflight checks. |
| `context.compaction.keepRecentTokens` | `integer` | `8000` | Recent conversation tokens retained verbatim alongside the generated summary. Scaled down proportionally for small-context models (35% of window, min 1000). |

**Example — local Ollama with aggressive compaction:**

```json
{
  "context": {
    "overrideContextWindow": 8192,
    "compaction": {
      "threshold": 0.60,
      "keepRecentTokens": 3000
    }
  }
}
```

### Provider Configuration

Each entry in `providers` is keyed by provider name. Builtin labels (`openai`, `ollama`, `openrouter`, `cerebras`, `huggingface`, `nvidia_nim`, `opencode_zen`, `ollama_cloud`, `llama.cpp`, `anthropic`) are recognized and mapped to their typed enum. Any other key is treated as a **custom provider** using the OpenAI-compatible adapter — it appears in the `/connect` picker alongside builtins and models.dev providers.

| Field | Type | Description |
| --- | --- | --- |
| `baseURL` | `string` | Custom base URL for this provider. Legacy key `base_url` is also accepted. |
| `models` | `object` | Per-model overrides keyed by model id. |
| `models.<id>.reasoningEffort` | `string` | One of `default`, `minimal`, `low`, `none`, `medium`, `high`, `xhigh`. `default` sends no reasoning parameter (model decides); `none` disables thinking explicitly. Internally stored as a `ReasoningSetting` union: when unset in a config layer, the lower layer's value is preserved during merge; when set, it overrides. |
| `models.<id>.contextWindow` | `integer` | Context window size in tokens. Overrides the catalogue lookup; falls back to `context.overrideContextWindow`. Minimum 1024. |
| `models.<id>.maxOutputTokens` | `integer` | Maximum tokens per generation turn. Sent as `max_tokens` in the request body; falls back to `context.maxOutputTokens`. Minimum 1. |
| `models.<id>.reasoningOptions` | `string[]` | Reasoning efforts this model supports (e.g. `["default", "low", "medium", "high", "xhigh"]`). The TUI model picker filters its reasoning cycle to this list. Empty or absent means all efforts are available. |

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

**Provider merge order in `/connect`:** builtin catalogue → models.dev registry (overrides builtins with same id) → config providers (overrides everything with same name, **except** entries already covered by the models.dev registry). All three sources share the same display surface.

> [!NOTE]
> **Custom provider session persistence**: Custom provider names (e.g., `"qwen-cloud"`) are preserved in `config.json` via the `defaultModel` field (e.g., `"qwen-cloud/qwen3.7-plus"`) and the `providers` map. On restart, Nova resolves the provider from `defaultModel`, hydrates `baseURL` from the `providers` map via `hydrateActiveModel`, and looks up the API key in `auth.json` using the provider name.
>
> **Dynamic providers (models.dev)** persist their identity through `defaultModel: "provider-id/model-id"` (e.g., `"stepfun-ai/step-3.7-flash"`). The `providers` map stores the `baseURL` and per-model metadata. Runtime-only fields (`dynamic_provider_id`, `dynamic_provider_name`) are never serialized; after restart, all rehydration paths fall back to the serialized `provider_name` from `defaultModel` and the `providers` map. `hydrateActiveModel` includes a recovery fallback for configs written before the `provider_name` serialization fix (where `provider_name` was the generic `"openai_compatible"` label).

### MCP Server Configuration

Each entry in `mcpServers` is keyed by server name:

| Field | Type | Description |
| --- | --- | --- |
| `command` | `string` | Executable for stdio transport. |
| `args` | `string[]` | Command arguments for stdio transport. |
| `url` | `string` | Endpoint URL for remote Streamable HTTP transport. |
| `enabled` | `boolean` | Whether this server is active (default `true`). |

A server is either stdio (`command` + `args`) or remote (`url`), never both. Misconfigured entries are caught at parse time.

`command`, `args`, and `url` support `{env:VAR}` placeholders, expanded against the process environment at parse time — keep secrets out of `config.json` (an unset variable expands to an empty string and logs a warning):

```json
"tavily": {
  "url": "https://mcp.tavily.com/mcp/?tavilyApiKey={env:TAVILY_API_KEY}"
}
```

> [!NOTE]
> **Adding servers from the TUI**: the `/mcp` overlay's `a` (add) key connects a remote server by URL for the current session only. Such servers are **runtime-only** — they are not written to `config.json` and do not survive a restart. Add them here by hand to make them permanent. See [MCP Integration](MCP.md) for details.

> [!IMPORTANT]
> **API Keys Security Invariant**: API keys (`api_key`) are **NEVER** serialized into `config.json`. API keys are stored separately in `~/.config/nova/auth.json` with strict file permissions (`0o600`).

> [!NOTE]
> **Typed Model Selection**: The in-memory `Config` struct carries a `model_selection: ?ModelSelection` typed view. `ModelSelection` packages the non-optional `provider`/`model`/`base_url`/`api_key` plus optional settings. `parseObject` only populates `model_selection` when all four fields are non-null — since `api_key` is never serialized to config.json (it lives in `auth.json`), disk-loaded configs **never** have `model_selection`. All rehydration paths fall back to the legacy fields (`provider`, `model`, `base_url`, `provider_name`), which ARE populated from `defaultModel` and `hydrateActiveModel`.

---

## Backward Compatibility (Schema v1 → v2)

Configs written by older Nova versions (schema v1, snake_case keys, integer version) are fully readable:

| v1 key | v2 key | Status |
| --- | --- | --- |
| `"version": 1` | `"version": "2.0.0"` | Integer normalized to semver at parse |
| `"model"` | `"defaultModel"` | Both accepted; v2 written on save |
| `"provider"` | _(removed)_ | Was write-only and redundant with `defaultModel`; no longer serialized. Still accepted at parse time if present (ignored). |
| `"base_url"` | `"baseURL"` | Both accepted; v2 written on save |
| `"use_responses_endpoint"` | `"useResponsesEndpoint"` | Both accepted; v2 written on save |
| `"enable_thinking"` | `"enableThinking"` | Both accepted; v2 written on save |
| `"system_prompt"` | `"systemPrompt"` | Both accepted; v2 written on save |
| `"bash_classifier_url"` | `"bashClassifierUrl"` | Both accepted; v2 written on save |
| `"mcp_servers"` / `"mcp"` | `"mcpServers"` | All three accepted; v2 written on save |

When both camelCase and snake_case keys are present, **camelCase wins**.

---

## Environment Variables

| Variable | Description | Example |
| --- | --- | --- |
| `OPENAI_MODEL` | Sets provider and model selection | `openrouter/anthropic/claude-3.7-sonnet` |
| `OPENAI_BASE_URL` | Overrides active provider base URL | `https://openrouter.ai/api` |
| `OPENAI_API_KEY` | Sets runtime API key | `sk-or-v1-...` |
| `NOVA_USE_RESPONSES_ENDPOINT` | Sets Responses endpoint routing | `true` or `1` |
| `NOVA_ENABLE_THINKING` | Sets extended reasoning mode | `true` or `1` |
| `NOVA_BASH_CLASSIFIER_URL` | Sets ModernBERT safety classifier URL | `http://localhost:8000` |
| `XDG_CONFIG_HOME` | Custom XDG configuration root | `/home/user/.config` |

---

## Persistence & Atomic Writes

1. **Atomic File Writes**: Config updates are written to a temporary file (`config.json.tmp`) before atomic renaming (`rename`), preventing corrupt configurations if process termination occurs mid-write.
2. **Directory Auto-Creation**: Parent directories (`~/.config/nova` or `.nova`) are created automatically if missing.

---

## Managing Configuration in TUI

You can view and edit settings directly inside Nova TUI:

- Press **Ctrl+S** or run `/settings` to open the settings interface.
- Navigate tabs using `Left`/`Right` arrows.
- Save changes using **Ctrl+S** to persist to `~/.config/nova/config.json`.
