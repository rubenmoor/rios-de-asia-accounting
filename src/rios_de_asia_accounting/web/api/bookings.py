from datetime import timedelta

from flask import Response, request

from rios_de_asia_accounting.model import Booking, BookingLine
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.web.api.common import bp, info, invalid, ok, read_form, warning
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.bookings import (
    _delete_refused,
    _is_imported,
    _listing_names,
    _manual_amount,
    _overlap_message,
    _read,
)
from rios_de_asia_accounting.web.forms import Form


def _line(line: BookingLine) -> dict:
    return {
        "date": line.date.isoformat(),
        "type": line.type,
        "currency": line.currency,
        "amount_minor": line.amount_minor,
        "amount_cop": line.amount_cop,
    }


def _summary(b: Booking) -> dict:
    return {
        "id": b.id,
        "check_in": b.check_in.isoformat(),
        "check_out": b.check_out.isoformat(),
        "guest_name": b.guest_name,
        "listing": b.listing,
        "nights": b.nights,
        "net_payout": None if b.needs_rate else b.net_payout,
        "needs_rate": b.needs_rate,
    }


def _detail(conn, booking: Booking) -> dict:
    lines = repo.list_lines(conn, booking.id)
    imported = _is_imported(lines)
    known = not booking.needs_rate
    return {
        **_summary(booking),
        "airbnb_code": booking.airbnb_code,
        "guests": booking.guests,
        "notes": booking.notes,
        "imported": imported,
        "gross": booking.gross if known else None,
        "airbnb_fee": booking.airbnb_fee if known else None,
        "cohost_cost": booking.cohost_cost if known else None,
        "manual_amount": None if imported else _manual_amount(lines),
        "lines": [_line(line) for line in lines],
    }


def _notices(conn, booking: Booking) -> list[dict]:
    notices = [info("Booking saved.")]
    overlap = _overlap_message(conn, booking)
    if overlap:
        notices.append(warning(overlap))
    return notices


@bp.get("/bookings")
def list_bookings():
    conn = get_db()
    start = Form(request.args)
    first = start.day("from")
    last = start.day("to")
    if not start.ok:
        return invalid(start)
    listing = request.args.get("listing") or None
    found = repo.list_bookings(conn, first, last + timedelta(days=1) if last else None, listing)
    found.sort(key=lambda b: (b.check_in, b.id or 0), reverse=True)
    return [_summary(b) for b in found]


@bp.get("/bookings/options")
def booking_options_api():
    return {"listings": _listing_names(get_db())}


@bp.get("/bookings/<int:booking_id>")
def booking_detail(booking_id: int):
    conn = get_db()
    booking = repo.get_booking(conn, booking_id)
    if booking is None:
        return {"error": "booking not found"}, 404
    return _detail(conn, booking)


@bp.post("/bookings")
def create_booking():
    conn = get_db()
    form = read_form()
    _read(form, False)
    if not form.ok:
        return invalid(form)
    booking = Booking(
        form.values["check_in"],
        form.values["check_out"],
        airbnb_code=form.values["airbnb_code"],
        listing=form.values["listing"],
        guest_name=form.values["guest_name"],
        guests=form.values["guests"],
        notes=form.values["notes"],
    )
    form.apply(
        lambda: repo.create_booking(conn, booking, manual_amount_cop=form.values["net_payout"])
    )
    if not form.ok:
        return invalid(form)
    return ok(_detail(conn, repo.get_booking(conn, booking.id)), _notices(conn, booking))


@bp.put("/bookings/<int:booking_id>")
def update_booking(booking_id: int):
    conn = get_db()
    booking = repo.get_booking(conn, booking_id)
    if booking is None:
        return {"error": "booking not found"}, 404
    imported = _is_imported(repo.list_lines(conn, booking_id))
    form = read_form()
    _read(form, imported)
    if not form.ok:
        return invalid(form)
    booking.guests = form.values["guests"]
    booking.notes = form.values["notes"]
    amount = None
    if not imported:
        booking.check_in = form.values["check_in"]
        booking.check_out = form.values["check_out"]
        booking.airbnb_code = form.values["airbnb_code"]
        booking.listing = form.values["listing"]
        booking.guest_name = form.values["guest_name"]
        amount = form.values["net_payout"]
    form.apply(lambda: repo.update_booking(conn, booking, manual_amount_cop=amount))
    if not form.ok:
        return invalid(form)
    return ok(_detail(conn, repo.get_booking(conn, booking_id)), _notices(conn, booking))


@bp.delete("/bookings/<int:booking_id>")
def delete_booking(booking_id: int) -> Response | tuple:
    conn = get_db()
    if repo.get_booking(conn, booking_id) is None:
        return {"error": "booking not found"}, 404
    form = Form()
    form.apply(lambda: repo.delete_booking(conn, booking_id))
    if not form.ok:
        form.errors[""] = _delete_refused(form.errors[""])
        return invalid(form)
    return ok(None, [info("Booking deleted.")])
