from dataclasses import dataclass, field
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


@dataclass
class Expense:
    date: date
    amount: int
    category: str
    booking_id: int | None = None
    useful_life_days: int | None = None
    description: str | None = None
    recurring_expense_id: int | None = None
    id: int | None = None


@dataclass
class RecurringExpense:
    description: str
    amount: int
    category: str
    start_month: str  # YYYY-MM
    end_month: str | None = None  # YYYY-MM
    id: int | None = None


@dataclass
class TimeEntry:
    date: date
    minutes: int
    booking_id: int | None = None
    description: str | None = None
    id: int | None = None


@dataclass
class Settings:
    hourly_value_cop: int = 0
    long_term_rent_cop_per_month: int = 0
    currency: str = "COP"
    per_booking_allocation: str = "check_in"  # or "spread"
    property_listings: list[str] = field(default_factory=list)
    backup_keep: int = 30


@dataclass
class Inputs:
    """Everything the allocation engine needs."""

    bookings: list[Booking]
    expenses: list[Expense]
    time_log: list[TimeEntry]
    settings: Settings


@dataclass
class Day:
    """One row of the per-day view; money in whole COP, time in minutes."""

    date: date
    occupied: bool = False
    income: int = 0
    cost_fixed: int = 0
    cost_per_night: int = 0
    cost_per_booking: int = 0
    cost_maintenance: int = 0
    cost_capex: int = 0
    cost_tax: int = 0
    minutes: int = 0

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
