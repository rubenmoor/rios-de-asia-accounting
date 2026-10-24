import json
from datetime import date
from pathlib import Path

import pytest

from rios_de_asia_accounting.rates import RateUnavailable, parse_cop, parse_eur

FIXTURES = Path(__file__).parent / "fixtures"


def load(name):
    return json.loads((FIXTURES / name).read_text())


def test_parse_cop():
    rates, through = parse_cop(load("rates_cop.json"))
    assert rates[1] == (date(2021, 12, 31), 3_981_160_000)
    assert through == date(2022, 1, 4)


def test_parse_eur():
    rates = parse_eur(load("rates_eur.json"))
    assert (date(2021, 12, 31), 882_920) in rates


def test_parse_errors():
    with pytest.raises(RateUnavailable):
        parse_cop({"error": "x"})
    with pytest.raises(RateUnavailable):
        parse_cop(
            [
                {
                    "valor": "abc",
                    "vigenciadesde": "2021-12-31T00:00:00.000",
                    "vigenciahasta": "2021-12-31T00:00:00.000",
                }
            ]
        )
    with pytest.raises(RateUnavailable):
        parse_eur([{"date": "2021-12-31"}])
