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


def test_rate_saved_with_notice(client):
    saved = client.post(
        "/api/rates", json={"date": "2026-01-05", "currency": "USD", "rate": "4.000,5"}
    )
    assert saved.status_code == 422
    saved = client.post(
        "/api/rates", json={"date": "2026-01-05", "currency": "USD", "rate": "4000.5"}
    )
    assert saved.get_json()["data"]["rate"] == 400050
    assert "booking" in saved.get_json()["notices"][0]["text"]
    assert client.get("/api/rates").get_json()[0]["rate"] == 400050
    assert client.delete("/api/rates/2026-01-05/USD").status_code == 200
    assert client.delete("/api/rates/2026-01-05/USD").status_code == 404
