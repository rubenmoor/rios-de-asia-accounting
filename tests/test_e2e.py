"""End to end through the web app: import, rates, expenses, time, dashboard, quit, restore.

The expected numbers for October 2026 were recomputed by hand from the CSV rows (not with
the app's code) and match the same run on the real export. Today is fixed at 2026-10-23, so
October counts its days 1 to 23; 2026-10-15 is blocked.

October 2026, listings "Large 4 bed …" and "Master bedroom …":
- HMECDBYSMK 10-07..10-12, USD 1093.52 at 3850.25 (rate of 10-08) = 4.210.325, co-host
  USD 214.95 = 827.611 as a per-booking cost on the check-in day
- HMNDSJTM25 10-21..11-21 (crosses into November), COP 1.476.880 over 31 nights:
  the first 9 nights get 47.642, so 10-21..10-23 = 142.926
- fixed 450.000/month over 31 days, 23 days = 333.872; per-night 90.001 over the 16 booked
  October nights, 8 of them up to today = 45.001; capex 2.400.000 over 365 days from
  09-15, 23 days of 6.576 = 151.248; maintenance 180.000; 4 hours logged
"""

import re
import shutil
from datetime import date
from pathlib import Path

from airbnb_books.cli import backup_on_exit
from airbnb_books.storage.db import connect, migrate
from airbnb_books.web.app import create_app

FIXTURES = Path(__file__).parent / "fixtures"
LISTINGS = [
    "Large 4 bed 3 bath apartment near Provenza Poblado",
    "Master bedroom in beautiful neighbourhood",
]
TODAY = date(2026, 10, 23)

OCTOBER = {
    "Available nights": "22",
    "Occupied nights": "8",
    "Occupancy": "36.4 %",
    "ADR": "544.156",
    "RevPAR": "197.875",
    "Income": "4.353.251",
    "Total cost": "1.537.732",
    "Profit": "2.815.519",
    "Variable cost per night": "109.077",
    "Break-even occupancy": "6.9 %",
    "Long-term rental benchmark": "2.225.808",
    "Profit vs. long-term rental": "589.711",
    "Hours": "4.0",
    "Profit per hour": "703.880",
    "Profit after own time": "2.735.519",
}
BREAKDOWN = {
    "Fixed": "333.872",
    "Per night": "45.001",
    "Per booking": "827.611",
    "Maintenance": "180.000",
    "Capex depreciation": "151.248",
    "Tax": "0",
}


def _app(db, backup_dir):
    app = create_app(db, shutdown=lambda: backup_on_exit(db, str(backup_dir)))
    app.config["TODAY"] = TODAY
    return app.test_client()


def _ok(response):
    assert response.status_code in (200, 302), response.data[:500]
    return response


def _table(page: bytes) -> dict[str, list[str]]:
    """First cell of each table row → the other cells, as text."""
    rows = {}
    for tr in re.findall(r"<tr>(.*?)</tr>", page.decode(), re.S):
        cells = [
            re.sub(r"<[^>]+>", "", c).strip()
            for c in re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", tr, re.S)
        ]
        if cells:
            rows[cells[0]] = cells[1:]
    return rows


def _october(client) -> tuple[dict, dict]:
    rows = _table(client.get("/?month=2026-10").data)
    heads = rows["COP unless stated"]
    month = next(i for i, head in enumerate(heads) if head.startswith("Month 2026-10"))
    return (
        {label: rows[label][month] for label in OCTOBER},
        {label: rows[label][0] for label in BREAKDOWN},
    )


def _enter_everything(client):
    data = {"file": ((FIXTURES / "airbnb_sample.csv").open("rb"), "airbnb_sample.csv")}
    page = _ok(client.post("/import/airbnb", data=data, content_type="multipart/form-data")).data
    token = re.search(rb'name="token" value="([0-9a-f]{32})"', page).group(1).decode()
    done = client.post("/import/airbnb/apply", data={"token": token, "listings": LISTINGS}).data
    assert b"Import done" in done

    for day, rate in (("2026-10-08", "3850.25"), ("2026-10-09", "3900.00")):
        _ok(client.post("/rates/new", data={"date": day, "currency": "USD", "rate": rate}))

    _ok(
        client.post(
            "/settings",
            data={
                "hourly_value_cop": "20.000",
                "long_term_rent_cop_per_month": "3.000.000",
                "per_booking_allocation": "check_in",
                "backup_keep": "30",
                "listings": LISTINGS,
            },
        )
    )
    _ok(
        client.post(
            "/recurring/new",
            data={
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
        _ok(client.post("/expenses/new", data={"description": "x", **expense}))
    _ok(
        client.post(
            "/blocked-days/new", data={"from": "2026-10-15", "to": "2026-10-15", "reason": "owner"}
        )
    )
    _ok(client.post("/time/new", data={"date": "2026-10-07", "hours": "2,5"}))
    _ok(client.post("/time/new", data={"date": "2026-10-21", "hours": "1:30"}))


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

    response = client.post("/quit")
    assert b"you can close this tab" in response.data
    response.close()  # runs the shutdown callback: the backup at exit
    (backup,) = backup_dir.glob("books-*.db")

    # restore as the README says: copy the backup over the live database, start again
    db.write_bytes(b"")
    shutil.copyfile(backup, db)
    assert _october(_app(db, backup_dir)) == before
