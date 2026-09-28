"""Database backend abstraction and implementations for Zay DB Server."""

from __future__ import annotations

import abc
import asyncio
import os
import sqlite3
from typing import Any


class DatabaseBackend(abc.ABC):
    """Abstract base class for database server backends."""

    @abc.abstractmethod
    async def connect(self) -> None:
        """Initialize connection pool or database connection."""

    @abc.abstractmethod
    async def close(self) -> None:
        """Close connections cleanly."""

    @abc.abstractmethod
    async def health(self) -> dict[str, Any]:
        """Return backend health and connection statistics."""

    @abc.abstractmethod
    async def exec(self, sql: str, params: list[Any] | None = None) -> dict[str, Any]:
        """Execute a DDL/DML statement and return changes and last_insert_rowid."""

    @abc.abstractmethod
    async def query(self, sql: str, params: list[Any] | None = None) -> dict[str, Any]:
        """Execute a SELECT query and return columns, types, and rows."""

    @abc.abstractmethod
    async def batch(self, statements: list[dict[str, Any]]) -> dict[str, Any]:
        """Execute a list of statements within an atomic transaction."""

    @abc.abstractmethod
    async def schema(self, table: str | None = None) -> dict[str, Any]:
        """Return database schema information for one or all tables."""


class SqliteBackend(DatabaseBackend):
    """SQLite implementation supporting file and in-memory databases."""

    def __init__(self, db_path: str = "zay_server.db") -> None:
        self.db_path = db_path
        self._conn: sqlite3.Connection | None = None
        self._lock = asyncio.Lock()

    def _sync_connect(self) -> None:
        if self.db_path != ":memory:":
            os.makedirs(os.path.dirname(os.path.abspath(self.db_path)), exist_ok=True)
        conn = sqlite3.connect(
            self.db_path,
            check_same_thread=False,
            timeout=10.0,
            isolation_level=None,  # Autocommit mode by default; explicit transactions when requested
        )
        conn.execute("PRAGMA journal_mode = WAL")
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("PRAGMA busy_timeout = 5000")
        self._conn = conn

    async def connect(self) -> None:
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, self._sync_connect)

    async def close(self) -> None:
        async with self._lock:
            if self._conn:
                self._conn.close()
                self._conn = None

    async def health(self) -> dict[str, Any]:
        async with self._lock:
            if not self._conn:
                return {"status": "disconnected", "backend": "sqlite"}
            try:
                cur = self._conn.cursor()
                cur.execute("SELECT 1")
                cur.close()
                # Get table list
                cur = self._conn.cursor()
                cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
                tables = [row[0] for row in cur.fetchall()]
                cur.close()
                return {
                    "status": "ok",
                    "backend": "sqlite",
                    "db_path": self.db_path,
                    "tables": tables,
                }
            except Exception as e:
                return {"status": "error", "backend": "sqlite", "error": str(e)}

    @staticmethod
    def _infer_type(val: Any) -> str:
        if val is None:
            return "null"
        if isinstance(val, bool):
            return "int"
        if isinstance(val, int):
            return "int"
        if isinstance(val, float):
            return "float"
        if isinstance(val, bytes):
            return "blob"
        return "text"

    async def exec(self, sql: str, params: list[Any] | None = None) -> dict[str, Any]:
        async with self._lock:
            if not self._conn:
                raise RuntimeError("Database not connected")
            p = params or []
            cur = self._conn.cursor()
            try:
                cur.execute(sql, p)
                changes = cur.rowcount if cur.rowcount != -1 else 0
                last_rowid = cur.lastrowid
                return {
                    "success": True,
                    "changes": changes,
                    "last_insert_rowid": last_rowid,
                }
            finally:
                cur.close()

    async def query(self, sql: str, params: list[Any] | None = None) -> dict[str, Any]:
        async with self._lock:
            if not self._conn:
                raise RuntimeError("Database not connected")
            p = params or []
            cur = self._conn.cursor()
            try:
                self._conn.execute("PRAGMA query_only = ON")
                cur.execute(sql, p)
                cols = [desc[0] for desc in cur.description] if cur.description else []
                raw_rows = cur.fetchall()

                types: list[str] = ["text"] * len(cols)
                if raw_rows:
                    # Infer types from first non-null sample per column
                    for col_idx in range(len(cols)):
                        for row in raw_rows:
                            val = row[col_idx]
                            if val is not None:
                                types[col_idx] = self._infer_type(val)
                                break

                # Serialize rows: convert bytes to hex or string
                formatted_rows: list[list[Any]] = []
                for row in raw_rows:
                    formatted_row: list[Any] = []
                    for val in row:
                        if isinstance(val, bytes):
                            formatted_row.append(val.decode("utf-8", errors="replace"))
                        else:
                            formatted_row.append(val)
                    formatted_rows.append(formatted_row)

                return {
                    "success": True,
                    "columns": cols,
                    "types": types,
                    "rows": formatted_rows,
                    "count": len(formatted_rows),
                }
            finally:
                self._conn.execute("PRAGMA query_only = OFF")
                cur.close()

    async def batch(self, statements: list[dict[str, Any]]) -> dict[str, Any]:
        async with self._lock:
            if not self._conn:
                raise RuntimeError("Database not connected")
            cur = self._conn.cursor()
            results: list[dict[str, Any]] = []
            try:
                self._conn.execute("BEGIN TRANSACTION")
                for s in statements:
                    sql = s.get("sql", "")
                    params = s.get("params", [])
                    cur.execute(sql, params)
                    results.append({
                        "changes": cur.rowcount if cur.rowcount != -1 else 0,
                        "last_insert_rowid": cur.lastrowid,
                    })
                self._conn.execute("COMMIT")
                return {"success": True, "results": results}
            except Exception as e:
                self._conn.execute("ROLLBACK")
                raise RuntimeError(f"Batch transaction failed and rolled back: {e}") from e
            finally:
                cur.close()

    async def schema(self, table: str | None = None) -> dict[str, Any]:
        async with self._lock:
            if not self._conn:
                raise RuntimeError("Database not connected")
            cur = self._conn.cursor()
            try:
                if table:
                    safe_table = table.replace('"', '""')
                    cur.execute(f'PRAGMA table_info("{safe_table}")')
                    cols = [
                        {"cid": row[0], "name": row[1], "type": row[2], "notnull": bool(row[3]), "dflt_value": row[4], "pk": bool(row[5])}
                        for row in cur.fetchall()
                    ]
                    return {"success": True, "tables": {table: cols}}
                else:
                    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
                    tables = [row[0] for row in cur.fetchall()]
                    result: dict[str, Any] = {}
                    for t in tables:
                        safe_t = t.replace('"', '""')
                        cur.execute(f'PRAGMA table_info("{safe_t}")')
                        result[t] = [
                            {"cid": row[0], "name": row[1], "type": row[2], "notnull": bool(row[3]), "dflt_value": row[4], "pk": bool(row[5])}
                            for row in cur.fetchall()
                        ]
                    return {"success": True, "tables": result}
            finally:
                cur.close()


