from datetime import date

import pytest

from rios_de_asia_accounting.model import (
    BlockedDay,
    Booking,
    BookingLine,
    Expense,
    RecurringExpense,
    Settings,
    TimeEntry,
)
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.storage.db import connect, migrate
from rios_de_asia_accounting.storage.repo import ValidationError


@pytest.fixture
def conn(tmp_path):
    c = connect(tmp_path / "t.db")
    migrate(c)
    return c


def d(s):
    return date.fromisoformat(s)


def test_expense_round_trip_and_range(conn):
    e = Expense(d("2026-01-05"), 1000, "capex", useful_life_days=365, description="sofa")
    eid = repo.create_expense(conn, e)
    repo.create_expense(conn, Expense(d("2026-02-05"), 50, "fixed"))
    assert repo.get_expense(conn, eid) == e
    assert len(repo.list_expenses(conn)) == 2
    assert [x.amount for x in repo.list_expenses(conn, d("2026-02-01"), d("2026-03-01"))] == [50]
    assert repo.list_expenses(conn, end=d("2026-01-05")) == []
    e.amount = 2000
    repo.update_expense(conn, e)
    assert repo.get_expense(conn, eid).amount == 2000
    repo.delete_expense(conn, eid)
    assert repo.get_expense(conn, eid) is None


def test_recurring_round_trip_and_generated_dedup(conn):
    r = RecurringExpense("rent", 900, "fixed", "2026-01")
    rid = repo.create_recurring_expense(conn, r)
    assert repo.get_recurring_expense(conn, rid) == r
    r.end_month = "2026-06"
    repo.update_recurring_expense(conn, r)
    assert repo.list_recurring_expenses(conn) == [r]

    gen = Expense(d("2026-01-01"), 900, "fixed", recurring_expense_id=rid)
    assert repo.insert_generated_expense(conn, gen) is True
    again = Expense(d("2026-01-01"), 123, "fixed", recurring_expense_id=rid)
    assert repo.insert_generated_expense(conn, again) is False
    assert [x.amount for x in repo.list_expenses_of_recurring(conn, rid)] == [900]

    repo.delete_recurring_expense(conn, rid)  # generated rows stay, unlinked
    (left,) = repo.list_expenses(conn)
    assert left.recurring_expense_id is None


def test_blocked_days(conn):
    repo.set_blocked_day(conn, BlockedDay(d("2026-01-02"), "owner", "mine"))
    repo.set_blocked_day(conn, BlockedDay(d("2026-01-03"), "buffer"))
    repo.set_blocked_day(conn, BlockedDay(d("2026-01-02"), "other"))
    assert repo.get_blocked_day(conn, d("2026-01-02")) == BlockedDay(d("2026-01-02"), "other", None)
    assert len(repo.list_blocked_days(conn)) == 2
    assert [b.date for b in repo.list_blocked_days(conn, d("2026-01-03"))] == [d("2026-01-03")]
    repo.delete_blocked_day(conn, d("2026-01-02"))
    assert repo.get_blocked_day(conn, d("2026-01-02")) is None


def test_time_entries(conn):
    t = TimeEntry(d("2026-01-02"), 90, description="cleaning")
    tid = repo.create_time_entry(conn, t)
    assert repo.get_time_entry(conn, tid) == t
    t.minutes = 45
    repo.update_time_entry(conn, t)
    assert [x.minutes for x in repo.list_time_entries(conn, d("2026-01-01"), d("2026-01-03"))] == [
        45
    ]
    repo.delete_time_entry(conn, tid)
    assert repo.list_time_entries(conn) == []


def test_settings_defaults_and_round_trip(conn):
    assert repo.load_settings(conn) == Settings()
    s = Settings(
        hourly_value_cop=20_000,
        long_term_rent_cop_per_month=1_500_000,
        per_booking_allocation="spread",
        property_listings=["Casa Río", "Loft"],
        backup_keep=10,
    )
    repo.save_settings(conn, s)
    assert repo.load_settings(conn) == s
    s.backup_keep = 5
    repo.save_settings(conn, s)
    assert repo.load_settings(conn).backup_keep == 5


def test_settings_validation(conn):
    with pytest.raises(ValidationError, match="check_in"):
        repo.save_settings(conn, Settings(per_booking_allocation="x"))


def test_constraint_violations_become_validation_errors(conn):
    with pytest.raises(ValidationError, match="booking"):
        repo.create_expense(conn, Expense(d("2026-01-01"), 1, "per_booking"))
    with pytest.raises(ValidationError, match="useful life"):
        repo.create_expense(conn, Expense(d("2026-01-01"), 1, "capex"))
    with pytest.raises(ValidationError, match="minutes"):
        repo.create_time_entry(conn, TimeEntry(d("2026-01-01"), 0))
    with pytest.raises(ValidationError):
        repo.create_recurring_expense(conn, RecurringExpense("x", 1, "capex", "2026-01"))

    b = Booking(d("2026-01-01"), d("2026-01-03"), airbnb_code="A")
    bid = repo.create_booking(conn, b)
    with pytest.raises(ValidationError, match="Airbnb code"):
        repo.create_booking(conn, Booking(d("2026-02-01"), d("2026-02-03"), airbnb_code="A"))
    with pytest.raises(ValidationError, match="check-out"):
        repo.create_booking(conn, Booking(d("2026-02-03"), d("2026-02-03")))
    repo.create_expense(conn, Expense(d("2026-01-01"), 1, "per_booking", booking_id=bid))
    with pytest.raises(ValidationError, match="still used"):
        repo.delete_booking(conn, bid)


def test_load_inputs(conn):
    bid = repo.create_booking(
        conn, Booking(d("2026-01-01"), d("2026-01-04"), airbnb_code="A"), manual_amount_cop=300_000
    )
    repo.add_line(conn, BookingLine(bid, "Co-Host payout", d("2026-01-04"), "COP", -3_000_000))
    repo.create_expense(conn, Expense(d("2026-01-02"), 10, "fixed"))
    repo.set_blocked_day(conn, BlockedDay(d("2026-01-10"), "buffer"))
    repo.create_time_entry(conn, TimeEntry(d("2026-01-02"), 60, booking_id=bid))
    repo.save_settings(conn, Settings(hourly_value_cop=5))
    inputs = repo.load_inputs(conn)
    (b,) = inputs.bookings
    assert (b.net_payout, b.cohost_cost, b.nights) == (300_000, 30_000, 3)
    assert [e.amount for e in inputs.expenses] == [10]
    assert [x.date for x in inputs.blocked_days] == [d("2026-01-10")]
    assert [t.minutes for t in inputs.time_log] == [60]
    assert inputs.settings.hourly_value_cop == 5
