import pytest

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
    body = {"date": "2026-01-05", "amount": "1.500.000", "category": "fixed"}
    saved = client.post("/api/expenses", json=body).get_json()
    assert saved["data"]["amount"] == 1500000
    assert saved["notices"] == [{"level": "info", "text": "Expense saved."}]
    assert len(client.get("/api/expenses?category=fixed").get_json()) == 1
    assert client.get("/api/expenses?category=tax").get_json() == []
    assert client.delete(f"/api/expenses/{saved['data']['id']}").status_code == 200
    assert client.get("/api/expenses/options").get_json()["bookings"] == []


def test_invalid_expense_is_422(client):
    response = client.post("/api/expenses", json={"category": "per_booking", "amount": "5"})
    assert response.status_code == 422
    assert {"date", "booking_id"} <= set(response.get_json()["errors"])


def test_recurring_generates_expenses(client):
    body = {
        "description": "Internet",
        "amount": "90.000",
        "category": "fixed",
        "start_month": "2026-01",
    }
    saved = client.post("/api/recurring", json=body).get_json()
    assert "expense(s) generated" in saved["notices"][0]["text"]
    assert saved["data"]["generated"]
    deleted = client.delete(f"/api/recurring/{saved['data']['id']}").get_json()
    assert "kept" in deleted["notices"][0]["text"]


def test_expense_fields_ignored_for_other_categories(client):
    booking = {"check_in": "2026-03-01", "check_out": "2026-03-03", "net_payout": "1"}
    bid = str(client.post("/api/bookings", json=booking).get_json()["data"]["id"])
    body = {"date": "2026-03-05", "amount": "10.000", "booking_id": bid, "useful_life_days": "x"}
    saved = client.post("/api/expenses", json={**body, "category": "fixed"}).get_json()["data"]
    assert saved["booking_id"] is None and saved["useful_life_days"] is None
    body["useful_life_days"] = "1095"
    saved = client.post("/api/expenses", json={**body, "category": "per_booking"}).get_json()
    assert (saved["data"]["booking_id"], saved["data"]["useful_life_days"]) == (int(bid), None)
    saved = client.post("/api/expenses", json={**body, "category": "capex"}).get_json()
    assert (saved["data"]["booking_id"], saved["data"]["useful_life_days"]) == (None, 1095)


def test_recurring_edit_keeps_generated_rows(client):
    body = {"description": "rent", "amount": "1.000.000", "category": "fixed"}
    saved = client.post("/api/recurring", json={**body, "start_month": "2026-08"}).get_json()
    item = saved["data"]
    edited = client.put(
        f"/api/recurring/{item['id']}",
        json={**body, "amount": "2000000", "start_month": "2026-08"},
    ).get_json()["data"]
    assert edited["amount"] == 2000000
    assert [e["amount"] for e in edited["generated"]] == [e["amount"] for e in item["generated"]]
