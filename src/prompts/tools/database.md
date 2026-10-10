Query Zay's active session database, including session history, timeline entries,
prompt history, and saved tool results. The backend may be local SQLite or a
configured external service.

Actions:
- `query`: Execute a read-only SELECT query. Select only needed columns and use
  LIMIT or keyset pagination for large tables.
- `exec`: Execute INSERT, UPDATE, DELETE, or DDL statements. Returns changes and
  `last_insert_rowid`.
- `schema`: Inspect tables and columns; optionally pass `table`.
- `health`: Probe the backend service, engine, and health metrics.
- `search_tool_result`: Find a case-sensitive literal in a saved tool result.
- `read_tool_result`: Read a bounded window from a saved large tool result.

When asked about older sessions, query the relevant session tables instead of
assuming a file path. Common tables are `sessions`, `session_entries`, and
`prompt_history`; filter by the current workspace (`sessions.cwd`) or `host_id`
when appropriate.

Operations use the active backend. If a configured server is unavailable, the
session may fall back to local storage. Saved result windows are bounded and
private; use a narrow query or window rather than fetching everything.
