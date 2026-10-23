import functools
import json
import sqlite3
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from datetime import date
from typing import TypeVar

from rios_de_asia_accounting.model import (
    BlockedDay,
    Booking,
    BookingLine,
    ExchangeRate,
    Expense,
    Inputs,
    RecurringExpense,
    Settings,
    TimeEntry,
)
from rios_de_asia_accounting.money import COP_RATE, to_cop

_BOOKING_SELECT = """
    SELECT b.*, t.nights, t.net_payout, t.cohost_cost, t.gross, t.airbnb_fee, t.needs_rate
    FROM bookings b JOIN booking_totals t ON t.booking_id = b.id
"""


class ValidationError(Exception):
    """A write broke a database rule; the message is meant for the user."""


_CONSTRAINT_HINTS = {
    "bookings.airbnb_code": "a booking with this Airbnb code already exists",
    "booking_lines.booking_id, booking_lines.type": "this line already exists",
    "expenses.recurring_expense_id, expenses.date": "already generated for that date",
    "exchange_rates.date, exchange_rates.currency": "this exchange rate already exists",
    "check_out > check_in": "check-out must be after check-in",
    "category <> 'per_booking' OR booking_id IS NOT NULL": "a per-booking expense needs a booking",
    "minutes > 0": "minutes must be greater than zero",
}


def _readable(error: sqlite3.IntegrityError) -> str:
    text = str(error)
    if text.startswith("FOREIGN KEY"):
        return "it refers to, or is still used by, another record (booking, expense or template)"
    for key, hint in _CONSTRAINT_HINTS.items():
        if key in text:
            return hint
    if "capex" in text or "useful_life_days" in text:
        return "capex needs a useful life in days (> 0); other categories must not have one"
    return f"not allowed by the database rules ({text})"


_F = TypeVar("_F", bound=Callable)


def validated(func: _F) -> _F:
    """Turn database constraint errors into one ValidationError."""

    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        try:
            return func(*args, **kwargs)
        except sqlite3.IntegrityError as e:
            raise ValidationError(_readable(e)) from e

    return wrapper  # type: ignore[return-value]


@contextmanager
def transaction(conn: sqlite3.Connection) -> Iterator[None]:
    """One transaction; joins the running one if there is any."""
    if conn.in_transaction:
        yield
        return
    conn.execute("BEGIN")
    try:
        yield
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    conn.execute("COMMIT")


def _booking(row: sqlite3.Row) -> Booking:
    return Booking(
        id=row["id"],
        airbnb_code=row["airbnb_code"],
        listing=row["listing"],
        guest_name=row["guest_name"],
        check_in=date.fromisoformat(row["check_in"]),
        check_out=date.fromisoformat(row["check_out"]),
        guests=row["guests"],
        notes=row["notes"],
        nights=row["nights"],
        net_payout=row["net_payout"],
        cohost_cost=row["cohost_cost"],
        gross=row["gross"],
        airbnb_fee=row["airbnb_fee"],
        needs_rate=bool(row["needs_rate"]),
    )


def _line(row: sqlite3.Row) -> BookingLine:
    return BookingLine(
        id=row["id"],
        booking_id=row["booking_id"],
        type=row["type"],
        date=date.fromisoformat(row["date"]),
        currency=row["currency"],
        amount_minor=row["amount_minor"],
        service_fee_minor=row["service_fee_minor"],
        cleaning_fee_minor=row["cleaning_fee_minor"],
        gross_minor=row["gross_minor"],
        rate=row["rate"],
        amount_cop=row["amount_cop"],
    )


# --- bookings ---------------------------------------------------------------------------------


@validated
def create_booking(
    conn: sqlite3.Connection, booking: Booking, manual_amount_cop: int | None = None
) -> int:
    """Insert a booking. With `manual_amount_cop` it is hand-entered and gets a Manual line."""
    with transaction(conn):
        cur = conn.execute(
            "INSERT INTO bookings (airbnb_code, listing, guest_name, check_in, check_out,"
            " guests, notes) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                booking.airbnb_code,
                booking.listing,
                booking.guest_name,
                booking.check_in.isoformat(),
                booking.check_out.isoformat(),
                booking.guests,
                booking.notes,
            ),
        )
        booking.id = cur.lastrowid
        if manual_amount_cop is not None:
            _set_manual_amount(conn, booking.id, booking.check_in, manual_amount_cop)
    return booking.id


