from dataclasses import dataclass, field
from datetime import date

from rios_de_asia_accounting.money import USD_RATE

# Money is in US cents. A converted entry also keeps what was typed or imported: the amount
# in minor units of its currency, the rate (currency units per USD x 1 000 000) and the
# rate's date. The USD amount and rate are None while the entry waits for a rate.


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
    rate_date: date | None = None
    amount_usd: int | None = None
    service_fee_usd: int | None = None
    gross_usd: int | None = None
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
    # Derived from booking_lines by the booking_totals view (US cents); ignored when saving.
    nights: int = 0
    net_payout: int = 0
    cohost_cost: int = 0
    gross: int = 0
    airbnb_fee: int = 0
    waiting: bool = False  # some line waits for a rate and counts as nothing


@dataclass
class ExchangeRate:
    date: date
    currency: str
    rate: int


@dataclass
class Expense:
    date: date
    amount: int | None  # US cents, None while waiting for a rate
    category: str
    booking_id: int | None = None
    useful_life_days: int | None = None
    description: str | None = None
    recurring_expense_id: int | None = None
    id: int | None = None
    original_minor: int | None = None
    currency: str = "USD"
    rate: int | None = None
    rate_date: date | None = None

    def __post_init__(self) -> None:
        # given only a USD amount: it is also what was typed
        if self.original_minor is None and self.amount is not None and self.currency == "USD":
            self.original_minor = self.amount
            self.rate = USD_RATE
            self.rate_date = self.date


@dataclass
class RecurringExpense:
    description: str
    amount_minor: int  # in the template's currency, converted per generated expense
    category: str
    start_month: str  # YYYY-MM
    end_month: str | None = None  # YYYY-MM
    id: int | None = None
    currency: str = "USD"


@dataclass
class Settings:
    long_term_rent_usd: int | None = 0  # US cents per month, None while waiting for a rate
    # what was typed: original_minor, currency, date (the reference day), rate, rate_date
    long_term_rent_entered: dict | None = None
    currency: str = "COP"
    per_booking_allocation: str = "check_in"  # or "spread"
    property_listings: list[str] = field(default_factory=list)
    backup_keep: int = 30


@dataclass
class Inputs:
    """Everything the allocation engine needs."""

    bookings: list[Booking]
    expenses: list[Expense]
    settings: Settings


@dataclass
class Day:
    """One row of the per-day view; money in US cents."""

    date: date
    occupied: bool = False
    income: int = 0
    cost_fixed: int = 0
    cost_per_night: int = 0
    cost_per_booking: int = 0
    cost_maintenance: int = 0
    cost_capex: int = 0
    cost_tax: int = 0

    @property
    def costs(self) -> int:
        return (
            self.cost_fixed
            + self.cost_per_night
            + self.cost_per_booking
            + self.cost_maintenance
            + self.cost_capex
            + self.cost_tax
        )

    @property
    def profit(self) -> int:
        return self.income - self.costs
