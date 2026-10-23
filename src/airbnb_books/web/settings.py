"""Settings and exchange-rate screens."""

from datetime import date

from flask import Flask, abort, flash, redirect, render_template, request, url_for
from werkzeug.wrappers import Response

from airbnb_books.model import ExchangeRate
from airbnb_books.storage import repo
from airbnb_books.web.app_db import get_db
from airbnb_books.web.bookings import _listing_names
from airbnb_books.web.forms import Form, format_money, format_rate

ALLOCATIONS = ["check_in", "spread"]


def _settings_page(conn, form: Form) -> str:
    chosen = set(form.raw_list("listings"))
    known = _listing_names(conn)
    # a hand-typed name that was not found in bookings stays visible as a checkbox
    names = sorted(set(known) | chosen)
    return render_template(
        "settings.html", form=form, allocations=ALLOCATIONS, listings=names, chosen=chosen
    )


def _needs_rate_message(conn, saved: str) -> str:
    missing = sum(1 for b in repo.list_bookings(conn) if b.needs_rate)
    if missing:
        return f"{saved} {missing} booking(s) still need an exchange rate."
    return f"{saved} No booking needs an exchange rate."


def _rate_page(conn, existing: ExchangeRate | None, form: Form) -> str:
    return render_template(
        "rate_form.html",
        rate=existing,
        form=form,
        title="Edit exchange rate" if existing else "New exchange rate",
    )


def register(app: Flask) -> None:
    def settings() -> str | Response:
        conn = get_db()
        if request.method == "GET":
            current = repo.load_settings(conn)
            form = Form(
                {
                    "hourly_value_cop": format_money(current.hourly_value_cop),
                    "long_term_rent_cop_per_month": format_money(
                        current.long_term_rent_cop_per_month
                    ),
                    "per_booking_allocation": current.per_booking_allocation,
                    "backup_keep": str(current.backup_keep),
                },
                lists={"listings": current.property_listings},
            )
            return _settings_page(conn, form)
        form = Form(request.form, lists={"listings": request.form.getlist("listings")})
        current = repo.load_settings(conn)
        current.hourly_value_cop = form.money("hourly_value_cop", required=True)
        current.long_term_rent_cop_per_month = form.money(
            "long_term_rent_cop_per_month", required=True
        )
        current.per_booking_allocation = form.choice("per_booking_allocation", ALLOCATIONS)
        current.backup_keep = form.whole("backup_keep", required=True, minimum=1)
        extra = form.text("other_listing")
        if form.ok:
            names = form.raw_list("listings")
            if extra and extra not in names:
                names.append(extra)
            current.property_listings = names
            form.apply(lambda: repo.save_settings(conn, current))
            if form.ok:
                flash("Settings saved.")
                return redirect(url_for("settings"))
        return _settings_page(conn, form)

    def rates() -> str:
        form = Form(request.args)
        currency = form.currency("currency")
        if not form.ok:
            currency = None
        return render_template(
            "rates.html", rates=repo.list_exchange_rates(get_db(), currency), form=form
        )

    def rate_new() -> str | Response:
        conn = get_db()
        if request.method == "GET":
            return _rate_page(
                conn, None, Form({"date": date.today().isoformat(), "currency": "USD"})
            )
        form = Form(request.form)
        day = form.day("date", required=True)
        currency = form.currency("currency", required=True)
        value = form.rate("rate", required=True, positive=True)
        if form.ok:
            form.apply(lambda: repo.set_exchange_rate(conn, ExchangeRate(day, currency, value)))
            if form.ok:
                flash(_needs_rate_message(conn, "Exchange rate saved."))
                return redirect(url_for("rates"))
        return _rate_page(conn, None, form)

    def _find_rate(conn, day: str, currency: str) -> ExchangeRate:
        try:
            when = date.fromisoformat(day)
        except ValueError:
            abort(404)
        for r in repo.list_exchange_rates(conn, currency):
            if r.date == when:
                return r
        abort(404)

    def rate_edit(day: str, currency: str) -> str | Response:
        conn = get_db()
        existing = _find_rate(conn, day, currency)
        if request.method == "GET":
            return _rate_page(conn, existing, Form({"rate": format_rate(existing.rate)}))
        form = Form(request.form)
        value = form.rate("rate", required=True, positive=True)
        if form.ok:
            existing.rate = value
            form.apply(lambda: repo.set_exchange_rate(conn, existing))
            if form.ok:
                flash(_needs_rate_message(conn, "Exchange rate saved."))
                return redirect(url_for("rates"))
        return _rate_page(conn, existing, form)

    def rate_delete(day: str, currency: str) -> Response:
        conn = get_db()
        existing = _find_rate(conn, day, currency)
        repo.delete_exchange_rate(conn, existing.date, existing.currency)
        flash(_needs_rate_message(conn, "Exchange rate deleted."))
        return redirect(url_for("rates"))

    app.add_url_rule("/settings", "settings", settings, methods=["GET", "POST"])
    app.add_url_rule("/rates", "rates", rates)
    app.add_url_rule("/rates/new", "rate_new", rate_new, methods=["GET", "POST"])
    app.add_url_rule("/rates/<day>/<currency>", "rate_edit", rate_edit, methods=["GET", "POST"])
    app.add_url_rule("/rates/<day>/<currency>/delete", "rate_delete", rate_delete, methods=["POST"])