def _set_manual_amount(conn: sqlite3.Connection, booking_id: int, day: date, cop: int) -> None:
    minor = cop * 100
    cur = conn.execute(
        "UPDATE booking_lines SET amount_minor = ?, amount_cop = ?"
        " WHERE booking_id = ? AND type = 'Manual'",
        (minor, cop, booking_id),
    )
    if cur.rowcount == 0:
        conn.execute(
            "INSERT INTO booking_lines (booking_id, type, date, currency, amount_minor,"
            " rate, amount_cop) VALUES (?, 'Manual', ?, 'COP', ?, ?, ?)",
            (booking_id, day.isoformat(), minor, COP_RATE, cop),
        )


def get_booking(conn: sqlite3.Connection, booking_id: int) -> Booking | None:
    row = conn.execute(_BOOKING_SELECT + " WHERE b.id = ?", (booking_id,)).fetchone()
    return _booking(row) if row else None


def find_booking_by_code(conn: sqlite3.Connection, airbnb_code: str) -> Booking | None:
    row = conn.execute(_BOOKING_SELECT + " WHERE b.airbnb_code = ?", (airbnb_code,)).fetchone()
    return _booking(row) if row else None


def list_bookings(
    conn: sqlite3.Connection,
    start: date | None = None,
    end: date | None = None,
    listing: str | None = None,
) -> list[Booking]:
    """Bookings overlapping [start, end) (check-out exclusive), optionally of one listing."""
    where, args = [], []
    if start is not None:
        where.append("b.check_out > ?")
        args.append(start.isoformat())
    if end is not None:
        where.append("b.check_in < ?")
        args.append(end.isoformat())
    if listing is not None:
        where.append("b.listing = ?")
        args.append(listing)
    sql = _BOOKING_SELECT + (" WHERE " + " AND ".join(where) if where else "")
    rows = conn.execute(sql + " ORDER BY b.check_in, b.id", args).fetchall()
    return [_booking(r) for r in rows]


@validated
def update_booking(
    conn: sqlite3.Connection, booking: Booking, manual_amount_cop: int | None = None
) -> None:
    """Save the booking's own fields; `manual_amount_cop` edits its Manual line."""
    with transaction(conn):
        conn.execute(
            "UPDATE bookings SET airbnb_code = ?, listing = ?, guest_name = ?, check_in = ?,"
            " check_out = ?, guests = ?, notes = ? WHERE id = ?",
            (
                booking.airbnb_code,
                booking.listing,
                booking.guest_name,
                booking.check_in.isoformat(),
                booking.check_out.isoformat(),
                booking.guests,
                booking.notes,
                booking.id,
            ),
        )
        if manual_amount_cop is not None:
            _set_manual_amount(conn, booking.id, booking.check_in, manual_amount_cop)


@validated
def delete_booking(conn: sqlite3.Connection, booking_id: int) -> None:
    conn.execute("DELETE FROM bookings WHERE id = ?", (booking_id,))


# --- booking lines ----------------------------------------------------------------------------


@validated
def add_line(conn: sqlite3.Connection, line: BookingLine) -> bool:
    """Add an imported line, converting with the known rate. False if it already existed."""
    if line.currency == "COP":
        line.rate = COP_RATE
    else:
        line.rate = rate_for(conn, line.currency, line.date)
    line.amount_cop = None if line.rate is None else to_cop(line.amount_minor, line.rate)
    cur = conn.execute(
        "INSERT INTO booking_lines (booking_id, type, date, currency, amount_minor,"
        " service_fee_minor, cleaning_fee_minor, gross_minor, rate, amount_cop)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        " ON CONFLICT (booking_id, type, date, currency, amount_minor) DO NOTHING",
        (
            line.booking_id,
            line.type,
            line.date.isoformat(),
            line.currency,
            line.amount_minor,
            line.service_fee_minor,
            line.cleaning_fee_minor,
            line.gross_minor,
            line.rate,
            line.amount_cop,
        ),
    )
    if cur.rowcount == 0:
        return False
    line.id = cur.lastrowid
    return True


def list_lines(conn: sqlite3.Connection, booking_id: int) -> list[BookingLine]:
    rows = conn.execute(
        "SELECT * FROM booking_lines WHERE booking_id = ? ORDER BY date, id", (booking_id,)
    ).fetchall()
    return [_line(r) for r in rows]


# --- exchange rates ---------------------------------------------------------------------------


@validated
def set_exchange_rate(conn: sqlite3.Connection, rate: ExchangeRate) -> None:
    """Add or change a rate and re-convert the lines."""
    with transaction(conn):
        conn.execute(
            "INSERT INTO exchange_rates (date, currency, rate) VALUES (?, ?, ?)"
            " ON CONFLICT (date, currency) DO UPDATE SET rate = excluded.rate",
            (rate.date.isoformat(), rate.currency, rate.rate),
        )
        recompute_lines(conn)


