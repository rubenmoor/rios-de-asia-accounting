"""Read Airbnb's earnings CSV into typed rows, plan what importing it would do, apply it."""

import csv
from collections import Counter
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from itertools import combinations
from pathlib import Path
from sqlite3 import Connection
from typing import IO

from rios_de_asia_accounting.conversion import convert_waiting
from rios_de_asia_accounting.model import Booking, BookingLine
from rios_de_asia_accounting.money import parse_minor
from rios_de_asia_accounting.storage import repo

REQUIRED_COLUMNS = (
    "Date",
    "Type",
    "Confirmation code",
    "Start date",
    "End date",
    "Nights",
    "Listing",
    "Guest",
    "Currency",
    "Amount",
    "Service fee",
    "Cleaning fee",
    "Gross earnings",
    "Paid out",
)
LINE_TYPES = (
    "Reservation",
    "Adjustment",
    "Resolution Adjustment",
    "Resolution Payout",
    "Co-Host payout",
)
PAYOUT_TYPE = "Payout"


class FileError(Exception):
    """The file cannot be read as an Airbnb earnings CSV at all."""


@dataclass(frozen=True)
class Row:
    line: int  # CSV line number (the header is line 1)
    type: str
    code: str
    date: date
    start: date
    end: date  # exclusive check-out
    nights: int
    listing: str
    guest: str
    currency: str
    amount: int  # minor units (hundredths)
    service_fee: int
    cleaning_fee: int
    gross: int | None


@dataclass(frozen=True)
class Problem:
    line: int
    message: str


@dataclass
class ParsedFile:
    rows: list[Row] = field(default_factory=list)
    payouts: int = 0
    listings: Counter = field(default_factory=Counter)
    problems: list[Problem] = field(default_factory=list)


def _date(text: str, name: str) -> date:
    try:
        return datetime.strptime(text.strip(), "%m/%d/%Y").date()
    except ValueError:
        raise ValueError(f"bad {name} {text!r}, expected MM/DD/YYYY") from None


def _amount(text: str, name: str) -> int:
    try:
        return parse_minor(text)
    except ValueError as e:
        raise ValueError(f"bad {name}: {e}") from None


def _row(line: int, rec: dict[str, str]) -> Row:
    kind = rec["Type"].strip()
    code = rec["Confirmation code"].strip()
    if not code:
        raise ValueError("missing confirmation code")
    start = _date(rec["Start date"], "Start date")
    end = _date(rec["End date"], "End date")
    try:
        nights = int(rec["Nights"].strip())
    except ValueError:
        raise ValueError(f"bad Nights {rec['Nights']!r}") from None
    if end - start != timedelta(days=nights):
        raise ValueError(f"Nights {nights} does not match {start} to {end}")
    currency = rec["Currency"].strip()
    if not currency:
        raise ValueError("missing currency")
    gross = rec["Gross earnings"].strip()
    return Row(
        line=line,
        type=kind,
        code=code,
        date=_date(rec["Date"], "Date"),
        start=start,
        end=end,
        nights=nights,
        listing=rec["Listing"].strip(),
        guest=rec["Guest"].strip(),
        currency=currency,
        amount=_amount(rec["Amount"], "Amount"),
        service_fee=_amount(rec["Service fee"].strip() or "0", "Service fee"),
        cleaning_fee=_amount(rec["Cleaning fee"].strip() or "0", "Cleaning fee"),
        gross=_amount(gross, "Gross earnings") if gross else None,
    )


def _parse_stream(f: IO[str]) -> ParsedFile:
    reader = csv.DictReader(f)
    missing = [c for c in REQUIRED_COLUMNS if c not in (reader.fieldnames or [])]
    if missing:
        raise FileError("missing column(s): " + ", ".join(missing))
    result = ParsedFile()
    for rec in reader:
        line = reader.line_num
        kind = (rec["Type"] or "").strip()
        if kind == PAYOUT_TYPE:
            result.payouts += 1
            continue
        if kind not in LINE_TYPES:
            result.problems.append(Problem(line, f"unknown type {kind!r}"))
            continue
        try:
            row = _row(line, rec)
        except ValueError as e:
            result.problems.append(Problem(line, str(e)))
            continue
        result.rows.append(row)
        result.listings[row.listing] += 1
    return result


