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
