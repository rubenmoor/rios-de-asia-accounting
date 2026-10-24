"""The display currency (decisions 46, 48): chosen here, applied by the browser."""

from rios_de_asia_accounting.conversion import rate_on
from rios_de_asia_accounting.money import USD_RATE
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.web.api.common import (
    bp,
    info,
    invalid,
    ok,
    read_form,
    today,
    warning,
)
from rios_de_asia_accounting.web.app_db import get_db
from rios_de_asia_accounting.web.forms import CURRENCIES


def _item(currency: str, display_rate: dict | None) -> dict:
    rate = display_rate or {"rate": USD_RATE, "rate_date": None}
    return {
        "currency": currency,
        "rate": rate["rate"],
        "rate_date": rate["rate_date"],
        "currencies": CURRENCIES,
    }


@bp.get("/display")
def get_display():
    settings = repo.load_settings(get_db())
    return _item(settings.currency, settings.display_rate if settings.currency != "USD" else None)


@bp.put("/display")
def put_display():
    conn = get_db()
    form = read_form()
    currency = form.choice("currency", CURRENCIES)
    if not form.ok:
        return invalid(form)
    settings = repo.load_settings(conn)
    if currency == "USD":
        settings.currency, settings.display_rate = "USD", None
    else:
        found = rate_on(conn, currency, today())
        if found is None:
            return ok(
                _item(settings.currency, settings.display_rate),
                [
                    warning(
                        f"No {currency} rate could be fetched (no connection?);"
                        " figures stay in USD."
                    )
                ],
            )
        rate, rate_date = found
        settings.currency = currency
        settings.display_rate = {"rate": rate, "rate_date": rate_date.isoformat()}
    repo.save_settings(conn, settings)
    return ok(
        _item(settings.currency, settings.display_rate), [info(f"Figures are shown in {currency}.")]
    )
