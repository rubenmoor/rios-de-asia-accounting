"""The exchange-rate cache and the conversion of entries to US cents.

Rates come from `rates` (decision 35) and are kept in `exchange_rates`; `rate_coverage` says
up to which day each currency's source has answered. The rate for a day is the latest cached
one on or before it. Reference days (decision 36): an expense its date, every line of a
booking the booking's check-in, the long-term rent setting the day it was saved.

An entry without a rate waits: its USD amount is NULL and it is left out of the figures
(decision 37). One dated after the coverage (a future check-in, today's EUR rate before the
ECB publishes it) is converted with the latest known rate and again once coverage reaches it.
"""

import sqlite3
import sys
import time
from collections.abc import Callable
from datetime import date, timedelta

from rios_de_asia_accounting import rates
from rios_de_asia_accounting.model import Settings
from rios_de_asia_accounting.money import USD_RATE, to_usd
from rios_de_asia_accounting.storage import repo

# currency → fetch(start, end) -> (rates received, coverage reached or None)
FETCHERS: dict[str, Callable[[date, date], tuple[rates.Rates, date | None]]] = {
    "COP": rates.fetch_cop,
    "EUR": rates.fetch_eur,
}
LOOKBACK = timedelta(days=10)  # a cached rate older than this before the day is refetched
RETRY_AFTER = 300  # seconds before the same range is asked again (unless forced)

# currency → (monotonic time, start, end) of the last fetch attempt in this process
_attempts: dict[str, tuple[float, date, date]] = {}

Rate = tuple[int, date]  # (rate, rate date)


def coverage(conn: sqlite3.Connection, currency: str) -> date | None:
    row = conn.execute(
        "SELECT through FROM rate_coverage WHERE currency = ?", (currency,)
    ).fetchone()
    return date.fromisoformat(row["through"]) if row else None


def cached_rate(conn: sqlite3.Connection, currency: str, day: date) -> Rate | None:
    """The latest rate on or before `day` (USD: 1 on the day itself), None when none is kept."""
    if currency == "USD":
        return USD_RATE, day
    row = conn.execute(
        "SELECT date, rate FROM exchange_rates WHERE currency = ? AND date <= ?"
        " ORDER BY date DESC LIMIT 1",
        (currency, day.isoformat()),
    ).fetchone()
    return (row["rate"], date.fromisoformat(row["date"])) if row else None


def _answered(conn: sqlite3.Connection, currency: str, day: date) -> bool:
    """The cache knows the rate of `day` without asking the source."""
    through = coverage(conn, currency)
    hit = cached_rate(conn, currency, day)
    return through is not None and day <= through and hit is not None and day - hit[1] <= LOOKBACK


def _store(
    conn: sqlite3.Connection, currency: str, received: rates.Rates, through: date | None
) -> None:
    with repo.transaction(conn):
        conn.executemany(
            "INSERT INTO exchange_rates (date, currency, rate) VALUES (?, ?, ?)"
            " ON CONFLICT (date, currency) DO UPDATE SET rate = excluded.rate",
            [(day.isoformat(), currency, rate) for day, rate in received],
        )
        if through is not None:
            conn.execute(
                "INSERT INTO rate_coverage (currency, through) VALUES (?, ?)"
                " ON CONFLICT (currency) DO UPDATE SET through = max(through, excluded.through)",
                (currency, through.isoformat()),
            )


def prefetch(
    conn: sqlite3.Connection, currency: str, days: list[date], today: date, force: bool = False
) -> None:
    """One range fetch for the days the cache cannot answer; a failure is logged on stderr."""
    fetch = FETCHERS.get(currency)
    missing = [day for day in days if not _answered(conn, currency, day)]
    if fetch is None or not missing:
        return
    end = min(max(missing), today)
    start = min(min(missing), end) - LOOKBACK
    last = _attempts.get(currency)
    if (
        not force
        and last is not None
        and time.monotonic() - last[0] < RETRY_AFTER
        and last[1] <= start
        and end <= last[2]
    ):
        return
    _attempts[currency] = (time.monotonic(), start, end)
    try:
        received, through = fetch(start, end)
    except rates.RateUnavailable as e:
        print(
            f"rios-de-asia-accounting: no {currency} rates for {start} to {end}: {e}",
            file=sys.stderr,
            flush=True,
        )
        return
    _store(conn, currency, received, through)


def rate_on(
    conn: sqlite3.Connection, currency: str, day: date, today: date | None = None
) -> Rate | None:
    """The rate for `day`: from the cache, fetched on a miss; None when there is none."""
    prefetch(conn, currency, [day], today or date.today())
    return cached_rate(conn, currency, day)


