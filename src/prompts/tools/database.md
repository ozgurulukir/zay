Execute SQL queries, statements, or inspect schemas on the database. Connects to the external database server (SQLite or PostgreSQL) when `databaseServerUrl` is configured, or operates on Zay's active session database by default.

Actions:
- `query`: Execute a SELECT query with structured results (columns, types, and rows).
- `exec`: Execute an INSERT, UPDATE, DELETE, or DDL statement. Returns changes count and last_insert_rowid.
- `schema`: Inspect database tables and column definitions. Optionally pass `table` to filter.
- `health`: Probe service status, backend engine (SQLite / PostgreSQL), and health metrics.

When `databaseServerUrl` is configured in config.json or `ZAY_DATABASE_SERVER_URL` is set, operations target the external database service. Otherwise, operations target the local session storage.
