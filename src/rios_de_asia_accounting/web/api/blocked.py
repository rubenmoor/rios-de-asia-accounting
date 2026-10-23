from datetime import date, timedelta

from flask import request

from rios_de_asia_accounting.model import BlockedDay
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.web.api.common import bp, info, invalid, notice, ok, read_form
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.forms import Form

REASONS = ["buffer", "owner", "maintenance", "other"]
MAX_RANGE_DAYS = 731


def _inside_bookings(conn, days: list[date]) -> list[date]:
    """Days on which a guest sleeps (check-in up to the night before check-out)."""
    if not days:
        return []
    bookings = repo.list_bookings(conn, min(days), max(days) + timedelta(days=1))
    return [d for d in days if any(b.check_in <= d < b.check_out for b in bookings)]


def read_range(form: Form) -> None:
    """Parse the posted day range, reason and note of a "block days" request."""
    first = form.day("from", required=True)
    last = form.day("to", required=True)
    form.choice("reason", REASONS)
    form.text("note")
    if first and last:
        if last < first:
            form.error("to", "the last day must not be before the first day")
        elif (last - first).days >= MAX_RANGE_DAYS:
            form.error("to", f"at most {MAX_RANGE_DAYS} days at once")


def block_range(conn, form: Form) -> list[tuple[str, str]]:
    """Block the days of a valid range form; returns the (level, text) messages."""
    first, last = form.values["from"], form.values["to"]
    days = [first + timedelta(days=i) for i in range((last - first).days + 1)]
    taken = {b.date for b in repo.list_blocked_days(conn, first, last + timedelta(days=1))}
    fresh = [d for d in days if d not in taken]
    for day in fresh:
        repo.set_blocked_day(conn, BlockedDay(day, form.values["reason"], form.values["note"]))
    message = f"{len(fresh)} day(s) blocked"
    if taken:
        message += f"; {len(taken)} already blocked and skipped"
    messages = [("info", message + ".")]
    booked = _inside_bookings(conn, fresh)
    if booked:
        messages.append(
            (
                "warning",
                f"{len(booked)} blocked day(s) fall inside a booking: "
                + ", ".join(str(d) for d in booked[:10])
                + (" …" if len(booked) > 10 else ""),
            )
        )
    return messages


def _item(b: BlockedDay) -> dict:
    return {"date": b.date.isoformat(), "reason": b.reason, "note": b.note}


def _find(day: str) -> BlockedDay | None:
    try:
        return repo.get_blocked_day(get_db(), date.fromisoformat(day))
    except ValueError:
        return None


@bp.get("/blocked-days")
def list_blocked_days():
    form = Form(request.args)
    first = form.day("from")
    last = form.day("to")
    if not form.ok:
        return invalid(form)
    found = repo.list_blocked_days(get_db(), first, last + timedelta(days=1) if last else None)
    return [_item(b) for b in reversed(found)]


@bp.get("/blocked-days/options")
def blocked_day_options():
    return {"reasons": REASONS}


@bp.post("/blocked-days")
def create_blocked_days():
    form = read_form()
    read_range(form)
    if not form.ok:
        return invalid(form)
    return ok(None, [notice(level, text) for level, text in block_range(get_db(), form)])


@bp.put("/blocked-days/<day>")
def update_blocked_day(day: str):
    item = _find(day)
    if item is None:
        return {"error": "blocked day not found"}, 404
    form = read_form()
    reason = form.choice("reason", REASONS)
    note = form.text("note")
    if form.ok:
        item = BlockedDay(item.date, reason, note)
        form.apply(lambda: repo.set_blocked_day(get_db(), item))
    if not form.ok:
        return invalid(form)
    return ok(_item(item), [info("Blocked day saved.")])


@bp.delete("/blocked-days/<day>")
def delete_blocked_day(day: str):
    if _find(day) is None:
        return {"error": "blocked day not found"}, 404
    repo.delete_blocked_day(get_db(), date.fromisoformat(day))
    return ok(None, [info("Blocked day deleted.")])
