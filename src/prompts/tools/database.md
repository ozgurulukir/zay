Execute SQL queries, statements, or inspect schemas on Zay's active session database (local SQLite or the configured external server).

Actions:
- `query`: Execute a read-only SELECT query; results are rendered as Markdown tables. Select only needed columns and use LIMIT or keyset pagination to explore large tables.
- `exec`: Execute an INSERT, UPDATE, DELETE, or DDL statement. Returns changes count and last_insert_rowid.
- `schema`: Inspect database tables and column definitions. Optionally pass `table` to filter.
- `health`: Probe service status, backend engine (SQLite / PostgreSQL), and health metrics.
- `search_tool_result`: Find a non-empty, case-sensitive literal in a saved tool observation. Pass its `result_id` and `needle`; results contain at most 5 match locations by default (hard maximum 8), with `chunk` and character `offset` values. Continue with `match_offset` when more matches exist.
- `read_tool_result`: Read a saved large tool observation from the active session. Pass its `result_id` from the tool output; `chunk` is zero-based, `offset` is a character offset within that chunk, and `limit` is characters (default 2048, maximum 4096, further bounded by the configured output budget). The response gives the next chunk or offset to request.

Operations follow the active session backend. If a configured server is unavailable and sessions fall back to local storage, this tool uses that local database too.

Large tool outputs include a `result_id` and retrieval instructions. Start with the head-tail preview. When you know a literal to find, use `search_tool_result`, then inspect relevant locations with `read_tool_result`; each search response bounds its matches and gives continuation instructions. Use sequential windows only when the target is unknown or the surrounding structure matters. Do not fetch every window unless the task requires the complete result. These reads retrieve rendered tool text; for database rows, prefer a narrow SELECT with LIMIT or keyset pagination when that answers the question directly. The result tables are private; do not query or modify them with SQL. Results are scoped to the active session, expire after seven days, and older results are pruned to keep project storage bounded.
