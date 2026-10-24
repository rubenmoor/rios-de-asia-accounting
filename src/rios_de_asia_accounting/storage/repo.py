import functools
import json
import sqlite3
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from datetime import date
from typing import TypeVar

from rios_de_asia_accounting.model import (
    Booking,
    BookingLine,
    Expense,
    Inputs,
    RecurringExpense,
    Settings,
)

_BOOKING_SELECT = """
    SELECT b.*, t.nights, t.net_payout, t.cohost_cost, t.gross, t.airbnb_fee, t.waiting
    FROM bookings b JOIN booking_totals t ON t.booking_id = b.id
"""


class ValidationError(Exception):
    """A write broke a database rule; the message is meant for the user."""


_CONSTRAINT_HINTS = {
    "bookings.airbnb_code": "a booking with this Airbnb code already exists",
    "booking_lines.booking_id, booking_lines.type": "this line already exists",
    "expenses.recurring_expense_id, expenses.date": "already generated for that date",
    "check_out > check_in": "check-out must be after check-in",
    "category <> 'per_booking' OR booking_id IS NOT NULL": "a per-booking expense needs a booking",
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


def _day(text: str | None) -> date | None:
    return None if text is None else date.fromisoformat(text)


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
        waiting=bool(row["waiting"]),
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
        rate_date=_day(row["rate_date"]),
        amount_usd=row["amount_usd"],
        service_fee_usd=row["service_fee_usd"],
        gross_usd=row["gross_usd"],
    )


# --- bookings ---------------------------------------------------------------------------------


# a hand-entered booking's amount: (minor units, currency)
Manual = tuple[int, str]


@validated
def create_booking(
    conn: sqlite3.Connection, booking: Booking, manual_amount: Manual | None = None
) -> int:
    """Insert a booking. With `manual_amount` it is hand-entered and gets a Manual line."""
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
        if manual_amount is not None:
            _set_manual_amount(conn, booking.id, booking.check_in, manual_amount)
    return booking.id


_UNCONVERTED = (
    "rate = NULL, rate_date = NULL, amount_usd = NULL, service_fee_usd = NULL, gross_usd = NULL"
)


def _set_manual_amount(
    conn: sqlite3.Connection, booking_id: int, day: date, amount: Manual
) -> None:
    """Write the Manual line, dated at check-in; a changed amount or currency waits for its
    conversion again."""
    minor, currency = amount
    conn.execute(
        f"UPDATE booking_lines SET {_UNCONVERTED}"
        " WHERE booking_id = ? AND type = 'Manual' AND (amount_minor, currency) IS NOT (?, ?)",
        (booking_id, minor, currency),
    )
    cur = conn.execute(
        "UPDATE booking_lines SET date = ?, currency = ?, amount_minor = ?"
        " WHERE booking_id = ? AND type = 'Manual'",
        (day.isoformat(), currency, minor, booking_id),
    )
    if cur.rowcount == 0:
        conn.execute(
            "INSERT INTO booking_lines (booking_id, type, date, currency, amount_minor)"
            " VALUES (?, 'Manual', ?, ?, ?)",
            (booking_id, day.isoformat(), currency, minor),
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
    conn: sqlite3.Connection, booking: Booking, manual_amount: Manual | None = None
) -> None:
    """Save the booking's own fields; `manual_amount` edits its Manual line. A new check-in
    makes all its lines wait for their conversion again (decision 36)."""
    with transaction(conn):
        conn.execute(
            f"UPDATE booking_lines SET {_UNCONVERTED}"
            " WHERE booking_id = (SELECT id FROM bookings WHERE id = ? AND check_in IS NOT ?)",
            (booking.id, booking.check_in.isoformat()),
        )
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
        if manual_amount is not None:
            _set_manual_amount(conn, booking.id, booking.check_in, manual_amount)


@validated
def delete_booking(conn: sqlite3.Connection, booking_id: int) -> None:
    conn.execute("DELETE FROM bookings WHERE id = ?", (booking_id,))


# --- booking lines ----------------------------------------------------------------------------


@validated
def add_line(conn: sqlite3.Connection, line: BookingLine) -> bool:
    """Add an imported line, waiting for its conversion. False if it already existed."""
    cur = conn.execute(
        "INSERT INTO booking_lines (booking_id, type, date, currency, amount_minor,"
        " service_fee_minor, cleaning_fee_minor, gross_minor)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
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
        original_minor=r["original_minor"],
        currency=r["currency"],
        rate=r["rate"],
        rate_date=_day(r["rate_date"]),
    )


def _expense_args(e: Expense) -> tuple:
    return (
        e.date.isoformat(),
        e.amount,
        e.original_minor,
        e.currency,
        e.rate,
        e.rate_date.isoformat() if e.rate_date else None,
        e.category,
        e.booking_id,
        e.useful_life_days,
        e.description,
        e.recurring_expense_id,
    )


