## 7. Known Limitations

- **`notifications/tools/list_changed`**: Handled via `drainMcpNotifications` (see §4);
  the catalog refreshes automatically on the notification (the advertised
  `listChanged` capability is recorded but the refresh is not gated on it).
- **Server-push requests**: Zay does not act on server-initiated Streamable HTTP GET
  streams (sampling/roots). The POST path (tool discovery + tool calls) is fully
  supported, which covers normal tool use.
- **Overlay-added servers are persisted** to the global `config.json` (see §5), so they survive a restart.
- **Server names containing `__` are rejected**: the `mcp__server__tool` namespace uses `__` as
  the separator, and parsing splits at the *first* separator — so **single underscores are
  fine** (`codebase_memory_mcp` parses correctly). A name containing `__` is skipped at config
  load with a warning and can never reach the wire.
- **OAuth 2.1**: Remote servers requiring OAuth (`401` + `WWW-Authenticate`) are not yet
  supported. Use a server that accepts an API key in the URL or headers via `{env:VAR}`.
- **JSON Schema composition in tool `inputSchema`**: `oneOf`/`anyOf` collapse to a single
  property kind only when every branch is the same primitive
  (`integer`/`number`/`boolean`/`string`); a nullable `{"type":"null"}` branch is ignored,
  so `anyOf:[{integer},{null}]` resolves to `integer`. Mixed-type or object/array unions,
  `$ref`, and the array-of-types nullable form (`"type":["string","null"]`) are not resolved
  and fall back to `string`.
