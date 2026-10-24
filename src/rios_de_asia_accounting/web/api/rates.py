"""Exchange rates are fetched by the app itself (decision 35); this is the retry button."""

from rios_de_asia_accounting.conversion import convert_waiting, waiting_count
from rios_de_asia_accounting.web.api.common import bp, info, ok, today, warning
from rios_de_asia_accounting.web.app_db import get_db


def waiting_notice(waiting: int) -> dict[str, str]:
    if not waiting:
        return info("All entries are converted to USD.")
    return warning(f"{waiting} entries wait for an exchange rate and are left out of the figures.")


@bp.get("/rates/waiting")
def rates_waiting():
    return {"waiting": waiting_count(get_db())}


@bp.post("/rates/fetch")
def fetch_rates():
    waiting = convert_waiting(get_db(), today(), force=True)
    return ok({"waiting": waiting}, [waiting_notice(waiting)])
