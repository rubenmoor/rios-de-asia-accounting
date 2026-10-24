"""Daily exchange rates from two public sources (decision 35).

COP: official TRM from datos.gov.co. EUR: ECB via Frankfurter.
Rates are integers: currency units per USD x 1 000 000.
"""

import json
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta
from decimal import Decimal, InvalidOperation

from rios_de_asia_accounting.money import RATE_SCALE

TIMEOUT = 10
USER_AGENT = "rios-de-asia-accounting (exchange rate fetch)"
COP_URL = "https://www.datos.gov.co/resource/32sa-8pi3.json"
EUR_URL = "https://api.frankfurter.dev/v2/rates"

# (date, rate) pairs, and the date up to which the source has been asked
Rates = list[tuple[date, int]]


class RateUnavailable(Exception):
    """Network, HTTP or format problem while fetching rates."""


def _scaled(value: object) -> int:
    try:
        rate = Decimal(str(value)) * RATE_SCALE
    except InvalidOperation:
        raise RateUnavailable(f"not a rate: {value!r}") from None
    if not rate.is_finite() or rate <= 0:
        raise RateUnavailable(f"not a rate: {value!r}")
    return int(rate.to_integral_value())


def parse_cop(payload: object) -> tuple[Rates, date | None]:
    """Rates dated by vigenciadesde, plus the latest vigenciahasta (None if empty)."""
    if not isinstance(payload, list):
        raise RateUnavailable("unexpected COP response")
    rates: Rates = []
    through: date | None = None
    try:
        for row in payload:
            start = datetime.fromisoformat(row["vigenciadesde"]).date()
            end = datetime.fromisoformat(row["vigenciahasta"]).date()
            rates.append((start, _scaled(row["valor"])))
            through = end if through is None else max(through, end)
    except (KeyError, TypeError, ValueError) as e:
        raise RateUnavailable(f"unexpected COP response: {e}") from None
    return rates, through


def parse_eur(payload: object) -> Rates:
    if not isinstance(payload, list):
        raise RateUnavailable("unexpected EUR response")
    try:
        return [(date.fromisoformat(row["date"]), _scaled(row["rate"])) for row in payload]
    except (KeyError, TypeError, ValueError) as e:
        raise RateUnavailable(f"unexpected EUR response: {e}") from None


def _get_json(url: str, params: dict[str, str]) -> object:
    request = urllib.request.Request(
        f"{url}?{urllib.parse.urlencode(params)}", headers={"User-Agent": USER_AGENT}
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.loads(response.read())
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise RateUnavailable(str(e)) from None


def fetch_cop(start: date, end: date) -> tuple[Rates, date | None]:
    """TRM rates valid at any time in [start, end]; coverage = latest vigenciahasta received.

    Coverage is None when nothing was received.
    """
    params = {
        "$where": (
            f"vigenciahasta >= '{start.isoformat()}' AND vigenciadesde <= '{end.isoformat()}'"
        ),
        "$order": "vigenciadesde",
        "$limit": "50000",
    }
    return parse_cop(_get_json(COP_URL, params))


def fetch_eur(start: date, end: date) -> tuple[Rates, date]:
    """ECB rates in [start, end] (working days only); coverage = min(end, yesterday)."""
    params = {
        "base": "USD",
        "quotes": "EUR",
        "from": start.isoformat(),
        "to": end.isoformat(),
        "providers": "ECB",
    }
    rates = parse_eur(_get_json(EUR_URL, params))
    return rates, min(end, date.today() - timedelta(days=1))
