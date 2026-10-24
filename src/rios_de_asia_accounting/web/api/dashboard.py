from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import date

from flask import request

from rios_de_asia_accounting import metrics
from rios_de_asia_accounting.conversion import waiting_count
from rios_de_asia_accounting.recurring import load_days
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.web.api.common import bp, error, today
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.forms import parse_date, parse_month

# (label, Metrics attribute, kind); money kinds are US cents
ROWS = [
    ("Available nights", "available_nights", "int"),
    ("Occupied nights", "occupied_nights", "int"),
    ("Occupancy", "occupancy", "pct"),
    ("ADR", "adr", "money"),
    ("RevPAR", "revpar", "money"),
    ("Income", "income", "money"),
    ("Total cost", "total_cost", "money"),
    ("Profit", "profit", "money"),
    ("Variable cost per night", "variable_cost_per_night", "money"),
    ("Break-even occupancy", "break_even_occupancy", "pct"),
    ("Long-term rental benchmark", "benchmark", "money"),
    ("Profit vs. long-term rental", "profit_vs_long_term", "money"),
]


COST_LABELS = {
    "cost_fixed": "Fixed",
    "cost_per_night": "Per night",
    "cost_per_booking": "Per booking",
    "cost_maintenance": "Maintenance",
    "cost_capex": "Capex depreciation",
    "cost_tax": "Tax",
}


def _last_month(today: date) -> date:
    first = today.replace(day=1)
    return date(first.year - (first.month == 1), (first.month - 2) % 12 + 1, 1)


@dataclass
class Dashboard:
    """The dashboard's data before any formatting; turned into JSON by `dashboard()`."""

    messages: list[str]
    waiting: int
    form: dict[str, str]
    days: list = field(default_factory=list)
    columns: list[tuple[str, metrics.DateRange]] = field(default_factory=list)
    summaries: list = field(default_factory=list)
    capex: list[float | None] = field(default_factory=list)
    breakdown_range: metrics.DateRange | None = None
    breakdown: list[tuple[str, str, int, float | None]] = field(default_factory=list)

    @property
    def empty(self) -> bool:
        return not self.days


def build_dashboard(conn, today: date, args: Mapping[str, str]) -> Dashboard:
    """Period handling (month, custom range, messages) and the figures for every column."""
    messages: list[str] = []
    month = _last_month(today)
    month_raw = args.get("month", "").strip()
    month_ok = True
    if month_raw:
        try:
            month = parse_month(month_raw)
        except ValueError as e:
            messages.append(str(e))
            month_ok = False

    custom = None
    start_raw, end_raw = args.get("from", "").strip(), args.get("to", "").strip()
    if start_raw or end_raw:
        try:
            if not (start_raw and end_raw):
                raise ValueError("enter both a from and a to date")
            start, end = parse_date(start_raw), parse_date(end_raw)
            if start > end:
                raise ValueError("the from date must not be after the to date")
            custom = metrics.custom(start, end)
        except ValueError as e:
            messages.append(str(e))

    days = load_days(conn, today)
    result = Dashboard(
        messages=messages,
        waiting=waiting_count(conn),
        form={
            "month": month.strftime("%Y-%m") if month_ok else month_raw,
            "from": start_raw,
            "to": end_raw,
        },
    )
    if not days:
        return result
    settings = repo.load_settings(conn)
    ranges = metrics.standard_ranges(today, days[0].date)
    columns = [
        ("All time", ranges["all_time"]),
        ("Last 90 days", ranges["last_90"]),
        ("Last 30 days", ranges["last_30"]),
        ("This month", ranges["this_month"]),
    ]
    if month_ok:
        columns.append((f"Month {month:%Y-%m}", metrics.month_range(month.year, month.month)))
    if custom:
        columns.append(("Custom", custom))
    expenses = repo.list_expenses(conn)
    result.days = days
    result.columns = columns
    result.summaries = [metrics.summarize(days, rng, settings) for _, rng in columns]
    result.capex = [metrics.capex_book_value(expenses, rng.end) for _, rng in columns]
    result.breakdown_range = custom or metrics.month_range(month.year, month.month)
    result.breakdown = [
        (column, COST_LABELS[column], amount, share)
        for column, amount, share in metrics.expense_breakdown(days, result.breakdown_range)
    ]
    return result


def _number(value: float | None, kind: str):
    if value is None:
        return None
    return int(value) if kind == "money" else value


def _range(rng: metrics.DateRange) -> dict:
    return {"start": rng.start.isoformat(), "end": rng.end.isoformat()}


@bp.get("/dashboard")
def dashboard():
    data = build_dashboard(get_db(), today(), request.args)
    body: dict = {
        "form": data.form,
        "waiting": data.waiting,
        "empty": data.empty,
        "columns": [],
        "rows": [],
        "rolling_90": [],
        "breakdown": None,
        "notices": [error(text) for text in data.messages],
    }
    if not data.empty:
        body["columns"] = [{"label": label, **_range(rng)} for label, rng in data.columns]
        for label, attr, kind in ROWS:
            body["rows"].append(
                {
                    "key": attr,
                    "label": label,
                    "kind": kind,
                    "values": [_number(getattr(m, attr), kind) for m in data.summaries],
                }
            )
        body["rows"].append(
            {
                "key": "capex_book_value",
                "label": "Remaining capex book value",
                "kind": "money",
                "values": [_number(v, "money") for v in data.capex],
            }
        )
        body["rolling_90"] = [
            {"date": p.date.isoformat(), "adr": p.adr, "revpar": p.revpar, "occupancy": p.occupancy}
            for p in metrics.rolling_90(data.days)
        ]
        body["breakdown"] = {
            **_range(data.breakdown_range),
            "items": [
                {"key": key, "label": label, "amount": amount, "share": share}
                for key, label, amount, share in data.breakdown
            ],
        }
    return body
