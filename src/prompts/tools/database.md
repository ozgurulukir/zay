Execute SQL queries, statements, or inspect schemas on Zay's active session database (local SQLite or the configured external server).

Actions:
- `query`: Execute a SELECT query with structured results (columns, types, and rows).
- `exec`: Execute an INSERT, UPDATE, DELETE, or DDL statement. Returns changes count and last_insert_rowid.
- `schema`: Inspect database tables and column definitions. Optionally pass `table` to filter.
- `health`: Probe service status, backend engine (SQLite / PostgreSQL), and health metrics.

Operations follow the active session backend. If a configured server is unavailable and sessions fall back to local storage, this tool uses that local database too.
