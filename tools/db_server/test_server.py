import sys
from pathlib import Path

# Ensure db_server directory is in sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent))

import pytest
from fastapi.testclient import TestClient

from backend import SqliteBackend
from server import DatabaseHost, build_app


@pytest.fixture
def client():
    backend = SqliteBackend(db_path=":memory:")
    host = DatabaseHost(backend=backend, api_key="test-secret")
    app = build_app(host)
    with TestClient(app) as test_client:
        yield test_client


def test_health(client: TestClient):
    response = client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert data["backend"] == "sqlite"
    assert "auth_required" not in data
    assert "version" not in data


def test_auth_unauthorized(client: TestClient):
    response = client.post("/v1/exec", json={"sql": "CREATE TABLE test (id INT);"})
    assert response.status_code == 401

    # Non-ASCII API key header must return 401 rather than TypeError (500) in hmac.compare_digest
    non_ascii_resp = client.post(
        "/v1/exec",
        json={"sql": "CREATE TABLE test (id INT);"},
        headers=[(b"x-api-key", b"caf\xe9")],
    )
    assert non_ascii_resp.status_code == 401


def test_exec_and_query(client: TestClient):
    headers = {"Authorization": "Bearer test-secret"}

    # Create table
    create_resp = client.post(
        "/v1/exec",
        json={"sql": "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, score REAL);"},
        headers=headers,
    )
    assert create_resp.status_code == 200
    assert create_resp.json()["success"] is True

    # Insert row
    insert_resp = client.post(
        "/v1/exec",
        json={"sql": "INSERT INTO users (name, score) VALUES (?, ?);", "params": ["Alice", 98.5]},
        headers=headers,
    )
    assert insert_resp.status_code == 200
    data = insert_resp.json()
    assert data["changes"] == 1
    assert data["last_insert_rowid"] == 1

    # Query row
    query_resp = client.post(
        "/v1/query",
        json={"sql": "SELECT id, name, score FROM users;"},
        headers=headers,
    )
    assert query_resp.status_code == 200
    qdata = query_resp.json()
    assert qdata["success"] is True
    assert qdata["columns"] == ["id", "name", "score"]
    assert qdata["rows"] == [[1, "Alice", 98.5]]
    assert qdata["count"] == 1


def test_batch_transaction(client: TestClient):
    headers = {"X-API-Key": "test-secret"}

    # Create table
    client.post(
        "/v1/exec",
        json={"sql": "CREATE TABLE items (id INT, label TEXT);"},
        headers=headers,
    )

    # Batch insert
    batch_resp = client.post(
        "/v1/batch",
        json={
            "statements": [
                {"sql": "INSERT INTO items VALUES (?, ?);", "params": [1, "item1"]},
                {"sql": "INSERT INTO items VALUES (?, ?);", "params": [2, "item2"]},
            ]
        },
        headers=headers,
    )
    assert batch_resp.status_code == 200
    assert len(batch_resp.json()["results"]) == 2

    # Query count
    query_resp = client.post(
        "/v1/query",
        json={"sql": "SELECT count(*) FROM items;"},
        headers=headers,
    )
    assert query_resp.status_code == 200
    assert query_resp.json()["rows"][0][0] == 2


def test_schema_inspection(client: TestClient):
    headers = {"Authorization": "Bearer test-secret"}
    client.post(
        "/v1/exec",
        json={"sql": "CREATE TABLE documents (id TEXT PRIMARY KEY, title TEXT NOT NULL);"},
        headers=headers,
    )

    schema_resp = client.post("/v1/schema", json={"table": "documents"}, headers=headers)
    assert schema_resp.status_code == 200
    tables = schema_resp.json()["tables"]
    assert "documents" in tables
    col_names = [col["name"] for col in tables["documents"]]
    assert "id" in col_names
    assert "title" in col_names


def test_to_pg_sql_translation():
    from backend import to_pg_sql

    assert to_pg_sql("SELECT * FROM t WHERE a = ? AND b = ?") == "SELECT * FROM t WHERE a = $1 AND b = $2"
    assert to_pg_sql("UPDATE t SET a = ?1 WHERE b = ?2") == "UPDATE t SET a = $1 WHERE b = $2"
    assert to_pg_sql("SELECT 'what? is ?' FROM t WHERE x = ?") == "SELECT 'what? is ?' FROM t WHERE x = $1"
    assert to_pg_sql("SELECT 'it''s ?' FROM t WHERE x = ?") == "SELECT 'it''s ?' FROM t WHERE x = $1"
    assert to_pg_sql('SELECT "col""?" FROM t WHERE x = ?') == 'SELECT "col""?" FROM t WHERE x = $1'
    assert to_pg_sql("SELECT ? -- ignored ?\nAND y = ?") == "SELECT $1 -- ignored ?\nAND y = $2"
    assert to_pg_sql("SELECT /* ignored ? */ ? FROM t") == "SELECT /* ignored ? */ $1 FROM t"


