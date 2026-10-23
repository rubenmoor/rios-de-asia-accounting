import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import date

from airbnb_books.model import Booking, BookingLine, ExchangeRate
from airbnb_books.money import COP_RATE, to_cop

_BOOKING_SELECT = """
    SELECT b.*, t.nights, t.net_payout, t.cohost_cost, t.gross, t.airbnb_fee, t.needs_rate
    FROM bookings b JOIN booking_totals t ON t.booking_id = b.id
"""


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


def delete_booking(conn: sqlite3.Connection, booking_id: int) -> None:
    conn.execute("DELETE FROM bookings WHERE id = ?", (booking_id,))


# --- booking lines ----------------------------------------------------------------------------


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


def set_exchange_rate(conn: sqlite3.Connection, rate: ExchangeRate) -> None:
    """Add or change a rate and re-convert the lines."""
    with transaction(conn):
        conn.execute(
            "INSERT INTO exchange_rates (date, currency, rate) VALUES (?, ?, ?)"
            " ON CONFLICT (date, currency) DO UPDATE SET rate = excluded.rate",
            (rate.date.isoformat(), rate.currency, rate.rate),
        )
        recompute_lines(conn)


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


def recompute_lines(conn: sqlite3.Connection) -> None:
    """Fill or update rate / amount_cop of every non-COP line from the exchange rates."""
    with transaction(conn):
        rows = conn.execute(
            "SELECT id, currency, date, amount_minor FROM booking_lines WHERE currency <> 'COP'"
        ).fetchall()
        for r in rows:
            rate = rate_for(conn, r["currency"], date.fromisoformat(r["date"]))
            cop = None if rate is None else to_cop(r["amount_minor"], rate)
            conn.execute(
                "UPDATE booking_lines SET rate = ?, amount_cop = ? WHERE id = ?",
                (rate, cop, r["id"]),
            )
