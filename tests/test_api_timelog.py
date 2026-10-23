import pytest

from rios_de_asia_accounting.storage.db import connect, migrate
from rios_de_asia_accounting.web.app import create_app


@pytest.fixture
def client(tmp_path):
    path = tmp_path / "books.db"
    conn = connect(path)
    migrate(conn)
    conn.close()
    return create_app(path).test_client()


def test_time_entry_minutes(client):
    saved = client.post("/api/time", json={"date": "2026-01-05", "hours": "1:30"}).get_json()
    assert saved["data"]["minutes"] == 90
    assert client.get("/api/time").get_json()[0]["minutes"] == 90
    assert client.delete(f"/api/time/{saved['data']['id']}").status_code == 200


def test_invalid_time_is_422(client):
    response = client.post("/api/time", json={"date": "2026-01-05", "hours": "0"})
    assert response.status_code == 422
    assert "hours" in response.get_json()["errors"]
