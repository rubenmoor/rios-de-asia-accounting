from datetime import date

import pytest

from rios_de_asia_accounting.model import Booking, BookingLine
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.storage.db import connect, migrate
from rios_de_asia_accounting.web.app import create_app


@pytest.fixture
def db_path(tmp_path):
    path = tmp_path / "books.db"
    conn = connect(path)
    migrate(conn)
    conn.close()
    return path


@pytest.fixture
def client(db_path):
    return create_app(db_path).test_client()


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


def test_imported_booking_only_takes_guests_and_notes(client, db_path):
    conn = connect(db_path)
    bid = repo.create_booking(
        conn, Booking(date(2026, 4, 1), date(2026, 4, 3), airbnb_code="IMP", guest_name="Bob")
    )
    repo.add_line(conn, BookingLine(bid, "Reservation", date(2026, 4, 1), "COP", 100000000))
    body = {"check_in": "2030-01-01", "guest_name": "Eve", "guests": "2", "notes": "hi"}
    saved = client.put(f"/api/bookings/{bid}", json=body).get_json()["data"]
    assert (saved["check_in"], saved["guest_name"]) == ("2026-04-01", "Bob")
    assert (saved["guests"], saved["notes"], saved["net_payout"]) == (2, "hi", 1000000)
