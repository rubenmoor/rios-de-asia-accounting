from datetime import timedelta

import pytest

from rios_de_asia_accounting import conversion
from rios_de_asia_accounting.web import app as app_module

# fixed test rates, currency units per USD x 1 000 000: 4000 COP and 0.8 EUR per USD
FIXED_RATES = {"COP": 4_000_000_000, "EUR": 800_000}


def fixed_fetcher(rate):
    def fetch(start, end):
        days = [start + timedelta(days=i) for i in range((end - start).days + 1)]
        return [(day, rate) for day in days], end

    return fetch


@pytest.fixture(autouse=True)
def no_frontend_bundle(tmp_path_factory, monkeypatch):
    """Tests never depend on a built frontend bundle in web/dist."""
    monkeypatch.setattr(app_module, "DIST", tmp_path_factory.getbasetemp() / "no-dist")


@pytest.fixture(autouse=True)
def fixed_rates(monkeypatch):
    """No test touches the network: every day has the rate of FIXED_RATES."""
    for currency, rate in FIXED_RATES.items():
        monkeypatch.setitem(conversion.FETCHERS, currency, fixed_fetcher(rate))
    monkeypatch.setattr(conversion, "_attempts", {})
