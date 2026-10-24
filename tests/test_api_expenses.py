import pytest

from rios_de_asia_accounting import conversion
from rios_de_asia_accounting.rates import RateUnavailable
from rios_de_asia_accounting.storage.db import connect, migrate
from rios_de_asia_accounting.web.app import create_app


@pytest.fixture
def client(tmp_path):
    path = tmp_path / "books.db"
    conn = connect(path)
    migrate(conn)
    conn.close()
    return create_app(path).test_client()


def test_expense_create_filter_delete(client):
    body = {"date": "2026-01-05", "amount": "1.500,25", "currency": "EUR", "category": "fixed"}
    saved = client.post("/api/expenses", json=body).get_json()
    assert saved["data"]["amount"] == 187_531  # 1500.25 EUR at 0.8 per USD
    assert (saved["data"]["original_minor"], saved["data"]["rate_date"]) == (150_025, "2026-01-05")
    assert saved["notices"] == [{"level": "info", "text": "Expense saved."}]
    assert client.get("/api/expenses/options").get_json()["default_currency"] == "EUR"
    assert len(client.get("/api/expenses?category=fixed").get_json()) == 1
    assert client.get("/api/expenses?category=tax").get_json() == []
    assert client.delete(f"/api/expenses/{saved['data']['id']}").status_code == 200
    assert client.get("/api/expenses/options").get_json()["bookings"] == []


def test_invalid_expense_is_422(client):
    response = client.post("/api/expenses", json={"category": "per_booking", "amount": "5"})
    assert response.status_code == 422
    assert {"date", "booking_id"} <= set(response.get_json()["errors"])


def test_offline_save_waits_then_fetch_converts(client, monkeypatch):
    def offline(start, end):
        raise RateUnavailable("no connection")

    fetch = conversion.FETCHERS["COP"]
    monkeypatch.setitem(conversion.FETCHERS, "COP", offline)
    body = {"date": "2026-01-05", "amount": "400.000", "currency": "COP", "category": "fixed"}
    saved = client.post("/api/expenses", json=body).get_json()
    assert saved["data"]["amount"] is None and saved["data"]["waiting"]
    assert saved["notices"][0]["level"] == "warning"
    assert "No COP rate for 2026-01-05" in saved["notices"][0]["text"]
    assert client.get("/api/rates/waiting").get_json() == {"waiting": 1}

    monkeypatch.setitem(conversion.FETCHERS, "COP", fetch)
    assert client.post("/api/rates/fetch").get_json()["data"] == {"waiting": 0}
    assert client.get("/api/expenses").get_json()[0]["amount"] == 10_000


def test_recurring_generates_expenses(client):
    body = {
        "description": "Internet",
        "amount": "90.000",
        "currency": "COP",
        "category": "fixed",
        "start_month": "2026-01",
    }
    saved = client.post("/api/recurring", json=body).get_json()
    assert "expense(s) generated" in saved["notices"][0]["text"]
    assert saved["data"]["generated"]
    deleted = client.delete(f"/api/recurring/{saved['data']['id']}").get_json()
    assert "kept" in deleted["notices"][0]["text"]


def test_expense_fields_ignored_for_other_categories(client):
    booking = {
        "check_in": "2026-03-01",
        "check_out": "2026-03-03",
        "amount": "1",
        "currency": "USD",
    }
    bid = str(client.post("/api/bookings", json=booking).get_json()["data"]["id"])
    body = {
        "date": "2026-03-05",
        "amount": "10",
        "currency": "USD",
        "booking_id": bid,
        "useful_life_days": "x",
    }
    saved = client.post("/api/expenses", json={**body, "category": "fixed"}).get_json()["data"]
    assert saved["booking_id"] is None and saved["useful_life_days"] is None
    body["useful_life_days"] = "1095"
    saved = client.post("/api/expenses", json={**body, "category": "per_booking"}).get_json()
    assert (saved["data"]["booking_id"], saved["data"]["useful_life_days"]) == (int(bid), None)
    saved = client.post("/api/expenses", json={**body, "category": "capex"}).get_json()
    assert (saved["data"]["booking_id"], saved["data"]["useful_life_days"]) == (None, 1095)


def test_recurring_edit_keeps_generated_rows(client):
    body = {"description": "rent", "amount": "1.000.000", "currency": "COP", "category": "fixed"}
    saved = client.post("/api/recurring", json={**body, "start_month": "2026-08"}).get_json()
    item = saved["data"]
    edited = client.put(
        f"/api/recurring/{item['id']}",
        json={**body, "amount": "2000000", "start_month": "2026-08"},
    ).get_json()["data"]
    assert (edited["amount_minor"], edited["currency"]) == (200_000_000, "COP")
    assert [e["amount"] for e in edited["generated"]] == [e["amount"] for e in item["generated"]]


def test_generated_expense_is_locked_in_generic_endpoints(client):
    body = {"description": "rent", "amount": "100", "currency": "USD", "category": "fixed"}
    item = client.post("/api/recurring", json={**body, "start_month": "2026-08"}).get_json()["data"]
    generated = item["generated"][0]
    url = f"/api/expenses/{generated['id']}"
    assert client.put(url, json=body | {"date": "2026-08-01"}).status_code == 409
    assert client.delete(url).status_code == 409
    own = f"/api/recurring/{item['id']}/expenses/{generated['id']}"
    edited = client.put(own, json={"date": generated["date"], "amount": "120", "currency": "USD"})
    assert edited.get_json()["data"]["amount"] == 12_000
    assert edited.get_json()["data"]["category"] == "fixed"
    assert (
        client.put(f"/api/recurring/{item['id'] + 1}/expenses/{generated['id']}").status_code == 404
    )
