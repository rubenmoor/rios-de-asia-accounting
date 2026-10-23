from datetime import date

from flask import request

from rios_de_asia_accounting.model import ExchangeRate
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.web.api.common import bp, info, invalid, ok, read_form
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.forms import Form


def _needs_rate_message(conn, saved: str) -> str:
    missing = sum(1 for b in repo.list_bookings(conn) if b.needs_rate)
    if missing:
        return f"{saved} {missing} booking(s) still need an exchange rate."
    return f"{saved} No booking needs an exchange rate."


def _item(r: ExchangeRate) -> dict:
    return {"date": r.date.isoformat(), "currency": r.currency, "rate": r.rate}


def _find(day: str, currency: str) -> ExchangeRate | None:
    try:
        when = date.fromisoformat(day)
    except ValueError:
        return None
    for r in repo.list_exchange_rates(get_db(), currency):
        if r.date == when:
            return r
    return None


def _not_found():
    return {"error": "exchange rate not found"}, 404


@bp.get("/rates")
def list_rates():
    form = Form(request.args)
    currency = form.currency("currency")
    if not form.ok:
        return invalid(form)
    return [_item(r) for r in repo.list_exchange_rates(get_db(), currency)]


@bp.post("/rates")
def create_rate():
    conn = get_db()
    form = read_form()
    day = form.day("date", required=True)
    currency = form.currency("currency", required=True)
    value = form.rate("rate", required=True, positive=True)
    if form.ok:
        saved = ExchangeRate(day, currency, value)
        form.apply(lambda: repo.set_exchange_rate(conn, saved))
    if not form.ok:
        return invalid(form)
    return ok(_item(saved), [info(_needs_rate_message(conn, "Exchange rate saved."))])


@bp.put("/rates/<day>/<currency>")
def update_rate(day: str, currency: str):
    conn = get_db()
    existing = _find(day, currency)
    if existing is None:
        return _not_found()
    form = read_form()
    value = form.rate("rate", required=True, positive=True)
    if form.ok:
        existing.rate = value
        form.apply(lambda: repo.set_exchange_rate(conn, existing))
    if not form.ok:
        return invalid(form)
    return ok(_item(existing), [info(_needs_rate_message(conn, "Exchange rate saved."))])


@bp.delete("/rates/<day>/<currency>")
def delete_rate(day: str, currency: str):
    conn = get_db()
    existing = _find(day, currency)
    if existing is None:
        return _not_found()
    repo.delete_exchange_rate(conn, existing.date, existing.currency)
    return ok(None, [info(_needs_rate_message(conn, "Exchange rate deleted."))])
