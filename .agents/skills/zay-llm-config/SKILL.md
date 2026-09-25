---
name: zay-llm-config
description: 'Configure Zay to talk to LLM providers. Use when the user asks how to set up/switch/connect a model or provider, needs to add an API key, point Zay at a custom OpenAI-compatible endpoint (Ollama, LM Studio, OpenRouter, vLLM, local gateways), set the default model/base URL, or understand config.json, auth.json, models.dev, or the relevant environment variables.'
---

# Configure Zay for LLM Providers

Zay is a terminal coding agent that talks to an OpenAI-compatible model through a
provider adapter. This skill teaches the full provider/model configuration model:
where settings live, the four config layers, how API keys are stored, the TUI
commands, and the common local/cloud setups.

Zay speaks the **OpenAI wire protocol** (chat-completions and Responses-API). Any
provider that implements an OpenAI-compatible endpoint works: OpenRouter, Ollama,
LM Studio, vLLM, Together, DeepSeek, Mistral, Cerebras, Gemini gateways, custom
`/v1`-style servers, etc. Builtin native support exists for OpenAI / Codex OAuth
(chat login, no API key).

**Reference docs:** `docs/CONFIG.md` (configuration architecture and provider
section), `docs/MCP.md` (model context protocol servers), `schema/config.schema.json`
(authoritative field documentation). `[[CONFIG]]` in repo docs links the wiki
version. For command-safety or transport internals, see `docs/PATTERNS.md`.

---

## 1. The four configuration layers

Values resolve by merging in order of increasing specificity (later overrides
earlier):

1. **Builtin defaults** (compiled in).
2. **Global config file** — location is **OS-dependent** (see below).
3. **Project config file** — `<project>/.zay/config.json`, merged over global.
4. **Environment variables** — override everything.

### Global config & auth dir are platform-selected (compile-time)

The global config tree roots at a single platform-aware directory computed from
the resolved `home_dir` (`src/paths.zig::platformConfigDir`), and both
`config.json` and `auth.json` live there:

| OS      | Platform config dir                                       | Global config file             |
| ------- | --------------------------------------------------------- | ------------------------------ |
| Windows | `<USERPROFILE>\AppData\Roaming\zay`  (== `%APPDATA%\zay`) | `%APPDATA%\zay\config.json`    |
| POSIX   | `<home>/.config/zay`                  (XDG base dir)      | `~/.config/zay/config.json`    |

Notes:
- The branch is selected at **compile time** via `os.is_windows` — the same
  binary does not remap at runtime; the path you see depends on the OS the
  process was built & run on.
- On POSIX the XDG base dir is **hardcoded to `~/.config/zay`**; `$XDG_CONFIG_HOME`
  is NOT honored (it is not consulted by `platformConfigDir`). If a distro/
  container overrides `XDG_CONFIG_HOME`, Zay still reads `~/.config/zay`.
- On Windows it does not use `ProgramData` or `LOCALAPPDATA` scope; it is the
  per-user roaming dir `AppData\Roaming\zay` under the logged-in user's home.

Keys are **camelCase**; legacy snake_case keys are accepted for backward
compatibility but are not schema-valid (`zig build --strict` / `zay --strict`
flags them). Config files are written atomically (temp + rename); editing in the
TUI and pressing **Ctrl+S** persists to the global config.

**Auth separation:** API keys are NEVER stored in config.json — they live in
`auth.json` (see §4). Rehydration of a disk-loaded config never carries a key.

---

## 2. Provider & model selection (`defaultModel`)

The **single source of truth** for provider + model is the `defaultModel` key, a
`"<provider>/<model-id>"` string. The provider part is split on the FIRST `/`;
model ids may themselves contain slashes (e.g. Hugging Face org/model ids).

```json
{
  "defaultModel": "openai/gpt-5.5",
  "defaultModel": "ollama/llama3.1:8b",
  "defaultModel": "qwen-cloud/qwen3.7-plus",
  "defaultModel": "huggingface/meta-llama/Llama-3.1-8B"
}
```

Both parts must be non-empty. The provider name is looked up in (in order):
user-defined `providers`, then builtin provider labels, then the models.dev
catalogue. `baseURL` (top-level, legacy) overrides the active provider's base
URL but is not schema-valid; new configs scope per-provider base URLs inside
`providers.<name>.baseURL`.

---

## 3. The `providers` block (per-provider config)

`providers` is keyed by provider name. Accepts builtin labels and **custom
provider names** (which appear in the `/connect` picker and use the
OpenAI-compatible adapter). Fields:

