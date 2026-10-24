import io
from pathlib import Path

import pytest

from rios_de_asia_accounting.storage.db import connect, migrate
from rios_de_asia_accounting.web.app import create_app

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def client(tmp_path):
    path = tmp_path / "books.db"
    conn = connect(path)
    migrate(conn)
    conn.close()
    return create_app(path).test_client()


def _file(name):
    return (io.BytesIO((FIXTURES / name).read_bytes()), name)


def test_airbnb_preview_apply_flow(client):
    response = client.post("/api/import/airbnb", data={"file": _file("airbnb_sample.csv")})
    preview = response.get_json()["data"]
    assert preview["needs_listing_choice"] is True and preview["listings_found"]
    token = preview["token"]

    refused = client.post("/api/import/airbnb/apply", json={"token": token})
    assert refused.status_code == 422
    assert refused.get_json()["preview"]["token"] == token

    listings = [f["listing"] for f in preview["listings_found"]]
    done = client.post("/api/import/airbnb/apply", json={"token": token, "listings": listings})
    assert done.get_json()["data"]["new"] > 0
    assert client.post("/api/import/airbnb/apply", json={"token": token}).status_code == 422


def test_cancel(client):
    preview = client.post("/api/import/airbnb", data={"file": _file("airbnb_sample.csv")})
    token = preview.get_json()["data"]["token"]
    cancelled = client.delete(f"/api/import/airbnb/{token}").get_json()
    assert cancelled["notices"][0]["text"] == "Import cancelled; nothing was changed."
