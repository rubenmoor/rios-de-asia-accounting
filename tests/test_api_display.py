import pytest

from rios_de_asia_accounting import conversion
from rios_de_asia_accounting.rates import RateUnavailable
from rios_de_asia_accounting.storage.db import _migration_files, connect, migrate
from rios_de_asia_accounting.web.app import create_app


@pytest.fixture
def client(tmp_path):
    path = tmp_path / "books.db"
    conn = connect(path)
    migrate(conn)
    conn.close()
    return create_app(path).test_client()


def test_starts_in_usd(client):
    got = client.get("/api/display").get_json()
    assert (got["currency"], got["rate"], got["rate_date"]) == ("USD", 1_000_000, None)
    assert got["currencies"] == ["USD", "COP", "EUR"]


def test_switch_to_cop_stores_the_rate(client):
    res = client.put("/api/display", json={"currency": "COP"}).get_json()
    assert res["notices"][0]["level"] == "info"
    got = client.get("/api/display").get_json()
    assert (got["currency"], got["rate"]) == ("COP", 4_000_000_000) and got["rate_date"]
    client.put("/api/display", json={"currency": "USD"})
    assert client.get("/api/display").get_json()["rate_date"] is None


def test_failed_fetch_leaves_usd(client, monkeypatch):
    def offline(start, end):
        raise RateUnavailable("no connection")

    monkeypatch.setitem(conversion.FETCHERS, "COP", offline)
    res = client.put("/api/display", json={"currency": "COP"}).get_json()
    assert res["notices"][0]["level"] == "warning" and res["data"]["currency"] == "USD"
    assert client.get("/api/display").get_json()["currency"] == "USD"


def test_unknown_currency_refused(client):
    assert client.put("/api/display", json={"currency": "XYZ"}).status_code == 422


def test_migration_sets_usd(tmp_path):
    conn = connect(tmp_path / "b.db")
    migrate(conn)
    conn.execute("INSERT INTO settings (key, value) VALUES ('currency', 'COP')")
    sql = next(sql for n, sql in _migration_files() if n == 5)
    conn.executescript(sql)
    assert conn.execute("SELECT value FROM settings WHERE key = 'currency'").fetchone()[0] == "USD"
