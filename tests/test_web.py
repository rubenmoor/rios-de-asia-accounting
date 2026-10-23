from datetime import date

import pytest

from airbnb_books.model import Booking
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
