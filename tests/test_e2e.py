"""End to end through the web app: import, rates, expenses, time, dashboard, backup, restore.

The expected numbers for October 2026 were recomputed by hand from the CSV rows (not with
the app's code) and match the same run on the real export. Today is fixed at 2026-10-23, so
October counts its days 1 to 23.

October 2026, listings "Large 4 bed …" and "Master bedroom …":
- HMECDBYSMK 10-07..10-12, USD 1093.52 at 3850.25 (rate of 10-08) = 4.210.325, co-host
  USD 214.95 = 827.611 as a per-booking cost on the check-in day
- HMNDSJTM25 10-21..11-21 (crosses into November), COP 1.476.880 over 31 nights:
  the first 9 nights get 47.642, so 10-21..10-23 = 142.926
- fixed 450.000/month over 31 days, 23 days = 333.872; per-night 90.001 over the 16 booked
  October nights, 8 of them up to today = 45.001; capex 2.400.000 over 365 days from
  09-15, 23 days of 6.576 = 151.248; maintenance 180.000
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

# row key → value in the October column: whole COP, ratios as fractions
OCTOBER = {
    "available_nights": 23,
    "occupied_nights": 8,
    "occupancy": "34.8 %",
    "adr": 544156,
    "revpar": 189272,
    "income": 4353251,
    "total_cost": 1537732,
    "profit": 2815519,
    "variable_cost_per_night": 109077,
    "break_even_occupancy": "6.6 %",
    "benchmark": 2225808,
    "profit_vs_long_term": 589711,
}
BREAKDOWN = {
    "cost_fixed": 333872,
    "cost_per_night": 45001,
    "cost_per_booking": 827611,
    "cost_maintenance": 180000,
    "cost_capex": 151248,
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
    assert done["new"] > 0

    for day, rate in (("2026-10-08", "3850.25"), ("2026-10-09", "3900.00")):
        _ok(client.post("/api/rates", json={"date": day, "currency": "USD", "rate": rate}))

    _ok(
        client.put(
            "/api/settings",
            json={
                "long_term_rent_cop_per_month": "3.000.000",
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
                "category": "fixed",
                "start_month": "2026-08",
                "end_month": "",
            },
        )
    )
    for expense in (
        {"date": "2026-10-10", "amount": "90.001", "category": "per_night"},
        {
            "date": "2026-09-15",
            "amount": "2.400.000",
            "category": "capex",
            "useful_life_days": "365",
        },
        {"date": "2026-10-18", "amount": "180.000", "category": "maintenance"},
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
