"""Time log screens."""

from datetime import date, timedelta

from flask import Flask, abort, flash, redirect, render_template, request, url_for
from werkzeug.wrappers import Response

from airbnb_books.model import TimeEntry
from airbnb_books.storage import repo
from airbnb_books.web.app_db import get_db
from airbnb_books.web.forms import Form, booking_options, format_hours


def _page(conn, entry: TimeEntry | None, form: Form) -> str:
    return render_template(
        "time_form.html",
        entry=entry,
        form=form,
        bookings=booking_options(repo.list_bookings(conn)),
        title="Edit time entry" if entry else "New time entry",
    )


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


def register(app: Flask) -> None:
    app.jinja_env.filters["hours"] = format_hours

    def time_list() -> str:
        conn = get_db()
        form = Form(request.args)
        first = form.day("from")
        last = form.day("to")
        if not form.ok:
            first = last = None
        found = repo.list_time_entries(conn, first, last + timedelta(days=1) if last else None)
        found.sort(key=lambda e: (e.date, e.id or 0), reverse=True)
        return render_template(
            "time.html", entries=found, form=form, total=sum(e.minutes for e in found)
        )

    def time_new() -> str | Response:
        conn = get_db()
        if request.method == "GET":
            return _page(conn, None, Form({"date": date.today().isoformat()}))
        form = Form(request.form)
        _read(form)
        if form.ok:
            entry = TimeEntry(date.today(), 0)
            _fill(form, entry)
            form.apply(lambda: repo.create_time_entry(conn, entry))
            if form.ok:
                flash("Time entry saved.")
                return redirect(url_for("time"))
        return _page(conn, None, form)

    def time_edit(entry_id: int) -> str | Response:
        conn = get_db()
        entry = repo.get_time_entry(conn, entry_id)
        if entry is None:
            abort(404)
        if request.method == "GET":
            form = Form(
                {
                    "date": str(entry.date),
                    "hours": format_hours(entry.minutes),
                    "booking_id": str(entry.booking_id or ""),
                    "description": entry.description or "",
                }
            )
            return _page(conn, entry, form)
        form = Form(request.form)
        _read(form)
        if form.ok:
            _fill(form, entry)
            form.apply(lambda: repo.update_time_entry(conn, entry))
            if form.ok:
                flash("Time entry saved.")
                return redirect(url_for("time"))
        return _page(conn, entry, form)

    def time_delete(entry_id: int) -> Response:
        repo.delete_time_entry(get_db(), entry_id)
        flash("Time entry deleted.")
        return redirect(url_for("time"))

    app.add_url_rule("/time", "time", time_list)
    app.add_url_rule("/time/new", "time_new", time_new, methods=["GET", "POST"])
    app.add_url_rule("/time/<int:entry_id>/edit", "time_edit", time_edit, methods=["GET", "POST"])
    app.add_url_rule("/time/<int:entry_id>/delete", "time_delete", time_delete, methods=["POST"])
