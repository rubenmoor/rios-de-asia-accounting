import json
import shutil
import sqlite3
from importlib import resources

import pytest

from rios_de_asia_accounting.storage.db import connect, migrate


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
    cols = {
        "date": "2026-01-05",
        "original_minor": 1000,
        "currency": "USD",
        "category": "fixed",
        **kw,
    }
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
        line(conn, bid, type="Payout")
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO recurring_expenses (description, amount_minor, category, start_month) "
            "VALUES ('x', 1, 'capex', '2026-01')"
        )


def test_money_columns_are_strict(conn):
    with pytest.raises(sqlite3.IntegrityError):
        expense(conn, original_minor=1.5)
    with pytest.raises(sqlite3.IntegrityError):
        expense(conn, amount="abc", rate=1_000_000, rate_date="2026-01-05")
    with pytest.raises(sqlite3.IntegrityError):  # a USD amount needs its rate and rate date
        expense(conn, amount=1000)
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
    expense(conn, category="per_booking", booking_id=bid)
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("DELETE FROM bookings WHERE id = ?", (bid,))
    conn.execute("DELETE FROM expenses")
    conn.execute("DELETE FROM bookings WHERE id = ?", (bid,))
    assert conn.execute("SELECT COUNT(*) FROM booking_lines").fetchone()[0] == 0


def test_duplicate_line_rejected(conn):
    bid = booking(conn)
    line(conn, bid)
    with pytest.raises(sqlite3.IntegrityError):
        line(conn, bid)
    line(conn, bid, amount=101)


def test_exchange_rate_constraints(conn):
    conn.execute("INSERT INTO exchange_rates VALUES ('2026-01-01', 'COP', 3185010000)")
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("INSERT INTO exchange_rates VALUES ('2026-01-01', 'COP', 400000)")
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("INSERT INTO exchange_rates VALUES ('2026-01-02', 'COP', 0)")


def test_recurring_month_rules(conn):
    sql = (
        "INSERT INTO recurring_expenses (description, amount_minor, category, start_month,"
        " end_month) "
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
        "INSERT INTO recurring_expenses (description, amount_minor, category, start_month) "
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
    bid = booking(conn)  # 3 nights; the view sums the lines' USD columns
    usd = {"rate": 4_000_000_000, "rate_date": "2026-01-01"}
    line(
        conn,
        bid,
        amount=50_000_000,
        amount_usd=12_500,
        gross_usd=15_000,
        service_fee_usd=-2_500,
        **usd,
    )
    line(conn, bid, date="2026-01-05", amount=10, amount_usd=7, service_fee_usd=0, **usd)
    line(
        conn,
        bid,
        type="Co-Host payout",
        amount=-5_000_000,
        amount_usd=-1_250,
        service_fee_usd=0,
        **usd,
    )
    row = conn.execute("SELECT * FROM booking_totals WHERE booking_id = ?", (bid,)).fetchone()
    assert row["nights"] == 3
    assert row["net_payout"] == 12_507
    assert row["cohost_cost"] == 1_250
    assert row["gross"] == 15_000
    assert row["airbnb_fee"] == -2_500
    assert row["waiting"] == 0
    line(conn, bid, type="Adjustment", date="2026-01-06", cur="EUR", amount=1_000)
    row = conn.execute("SELECT * FROM booking_totals WHERE booking_id = ?", (bid,)).fetchone()
    assert row["waiting"] == 1 and row["net_payout"] == 12_507


def test_migration_keeps_peso_amounts_as_waiting_originals(tmp_path):
    """Books of version 3 (whole pesos) become COP originals waiting for a rate."""
    old = tmp_path / "migrations"
    old.mkdir()
    for entry in (resources.files("rios_de_asia_accounting.storage") / "migrations").iterdir():
        if entry.name[:4] in ("0001", "0002", "0003"):
            shutil.copyfile(entry, old / entry.name)
    c = connect(tmp_path / "old.db")
    migrate(c, migrations_dir=old)
    bid = booking(c)
    line(c, bid, cur="USD", amount=10_000, rate=385025, amount_cop=385_025)
    c.execute(
        "INSERT INTO recurring_expenses (id, description, amount, category, start_month)"
        " VALUES (1, 'admin', 450000, 'fixed', '2026-01')"
    )
    c.execute(
        "INSERT INTO expenses (date, amount, category, recurring_expense_id)"
        " VALUES ('2026-01-01', 450000, 'fixed', 1)"
    )
    c.execute("INSERT INTO exchange_rates VALUES ('2026-01-01', 'USD', 385025)")
    c.execute("INSERT INTO settings VALUES ('long_term_rent_cop_per_month', '3000000')")

    assert migrate(c) == 1
    e = c.execute("SELECT * FROM expenses").fetchone()
    assert (e["amount"], e["original_minor"], e["currency"], e["rate"]) == (
        None,
        45_000_000,
        "COP",
        None,
    )
    assert e["recurring_expense_id"] == 1
    r = c.execute("SELECT amount_minor, currency FROM recurring_expenses").fetchone()
    assert tuple(r) == (45_000_000, "COP")
    ln = c.execute("SELECT * FROM booking_lines").fetchone()
    assert "amount_cop" not in ln.keys()
    assert (ln["amount_minor"], ln["currency"], ln["rate"], ln["amount_usd"]) == (
        10_000,
        "USD",
        None,
        None,
    )
    assert c.execute("SELECT waiting FROM booking_totals").fetchone()[0] == 1
    assert c.execute("SELECT COUNT(*) FROM exchange_rates").fetchone()[0] == 0
    settings = dict(c.execute("SELECT key, value FROM settings").fetchall())
    assert "long_term_rent_cop_per_month" not in settings
    assert json.loads(settings["long_term_rent_entered"]) == {
        "original_minor": 300_000_000,
        "currency": "COP",
        "date": None,
        "rate": None,
        "rate_date": None,
    }


def test_blocked_days_table_is_gone(conn):
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    assert "blocked_days" not in tables
