from datetime import date

import pytest

from airbnb_books.model import Booking, BookingLine, Expense, Settings
from airbnb_books.storage import repo
from airbnb_books.storage.db import connect, migrate
from airbnb_books.web import forms
from airbnb_books.web.app import NAV, create_app


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


def test_index(client):
    response = client.get("/")
    assert response.status_code == 200
    assert b"airbnb-books" in response.data


@pytest.mark.parametrize("url", [url for _, url, _ in NAV])
def test_nav_links_render(client, url):
    assert client.get("/").data.count(f'href="{url}"'.encode()) == 1
    assert client.get(url).status_code == 200


@pytest.mark.parametrize(
    ("text", "pesos"),
    [("1.234.567", 1234567), ("1,234,567", 1234567), ("1234567", 1234567), ("1 234", 1234)],
)
def test_parse_money(text, pesos):
    assert forms.parse_money(text) == pesos


@pytest.mark.parametrize("text", ["12,5", "1.5", "12.34.567", "-5", "abc", "1.2345", ""])
def test_parse_money_errors(text):
    with pytest.raises(ValueError):
        forms.parse_money(text)


def test_format_money():
    assert forms.format_money(1234567) == "1.234.567"
    assert forms.format_money(0) == "0"


@pytest.mark.parametrize(
    ("text", "minutes"), [("1.5", 90), ("1,5", 90), ("1:30", 90), ("0:45", 45), ("2", 120)]
)
def test_parse_hours(text, minutes):
    assert forms.parse_hours(text) == minutes


@pytest.mark.parametrize("text", ["1:75", "x", "1.5.5", "-1", ":30"])
def test_parse_hours_errors(text):
    with pytest.raises(ValueError):
        forms.parse_hours(text)


def test_format_hours():
    assert forms.format_hours(90) == "1.5"
    assert forms.format_hours(120) == "2"


def test_rates_dates_months():
    assert forms.parse_rate("4100.5") == 41005000
    assert forms.format_rate(41005000) == "4100.50"
    assert forms.format_rate(41000000) == "4100"
    with pytest.raises(ValueError):
        forms.parse_rate("4100.123")
    assert forms.parse_date("2026-03-05") == date(2026, 3, 5)
    assert forms.parse_month("2026-03") == date(2026, 3, 1)
    for bad in ("2026-13-01", "5/3/2026"):
        with pytest.raises(ValueError):
            forms.parse_date(bad)
    with pytest.raises(ValueError):
        forms.parse_month("2026-3x")
    assert forms.parse_currency("usd") == "USD"
    with pytest.raises(ValueError):
        forms.parse_currency("US")


def test_form_collects_one_error_per_field():
    form = forms.Form({"amount": "12,5", "day": "", "hours": "1:30"})
    assert form.money("amount", positive=True) is None
    assert form.day("day", required=True) is None
    assert form.hours("hours", positive=True) == 90
    assert set(form.errors) == {"amount", "day"}
    assert not form.ok


def test_form_apply_maps_validation_error():
    from airbnb_books.storage.repo import ValidationError

    def fail():
        raise ValidationError("nope")

    form = forms.Form()
    assert form.apply(fail) is None
    assert form.errors == {"": "nope"}


def test_booking_options_newest_first():
    options = forms.booking_options(
        [
            Booking(date(2026, 1, 1), date(2026, 1, 3), guest_name="Ann", listing="L", id=1),
            Booking(date(2026, 2, 1), date(2026, 2, 3), id=2),
        ]
    )
    assert options == [
        (2, "2026-02-01 – 2026-02-03 · - · -"),
        (1, "2026-01-01 – 2026-01-03 · Ann · L"),
    ]


def test_origin_check(db_path):
    app = create_app(db_path)
    app.add_url_rule("/echo", "echo", lambda: "ok", methods=["POST"])
    c = app.test_client()
    assert c.post("/echo", headers={"Origin": "http://evil.example"}).status_code == 403
    assert c.post("/echo", headers={"Referer": "http://evil.example/x"}).status_code == 403
    assert c.post("/echo", headers={"Origin": "http://localhost"}).status_code == 200
    assert c.post("/echo", headers={"Referer": "http://localhost/x"}).status_code == 200
    assert c.post("/echo").status_code == 200


def test_one_connection_per_request(db_path):
    from airbnb_books.web.app import get_db

    app = create_app(db_path)
    seen = []

    @app.route("/count")
    def count():
        seen.append(get_db())
        assert get_db() is seen[-1]
        return str(get_db().execute("SELECT count(*) FROM bookings").fetchone()[0])

    c = app.test_client()
    assert c.get("/count").data == b"0"
    assert c.get("/count").data == b"0"
    assert seen[0] is not seen[1]
    with pytest.raises(Exception, match="closed"):
        seen[0].execute("SELECT 1")


