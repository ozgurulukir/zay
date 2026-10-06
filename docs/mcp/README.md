# Model Context Protocol (MCP) Integration Guide

Zay Agent features production-grade support for the **Model Context Protocol (MCP)**,
allowing your LLM models to dynamically discover and invoke external tools, databases,
APIs, and file services.

---

## 1. Overview & Transports

Zay Agent supports two standard MCP transports:

1. **Stdio (`stdio`)**: Child processes launched locally by Zay Agent (e.g. via `npx`,
   `python`, `uv`, or precompiled binaries).
2. **Streamable HTTP (`sse`)**: Remote MCP servers reached over HTTP. Each JSON-RPC
   request is a `POST` with `Accept: application/json, text/event-stream`; the response
   is either a single `application/json` body or a `text/event-stream` searched for the
   matching response id. Sessions are tracked via the `Mcp-Session-Id` header
   (Streamable HTTP, protocol `2025-03-26`). The config key is still named `sse` for
   backward compatibility, but the wire protocol is the modern Streamable HTTP transport.

A server carries **exactly one** transport: a `command` makes it stdio, a `url` makes it
remote. Providing both (or neither) is rejected at parse time.

---

## 2. Configuration (`config.json` / `mcpServers` or `mcp_servers`)

MCP servers are configured inside global `~/.config/zay/config.json` or project-local
`<cwd>/.zay/config.json` under the `"mcpServers"` (Claude Desktop / Cursor format) or
`"mcp_servers"` key; the legacy top-level `"mcp"` alias is also parsed for backward
compatibility. `camelCase` wins when several spellings are present, and the next save
rewrites the config as `"mcpServers"`.

### Example Configuration

```json
{
  "version": "2.0.0",
  "mcpServers": {
    "codebase-memory-mcp": {
      "command": "/path/to/codebase-memory-mcp",
      "args": []
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "enabled": true
    },
    "tavily": {
      "url": "https://mcp.tavily.com/mcp/?tavilyApiKey={env:TAVILY_API_KEY}",
      "enabled": true
    },
    "context7": {
      "url": "https://mcp.context7.com/mcp",
      "headers": {
        "CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}"
      }
    }
  }
}
```

### Server Configuration Options

The `mcpServers` entry fields (`command`, `args`, `url`, `headers`, `enabled`, `requestTimeoutMs`) are part of the config schema — the authoritative field table lives in the [Configuration Guide](../config/README.md#mcp-server-configuration). A `"type"` key may be present for compatibility with other MCP clients but is **ignored**: Zay infers the transport solely from `command` (stdio) vs `url` (Streamable HTTP). The two auth shapes and the `{env:VAR}` expansion behavior are specific to MCP and covered below.

### Environment variable expansion (`{env:VAR}`)

`command`, `args`, `url`, and `headers` values support `{env:VAR}` placeholders, expanded
against the process environment. This keeps secrets (API keys, tokens) out of
`config.json` — store them in the environment instead. A placeholder whose variable is
unset expands to an empty string and logs a warning, so a missing secret surfaces rather
than silently producing a broken command or URL.

> [!IMPORTANT]
> **Secrets stay out of config.json.** Placeholders are stored verbatim in the parsed
> config and expanded only at connect time, into an in-memory copy held by the MCP
> client. When Zay rewrites `config.json` (e.g. on a settings save) it writes the
> `{env:VAR}` placeholder back — never the resolved value — so a secret is never
> persisted to disk.

The same `{env:VAR}` mechanism (raw placeholders on disk, expansion at use time,
secrets never written back) also covers AI provider headers
(`providers.<name>.headers`), expanded once per client attach — see
[Configuration Guide — Provider Configuration](../config/README.md#provider-configuration).

**Project-layer trust parity.** When an `mcpServers` entry (or a provider
header) comes from the *project* config (`<cwd>/.zay/config.json`) and its
`url`/`headers` carry `{env:VAR}` placeholders, Zay logs a warning at load
naming the server, destination, and header names — never the values — and the
expansion still applies at connect time. This mirrors the provider-header
policy: project-layer expansion is visible, not blocked; see
[Configuration Guide — Project-Layer Trust](../config/README.md#project-layer-trust--environment-expansion).

Two common auth shapes for remote servers:

```json
// API key in the URL query string (e.g. Tavily)
"tavily": {
  "url": "https://mcp.tavily.com/mcp/?tavilyApiKey={env:TAVILY_API_KEY}"
}

// API key in a request header (e.g. Context7)
"context7": {
  "url": "https://mcp.context7.com/mcp",
  "headers": { "CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}" }
}
```

---
