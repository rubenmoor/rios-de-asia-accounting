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


def test_settings_roundtrip(client):
    body = {
        "long_term_rent_cop_per_month": "1.500.000",
        "per_booking_allocation": "spread",
        "backup_keep": "10",
        "listings": ["Casa A"],
    }
    assert client.put("/api/settings", json=body).status_code == 200
    got = client.get("/api/settings").get_json()
    assert got["long_term_rent_cop_per_month"] == 1_500_000 and got["listings"] == ["Casa A"]


def test_invalid_settings_is_422(client):
    response = client.put("/api/settings", json={"backup_keep": "0"})
    assert response.status_code == 422
    assert "backup_keep" in response.get_json()["errors"]
