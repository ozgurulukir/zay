# Zay Agent Configuration Architecture & Guide

Zay Agent employs a layered, type-safe configuration system written in Zig 0.16. Configuration is stored as human-readable JSON files and supports field-level merging across four priority layers. (The global directory follows the XDG default location convention, but the `XDG_CONFIG_HOME` override is not honored — the root below is fixed.)

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
│    • ~/.config/zay/config.json  (XDG Standard)            │
└──────────────────────────────┬──────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Project-Local Configuration                              │
│    • <cwd>/.zay/config.json                                │
└──────────────────────────────┬──────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Environment Variables                                    │
│    • OPENAI_MODEL, OPENAI_BASE_URL, OPENAI_API_KEY, etc.    │
└─────────────────────────────────────────────────────────────┘
```

1. **Built-in Defaults**: Fallback defaults compiled into the binary.
2. **Global Config**: User-wide preferences at `~/.config/zay/config.json`.
3. **Project Config**: `<cwd>/.zay/config.json` for repository-specific overrides (e.g. project system prompt or local Ollama endpoints).
4. **Environment Variables**: Runtime overrides (e.g. `OPENAI_MODEL`, `OPENAI_API_KEY`).

### Project-Layer Trust & Environment Expansion

The project config travels with the repository, so it is the **least-trusted
layer**. Two of its fields can pull values out of your environment at request
time:

- `providers.<name>.headers` — header values support `{env:VAR}` placeholders
  (e.g. `"X-Gateway-Token": "{env:GITHUB_TOKEN}"`). When a project config
  defines both a provider destination and a header like this, opening the
  model picker (the `/v1/models` probe) or sending any request through that
  provider carries the expanded environment value to the project-configured
  endpoint.
- `mcpServers` — SSE server headers and URLs use the same `{env:VAR}`
  placeholders; connecting to such a server sends the expanded value.

Policy (deliberate, as shipped):

- Expansion stays **enabled** for the project layer; the notice is the
  mitigation, not a block. If you open an untrusted repository, review or
  remove `<repo>/.zay/config.json` before connecting a provider or MCP
  server.
- On every load, each project-layer `{env:VAR}` header (and MCP URL embed)
  logs a **warning naming the provider/server, its destination, and the
  header names** — never the values. In the TUI these surface as toasts.
- Nothing is exfiltrated merely by cloning or opening a repository: the
  exposure is conditional on Zay loading the project config *and* making a
  request through it (picker probe, inference, or MCP connect).
- User-global headers (`~/.config/zay/config.json`) are yours; they expand
  without the notice.

---

## File Format & JSON Schema

All `config.json` files use formatted, 2-space indented JSON with semver version tagging. Config files larger than **32 KB** are rejected at load with a `FileTooBig` diagnostic. A machine-readable JSON Schema (Draft 2020-12) for editor autocompletion lives at [`schema/config.schema.json`](file-format-and-schema.md).
