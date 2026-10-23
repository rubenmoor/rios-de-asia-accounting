from datetime import date
from fractions import Fraction

import pytest

from airbnb_books.allocation import date_range
from airbnb_books.metrics import DateRange, custom, month_range, standard_ranges, summarize
from airbnb_books.model import Day, Settings


def d(s):
    return date.fromisoformat(s)


def ten_days():
    """2026-01-01..10: nights 1-4 and 6-7 booked at 100 000, day 10 blocked.

    Fixed 10 000 a day, 5 000 per occupied night, 20 000 per booking on check-in.
    """
    days = []
    for i, day in enumerate(date_range(d("2026-01-01"), d("2026-01-10")), start=1):
        occupied = i in (1, 2, 3, 4, 6, 7)
        days.append(
            Day(
                date=day,
                available=i != 10,
                occupied=occupied,
                income=100_000 if occupied else 0,
                cost_fixed=10_000,
                cost_per_night=5_000 if occupied else 0,
                cost_per_booking=20_000 if i in (1, 6) else 0,
                minutes=45 if i in (1, 2) else 0,
            )
        )
    return days


ALL = custom(d("2026-01-01"), d("2026-01-10"))


def test_ten_day_example():
    m = summarize(ten_days(), ALL, Settings())
    assert (m.available_nights, m.occupied_nights) == (9, 6)
    assert m.income == 600_000
    assert (m.cost_fixed, m.cost_per_night, m.cost_per_booking) == (100_000, 30_000, 40_000)
    assert m.total_cost == 170_000
    assert m.profit == 430_000
    assert m.occupancy == pytest.approx(6 / 9)
    assert m.adr == 100_000
    assert m.revpar == 66_667  # 600 000 / 9 = 66 666.67
    assert m.variable_cost_per_night == 11_667  # 70 000 / 6
    # (100 000 / 9) / (100 000 − 70 000 / 6) = 20 / 159
    assert m.break_even_occupancy == float(Fraction(20, 159))


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
    m = summarize(days, month_range(2024, 2), Settings(long_term_rent_cop_per_month=2_900_001))
    assert m.benchmark == 2_900_001
    assert m.profit_vs_long_term == -2_900_001


def test_benchmark_across_february_march_of_a_leap_year():
    days = [Day(day, income=50_000) for day in date_range(d("2024-02-01"), d("2024-03-31"))]
    m = summarize(
        days,
        custom(d("2024-02-28"), d("2024-03-02")),
        Settings(long_term_rent_cop_per_month=290_000),
    )
    # February: 290 000 / 29 = 10 000 a day; March: 290 000 / 31 = 9 354 rest 26 → 9 355
    assert m.benchmark == 2 * 10_000 + 2 * 9_355
    assert m.profit_vs_long_term == 200_000 - 38_710


def test_profit_per_hour_and_own_time():
    m = summarize(ten_days(), ALL, Settings(hourly_value_cop=20_000))
    assert m.minutes == 90
    assert m.profit_per_hour == 286_667  # 430 000 * 60 / 90
    assert m.own_time_value == 30_000
    assert m.profit_after_own_time == 400_000

    m = summarize(
        ten_days(), custom(d("2026-01-03"), d("2026-01-10")), Settings(hourly_value_cop=20_000)
    )
    assert m.minutes == 0
    assert m.profit_per_hour is None
    assert m.own_time_value == 0
    assert m.profit_after_own_time == m.profit


def assert_empty(m):
    assert (m.available_nights, m.occupied_nights, m.income, m.total_cost, m.profit) == (0,) * 5
    assert (m.minutes, m.benchmark, m.profit_vs_long_term, m.own_time_value) == (0,) * 4
    assert m.occupancy is m.adr is m.revpar is m.variable_cost_per_night is None
    assert m.break_even_occupancy is None and m.profit_per_hour is None


def test_empty_range():
    settings = Settings(hourly_value_cop=20_000, long_term_rent_cop_per_month=900_000)
    assert_empty(summarize(ten_days(), custom(d("2026-01-05"), d("2026-01-04")), settings))


def test_range_before_first_day():
    settings = Settings(hourly_value_cop=20_000, long_term_rent_cop_per_month=900_000)
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