| Field | Meaning |
| ----- | ------- |
| `baseURL` | Custom base URL for this provider (legacy `base_url`). |
| `models.<id>` | Per-model settings keyed by model id (see below). |
| `headers` | Extra outbound HTTP headers (max 8). Support `{env:VAR}` placeholders; secrets stay in the environment. Reserved transport headers (authorization, content-type, host…) are rejected — credentials belong in `auth.json`. |

Per-model settings under `providers.<name>.models.<id>`:

```json
{
  "providers": {
    "openai": {
      "baseURL": "https://api.openai.com/v1",
      "models": {
        "gpt-4o": { "reasoningEffort": "high" }
      }
    },
    "ollama": {
      "baseURL": "http://localhost:11434",
      "models": { "llama3.1:8b": {} }
    }
  }
}
```

Common per-model keys:
- `reasoningEffort` — `"default"` (model decides) / `"none"` (no thinking) /
  `"low"`/`"medium"`/`"high"`/`"xhigh"` / `"max"` (OpenRouter-only top level;
  OpenAI-native ignores it; Qwen/DashScope clips to `"medium"`).
- `reasoningEfforts` — array this model supports; the TUI picker filters its
  cycle to this list.
- `contextWindow` — token context window; overrides catalogue lookup (needed
  for local Ollama/LM Studio models the catalogue misses).
- `maxOutputTokens` — caps `max_tokens` per turn; falls back to
  `context.maxOutputTokens`.
- `disablePromptCache` — strip prompt-caching fields (some `:free` /
  gateway-fronted models 400 on them).
- `autoContinueOnLengthCut` — continue once when a response ends at the output
  token cap without tool calls.

Reasoning-effort application is two composed layers (dialect-level clipping +
Qwen/QwQ model-level clipping) resolved at one named home; you don't need to care
unless you hit a provider that rejects the reasoning parameter — set
`reasoningEffort: "none"` or rely on the model-level clip.

---

## 4. API keys: `auth.json`

Credentials are stored per-provider in `auth.json` in the platform config dir
(`~/.config/zay/auth.json` on POSIX, `%APPDATA%\zay\auth.json` on Windows),
optionally backed by the OS keychain on supported platforms.

Shape used by Zay's own stores:

```json
{
  "apiKeys": {
    "openrouter": "sk-or-v1-...",
    "cerebras": "csk-...",
    "ollama": ""
  }
}
```

(`openaiCodex` OAuth tokens live in a separate `openaiCodex` section — do not
hand-edit those.)

**Key invocation:** the API key Zay sends is selected by provider name at attach
time. The defaultModel provider part must match the key's label.

Ways to set a key:
- The `/connect` picker prompts for an API key for cloud providers.
- `OPENAI_API_KEY` env var (runtime override, not persisted).
- Hand-edit `auth.json` (fine, but prefer the picker so the file stays valid).

---

## 5. Environment variables

| Variable | Effect |
| -------- | ------ |
| `OPENAI_MODEL` | Sets provider+model selection, e.g. `openrouter/anthropic/claude-3.7-sonnet`. |
| `OPENAI_BASE_URL` | Overrides the active provider base URL, e.g. `https://openrouter.ai/api`. |
| `OPENAI_API_KEY` | Runtime API key. |
| `ZAY_USE_RESPONSES_ENDPOINT` | Force Responses-endpoint routing (`true`/`1`). |
| `ZAY_STRICT_OUTPUTS` | OpenAI strict structured-outputs — gateway-incompatible (`true`/`1`). |
| `ZAY_BASH_CLASSIFIER_URL` | External safety classifier URL (optional). |
| `ZAY_LOG_FILE`, `ZAY_LOG_MAX_BYTES`, `ZAY_LOG_STDERR_LEVEL` | Logging knobs. |

Env vars override every file layer and are the quickest way to point Zay at a
provider for a one-off run:
`OPENAI_MODEL=openrouter/anthropic/claude-3.7-sonnet OPENAI_BASE_URL=https://openrouter.ai/api OPENAI_API_KEY=sk-or-... zay`.

---

## 6. TUI commands

From the command palette (`/`):

- **`/connect`** — provider picker. Shows builtin providers, custom (user-defined)
  providers, and models.dev catalogue models. Selecting a cloud provider prompts
  for an API key (stored via auth). Local providers (Ollama, LM Studio) need no
  key and probe `/v1/models` to list available models.
- **`/model`** — switch the active model for the session; the picker reflects
  `reasoningEfforts` constraints and shows the model's context window.
- **`/parallel`**, `/diff`, `/timeline`, `/undo`, `/help` — misc, not provider.

Editing config in the TUI and hitting **Ctrl+S** persists to the global config
file.

---

## 7. Common setups (playbook)

