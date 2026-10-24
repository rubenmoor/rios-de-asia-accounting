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


def test_unknown_api_path_is_json_404(client):
    response = client.get("/api/nothing")
    assert response.status_code == 404
    assert "error" in response.get_json()


def test_cross_origin_put_and_delete_are_403(client):
    for method in (client.put, client.delete):
        response = method("/api/nothing", headers={"Origin": "http://evil.example"})
        assert response.status_code == 403
        assert "error" in response.get_json()
