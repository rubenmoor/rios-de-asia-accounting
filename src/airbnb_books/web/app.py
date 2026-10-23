import os
from pathlib import Path
from urllib.parse import urlparse

from flask import Flask, abort, g, render_template, request

from airbnb_books import __version__
from airbnb_books.web import bookings
from airbnb_books.web.app_db import get_db  # noqa: F401  (re-exported)
from airbnb_books.web.forms import format_money

NAV = [
    ("bookings", "/bookings", "Bookings"),
    ("expenses", "/expenses", "Expenses"),
    ("recurring", "/recurring", "Recurring"),
    ("blocked", "/blocked-days", "Blocked days"),
    ("time", "/time", "Time"),
    ("rates", "/rates", "Rates"),
    ("import", "/import", "Import"),
    ("settings", "/settings", "Settings"),
]


def _same_origin() -> bool:
    for header in ("Origin", "Referer"):
        value = request.headers.get(header)
        if value:
            return urlparse(value).netloc == request.host
    return True


def create_app(db_path: str | Path) -> Flask:
    app = Flask(__name__)
    app.secret_key = os.urandom(24)  # only signs flash messages of this run
    app.config["DB_PATH"] = str(db_path)

    @app.before_request
    def guard() -> None:
        g.app_db_path = app.config["DB_PATH"]
        if request.method == "POST" and not _same_origin():
            abort(403)

    @app.teardown_appcontext
    def close_db(_exc: BaseException | None) -> None:
        conn = g.pop("db", None)
        if conn is not None:
            conn.close()

    app.jinja_env.filters["money"] = format_money

    @app.context_processor
    def nav() -> dict:
        active = next((e for e, url, _ in NAV if request.path.startswith(url)), None)
        return {"nav": NAV, "active": active}

    @app.route("/")
    def index() -> str:
        return render_template("index.html", version=__version__)

    def register_stub(endpoint: str, url: str, title: str) -> None:
        def view() -> str:
            return render_template("stub.html", title=title)

        app.add_url_rule(url, endpoint, view)

    bookings.register(app)
    for endpoint, url, title in NAV:
        if endpoint not in app.view_functions:
            register_stub(endpoint, url, title)

    return app