def parse(file: str | Path | IO[str]) -> ParsedFile:
    """Parse an Airbnb earnings CSV given as a path (read as utf-8-sig) or an open text file."""
    if isinstance(file, str | Path):
        try:
            with open(file, encoding="utf-8-sig", newline="") as f:
                return _parse_stream(f)
        except (OSError, UnicodeDecodeError) as e:
            raise FileError(f"cannot read {file}: {e}") from e
    return _parse_stream(file)


# --- plan and apply ---------------------------------------------------------------------------


@dataclass
class Change:
    field: str
    old: str
    new: str

    def __str__(self) -> str:
        return f"{self.field}: {self.old} -> {self.new}"


@dataclass
class PlannedBooking:
    code: str
    listing: str
    guest: str
    check_in: date
    check_out: date
    lines: list[Row]
    booking_id: int | None = None  # set for updates of an existing booking
    changes: list[Change] = field(default_factory=list)


@dataclass
class ImportPlan:
    needs_listing_choice: bool = False
    listings_found: Counter = field(default_factory=Counter)
    listings: list[str] = field(default_factory=list)  # the listings to import
    save_listings: bool = False  # listings were given: save them to the setting on apply
    new: list[PlannedBooking] = field(default_factory=list)
    updated: list[PlannedBooking] = field(default_factory=list)
    skipped_payouts: int = 0
    skipped_known_lines: int = 0
    skipped_listings: Counter = field(default_factory=Counter)  # rows of other listings
    problems: list[Problem] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


@dataclass
class ImportSummary:
    new: int = 0
    updated: int = 0
    lines_added: int = 0
    skipped_payouts: int = 0
    skipped_known_lines: int = 0
    skipped_listings: Counter = field(default_factory=Counter)
    problems: list[Problem] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    waiting: int = 0  # lines of the imported or updated bookings still waiting for a rate


def _line_key(r: Row | BookingLine) -> tuple:
    amount = r.amount if isinstance(r, Row) else r.amount_minor
    return (r.type, r.date, r.currency, amount)


def _booking_source(rows: list[Row]) -> Row:
    """The row that sets dates, listing and guest: latest-dated Reservation, else any row."""
    candidates = [r for r in rows if r.type == "Reservation"] or rows
    return max(candidates, key=lambda r: r.date)


def plan_import(
    conn: Connection, parsed: ParsedFile, listings: list[str] | None = None
) -> ImportPlan:
    """What importing `parsed` would do. Reads only."""
    plan = ImportPlan(
        listings_found=Counter(parsed.listings),
        skipped_payouts=parsed.payouts,
        problems=list(parsed.problems),
    )
    if listings is None:
        listings = repo.load_settings(conn).property_listings
    else:
        plan.save_listings = True
    plan.listings = list(listings)
    if not plan.listings:
        plan.needs_listing_choice = True
        return plan

    by_code: dict[str, list[Row]] = {}
    for row in parsed.rows:
        if row.listing not in plan.listings:
            plan.skipped_listings[row.listing] += 1
        elif row.end <= row.start:
            plan.problems.append(Problem(row.line, "stay has no nights"))
        else:
            by_code.setdefault(row.code, []).append(row)

    for code, rows in by_code.items():
        source = _booking_source(rows)
        existing = repo.find_booking_by_code(conn, code)
        known = set()
        if existing:
            known = {_line_key(line) for line in repo.list_lines(conn, existing.id)}
        fresh = []
        for row in rows:
            if _line_key(row) in known:
                plan.skipped_known_lines += 1
            else:
                known.add(_line_key(row))
                fresh.append(row)
        planned = PlannedBooking(
            code, source.listing, source.guest, source.start, source.end, fresh
        )
        if existing is None:
            plan.new.append(planned)
            continue
        planned.booking_id = existing.id
        for name, old, new in (
            ("check-in", existing.check_in, source.start),
            ("check-out", existing.check_out, source.end),
            ("listing", existing.listing, source.listing),
            ("guest name", existing.guest_name, source.guest),
        ):
            if old != new:
                planned.changes.append(Change(name, str(old or ""), str(new)))
        if fresh or planned.changes:
            plan.updated.append(planned)

    _warn_overlaps(conn, plan)
    return plan