### a. OpenAI / Codex (native, no key)
```json
{ "defaultModel": "openai/gpt-5.5" }
```
Login via the Codex OAuth flow (`/connect` → Codex). API key not required.

### b. OpenRouter (aggregator)
```json
{
  "defaultModel": "openrouter/anthropic/claude-3.7-sonnet",
  "providers": {
    "openrouter": { "baseURL": "https://openrouter.ai/api/v1" }
  }
}
```
Key: `sk-or-v1-...` under `apiKeys.openrouter` (or `OPENAI_API_KEY`).

### c. Ollama (local)
```json
{
  "defaultModel": "ollama/llama3.1:8b",
  "providers": {
    "ollama": { "baseURL": "http://localhost:11434" }
  }
}
```
No key. Models list via the Ollama `/v1` OpenAI-compat endpoint. If the model's
context window is unknown to the catalogue, set it explicitly:
`"models": { "llama3.1:8b": { "contextWindow": 8192 } }`.

### d. LM Studio (local, OpenAI-compatible)
```json
{
  "defaultModel": "lmstudio/qwen2.5-7b",
  "providers": {
    "lmstudio": { "baseURL": "http://localhost:1234/v1" }
  }
}
```

### e. Custom endpoint / vLLM / gateway
```json
{
  "defaultModel": "my-endpoint/my-model",
  "providers": {
    "my-endpoint": { "baseURL": "https://my-gateway.example.com/v1" }
  }
}
```
Custom providers appear in `/connect` and use the OpenAI-compatible adapter. If
the gateway rejects reasoning fields, set `reasoningEffort: "none"` or disable
prompt caching with `disablePromptCache: true`.

### f. Qwen / DashScope
Model id prefix `qwen`/`qwq` triggers Qwen-specific handling (single leading
system message normalization, reasoning-effort clipping). Use e.g.
`qwen-cloud/qwen3.7-plus` with `providers.qwen-cloud.baseURL` pointing at the
DashScope OpenAI-compat endpoint.

---

## 8. models.dev catalogue

Zay embeds a models.dev registry (`models.dev.Registry`) used by the provider/
model pickers to autocomplete providers, base URLs (provider.PROVIDERS.ai), and
context windows. The picker's `/v1/models` probe refreshes live model lists for a
provider. If a model/provider isn't in the catalogue, define it manually in the
`providers` block (this is the intended escape hatch) and set `contextWindow` if
the catalogue doesn't know it.

The catalogue payload cap is one constant (`registry_payload_max_bytes`, 16 MiB)
shared by network fetch, disk cache, and vendored `share/zay/api.json`; a 4 MiB+
api.json is supported (not a per-site-literal issue). If `/connect` shows only
builtins, suspect a failed registry read (check logs) rather than a missing
model definition.

---

## 9. Debugging & gotchas

- **API key not sent / 401** — key label must match the provider part of
  `defaultModel`; check `auth.json` `apiKeys` for the right label, or use
  `OPENAI_API_KEY`.
- **Gateway 400 on reasoning/caching fields** — some `:free` /
  gateway-fronted models reject `reasoning_effort` or prompt-cache fields. Set
  `reasoningEffort: "none"` and/or `disablePromptCache: true` on that model.
- **Strict structured outputs breaks gateways** — `strictOutputs: true` only
  works against real OpenAI; OpenRouter/Ollama/vLLM/Together reject or silently
  break function calling. Disable it unless talking directly to OpenAI.
- **Local model context too small/large** — the catalogue estimate may be
  wrong; pin `contextWindow` per model so compaction/swap work correctly.
- **Responses-API mismatch** — some providers only speak chat-completions (or
  vice versa). `ZAY_USE_RESPONSES_ENDPOINT` toggles routing; a provider that
  rejects the endpoint should stay on chat-completions.
- **Scope of `/connect` changes** — the active model selection may be session
  scope; use `defaultModel` in config for a persistent default. Save edits with
  **Ctrl+S** to persist.
- **Verify what's loaded** — model/config caching: after editing config.json,
  a running instance may hold stale values; restart Zay to be sure. Logs are the
  first stop for "wrong provider" — see `ZAY_LOG_STDERR_LEVEL=debug`.

---

## 10. Quick checklist — "point Zay at a new LLM"

1. Pick provider name and model id → set `defaultModel` (`"<provider>/<model>"`).
2. Add `providers.<name>.baseURL` (unless it's a builtin with a default).
3. If cloud: set the API key via `/connect` (→ `auth.json` `apiKeys.<name>`).
4. If local / unknown context: set `models.<id>.contextWindow`.
5. If reasoning/caching 400s: set `reasoningEffort: "none"` / `disablePromptCache`.
6. Restart (or `/connect`/`/model`) and confirm via the picker probe.

