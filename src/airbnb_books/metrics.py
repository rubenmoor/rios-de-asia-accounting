"""Metrics over the per-day view: list[Day] + a date range + settings → numbers.

Pure: no database, no clock. Money is whole COP (`int`), rounded half away from zero;
ratios are `float`; a figure that cannot be computed is None.
"""

from dataclasses import dataclass
from datetime import date, timedelta
from fractions import Fraction

from airbnb_books.allocation import days_in_month, split
from airbnb_books.model import Day, Settings

COST_COLUMNS = (
    "cost_fixed",
    "cost_per_night",
    "cost_per_booking",
    "cost_maintenance",
    "cost_capex",
    "cost_tax",
)


@dataclass(frozen=True)
class DateRange:
    """From `start` to `end`, both inclusive; empty when end < start."""

    start: date
    end: date

    def __contains__(self, day: date) -> bool:
        return self.start <= day <= self.end


def custom(start: date, end: date) -> DateRange:
    return DateRange(start, end)


def month_range(year: int, month: int) -> DateRange:
    return DateRange(date(year, month, 1), date(year, month, days_in_month(year, month)))


def standard_ranges(today: date, first_day: date) -> dict[str, DateRange]:
    """All-time, last 30 days, last 90 days and the current month, clipped to first_day..today."""

    def clipped(start: date) -> DateRange:
        return DateRange(max(start, first_day), today)

    return {
        "all_time": clipped(first_day),
        "last_30": clipped(today - timedelta(days=29)),
        "last_90": clipped(today - timedelta(days=89)),
        "this_month": clipped(today.replace(day=1)),
    }


def round_div(num: int, den: int) -> int:
    """num / den rounded half away from zero, in integers (den > 0)."""
    rounded = (abs(num) * 2 + den) // (den * 2)
    return rounded if num >= 0 else -rounded


def _ratio(num: int, den: int) -> int | None:
    return round_div(num, den) if den else None


def benchmark_part(day: date, monthly: int) -> int:
    """The share of `monthly` that falls on `day`, split like a fixed cost over its month."""
    return split(monthly, days_in_month(day.year, day.month))[day.day - 1]


@dataclass
class Metrics:
    available_nights: int
    occupied_nights: int
    income: int
    cost_fixed: int
    cost_per_night: int
    cost_per_booking: int
    cost_maintenance: int
    cost_capex: int
    cost_tax: int
    total_cost: int
    profit: int
    minutes: int
    occupancy: float | None
    adr: int | None
    revpar: int | None
    variable_cost_per_night: int | None
    break_even_occupancy: float | None
    benchmark: int
    profit_vs_long_term: int
    profit_per_hour: int | None
    own_time_value: int
    profit_after_own_time: int


def summarize(days: list[Day], rng: DateRange, settings: Settings) -> Metrics:
    selected = [day for day in days if day.date in rng]
    available = sum(day.available for day in selected)
    occupied = sum(day.occupied for day in selected)
    income = sum(day.income for day in selected)
    costs = {column: sum(getattr(day, column) for day in selected) for column in COST_COLUMNS}
    total_cost = sum(costs.values())
    profit = income - total_cost
    minutes = sum(day.minutes for day in selected)
    variable = costs["cost_per_night"] + costs["cost_per_booking"]

    break_even = None
    if available and occupied:
        fixed = (
            costs["cost_fixed"]
            + costs["cost_maintenance"]
            + costs["cost_capex"]
            + costs["cost_tax"]
        )
        margin = Fraction(income - variable, occupied)  # ADR − variable cost per night
        if margin > 0:
            break_even = float(Fraction(fixed, available) / margin)

    monthly = settings.long_term_rent_cop_per_month
    benchmark = sum(benchmark_part(day.date, monthly) for day in selected) if monthly else 0
    own_time_value = round_div(minutes * settings.hourly_value_cop, 60)

    return Metrics(
        available_nights=available,
        occupied_nights=occupied,
        income=income,
        **costs,
        total_cost=total_cost,
        profit=profit,
        minutes=minutes,
        occupancy=occupied / available if available else None,
        adr=_ratio(income, occupied),
        revpar=_ratio(income, available),
        variable_cost_per_night=_ratio(variable, occupied),
        break_even_occupancy=break_even,
        benchmark=benchmark,
        profit_vs_long_term=profit - benchmark,
        profit_per_hour=_ratio(profit * 60, minutes),
        own_time_value=own_time_value,
        profit_after_own_time=profit - own_time_value,
    )
