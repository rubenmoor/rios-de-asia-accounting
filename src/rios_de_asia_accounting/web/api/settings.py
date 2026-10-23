from rios_de_asia_accounting.model import Settings
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.web.api.bookings import listing_names
from rios_de_asia_accounting.web.api.common import bp, info, invalid, ok, read_form
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.forms import Form

ALLOCATIONS = ["check_in", "spread"]


def _read(form: Form, current: Settings) -> None:
    """Parse the settings fields into `current` (errors land in the form)."""
    current.hourly_value_cop = form.money("hourly_value_cop", required=True)
    current.long_term_rent_cop_per_month = form.money("long_term_rent_cop_per_month", required=True)
    current.per_booking_allocation = form.choice("per_booking_allocation", ALLOCATIONS)
    current.backup_keep = form.whole("backup_keep", required=True, minimum=1)


def _item(s: Settings) -> dict:
    return {
        "hourly_value_cop": s.hourly_value_cop,
        "long_term_rent_cop_per_month": s.long_term_rent_cop_per_month,
        "per_booking_allocation": s.per_booking_allocation,
        "backup_keep": s.backup_keep,
        "listings": s.property_listings,
    }


@bp.get("/settings")
def get_settings():
    return _item(repo.load_settings(get_db()))


@bp.get("/settings/options")
def settings_options():
    return {"allocations": ALLOCATIONS, "listings": listing_names(get_db())}


@bp.put("/settings")
def update_settings():
    conn = get_db()
    form = read_form()
    current = repo.load_settings(conn)
    _read(form, current)
    if form.ok:
        current.property_listings = form.raw_list("listings")
        form.apply(lambda: repo.save_settings(conn, current))
    if not form.ok:
        return invalid(form)
    return ok(_item(current), [info("Settings saved.")])
