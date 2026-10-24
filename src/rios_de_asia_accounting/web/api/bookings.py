from datetime import timedelta

from flask import Response, request

from rios_de_asia_accounting.conversion import convert_waiting
from rios_de_asia_accounting.model import Booking, BookingLine
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.web.api.common import (
    bp,
    info,
    invalid,
    money_options,
    ok,
    read_form,
    saved_notice,
    today,
    warning,
)
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.forms import Form


def _is_imported(lines: list) -> bool:
    return any(line.type != "Manual" for line in lines)


def _manual_line(lines: list) -> BookingLine | None:
    return next((line for line in lines if line.type == "Manual"), None)


def _overlap_message(conn, booking: Booking) -> str | None:
    others = [
        b
        for b in repo.list_bookings(conn, booking.check_in, booking.check_out)
        if b.id != booking.id
    ]
    if not others:
        return None
    names = ", ".join(f"{b.check_in} – {b.check_out} ({b.guest_name or '-'})" for b in others)
    return f"This stay overlaps another booking: {names}."


def _delete_refused(reason: str) -> str:
    return f"Booking not deleted: {reason}. Delete its expenses first."


def listing_names(conn) -> list[str]:
    names = {b.listing for b in repo.list_bookings(conn) if b.listing}
    names.update(repo.load_settings(conn).property_listings)
    return sorted(names)


def _read(form: Form, imported: bool) -> None:
    """Parse the posted fields; imported bookings only take guests and notes."""
    form.whole("guests", positive=True)
    form.text("notes")
    if imported:
        return
    check_in = form.day("check_in", required=True)
    check_out = form.day("check_out", required=True)
    if check_in and check_out and check_out <= check_in:
        form.error("check_out", "check-out must be after check-in")
    form.money("amount", required=True)
    form.text("airbnb_code")
    form.text("listing")
    form.text("guest_name")


def _line(line: BookingLine) -> dict:
    return {
        "date": line.date.isoformat(),
        "type": line.type,
        "currency": line.currency,
        "amount_minor": line.amount_minor,
        "amount_usd": line.amount_usd,
        "rate": line.rate,
        "rate_date": line.rate_date.isoformat() if line.rate_date else None,
    }


def _summary(b: Booking) -> dict:
    return {
        "id": b.id,
        "check_in": b.check_in.isoformat(),
        "check_out": b.check_out.isoformat(),
        "guest_name": b.guest_name,
        "listing": b.listing,
        "nights": b.nights,
        "net_payout": None if b.waiting else b.net_payout,
        "waiting": b.waiting,
    }


def _detail(conn, booking: Booking) -> dict:
    lines = repo.list_lines(conn, booking.id)
    imported = _is_imported(lines)
    known = not booking.waiting
    manual = None if imported else _manual_line(lines)
    return {
        **_summary(booking),
        "airbnb_code": booking.airbnb_code,
        "guests": booking.guests,
        "notes": booking.notes,
        "imported": imported,
        "gross": booking.gross if known else None,
        "airbnb_fee": booking.airbnb_fee if known else None,
        "cohost_cost": booking.cohost_cost if known else None,
        # what was typed for a hand-entered booking
        "manual_amount": manual.amount_minor if manual else None,
        "manual_currency": manual.currency if manual else None,
        "lines": [_line(line) for line in lines],
    }


def _notices(conn, booking: Booking) -> list[dict]:
    lines = repo.list_lines(conn, booking.id)
    waiting = [line for line in lines if line.amount_usd is None]
    currency = waiting[0].currency if waiting else ""
    notices = [saved_notice("booking", bool(waiting), currency, booking.check_in)]
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
    conn = get_db()
    return {"listings": listing_names(conn), **money_options(conn)}


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
    amount = (form.values["amount"], form.values["currency"])
    form.apply(lambda: repo.create_booking(conn, booking, manual_amount=amount))
    if not form.ok:
        return invalid(form)
    convert_waiting(conn, today())
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
        amount = (form.values["amount"], form.values["currency"])
    form.apply(lambda: repo.update_booking(conn, booking, manual_amount=amount))
    if not form.ok:
        return invalid(form)
    convert_waiting(conn, today())
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
