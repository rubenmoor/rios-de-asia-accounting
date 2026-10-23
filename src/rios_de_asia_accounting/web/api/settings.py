from rios_de_asia_accounting.model import Settings
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.web.api.common import bp, info, invalid, ok, read_form
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.bookings import _listing_names
from rios_de_asia_accounting.web.settings import ALLOCATIONS, read_settings


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
    return {"allocations": ALLOCATIONS, "listings": _listing_names(get_db())}


@bp.put("/settings")
def update_settings():
    conn = get_db()
    form = read_form()
    current = repo.load_settings(conn)
    read_settings(form, current)
    if form.ok:
        current.property_listings = form.raw_list("listings")
        form.apply(lambda: repo.save_settings(conn, current))
    if not form.ok:
        return invalid(form)
    return ok(_item(current), [info("Settings saved.")])
