from datetime import date
from fractions import Fraction

import pytest

from rios_de_asia_accounting.allocation import date_range
from rios_de_asia_accounting.metrics import (
    DateRange,
    capex_book_value,
    custom,
    expense_breakdown,
    month_range,
    rolling_90,
    standard_ranges,
    summarize,
)
from rios_de_asia_accounting.model import Day, Expense, Settings


def d(s):
    return date.fromisoformat(s)


def ten_days():
    """2026-01-01..10: nights 1-4 and 6-7 booked at 100 000.

    Fixed 10 000 a day, 5 000 per occupied night, 20 000 per booking on check-in.
    """
    days = []
    for i, day in enumerate(date_range(d("2026-01-01"), d("2026-01-10")), start=1):
        occupied = i in (1, 2, 3, 4, 6, 7)
        days.append(
            Day(
                date=day,
                occupied=occupied,
                income=100_000 if occupied else 0,
                cost_fixed=10_000,
                cost_per_night=5_000 if occupied else 0,
                cost_per_booking=20_000 if i in (1, 6) else 0,
            )
        )
    return days


ALL = custom(d("2026-01-01"), d("2026-01-10"))


def test_ten_day_example():
    m = summarize(ten_days(), ALL, Settings())
    assert (m.available_nights, m.occupied_nights) == (10, 6)
    assert m.income == 600_000
    assert (m.cost_fixed, m.cost_per_night, m.cost_per_booking) == (100_000, 30_000, 40_000)
    assert m.total_cost == 170_000
    assert m.profit == 430_000
    assert m.occupancy == pytest.approx(6 / 10)
    assert m.adr == 100_000
    assert m.revpar == 60_000
    assert m.variable_cost_per_night == 11_667  # 70 000 / 6
    # (100 000 / 10) / (100 000 − 70 000 / 6) = 6 / 53
    assert m.break_even_occupancy == float(Fraction(6, 53))


def test_break_even_none_when_adr_not_above_variable_cost():
    days = [Day(d("2026-01-01"), occupied=True, income=10_000, cost_per_night=10_000)]
    days.append(Day(d("2026-01-02"), cost_fixed=5_000))
    m = summarize(days, custom(d("2026-01-01"), d("2026-01-02")), Settings())
    assert m.adr == m.variable_cost_per_night == 10_000
    assert m.break_even_occupancy is None


def test_no_occupancy():
    days = [Day(day, cost_fixed=1_000) for day in date_range(d("2026-01-01"), d("2026-01-05"))]
    m = summarize(days, custom(d("2026-01-01"), d("2026-01-05")), Settings())
    assert m.occupancy == 0
    assert m.adr is None and m.variable_cost_per_night is None
    assert m.break_even_occupancy is None
    assert m.revpar == 0
    assert m.profit == -5_000


def test_benchmark_full_month():
    days = [Day(day) for day in date_range(d("2024-02-01"), d("2024-02-29"))]
    m = summarize(days, month_range(2024, 2), Settings(long_term_rent_usd=2_900_001))
    assert m.benchmark == 2_900_001
    assert m.profit_vs_long_term == -2_900_001


def test_benchmark_across_february_march_of_a_leap_year():
    days = [Day(day, income=50_000) for day in date_range(d("2024-02-01"), d("2024-03-31"))]
    m = summarize(
        days,
        custom(d("2024-02-28"), d("2024-03-02")),
        Settings(long_term_rent_usd=290_000),
    )
    # February: 290 000 / 29 = 10 000 a day; March: 290 000 / 31 = 9 354 rest 26 → 9 355
    assert m.benchmark == 2 * 10_000 + 2 * 9_355
    assert m.profit_vs_long_term == 200_000 - 38_710


def assert_empty(m):
    assert (m.available_nights, m.occupied_nights, m.income, m.total_cost, m.profit) == (0,) * 5
    assert (m.benchmark, m.profit_vs_long_term) == (0,) * 2
    assert m.occupancy is m.adr is m.revpar is m.variable_cost_per_night is None
    assert m.break_even_occupancy is None


def test_empty_range():
    settings = Settings(long_term_rent_usd=900_000)
    assert_empty(summarize(ten_days(), custom(d("2026-01-05"), d("2026-01-04")), settings))


def test_range_before_first_day():
    settings = Settings(long_term_rent_usd=900_000)
    assert_empty(summarize(ten_days(), month_range(2025, 12), settings))