@validated
def upsert_exchange_rates(
    conn: sqlite3.Connection, rates: list[ExchangeRate]
) -> tuple[int, int, int]:
    """Add or change many rates, then re-convert the lines once.

    Returns (rates added, rates changed, lines recomputed).
    """
    added = changed = 0
    with transaction(conn):
        for rate in rates:
            row = conn.execute(
                "SELECT rate FROM exchange_rates WHERE date = ? AND currency = ?",
                (rate.date.isoformat(), rate.currency),
            ).fetchone()
            if row is None:
                added += 1
            elif row["rate"] != rate.rate:
                changed += 1
            else:
                continue
            conn.execute(
                "INSERT INTO exchange_rates (date, currency, rate) VALUES (?, ?, ?)"
                " ON CONFLICT (date, currency) DO UPDATE SET rate = excluded.rate",
                (rate.date.isoformat(), rate.currency, rate.rate),
            )
        recomputed = recompute_lines(conn)
    return added, changed, recomputed


@validated
def delete_exchange_rate(conn: sqlite3.Connection, day: date, currency: str) -> None:
    with transaction(conn):
        conn.execute(
            "DELETE FROM exchange_rates WHERE date = ? AND currency = ?",
            (day.isoformat(), currency),
        )
        recompute_lines(conn)


def list_exchange_rates(
    conn: sqlite3.Connection, currency: str | None = None
) -> list[ExchangeRate]:
    sql = "SELECT * FROM exchange_rates"
    args: list[str] = []
    if currency is not None:
        sql += " WHERE currency = ?"
        args.append(currency)
    rows = conn.execute(sql + " ORDER BY date DESC, currency", args).fetchall()
    return [ExchangeRate(date.fromisoformat(r["date"]), r["currency"], r["rate"]) for r in rows]


def rate_for(conn: sqlite3.Connection, currency: str, day: date) -> int | None:
    """Latest rate on or before `day`, None when there is none."""
    if currency == "COP":
        return COP_RATE
    row = conn.execute(
        "SELECT rate FROM exchange_rates WHERE currency = ? AND date <= ?"
        " ORDER BY date DESC LIMIT 1",
        (currency, day.isoformat()),
    ).fetchone()
    return row["rate"] if row else None


def recompute_lines(conn: sqlite3.Connection) -> int:
    """Fill or update rate / amount_cop of every non-COP line from the exchange rates.

    Returns how many lines changed.
    """
    changed = 0
    with transaction(conn):
        rows = conn.execute(
            "SELECT id, currency, date, amount_minor, rate, amount_cop FROM booking_lines"
            " WHERE currency <> 'COP'"
        ).fetchall()
        for r in rows:
            rate = rate_for(conn, r["currency"], date.fromisoformat(r["date"]))
            cop = None if rate is None else to_cop(r["amount_minor"], rate)
            if (rate, cop) == (r["rate"], r["amount_cop"]):
                continue
            changed += 1
            conn.execute(
                "UPDATE booking_lines SET rate = ?, amount_cop = ? WHERE id = ?",
                (rate, cop, r["id"]),
            )
    return changed


# --- expenses ---------------------------------------------------------------------------------


def _expense(r: sqlite3.Row) -> Expense:
    return Expense(
        id=r["id"],
        date=date.fromisoformat(r["date"]),
        amount=r["amount"],
        category=r["category"],
        booking_id=r["booking_id"],
        useful_life_days=r["useful_life_days"],
        description=r["description"],
        recurring_expense_id=r["recurring_expense_id"],
    )


def _expense_args(e: Expense) -> tuple:
    return (
        e.date.isoformat(),
        e.amount,
        e.category,
        e.booking_id,
        e.useful_life_days,
        e.description,
        e.recurring_expense_id,
    )


_EXPENSE_COLS = (
    "date, amount, category, booking_id, useful_life_days, description, recurring_expense_id"
)


@validated
def create_expense(conn: sqlite3.Connection, expense: Expense) -> int:
    cur = conn.execute(
        f"INSERT INTO expenses ({_EXPENSE_COLS}) VALUES (?, ?, ?, ?, ?, ?, ?)",
        _expense_args(expense),
    )
    expense.id = cur.lastrowid
    return expense.id