def to_pg_sql(sql: str) -> str:
    """Translates '?' or '?1' placeholders in SQL to '$1, $2, ...' for Postgres/asyncpg."""
    parts: list[str] = []
    param_idx = 1
    in_single_quote = False
    in_double_quote = False
    i = 0
    while i < len(sql):
        c = sql[i]
        if c == "'" and not in_double_quote:
            in_single_quote = not in_single_quote
            parts.append(c)
        elif c == '"' and not in_single_quote:
            in_double_quote = not in_double_quote
            parts.append(c)
        elif c == '?' and not in_single_quote and not in_double_quote:
            j = i + 1
            while j < len(sql) and sql[j].isdigit():
                j += 1
            if j > i + 1:
                digit = int(sql[i + 1 : j])
                parts.append(f"${digit}")
                i = j - 1
            else:
                parts.append(f"${param_idx}")
                param_idx += 1
        else:
            parts.append(c)
        i += 1
    return "".join(parts)


class PostgresBackend(DatabaseBackend):
    """PostgreSQL backend connector (using asyncpg or psycopg when available)."""

    def __init__(self, connection_url: str) -> None:
        self.connection_url = connection_url
        self._pool: Any = None

    async def connect(self) -> None:
        try:
            import asyncpg  # type: ignore
            self._pool = await asyncpg.create_pool(self.connection_url)
        except ImportError:
            # Fallback or informative notice
            pass

    async def close(self) -> None:
        if self._pool:
            await self._pool.close()
            self._pool = None

    async def health(self) -> dict[str, Any]:
        if not self._pool:
            return {"status": "standby", "backend": "postgres", "detail": "asyncpg pool not connected"}
        async with self._pool.acquire() as conn:
            val = await conn.fetchval("SELECT 1")
            return {"status": "ok" if val == 1 else "error", "backend": "postgres"}

    async def exec(self, sql: str, params: list[Any] | None = None) -> dict[str, Any]:
        if not self._pool:
            raise RuntimeError("Postgres pool not connected")
        p = params or []
        pg_sql = to_pg_sql(sql)
        async with self._pool.acquire() as conn:
            status = await conn.execute(pg_sql, *p)
            return {"success": True, "status": status, "changes": 1}

    async def query(self, sql: str, params: list[Any] | None = None) -> dict[str, Any]:
        if not self._pool:
            raise RuntimeError("Postgres pool not connected")
        p = params or []
        pg_sql = to_pg_sql(sql)
        async with self._pool.acquire() as conn:
            async with conn.transaction(readonly=True):
                records = await conn.fetch(pg_sql, *p)
            if not records:
                return {"success": True, "columns": [], "types": [], "rows": [], "count": 0}
            cols = list(records[0].keys())
            rows = [[r[k] for k in cols] for r in records]
            return {"success": True, "columns": cols, "types": ["text"] * len(cols), "rows": rows, "count": len(rows)}

    async def batch(self, statements: list[dict[str, Any]]) -> dict[str, Any]:
        if not self._pool:
            raise RuntimeError("Postgres pool not connected")
        async with self._pool.acquire() as conn:
            async with conn.transaction():
                results = []
                for s in statements:
                    sql = s.get("sql", "")
                    p = s.get("params", [])
                    pg_sql = to_pg_sql(sql)
                    st = await conn.execute(pg_sql, *p)
                    results.append({"status": st})
                return {"success": True, "results": results}

    async def schema(self, table: str | None = None) -> dict[str, Any]:
        if not self._pool:
            raise RuntimeError("Postgres pool not connected")
        sql = """
            SELECT table_name, column_name, data_type, is_nullable
            FROM information_schema.columns
            WHERE table_schema = 'public'
        """
        params: list[Any] = []
        if table:
            sql += " AND table_name = $1"
            params.append(table)
        async with self._pool.acquire() as conn:
            records = await conn.fetch(sql, *params)
            tables: dict[str, Any] = {}
            for r in records:
                t = r["table_name"]
                if t not in tables:
                    tables[t] = []
                tables[t].append({
                    "name": r["column_name"],
                    "type": r["data_type"],
                    "nullable": r["is_nullable"] == "YES",
                })
            return {"success": True, "tables": tables}
