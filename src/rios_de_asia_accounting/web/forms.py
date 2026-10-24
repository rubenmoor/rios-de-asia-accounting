"""Parsing, formatting and validation helpers shared by the data entry screens."""

import re
from collections.abc import Callable, Collection, Mapping
from datetime import date
from typing import Any

from rios_de_asia_accounting.model import Booking
from rios_de_asia_accounting.storage.repo import ValidationError

_WHOLE = re.compile(r"\d+|\d{1,3}(?:[.,  ]\d{3})+")
_DECIMALS = re.compile(r"(.*)[.,](\d{1,2})")
CURRENCIES = ["USD", "COP", "EUR"]  # money entry (decision 39)


def parse_amount(text: str, currency: str) -> int:
    """An amount in minor units of `currency` (decision 39).

    COP: whole pesos, with optional . , or space thousands separators. USD and EUR: up to 2
    decimals; the last . or , followed by 1-2 digits at the end is the decimal mark, other
    . , and spaces are thousands separators ("1.234,50" = "1,234.50", "1.234" = 1234.00).
    """
    text = text.strip()
    if currency == "COP":
        if not _WHOLE.fullmatch(text):
            raise ValueError("enter whole pesos, e.g. 1.234.567 (no decimals)")
        return int(re.sub(r"\D", "", text)) * 100
    whole, cents = text, "0"
    if m := _DECIMALS.fullmatch(text):
        whole, cents = m.group(1) or "0", m.group(2).ljust(2, "0")
    if not _WHOLE.fullmatch(whole):
        raise ValueError("enter an amount with up to 2 decimals, e.g. 1.234,50 or 1,234.50")
    return int(re.sub(r"\D", "", whole)) * 100 + int(cents)


def format_amount(minor: int, currency: str = "USD") -> str:
    """COP as whole pesos (1.234.567), other currencies with 2 decimals (1.234,56)."""
    sign = "-" if minor < 0 else ""
    whole, cents = divmod(abs(minor), 100)
    grouped = f"{whole:,}".replace(",", ".")
    return f"{sign}{grouped}" if currency == "COP" else f"{sign}{grouped},{cents:02d}"


def parse_date(text: str) -> date:
    try:
        return date.fromisoformat(text.strip())
    except ValueError:
        raise ValueError("enter a date as YYYY-MM-DD") from None


def parse_month(text: str) -> date:
    """A month as the date of its first day."""
    try:
        return date.fromisoformat(text.strip() + "-01")
    except ValueError:
        raise ValueError("enter a month as YYYY-MM") from None


def parse_int(text: str) -> int:
    try:
        return int(text.strip())
    except ValueError:
        raise ValueError("enter a whole number") from None


class Form:
    """A POST turned into parsed values plus at most one error per field.

    Each getter records an error instead of raising and returns None for an
    empty or invalid field; `raw` keeps what was typed so the form can be re-shown.
    """

    def __init__(
        self, data: Mapping[str, str] | None = None, lists: Mapping[str, list[str]] | None = None
    ) -> None:
        self.raw: dict[str, str] = dict(data or {})
        self.lists: dict[str, list[str]] = {k: list(v) for k, v in (lists or {}).items()}
        self.values: dict[str, Any] = {}
        self.errors: dict[str, str] = {}

    def raw_list(self, field: str) -> list[str]:
        """Repeated values of a multi-value field (checkboxes), blanks dropped."""
        return [v.strip() for v in self.lists.get(field, []) if v.strip()]

    def error(self, field: str, message: str) -> None:
        self.errors.setdefault(field, message)

    @property
    def ok(self) -> bool:
        return not self.errors

    def text(self, field: str, required: bool = False) -> str | None:
        value = self.raw.get(field, "").strip()
        if not value:
            if required:
                self.error(field, "required")
            value = ""
        self.values[field] = value or None
        return self.values[field]

    def parsed(
        self,
        field: str,
        parser: Callable[[str], Any],
        required: bool = False,
        minimum: int | None = None,
        positive: bool = False,
    ) -> Any:
        """Parse a field; `minimum` and `positive` check numbers (> 0 when positive)."""
        value = None
        text = self.raw.get(field, "").strip()
        if not text:
            if required:
                self.error(field, "required")
        else:
            try:
                value = parser(text)
            except ValueError as e:
                self.error(field, str(e))
            else:
                if positive and value <= 0:
                    self.error(field, "must be greater than zero")
                elif minimum is not None and value < minimum:
                    self.error(field, f"must be at least {minimum}")
        self.values[field] = value
        return value

    def money(self, field: str, currency_field: str = "currency", **kw: Any) -> int | None:
        """An amount in minor units of the currency chosen in `currency_field`."""
        currency = self.choice(currency_field, CURRENCIES)
        return self.parsed(field, lambda text: parse_amount(text, currency or "USD"), **kw)

    def day(self, field: str, **kw: Any) -> date | None:
        return self.parsed(field, parse_date, **kw)

    def month(self, field: str, **kw: Any) -> date | None:
        return self.parsed(field, parse_month, **kw)

    def whole(self, field: str, **kw: Any) -> int | None:
        return self.parsed(field, parse_int, **kw)

    def choice(self, field: str, options: Collection[str], required: bool = True) -> str | None:
        value = self.raw.get(field, "").strip()
        if value in options:
            self.values[field] = value
            return value
        self.values[field] = None
        if value or required:
            self.error(field, "choose one of the options" if value else "required")
        return None

    def apply(self, action: Callable[[], Any]) -> Any:
        """Run a repo write; a ValidationError becomes a form-level error (key '')."""
        try:
            return action()
        except ValidationError as e:
            self.error("", str(e))
            return None


def booking_options(bookings: list[Booking]) -> list[tuple[int, str]]:
    """(id, label) for a booking <select>, newest first."""
    ordered = sorted(bookings, key=lambda b: (b.check_in, b.id or 0), reverse=True)
    return [
        (
            b.id or 0,
            " · ".join([f"{b.check_in} – {b.check_out}", b.guest_name or "-", b.listing or "-"]),
        )
        for b in ordered
    ]
