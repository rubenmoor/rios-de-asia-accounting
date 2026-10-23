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


# --- expenses and recurring expenses --------------------------------------------------------


def _expense(client, **over):
    data = {"date": "2026-03-10", "amount": "50.000", "category": "fixed", "description": "wifi"}
    data.update(over)
    return client.post("/expenses/new", data=data)


def test_expense_create_edit_delete(client, db_path):
    assert _expense(client).status_code == 302
    conn = _db(db_path)
    (expense,) = repo.list_expenses(conn)
    assert expense.amount == 50000 and expense.booking_id is None
    page = client.get(f"/expenses/{expense.id}/edit").data
    assert b"50.000" in page and b"wifi" in page
    data = {"date": "2026-03-11", "amount": "60000", "category": "tax"}
    assert client.post(f"/expenses/{expense.id}/edit", data=data).status_code == 302
    assert repo.get_expense(conn, expense.id).amount == 60000
    assert b"2026-03-11" in client.get("/expenses").data
    client.post(f"/expenses/{expense.id}/delete")
    assert repo.list_expenses(conn) == []


def test_expense_validation(client, db_path):
    page = _expense(client, category="capex").data
    assert b"required" in page and b'value="wifi"' in page
    assert b"greater than zero" in _expense(client, category="capex", useful_life_days="0").data
    assert b"required" in _expense(client, category="per_booking").data
    assert b"greater than zero" in _expense(client, amount="0").data
    assert b"choose one" in _expense(client, category="bogus").data
    assert repo.list_expenses(_db(db_path)) == []


def test_expense_fields_ignored_for_other_categories(client, db_path):
    conn = _db(db_path)
    bid = repo.create_booking(conn, Booking(date(2026, 3, 1), date(2026, 3, 3)), 1)
    assert _expense(client, booking_id=str(bid), useful_life_days="x").status_code == 302
    (expense,) = repo.list_expenses(conn)
    assert expense.booking_id is None and expense.useful_life_days is None
    assert _expense(client, category="per_booking", booking_id=str(bid)).status_code == 302
    assert (
        _expense(client, category="capex", useful_life_days="1095", booking_id=str(bid)).status_code
        == 302
    )
    by_cat = {e.category: e for e in repo.list_expenses(conn)}
    assert (
        by_cat["per_booking"].booking_id == bid and by_cat["per_booking"].useful_life_days is None
    )
    assert by_cat["capex"].booking_id is None and by_cat["capex"].useful_life_days == 1095


def test_expense_filter(client):
    _expense(client, date="2026-03-10", description="march-fixed")
    _expense(client, date="2026-04-10", description="april-fixed")
    _expense(client, date="2026-04-12", category="tax", description="april-tax")
    page = client.get("/expenses?from=2026-04-01&to=2026-04-30&category=tax").data
    assert b"april-tax" in page and b"april-fixed" not in page and b"march-fixed" not in page
    page = client.get("/expenses?from=2026-04-01").data
    assert b"april-fixed" in page and b"march-fixed" not in page
    assert b"enter a date" in client.get("/expenses?from=bogus").data


def _template(client, **over):
    data = {
        "description": "rent",
        "amount": "1.000.000",
        "category": "fixed",
        "start_month": "2026-08",
    }
    data.update(over)
    return client.post("/recurring/new", data=data)


def test_recurring_create_generates_due_months(client, db_path):
    response = _template(client)
    assert response.status_code == 302
    conn = _db(db_path)
    (item,) = repo.list_recurring_expenses(conn)
    generated = repo.list_expenses_of_recurring(conn, item.id)
    months = (date.today().year * 12 + date.today().month) - (2026 * 12 + 8) + 1
    assert len(generated) == months and generated[0].date == date(2026, 8, 1)
    page = client.get(response.headers["Location"]).data
    assert b"2026-08-01" in page and b"generated" in page
    assert b"rent" in client.get("/recurring").data


