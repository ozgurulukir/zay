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
    assert data["auth_required"] is True


def test_auth_unauthorized(client: TestClient):
    response = client.post("/v1/exec", json={"sql": "CREATE TABLE test (id INT);"})
    assert response.status_code == 401


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
