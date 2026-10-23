import sqlite3

import pytest

from airbnb_books.storage.db import connect, migrate


@pytest.fixture
def conn(tmp_path):
    c = connect(tmp_path / "t.db")
    migrate(c)
    return c


def booking(conn, code="C1", cin="2026-01-01", cout="2026-01-04"):
    return conn.execute(
        "INSERT INTO bookings (airbnb_code, check_in, check_out) VALUES (?, ?, ?)",
        (code, cin, cout),
    ).lastrowid


def line(conn, bid, type="Reservation", date="2026-01-04", cur="COP", amount=100, **kw):
    cols = {
        "booking_id": bid,
        "type": type,
        "date": date,
        "currency": cur,
        "amount_minor": amount,
        **kw,
    }
    return conn.execute(
        f"INSERT INTO booking_lines ({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})",
        list(cols.values()),
    ).lastrowid


def expense(conn, **kw):
    cols = {"date": "2026-01-05", "amount": 1000, "category": "fixed", **kw}
    conn.execute(
        f"INSERT INTO expenses ({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})",
        list(cols.values()),
    )


def test_bad_booking_dates(conn):
    with pytest.raises(sqlite3.IntegrityError):
        booking(conn, cin="2026-02-30")
    with pytest.raises(sqlite3.IntegrityError):
        booking(conn, cin="2026-1-1")


def test_checkout_after_checkin(conn):
    with pytest.raises(sqlite3.IntegrityError):
        booking(conn, cin="2026-01-04", cout="2026-01-04")


def test_duplicate_code_but_many_nulls(conn):
    booking(conn, "X")
    with pytest.raises(sqlite3.IntegrityError):
        booking(conn, "X")
    booking(conn, None)
    booking(conn, None)


def test_guests_positive(conn):
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO bookings (check_in, check_out, guests) "
            "VALUES ('2026-01-01', '2026-01-02', 0)"
        )


def test_capex_needs_useful_life(conn):
    with pytest.raises(sqlite3.IntegrityError):
        expense(conn, category="capex")
    with pytest.raises(sqlite3.IntegrityError):
        expense(conn, category="capex", useful_life_days=0)
    expense(conn, category="capex", useful_life_days=365)
    with pytest.raises(sqlite3.IntegrityError):
        expense(conn, category="fixed", useful_life_days=365)


def test_per_booking_needs_booking(conn):
    with pytest.raises(sqlite3.IntegrityError):
        expense(conn, category="per_booking")
    expense(conn, category="per_booking", booking_id=booking(conn))


def test_unknown_enums(conn):
    bid = booking(conn)
    with pytest.raises(sqlite3.IntegrityError):
        expense(conn, category="food")
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("INSERT INTO blocked_days (date, reason) VALUES ('2026-01-01', 'nap')")
    with pytest.raises(sqlite3.IntegrityError):
        line(conn, bid, type="Payout")
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO recurring_expenses (description, amount, category, start_month) "
            "VALUES ('x', 1, 'capex', '2026-01')"
        )


def test_money_columns_are_strict(conn):
    with pytest.raises(sqlite3.IntegrityError):
        expense(conn, amount=1.5)
    with pytest.raises(sqlite3.IntegrityError):
        expense(conn, amount="abc")
    bid = booking(conn)
    with pytest.raises(sqlite3.IntegrityError):
        line(conn, bid, amount=10.5)


def test_currency_format(conn):
    bid = booking(conn)
    with pytest.raises(sqlite3.IntegrityError):
        line(conn, bid, cur="usd")
    with pytest.raises(sqlite3.IntegrityError):
        line(conn, bid, cur="US1")


def test_delete_booking_with_expenses_fails_and_lines_cascade(conn):
    bid = booking(conn)
    line(conn, bid)
    conn.execute(
        "INSERT INTO time_log (date, minutes, booking_id) VALUES ('2026-01-02', 30, ?)", (bid,)
    )
    expense(conn, category="per_booking", booking_id=bid)
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("DELETE FROM bookings WHERE id = ?", (bid,))
    conn.execute("DELETE FROM expenses")
    conn.execute("DELETE FROM bookings WHERE id = ?", (bid,))
    assert conn.execute("SELECT COUNT(*) FROM booking_lines").fetchone()[0] == 0
    assert conn.execute("SELECT booking_id FROM time_log").fetchone()[0] is None


