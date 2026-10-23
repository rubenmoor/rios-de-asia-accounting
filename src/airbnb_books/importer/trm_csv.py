"""Read the official Colombian TRM history and load it as USD exchange rates.

Source: datos.gov.co, "Tasa de Cambio Representativa del Mercado - Historico" (dataset 32sa-8pi3),
CSV export. Real format, checked 2026-10-23:
  header   VALOR,UNIDAD,VIGENCIADESDE,VIGENCIAHASTA   (the API variant uses lower-case names and
           ISO timestamps "2026-10-23T00:00:00.000"; both are accepted)
  VALOR    COP per USD, dot as decimal separator, 2 decimals, no thousands separator ("3185.01")
  UNIDAD   always "COP"
  dates    DD/MM/YYYY; VIGENCIADESDE..VIGENCIAHASTA is the validity span (a Friday rate is valid
           Saturday to Monday); the rate is stored at VIGENCIADESDE, and "latest rate on or before"
           covers the rest of the span.
The rate is stored in hundredths of COP per USD, which is what parse_minor yields.
"""

import csv
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path
from sqlite3 import Connection

from airbnb_books.importer.airbnb_csv import FileError, Problem
from airbnb_books.model import ExchangeRate
from airbnb_books.money import parse_minor
from airbnb_books.storage import repo


@dataclass
class ParsedRates:
    rates: list[tuple[date, int]] = field(default_factory=list)
    problems: list[Problem] = field(default_factory=list)


@dataclass
class RatesSummary:
    added: int = 0
    changed: int = 0
    lines_recomputed: int = 0
    needing_rate: int = 0  # bookings still lacking a rate afterwards


def _parse_date(text: str) -> date:
    text = text.strip()
    if text[:4].isdigit():
        return datetime.fromisoformat(text).date()
    return datetime.strptime(text, "%d/%m/%Y").date()


def parse(path: str | Path) -> ParsedRates:
    try:
        with open(path, newline="", encoding="utf-8-sig") as f:
            reader = csv.DictReader(f)
            names = {(n or "").strip().upper(): n for n in reader.fieldnames or []}
            missing = [c for c in ("VALOR", "VIGENCIADESDE") if c not in names]
            if missing:
                raise FileError(f"missing column(s): {', '.join(missing)}")
            result = ParsedRates()
            for row in reader:
                line = reader.line_num
                try:
                    value = (row[names["VALOR"]] or "").strip()
                    day = _parse_date(row[names["VIGENCIADESDE"]] or "")
                    rate = parse_minor(value)
                    if rate <= 0:
                        raise ValueError(f"rate must be positive: {value!r}")
                except (ValueError, TypeError) as e:
                    result.problems.append(Problem(line, str(e)))
                    continue
                result.rates.append((day, rate))
            return result
    except UnicodeDecodeError as e:
        raise FileError(f"not a text file: {e}") from None


def apply_rates(conn: Connection, parsed: ParsedRates, currency: str = "USD") -> RatesSummary:
    added, changed, recomputed = repo.upsert_exchange_rates(
        conn, [ExchangeRate(d, currency, r) for d, r in parsed.rates]
    )
    needing = sum(b.needs_rate for b in repo.list_bookings(conn))
    return RatesSummary(added, changed, recomputed, needing)
