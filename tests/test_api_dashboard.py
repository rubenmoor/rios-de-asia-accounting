from datetime import date

import pytest

from rios_de_asia_accounting.model import Booking, Expense
from rios_de_asia_accounting.storage import repo
from rios_de_asia_accounting.storage.db import connect, migrate
from rios_de_asia_accounting.web.app import create_app


@pytest.fixture
def db_path(tmp_path):
    path = tmp_path / "books.db"
    conn = connect(path)
    migrate(conn)
    conn.close()
    return path


def _client(db_path):
    app = create_app(db_path)
    app.config["TODAY"] = date(2026, 3, 10)
    return app.test_client()


def test_dashboard_empty_has_form_defaults(db_path):
    body = _client(db_path).get("/api/dashboard").get_json()
    assert body["empty"] is True and body["rows"] == []
    assert body["form"] == {"month": "2026-02", "from": "", "to": ""}


def test_dashboard_figures_and_notice(db_path):
    conn = connect(db_path)
    repo.create_booking(
        conn, Booking(date(2026, 3, 1), date(2026, 3, 4), airbnb_code="A"), 1_500_000
    )
    repo.create_expense(conn, Expense(date(2026, 3, 1), 310_000, "fixed"))
    conn.close()
    body = _client(db_path).get("/api/dashboard?from=2026-03-01").get_json()
    assert [n["level"] for n in body["notices"]] == ["error"]
    assert body["columns"][0] == {"label": "All time", "start": "2026-03-01", "end": "2026-03-10"}
    rows = {r["key"]: r for r in body["rows"]}
    assert rows["occupancy"]["values"][0] == pytest.approx(0.3)
    assert rows["income"]["values"][0] == 1_500_000
    assert rows["profit_per_hour"]["values"][0] is None
    assert body["rolling_90"] == [] and body["breakdown"]["items"][0]["key"] == "cost_fixed"