_EXPENSE_COLS = (
    "date, amount, original_minor, currency, rate, rate_date, category, booking_id,"
    " useful_life_days, description, recurring_expense_id"
)
_EXPENSE_VALUES = ", ".join("?" * 11)


@validated
def create_expense(conn: sqlite3.Connection, expense: Expense) -> int:
    cur = conn.execute(
        f"INSERT INTO expenses ({_EXPENSE_COLS}) VALUES ({_EXPENSE_VALUES})",
        _expense_args(expense),
    )
    expense.id = cur.lastrowid
    return expense.id


@validated
def insert_generated_expense(conn: sqlite3.Connection, expense: Expense) -> bool:
    """Insert unless (recurring_expense_id, date) exists. True if it was new."""
    cur = conn.execute(
        f"INSERT INTO expenses ({_EXPENSE_COLS}) VALUES ({_EXPENSE_VALUES})"
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


def default_currency(conn: sqlite3.Connection) -> str:
    """The currency of the most recently saved (not generated) expense, else USD."""
    row = conn.execute(
        "SELECT currency FROM expenses WHERE recurring_expense_id IS NULL ORDER BY id DESC LIMIT 1"
    ).fetchone()
    return row["currency"] if row else "USD"


def list_expenses_of_recurring(conn: sqlite3.Connection, recurring_id: int) -> list[Expense]:
    rows = conn.execute(
        "SELECT * FROM expenses WHERE recurring_expense_id = ? ORDER BY date", (recurring_id,)
    ).fetchall()
    return [_expense(r) for r in rows]


@validated
def update_expense(conn: sqlite3.Connection, expense: Expense) -> None:
    """Save; a changed date, amount or currency makes it wait for its conversion again."""
    old = get_expense(conn, expense.id)
    if old is not None and (old.date, old.original_minor, old.currency) != (
        expense.date,
        expense.original_minor,
        expense.currency,
    ):
        expense.amount = expense.rate = expense.rate_date = None
    conn.execute(
        "UPDATE expenses SET date = ?, amount = ?, original_minor = ?, currency = ?, rate = ?,"
        " rate_date = ?, category = ?, booking_id = ?, useful_life_days = ?, description = ?,"
        " recurring_expense_id = ? WHERE id = ?",
        (*_expense_args(expense), expense.id),
    )


def delete_expense(conn: sqlite3.Connection, expense_id: int) -> None:
    conn.execute("DELETE FROM expenses WHERE id = ?", (expense_id,))


# --- recurring expenses -----------------------------------------------------------------------


def _recurring(r: sqlite3.Row) -> RecurringExpense:
    return RecurringExpense(
        id=r["id"],
        description=r["description"],
        amount_minor=r["amount_minor"],
        currency=r["currency"],
        category=r["category"],
        start_month=r["start_month"],
        end_month=r["end_month"],
    )


@validated
def create_recurring_expense(conn: sqlite3.Connection, item: RecurringExpense) -> int:
    cur = conn.execute(
        "INSERT INTO recurring_expenses (description, amount_minor, currency, category,"
        " start_month, end_month) VALUES (?, ?, ?, ?, ?, ?)",
        (
            item.description,
            item.amount_minor,
            item.currency,
            item.category,
            item.start_month,
            item.end_month,
        ),
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
        "UPDATE recurring_expenses SET description = ?, amount_minor = ?, currency = ?,"
        " category = ?, start_month = ?, end_month = ? WHERE id = ?",
        (
            item.description,
            item.amount_minor,
            item.currency,
            item.category,
            item.start_month,
            item.end_month,
            item.id,
        ),
    )


def delete_recurring_expense(conn: sqlite3.Connection, item_id: int) -> None:
    """Generated expenses stay (their link is cleared)."""
    conn.execute("DELETE FROM recurring_expenses WHERE id = ?", (item_id,))


# --- settings ---------------------------------------------------------------------------------

_INT_SETTINGS = ("backup_keep",)
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
    if "long_term_rent_entered" in stored:
        settings.long_term_rent_entered = json.loads(stored["long_term_rent_entered"])
        usd = stored.get("long_term_rent_usd")
        settings.long_term_rent_usd = None if usd is None else int(usd)
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
    entered = settings.long_term_rent_entered
    if entered is not None:
        values["long_term_rent_entered"] = json.dumps(entered)
        if settings.long_term_rent_usd is not None:
            values["long_term_rent_usd"] = str(settings.long_term_rent_usd)
    with transaction(conn):
        for key in ("long_term_rent_entered", "long_term_rent_usd"):
            if key not in values:  # no rent, or the rent waits for a rate
                conn.execute("DELETE FROM settings WHERE key = ?", (key,))
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
        settings=load_settings(conn),
    )
