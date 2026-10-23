"""Read Airbnb's earnings CSV into typed rows. Pure: no database."""

import csv
from collections import Counter
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import IO

from airbnb_books.money import parse_minor

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
