### Supported Actions:
- **`health`**: Checks connectivity and reports the backend engine (`turso (libsql)`, `postgres`, or `sqlite`) and status.
- **`schema`**: Discovers table structures, column types, nullable flags, and primary keys.
- **`query`**: Runs read-only `SELECT` queries (formatted as Markdown tables). Select only needed columns and use `LIMIT` or keyset pagination when exploring large tables.
- **`exec`**: Runs DDL/DML statements (`INSERT`, `UPDATE`, `CREATE TABLE`) and reports success; remote service responses also include change counts.
- **`search_tool_result`**: Finds a case-sensitive literal in a saved large tool result and returns bounded chunk/character offsets. Defaults to five matches per call, up to eight; use `match_offset` to continue.
- **`read_tool_result`**: Reads a large tool result saved by the executor, using its `result_id`, zero-based `chunk`, character `offset`, and `limit` (up to 4096 characters per call).

The executor applies `context.compaction.toolOutputCapBytes` to every model-facing tool result, including Bash/Pwsh, database, plugin, and MCP tools. Larger results are saved before the model receives a head+tail preview. When the target text is known, use `search_tool_result` to locate it, then `read_tool_result` to inspect the returned chunk and character offset. Use sequential read windows when the target is unknown or surrounding structure matters. This lets the model probe a large result without loading it all into context. For database exploration, prefer a narrow `SELECT` with `LIMIT` or keyset pagination when the goal is to inspect rows rather than retrieve the rendered query output.

Artifact tables are private and cannot be accessed through arbitrary SQL. Reads are scoped to the active session, while rows carry the project key so maintenance can enforce per-project quotas. Each result is limited to 10 MiB, split into 64 KiB chunks, retained for seven days, and pruned to at most 128 results or 32 MiB per project. Incomplete writes older than 24 hours are removed. Session startup and new writes run expiry maintenance, and deleting a session removes its result artifacts. The same schema migration and parameterized backend API are used for SQLite, Turso/D1, and the companion service's SQLite/PostgreSQL backends.

### Example User Prompts:
```text
"What tables exist in our sessions database?"
"Show me the last 5 sessions recorded in the database using the database tool."
"Check the health of our active database connection."
```
