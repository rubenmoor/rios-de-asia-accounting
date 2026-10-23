"""Blocked days screens."""

from datetime import date, timedelta

from flask import Flask, abort, flash, redirect, render_template, request, url_for
from werkzeug.wrappers import Response

from airbnb_books.model import BlockedDay
from airbnb_books.storage import repo
from airbnb_books.web.app_db import get_db
from airbnb_books.web.forms import Form

REASONS = ["buffer", "owner", "maintenance", "other"]
MAX_RANGE_DAYS = 731


def _inside_bookings(conn, days: list[date]) -> list[date]:
    """Days on which a guest sleeps (check-in up to the night before check-out)."""
    if not days:
        return []
    bookings = repo.list_bookings(conn, min(days), max(days) + timedelta(days=1))
    return [d for d in days if any(b.check_in <= d < b.check_out for b in bookings)]


def register(app: Flask) -> None:
    def blocked() -> str:
        conn = get_db()
        form = Form(request.args)
        first = form.day("from")
        last = form.day("to")
        if not form.ok:
            first = last = None
        found = repo.list_blocked_days(conn, first, last + timedelta(days=1) if last else None)
        return render_template("blocked.html", days=list(reversed(found)), form=form)

    def blocked_new() -> str | Response:
        conn = get_db()
        if request.method == "GET":
            return render_template(
                "blocked_new.html", reasons=REASONS, form=Form(), title="Block days"
            )
        form = Form(request.form)
        first = form.day("from", required=True)
        last = form.day("to", required=True)
        reason = form.choice("reason", REASONS)
        note = form.text("note")
        if first and last:
            if last < first:
                form.error("to", "the last day must not be before the first day")
            elif (last - first).days >= MAX_RANGE_DAYS:
                form.error("to", f"at most {MAX_RANGE_DAYS} days at once")
        if not form.ok:
            return render_template(
                "blocked_new.html", reasons=REASONS, form=form, title="Block days"
            )
        days = [first + timedelta(days=i) for i in range((last - first).days + 1)]
        taken = {b.date for b in repo.list_blocked_days(conn, first, last + timedelta(days=1))}
        fresh = [d for d in days if d not in taken]
        for day in fresh:
            repo.set_blocked_day(conn, BlockedDay(day, reason, note))
        message = f"{len(fresh)} day(s) blocked"
        if taken:
            message += f"; {len(taken)} already blocked and skipped"
        flash(message + ".")
        booked = _inside_bookings(conn, fresh)
        if booked:
            flash(
                f"{len(booked)} blocked day(s) fall inside a booking: "
                + ", ".join(str(d) for d in booked[:10])
                + (" …" if len(booked) > 10 else ""),
                "warning",
            )
        return redirect(url_for("blocked"))

    def blocked_edit(day: str) -> str | Response:
        conn = get_db()
        try:
            item = repo.get_blocked_day(conn, date.fromisoformat(day))
        except ValueError:
            item = None
        if item is None:
            abort(404)
        title = f"Blocked day {item.date}"
        if request.method == "GET":
            form = Form({"reason": item.reason, "note": item.note or ""})
            return render_template(
                "blocked_edit.html", item=item, reasons=REASONS, form=form, title=title
            )
        form = Form(request.form)
        reason = form.choice("reason", REASONS)
        note = form.text("note")
        if form.ok:
            form.apply(lambda: repo.set_blocked_day(conn, BlockedDay(item.date, reason, note)))
            if form.ok:
                flash("Blocked day saved.")
                return redirect(url_for("blocked"))
        return render_template(
            "blocked_edit.html", item=item, reasons=REASONS, form=form, title=title
        )

    def blocked_delete(day: str) -> Response:
        try:
            repo.delete_blocked_day(get_db(), date.fromisoformat(day))
        except ValueError:
            abort(404)
        flash("Blocked day deleted.")
        return redirect(url_for("blocked"))

    app.add_url_rule("/blocked-days", "blocked", blocked)
    app.add_url_rule("/blocked-days/new", "blocked_new", blocked_new, methods=["GET", "POST"])
    app.add_url_rule("/blocked-days/<day>", "blocked_edit", blocked_edit, methods=["GET", "POST"])
    app.add_url_rule(
        "/blocked-days/<day>/delete", "blocked_delete", blocked_delete, methods=["POST"]
    )
