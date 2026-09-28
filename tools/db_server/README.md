# Zay External Database Server & Service

A standalone, high-performance REST database service for the Zay Agent, providing remote session storage, centralized state persistence, and external database querying capabilities.

## Features

- **Multi-backend support:** SQLite (local/remote file or `:memory:`) and PostgreSQL.
- **RESTful Data API:**
  - `GET /health` — Service health, engine status, and discovered tables.
  - `POST /v1/exec` — Execute DDL/DML statements with parameterized values (`changes`, `last_insert_rowid`).
  - `POST /v1/query` — Execute SELECT queries with column type reflection and formatted rows.
  - `POST /v1/batch` — Execute multiple statements atomically inside a transaction.
  - `POST /v1/schema` — Inspect table definitions and column metadata.
- **Authentication:** Optional API token/key verification via `Authorization: Bearer <key>` or `X-API-Key`.
- **Zay Agent Native Integration:** Built-in HTTP client in Zay (`src/db/service.zig`) with non-blocking timeouts and automatic local SQLite fallback.

## Quickstart

### 1. Run with `uv` (Recommended)

```bash
# Start default SQLite service on port 8766:
uv run -m tools.db_server.server --port 8766

# Start with an API key and custom DB path:
uv run -m tools.db_server.server --port 8766 --api-key "secret-key" --db-path "/data/zay.db"

# Start with PostgreSQL backend:
uv run -m tools.db_server.server --port 8766 --backend postgres --postgres-url "postgresql://user:pass@localhost:5432/zay"
```

### 2. Configure Zay Agent

Point Zay to your external database service in `config.json` (`~/.config/zay/config.json` or `%APPDATA%\zay\config.json`):

```json
{
  "databaseServerUrl": "http://127.0.0.1:8766",
  "databaseAuthToken": "secret-key"
}
```

Or via environment variables:

```bash
export ZAY_DATABASE_SERVER_URL="http://127.0.0.1:8766"
export ZAY_DATABASE_AUTH_TOKEN="secret-key"
```

### 3. Docker Deployment

```bash
docker build -t zay-db-server -f tools/db_server/Dockerfile tools/db_server
docker run -d -p 8766:8766 -v zay-data:/data --name zay-db-server zay-db-server
```