@validated
def insert_generated_expense(conn: sqlite3.Connection, expense: Expense) -> bool:
    """Insert unless (recurring_expense_id, date) exists. True if it was new."""
    cur = conn.execute(
        f"INSERT INTO expenses ({_EXPENSE_COLS}) VALUES (?, ?, ?, ?, ?, ?, ?)"
        " ON CONFLICT (recurring_expense_id, date) DO NOTHING",
        _expense_args(expense),
    )
    if cur.rowcount == 0:
        return False
    expense.id = cur.lastrowid
    return True


def get_expense(conn: sqlite3.Connection, expense_id: int) -> Expense | None:
    row = conn.execute("SELECT * FROM expenses WHERE id = ?", (expense_id,)).fetchone()
    return _expense(row) if row else None


def _range_filter(start: date | None, end: date | None) -> tuple[str, list[str]]:
    """WHERE clause for start <= date < end."""
    where, args = [], []
    if start is not None:
        where.append("date >= ?")
        args.append(start.isoformat())
    if end is not None:
        where.append("date < ?")
        args.append(end.isoformat())
    return (" WHERE " + " AND ".join(where) if where else ""), args


def list_expenses(
    conn: sqlite3.Connection, start: date | None = None, end: date | None = None
) -> list[Expense]:
    """Expenses dated in [start, end)."""
    where, args = _range_filter(start, end)
    rows = conn.execute(f"SELECT * FROM expenses{where} ORDER BY date, id", args).fetchall()
    return [_expense(r) for r in rows]


def list_expenses_of_recurring(conn: sqlite3.Connection, recurring_id: int) -> list[Expense]:
    rows = conn.execute(
        "SELECT * FROM expenses WHERE recurring_expense_id = ? ORDER BY date", (recurring_id,)
    ).fetchall()
    return [_expense(r) for r in rows]


@validated
def update_expense(conn: sqlite3.Connection, expense: Expense) -> None:
    conn.execute(
        "UPDATE expenses SET date = ?, amount = ?, category = ?, booking_id = ?,"
        " useful_life_days = ?, description = ?, recurring_expense_id = ? WHERE id = ?",
        (*_expense_args(expense), expense.id),
    )


def delete_expense(conn: sqlite3.Connection, expense_id: int) -> None:
    conn.execute("DELETE FROM expenses WHERE id = ?", (expense_id,))


# --- recurring expenses -----------------------------------------------------------------------


def _recurring(r: sqlite3.Row) -> RecurringExpense:
    return RecurringExpense(
        id=r["id"],
        description=r["description"],
        amount=r["amount"],
        category=r["category"],
        start_month=r["start_month"],
        end_month=r["end_month"],
    )


@validated
def create_recurring_expense(conn: sqlite3.Connection, item: RecurringExpense) -> int:
    cur = conn.execute(
        "INSERT INTO recurring_expenses (description, amount, category, start_month, end_month)"
        " VALUES (?, ?, ?, ?, ?)",
        (item.description, item.amount, item.category, item.start_month, item.end_month),
    )
    item.id = cur.lastrowid
    return item.id


def get_recurring_expense(conn: sqlite3.Connection, item_id: int) -> RecurringExpense | None:
    row = conn.execute("SELECT * FROM recurring_expenses WHERE id = ?", (item_id,)).fetchone()
    return _recurring(row) if row else None


def list_recurring_expenses(conn: sqlite3.Connection) -> list[RecurringExpense]:
    rows = conn.execute("SELECT * FROM recurring_expenses ORDER BY start_month, id").fetchall()
    return [_recurring(r) for r in rows]


@validated
def update_recurring_expense(conn: sqlite3.Connection, item: RecurringExpense) -> None:
    conn.execute(
        "UPDATE recurring_expenses SET description = ?, amount = ?, category = ?,"
        " start_month = ?, end_month = ? WHERE id = ?",
        (item.description, item.amount, item.category, item.start_month, item.end_month, item.id),
    )


def delete_recurring_expense(conn: sqlite3.Connection, item_id: int) -> None:
    """Generated expenses stay (their link is cleared)."""
    conn.execute("DELETE FROM recurring_expenses WHERE id = ?", (item_id,))


# --- blocked days -----------------------------------------------------------------------------


def _blocked(r: sqlite3.Row) -> BlockedDay:
    return BlockedDay(date.fromisoformat(r["date"]), r["reason"], r["note"])


@validated
def set_blocked_day(conn: sqlite3.Connection, day: BlockedDay) -> None:
    """Block a day, or change the reason / note if it is blocked already."""
    conn.execute(
        "INSERT INTO blocked_days (date, reason, note) VALUES (?, ?, ?)"
        " ON CONFLICT (date) DO UPDATE SET reason = excluded.reason, note = excluded.note",
        (day.date.isoformat(), day.reason, day.note),
    )


