from pathlib import Path
from urllib.parse import urlparse

from flask import Flask, abort, g, request, send_from_directory
from werkzeug.exceptions import NotFound

from rios_de_asia_accounting.web import api
from rios_de_asia_accounting.web.app_db import get_db  # noqa: F401  (re-exported)

DIST = Path(__file__).parent / "dist"


def _same_origin() -> bool:
    for header in ("Origin", "Referer"):
        value = request.headers.get(header)
        if value:
            return urlparse(value).netloc == request.host
    return True


def create_app(db_path: str | Path) -> Flask:
    app = Flask(__name__, static_folder=DIST / "assets", static_url_path="/assets")
    app.config["DB_PATH"] = str(db_path)
    app.config["LAST_BACKUP"] = None  # set by the backup thread: {time, file, error}

    @app.before_request
    def guard() -> None:
        g.app_db_path = app.config["DB_PATH"]
        if request.method != "GET" and not _same_origin():
            abort(403)

    @app.teardown_appcontext
    def close_db(_exc: BaseException | None) -> None:
        conn = g.pop("db", None)
        if conn is not None:
            conn.close()

    api.register(app)
    api.common.register_errors(app)

    @app.errorhandler(NotFound)
    def not_found(exc: NotFound):
        # a client-side route: the app shell; /api keeps its JSON 404
        if request.path == "/api" or request.path.startswith("/api/"):
            return api.common._json_error(exc)
        if request.method != "GET" or request.path.startswith("/assets/"):
            return exc
        if not (DIST / "index.html").is_file():
            return "frontend not built\n", 404, {"Content-Type": "text/plain; charset=utf-8"}
        return send_from_directory(DIST, "index.html")

    return app
