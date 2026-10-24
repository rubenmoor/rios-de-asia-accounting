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
        "long_term_rent": "1.500.000",
        "long_term_rent_currency": "COP",
        "per_booking_allocation": "spread",
        "backup_keep": "10",
        "listings": ["Casa A"],
    }
    assert client.put("/api/settings", json=body).status_code == 200
    got = client.get("/api/settings").get_json()
    assert got["long_term_rent_usd"] == 37_500 and got["listings"] == ["Casa A"]
    entered = got["long_term_rent_entered"]
    assert (entered["original_minor"], entered["currency"]) == (150_000_000, "COP")
    assert entered["rate_date"] == entered["date"] and entered["rate"] == 4_000_000_000


def test_invalid_settings_is_422(client):
    response = client.put("/api/settings", json={"backup_keep": "0"})
    assert response.status_code == 422
    assert "backup_keep" in response.get_json()["errors"]
