## Backward Compatibility (Schema v1 → v2)

Configs written by older Zay versions (schema v1, snake_case keys, integer version) are fully readable:

| v1 key                     | v2 key                   | Status                                                                                                                     |
| -------------------------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| `"version": 1`             | `"version": "1.0.0"`     | Integer normalized to semver at parse (`1` → `"1.0.0"`); it is **not** auto-bumped to `"2.0.0"` on save                    |
| `"model"`                  | `"defaultModel"`         | Both accepted; v2 written on save                                                                                          |
| `"provider"`               | _(removed)_              | Was write-only and redundant with `defaultModel`; no longer serialized. Still accepted at parse time if present (ignored). |
| `"base_url"`               | `"baseURL"`              | Both accepted; v2 written on save                                                                                          |
| `"use_responses_endpoint"` | `"useResponsesEndpoint"` | Both accepted; v2 written on save                                                                                          |
| `"enable_thinking"`        | _(removed)_              | Accepted but ignored (reasoning is per-model `reasoningEffort`); dropped on next save                                       |
| `"strict_outputs"`         | `"strictOutputs"`        | Both accepted; v2 written on save                                                                                          |
| `"system_prompt"`          | `"systemPrompt"`         | Both accepted; v2 written on save                                                                                          |
| `"bash_classifier_url"`    | `"bashClassifierUrl"`    | Both accepted; v2 written on save                                                                                          |
| `"disable_prompt_cache"`   | `"disablePromptCache"`   | Both accepted; v2 written on save                                                                                          |
| `"soft_stop_on_tool_call_limit"` | `"softStopOnToolCallLimit"` | Both accepted; v2 written on save                                                                                  |
| `"mcp_servers"` / `"mcp"`  | `"mcpServers"`           | All three accepted; v2 written on save                                                                                     |

When both camelCase and snake_case keys are present, **camelCase wins**.

> **Schema validity vs parse acceptance:** Zay parses these v1 snake_case keys for backward compatibility (the table above), but they are **not schema-valid** against [`schema/config.schema.json`](file-format-and-schema.md) (`additionalProperties: false`). A strict schema validator rejects them; Zay's own parser accepts them and rewrites them as camelCase on the next save. Write new configs in camelCase.

---

## Environment Variables

| Variable                      | Description                           | Example                                  |
| ----------------------------- | ------------------------------------- | ---------------------------------------- |
| `OPENAI_MODEL`                | Sets provider and model selection     | `openrouter/anthropic/claude-3.7-sonnet` |
| `OPENAI_BASE_URL`             | Overrides active provider base URL    | `https://openrouter.ai/api`              |
| `OPENAI_API_KEY`              | Sets runtime API key                  | `sk-or-v1-...`                           |
| `ZAY_USE_RESPONSES_ENDPOINT` | Sets Responses endpoint routing       | `true` or `1`                            |
| `ZAY_STRICT_OUTPUTS`         | Sets OpenAI strict structured-outputs mode (gateway-incompatible) | `true` or `1`                            |
| `ZAY_BASH_CLASSIFIER_URL`    | Sets external safety classifier URL   | `http://localhost:8765/classify`         |
| `ZAY_DATABASE_SERVER_URL`    | Sets external database service URL    | `http://localhost:8766`                  |
| `ZAY_DATABASE_AUTH_TOKEN`    | Sets external database auth token     | `secret-key`                             |
| `ZAY_DATABASE_BACKEND`    | Selects the session-database backend (see [Supported Backends](#external-database--roaming-session-configuration)); invalid values fail env loading | `turso_http` |
| `ZAY_DATABASE_URL`        | Sets the backend endpoint URL (equivalent to `database.url`) | `libsql://my-db.turso.io` |
| `ZAY_DATABASE_PATH`       | Overrides the local SQLite file path (equivalent to `database.path`) | `/srv/zay/sessions.sqlite` |
| `ZAY_HOST_ID`             | Pins the roaming `host_id` instead of deriving it from `COMPUTERNAME` / `HOSTNAME` | `laptop-01` |
| `ZAY_LOG_FILE`               | Path to the log file (path max 1024 bytes); defaults to `~/.config/zay/zay.log` | `/tmp/zay.log` |
| `ZAY_LOG_STDERR_LEVEL`       | Min level for the stderr sink (`err`\|`warn`\|`info`\|`debug`, case-insensitive). Default `warn` in release, `err` in debug. When the TUI is up, setting this **also** restores `warn`+ output to stderr (otherwise it goes to the toast). | `debug` |
| `ZAY_LOG_MAX_BYTES`          | Max log file size before rotation (default 10 MB). On launch, if the existing log exceeds this, `zay.log` is renamed to `zay.log.1` and a fresh file starts. | `5242880` |

---

## Persistence & Atomic Writes

1. **Atomic File Writes**: Config updates are written to a temporary file (`config.json.tmp`) before atomic renaming (`rename`), preventing corrupt configurations if process termination occurs mid-write.
2. **Directory Auto-Creation**: Parent directories (`~/.config/zay` or `.zay`) are created automatically if missing.

---

## Managing Configuration in TUI

You can view and edit settings directly inside Zay TUI:

- Press **Ctrl+S** or run `/settings` to open the settings interface.
- Navigate tabs using `Left`/`Right` arrows.
- Save changes using **Ctrl+S** to persist to `~/.config/zay/config.json`.