def _warn_overlaps(conn: Connection, plan: ImportPlan) -> None:
    touched = {p.code for p in plan.new + plan.updated}
    # (label, listing, start, end, touched) of existing bookings, replaced by planned values
    stays = {}
    for b in repo.list_bookings(conn):
        if b.listing in plan.listings or b.airbnb_code in touched:
            stays[b.airbnb_code or f"booking {b.id}"] = (b.listing, b.check_in, b.check_out)
    for p in plan.new + plan.updated:
        stays[p.code] = (p.listing, p.check_in, p.check_out)
    for (a, (la, sa, ea)), (b, (lb, sb, eb)) in combinations(sorted(stays.items()), 2):
        if (a in touched or b in touched) and sa < eb and sb < ea:
            plan.warnings.append(
                f"overlapping stays: {a} ({la}, {sa} to {ea}) and {b} ({lb}, {sb} to {eb})"
            )


def _to_line(booking_id: int, r: Row) -> BookingLine:
    return BookingLine(
        booking_id=booking_id,
        type=r.type,
        date=r.date,
        currency=r.currency,
        amount_minor=r.amount,
        service_fee_minor=r.service_fee,
        cleaning_fee_minor=r.cleaning_fee,
        gross_minor=r.gross,
    )


def apply_import(conn: Connection, plan: ImportPlan, today: date | None = None) -> ImportSummary:
    """Do what `plan` says, in one transaction, then convert what waits for a rate (one fetch
    per currency). `guests` and `notes` are never written."""
    summary = ImportSummary(
        skipped_payouts=plan.skipped_payouts,
        skipped_known_lines=plan.skipped_known_lines,
        skipped_listings=Counter(plan.skipped_listings),
        problems=list(plan.problems),
        warnings=list(plan.warnings),
    )
    if plan.needs_listing_choice:
        return summary
    touched: list[int] = []
    with repo.transaction(conn):
        if plan.save_listings:
            settings = repo.load_settings(conn)
            settings.property_listings = list(plan.listings)
            repo.save_settings(conn, settings)
        for p in plan.new:
            booking = Booking(
                check_in=p.check_in,
                check_out=p.check_out,
                airbnb_code=p.code,
                listing=p.listing,
                guest_name=p.guest,
            )
            booking_id = repo.create_booking(conn, booking)
            touched.append(booking_id)
            summary.new += 1
            summary.lines_added += _add_lines(conn, booking_id, p.lines)
        for p in plan.updated:
            booking = repo.get_booking(conn, p.booking_id)
            booking.check_in, booking.check_out = p.check_in, p.check_out
            booking.listing, booking.guest_name = p.listing, p.guest
            repo.update_booking(conn, booking)
            touched.append(booking.id)
            summary.updated += 1
            summary.lines_added += _add_lines(conn, booking.id, p.lines)
    convert_waiting(conn, today or date.today())
    summary.waiting = sum(
        line.amount_usd is None for i in touched for line in repo.list_lines(conn, i)
    )
    return summary


def _add_lines(conn: Connection, booking_id: int, rows: list[Row]) -> int:
    return sum(repo.add_line(conn, _to_line(booking_id, r)) for r in rows)
