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
