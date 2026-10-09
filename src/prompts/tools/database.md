Execute SQL queries, statements, or inspect schemas on Zay's active session database (local SQLite or the configured external server).

Actions:
- `query`: Execute a SELECT query with structured results (columns, types, and rows).
- `exec`: Execute an INSERT, UPDATE, DELETE, or DDL statement. Returns changes count and last_insert_rowid.
- `schema`: Inspect database tables and column definitions. Optionally pass `table` to filter.
- `health`: Probe service status, backend engine (SQLite / PostgreSQL), and health metrics.
- `read_tool_result`: Read a saved large tool observation from the active session. Pass its `result_id` from the tool output; `chunk` is zero-based, `offset` is a character offset within that chunk, and `limit` is characters (default 2048, maximum 4096). The response gives the next chunk or offset to request.

Operations follow the active session backend. If a configured server is unavailable and sessions fall back to local storage, this tool uses that local database too.

Large tool outputs include a `result_id` and retrieval instructions. Use `read_tool_result` to inspect them in small pieces. The result tables are private; do not query or modify them with SQL. Results are scoped to the active session, expire after seven days, and older results are pruned to keep project storage bounded.