# --- bookings -------------------------------------------------------------------------------


def _new_booking(client, **over):
    data = {
        "check_in": "2026-03-01",
        "check_out": "2026-03-04",
        "net_payout": "1.500.000",
        "guest_name": "Ann",
        "listing": "L1",
    }
    data.update(over)
    return client.post("/bookings/new", data=data)


def _db(db_path):
    return connect(db_path)


def test_booking_create_with_manual_line(client, db_path):
    response = _new_booking(client, airbnb_code="ABC")
    assert response.status_code == 302
    conn = _db(db_path)
    booking = repo.find_booking_by_code(conn, "ABC")
    assert booking.net_payout == 1500000 and booking.nights == 3
    assert [ln.type for ln in repo.list_lines(conn, booking.id)] == ["Manual"]
    page = client.get(response.headers["Location"])
    assert b"1.500.000" in page.data and b"Booking saved" in page.data
    assert b"Ann" in client.get("/bookings").data
    assert b"Ann" not in client.get("/bookings?listing=other").data


def test_booking_new_form_presets_single_listing(client, db_path):
    conn = _db(db_path)
    repo.save_settings(conn, Settings(property_listings=["Only one"]))
    assert b'value="Only one"' in client.get("/bookings/new").data


def test_booking_edit_amount_changes_line(client, db_path):
    _new_booking(client, airbnb_code="ABC")
    conn = _db(db_path)
    bid = repo.find_booking_by_code(conn, "ABC").id
    assert b"1.500.000" in client.get(f"/bookings/{bid}/edit").data
    data = {"check_in": "2026-03-01", "check_out": "2026-03-05", "net_payout": "2000000"}
    assert client.post(f"/bookings/{bid}/edit", data=data).status_code == 302
    booking = repo.get_booking(conn, bid)
    assert booking.net_payout == 2000000 and booking.nights == 4
    assert len(repo.list_lines(conn, bid)) == 1


def test_booking_validation(client):
    page = _new_booking(client, check_out="2026-03-01").data
    assert b"check-out must be after check-in" in page and b'value="Ann"' in page
    assert b"required" in _new_booking(client, net_payout="").data
    assert b"whole pesos" in _new_booking(client, net_payout="12,5").data
    assert b"greater than zero" in _new_booking(client, guests="0").data
    _new_booking(client, airbnb_code="DUP")
    assert b"already exists" in _new_booking(client, airbnb_code="DUP").data


def test_imported_booking_only_guests_and_notes(client, db_path):
    conn = _db(db_path)
    bid = repo.create_booking(
        conn, Booking(date(2026, 4, 1), date(2026, 4, 3), airbnb_code="IMP", guest_name="Bob")
    )
    repo.add_line(conn, BookingLine(bid, "Reservation", date(2026, 4, 1), "COP", 100000000))
    page = client.get(f"/bookings/{bid}/edit").data
    assert b'name="check_in"' not in page and b"re-import brings it back" in page
    data = {"check_in": "2030-01-01", "guest_name": "Eve", "guests": "2", "notes": "hi"}
    assert client.post(f"/bookings/{bid}/edit", data=data).status_code == 302
    booking = repo.get_booking(conn, bid)
    assert (booking.check_in, booking.guest_name) == (date(2026, 4, 1), "Bob")
    assert (booking.guests, booking.notes) == (2, "hi")
    assert booking.net_payout == 1000000


def test_booking_overlap_warns(client):
    _new_booking(client)
    response = _new_booking(client, check_in="2026-03-03", check_out="2026-03-06")
    assert response.status_code == 302
    assert b"overlaps another booking" in client.get(response.headers["Location"]).data


def test_booking_delete(client, db_path):
    conn = _db(db_path)
    bid = repo.create_booking(
        conn, Booking(date(2026, 4, 1), date(2026, 4, 3)), manual_amount_cop=5
    )
    repo.create_expense(conn, Expense(date(2026, 4, 2), 100, "per_booking", booking_id=bid))
    response = client.post(f"/bookings/{bid}/delete")
    assert b"not deleted" in client.get(response.headers["Location"]).data
    assert repo.get_booking(conn, bid) is not None
    conn.execute("DELETE FROM expenses")
    client.post(f"/bookings/{bid}/delete")
    assert repo.get_booking(conn, bid) is None
    assert client.get(f"/bookings/{bid}").status_code == 404
