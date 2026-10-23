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


def test_block_range_warns_inside_booking(client):
    booking = {"check_in": "2026-01-05", "check_out": "2026-01-08", "net_payout": "100"}
    client.post("/api/bookings", json=booking)
    body = {"from": "2026-01-04", "to": "2026-01-06", "reason": "owner"}
    notices = client.post("/api/blocked-days", json=body).get_json()["notices"]
    assert notices[0]["text"] == "3 day(s) blocked."
    assert notices[1]["level"] == "warning"
    assert len(client.get("/api/blocked-days").get_json()) == 3
    assert client.delete("/api/blocked-days/2026-01-04").status_code == 200
    assert client.delete("/api/blocked-days/nonsense").status_code == 404


def test_invalid_range_is_422(client):
    body = {"from": "2026-01-06", "to": "2026-01-04", "reason": "owner"}
    assert "to" in client.post("/api/blocked-days", json=body).get_json()["errors"]
