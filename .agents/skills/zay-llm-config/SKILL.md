---
name: zay-llm-config
description: Use when setting up, switching, or troubleshooting Zay LLM providers, models, API keys, or custom OpenAI-compatible endpoints (Ollama, LM Studio, OpenRouter, vLLM, /connect, config.json, auth.json, reasoningEffort, env overrides).
---

# Configure Zay for LLM Providers

Zay talks to OpenAI-compatible endpoints (Chat Completions and Responses API) plus built-in OpenAI / Codex OAuth. Authoritative schema and field tables live in `schema/config.schema.json`, `docs/config/README.md`, `docs/config/file-format-and-schema.md`, `docs/config/providers-mcp-and-plugins.md`, `docs/config/compatibility-environment-and-persistence.md`, and `docs/patterns/configuration-sessions-and-persistence.md`.

## 1. Config layers and paths

Values merge in order of increasing precedence:

1. **Built-in defaults**
2. **Global config** — compile-time selected (`src/paths.zig::platformConfigDir`):
   - POSIX: `~/.config/zay/config.json` (`$XDG_CONFIG_HOME` is **not** honored)
   - Windows: `%APPDATA%\zay\config.json`
3. **Project config** — `<project>/.zay/config.json`
4. **Environment variables** — runtime overrides

Use **camelCase** keys; legacy v1 snake_case keys are accepted at parse time, rejected by `schema/config.schema.json` (`additionalProperties: false`), and rewritten as camelCase on save. Config files are written atomically (`0600` on POSIX) and capped at 32 KB. API keys stay in `auth.json` (never serialized into `config.json`).

## 2. Model selection (`defaultModel`)

`defaultModel` is the single source of truth as `"<provider>/<model-id>"`, split on the first `/` (model IDs may contain slashes):

```json
{
  "defaultModel": "openrouter/anthropic/claude-3.7-sonnet"
}
```

Use top-level `baseURL` for an active override, or `providers.<name>.baseURL` when binding an endpoint to a named provider across model switches.

## 3. Providers and per-model settings

`providers` accepts built-in provider IDs (18 compiled-in entries in `src/config/provider.zig`) and custom provider names (surfaced in `/connect` via the OpenAI-compatible adapter):

- `providers.<name>.baseURL` — endpoint base URL.
- `providers.<name>.headers` — up to 8 extra outbound headers supporting `{env:VAR}` placeholders; reserved transport headers (`authorization`, `content-type`, `host`, etc.) are rejected.
- `providers.<name>.models.<id>.reasoningEffort` — `"default"`, `"minimal"`, `"low"`, `"none"`, `"medium"`, `"high"`, `"xhigh"`, `"max"` (OpenRouter top level; Qwen/DashScope clips to valid values; `.minimal` dialect clips `xhigh`→`max`, `minimal`→`low`).
- `providers.<name>.models.<id>.reasoningOptions` — restricts the `/model` picker cycle.
- `providers.<name>.models.<id>.contextWindow` — overrides catalogue lookup (essential for local Ollama/LM Studio models).
- `providers.<name>.models.<id>.maxOutputTokens` — caps `max_tokens` per turn (falls back to `context.maxOutputTokens`).
- `providers.<name>.responsePolicy` — maps proxy fields (`reasoning`, `reasoning_content`, `reasoning_details`, `thinking`) to `text`, `reasoning`, or `ignore`.

Global / `context` switches relevant to gateways:

- `useResponsesEndpoint: true` — route via Responses API instead of Chat Completions.
- `strictOutputs: true` — OpenAI-only strict tool schemas; keep `false` for OpenRouter, Ollama, vLLM, and other gateways.
- `context.disablePromptCache: true` — suppresses cache fields (`cache_control`, `session_id`, `prompt_cache_key`) when a gateway rejects them with HTTP 400.
- `context.autoContinueOnLengthCut: true` — retries once when a response ends at `finish_reason=length` with no tool calls.

For session database backends (`local_sqlite`, `turso_http`, `d1_http`, `zay_service`), see `docs/config/database-and-roaming.md`.

## 4. Credentials (`auth.json`)

Credentials live in `<platformConfigDir>/auth.json` (and the OS keychain on supported platforms via `src/auth/store.zig`), keyed by provider ID under `apiKeys`:

```json
{
  "apiKeys": {
    "openrouter": "sk-or-v1-..."
  }
}
```

The `apiKeys` key must match the provider prefix in `defaultModel`. Set keys via `/connect`, `OPENAI_API_KEY` (runtime override), or `auth.json` (leave `openaiCodex` OAuth entries untouched).

## 5. Environment variables and TUI commands

Key overrides (full list in `docs/config/compatibility-environment-and-persistence.md`):

- `OPENAI_MODEL`, `OPENAI_BASE_URL`, `OPENAI_API_KEY`
- `ZAY_USE_RESPONSES_ENDPOINT`, `ZAY_STRICT_OUTPUTS`, `ZAY_BASH_CLASSIFIER_URL`
- `ZAY_LOG_FILE`, `ZAY_LOG_MAX_BYTES`, `ZAY_LOG_STDERR_LEVEL` (`debug` surfaces provider/loading logs)

TUI commands:

- `/connect` — select built-in, models.dev, or custom provider and enter cloud API keys (local providers probe `/v1/models`).
- `/model` — switch active model and reasoning effort; press **Ctrl+S** inside `/model` to cycle save scope (global / project / session).
- `/settings` (**Ctrl+S** to open and save) — persists global settings fields (`useResponsesEndpoint`, `systemPrompt`, `bashClassifierUrl`, `toast.enabled`), never `defaultModel`.

## 6. Common setups

- **OpenAI / Codex OAuth:** `{ "defaultModel": "openai/gpt-5.5" }` and log in via `/connect` → Codex (no API key).
- **OpenRouter:** `defaultModel: "openrouter/<org/model>"`, `providers.openrouter.baseURL: "https://openrouter.ai/api/v1"`, key in `apiKeys.openrouter`.
- **Ollama (local):** `defaultModel: "ollama/llama3.1:8b"`, `providers.ollama.baseURL: "http://localhost:11434"`, plus `models.<id>.contextWindow` if missing from catalogue.
- **LM Studio / vLLM / custom gateway:** define `providers.<custom>.baseURL: "http://localhost:1234/v1"` and set `defaultModel: "<custom>/<model>"`.

## 7. models.dev catalogue and troubleshooting

Zay embeds and caches `models.dev/api.json` (`registry_payload_max_bytes = 16 MiB` shared across network fetch, cache, and `<prefix>/share/zay/api.json`). Custom `providers.<name>` entries are the escape hatch for unlisted models/endpoints.

- **401 / missing key:** match `apiKeys.<provider>` to the `defaultModel` prefix, or test with `OPENAI_API_KEY`.
- **400 on reasoning/cache fields:** set `reasoningEffort: "none"` or `context.disablePromptCache: true`.
- **Missing tool calls on gateways:** keep `strictOutputs: false`.
- **Stale config:** restart Zay or re-run `/connect` / `/model`, and inspect `ZAY_LOG_STDERR_LEVEL=debug`.

## Quick checklist

1. Choose `<provider>/<model-id>` and set `defaultModel`.
2. Add `providers.<provider>.baseURL` for custom or non-default endpoints.
3. Add `auth.json` `apiKeys.<provider>` (via `/connect`) for authenticated endpoints.
4. Set `models.<id>.contextWindow` for local/unlisted models, and `reasoningEffort: "none"` / `disablePromptCache: true` if a gateway rejects them.
5. Restart Zay or probe via `/connect` / `/model`.
