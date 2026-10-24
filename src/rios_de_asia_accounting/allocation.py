"""The per-day view: bookings and expenses → list[Day], money in US cents.

Pure: no database, no clock (`today` is a parameter). Every amount is split over its
full span with `split`, so the days sum exactly to it; only days up to today are kept.
"""

import calendar
from datetime import date, timedelta

from rios_de_asia_accounting.model import Booking, Day, Expense, Inputs


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


COLUMNS = {
    "fixed": "cost_fixed",
    "per_night": "cost_per_night",
    "per_booking": "cost_per_booking",
    "maintenance": "cost_maintenance",
    "capex": "cost_capex",
    "tax": "cost_tax",
}


def _nights(booking: Booking) -> list[date]:
    return date_range(booking.check_in, booking.check_out - timedelta(days=1))


def _booking_cost_span(booking: Booking, mode: str) -> list[date]:
    """Days a per-booking cost is spread over: the check-in day, or the booking's nights."""
    return (mode == "spread" and _nights(booking)) or [booking.check_in]


def _expense_span(
    expense: Expense, bookings: dict[int, Booking], booked: set[date], mode: str
) -> list[date]:
    """The days an expense is split over, by its category (future days included)."""
    match expense.category:
        case "fixed":
            return month_days(expense.date)
        case "per_night":
            month = month_days(expense.date)
            return [d for d in month if d in booked] or month
        case "per_booking" if expense.booking_id in bookings:
            return _booking_cost_span(bookings[expense.booking_id], mode)
        case "capex":
            return date_range(
                expense.date, expense.date + timedelta(days=(expense.useful_life_days or 1) - 1)
            )
        case _:
            return [expense.date]


def allocate(inputs: Inputs, today: date, start: date | None = None) -> list[Day]:
    """One Day per date from `start` to `today` inclusive.

    The default start is the earliest day any input touches: a check-in or the first day
    an expense is spread over (the 1st of its month for a fixed or per-night cost).
    """
    bookings = {b.id: b for b in inputs.bookings if b.id is not None}
    booked = {night for b in inputs.bookings for night in _nights(b)}
    mode = inputs.settings.per_booking_allocation
    items = [
        (COLUMNS[e.category], _expense_span(e, bookings, booked, mode), e.amount)
        for e in inputs.expenses
        if e.amount is not None  # waiting for a rate: left out
    ] + [
        ("cost_per_booking", _booking_cost_span(b, mode), b.cohost_cost)
        for b in inputs.bookings
        if b.cohost_cost
    ]

    if start is None:
        start = min(
            [
                *(b.check_in for b in inputs.bookings),
                *(span[0] for _, span, _ in items),
            ],
            default=None,
        )
        if start is None:
            return []
    days = {d: Day(date=d) for d in date_range(start, today)}

    for booking in inputs.bookings:
        nights = _nights(booking)
        if not nights:
            continue
        for night in nights:
            if night in days:
                days[night].occupied = True
        _spread(days, nights, booking.net_payout, "income")

    for column, span, amount in items:
        _spread(days, span, amount, column)

    return list(days.values())
