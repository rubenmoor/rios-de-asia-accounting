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


def test_create_overlap_warning_and_delete(client):
    body = {"check_in": "2026-01-05", "check_out": "2026-01-08", "net_payout": "1.234.567"}
    first = client.post("/api/bookings", json=body).get_json()
    assert first["data"]["net_payout"] == 1234567
    assert first["notices"] == [{"level": "info", "text": "Booking saved."}]
    second = client.post("/api/bookings", json={**body, "check_in": "2026-01-06"}).get_json()
    assert [n["level"] for n in second["notices"]] == ["info", "warning"]
    assert len(client.get("/api/bookings?from=2026-01-01").get_json()) == 2
    deleted = client.delete(f"/api/bookings/{first['data']['id']}")
    assert deleted.get_json()["notices"][0]["text"] == "Booking deleted."


def test_invalid_booking_is_422(client):
    response = client.post("/api/bookings", json={"check_in": "2026-01-05"})
    assert response.status_code == 422
    assert set(response.get_json()["errors"]) == {"check_out", "net_payout"}
    assert client.get("/api/bookings/99").status_code == 404
