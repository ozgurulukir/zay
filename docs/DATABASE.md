# Database & Session Backends

Zay features a modular storage subsystem (`src/session/`) that decouples session persistence, timeline branches, prompt history, and lane manifests from local disk storage. 

Users can run Zay in four primary modes:
1. **Local SQLite (`local_sqlite`):** Fast, zero-configuration embedded storage on your local machine (default).
2. **Turso / LibSQL Cloud (`turso_http`):** Direct serverless cloud database over HTTP with zero proxy daemons.
3. **Cloudflare D1 (`d1_http`):** Direct serverless database over Cloudflare's REST API with zero proxy daemons.
4. **Companion Service (`zay_service`):** Self-hosted or cloud-hosted Python service supporting SQLite and PostgreSQL (Neon, Supabase, Render, local Docker).

The `postgres_native` backend name is accepted for configuration compatibility,
but the native arm is not implemented. Use `zay_service` when the companion
service is backed by PostgreSQL.

---

## Backend Comparison Matrix

| Feature | `local_sqlite` | `turso_http` | `d1_http` | `zay_service` |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Use Case** | Single machine, offline-first | Cloud roaming, zero-ops setup | Cloudflare ecosystem, global edge | Custom PostgreSQL, enterprise DBs |
| **Daemon Required?** | ❌ None | ❌ None (Direct HTTP pipeline) | ❌ None (Direct HTTPS REST) | ✅ Yes (`tools.db_server`) |
| **Setup Complexity** | Zero configuration | Very Low (Turso CLI/Web token) | Very Low (Cloudflare API token) | Medium (Python server or Docker) |
| **Multi-Machine Roaming** | Manual file copying | ✅ Automatic via `host_id` | ✅ Automatic via `host_id` | ✅ Automatic via `host_id` |
| **Free-Tier Friendly** | Local disk | ✅ Turso Free Tier (9 GB, 500 DBs) | ✅ Cloudflare Free (500 MB per database) | ✅ Neon, Supabase, Render free tiers |
| **Storage Engine** | SQLite WAL | LibSQL (SQLite dialect) | SQLite (Cloudflare D1) | SQLite or PostgreSQL |
| **Atomic Transactions** | Native SQLite WAL | Hrana v2 conditional batches | REST `{ "batch": [...] }` payload | REST batch endpoint (`POST /v1/batch`) |

---

## 1. Quickstart: Local Embedded SQLite (`local_sqlite`)

This is the default configuration. No extra configuration or setup is required.

### Default Storage Paths
- **Windows:** `%APPDATA%\zay\sessions.sqlite`
- **Linux & macOS:** `~/.config/zay/sessions.sqlite`

### Custom Local Path
To point Zay to a custom database file (e.g., in a synchronized folder or mounted volume):

In `~/.config/zay/config.json`:
```json
{
  "database": {
    "backend": "local",
    "path": "/path/to/custom_sessions.sqlite"
  }
}
```

Or via environment variable:
```bash
export ZAY_DATABASE_PATH="/path/to/custom_sessions.sqlite"
```

---

## 2. Quickstart: Turso / LibSQL Cloud (`turso_http`)

The `turso_http` backend enables roaming between development machines (e.g., desktop, laptop, remote dev container) without running any background proxy or python daemon. Zay communicates directly with Turso's Hrana v2 pipeline endpoint over HTTPS.

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

## 5. Multi-Host Roaming & Machine Identity (`host_id`)

When using a remote backend (`turso_http`, `d1_http`, or `zay_service`), developers frequently connect from different computers (e.g., office desktop, home laptop, SSH dev container).

To ensure conflict-free coexistence:
1. Schema migration 8 adds a `host_id` column to both the `sessions` and `lanes` tables; the current schema is **version 9** (v9 adds `project_key` and the `project_locations` table for cross-project roaming).
2. At startup, Zay resolves the machine identity once, checking in this order on every platform:
   - `ZAY_HOST_ID` (if set — pin this to control roaming identity explicitly)
   - `COMPUTERNAME` (the Windows default)
   - `HOSTNAME` (the POSIX default)
   - Fallback: `"default-host"`
3. Sessions and lane reviews recorded from each machine retain their originating `host_id`.
4. In the session picker (`/resume`), sessions can be inspected and filtered while preserving distinct lane recovery manifests across machines.

---

## 6. Fail-Safe Startup Fallback

Network connections can drop, laptops can be opened on airplanes without Wi-Fi, or cloud databases might undergo maintenance.

Zay adheres to a **zero-lockout resilience rule**:
- At startup, `SessionManager` performs a health check against the configured remote backend.
- If the endpoint returns a network error, HTTP error, or timeout, Zay logs a single warning diagnostic — `session.external_db_fallback url=… err=…` — used for **every** remote backend kind (service, Turso, and D1 alike), not a per-backend variant.
- Zay **automatically falls back to local embedded SQLite** (`sessions.sqlite`).
- The developer can continue coding, querying models, and editing code locally without crash interruptions.

---

## 7. Built-in Agent Database Tool

The built-in `database` tool is **always advertised to the model**; it needs an endpoint to do
work. It resolves one from `databaseServerUrl` or the active session backend — `zay_service`,
`turso_http`, `d1_http`, or a local SQLite path (the local session store itself is queryable).
With nothing configured the call simply returns `External database service is not configured.`
rather than being absent from the tool list.

### Supported Actions:
- **`health`**: Checks connectivity and reports the backend engine (`turso (libsql)`, `postgres`, or `sqlite`) and status.
- **`schema`**: Discovers table structures, column types, nullable flags, and primary keys.
- **`query`**: Runs read-only `SELECT` queries (formatted as Markdown tables).
- **`exec`**: Runs DDL/DML statements (`INSERT`, `UPDATE`, `CREATE TABLE`) and reports success; remote service responses also include change counts.

### Example User Prompts:
```text
"What tables exist in our sessions database?"
"Show me the last 5 sessions recorded in the database using the database tool."
"Check the health of our active database connection."
```
