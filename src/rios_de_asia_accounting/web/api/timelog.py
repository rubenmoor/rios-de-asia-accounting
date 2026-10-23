from datetime import date, timedelta

from flask import request

from rios_de_asia_accounting.model import TimeEntry
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.web.api.common import bp, info, invalid, ok, read_form
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.forms import Form, booking_options


def _read(form: Form) -> None:
    form.day("date", required=True)
    form.hours("hours", required=True, positive=True)
    booking = form.whole("booking_id")
    form.text("description")
    if booking is not None and repo.get_booking(get_db(), booking) is None:
        form.error("booking_id", "choose one of the bookings")


def _fill(form: Form, entry: TimeEntry) -> None:
    entry.date = form.values["date"]
    entry.minutes = form.values["hours"]
    entry.booking_id = form.values["booking_id"]
    entry.description = form.values["description"]


def _item(e: TimeEntry) -> dict:
    return {
        "id": e.id,
        "date": e.date.isoformat(),
        "minutes": e.minutes,
        "booking_id": e.booking_id,
        "description": e.description,
    }


def _not_found():
    return {"error": "time entry not found"}, 404


@bp.get("/time")
def list_time():
    form = Form(request.args)
    first = form.day("from")
    last = form.day("to")
    if not form.ok:
        return invalid(form)
    found = repo.list_time_entries(get_db(), first, last + timedelta(days=1) if last else None)
    found.sort(key=lambda e: (e.date, e.id or 0), reverse=True)
    return [_item(e) for e in found]


@bp.get("/time/options")
def time_options():
    bookings = booking_options(repo.list_bookings(get_db()))
    return {"bookings": [{"id": i, "label": label} for i, label in bookings]}


@bp.get("/time/<int:entry_id>")
def time_detail(entry_id: int):
    entry = repo.get_time_entry(get_db(), entry_id)
    return _item(entry) if entry else _not_found()


def _save(entry: TimeEntry, saving):
    conn = get_db()
    form = read_form()
    _read(form)
    if form.ok:
        _fill(form, entry)
        form.apply(lambda: saving(conn, entry))
    if not form.ok:
        return invalid(form)
    return ok(_item(entry), [info("Time entry saved.")])


@bp.post("/time")
def create_time():
    return _save(TimeEntry(date.today(), 0), repo.create_time_entry)


@bp.put("/time/<int:entry_id>")
def update_time(entry_id: int):
    entry = repo.get_time_entry(get_db(), entry_id)
    if entry is None:
        return _not_found()
    return _save(entry, repo.update_time_entry)


@bp.delete("/time/<int:entry_id>")
def delete_time(entry_id: int):
    conn = get_db()
    if repo.get_time_entry(conn, entry_id) is None:
        return _not_found()
    repo.delete_time_entry(conn, entry_id)
    return ok(None, [info("Time entry deleted.")])
