# Nova Agent Configuration Architecture & Guide

Nova Agent employs a layered, type-safe, XDG-compliant configuration system written in Zig 0.16. Configuration is stored as human-readable JSON files and supports field-level merging across four priority layers.

---

## Configuration Layer Hierarchy

Configuration values are resolved by merging four layers in order of increasing specificity (later layers override earlier layers):

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Built-in Defaults                                        │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Global Configuration                                     │
│    • ~/.config/nova/config.json  (XDG Standard)            │
│    • ~/.nova/config.json         (Legacy Fallback)          │
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
└──────────────────────────────┴──────────────────────────────┘
```

1. **Built-in Defaults**: Fallback defaults compiled into the binary.
2. **Global Config**: User-wide preferences.
   - Primary (XDG Standard): `~/.config/nova/config.json` (or `$XDG_CONFIG_HOME/nova/config.json`).
   - Legacy Fallback: `~/.nova/config.json` (automatically read if XDG path does not exist).
3. **Project Config**: `<cwd>/.nova/config.json` for repository-specific overrides (e.g. project system prompt or local Ollama endpoints).
4. **Environment Variables**: Runtime overrides (e.g. `OPENAI_MODEL`, `OPENAI_API_KEY`, `NOVA_ENABLE_THINKING`).

---

## File Format & JSON Schema

All `config.json` files use formatted, 2-space indented JSON with version tagging.

### JSON Schema (`version: 1`)

```json
{
  "version": 1,
  "provider": "ollama",
  "model": "ollama/llama3.1:8b",
  "base_url": "http://localhost:11434",
  "use_responses_endpoint": false,
  "enable_thinking": true,
  "system_prompt": "Custom system prompt for this project...",
  "bash_classifier_url": "http://localhost:8000/classify",
  "providers": {
    "openai": {
      "base_url": "https://api.openai.com/v1",
      "models": {
        "gpt-4o": {
          "reasoningEffort": "high"
        }
      }
    },
    "ollama": {
      "base_url": "http://localhost:11434",
      "models": {
        "llama3.1:8b": {}
      }
    }
  }
}
```

### Supported Fields

| Field | Type | Description |
|---|---|---|
| `version` | `number` | Schema version (currently `1`). |
| `provider` | `string` | Active provider identifier (e.g., `openai`, `ollama`, `openrouter`, `anthropic`, `ollama_cloud`). |
| `model` | `string` | Model selection in `<provider>/<model-id>` format (e.g., `openrouter/anthropic/claude-3.7-sonnet`). |
| `base_url` | `string` | Custom REST / API endpoint base URL. Must start with `http://` or `https://`. |
| `use_responses_endpoint` | `boolean` | `true` to route via OpenAI Responses API instead of ChatCompletions. |
| `enable_thinking` | `boolean` | `true` to enable extended reasoning (`reasoning_effort`) for supported models. |
| `system_prompt` | `string` | Base system prompt template (supports `${CWD}` and `${OS}` tokens). |
| `bash_classifier_url` | `string` | ModernBERT classifier endpoint for shell command safety check. |
| `mcpServers` / `mcp_servers` / `mcp` | `object` | MCP server configurations (Claude Desktop format compatible). Each server has a `transport: union(enum) { stdio, sse }` — stdio requires `command`+`args`, sse requires `url`. |
| `providers` | `object` | Provider-specific configurations and reasoning effort overrides. `ProviderModel` is a type alias for `Model` — both carry `id` and `reasoning_effort`. |

> [!IMPORTANT]
> **API Keys Security Invariant**: API keys (`api_key`) are **NEVER** serialized into `config.json`. API keys are stored separately in `~/.config/nova/auth.json` (or `~/.nova/auth.json`) with strict file permissions (`0o600`).

> [!NOTE]
> **Typed Model Selection**: The in-memory `Config` struct carries a `model_selection: ?ModelSelection` typed view. `ModelSelection` packages the non-optional `provider`/`model`/`base_url`/`api_key` plus optional settings (`use_responses_endpoint`/`enable_thinking`/`system_prompt`/`bash_classifier_url`). When all required fields are present, `parseObject` populates `model_selection` and clears the legacy optional fields. Callers read through `model_selection`; the legacy fields stay only for disk round-trip via `serialize`/`applyConfigOverlay`.

---

## Environment Variables

| Variable | Description | Example |
|---|---|---|
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
