Execute SQL queries, statements, or inspect schemas on the configured external database server or database service.

Actions:
- `query`: Execute a SELECT query with structured results (columns, types, and rows).
- `exec`: Execute an INSERT, UPDATE, DELETE, or DDL statement. Returns changes count and last_insert_rowid.
- `schema`: Inspect database tables and column definitions. Optionally pass `table` to filter.
- `health`: Probe service status, backend engine (SQLite / PostgreSQL), and health metrics.

Requires `databaseServerUrl` in config.json or `ZAY_DATABASE_SERVER_URL` in the environment.
