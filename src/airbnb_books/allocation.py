"""The per-day view: bookings, expenses, blocked days and time log → list[Day].

Pure: no database, no clock (`today` is a parameter). Every amount is split over its
full span with `split`, so the days sum exactly to it; only days up to today are kept.
"""

import calendar
from datetime import date, timedelta

from airbnb_books.model import Day, Inputs


def split(amount: int, n: int) -> list[int]:
    """Split `amount` over `n` parts: each gets amount // n, the first amount % n one more."""
    if n <= 0:
        raise ValueError("split needs at least one part")
    base, rest = divmod(amount, n)
    return [base + 1] * rest + [base] * (n - rest)


def days_in_month(year: int, month: int) -> int:
    return calendar.monthrange(year, month)[1]


def date_range(first: date, last: date) -> list[date]:
    """All dates from `first` to `last`, both inclusive (empty if last < first)."""
    return [first + timedelta(days=i) for i in range((last - first).days + 1)]


def month_days(day: date) -> list[date]:
    """All dates of the calendar month of `day`."""
    first = day.replace(day=1)
    return date_range(first, first.replace(day=days_in_month(day.year, day.month)))


def months_between(first: date, last: date) -> list[date]:
    """The first day of every month from the month of `first` to that of `last`, inclusive."""
    months = []
    year, month = first.year, first.month
    while (year, month) <= (last.year, last.month):
        months.append(date(year, month, 1))
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)
    return months


def _spread(days: dict[date, Day], dates: list[date], amount: int, column: str) -> None:
    """Add `amount`, split over `dates`, to `column` of the days that are in the view."""
    for day, part in zip(dates, split(amount, len(dates)), strict=True):
        if day in days:
            setattr(days[day], column, getattr(days[day], column) + part)


def _earliest(inputs: Inputs) -> date | None:
    dates = [
        *(b.check_in for b in inputs.bookings),
        *(e.date for e in inputs.expenses),
        *(b.date for b in inputs.blocked_days),
        *(t.date for t in inputs.time_log),
    ]
    return min(dates, default=None)


def allocate(inputs: Inputs, today: date, start: date | None = None) -> list[Day]:
    """One Day per date from `start` (default: earliest input date) to `today` inclusive."""
    if start is None:
        start = _earliest(inputs)
        if start is None:
            return []
    days = {d: Day(date=d) for d in date_range(start, today)}

    for blocked in inputs.blocked_days:
        if blocked.date in days:
            days[blocked.date].available = False

    for booking in inputs.bookings:
        nights = date_range(booking.check_in, booking.check_out - timedelta(days=1))
        if not nights:
            continue
        for night in nights:
            if night in days:
                days[night].occupied = True
                days[night].available = True
        _spread(days, nights, booking.net_payout, "income")

    for entry in inputs.time_log:
        if entry.date in days:
            days[entry.date].minutes += entry.minutes

    return list(days.values())
