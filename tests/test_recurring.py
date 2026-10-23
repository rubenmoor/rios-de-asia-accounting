from datetime import date

import pytest

from rios_de_asia_accounting.model import Booking, BookingLine, Expense, RecurringExpense
from rios_de_asia_accounting.recurring import due_expenses, generate_recurring, load_days
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.storage.db import connect, migrate


@pytest.fixture
def conn(tmp_path):
    c = connect(tmp_path / "t.db")
    migrate(c)
    return c


def d(s):
    return date.fromisoformat(s)


def tpl(start, end=None, id=1):
    return RecurringExpense("wifi", 100, "fixed", start, end, id)


def test_due_months():
    got = due_expenses([tpl("2026-01", "2026-03")], d("2026-10-23"))
    assert [e.date for e in got] == [d("2026-01-01"), d("2026-02-01"), d("2026-03-01")]
    assert (got[0].amount, got[0].category, got[0].description) == (100, "fixed", "wifi")
    assert got[0].recurring_expense_id == 1


def test_open_end_stops_at_today_month():
    got = due_expenses([tpl("2026-08")], d("2026-10-23"))
    assert [e.date.month for e in got] == [8, 9, 10]


def test_future_start_nothing():
    assert due_expenses([tpl("2026-11")], d("2026-10-23")) == []


def test_december_to_january():
    got = due_expenses([tpl("2025-12")], d("2026-01-15"))
    assert [e.date for e in got] == [d("2025-12-01"), d("2026-01-01")]


def test_generate_idempotent_keep_edit_recreate_deleted(conn):
    rid = repo.create_recurring_expense(conn, RecurringExpense("wifi", 100, "fixed", "2026-08"))
    assert generate_recurring(conn, d("2026-10-23")) == 3
    assert generate_recurring(conn, d("2026-10-23")) == 0
    rows = repo.list_expenses_of_recurring(conn, rid)
    rows[0].amount = 999
    repo.update_expense(conn, rows[0])
    conn.execute("DELETE FROM expenses WHERE id = ?", (rows[1].id,))
    assert generate_recurring(conn, d("2026-10-23")) == 1
    assert [e.amount for e in repo.list_expenses_of_recurring(conn, rid)] == [999, 100, 100]


def test_load_days(conn):
    repo.create_recurring_expense(
        conn, RecurringExpense("rent", 3100, "fixed", "2026-01", "2026-01")
    )
    repo.create_expense(conn, Expense(d("2026-01-10"), 1000, "capex", useful_life_days=100))
    bid = repo.create_booking(conn, Booking(d("2026-01-05"), d("2026-01-07")))
    repo.add_line(conn, BookingLine(bid, "Reservation", d("2026-01-05"), "COP", 20_000))
    days = load_days(conn, d("2026-01-31"))
    assert len(days) == 31 and days[0].date == d("2026-01-01")
    assert sum(x.cost_fixed for x in days) == 3100
    assert sum(x.income for x in days) == 200
    assert sum(x.occupied for x in days) == 2
    assert sum(x.cost_capex for x in days) == 22 * 10
