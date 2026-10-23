"""The dashboard on `/`: one metrics table with a column per period."""

from datetime import date

from flask import Flask, render_template, request

from airbnb_books import metrics
from airbnb_books.recurring import load_days
from airbnb_books.storage import repo
from airbnb_books.web.app_db import get_db
from airbnb_books.web.forms import format_money, parse_date, parse_month

# (label, Metrics attribute, kind); money kinds are COP, "minutes" is shown as hours
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
    ("Hours", "minutes", "hours"),
    ("Profit per hour", "profit_per_hour", "money"),
    ("Profit after own time", "profit_after_own_time", "money"),
]


def _cell(value: float | None, kind: str) -> tuple[str, bool]:
    """(text, negative); None is a dash (decision 10)."""
    if value is None:
        return "–", False
    if kind == "pct":
        return f"{value * 100:.1f} %", False
    if kind == "hours":
        return f"{value / 60:.1f}", False
    if kind == "money":
        text = format_money(int(value))
        return (text.replace("-", "−"), value < 0)
    return str(value), False


def _last_month(today: date) -> date:
    first = today.replace(day=1)
    return date(first.year - (first.month == 1), (first.month - 2) % 12 + 1, 1)


def _header(rng: metrics.DateRange) -> str:
    return f"{rng.start} – {rng.end}"


def register(app: Flask) -> None:
    @app.route("/")
    def index() -> str:
        conn = get_db()
        today = app.config.get("TODAY") or date.today()
        messages: list[str] = []
        args = request.args

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
        needing = sum(1 for b in repo.list_bookings(conn) if b.needs_rate)
        form = {
            "month": month.strftime("%Y-%m") if month_ok else month_raw,
            "from": start_raw,
            "to": end_raw,
        }
        page = {"messages": messages, "needing": needing, "form": form}
        if not days:
            return render_template("index.html", empty=True, **page)

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
        summaries = [metrics.summarize(days, rng, settings) for _, rng in columns]
        rows = [
            (label, [_cell(getattr(m, attr), kind) for m in summaries])
            for label, attr, kind in ROWS
        ]
        heads = [(label, _header(rng)) for label, rng in columns]
        return render_template("index.html", empty=False, heads=heads, rows=rows, **page)