def test_duplicate_line_rejected(conn):
    bid = booking(conn)
    line(conn, bid)
    with pytest.raises(sqlite3.IntegrityError):
        line(conn, bid)
    line(conn, bid, amount=101)


def test_time_log_minutes_positive(conn):
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("INSERT INTO time_log (date, minutes) VALUES ('2026-01-01', 0)")


def test_exchange_rate_constraints(conn):
    conn.execute("INSERT INTO exchange_rates VALUES ('2026-01-01', 'USD', 412345)")
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("INSERT INTO exchange_rates VALUES ('2026-01-01', 'USD', 400000)")
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("INSERT INTO exchange_rates VALUES ('2026-01-02', 'USD', 0)")


def test_recurring_month_rules(conn):
    sql = (
        "INSERT INTO recurring_expenses (description, amount, category, start_month, end_month) "
        "VALUES ('rent', 1, 'fixed', ?, ?)"
    )
    conn.execute(sql, ("2026-03", None))
    conn.execute(sql, ("2026-03", "2026-03"))
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(sql, ("2026-03", "2026-02"))
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(sql, ("2026-13", None))


def test_duplicate_recurring_month_rejected(conn):
    rid = conn.execute(
        "INSERT INTO recurring_expenses (description, amount, category, start_month) "
        "VALUES ('rent', 1000, 'fixed', '2026-01')"
    ).lastrowid
    expense(conn, date="2026-01-01", recurring_expense_id=rid)
    with pytest.raises(sqlite3.IntegrityError):
        expense(conn, date="2026-01-01", recurring_expense_id=rid)
    expense(conn, date="2026-02-01", recurring_expense_id=rid)
    expense(conn, date="2026-01-01")
    expense(conn, date="2026-01-01")
    conn.execute("DELETE FROM recurring_expenses")
    assert (
        conn.execute("SELECT COUNT(*) FROM expenses WHERE recurring_expense_id IS NULL").fetchone()[
            0
        ]
        == 4
    )


def test_booking_totals(conn):
    bid = booking(conn)  # 3 nights; COP amounts are centavos (rate 100)
    line(
        conn,
        bid,
        amount=50_000_000,
        gross_minor=60_000_000,
        service_fee_minor=-10_000_000,
        rate=100,
        amount_cop=500_000,
    )
    # USD 100.00 net, gross 120.00, fee -20.00 at 4123.45 -> 412 345 + 494 814 + -82 469 (rounded)
    line(
        conn,
        bid,
        date="2026-01-05",
        cur="USD",
        amount=10_000,
        gross_minor=12_000,
        service_fee_minor=-2_000,
        rate=412345,
        amount_cop=412_345,
    )
    line(conn, bid, type="Co-Host payout", amount=-5_000_000, rate=100, amount_cop=-50_000)
    line(conn, bid, type="Adjustment", date="2026-01-06", cur="EUR", amount=1_000)
    row = conn.execute("SELECT * FROM booking_totals WHERE booking_id = ?", (bid,)).fetchone()
    assert row["nights"] == 3
    assert row["net_payout"] == 500_000 + 412_345
    assert row["cohost_cost"] == 50_000
    assert row["gross"] == 600_000 + 494_814
    assert row["airbnb_fee"] == -100_000 - 82_469
    assert row["needs_rate"] == 1


def test_booking_totals_no_lines_and_all_rated(conn):
    empty = booking(conn, "E")
    rated = booking(conn, "R")
    line(conn, rated, amount=10, rate=100, amount_cop=10)
    rows = {r["booking_id"]: r for r in conn.execute("SELECT * FROM booking_totals")}
    assert rows[empty]["net_payout"] == 0 and rows[empty]["needs_rate"] == 0
    assert rows[rated]["net_payout"] == 10 and rows[rated]["needs_rate"] == 0
