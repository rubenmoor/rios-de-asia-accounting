from dataclasses import dataclass
from datetime import date


@dataclass
class BookingLine:
    booking_id: int
    type: str
    date: date
    currency: str
    amount_minor: int
    service_fee_minor: int = 0
    cleaning_fee_minor: int = 0
    gross_minor: int | None = None
    rate: int | None = None
    amount_cop: int | None = None
    id: int | None = None


@dataclass
class Booking:
    check_in: date
    check_out: date
    airbnb_code: str | None = None
    listing: str | None = None
    guest_name: str | None = None
    guests: int | None = None
    notes: str | None = None
    id: int | None = None
    # Derived from booking_lines by the booking_totals view; ignored when saving.
    nights: int = 0
    net_payout: int = 0
    cohost_cost: int = 0
    gross: int = 0
    airbnb_fee: int = 0
    needs_rate: bool = False


@dataclass
class ExchangeRate:
    date: date
    currency: str
    rate: int
