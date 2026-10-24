from datetime import date

import pytest

from rios_de_asia_accounting.allocation import (
    allocate,
    date_range,
    days_in_month,
    months_between,
    split,
)
from rios_de_asia_accounting.model import Booking, Expense, Inputs, Settings, TimeEntry


def d(s):
    return date.fromisoformat(s)


def inputs(bookings=(), expenses=(), time_log=(), mode="check_in"):
    settings = Settings(per_booking_allocation=mode)
    return Inputs(list(bookings), list(expenses), list(time_log), settings)


def booking(check_in, check_out, net_payout, cohost_cost=0, id=None):
    return Booking(
        check_in=d(check_in),
        check_out=d(check_out),
        net_payout=net_payout,
        cohost_cost=cohost_cost,
        id=id,
    )


def expense(day, amount, category, booking_id=None, life=None):
    return Expense(d(day), amount, category, booking_id=booking_id, useful_life_days=life)


def total(days, column):
    return sum(getattr(day, column) for day in days)


def nonzero(days, column):
    return {day.date.isoformat(): getattr(day, column) for day in days if getattr(day, column)}


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


def test_default_start_is_earliest_input_and_time_log():
    days = allocate(
        inputs(
            [booking("2026-01-05", "2026-01-06", 10)],
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


@pytest.mark.parametrize(
    "dated, first, last, n",
    [
        ("2024-02-10", "2024-02-01", "2024-02-29", 29),
        ("2025-02-01", "2025-02-01", "2025-02-28", 28),
        ("2025-04-30", "2025-04-01", "2025-04-30", 30),
        ("2025-01-15", "2025-01-01", "2025-01-31", 31),
    ],
)
def test_fixed_covers_its_whole_month(dated, first, last, n):
    days = allocate(inputs(expenses=[expense(dated, 1000, "fixed")]), d("2025-12-31"))
    assert days[0].date == d(first)  # default start: the 1st, even if dated mid-month
    costs = nonzero(days, "cost_fixed")
    assert len(costs) == n
    assert min(costs) == first and max(costs) == last
    assert costs[first] == 1000 // n + 1 and costs[last] == 1000 // n
    assert total(days, "cost_fixed") == 1000


def test_fixed_stops_at_today():
    days = allocate(inputs(expenses=[expense("2025-04-01", 3000, "fixed")]), d("2025-04-10"))
    assert len(days) == 10
    assert total(days, "cost_fixed") == 1000  # 10 of 30 days of 100


def test_per_night_over_occupied_nights_of_its_month():
    days = allocate(
        inputs(
            # nights Mar 30, 31 (in March) and Apr 1 (not); Mar 10, 11
            [booking("2025-03-30", "2025-04-02", 0), booking("2025-03-10", "2025-03-12", 0)],
            [expense("2025-03-20", 1001, "per_night")],
        ),
        d("2025-12-31"),
    )
    assert nonzero(days, "cost_per_night") == {
        "2025-03-10": 251,
        "2025-03-11": 250,
        "2025-03-30": 250,
        "2025-03-31": 250,
    }
    assert total(days, "cost_per_night") == 1001


def test_per_night_counts_future_nights_and_falls_back_to_the_month():
    data = inputs(
        [booking("2025-03-05", "2025-03-06", 0), booking("2025-03-25", "2025-03-26", 0)],
        [expense("2025-03-01", 100, "per_night"), expense("2025-06-01", 300, "per_night")],
    )
    # today Mar 10: the future night of Mar 25 still takes its half
    assert nonzero(allocate(data, d("2025-03-10")), "cost_per_night") == {"2025-03-05": 50}
    days = allocate(data, d("2025-12-31"))
    june = {k: v for k, v in nonzero(days, "cost_per_night").items() if k.startswith("2025-06")}
    assert len(june) == 30 and set(june.values()) == {10}  # no nights in June: whole month
    assert total(days, "cost_per_night") == 400


def test_per_booking_on_check_in_and_spread_across_months():
    data = dict(
        bookings=[booking("2025-01-30", "2025-02-02", 0, cohost_cost=31, id=7)],
        expenses=[expense("2025-05-05", 300, "per_booking", booking_id=7)],  # date ignored
    )
    days = allocate(inputs(**data), d("2025-12-31"))
    assert nonzero(days, "cost_per_booking") == {"2025-01-30": 331}
    days = allocate(inputs(**data, mode="spread"), d("2025-12-31"))
    assert nonzero(days, "cost_per_booking") == {
        "2025-01-30": 100 + 11,
        "2025-01-31": 100 + 10,
        "2025-02-01": 100 + 10,
    }
    assert total(days, "cost_per_booking") == 331
    assert not nonzero(days, "cost_maintenance")


def test_cohost_cost_alone_in_both_modes():
    b = booking("2025-01-01", "2025-01-03", 1000, cohost_cost=200, id=1)
    days = allocate(inputs([b]), d("2025-01-31"))
    assert nonzero(days, "cost_per_booking") == {"2025-01-01": 200}
    days = allocate(inputs([b], mode="spread"), d("2025-01-31"))
    assert nonzero(days, "cost_per_booking") == {"2025-01-01": 100, "2025-01-02": 100}
    assert days[0].profit == 500 - 100


def test_capex_across_a_leap_day():
    data = inputs(expenses=[expense("2024-02-27", 1000, "capex", life=3)])
    days = allocate(data, d("2024-12-31"))
    assert nonzero(days, "cost_capex") == {"2024-02-27": 334, "2024-02-28": 333, "2024-02-29": 333}
    days = allocate(
        inputs(expenses=[expense("2024-01-01", 3_650_000, "capex", life=3650)]), d("2034-01-01")
    )
    assert total(days, "cost_capex") == 3_650_000
    assert nonzero(days, "cost_capex")["2024-02-29"] == 1000
    assert max(nonzero(days, "cost_capex")) == "2033-12-28"  # 3650 days incl. 3 leap days
    # partway: only the days up to today
    days = allocate(
        inputs(expenses=[expense("2024-01-01", 3_650_000, "capex", life=3650)]), d("2024-01-10")
    )
    assert total(days, "cost_capex") == 10_000


def test_capex_starting_before_start():
    data = inputs(expenses=[expense("2025-01-01", 1000, "capex", life=10)])
    days = allocate(data, d("2025-12-31"), start=d("2025-01-06"))
    assert days[0].date == d("2025-01-06")
    assert total(days, "cost_capex") == 500
    assert total(allocate(data, d("2025-12-31")), "cost_capex") == 1000


def test_maintenance_and_tax_on_their_date():
    data = inputs(
        expenses=[
            expense("2025-03-03", 500, "maintenance"),
            expense("2025-03-05", 700, "tax"),
            expense("2025-03-05", 1, "tax", booking_id=4),  # a booking link changes nothing
        ]
    )
    days = allocate(data, d("2025-03-31"))
    assert days[0].date == d("2025-03-03")
    assert nonzero(days, "cost_maintenance") == {"2025-03-03": 500}
    assert nonzero(days, "cost_tax") == {"2025-03-05": 701}
    assert total(days, "cost_tax") == 701
    assert by_date(days)["2025-03-05"].profit == -701
