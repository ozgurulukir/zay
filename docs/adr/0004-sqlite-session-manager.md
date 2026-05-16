# SQLite session manager with entry trees

Durable agent sessions are stored in SQLite with a `sessions` table and a tree-shaped `session_entries` table. Entry identity, parent links, role, kind, and timestamps live in queryable columns, while each entry's heterogeneous message payload is stored as JSON text constructed by Nova; this preserves branchable session semantics without prematurely normalizing every message/content variant.