def test_last_30_days_with_fewer_days():
    ranges = standard_ranges(d("2026-01-10"), d("2026-01-01"))
    assert ranges["last_30"] == ranges["last_90"] == ranges["all_time"] == ALL
    assert summarize(ten_days(), ranges["last_30"], Settings()).profit == 430_000


def test_standard_ranges():
    ranges = standard_ranges(d("2026-10-23"), d("2025-01-15"))
    assert ranges["all_time"] == DateRange(d("2025-01-15"), d("2026-10-23"))
    assert ranges["last_30"] == DateRange(d("2026-09-24"), d("2026-10-23"))
    assert ranges["last_90"] == DateRange(d("2026-07-26"), d("2026-10-23"))
    assert ranges["this_month"] == DateRange(d("2026-10-01"), d("2026-10-23"))


def test_current_month_on_the_first():
    ranges = standard_ranges(d("2026-02-01"), d("2026-01-01"))
    assert ranges["this_month"] == DateRange(d("2026-02-01"), d("2026-02-01"))
    days = [Day(day, cost_fixed=100) for day in date_range(d("2026-01-01"), d("2026-02-01"))]
    m = summarize(days, ranges["this_month"], Settings())
    assert (m.available_nights, m.total_cost) == (1, 100)


def long_history(n):
    """n days from 2026-01-01 with varying occupancy, income and costs."""
    return [
        Day(
            date=day,
            occupied=i % 3 != 0 and i % 17 != 0,
            income=(40_000 + i * 100) if i % 3 != 0 and i % 17 != 0 else 0,
            cost_fixed=1_000 + i,
            cost_per_night=500 if i % 3 != 0 else 0,
        )
        for i, day in enumerate(
            date_range(
                d("2026-01-01"), d("2026-01-01").fromordinal(d("2026-01-01").toordinal() + n - 1)
            )
        )
    ]


def check_point(days, point, index):
    window = days[index - 89 : index + 1]
    m = summarize(days, custom(window[0].date, window[-1].date), Settings())
    assert point.date == window[-1].date
    assert (point.revpar, point.adr, point.occupancy) == (m.revpar, m.adr, m.occupancy)


def test_rolling_needs_90_days():
    assert rolling_90(long_history(89)) == []


def test_rolling_on_exactly_90_days():
    days = long_history(90)
    points = rolling_90(days)
    assert len(points) == 1
    check_point(days, points[0], 89)


def test_rolling_on_200_days():
    days = long_history(200)
    points = rolling_90(days)
    assert len(points) == 111
    for index in (89, 90, 120, 199):
        check_point(days, points[index - 89], index)


def test_expense_breakdown():
    rows = expense_breakdown(ten_days(), ALL)
    assert [r[0] for r in rows] == [
        "cost_fixed",
        "cost_per_night",
        "cost_per_booking",
        "cost_maintenance",
        "cost_capex",
        "cost_tax",
    ]
    assert [r[1] for r in rows] == [100_000, 30_000, 40_000, 0, 0, 0]
    assert sum(r[1] for r in rows) == summarize(ten_days(), ALL, Settings()).total_cost
    assert sum(r[2] for r in rows) == pytest.approx(1)
    assert rows[0][2] == pytest.approx(100 / 170)


def test_expense_breakdown_without_costs():
    days = [Day(d("2026-01-01"), income=5_000)]
    assert all(share is None for _, _, share in expense_breakdown(days, ALL))


def capex(on, amount, life):
    return Expense(date=d(on), amount=amount, category="capex", useful_life_days=life)


def test_capex_book_value():
    bought = capex("2028-02-27", 1_000_001, 4)  # parts 250 001, 250 000, 250 000, 250 000
    assert capex_book_value([bought], d("2028-02-26")) == 0  # not yet bought
    assert capex_book_value([bought], d("2028-02-27")) == 750_000
    assert capex_book_value([bought], d("2028-02-29")) == 250_000  # leap day counts as a day
    assert capex_book_value([bought], d("2028-03-01")) == 0
    assert capex_book_value([bought], d("2030-01-01")) == 0


def test_capex_book_value_two_purchases_and_other_categories():
    expenses = [
        capex("2026-01-01", 1_000, 10),
        capex("2026-01-05", 600, 3),
        Expense(date=d("2026-01-01"), amount=999, category="fixed"),
    ]
    # first: 1 000 − 5 × 100 = 500; second: 600 − 200 = 400
    assert capex_book_value(expenses, d("2026-01-05")) == 900