def test_recurring_edit_keeps_generated_rows_and_delete_keeps_them(client, db_path):
    _template(client)
    conn = _db(db_path)
    (item,) = repo.list_recurring_expenses(conn)
    before = repo.list_expenses_of_recurring(conn, item.id)
    data = {
        "description": "rent2",
        "amount": "2000000",
        "category": "fixed",
        "start_month": "2026-08",
    }
    assert client.post(f"/recurring/{item.id}", data=data).status_code == 302
    assert repo.get_recurring_expense(conn, item.id).amount == 2000000
    assert [e.amount for e in repo.list_expenses_of_recurring(conn, item.id)] == [
        e.amount for e in before
    ]
    client.post(f"/recurring/{item.id}/delete")
    assert repo.list_recurring_expenses(conn) == []
    assert len(repo.list_expenses(conn)) == len(before)


def test_recurring_validation(client, db_path):
    page = _template(client, end_month="2026-07").data
    assert b"must not be before" in page and b'value="rent"' in page
    assert b"required" in _template(client, description="").data
    assert b"greater than zero" in _template(client, amount="0").data
    assert b"choose one" in _template(client, category="capex").data
    assert repo.list_recurring_expenses(_db(db_path)) == []


def _block(client, **over):
    data = {"from": "2026-05-01", "to": "2026-05-05", "reason": "owner", "note": "trip"}
    data.update(over)
    return client.post("/blocked-days/new", data=data, follow_redirects=True)


def test_blocked_range_skips_existing_and_warns_inside_booking(client, db_path):
    assert b"5 day(s) blocked." in _block(client, **{"from": "2026-05-04", "to": "2026-05-08"}).data
    page = _block(client).data
    assert b"3 day(s) blocked; 2 already blocked and skipped" in page
    assert len(repo.list_blocked_days(_db(db_path))) == 8
    _new_booking(client, check_in="2026-06-02", check_out="2026-06-05")
    page = _block(client, **{"from": "2026-06-04", "to": "2026-06-05"}).data
    assert b"fall inside a booking" in page and b"2026-06-04" in page
    # check-out day itself is free
    assert b"fall inside" not in _block(client, **{"from": "2026-06-05", "to": "2026-06-05"}).data


def test_blocked_validation_edit_delete(client, db_path):
    assert b"must not be before" in _block(client, to="2026-04-01").data
    assert b"choose one" in _block(client, reason="x").data
    assert b"required" in _block(client, **{"from": ""}).data
    assert repo.list_blocked_days(_db(db_path)) == []
    _block(client, **{"to": "2026-05-01"})
    assert b"trip" in client.get("/blocked-days?from=2026-05-01&to=2026-05-01").data
    assert b"trip" not in client.get("/blocked-days?from=2026-06-01").data
    client.post("/blocked-days/2026-05-01", data={"reason": "buffer", "note": "n2"})
    day = repo.get_blocked_day(_db(db_path), date(2026, 5, 1))
    assert (day.reason, day.note) == ("buffer", "n2")
    assert client.get("/blocked-days/bogus").status_code == 404
    client.post("/blocked-days/2026-05-01/delete")
    assert repo.list_blocked_days(_db(db_path)) == []


def _time(client, **over):
    data = {"date": "2026-05-02", "hours": "1:30", "description": "cleaning"}
    data.update(over)
    return client.post("/time/new", data=data)


def test_time_create_edit_delete_total(client, db_path):
    assert _time(client).status_code == 302
    _time(client, date="2026-06-02", hours="2,5", description="repairs")
    conn = _db(db_path)
    first, second = repo.list_time_entries(conn)
    assert (first.minutes, second.minutes) == (90, 150)
    page = client.get("/time").data
    assert b"1.5 h" in page and b"4 h" in page and page.index(b"repairs") < page.index(b"cleaning")
    page = client.get("/time?from=2026-05-01&to=2026-05-31").data
    assert b"cleaning" in page and b"repairs" not in page and b"1.5 h" in page
    assert b'value="1.5"' in client.get(f"/time/{first.id}/edit").data
    client.post(f"/time/{first.id}/edit", data={"date": "2026-05-02", "hours": "2"})
    assert repo.get_time_entry(conn, first.id).minutes == 120
    client.post(f"/time/{first.id}/delete")
    assert len(repo.list_time_entries(conn)) == 1


