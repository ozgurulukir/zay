"""FastAPI server for the Zay External Database Service."""

from __future__ import annotations

import argparse
import hmac
import ipaddress
import os
import sys
from contextlib import asynccontextmanager
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, status
from pydantic import BaseModel, Field

try:
    from .backend import DatabaseBackend, PostgresBackend, SqliteBackend
    from .defaults import (
        DEFAULT_API_VERSION,
        DEFAULT_BACKEND,
        DEFAULT_BIND_HOST,
        DEFAULT_BIND_PORT,
        DEFAULT_SQLITE_PATH,
    )
except (ImportError, ValueError):
    from backend import DatabaseBackend, PostgresBackend, SqliteBackend
    from defaults import (
        DEFAULT_API_VERSION,
        DEFAULT_BACKEND,
        DEFAULT_BIND_HOST,
        DEFAULT_BIND_PORT,
        DEFAULT_SQLITE_PATH,
    )


class ExecRequest(BaseModel):
    sql: str = Field(..., description="SQL statement to execute (DDL/DML)")
    params: list[Any] = Field(default_factory=list, description="Positional parameters for query")


class ExecResponse(BaseModel):
    success: bool
    changes: int = 0
    last_insert_rowid: int | None = None


class QueryRequest(BaseModel):
    sql: str = Field(..., description="SQL SELECT query to execute")
    params: list[Any] = Field(default_factory=list, description="Positional parameters for query")


class QueryResponse(BaseModel):
    success: bool
    columns: list[str] = Field(default_factory=list)
    types: list[str] = Field(default_factory=list)
    rows: list[list[Any]] = Field(default_factory=list)
    count: int = 0


class BatchStatement(BaseModel):
    sql: str
    params: list[Any] = Field(default_factory=list)


class BatchRequest(BaseModel):
    statements: list[BatchStatement] = Field(..., description="List of statements to execute in an atomic transaction")


class BatchResponse(BaseModel):
    success: bool
    results: list[dict[str, Any]] = Field(default_factory=list)


class SchemaRequest(BaseModel):
    table: str | None = Field(default=None, description="Optional table name to filter schema inspection")


class DatabaseHost:
    """Holds the active backend instance."""

    def __init__(self, backend: DatabaseBackend, api_key: str | None = None) -> None:
        self.backend = backend
        self.api_key = api_key


def build_app(host: DatabaseHost) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        await host.backend.connect()
        yield
        await host.backend.close()

    app = FastAPI(
        title="Zay Database Server",
        description="High-performance external database service for Zay Agent session persistence and data tooling.",
        version=DEFAULT_API_VERSION,
        lifespan=lifespan,
    )

    async def verify_auth(
        authorization: str | None = Header(default=None),
        x_api_key: str | None = Header(default=None),
    ) -> None:
        if not host.api_key:
            return
        token = None
        if authorization and authorization.startswith("Bearer "):
            token = authorization[7:].strip()
        elif x_api_key:
            token = x_api_key.strip()

        if token is None or not hmac.compare_digest(token.encode("utf-8"), host.api_key.encode("utf-8")):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid or missing database service API key",
            )

    @app.get("/health")
    async def health() -> dict[str, Any]:
        h = await host.backend.health()
        return {
            "status": h.get("status", "ok"),
            "backend": h.get("backend", "unknown"),
        }

    @app.post("/v1/exec", response_model=ExecResponse, dependencies=[Depends(verify_auth)])
    async def execute(req: ExecRequest) -> ExecResponse:
        try:
            res = await host.backend.exec(req.sql, req.params)
            return ExecResponse(**res)
        except Exception as e:
            raise HTTPException(status_code=400, detail=str(e)) from e

    @app.post("/v1/query", response_model=QueryResponse, dependencies=[Depends(verify_auth)])
    async def query(req: QueryRequest) -> QueryResponse:
        try:
            res = await host.backend.query(req.sql, req.params)
            return QueryResponse(**res)
        except Exception as e:
            raise HTTPException(status_code=400, detail=str(e)) from e

    @app.post("/v1/batch", response_model=BatchResponse, dependencies=[Depends(verify_auth)])
    async def batch(req: BatchRequest) -> BatchResponse:
        try:
            stmts = [s.model_dump() for s in req.statements]
            res = await host.backend.batch(stmts)
            return BatchResponse(**res)
        except Exception as e:
            raise HTTPException(status_code=400, detail=str(e)) from e

    @app.post("/v1/schema", dependencies=[Depends(verify_auth)])
    async def schema(req: SchemaRequest) -> dict[str, Any]:
        try:
            return await host.backend.schema(req.table)
        except Exception as e:
            raise HTTPException(status_code=400, detail=str(e)) from e

    return app


def _is_loopback_host(host: str) -> bool:
    normalized = host.strip().lower()
    if normalized == "localhost":
        return True
    try:
        return ipaddress.ip_address(normalized).is_loopback
    except ValueError:
        return False


def validate_bind_security(host: str, api_key: str | None, allow_unauthenticated: bool = False) -> None:
    if not api_key and not allow_unauthenticated and not _is_loopback_host(host):
        raise ValueError(
            f"Cannot bind to non-loopback host '{host}' without an API key. "
            "To fix, pass --api-key, set ZAY_DB_API_KEY, or pass --allow-unauthenticated."
        )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Zay Standalone Database Server")
    parser.add_argument("--host", default=DEFAULT_BIND_HOST, help=f"Bind host (default: {DEFAULT_BIND_HOST})")
    parser.add_argument("--port", type=int, default=DEFAULT_BIND_PORT, help=f"Bind port (default: {DEFAULT_BIND_PORT})")
    parser.add_argument("--backend", choices=["sqlite", "postgres"], default=DEFAULT_BACKEND, help="Database backend")
    parser.add_argument("--db-path", default=DEFAULT_SQLITE_PATH, help=f"SQLite file path (default: {DEFAULT_SQLITE_PATH})")
    parser.add_argument("--postgres-url", default=None, help="Postgres connection string")
    parser.add_argument(
        "--api-key",
        default=None,
        help="Optional API authentication key (falls back to ZAY_DB_API_KEY env var)",
    )
    parser.add_argument(
        "--allow-unauthenticated",
        action="store_true",
        help="Allow binding to a non-loopback host without an API key (unsafe)",
    )
    return parser.parse_args(argv)


def main() -> None:
    import uvicorn

    args = parse_args()
    api_key = args.api_key or os.environ.get("ZAY_DB_API_KEY") or None
    try:
        validate_bind_security(args.host, api_key, allow_unauthenticated=args.allow_unauthenticated)
    except ValueError as e:
        print(f"[!] Error: {e}", file=sys.stderr)
        sys.exit(1)

    if args.backend == "postgres":
        if not args.postgres_url:
            print("[!] Error: --postgres-url is required when using the postgres backend.", file=sys.stderr)
            sys.exit(1)
        backend: DatabaseBackend = PostgresBackend(args.postgres_url)
    else:
        backend = SqliteBackend(args.db_path)

    host = DatabaseHost(backend=backend, api_key=api_key)
    app = build_app(host)

    print(f"[*] Starting Zay Database Server on {args.host}:{args.port} (backend: {args.backend})")
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
