"""Parsing, formatting and validation helpers shared by the data entry screens."""

import re
from collections.abc import Callable, Collection, Mapping
from datetime import date
from decimal import Decimal
from typing import Any

from airbnb_books.model import Booking
from airbnb_books.storage.repo import ValidationError

_MONEY = re.compile(r"\d+|\d{1,3}(?:[.,  ]\d{3})+")
_HOURS_DECIMAL = re.compile(r"\d+(?:[.,]\d+)?")
_HOURS_CLOCK = re.compile(r"(\d+):([0-5]\d)")
_RATE = re.compile(r"\d+(?:\.\d{1,2})?")
_CURRENCY = re.compile(r"[A-Za-z]{3}")


def parse_money(text: str) -> int:
    """Whole pesos: digits with optional . , or space thousands separators."""
    text = text.strip()
    if not _MONEY.fullmatch(text):
        raise ValueError("enter whole pesos, e.g. 1.234.567 (no decimals)")
    return int(re.sub(r"\D", "", text))


def format_money(pesos: int) -> str:
    return f"{pesos:,}".replace(",", ".")


def parse_hours(text: str) -> int:
    """Hours as 1.5, 1,5 or 1:30; returns whole minutes."""
    text = text.strip()
    if m := _HOURS_CLOCK.fullmatch(text):
        return int(m[1]) * 60 + int(m[2])
    if _HOURS_DECIMAL.fullmatch(text):
        return int((Decimal(text.replace(",", ".")) * 60).to_integral_value())
    raise ValueError("enter hours as 1.5, 1,5 or 1:30")


def format_hours(minutes: int) -> str:
    """Minutes as decimal hours, e.g. 90 -> '1.5'."""
    hours = (Decimal(minutes) / 60).quantize(Decimal("0.01")).normalize()
    return f"{hours:f}"


def parse_rate(text: str) -> int:
    """COP per unit with up to 2 decimals after a dot; returns the stored scaled integer."""
    cleaned = text.strip().replace(",", "")
    if not _RATE.fullmatch(cleaned):
        raise ValueError("enter a rate with up to 2 decimals after a dot, e.g. 4100.50")
    return int(Decimal(cleaned) * 100)


def format_rate(rate: int) -> str:
    text = f"{Decimal(rate) / 100:.2f}"
    return text[:-3] if text.endswith(".00") else text


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


def parse_currency(text: str) -> str:
    if not _CURRENCY.fullmatch(text.strip()):
        raise ValueError("enter a 3-letter currency code, e.g. USD")
    return text.strip().upper()


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

    def money(self, field: str, **kw: Any) -> int | None:
        return self.parsed(field, parse_money, **kw)

    def hours(self, field: str, **kw: Any) -> int | None:
        return self.parsed(field, parse_hours, **kw)

    def rate(self, field: str, **kw: Any) -> int | None:
        return self.parsed(field, parse_rate, **kw)

    def day(self, field: str, **kw: Any) -> date | None:
        return self.parsed(field, parse_date, **kw)

    def month(self, field: str, **kw: Any) -> date | None:
        return self.parsed(field, parse_month, **kw)

    def whole(self, field: str, **kw: Any) -> int | None:
        return self.parsed(field, parse_int, **kw)

    def currency(self, field: str, **kw: Any) -> str | None:
        return self.parsed(field, parse_currency, **kw)

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
