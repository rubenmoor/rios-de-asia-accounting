from rios_de_asia_accounting.web import app as app_module
from rios_de_asia_accounting.web.app import create_app


def test_unknown_paths_without_bundle(tmp_path, monkeypatch):
    monkeypatch.setattr(app_module, "DIST", tmp_path / "no-dist")
    client = create_app(tmp_path / "t.db").test_client()
    response = client.get("/nowhere")
    assert response.status_code == 404
    assert response.mimetype == "text/plain"
    assert "frontend not built" in response.text
    response = client.get("/api/nowhere")
    assert response.status_code == 404
    assert response.is_json and "error" in response.json


def test_unknown_path_with_bundle(tmp_path, monkeypatch):
    (tmp_path / "index.html").write_text("<div id=root></div>")
    monkeypatch.setattr(app_module, "DIST", tmp_path)
    response = create_app(tmp_path / "t.db").test_client().get("/nowhere")
    assert response.status_code == 200 and "root" in response.text