def get_blocked_day(conn: sqlite3.Connection, day: date) -> BlockedDay | None:
    row = conn.execute("SELECT * FROM blocked_days WHERE date = ?", (day.isoformat(),)).fetchone()
    return _blocked(row) if row else None


def list_blocked_days(
    conn: sqlite3.Connection, start: date | None = None, end: date | None = None
) -> list[BlockedDay]:
    where, args = _range_filter(start, end)
    rows = conn.execute(f"SELECT * FROM blocked_days{where} ORDER BY date", args).fetchall()
    return [_blocked(r) for r in rows]


def delete_blocked_day(conn: sqlite3.Connection, day: date) -> None:
    conn.execute("DELETE FROM blocked_days WHERE date = ?", (day.isoformat(),))


# --- time log ---------------------------------------------------------------------------------


def _time_entry(r: sqlite3.Row) -> TimeEntry:
    return TimeEntry(
        id=r["id"],
        date=date.fromisoformat(r["date"]),
        minutes=r["minutes"],
        booking_id=r["booking_id"],
        description=r["description"],
    )


@validated
def create_time_entry(conn: sqlite3.Connection, entry: TimeEntry) -> int:
    cur = conn.execute(
        "INSERT INTO time_log (date, minutes, booking_id, description) VALUES (?, ?, ?, ?)",
        (entry.date.isoformat(), entry.minutes, entry.booking_id, entry.description),
    )
    entry.id = cur.lastrowid
    return entry.id


def get_time_entry(conn: sqlite3.Connection, entry_id: int) -> TimeEntry | None:
    row = conn.execute("SELECT * FROM time_log WHERE id = ?", (entry_id,)).fetchone()
    return _time_entry(row) if row else None


def list_time_entries(
    conn: sqlite3.Connection, start: date | None = None, end: date | None = None
) -> list[TimeEntry]:
    where, args = _range_filter(start, end)
    rows = conn.execute(f"SELECT * FROM time_log{where} ORDER BY date, id", args).fetchall()
    return [_time_entry(r) for r in rows]


@validated
def update_time_entry(conn: sqlite3.Connection, entry: TimeEntry) -> None:
    conn.execute(
        "UPDATE time_log SET date = ?, minutes = ?, booking_id = ?, description = ? WHERE id = ?",
        (entry.date.isoformat(), entry.minutes, entry.booking_id, entry.description, entry.id),
    )


def delete_time_entry(conn: sqlite3.Connection, entry_id: int) -> None:
    conn.execute("DELETE FROM time_log WHERE id = ?", (entry_id,))


# --- settings ---------------------------------------------------------------------------------

_INT_SETTINGS = ("hourly_value_cop", "long_term_rent_cop_per_month", "backup_keep")
_ALLOCATIONS = ("check_in", "spread")


def load_settings(conn: sqlite3.Connection) -> Settings:
    """Stored values over the defaults in `Settings`; unknown keys are ignored."""
    stored = {r["key"]: r["value"] for r in conn.execute("SELECT key, value FROM settings")}
    settings = Settings()
    for key in _INT_SETTINGS:
        if key in stored:
            setattr(settings, key, int(stored[key]))
    for key in ("currency", "per_booking_allocation"):
        if key in stored:
            setattr(settings, key, stored[key])
    if "property_listings" in stored:
        settings.property_listings = list(json.loads(stored["property_listings"]))
    return settings


def save_settings(conn: sqlite3.Connection, settings: Settings) -> None:
    if settings.per_booking_allocation not in _ALLOCATIONS:
        raise ValidationError("per-booking allocation must be 'check_in' or 'spread'")
    if settings.backup_keep < 1:
        raise ValidationError("the number of backups to keep must be at least 1")
    values = {
        **{k: str(getattr(settings, k)) for k in _INT_SETTINGS},
        "currency": settings.currency,
        "per_booking_allocation": settings.per_booking_allocation,
        "property_listings": json.dumps(settings.property_listings),
    }
    with transaction(conn):
        for key, value in values.items():
            conn.execute(
                "INSERT INTO settings (key, value) VALUES (?, ?)"
                " ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                (key, value),
            )


# --- allocation inputs ------------------------------------------------------------------------


def load_inputs(conn: sqlite3.Connection) -> Inputs:
    return Inputs(
        bookings=list_bookings(conn),
        expenses=list_expenses(conn),
        blocked_days=list_blocked_days(conn),
        time_log=list_time_entries(conn),
        settings=load_settings(conn),
    )
