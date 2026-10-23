import pytest

from rios_de_asia_accounting.web import app as app_module


@pytest.fixture(autouse=True)
def no_frontend_bundle(tmp_path_factory, monkeypatch):
    """Tests never depend on a built frontend bundle in web/dist."""
    monkeypatch.setattr(app_module, "DIST", tmp_path_factory.getbasetemp() / "no-dist")
