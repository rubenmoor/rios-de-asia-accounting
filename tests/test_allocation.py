from datetime import date

import pytest

from airbnb_books.allocation import allocate, date_range, days_in_month, months_between, split
from airbnb_books.model import BlockedDay, Booking, Inputs, Settings, TimeEntry


def d(s):
    return date.fromisoformat(s)


def inputs(bookings=(), expenses=(), blocked=(), time_log=()):
    return Inputs(list(bookings), list(expenses), list(blocked), list(time_log), Settings())


def booking(check_in, check_out, net_payout):
    return Booking(check_in=d(check_in), check_out=d(check_out), net_payout=net_payout)


def by_date(days):
    return {day.date.isoformat(): day for day in days}


@pytest.mark.parametrize("amount", [-1001, -7, -1, 0, 1, 2, 5, 99, 100, 1000, 123457])
@pytest.mark.parametrize("n", [1, 2, 3, 7, 28, 29, 30, 31, 365, 1000])
def test_split_sums_exactly(amount, n):
    parts = split(amount, n)
    assert len(parts) == n
    assert sum(parts) == amount
    assert max(parts) - min(parts) <= 1
    assert parts == sorted(parts, reverse=True)  # the extra units go to the first days


def test_split_examples():
    assert split(10, 3) == [4, 3, 3]
    assert split(2, 5) == [1, 1, 0, 0, 0]
    assert split(-10, 3) == [-3, -3, -4]


def test_calendar_helpers():
    assert days_in_month(2024, 2) == 29
    assert days_in_month(2025, 2) == 28
    assert date_range(d("2025-12-30"), d("2026-01-02"))[-1] == d("2026-01-02")
    assert len(date_range(d("2025-12-30"), d("2026-01-02"))) == 4
    assert date_range(d("2025-01-02"), d("2025-01-01")) == []
    assert months_between(d("2025-11-15"), d("2026-02-01")) == [
        d("2025-11-01"),
        d("2025-12-01"),
        d("2026-01-01"),
        d("2026-02-01"),
    ]


def test_empty_inputs():
    assert allocate(inputs(), d("2026-01-01")) == []


def test_stay_across_month_and_year_end():
    days = allocate(inputs([booking("2025-12-30", "2026-01-02", 100)]), d("2026-01-10"))
    rows = by_date(days)
    assert days[0].date == d("2025-12-30")  # default start: the check-in
    assert days[-1].date == d("2026-01-10")
    assert [rows[k].income for k in ("2025-12-30", "2025-12-31", "2026-01-01")] == [34, 33, 33]
    assert all(rows[k].occupied for k in ("2025-12-30", "2025-12-31", "2026-01-01"))
    assert not rows["2026-01-02"].occupied  # check-out day is not a night
    assert sum(day.income for day in days) == 100


def test_stay_running_past_today():
    days = allocate(inputs([booking("2026-01-01", "2026-01-05", 1000)]), d("2026-01-02"))
    assert [day.date for day in days] == [d("2026-01-01"), d("2026-01-02")]
    assert [day.income for day in days] == [250, 250]  # split over all 4 nights


def test_future_booking_counts_nothing():
    days = allocate(
        inputs([booking("2026-03-01", "2026-03-04", 900)]),
        d("2026-01-31"),
        start=d("2026-01-01"),
    )
    assert len(days) == 31
    assert not any(day.occupied or day.income for day in days)
    # with the default start the view begins after today: no rows at all
    assert allocate(inputs([booking("2026-03-01", "2026-03-04", 900)]), d("2026-01-31")) == []


def test_overlapping_bookings():
    days = allocate(
        inputs([booking("2026-01-01", "2026-01-03", 200), booking("2026-01-02", "2026-01-04", 50)]),
        d("2026-01-05"),
    )
    rows = by_date(days)
    assert [rows[k].income for k in ("2026-01-01", "2026-01-02", "2026-01-03")] == [100, 125, 25]
    assert [day.occupied for day in days] == [True, True, True, False, False]


def test_blocked_and_booked_same_day():
    days = allocate(
        inputs(
            [booking("2026-01-02", "2026-01-03", 10)],
            blocked=[
                BlockedDay(d("2026-01-01"), "owner"),
                BlockedDay(d("2026-01-02"), "owner"),
            ],
        ),
        d("2026-01-03"),
    )
    assert [(day.available, day.occupied) for day in days] == [
        (False, False),
        (True, True),  # a booking wins over a block
        (True, False),
    ]


def test_default_start_is_earliest_input_and_time_log():
    days = allocate(
        inputs(
            [booking("2026-01-05", "2026-01-06", 10)],
            blocked=[BlockedDay(d("2026-01-03"), "repair")],
            time_log=[
                TimeEntry(d("2026-01-02"), 30),
                TimeEntry(d("2026-01-02"), 45),
                TimeEntry(d("2025-12-31"), 1),
            ],
        ),
        d("2026-01-06"),
    )
    rows = by_date(days)
    assert days[0].date == d("2025-12-31")
    assert rows["2026-01-02"].minutes == 75
    assert sum(day.minutes for day in days) == 76


def test_explicit_start_drops_earlier_days_and_profit():
    days = allocate(
        inputs([booking("2026-01-01", "2026-01-05", 400)]),
        d("2026-01-04"),
        start=d("2026-01-03"),
    )
    assert [(day.date, day.income) for day in days] == [
        (d("2026-01-03"), 100),
        (d("2026-01-04"), 100),
    ]
    assert days[0].profit == 100
