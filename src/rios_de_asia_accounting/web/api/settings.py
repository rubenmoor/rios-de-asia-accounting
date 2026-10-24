from datetime import date

from flask import current_app

from rios_de_asia_accounting.conversion import convert_waiting
from rios_de_asia_accounting.model import Settings
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.web.api.bookings import listing_names
from rios_de_asia_accounting.web.api.common import (
    bp,
    info,
    invalid,
    money_options,
    ok,
    read_form,
    today,
    warning,
)
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.forms import Form

ALLOCATIONS = ["check_in", "spread"]


def _read(form: Form, current: Settings, day: date) -> None:
    """Parse the settings fields into `current` (errors land in the form). A rent typed
    differently from before is converted at the rate of `day` (decision 41)."""
    minor = form.money("long_term_rent", "long_term_rent_currency", required=True)
    currency = form.values["long_term_rent_currency"]
    current.per_booking_allocation = form.choice("per_booking_allocation", ALLOCATIONS)
    current.backup_keep = form.whole("backup_keep", required=True, minimum=1)
    entered = current.long_term_rent_entered or {}
    if minor is not None and (entered.get("original_minor"), entered.get("currency")) != (
        minor,
        currency,
    ):
        current.long_term_rent_entered = {
            "original_minor": minor,
            "currency": currency,
            "date": day.isoformat(),
            "rate": None,
            "rate_date": None,
        }
        current.long_term_rent_usd = None


def _item(s: Settings) -> dict:
    return {
        "long_term_rent_usd": s.long_term_rent_usd,  # US cents, None while waiting
        "long_term_rent_entered": s.long_term_rent_entered,
        "per_booking_allocation": s.per_booking_allocation,
        "backup_keep": s.backup_keep,
        "listings": s.property_listings,
    }


@bp.get("/settings")
def get_settings():
    return {**_item(repo.load_settings(get_db())), "last_backup": current_app.config["LAST_BACKUP"]}


@bp.get("/settings/options")
def settings_options():
    conn = get_db()
    return {"allocations": ALLOCATIONS, "listings": listing_names(conn), **money_options(conn)}


@bp.put("/settings")
def update_settings():
    conn = get_db()
    form = read_form()
    current = repo.load_settings(conn)
    _read(form, current, today())
    if form.ok:
        current.property_listings = form.raw_list("listings")
        form.apply(lambda: repo.save_settings(conn, current))
    if not form.ok:
        return invalid(form)
    convert_waiting(conn, today())
    saved = repo.load_settings(conn)
    notice = info("Settings saved.")
    if saved.long_term_rent_entered is not None and saved.long_term_rent_usd is None:
        entered = saved.long_term_rent_entered
        notice = warning(
            f"Saved. No {entered['currency']} rate for {entered['date']} yet (no connection?);"
            " the long-term rent is left out of the figures until the rate is fetched."
        )
    return ok(_item(saved), [notice])