# rows waiting for a rate, or converted before coverage reached their day
_PENDING_EXPENSES = """
    SELECT e.id, e.date AS day, e.currency, e.original_minor, e.rate, e.rate_date
    FROM expenses e LEFT JOIN rate_coverage c ON c.currency = e.currency
    WHERE e.amount IS NULL OR (e.currency <> 'USD' AND (c.through IS NULL OR e.date > c.through))
"""
_PENDING_LINES = """
    SELECT l.id, b.check_in AS day, l.currency, l.amount_minor, l.service_fee_minor,
           l.gross_minor, l.rate, l.rate_date
    FROM booking_lines l JOIN bookings b ON b.id = l.booking_id
    LEFT JOIN rate_coverage c ON c.currency = l.currency
    WHERE l.amount_usd IS NULL
       OR (l.currency <> 'USD' AND (c.through IS NULL OR b.check_in > c.through))
"""


def _rent_pending(conn: sqlite3.Connection, today: date) -> tuple[Settings, date] | None:
    settings = repo.load_settings(conn)
    entered = settings.long_term_rent_entered
    if entered is None:
        return None
    day = date.fromisoformat(entered["date"]) if entered.get("date") else today
    through = coverage(conn, entered["currency"])
    if settings.long_term_rent_usd is None or (
        entered["currency"] != "USD" and (through is None or day > through)
    ):
        return settings, day
    return None


def convert_waiting(conn: sqlite3.Connection, today: date, force: bool = False) -> int:
    """Convert every waiting or provisional expense, booking line and setting, with at most
    one fetch per currency. Returns how many entries still wait (see `waiting_count`)."""
    expenses = conn.execute(_PENDING_EXPENSES).fetchall()
    lines = conn.execute(_PENDING_LINES).fetchall()
    rent = _rent_pending(conn, today)
    days: dict[str, list[date]] = {}
    for row in [*expenses, *lines]:
        days.setdefault(row["currency"], []).append(date.fromisoformat(row["day"]))
    if rent is not None:
        days.setdefault(rent[0].long_term_rent_entered["currency"], []).append(rent[1])
    for currency, wanted in days.items():
        prefetch(conn, currency, wanted, today, force)

    def changed(row: sqlite3.Row | dict) -> Rate | None:
        """The rate to convert `row` with, None when there is none or it is unchanged."""
        found = cached_rate(conn, row["currency"], date.fromisoformat(row["day"]))
        if found is None or (row["rate"], row["rate_date"]) == (found[0], found[1].isoformat()):
            return None
        return found

    with repo.transaction(conn):
        for row in expenses:
            if found := changed(row):
                rate, rate_day = found
                conn.execute(
                    "UPDATE expenses SET amount = ?, rate = ?, rate_date = ? WHERE id = ?",
                    (to_usd(row["original_minor"], rate), rate, rate_day.isoformat(), row["id"]),
                )
        for row in lines:
            if found := changed(row):
                rate, rate_day = found
                gross = row["gross_minor"]
                conn.execute(
                    "UPDATE booking_lines SET amount_usd = ?, service_fee_usd = ?, gross_usd = ?,"
                    " rate = ?, rate_date = ? WHERE id = ?",
                    (
                        to_usd(row["amount_minor"], rate),
                        to_usd(row["service_fee_minor"], rate),
                        None if gross is None else to_usd(gross, rate),
                        rate,
                        rate_day.isoformat(),
                        row["id"],
                    ),
                )
        if rent is not None:
            settings, day = rent
            entered = settings.long_term_rent_entered
            found = changed({**entered, "day": day.isoformat()})
            if found or entered.get("date") is None:
                entered["date"] = day.isoformat()  # a migrated rent: the day of the first start
                if found:
                    rate, rate_day = found
                    entered.update(rate=rate, rate_date=rate_day.isoformat())
                    settings.long_term_rent_usd = to_usd(entered["original_minor"], rate)
                repo.save_settings(conn, settings)
    return waiting_count(conn)


def waiting_count(conn: sqlite3.Connection) -> int:
    """Entries left out of the figures for lack of a rate: expenses, bookings (with any
    waiting line) and the long-term rent."""
    expenses = conn.execute("SELECT COUNT(*) FROM expenses WHERE amount IS NULL").fetchone()[0]
    bookings = conn.execute(
        "SELECT COUNT(DISTINCT booking_id) FROM booking_lines WHERE amount_usd IS NULL"
    ).fetchone()[0]
    settings = repo.load_settings(conn)
    rent = settings.long_term_rent_entered is not None and settings.long_term_rent_usd is None
    return expenses + bookings + rent
