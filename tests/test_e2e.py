"""End to end through the web app: import, expenses, settings, dashboard, backup, restore.

The expected numbers for October 2026 were recomputed by hand from the CSV rows (not with
the app's code), in US cents at the fixed test rates of 4000 COP and 0.8 EUR per USD (see
conftest). Today is fixed at 2026-10-23, so October counts its days 1 to 23.

October 2026, listings "Large 4 bed …" and "Master bedroom …":
- HMECDBYSMK 10-07..10-12, USD 1093.52 = 109.352 over 5 nights, co-host USD 214.95 =
  21.495 as a per-booking cost on the check-in day
- HMNDSJTM25 10-21..11-21 (crosses into November), COP 1.476.880,34 = 36.922 over 31
  nights: the first night gets 1.192, the others 1.191, so 10-21..10-23 = 3.574
- fixed COP 450.000/month = 11.250 over 31 days, 23 days of 363 = 8.349; per-night USD 22,50
  = 2.250 over the 16 booked October nights, 8 of them up to today at 141 = 1.128; capex COP
  2.400.000 = 60.000 over 365 days from 09-15, 23 days of 165 = 3.795; maintenance EUR 45,00
  = 5.625
- long-term rent COP 3.000.000 = 75.000/month: 11 days of 2.420 + 12 of 2.419 = 55.648
"""

import shutil
from datetime import date
from pathlib import Path

from rios_de_asia_accounting.cli import backup_on_exit
from rios_de_asia_accounting.storage.db import connect, migrate
from rios_de_asia_accounting.web.app import create_app

FIXTURES = Path(__file__).parent / "fixtures"
LISTINGS = [
    "Large 4 bed 3 bath apartment near Provenza Poblado",
    "Master bedroom in beautiful neighbourhood",
]
TODAY = date(2026, 10, 23)

# row key → value in the October column: US cents, ratios as percentages
OCTOBER = {
    "available_nights": 23,
    "occupied_nights": 8,
    "occupancy": "34.8 %",
    "adr": 14116,
    "revpar": 4910,
    "income": 112926,
    "total_cost": 40392,
    "profit": 72534,
    "variable_cost_per_night": 2828,
    "break_even_occupancy": "6.8 %",
    "benchmark": 55648,
    "profit_vs_long_term": 16886,
}
BREAKDOWN = {
    "cost_fixed": 8349,
    "cost_per_night": 1128,
    "cost_per_booking": 21495,
    "cost_maintenance": 5625,
    "cost_capex": 3795,
    "cost_tax": 0,
}


def _app(db, backup_dir):
    app = create_app(db)
    app.config["TODAY"] = TODAY
    return app.test_client()


def _ok(response):
    assert response.status_code == 200, response.data[:500]
    return response.get_json()["data"]


def _october(client) -> tuple[dict, dict]:
    body = client.get("/api/dashboard?month=2026-10").get_json()
    month = next(i for i, c in enumerate(body["columns"]) if c["start"] == "2026-10-01")
    rows = {row["key"]: row["values"][month] for row in body["rows"]}
    shown = {}
    for key in OCTOBER:
        value = rows[key]
        shown[key] = (
            f"{value * 100:.1f} %" if key in ("occupancy", "break_even_occupancy") else value
        )
    breakdown = {item["key"]: item["amount"] for item in body["breakdown"]["items"]}
    return shown, breakdown


def _enter_everything(client):
    data = {"file": ((FIXTURES / "airbnb_sample.csv").open("rb"), "airbnb_sample.csv")}
    preview = _ok(client.post("/api/import/airbnb", data=data, content_type="multipart/form-data"))
    assert preview["needs_listing_choice"]
    done = _ok(
        client.post(
            "/api/import/airbnb/apply", json={"token": preview["token"], "listings": LISTINGS}
        )
    )
    assert done["new"] > 0 and done["waiting"] == 0

    _ok(
        client.put(
            "/api/settings",
            json={
                "long_term_rent": "3.000.000",
                "long_term_rent_currency": "COP",
                "per_booking_allocation": "check_in",
                "backup_keep": "30",
                "listings": LISTINGS,
            },
        )
    )
    _ok(
        client.post(
            "/api/recurring",
            json={
                "description": "Admin fee",
                "amount": "450.000",
                "currency": "COP",
                "category": "fixed",
                "start_month": "2026-08",
                "end_month": "",
            },
        )
    )
    for expense in (
        {"date": "2026-10-10", "amount": "22,50", "currency": "USD", "category": "per_night"},
        {
            "date": "2026-09-15",
            "amount": "2.400.000",
            "currency": "COP",
            "category": "capex",
            "useful_life_days": "365",
        },
        {"date": "2026-10-18", "amount": "45,00", "currency": "EUR", "category": "maintenance"},
    ):
        _ok(client.post("/api/expenses", json={"description": "x", **expense}))


def test_october_2026_end_to_end(tmp_path):
    db = tmp_path / "books.db"
    backup_dir = tmp_path / "backups"
    conn = connect(db)
    migrate(conn)
    conn.close()
    client = _app(db, backup_dir)
    _enter_everything(client)

    before = _october(client)
    assert before == (OCTOBER, BREAKDOWN)

    backup_on_exit(db, str(backup_dir))
    (backup,) = backup_dir.glob("books-*.db")

    # restore as the README says: copy the backup over the live database, start again
    db.write_bytes(b"")
    shutil.copyfile(backup, db)
    assert _october(_app(db, backup_dir)) == before
