from datetime import date, timedelta

from flask import request

from rios_de_asia_accounting.model import BlockedDay
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.web.api.common import bp, info, invalid, notice, ok, read_form
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.blocked import REASONS, block_range, read_range
from rios_de_asia_accounting.web.forms import Form


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