def test_time_validation_and_booking_picker(client, db_path):
    assert b"greater than zero" in _time(client, hours="0").data
    assert b"enter hours" in _time(client, hours="abc").data
    assert b"required" in _time(client, date="").data
    assert b"choose one" in _time(client, booking_id="999").data
    assert repo.list_time_entries(_db(db_path)) == []
    _new_booking(client)
    (booking,) = repo.list_bookings(_db(db_path))
    assert b"2026-03-01 \xe2\x80\x93 2026-03-04 \xc2\xb7 Ann" in client.get("/time/new").data
    _time(client, booking_id=str(booking.id))
    assert repo.list_time_entries(_db(db_path))[0].booking_id == booking.id


def _settings(client, **over):
    data = {
        "hourly_value_cop": "25.000",
        "long_term_rent_cop_per_month": "2000000",
        "per_booking_allocation": "spread",
        "backup_keep": "10",
    }
    data.update(over)
    return client.post("/settings", data=data)


def test_settings_defaults_round_trip_and_listings(client, db_path):
    page = client.get("/settings").data
    assert b'name="backup_keep" value="30"' in page and b"COP" in page
    _new_booking(client, listing="Casa A")
    _new_booking(client, listing="Casa B", check_in="2026-04-01", check_out="2026-04-03")
    page = client.get("/settings").data
    assert b'value="Casa A"' in page and b'value="Casa B"' in page
    response = client.post(
        "/settings",
        data={
            "hourly_value_cop": "25.000",
            "long_term_rent_cop_per_month": "2000000",
            "per_booking_allocation": "spread",
            "backup_keep": "10",
            "listings": ["Casa B"],
            "other_listing": "Casa C",
        },
    )
    assert response.status_code == 302
    saved = repo.load_settings(_db(db_path))
    assert saved.hourly_value_cop == 25000 and saved.long_term_rent_cop_per_month == 2000000
    assert (saved.per_booking_allocation, saved.backup_keep) == ("spread", 10)
    assert saved.property_listings == ["Casa B", "Casa C"]
    page = client.get("/settings").data
    assert b"25.000" in page and b'value="Casa C" checked' in page


def test_settings_validation(client, db_path):
    assert b"enter whole pesos" in _settings(client, hourly_value_cop="-5").data
    assert b"at least 1" in _settings(client, backup_keep="0").data
    assert b"choose one" in _settings(client, per_booking_allocation="x").data
    assert repo.load_settings(_db(db_path)).backup_keep == 30


def _usd_booking(db_path):
    conn = _db(db_path)
    bid = repo.create_booking(conn, Booking(date(2026, 1, 10), date(2026, 1, 12)))
    line = BookingLine(bid, "Reservation", date(2026, 1, 15), "USD", 10_000)
    repo.add_line(conn, line)
    return conn, bid


def test_rates_create_recompute_edit_delete(client, db_path):
    conn, bid = _usd_booking(db_path)
    assert repo.get_booking(conn, bid).needs_rate
    response = client.post(
        "/rates/new", data={"date": "2026-01-10", "currency": "usd", "rate": "4000.50"}
    )
    assert response.status_code == 302
    (rate,) = repo.list_exchange_rates(conn)
    assert (rate.currency, rate.rate) == ("USD", 40_005_000)
    first = repo.get_booking(conn, bid)
    assert not first.needs_rate and first.net_payout > 0
    page = client.get("/rates").data
    assert b"4000.5" in page
    client.post("/rates/2026-01-10/USD", data={"rate": "5000"})
    assert repo.get_booking(conn, bid).net_payout > first.net_payout
    assert b"5000" in client.get("/rates/2026-01-10/USD").data
    response = client.post("/rates/2026-01-10/USD/delete", follow_redirects=True)
    assert b"1 booking(s) still need an exchange rate" in response.data
    assert repo.list_exchange_rates(conn) == [] and repo.get_booking(conn, bid).needs_rate
    assert client.get("/rates/2026-01-10/USD").status_code == 404


def test_rates_validation(client, db_path):
    base = {"date": "2026-01-10", "currency": "USD", "rate": "4000"}
    assert b"3-letter" in client.post("/rates/new", data={**base, "currency": "US"}).data
    assert b"greater than zero" in client.post("/rates/new", data={**base, "rate": "0"}).data
    assert b"up to 2 decimals" in client.post("/rates/new", data={**base, "rate": "4000.123"}).data
    assert b"required" in client.post("/rates/new", data={**base, "date": ""}).data
    assert repo.list_exchange_rates(_db(db_path)) == []