def test_schema_invalid_identifier_rejected(client: TestClient):
    headers = {"Authorization": "Bearer test-secret"}
    resp = client.post("/v1/schema", json={"table": "bad; DROP TABLE x"}, headers=headers)
    assert resp.status_code == 400


def test_postgres_backend_ssl_parsing():
    import ssl
    from backend import PostgresBackend, _prepare_postgres_connection

    b = PostgresBackend("postgresql://user:pass@ep-xyz.neon.tech/neondb?sslmode=require")
    assert b.connection_url.endswith("?sslmode=require")

    # verify-full produces strict SSLContext with hostname checking and preserves other params
    url, ssl_opt = _prepare_postgres_connection(
        "postgresql://user:pass@db.example.com:5432/app?sslmode=verify-full&application_name=zay&connect_timeout=5"
    )
    assert url == "postgresql://user:pass@db.example.com:5432/app?application_name=zay&connect_timeout=5"
    assert isinstance(ssl_opt, ssl.SSLContext)
    assert ssl_opt.check_hostname is True
    assert ssl_opt.verify_mode == ssl.CERT_REQUIRED

    # verify-ca produces SSLContext with CA verification and check_hostname=False
    url_ca, ssl_ca = _prepare_postgres_connection(
        "postgresql://user:pass@db.example.com/app?connect_timeout=5&sslmode=verify-ca"
    )
    assert url_ca == "postgresql://user:pass@db.example.com/app?connect_timeout=5"
    assert isinstance(ssl_ca, ssl.SSLContext)
    assert ssl_ca.check_hostname is False
    assert ssl_ca.verify_mode == ssl.CERT_REQUIRED

    # require and disable
    url_req, ssl_req = _prepare_postgres_connection("postgresql://u:p@host/db?sslmode=require")
    assert url_req == "postgresql://u:p@host/db"
    assert ssl_req == "require"

    url_dis, ssl_dis = _prepare_postgres_connection("postgresql://u:p@host/db?sslmode=disable")
    assert url_dis == "postgresql://u:p@host/db"
    assert ssl_dis is False

    # no sslmode
    url_none, ssl_none = _prepare_postgres_connection("postgresql://u:p@host/db?application_name=zay")
    assert url_none == "postgresql://u:p@host/db?application_name=zay"
    assert ssl_none is None

    # unsupported sslmode fails fast
    with pytest.raises(ValueError, match="Unsupported PostgreSQL sslmode"):
        _prepare_postgres_connection("postgresql://u:p@host/db?sslmode=invalid")


def test_postgres_connect_fails_fast_without_asyncpg(monkeypatch):
    import asyncio
    from backend import PostgresBackend

    monkeypatch.setitem(sys.modules, "asyncpg", None)
    backend = PostgresBackend("postgresql://u:p@host/db")
    with pytest.raises(RuntimeError, match="asyncpg"):
        asyncio.run(backend.connect())


def test_batch_rollback_preserves_original_error_when_not_in_transaction(client: TestClient):
    headers = {"Authorization": "Bearer test-secret"}
    # COMMIT ends the transaction early; the next invalid statement fails outside a transaction.
    # The error should report the invalid SQL error, not "cannot rollback - no transaction is active".
    resp = client.post(
        "/v1/batch",
        json={
            "statements": [
                {"sql": "COMMIT"},
                {"sql": "SELECT * FROM nonexistent_table_xyz"},
            ]
        },
        headers=headers,
    )
    assert resp.status_code == 400
    assert "nonexistent_table_xyz" in resp.json()["detail"]
    assert "no transaction is active" not in resp.json()["detail"]


def test_validate_bind_security():
    from server import parse_args, validate_bind_security

    # Loopback hosts allowed without API key
    validate_bind_security("127.0.0.1", None)
    validate_bind_security("localhost", None)
    validate_bind_security("::1", None)

    # Non-loopback hosts refused without API key
    with pytest.raises(ValueError, match="non-loopback"):
        validate_bind_security("0.0.0.0", None)
    with pytest.raises(ValueError, match="non-loopback"):
        validate_bind_security("::", None)
    with pytest.raises(ValueError, match="non-loopback"):
        validate_bind_security("192.168.1.50", None)

    # Allowed with API key or explicit override
    validate_bind_security("0.0.0.0", "secret-key")
    validate_bind_security("0.0.0.0", None, allow_unauthenticated=True)

    # --reload flag removed; --allow-unauthenticated supported
    args = parse_args(["--host", "0.0.0.0", "--allow-unauthenticated"])
    assert args.allow_unauthenticated is True
    with pytest.raises(SystemExit):
        parse_args(["--reload"])
