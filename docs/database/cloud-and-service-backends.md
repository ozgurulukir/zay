### Step 1: Create a Turso Database
If you haven't installed the [Turso CLI](https://docs.turso.tech/cli/introduction):
```bash
# macOS / Linux
curl -sSfL https://get.tur.so/install.sh | bash

# Windows (Scoop)
scoop bucket add turso https://github.com/tursodatabase/scoop-bucket.git
scoop install turso
```

Login and create your database:
```bash
turso auth login
turso db create zay-sessions
```

Get your database URL:
```bash
turso db show zay-sessions --url
# Outputs: libsql://zay-sessions-<org>.turso.io
```

### Step 2: Generate an Auth Token
```bash
turso db tokens create zay-sessions --expiration none
# Outputs: eyJhbGciOi... (JWT token)
```

### Step 3: Configure Zay

Add the database section to `~/.config/zay/config.json`:
```json
{
  "database": {
    "backend": "turso_http",
    "url": "libsql://zay-sessions-<org>.turso.io",
    "authToken": "eyJhbGciOi..."
  }
}
```

> [!NOTE]
> Zay automatically normalizes `libsql://` and `https://` URLs to Turso's `/v2/pipeline` endpoint.

Alternatively, use environment variables:
```bash
export ZAY_DATABASE_BACKEND="turso_http"
export ZAY_DATABASE_URL="libsql://zay-sessions-<org>.turso.io"
export ZAY_DATABASE_AUTH_TOKEN="eyJhbGciOi..."
```

---

## 3. Quickstart: Cloudflare D1 (`d1_http`)

The `d1_http` backend connects directly to Cloudflare D1 over Cloudflare's v4 REST API (`POST https://api.cloudflare.com/client/v4/accounts/{account_id}/d1/database/{database_id}/query`). It enables zero-daemon, serverless session persistence directly in the Cloudflare ecosystem.

### Step 1: Create a D1 Database
Using the [Cloudflare Wrangler CLI](https://developers.cloudflare.com/workers/wrangler/):
```bash
npx wrangler d1 create zay-sessions
```
This outputs your `database_id` (a UUID like `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`).

### Step 2: Get your Account ID & API Token
1. **Account ID:** Found in the right sidebar of the [Cloudflare Dashboard](https://dash.cloudflare.com) or via `npx wrangler whoami`.
2. **API Token:** In Cloudflare Dashboard -> **My Profile** -> **API Tokens** -> **Create Token**.
   - Create a token with **D1:Edit** permissions for your account.

### Step 3: Configure Zay

Add the database section to `~/.config/zay/config.json`:
```json
{
  "database": {
    "backend": "d1_http",
    "url": "d1://<account_id>/<database_id>",
    "authToken": "<your-cloudflare-api-token>"
  }
}
```

> [!NOTE]
> Zay automatically expands shorthand `d1://<account_id>/<database_id>` or `d1://<account_id>:<database_id>` into Cloudflare's full REST endpoint (`https://api.cloudflare.com/client/v4/accounts/<account_id>/d1/database/<database_id>/query`). You can also specify the full HTTPS URL directly.

Alternatively, configure using environment variables:
```bash
export ZAY_DATABASE_BACKEND="d1_http"
export ZAY_DATABASE_URL="d1://<account_id>/<database_id>"
export ZAY_DATABASE_AUTH_TOKEN="<your-cloudflare-api-token>"
```

---

## 4. Quickstart: Companion Database Service (`zay_service`)

Use `zay_service` when you want to host your session database on PostgreSQL (such as [Neon](https://neon.tech), [Supabase](https://supabase.com), [Render](https://render.com), or AWS RDS) or manage a centralized company server.

### Step 1: Start the Database Server
Zay includes a standalone FastAPI companion service in `tools/db_server/`.

#### Option A: Local SQLite over HTTP
```bash
uv run -m tools.db_server.server --port 8766
```

#### Option B: Cloud PostgreSQL (Neon / Supabase / Render)

The service is configured **entirely through CLI flags** — it reads no `ZAY_DB_*`
environment variables. `asyncpg` ships as the `postgres` extra, so install it or the
Postgres pool is never created and `/health` reports `standby`.

```bash
uv run --project tools/db_server --extra postgres -m tools.db_server.server \
  --port 8766 \
  --backend postgres \
  --postgres-url "postgresql://user:password@ep-xyz.neon.tech/neondb?sslmode=require" \
  --api-key "your-chosen-secret"
```

> [!NOTE]
> Always pass `--api-key` when starting Postgres remotely. When it is omitted, the API
> accepts unauthenticated requests.

> [!IMPORTANT]
> **Transaction Pooling Compatibility:** `tools/db_server/` is hardened for serverless PostgreSQL providers using transaction-mode poolers (such as PgBouncer or Supabase transaction pooling on port 6543). The server acquires an explicit connection per operation (`pool.acquire()`), disables the session-level prepared-statement cache (`statement_cache_size=0` — critical for PgBouncer/Supavisor/Neon), and caps the pool at `min_size=1, max_size=10`.

### Step 2: Configure Zay
In `~/.config/zay/config.json`:
```json
{
  "database": {
    "backend": "zay_service",
    "url": "http://127.0.0.1:8766",
    "authToken": "your-chosen-secret"
  }
}
```

Or via environment variables:
```bash
export ZAY_DATABASE_BACKEND="zay_service"
export ZAY_DATABASE_URL="http://127.0.0.1:8766"
export ZAY_DATABASE_AUTH_TOKEN="your-chosen-secret"
```

---
