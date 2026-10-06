### External Database & Roaming Session Configuration

Zay supports delegating its internal session storage (`src/session/`) and application database inspection to a remote database service (such as `tools/db_server/`) or directly to cloud SQLite providers over HTTP (**Turso / LibSQL** via `turso_http` or **Cloudflare D1** via `d1_http`). This enables roaming users to access and sync their full session history, timeline branches, and resume points across multiple development machines without managing a local proxy.

**Turso / LibSQL (`turso_http`):**
```json
{
  "database": {
    "backend": "turso_http",
    "url": "libsql://my-database-org.turso.io",
    "authToken": "your-turso-jwt-token"
  }
}
```

**Cloudflare D1 (`d1_http`):**
```json
{
  "database": {
    "backend": "d1_http",
    "url": "d1://my-account-id/my-database-id",
    "authToken": "your-cloudflare-api-token"
  }
}
```

**Companion Service (`zay_service`):**
```json
{
  "database": {
    "backend": "zay_service",
    "url": "http://127.0.0.1:8766",
    "authToken": "your-secret-token"
  }
}
```

- **Supported Backends (`database.backend`):**
  - `local` / `local_sqlite` / `sqlite`: Local embedded SQLite file in the platform config directory (`~/.config/zay/sessions.sqlite` on POSIX; `%APPDATA%\zay\sessions.sqlite` on Windows).
  - `turso_http` / `turso` / `libsql`: Direct, native LibSQL Hrana v2 pipeline over HTTP. Reaches Turso Cloud directly with automatic `libsql://` -> `https://.../v2/pipeline` normalization, single-roundtrip pipeline batching, and zero daemon requirements.
  - `d1_http` / `d1` / `cloudflare_d1` / `cloudflare`: Direct, native Cloudflare D1 client over Cloudflare's REST API (`POST .../d1/database/{id}/query`). Supports `d1://<account_id>/<database_id>` shorthand, atomic `{ "batch": [...] }` requests, and zero daemon requirements.
  - `zay_service` / `remote_service` / `service`: Python or containerized database companion service supporting SQLite and PostgreSQL.
  - `postgres_native` / `postgres` / `postgresql`: Accepted by the parser, but the arm is **not yet implemented** — selecting it logs `session.backend_not_implemented` and, where fallback is allowed, falls back. Use `zay_service` pointed at a PostgreSQL-backed companion service instead.
- **`database.path`:** Optional override for the local SQLite file location, used instead of the platform default (`effectiveDatabasePath`).
- **Roaming User Synchronization:** Sessions and lane manifests record a `host_id`, allowing filtering and clean multi-host coexistence. It is derived in this order: `ZAY_HOST_ID`, `COMPUTERNAME`, `HOSTNAME`, then `"default-host"`; set `ZAY_HOST_ID` to pin it explicitly.
- **Fail-Safe Local Fallback:** If the external database server or remote cloud endpoint is unreachable or offline during startup, Zay logs a single warning diagnostic — `session.external_db_fallback url=… err=…`, used for every remote backend kind (service, Turso, and D1 alike) — and then falls back to the local embedded `sessions.sqlite` without crashing.
- **Agent Database Tool:** The built-in `database` tool is always advertised to the model; it needs an endpoint to do work. It uses `databaseServerUrl`, or the active session backend (`zay_service`, `turso_http`, `d1_http`, or a configured local SQLite path). With none configured a call simply returns `External database service is not configured.` When an endpoint is available the tool exposes `health`, schema inspection (`schema`), read-only SQL queries (`query`), and DDL/DML execution (`exec`).

---
