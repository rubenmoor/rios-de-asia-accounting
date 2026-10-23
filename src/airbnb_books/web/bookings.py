"""Booking screens: list, detail, new, edit, delete."""

from datetime import timedelta

from flask import Flask, abort, flash, redirect, render_template, request, url_for
from werkzeug.wrappers import Response

from airbnb_books.model import Booking
from airbnb_books.storage import repo
from airbnb_books.web.app_db import get_db
from airbnb_books.web.forms import Form, format_money


def _is_imported(lines: list) -> bool:
    return any(line.type != "Manual" for line in lines)


def _manual_amount(lines: list) -> int | None:
    return next((line.amount_cop for line in lines if line.type == "Manual"), None)


def _overlaps(conn, booking: Booking) -> list[Booking]:
    return [
        b
        for b in repo.list_bookings(conn, booking.check_in, booking.check_out)
        if b.id != booking.id
    ]


def _warn_overlap(conn, booking: Booking) -> None:
    others = _overlaps(conn, booking)
    if others:
        names = ", ".join(f"{b.check_in} – {b.check_out} ({b.guest_name or '-'})" for b in others)
        flash(f"This stay overlaps another booking: {names}.", "warning")


def _listing_names(conn) -> list[str]:
    names = {b.listing for b in repo.list_bookings(conn) if b.listing}
    names.update(repo.load_settings(conn).property_listings)
    return sorted(names)


def _form_page(conn, booking: Booking | None, form: Form, imported: bool) -> str:
    return render_template(
        "booking_form.html",
        booking=booking,
        form=form,
        imported=imported,
        listings=_listing_names(conn),
        title="Edit booking" if booking else "New booking",
    )


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
    form.money("net_payout", required=True)
    form.text("airbnb_code")
    form.text("listing")
    form.text("guest_name")


def register(app: Flask) -> None:
    def bookings() -> str:
        conn = get_db()
        start = Form(request.args)
        first = start.day("from")
        last = start.day("to")
        listing = request.args.get("listing") or None
        if not start.ok:
            first = last = None
        found = repo.list_bookings(conn, first, last + timedelta(days=1) if last else None, listing)
        found.sort(key=lambda b: (b.check_in, b.id or 0), reverse=True)
        return render_template(
            "bookings.html",
            bookings=found,
            form=start,
            listing=listing,
            listings=_listing_names(conn),
        )

    def detail(booking_id: int) -> str:
        conn = get_db()
        booking = repo.get_booking(conn, booking_id)
        if booking is None:
            abort(404)
        lines = repo.list_lines(conn, booking_id)
        return render_template(
            "booking_detail.html", booking=booking, lines=lines, imported=_is_imported(lines)
        )

    def new() -> str | Response:
        conn = get_db()
        if request.method == "GET":
            listings = repo.load_settings(conn).property_listings
            preset = {"listing": listings[0]} if len(listings) == 1 else {}
            return _form_page(conn, None, Form(preset), False)
        form = Form(request.form)
        _read(form, False)
        if form.ok:
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
                lambda: repo.create_booking(
                    conn, booking, manual_amount_cop=form.values["net_payout"]
                )
            )
            if form.ok:
                flash("Booking saved.")
                _warn_overlap(conn, booking)
                return redirect(url_for("booking_detail", booking_id=booking.id))
        return _form_page(conn, None, form, False)

    def edit(booking_id: int) -> str | Response:
        conn = get_db()
        booking = repo.get_booking(conn, booking_id)
        if booking is None:
            abort(404)
        lines = repo.list_lines(conn, booking_id)
        imported = _is_imported(lines)
        if request.method == "GET":
            form = Form(
                {
                    "check_in": str(booking.check_in),
                    "check_out": str(booking.check_out),
                    "net_payout": format_money(_manual_amount(lines) or 0),
                    "airbnb_code": booking.airbnb_code or "",
                    "listing": booking.listing or "",
                    "guest_name": booking.guest_name or "",
                    "guests": str(booking.guests or ""),
                    "notes": booking.notes or "",
                }
            )
            return _form_page(conn, booking, form, imported)
        form = Form(request.form)
        _read(form, imported)
        if form.ok:
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
            if form.ok:
                flash("Booking saved.")
                _warn_overlap(conn, booking)
                return redirect(url_for("booking_detail", booking_id=booking_id))
        return _form_page(conn, booking, form, imported)

    def delete(booking_id: int) -> Response:
        conn = get_db()
        form = Form()
        form.apply(lambda: repo.delete_booking(conn, booking_id))
        if form.ok:
            flash("Booking deleted.")
            return redirect(url_for("bookings"))
        flash(f"Booking not deleted: {form.errors['']}. Delete its expenses first.", "error")
        return redirect(url_for("booking_detail", booking_id=booking_id))

    app.add_url_rule("/bookings", "bookings", bookings)
    app.add_url_rule("/bookings/new", "booking_new", new, methods=["GET", "POST"])
    app.add_url_rule("/bookings/<int:booking_id>", "booking_detail", detail)
    app.add_url_rule(
        "/bookings/<int:booking_id>/edit", "booking_edit", edit, methods=["GET", "POST"]
    )
    app.add_url_rule(
        "/bookings/<int:booking_id>/delete", "booking_delete", delete, methods=["POST"]
    )
